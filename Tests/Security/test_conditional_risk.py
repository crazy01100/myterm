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

    def test_exact_head_maintainer_review_allows_changed_baseline_only(self):
        import subprocess
        event=self.root/'event.json';repo={'full_name':'crazy01100/myterm'}
        event.write_text(json.dumps({'pull_request':{'number':99,'base':{'repo':repo,'sha':'a'*40},'head':{'repo':repo,'sha':'c'*40}}}))
        trusted=copy.deepcopy(self.decision);trusted['baseline']['advisoryDigest']='b'*64
        base=subprocess.CompletedProcess([],0,json.dumps({'decision':trusted}))
        for state,sha,author,valid in [('APPROVED','c'*40,'crazy01100',True),('DISMISSED','c'*40,'crazy01100',False),
                                      ('APPROVED','d'*40,'crazy01100',False),('APPROVED','c'*40,'someone',False),
                                      ('CHANGES_REQUESTED','c'*40,'crazy01100',False)]:
            with self.subTest(state=state,sha=sha,author=author):
                reviews=subprocess.CompletedProcess([],0,json.dumps([[{'id':1,'state':state,'commit_id':sha,'user':{'login':author}}]]))
                with patch.object(p.subprocess,'run',side_effect=[base,reviews]):
                    if valid:p.verify_ci_baseline(self.root,self.decision,{'GITHUB_EVENT_NAME':'pull_request','GITHUB_EVENT_PATH':str(event)})
                    else:
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

    def test_pr_cannot_change_reviewed_baseline(self):
        import subprocess
        event=self.root/'event.json';repo={'full_name':'crazy01100/myterm'}
        event.write_text(json.dumps({'pull_request':{'base':{'repo':repo,'sha':'a'*40},'head':{'repo':repo}}}))
        trusted=copy.deepcopy(self.decision);trusted['baseline']['advisoryDigest']='b'*64
        response=subprocess.CompletedProcess([],0,json.dumps({'decision':trusted}))
        with patch.object(p.subprocess,'run',return_value=response),self.assertRaises(ValueError):
            p.verify_ci_baseline(self.root,self.decision,{'GITHUB_EVENT_NAME':'pull_request','GITHUB_EVENT_PATH':str(event)})


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

if __name__=='__main__':unittest.main()
