"""Inert official-archive fixtures and Issue metadata; no glob execution."""
import base64
import copy
import datetime as dt
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import tarfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT/'scripts'/f'{name}.py')
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m


m = load('security-picomatch-applicability')
p = load('security-project-applicability')
a = load('security-audit')
s = load('sync-security-issues')
from test_security_issues import FakeGitHub
ENV = {'GITHUB_ACTIONS': 'true', 'GITHUB_EVENT_NAME': 'schedule',
       'GITHUB_REPOSITORY': m.REPO, 'GITHUB_REF': 'refs/heads/main'}


class API(FakeGitHub):
    def request(self, path, method='GET', payload=None):
        if method == 'GET' and path.startswith('issues/'):
            return copy.deepcopy(next(i for i in self.issues if i['number'] == int(path.split('/')[1])))
        return super().request(path, method, payload)


class PicomatchTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup); self.root = Path(temp.name).resolve()
        self.advisory = {'ghsa_id': m.ID, 'summary': 'Synthetic fixed-caller assessment',
                         'description': 'Metadata fixture; never a vulnerability input', 'vulnerabilities': []}
        self.data = {'schemaVersion': 1, 'decision': m.DECISION, 'grantsRiskException': False,
                     'sourceFiles': {}, 'packages': {}, 'preparedSources': {},
                     'npmPolicy': {'fixture': 'official bundle'}, 'npmSources': {}, 'resolutions': m.RESOLUTIONS}
        lock = {'packages': {}}
        for relative, version in m.PACKAGES.items():
            files = {'package.json': json.dumps({'name': relative.split('node_modules/')[-1], 'version': version}).encode(),
                     'index.js': b'// inert source fixture\n'}
            prepared = {'node_modules/firebase-tools': 'lib/fsAsync.js',
                        'node_modules/superstatic': 'lib/utils/patterns.js'}.get(relative)
            if prepared: files[prepared] = b'// upstream import fixture\n'
            blob = self.tar(files); integrity = 'sha512-'+base64.b64encode(hashlib.sha512(blob).digest()).decode()
            key = hashlib.sha512(blob).hexdigest()
            self.write('.npm-cache/_cacache/content-v2/sha512/'+key[:2]+'/'+key[2:4]+'/'+key[4:], blob)
            entry = {'version': version, 'integrity': integrity, 'resolved': 'https://registry.npmjs.org/fixture.tgz'}
            lock['packages'][relative] = entry
            self.data['packages'][relative] = {'lockEntry': entry, 'sourceDigest': m.digest({n:m.sha(v) for n,v in files.items()})}
            for name, raw in files.items(): self.write(relative+'/'+name, raw)
            if prepared:
                actual = b'// reviewed prepared import fixture\n'; self.write(relative+'/'+prepared, actual)
                self.data['preparedSources'][relative+'/'+prepared] = {'upstream':m.sha(files[prepared]),'prepared':m.sha(actual)}
        for name in m.SOURCES: self.write(name, b'fixture reviewed project entry\n')
        self.write('package-lock.json', json.dumps(lock).encode())
        for name in m.NPM_SOURCES:
            raw = b'// inert official npm source\n'; self.write('.build/npm-runtime/'+name, raw)
            self.data['npmSources'][name] = m.sha(raw)
        # The fake official bundle verifier is a separate, already tested trust boundary.
        for dependencies in m.RESOLUTIONS.values():
            for relative in dependencies.values(): (self.root/relative).mkdir(parents=True, exist_ok=True)
        self.data['sourceFiles'] = {n:m.sha((self.root/n).read_bytes()) for n in m.SOURCES}
        self.rule = {'id':m.ID,'component':m.COMPONENT,'scope':'development','decision':m.DECISION,
                     'origins':list(m.VERSIONS),'originVersions':m.VERSIONS,'advisoryKind':'ghsa',
                     'advisorySHA256':p.advisory_digest(self.advisory,'ghsa'),'evidenceFile':m.EVIDENCE,'reason':'Synthetic fixed-caller evidence'}
        self.save_evidence()
        policy = json.loads((ROOT/p.CONFIG).read_text())
        policy['rules'] = [self.rule if r['id']==m.ID else r for r in policy['rules']]
        self.write(p.CONFIG,json.dumps(policy).encode())
        self.write('Config/Security/usage-applicability.json',(ROOT/'Config/Security/usage-applicability.json').read_bytes())
        self.write('Config/Security/exceptions.json',b'{"schemaVersion":1,"exceptions":[]}')
        npm = SimpleNamespace(verify=Mock(),policy=lambda _:self.data['npmPolicy'])
        old_m,old_p,old_s = m.load,p.load,s.load
        patches = [patch.object(m,'load',side_effect=lambda n: npm if n=='node-toolchain' else p if n=='security-project-applicability' else old_m(n)),
                   patch.object(p,'load',side_effect=lambda n:m if n=='security-picomatch-applicability' else old_p(n)),
                   patch.object(s,'load',side_effect=lambda n:m if n=='security-picomatch-applicability' else p if n=='security-project-applicability' else old_s(n)),
                   patch.object(p,'configuration',return_value=[self.rule]),
                   patch.object(p,'fetch_advisory',return_value=self.advisory),
                   patch.dict(os.environ,{'GITHUB_ACTIONS':'false'})]
        for item in patches: item.start(); self.addCleanup(item.stop)
        self.npm = npm

    def write(self,name,raw):
        path=self.root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(raw)

    def save_evidence(self):
        self.write(m.EVIDENCE,json.dumps(self.data).encode());self.rule['evidenceSHA256']=m.sha((self.root/m.EVIDENCE).read_bytes())

    def tar(self,files):
        buffer=io.BytesIO()
        with tarfile.open(fileobj=buffer,mode='w:gz') as tar:
            for name,raw in files.items():
                member=tarfile.TarInfo('package/'+name);member.size=len(raw);tar.addfile(member,io.BytesIO(raw))
        return buffer.getvalue()

    def report(self):
        f={'id':m.ID,'component':m.COMPONENT,'scope':'development','version':'4.0.4, 4.0.7',
           'severity':'high','status':'affected','url':'https://github.com/advisories/'+m.ID,'queryComplete':True,
           'dependencyPaths':list(m.VERSIONS)+[m.CHAIN],
           'environmentObservations':[{'environment':'local','origin':o,'versions':v} for o,v in m.VERSIONS.items()]}
        rows=[]
        for name in sorted(a.BASELINE_COLLECTORS)+['expanded-toolchain','released-app']:
            findings=([a.risk_projection({**f,'version':'4.0.7'})] if name=='npm-project' else
                      [a.risk_projection({**f,'version':'4.0.4'})] if name=='expanded-toolchain' else [])
            rows.append({'collector':name,'status':'complete','findings':findings})
        r={'schemaVersion':1,'checkedAt':dt.datetime.now(dt.timezone.utc).isoformat(),'scanStatus':'complete','errors':[],
           'findings':[f],'rawFindings':[copy.deepcopy(f)],'observedEnvironment':'local','observedOrigins':list(m.VERSIONS),
           'releaseTag':'v1.11.0',
           'applicabilityReviews':[],'supplierFixReviews':[],'picomatchReviewRequested':True,
           'collectionEvidence':{'schemaVersion':1,'baselineCommit':'22c3361bd0cce52086527a979ae61c3201d93763','collectors':rows},
           'toolchainCoverage':{'checksComplete':True},'packageMonitoring':{'queriesComplete':True},'vendorNotices':{'checksComplete':True},
           'sourceReview':{'sourceVerified':True,'grantsRiskException':False,'policySHA256':'a'*64}}
        p.classify(r,self.root)
        return r

    def api(self,r):
        api=API();f=r['rawFindings'][0];key=s.digest([f[k] for k in ('id','component','scope')]);title,body=s.render(key,f,r)
        api.issues=[{'number':220,'title':title,'body':body,'state':'open','user':{'login':s.BOT}}];return api

    def withdrawn_report(self):
        r=self.report();finding=copy.deepcopy(r['rawFindings'][0])
        previous=self.rule['advisorySHA256']
        stamp=(dt.datetime.now(dt.timezone.utc)-dt.timedelta(days=1)).isoformat()
        self.advisory.update(withdrawn_at=stamp,cve_id='CVE-2026-112366',
            html_url='https://github.com/advisories/'+m.ID,
            vulnerabilities=[{'package':{'ecosystem':'npm','name':'picomatch'}}])
        self.rule['withdrawal']={'state':'reviewed','withdrawnAt':stamp,
            'previousAdvisorySHA256':previous,'reason':'Synthetic reviewed official withdrawal; not a repair'}
        self.rule['advisorySHA256']=p.advisory_digest(self.advisory,'ghsa')
        r['findings']=[];r['rawFindings']=[]
        for row in r['collectionEvidence']['collectors']:row['findings']=[]
        for key in ('projectApplicabilityProofs','projectApplicabilityReviews'):del r[key]
        p.classify(r,self.root)
        return r,finding

    def test_withdrawal_is_distinct_and_never_excludes_a_current_risk(self):
        r,f=self.withdrawn_report();self.assertEqual(r['errors'],[])
        proof=r['projectApplicabilityProofs'][0]
        self.assertEqual(proof['status'],'withdrawn');self.assertFalse(m.covers(proof,f,'local'))
        self.assertEqual(r['projectApplicabilityReviews'],[])
        p.revalidate(r,self.root);s.validate_report(r)
        summary=self.root/'summary.md'
        with patch.dict(os.environ,{'GITHUB_STEP_SUMMARY':str(summary)}):a.write_summary(r,True)
        self.assertIn('官方公告已撤回（非套件修補）',summary.read_text())
        self.assertNotIn('精確平台／封裝不適用',summary.read_text())
        self.assertEqual(m.filter_baseline(r,[f]),[f])
        r['rawFindings']=[f]
        with self.assertRaises(ValueError):p.revalidate(r,self.root)

    def test_withdrawal_records_evidence_without_closing_then_reopens_original(self):
        r,f=self.withdrawn_report();api=self.api({**r,'rawFindings':[f]})
        changes=s.synchronize(r,api,True,ENV)
        self.assertEqual(changes[0]['action'],'record-withdrawal')
        self.assertEqual(api.issues[0]['state'],'open');self.assertEqual(api.comments,[])
        snapshot=s.fmt.parse_issue(api.issues[0]);self.assertEqual(snapshot['finding'],s.fmt.public_finding(f))
        self.assertTrue(m.owned_resolution(snapshot,220));self.assertTrue(p.owned_resolution(snapshot))
        self.assertIn('非套件修補',api.issues[0]['body']);self.assertEqual(s.synchronize(r,api,True,ENV),[])
        # Simulate the separately authorized maintainer closure after health.
        api.issues[0].update(state='closed',state_reason='not_planned')
        self.assertEqual(s.check_picomatch_for_publication(r,api,apply=True,environ=ENV,root=self.root)[0],[])
        self.assertEqual(s.synchronize(r,api,True,ENV),[])
        self.advisory['withdrawn_at']=None
        changes,changed=s.check_picomatch_for_publication(r,api,apply=True,environ=ENV,root=self.root)
        self.assertTrue(changed);self.assertEqual(changes[0]['number'],220)
        self.assertEqual(api.issues[0]['state'],'open');self.assertEqual(len(api.issues),1)
        self.assertNotIn('withdrawalReview',s.fmt.parse_issue(api.issues[0]))
        self.assertEqual(s.check_picomatch_for_publication(r,api,apply=True,environ=ENV,root=self.root)[0],[])

    def test_withdrawal_content_time_identity_and_source_drift_rejected(self):
        r,_=self.withdrawn_report();original=copy.deepcopy(self.advisory)
        for changes in ({'description':'changed'}, {'withdrawn_at':None}, {'withdrawn_at':'2020-01-01T00:00:00Z'},
                        {'cve_id':'CVE-other'},{'ghsa_id':'GHSA-other'},
                        {'vulnerabilities':[{'package':{'ecosystem':'npm','name':'other'}}]}):
            with self.subTest(changes=changes):
                self.advisory.clear();self.advisory.update(original);self.advisory.update(changes)
                with self.assertRaises(ValueError):p.revalidate(r,self.root)
        self.advisory.clear();self.advisory.update(original)
        self.write('node_modules/node-gyp/index.js',b'changed source')
        with self.assertRaises(ValueError):p.revalidate(r,self.root)

    def test_withdrawal_query_failure_reopens_closed_owned_record(self):
        r,f=self.withdrawn_report();api=self.api({**r,'rawFindings':[f]});s.synchronize(r,api,True,ENV)
        api.issues[0].update(state='closed',state_reason='not_planned')
        with patch.object(p,'fetch_advisory',side_effect=TimeoutError):
            changes,changed=s.check_picomatch_for_publication(r,api,apply=True,environ=ENV,root=self.root)
        self.assertTrue(changed);self.assertEqual(changes[0]['number'],220)

    def test_failed_scan_cannot_record_or_close_withdrawal(self):
        r,f=self.withdrawn_report();api=self.api({**r,'rawFindings':[f]})
        r['scanStatus']='failed';r['errors']=['unrelated query failed']
        with self.assertRaises(ValueError):s.synchronize(r,api,True,ENV)
        r['publicationMode']='additive'
        self.assertEqual(s.synchronize(r,api,True,ENV)[0]['action'],'preserve')
        self.assertEqual(api.issues[0]['state'],'open')
        self.assertNotIn('withdrawalReview',s.fmt.parse_issue(api.issues[0]))

    def test_withdrawal_proof_cannot_be_borrowed_or_forged(self):
        r,f=self.withdrawn_report();original=copy.deepcopy(r)
        for changes in ({'id':'GHSA-other'}, {'component':'other'}, {'scope':'released-app'},
                        {'status':'fixed'}, {'evidence':{}}, {'grantsRiskException':True}):
            r=copy.deepcopy(original);r['projectApplicabilityProofs'][0].update(changes)
            with self.assertRaises(ValueError):p.validate_envelope(r)
        r=copy.deepcopy(original);r['projectApplicabilityProofs'][0]['evidence']['withdrawal']['advisorySHA256']='b'*64
        with self.assertRaises(ValueError):p.validate_envelope(r)
        self.assertFalse(m.owned_resolution({'finding':f,'withdrawalReview':{
            'kind':'official-withdrawal','decision':m.DECISION,'proofSHA256':'a'*64}},999))

    def test_withdrawn_advisory_without_review_still_fails(self):
        self.advisory['withdrawn_at']=dt.datetime.now(dt.timezone.utc).isoformat()
        self.rule['advisorySHA256']=p.advisory_digest(self.advisory,'ghsa')
        with self.assertRaisesRegex(ValueError,'conditions changed'):p.verify(self.rule,self.root)

    def test_withdrawal_reopen_write_failure_is_not_success_and_comment_deduplicates(self):
        r,f=self.withdrawn_report();api=self.api({**r,'rawFindings':[f]});s.synchronize(r,api,True,ENV)
        api.issues[0].update(state='closed',state_reason='not_planned');self.advisory['withdrawn_at']=None
        api.fail_patch=True
        with self.assertRaises(RuntimeError):s.check_picomatch_for_publication(r,api,apply=True,environ=ENV,root=self.root)
        count=len(api.comments);api.fail_patch=False
        s.check_picomatch_for_publication(r,api,apply=True,environ=ENV,root=self.root)
        self.assertEqual(len(api.comments),count);self.assertEqual(api.issues[0]['state'],'open')

    def test_exact_official_sources_preserve_raw_and_validate_partition(self):
        r=self.report();self.assertEqual(r['errors'],[]);self.assertEqual(r['findings'],[])
        self.assertEqual(len(r['projectApplicabilityReviews']),1);self.npm.verify.assert_called()
        s.validate_report(r);p.revalidate(json.loads(json.dumps(r)),self.root)
        with patch.object(a,'ROOT',self.root):self.assertEqual(m.filter_baseline(r,a.baseline_findings(r)),[])

    def test_prepared_imports_do_not_allow_arbitrary_edits(self):
        self.write('node_modules/firebase-tools/lib/fsAsync.js',b'changed normal source')
        with self.assertRaisesRegex(ValueError,'consumer differs'):m.verify(self.root,self.rule)

    def test_archive_corruption_and_extra_or_modified_source_rejected(self):
        for mutate in ('archive','extra','modified'):
            with self.subTest(mutate=mutate):
                path=self.root/'node_modules/node-gyp/index.js'
                if mutate=='archive':path=next(p for p in (self.root/'.npm-cache').rglob('*') if p.is_file())
                if mutate=='extra':path=self.root/'node_modules/node-gyp/additional.js'
                old=path.read_bytes() if path.exists() else None;path.write_bytes(b'changed inert bytes')
                with self.assertRaises(ValueError):m.verify(self.root,self.rule)
                if old is None:path.unlink()
                else:path.write_bytes(old)

    def test_workflow_npm_source_or_missing_resolution_cannot_pass(self):
        for name in ['.github/workflows/security-gate.yml','.build/npm-runtime/node_modules/node-gyp/lib/build.js']:
            old=(self.root/name).read_bytes();self.write(name,b'changed entry')
            with self.assertRaises(ValueError):m.verify(self.root,self.rule)
            self.write(name,old)
        shadow=self.root/'node_modules/node-gyp/node_modules/tinyglobby';shadow.mkdir(parents=True)
        with self.assertRaisesRegex(ValueError,'shadowed'):m.verify(self.root,self.rule)

    def test_symlink_and_missing_archive_are_rejected(self):
        source=self.root/'node_modules/node-gyp/index.js';source.unlink();source.symlink_to(self.root/'package.json')
        with self.assertRaises(ValueError):m.verify(self.root,self.rule)
        source.unlink();source.write_bytes(b'// inert source fixture\n')
        cache=next(p for p in (self.root/'.npm-cache').rglob('*') if p.is_file());cache.unlink()
        with self.assertRaises(OSError):m.verify(self.root,self.rule)

    def test_other_scope_origins_versions_and_incomplete_queries_stay_risks(self):
        r=self.report();proof=r['projectApplicabilityProofs'][0];f=r['rawFindings'][0]
        for change in [{'id':'GHSA-other'},{'component':'other'},{'scope':'github-actions'},{'version':'4.0.8'},
                       {'dependencyPaths':list(m.VERSIONS)}, {'environmentObservations':[]},
                       {'environmentObservations':[{'environment':'ci','origin':'project-npm','versions':['4.0.7']}]}]:
            self.assertFalse(m.covers(proof,{**f,**change},'local'))
        r['projectApplicabilityReviews'][0]['finding']['queryComplete']=False
        with patch.object(a,'ROOT',self.root):self.assertEqual(len(m.filter_baseline(r,a.baseline_findings(r))),1)

    def test_original_collector_cannot_borrow_expanded_only_or_foreign_proof(self):
        r=self.report();original=copy.deepcopy(r)
        core=next(x for x in r['collectionEvidence']['collectors'] if x['collector']=='npm-project')['findings'][0]
        self.assertEqual(m.filter_baseline(r,[core]),[])
        r['projectApplicabilityReviews']=[];self.assertEqual(m.filter_baseline(r,[core]),[core])
        r=copy.deepcopy(original);next(x for x in r['collectionEvidence']['collectors'] if x['collector']=='app-source')['findings']=[copy.deepcopy(core)]
        self.assertEqual(m.filter_baseline(r,[core]),[core])
        r=copy.deepcopy(original);core={**core,'version':'4.0.8'}
        self.assertEqual(m.filter_baseline(r,[core]),[core])

    def test_gate_rechecks_live_sources_and_keeps_other_high_risks(self):
        r=self.report();noop=SimpleNamespace(revalidate=lambda *args:None)
        with patch.object(a,'ROOT',self.root),patch.object(a,'project_applicability',return_value=p), \
             patch.object(a,'pip_applicability',return_value=noop),patch.object(a,'openssl_supplier',return_value=noop), \
             patch.object(a,'supplier_notices',return_value=noop):
            self.assertFalse(a.blocking(r,merge_gate=True))
            self.write('node_modules/node-gyp/index.js',b'changed')
            self.assertTrue(a.blocking(r,merge_gate=True))
        core=a.risk_projection({**r['rawFindings'][0],'id':'GHSA-other','version':'1.0.0'})
        self.assertEqual(m.filter_baseline(r,[core]),[core])

    def test_advisory_drift_failure_and_raw_deletion_cannot_authorize(self):
        r=self.report();self.advisory['description']='changed conditions'
        current,changed=m.publication_state(r,self.root);self.assertTrue(changed);self.assertEqual(current['outcomes'][0]['status'],'needs-review')
        with self.assertRaises(ValueError):p.revalidate(r,self.root)
        r['rawFindings']=[]
        with self.assertRaises(ValueError):s.validate_report(r)

    def test_close_once_and_reopen_owned_original_after_source_drift(self):
        r=self.report();api=self.api(r)
        self.assertEqual(s.synchronize(r,api,True,ENV)[0]['action'],'close-not-applicable')
        self.assertEqual(s.synchronize(r,api,True,ENV),[])
        self.write('node_modules/node-gyp/index.js',b'changed')
        changes,changed=s.check_picomatch_for_publication(r,api,apply=True,environ=ENV,root=self.root)
        self.assertTrue(changed);self.assertEqual(changes[0]['number'],220);self.assertEqual(api.issues[0]['state'],'open')
        self.assertEqual(s.check_picomatch_for_publication(r,api,apply=True,environ=ENV,root=self.root)[0],[])

    def test_failed_scan_still_reopens_but_cannot_close_other_issue(self):
        r=self.report();api=self.api(r);s.synchronize(r,api,True,ENV)
        self.write('node_modules/node-gyp/index.js',b'changed');partial=self.report();self.assertTrue(partial['errors'])
        api.issues.append({'number':999,'body':'unrelated','state':'open'})
        changes,_=s.check_picomatch_for_publication(partial,api,apply=True,environ=ENV,root=self.root)
        self.assertEqual([c['number'] for c in changes],[220]);self.assertEqual(api.issues[1]['body'],'unrelated')

    def test_reopen_requires_exact_owner_record_and_main_context(self):
        r=self.report();api=self.api(r);s.synchronize(r,api,True,ENV);self.write('node_modules/node-gyp/index.js',b'changed')
        for env in [{},{**ENV,'GITHUB_EVENT_NAME':'pull_request'},{**ENV,'GITHUB_REPOSITORY':'other/repo'}]:
            with self.assertRaises(ValueError):s.check_picomatch_for_publication(r,api,apply=True,environ=env,root=self.root)
        api.issues[0]['user']['login']='human'
        self.assertEqual(s.check_picomatch_for_publication(r,api,apply=True,environ=ENV,root=self.root)[0],[])

    def test_write_failure_remains_incomplete_and_deduplicates_comment(self):
        r=self.report();api=self.api(r);s.synchronize(r,api,True,ENV);self.write('node_modules/node-gyp/index.js',b'changed')
        api.fail_patch=True
        with self.assertRaises(RuntimeError):s.check_picomatch_for_publication(r,api,apply=True,environ=ENV,root=self.root)
        count=len(api.comments);api.fail_patch=False
        s.check_picomatch_for_publication(r,api,apply=True,environ=ENV,root=self.root)
        self.assertEqual(len(api.comments),count)

    def test_absence_without_proof_does_not_close_as_fixed(self):
        r=self.report();api=self.api(r);r['findings']=[];r['rawFindings']=[];r['projectApplicabilityProofs']=[];r['projectApplicabilityReviews']=[]
        self.assertEqual(s.synchronize(r,api,True,ENV)[0]['action'],'preserve');self.assertEqual(api.issues[0]['state'],'open')

    def test_missing_required_binding_or_different_origin_policy_is_rejected(self):
        old=copy.deepcopy(self.data)
        for field in ('npmSources','resolutions','sourceFiles'):
            self.data=copy.deepcopy(old);self.data[field]={};self.save_evidence()
            with self.assertRaises(ValueError):m.verify(self.root,self.rule)
        self.data=old;self.save_evidence()
        with self.assertRaises(ValueError):m.verify(self.root,{**self.rule,'originVersions':{'other':['4.0.7']}})

    def test_notice_failure_cli_only_reopens_and_records_incomplete_receipt(self):
        r=self.report();api=self.api(r);s.synchronize(r,api,True,ENV)
        self.write('node_modules/node-gyp/index.js',b'changed');partial=self.report()
        current,changed=m.publication_state(partial,self.root)
        partial['sourceReview'].update(checkoutCommit='a'*40,publicationAuthorized=True)
        path=self.root/'report.json';path.write_text(json.dumps(partial))
        original=s.load
        def loaded(name):
            if name=='security-source-review':return SimpleNamespace(source_check=lambda:partial['sourceReview'])
            return original(name)
        with patch.object(s,'load',side_effect=loaded),patch.object(s,'GitHub',return_value=api), \
             patch.object(m,'publication_state',return_value=(current,changed)),patch.dict(os.environ,ENV), \
             patch('sys.argv',['sync','--report',str(path),'--apply','--reopen-applicability-only']):
            with self.assertRaisesRegex(ValueError,'Notice publication failed'):s.main()
        result=json.loads(path.with_name('security-issues-result.json').read_text())
        self.assertFalse(result['complete']);self.assertEqual(result['changes'][0]['number'],220)
        self.assertEqual(api.issues[0]['state'],'open')


if __name__=='__main__':unittest.main()
