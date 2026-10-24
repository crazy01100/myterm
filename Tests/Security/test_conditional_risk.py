"""Policy-only fixtures. No npm import, emulator, vulnerability input or network."""
import copy
import datetime as dt
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]

def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module

p = load('security-conditional-risk')
a = load('security-audit')
f = load('security-issue-format')
s = load('sync-security-issues')
NOW = dt.datetime(2026, 10, 15, 12, tzinfo=dt.timezone.utc)

class ConditionalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='MyTerm-policy-fixture-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        packages = {'': {'devDependencies': {'firebase-tools': '15.33.0'}},
                    'node_modules/firebase-tools': {'version': '15.33.0', 'dependencies': {'chokidar': '3.6.0'}},
                    'node_modules/chokidar': {'version': '3.6.0', 'dependencies': {'braces': '3.0.3'}},
                    'node_modules/braces': {'version': '3.0.3'}}
        files = {'package-lock.json': json.dumps({'packages': packages}),
                 'firebase.json': json.dumps({'firestore': {'rules': 'firestore.rules'}, 'emulators': {'firestore': {'host': '127.0.0.1'}}})}
        for name in ('package.json','firestore.rules','firestore.indexes.json','Package.swift','Package.resolved',
                     'scripts/firebase-tools.sh','scripts/firebase-command-policy.py','scripts/build-app.sh',
                     'scripts/package-app.sh','scripts/security-conditional-risk.py'):
            files[name] = 'ordinary policy fixture\n'
        for name, value in files.items():
            target = self.root / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_text(value)
        for key, value in packages.items():
            if key:
                target = self.root / key / 'package.json'; target.parent.mkdir(parents=True); target.write_text(json.dumps(value))
        self.advisory = {'ghsa_id': p.IDENTITY['id'], 'summary':'fixture', 'description':'fixture', 'severity':'high',
                         'withdrawn_at':None, 'vulnerabilities':[{'package':{'ecosystem':'npm','name':'braces'},
                         'first_patched_version':None,'vulnerable_version_range':'<= 3.0.3'}]}
        self.registry = {'dist-tags':{'latest':'3.0.3'},'versions':{'3.0.3':{}}}
        self.cli = {'version':'15.33.0','dependencies':{'chokidar':'^3.6.0'}}
        self.decision = {**p.IDENTITY, 'state':'active','revision':1,'acceptedBy':'project maintainer',
                         'acceptedAt':'2026-10-15T00:00:00+00:00','allowedUses':['reviewed local tools'],
                         'residualRisk':'not a fix', 'baseline':{
                         'files':{name:p.file_hash(self.root,name) for name in files},
                         'dependencyGraph':p.dependency_graph(packages),
                         'advisoryDigest':p.digest(p.advisory_snapshot(self.advisory)),
                         'registryDigest':p.digest(p.registry_snapshot(self.registry)),
                         'upstreamChokidarRange':'^3.6.0'}}
        self.responses = {p.ADVISORY_URL:self.advisory,p.REGISTRY_URL:self.registry,p.CLI_URL:self.cli}

    def review(self):
        with patch.dict('os.environ', {}, clear=True):
            return p.evaluate(self.root,self.decision,lambda url:self.responses[url],NOW)

    def report(self):
        return {'errors':[],'findings':[{**p.IDENTITY,'severity':'high','status':'affected','url':'https://github.com/advisories/'+p.IDENTITY['id']}]}

    def test_exact_acceptance_retains_finding(self):
        r=self.report();p.attach(r,self.decision,self.review())
        self.assertFalse(a.blocking(r));self.assertEqual(len(r['findings']),1)
        self.assertEqual(r['findings'][0]['severity'],'high');self.assertEqual(r['findings'][0]['status'],'affected')

    def test_valid_pr_review_cannot_bypass_patch_or_source_checks(self):
        with patch.object(p,'verify_ci_baseline',return_value={'reviewId':10}):
            self.advisory['vulnerabilities'][0]['first_patched_version']='3.0.4'
            self.assertFalse(self.review()['accepted'])
            self.advisory['vulnerabilities'][0]['first_patched_version']=None
            (self.root/'firestore.rules').write_text('changed')
            self.assertFalse(self.review()['accepted'])

    def test_pr_review_rechecked_after_metadata_reads(self):
        with patch.object(p,'verify_ci_baseline',side_effect=[{'reviewId':10},{'reviewId':20}]):
            self.assertFalse(self.review()['accepted'])
        with patch.object(p,'verify_ci_baseline',return_value={'reviewId':10}) as check:
            self.assertTrue(self.review()['accepted'])
            self.assertEqual(check.call_count,2)

    def test_pending_never_authorizes(self):
        self.decision['state']='pending';r=self.review()
        self.assertEqual(r['status'],'matched');self.assertFalse(r['accepted'])

    def test_revoked_future_or_missing_approval(self):
        for change in ({'state':'revoked'},{'acceptedAt':'2027-01-01T00:00:00Z'},{'acceptedAt':None},{'acceptedBy':'bot'}):
            with self.subTest(change=change):
                original=copy.deepcopy(self.decision);self.decision.update(change)
                self.assertFalse(self.review()['accepted']);self.decision=original

    def test_wrong_identity_never_accepts(self):
        for key,value in [('id','GHSA-other'),('version','3.0.4'),('scope','released-app')]:
            with self.subTest(key=key):
                old=self.decision[key];self.decision[key]=value;self.assertFalse(self.review()['accepted']);self.decision[key]=old

    def test_source_change_blocks(self):
        (self.root/'scripts/firebase-tools.sh').write_text('changed')
        self.assertFalse(self.review()['accepted'])

    def test_unrelated_ui_does_not_change_scope(self):
        (self.root/'unrelated-ui.txt').write_text('ordinary UI fixture')
        self.assertTrue(self.review()['accepted'])

    def test_every_call_fetches_fresh(self):
        calls=[]
        def fetch(url):calls.append(url);return self.responses[url]
        with patch.dict('os.environ', {}, clear=True):
            for _ in range(2):self.assertTrue(p.evaluate(self.root,self.decision,fetch,NOW)['accepted'])
        self.assertEqual(len(calls),6)
        self.responses[p.ADVISORY_URL]['summary']='updated advisory'
        self.assertFalse(self.review()['accepted'])

    def test_offline_blocks_without_cached_receipt(self):
        with patch.dict('os.environ', {}, clear=True):
            result=p.evaluate(self.root,self.decision,lambda _:(_ for _ in ()).throw(OSError('offline')),NOW)
        self.assertFalse(result['accepted']);self.assertTrue(result['unavailable'])

    def test_patch_new_version_or_firebase_replacement_requires_review(self):
        self.advisory['vulnerabilities'][0]['first_patched_version']='3.0.4';self.assertFalse(self.review()['accepted'])
        self.advisory['vulnerabilities'][0]['first_patched_version']=None
        self.registry['versions']['3.0.4']={};self.assertFalse(self.review()['accepted'])
        del self.registry['versions']['3.0.4'];self.cli['dependencies']['chokidar']='^4.0.0';self.assertFalse(self.review()['accepted'])

    def test_other_risks_and_errors_still_block(self):
        for other in ({'scope':'development','status':'affected','severity':'high'}, {'scope':'current-source','status':'needs-review','severity':'low'}):
            r=self.report();p.attach(r,self.decision,self.review());r['findings'].append(other);self.assertTrue(a.blocking(r))
        r=self.report();r['errors']=['offline'];p.attach(r,self.decision,self.review());self.assertTrue(a.blocking(r))

    def test_no_fallback_to_old_exception(self):
        r=self.report();r['findings'][0].update(acceptedRisk=True,exceptionExpiresAt='old')
        self.decision['state']='revoked';p.attach(r,self.decision,self.review())
        self.assertTrue(a.blocking(r));self.assertNotIn('exceptionExpiresAt',r['findings'][0])

    def test_graph_includes_multiple_parents(self):
        graph={'':{'devDependencies':{'a':'1','b':'1'}},'node_modules/a':{'version':'1','dependencies':{'braces':'3.0.3'}},
               'node_modules/b':{'version':'1','dependencies':{'braces':'3.0.3'}},'node_modules/braces':{'version':'3.0.3'}}
        result=p.dependency_graph(graph)
        self.assertEqual(len(result['edges']),4);self.assertIn('node_modules/b',result['nodes'])

    def test_symlink_outside_checkout_rejected(self):
        (self.root/'firestore.rules').unlink();(self.root/'firestore.rules').symlink_to(ROOT/'firestore.rules')
        self.assertFalse(self.review()['accepted'])

    def test_pending_report_keeps_legacy_policy(self):
        r=self.report();r['findings'][0]['acceptedRisk']=True
        with patch.object(p,'load_policy',return_value={**self.decision,'state':'pending'}),patch.object(p,'evaluate') as call:
            p.review_report(r,self.root);call.assert_not_called()
        self.assertTrue(r['findings'][0]['acceptedRisk'])

    def test_missing_finding_prevents_resolution(self):
        r={'errors':[],'findings':[]}
        with patch.object(p,'load_policy',return_value=self.decision),patch.object(p,'evaluate',return_value=self.review()):p.review_report(r,self.root)
        self.assertTrue(r['errors']);self.assertTrue(a.blocking(r))

    def test_condition_mismatch_visible_without_marking_scan_failure(self):
        r=self.report();bad={**self.review(),'accepted':False,'status':'needs-review','reason':'changed source'}
        with patch.object(p,'load_policy',return_value=self.decision),patch.object(p,'evaluate',return_value=bad):p.review_report(r,self.root)
        self.assertEqual(r['errors'],[]);self.assertTrue(a.blocking(r));self.assertFalse(r['findings'][0]['acceptedRisk'])

    def test_format_preserves_severity_and_separates_review_time(self):
        r=self.report();p.attach(r,self.decision,self.review());finding=r['findings'][0]
        finding['conditionalAcceptance']['privateValue']='SHOULD_NOT_APPEAR'
        title,body=f.render('key',finding,{'checkedAt':'2026-10-01T00:00:00Z'})
        self.assertIn('高風險',title);self.assertIn('最近複核',body);self.assertIn('2026-10-15 20:00:00',body)
        self.assertIn('2026-10-01 08:00:00',body);self.assertNotIn('SHOULD_NOT_APPEAR',body)

    def test_review_time_change_is_not_risk_transition(self):
        r=self.report();p.attach(r,self.decision,self.review());before=f.semantic(r['findings'][0])
        r['findings'][0]['conditionalAcceptance']['checkedAt']='2026-10-16T00:00:00Z'
        self.assertEqual(before,f.semantic(r['findings'][0]))
        r['findings'][0]['conditionalAcceptance']['accepted']=False
        self.assertNotEqual(before,f.semantic(r['findings'][0]))

    def test_unreviewed_fork_cannot_accept(self):
        event=self.root/'event.json';event.write_text(json.dumps({'pull_request':{'base':{'repo':{'full_name':'crazy01100/myterm'},'sha':'a'*40},'head':{'repo':{'full_name':'other/fork'}}}}))
        with self.assertRaises(ValueError):p.verify_ci_baseline(self.root,self.decision,{'GITHUB_EVENT_NAME':'pull_request','GITHUB_EVENT_PATH':str(event)})

    def test_missing_and_malformed_policy_rejected(self):
        target=self.root/p.POLICY;target.parent.mkdir(parents=True)
        for value in ([],{}, {'schemaVersion':2,'decision':self.decision}, {'schemaVersion':1,'decision':{**self.decision,'state':'unknown'}}):
            with self.subTest(value=value):
                target.write_text(json.dumps(value))
                with self.assertRaises(ValueError):p.load_policy(self.root)

    def test_metadata_and_installation_missing_are_not_safe(self):
        del self.advisory['vulnerabilities'][0]['first_patched_version'];self.assertFalse(self.review()['accepted'])
        self.advisory['vulnerabilities'][0]['first_patched_version']=None
        (self.root/'node_modules/braces/package.json').write_text('{"version":"0.0.0"}')
        self.assertFalse(self.review()['accepted'])



class PRReviewTests(unittest.TestCase):
    """GitHub responses are synthetic. No real review submission or network."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='MyTerm-review-policy-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.head, self.base = 'c' * 40, 'a' * 40
        self.decision = {**p.IDENTITY, 'revision': 4, 'state': 'active',
                         'allowedUses': ['fixture'], 'residualRisk': 'unpatched',
                         'baseline': {'files': {'fixture': 'f' * 64}}}
        self.raw = json.dumps({'schemaVersion': 1, 'decision': self.decision}).encode()
        self.pr = {'number': 65, 'state': 'open', 'draft': False, 'user': dict(p.MAINTAINER),
                   'head': {'sha': self.head, 'repo': {'full_name': p.REPOSITORY}},
                   'base': {'sha': self.base, 'ref': 'main', 'repo': {'full_name': p.REPOSITORY}}}
        self.identity = p.pr_identity(self.pr, 65, self.head, self.base)
        target = self.root / p.POLICY
        target.parent.mkdir(parents=True)
        target.write_bytes(self.raw)
        trusted = copy.deepcopy(self.decision); trusted['revision'] = 3
        self.trusted = json.dumps({'schemaVersion': 1, 'decision': trusted}).encode()

    def review(self, **changes):
        value = {'id': 10, 'user': dict(p.MAINTAINER), 'state': 'COMMENTED',
                 'commit_id': self.head, 'submitted_at': '2026-10-15T00:00:00Z',
                 'body': p.REVIEW_MARKER + '\n' + json.dumps(
                     p.review_document(self.identity, self.decision, self.raw))}
        value.update(changes)
        return value

    def select(self, pages, identity=None):
        return p.select_review(pages, identity or self.identity, self.decision, self.raw)

    def inspect(self, pages=None, **kwargs):
        pages = pages if pages is not None else [[self.review()]]
        sequence = [self.pr, self.raw, self.trusted]
        if not kwargs.get('template'):
            sequence += [pages, copy.deepcopy(pages)]
        sequence += [self.pr]
        with patch.object(p, 'gh_read', side_effect=sequence) as api:
            result = p.inspect_pr_review(self.root, self.decision, 65, self.head, self.base, **kwargs)
        return result, api

    def test_self_comment_and_native_approval_are_distinct(self):
        self.assertEqual(self.select([[self.review()]])['mode'], 'maintainer-self-review')
        bot = {**self.identity, 'author': {'id': 42, 'login': 'dependabot[bot]', 'type': 'Bot'}}
        self.assertEqual(self.select([[self.review(state='APPROVED', body='Reviewed')]], bot)['mode'], 'github-approved')
        with self.assertRaises(ValueError):self.select([[self.review(state='APPROVED')]])
        with self.assertRaises(ValueError):self.select([[self.review()]], bot)

    def test_wrong_identity_never_qualifies(self):
        for user in ({'id': 42, 'login': 'other', 'type': 'User'},
                     {**p.MAINTAINER, 'id': 42}, {**p.MAINTAINER, 'type': 'Bot'},
                     {**p.MAINTAINER, 'login': 'renamed'}, {**p.MAINTAINER, 'id': str(p.MAINTAINER['id'])}):
            with self.subTest(user=user), self.assertRaises(ValueError):self.select([[self.review(user=user)]])

    def test_unsubmitted_stale_and_withdrawn_rejected(self):
        for changes in ({'state':'PENDING'}, {'state':'DISMISSED'}, {'state':'CHANGES_REQUESTED'},
                        {'submitted_at':None}, {'submitted_at':'2026-10-15'},
                        {'submitted_at':'2999-01-01T00:00:00Z'}, {'commit_id':'d'*40}):
            with self.subTest(changes=changes),self.assertRaises(ValueError):self.select([[self.review(**changes)]])

    def test_plain_comments_and_embedded_markers_do_not_approve(self):
        for body in ('LGTM', '同意', '', ' '+self.review()['body'], '```\n'+self.review()['body']+'\n```'):
            with self.subTest(body=body[:20]),self.assertRaises(ValueError):self.select([[self.review(body=body)]])

    def test_exact_document_fields_and_types_required(self):
        document = p.review_document(self.identity, self.decision, self.raw)
        for key,value in [('head',self.head[:7]),('base','b'*40),('pr',66),('repository','other/repo'),
                          ('revision',3),('policySHA256','0'*64),('action','revoke'),
                          ('schemaVersion',True),('statement','approved'),('decisionId','another')]:
            bad={**document,key:value}
            with self.subTest(key=key),self.assertRaises(ValueError):
                self.select([[self.review(body=p.REVIEW_MARKER+'\n'+json.dumps(bad))]])
        for bad in ({**document,'extra':True}, {k:v for k,v in document.items() if k!='head'}):
            with self.assertRaises(ValueError):self.select([[self.review(body=p.REVIEW_MARKER+'\n'+json.dumps(bad))]])

    def test_duplicate_json_fields_rejected(self):
        body=self.review()['body'].replace('"schemaVersion": 1','"schemaVersion": 1, "schemaVersion": 1')
        with self.assertRaises(ValueError):self.select([[self.review(body=body)]])

    def test_raw_policy_bytes_are_bound(self):
        with self.assertRaises(ValueError):p.select_review([[self.review()]],self.identity,self.decision,self.raw+b'\n')

    def test_latest_revocation_blocks_old_accept_across_pages(self):
        revoke=p.REVIEW_MARKER+'\n'+json.dumps(p.review_document(self.identity,self.decision,self.raw,'revoke'))
        for latest in (self.review(id=20,body=revoke), self.review(id=20,state='CHANGES_REQUESTED'),
                       self.review(id=20,state='DISMISSED'), self.review(id=20,body=p.REVIEW_MARKER+'\n{}')):
            with self.subTest(state=latest['state']),self.assertRaises(ValueError):
                self.select([[latest],[self.review()]])
        self.assertEqual(self.select([[self.review(id=20,body=revoke)],[self.review(id=30)]])['reviewId'],30)

    def test_later_self_review_cannot_erase_revocation_and_revive_old_accept(self):
        # Editing a later explicit revoke into ordinary text must not fall back
        # to an earlier acceptance. New self-authored reviews require a fresh
        # explicit decision; ordinary issue discussion comments are separate.
        with self.assertRaises(ValueError):
            self.select([[self.review(), self.review(id=20, body='A discussion')]])
        bot = {**self.identity, 'author': {'id':42,'login':'dependabot[bot]','type':'Bot'}}
        self.assertEqual(self.select([[self.review(state='APPROVED'),
                                      self.review(id=20,body='A discussion')]],bot)['reviewId'],10)

    def test_missing_malformed_or_duplicate_pages_fail(self):
        for pages in ([],{},[{}],[[None]],[[{'id':True}]],[[self.review()],[self.review()]], [[]]):
            with self.subTest(pages=pages),self.assertRaises((ValueError,TypeError)):self.select(pages)

    def test_readonly_api_sequence_and_binding(self):
        result,api=self.inspect()
        self.assertEqual(result['reviewId'],10)
        self.assertEqual(api.call_count,6)
        self.assertEqual(api.call_args_list[3],api.call_args_list[4])
        self.assertEqual(api.call_args_list[0],api.call_args_list[-1])

    def test_template_is_text_only_and_binds_revoke(self):
        result,api=self.inspect(template=True,action='revoke')
        self.assertEqual(api.call_count,4)
        self.assertEqual(p.strict_json(result.split('\n',1)[1])['action'],'revoke')
        self.assertNotIn('/reviews', str(api.call_args_list))

    def test_fork_draft_wrong_base_and_changed_refs_rejected(self):
        for field,value in [('draft',True),('state','closed'),('number',66)]:
            pr={**self.pr,field:value}
            with self.subTest(field=field),self.assertRaises(ValueError):p.pr_identity(pr,65,self.head,self.base)
        for part,field,value in [('head','repo',{'full_name':'other/fork'}),('base','ref','dev'),
                                 ('head','sha','d'*40),('base','sha','b'*40)]:
            pr=copy.deepcopy(self.pr);pr[part][field]=value
            with self.subTest(part=part,field=field),self.assertRaises(ValueError):p.pr_identity(pr,65,self.head,self.base)

    def test_invalid_arguments_never_reach_api(self):
        for number,head,base in [(True,self.head,self.base),(0,self.head,self.base),(65,'bad',self.base),(65,self.head,None)]:
            with patch.object(p,'gh_read') as api,self.assertRaises(ValueError):
                p.inspect_pr_review(self.root,self.decision,number,head,base)
            api.assert_not_called()

    def test_local_policy_does_not_match_remote(self):
        with patch.object(p,'gh_read',side_effect=[self.pr,self.raw+b'\n']),self.assertRaises(ValueError):
            p.inspect_pr_review(self.root,self.decision,65,self.head,self.base)

    def test_review_edit_or_deletion_during_query_fails(self):
        for after in ([[]],[[self.review(body='removed')]],[[self.review(id=20,state='DISMISSED')]]):
            seq=[self.pr,self.raw,self.trusted,[[self.review()]],after]
            with self.subTest(after=after),patch.object(p,'gh_read',side_effect=seq),self.assertRaises(ValueError):
                p.inspect_pr_review(self.root,self.decision,65,self.head,self.base)

    def test_push_or_author_change_during_query_fails(self):
        for after in ({**self.pr,'head':{**self.pr['head'],'sha':'d'*40}},
                      {**self.pr,'user':{'id':42,'login':'other','type':'User'}}):
            seq=[self.pr,self.raw,self.trusted,[[self.review()]],[[self.review()]],after]
            with patch.object(p,'gh_read',side_effect=seq),self.assertRaises(ValueError):
                p.inspect_pr_review(self.root,self.decision,65,self.head,self.base)

    def test_local_change_during_query_fails(self):
        seq=iter([self.pr,self.raw,self.trusted,[[self.review()]],[[self.review()]],self.pr])
        def read(*args,**kwargs):
            result=next(seq)
            if result is self.pr and read.calls:
                (self.root/p.POLICY).write_bytes(self.raw+b'\n')
            read.calls+=1
            return result
        read.calls=0
        with patch.object(p,'gh_read',side_effect=read),self.assertRaises(ValueError):
            p.inspect_pr_review(self.root,self.decision,65,self.head,self.base)

    def test_api_failure_is_not_acceptance(self):
        import subprocess
        with patch.object(p,'gh_read',side_effect=subprocess.TimeoutExpired('gh',25)),self.assertRaises(subprocess.SubprocessError):
            p.inspect_pr_review(self.root,self.decision,65,self.head,self.base)

    def test_unchanged_base_still_honours_revocation(self):
        self.trusted=self.raw
        result,_=self.inspect(pages=[[]])
        self.assertEqual(result['mode'],'unchanged-reviewed-base')
        with self.assertRaises(ValueError):self.inspect(pages=[[self.review(state='DISMISSED')]])

    def test_all_decision_fields_require_review_when_changed(self):
        for field in ('state','acceptedAt','reassessmentTriggers','allowedUses'):
            trusted={**self.decision,field:'different'}
            self.trusted=json.dumps({'decision':trusted}).encode()
            with self.subTest(field=field),self.assertRaises(ValueError):self.inspect(pages=[[]])

    def test_ci_uses_live_verifier_and_only_pr_event(self):
        event=self.root/'event.json';event.write_text(json.dumps({'pull_request':self.pr}))
        env={'GITHUB_EVENT_NAME':'pull_request','GITHUB_EVENT_PATH':str(event)}
        with patch.object(p,'inspect_pr_review',return_value={'mode':'fixture'}) as verifier:
            self.assertEqual(p.verify_ci_baseline(self.root,self.decision,env),{'mode':'fixture'})
            verifier.assert_called_once_with(self.root,self.decision,65,self.head,self.base)
        with patch.object(p,'inspect_pr_review') as verifier:
            p.verify_ci_baseline(self.root,self.decision,{'GITHUB_EVENT_NAME':'push'})
            verifier.assert_not_called()

    def test_cli_template_cannot_enable_acceptance_or_write(self):
        with patch.object(p,'ROOT',self.root),patch.object(p,'inspect_pr_review',return_value='template') as inspect,patch.object(p,'evaluate') as evaluate:
            self.assertEqual(p.main(['--pr-review','template','--pr','65','--expected-head',self.head,'--expected-base',self.base]),0)
            evaluate.assert_not_called()
            self.assertTrue(inspect.call_args.kwargs['template'])

    def test_premerge_rechecks_after_fresh_conditions(self):
        evidence={'reviewId':10}
        for accepted,after,expected in [(True,evidence,0),(False,evidence,1),(True,{'reviewId':20},1)]:
            with patch.object(p,'ROOT',self.root),patch.object(p,'inspect_pr_review',side_effect=[evidence,after]),patch.object(p,'evaluate',return_value={'accepted':accepted}):
                self.assertEqual(p.main(['--pr-review','verify','--pr','65','--expected-head',self.head,'--expected-base',self.base]),expected)

    def test_gh_transport_is_get_only(self):
        import subprocess
        with patch.object(p.subprocess,'run',return_value=subprocess.CompletedProcess([],0,b'[]')) as run:
            p.gh_read(self.root,'repos/example',pages=True)
        args=run.call_args.args[0]
        self.assertEqual(args[:4],['gh','api','--method','GET'])
        self.assertIn('--paginate',args);self.assertIn('--slurp',args)


class IssueLifecycleTests(unittest.TestCase):
    def test_issue43_never_auto_closes_when_finding_disappears(self):
        spec=importlib.util.spec_from_file_location('issue_fixtures',ROOT/'Tests/Security/test_security_issues.py')
        fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)
        api=fixture.FakeGitHub();report=fixture.report()
        report['findings']=[{**p.IDENTITY,'severity':'high','status':'affected','url':'https://github.com/advisories/'+p.IDENTITY['id']}]
        s.synchronize(report,api,True,fixture.ENV)
        actions=s.synchronize(fixture.report(False),api,True,fixture.ENV)
        self.assertEqual(api.issues[0]['state'],'open');self.assertEqual(actions[0]['action'],'needs-review')

    def test_repeated_reviews_update_summary_without_comments(self):
        spec=importlib.util.spec_from_file_location('issue_fixtures',ROOT/'Tests/Security/test_security_issues.py')
        fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)
        api=fixture.FakeGitHub();report=fixture.report();finding={**p.IDENTITY,'severity':'high','status':'affected','url':'https://github.com/advisories/'+p.IDENTITY['id'],
            'acceptedRisk':True,'conditionalAcceptance':{'decisionId':'issue-43','revision':1,'state':'active','status':'matched','accepted':True,'scope':'fixture','checkedAt':'2026-10-15T00:00:00Z'}}
        report['findings']=[finding];s.synchronize(report,api,True,fixture.ENV)
        finding['conditionalAcceptance']['checkedAt']='2026-10-15T01:00:00Z';s.synchronize(report,api,True,fixture.ENV)
        self.assertEqual(api.comments,[]);self.assertEqual(api.issues[0]['state'],'open');self.assertIn('09:00:00',api.issues[0]['body'])

class EntryOrderTests(unittest.TestCase):
    def test_guard_blocks_before_cli_build_or_dev_process_operations(self):
        import shutil,subprocess,sys
        if not shutil.which('zsh'):self.skipTest('zsh entry integration requires zsh')
        for entry,args in [('firebase-tools.sh',['--version']),('run-dev-app.sh',['--version','1.0.0-dev.1','--build','1']),
                           ('prepare-release-build.sh',['--version','1.0.0','--build','1'])]:
            with self.subTest(entry=entry),tempfile.TemporaryDirectory(prefix='MyTerm-entry-policy-') as tmp:
                root=Path(tmp);scripts=root/'scripts';scripts.mkdir()
                for name in ['firebase-command-policy.py','check-dev-launch.py']:(scripts/name).write_text('')
                (scripts/'security-conditional-risk.py').write_text('raise SystemExit(73)\n')
                py=scripts/'project-python.sh';py.write_text('#!/bin/sh\nexec "'+sys.executable+'" "$@"\n');py.chmod(0o700)
                (scripts/entry).write_text((ROOT/'scripts'/entry).read_text())
                cli=root/'node_modules/.bin/firebase';cli.parent.mkdir(parents=True);cli.write_text('#!/bin/sh\nexit 99\n');cli.chmod(0o700)
                result=subprocess.run(['zsh',str(scripts/entry),*args],capture_output=True,text=True,timeout=10)
                self.assertEqual(result.returncode,73,result.stderr)
                self.assertFalse((root/'build').exists())


class RetirementTests(unittest.TestCase):
    def setUp(self):
        ConditionalTests.setUp(self)
        self.advisory.update(cve_id='CVE-2026-93687',
                             html_url='https://github.com/advisories/'+p.IDENTITY['id'],
                             withdrawn_at='2026-10-14T00:00:00Z', description='Official withdrawal fixture')
        for name in p.RETIREMENT_FILES:
            target=self.root/name; target.parent.mkdir(parents=True,exist_ok=True)
            if not target.exists():target.write_text('fixture policy source\n')
        self.decision.update(state='retired',revision=6,retirement={
            'reason':'official-advisory-withdrawn','approvedBy':'project maintainer',
            'approvedAt':'2026-10-15T00:00:00Z','proposalSHA256':'a'*64,
            'withdrawnAt':self.advisory['withdrawn_at'],
            'advisoryDigest':p.digest(p.withdrawal_snapshot(self.advisory)),
            'sourceFiles':{name:p.file_hash(self.root,name) for name in p.RETIREMENT_FILES}})
        self.save()

    def save(self):
        target=self.root/p.POLICY;target.parent.mkdir(parents=True,exist_ok=True)
        target.write_text(json.dumps({'schemaVersion':1,'decision':self.decision}))

    def review(self):
        with patch.dict('os.environ',{},clear=True):
            return p.evaluate(self.root,self.decision,lambda url:self.responses[url],NOW)

    def test_retirement_is_verified_but_not_risk_acceptance(self):
        result=self.review()
        self.assertTrue(p.verified(result),result)
        self.assertFalse(result['accepted']);self.assertEqual(result['status'],'retired')
        # A new dependency lock does not revive an obsolete risk baseline.
        (self.root/'package-lock.json').write_text('{}')
        self.assertTrue(p.verified(self.review()))

    def test_fresh_metadata_required_and_reinstatement_blocks(self):
        for update in ({'withdrawn_at':None},{'description':'changed'},{'ghsa_id':'GHSA-other'},
                       {'withdrawn_at':'bad'}, {'vulnerabilities':[]}):
            original=copy.deepcopy(self.advisory)
            self.advisory.update(update)
            self.assertFalse(p.verified(self.review()),update)
            self.advisory.clear();self.advisory.update(original)
        with patch.dict('os.environ',{},clear=True):
            result=p.evaluate(self.root,self.decision,lambda _:(_ for _ in ()).throw(OSError('offline')),NOW)
        self.assertFalse(p.verified(result));self.assertTrue(result['unavailable'])

    def test_missing_approval_or_enforcement_source_blocks(self):
        for key,value in [('approvedBy','bot'),('approvedAt','2027-01-01T00:00:00Z'),
                          ('proposalSHA256',''),('reason','patched')]:
            old=self.decision['retirement'][key];self.decision['retirement'][key]=value;self.save()
            self.assertFalse(p.verified(self.review()))
            self.decision['retirement'][key]=old
        self.save()
        (self.root/'scripts/security-conditional-risk.py').write_text('changed')
        self.assertFalse(p.verified(self.review()))

    def test_retirement_still_requires_pr_review_and_rechecks_it(self):
        with patch.object(p,'verify_ci_baseline',side_effect=ValueError('missing review')):
            self.assertFalse(p.verified(self.review()))
        with patch.object(p,'verify_ci_baseline',side_effect=[{'reviewId':1},{'reviewId':2}]):
            self.assertFalse(p.verified(self.review()))
        with patch.object(p,'verify_ci_baseline',return_value={'reviewId':1}) as check:
            self.assertTrue(p.verified(self.review()));self.assertEqual(check.call_count,2)

    def test_retirement_report_no_exemption_for_active_findings_or_failures(self):
        report={'errors':[],'findings':[]}
        p.review_report(report,self.root,lambda url:self.responses[url])
        self.assertFalse(a.blocking(report),report)
        report={'errors':[],'findings':[{**p.IDENTITY,'severity':'high','status':'affected','acceptedRisk':True}]}
        p.review_report(report,self.root,lambda url:self.responses[url])
        self.assertTrue(a.blocking(report));self.assertFalse(report['findings'][0]['acceptedRisk'])
        self.advisory['withdrawn_at']=None
        report={'errors':[],'findings':[]}
        p.review_report(report,self.root,lambda url:self.responses[url])
        self.assertTrue(a.blocking(report))

    def test_main_retired_must_not_return_early_or_skip_report(self):
        output=self.root/'result.json'
        with patch.object(p,'ROOT',self.root),patch.object(p,'load_policy',return_value=self.decision),patch.object(p,'evaluate',return_value={'accepted':False,'status':'needs-review'}),patch.object(p.subprocess,'run') as run:
            run.return_value.stdout='a'*40
            self.assertEqual(p.main(['--purpose','development','--task','fixture','--output',str(output)]),1)
        self.assertTrue(output.exists())

    def test_retired_review_statement_is_distinct_and_bound_to_policy(self):
        identity={'number':1,'head':'a'*40,'base':'b'*40}
        doc=p.review_document(identity,self.decision,b'policy')
        self.assertEqual(doc['action'],'retire');self.assertEqual(doc['statement'],p.RETIREMENT_STATEMENT)
        with self.assertRaises(ValueError):p.review_document(identity,self.decision,b'policy','accept')
        self.assertEqual(p.review_document(identity,self.decision,b'policy','revoke')['action'],'revoke')

if __name__=='__main__':unittest.main()
