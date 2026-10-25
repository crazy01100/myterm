"""Inventory and health fixtures only. No services, installs or vulnerability inputs."""
import datetime as dt
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT=Path(__file__).resolve().parents[2]
def load(name):
    s=importlib.util.spec_from_file_location(name,ROOT/'scripts'/f'{name}.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
c=load('security-toolchain-inventory');h=load('security-monitor-health')

class CoverageTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
    def write(self,path,data):
        p=self.root/path;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(data));return p
    def test_vendor_identity_is_separate_from_installed_distribution(self):
        rows=c.vendor_rows('requests==2.34.2\n  urllib3==2.7.0\ncertifi==2026.10.19\n','fixture')
        self.assertEqual(len(rows),3);self.assertEqual(rows[1]['origin'],'fixture/pip-vendored')
        self.assertEqual(rows[1]['advisoryStatus'],'not-queried')
    def test_invalid_or_duplicate_vendor_does_not_silently_disappear(self):
        for text in ('','requests>=1','requests==1\nRequests==2','name @ https://example.invalid'):
            with self.subTest(text=text),self.assertRaises(ValueError):c.vendor_rows(text,'fixture')
    def test_metadata_escape_and_size_limit(self):
        external=self.root/'outside';external.write_text('{}');base=self.root/'inside';base.mkdir();(base/'alias').symlink_to(external)
        with self.assertRaises(ValueError):c.document(base/'alias',base)
        with self.assertRaises(ValueError):c.read(external,limit=1)
    def test_duplicate_json_fields_rejected(self):
        p=self.root/'bad.json';p.write_text('{"name":"one","name":"two"}')
        with self.assertRaises(ValueError):c.document(p)
    def test_npm_inventory_excludes_fixture_package_files(self):
        self.write('package.json',{'name':'tool','version':'1.0.0'})
        self.write('node_modules/@fixture/a/package.json',{'name':'@fixture/a','version':'2.0.0'})
        self.write('node_modules/@fixture/a/test/package.json',{'name':'not-installed','version':'3.0.0'})
        self.write('node_modules/@fixture/a/node_modules/b/package.json',{'name':'b','version':'4.0.0'})
        self.assertEqual({r['name'] for r in c.npm_rows(self.root,'npm-tool')},{'tool','@fixture/a','b'})
    def test_lock_required_missing_or_installed_drift_blocks(self):
        self.write('package.json',{'name':'project','version':'1.0.0'})
        self.write('package-lock.json',{'lockfileVersion':3,'packages':{'':{},'node_modules/a':{'version':'1.0.0'}}})
        with self.assertRaises(ValueError):c.collect_project_npm(self.root)
        self.write('node_modules/a/package.json',{'name':'a','version':'2.0.0'})
        with self.assertRaises(ValueError):c.collect_project_npm(self.root)
    def test_platform_optional_absence_recorded(self):
        self.write('package.json',{'name':'project','version':'1.0.0'})
        self.write('package-lock.json',{'lockfileVersion':3,'packages':{'node_modules/a':{'version':'1.0.0','optional':True}}})
        rows,evidence=c.collect_project_npm(self.root);self.assertEqual(evidence[0]['optionalAbsent'],['node_modules/a'])
    def test_rust_path_crates_do_not_become_fake_registry_versions(self):
        data={'components':[{'name':'local','version':'1','purl':'pkg:cargo/local@1?download_url=file://.'},
                            {'name':'asn1','version':'0.24.1','purl':'pkg:cargo/asn1@0.24.1'}]}
        rows=c.rust_rows(data,'fixture');self.assertEqual([r['name'] for r in rows],['asn1'])
        self.assertEqual(rows[0]['runtimeReachability'],'not-established')
    def test_jar_requires_hash_and_preserves_shaded_limit(self):
        p=self.root/'fixture.jar'
        with zipfile.ZipFile(p,'w') as z:z.writestr('META-INF/maven/org.example/lib/pom.properties','groupId=org.example\nartifactId=lib\nversion=1.2.3\n')
        result=c.jar_metadata(p,hashlib.sha256(p.read_bytes()).hexdigest())
        self.assertEqual(result['coverage'],'partial');self.assertEqual(result['components'][0]['name'],'org.example:lib')
        with self.assertRaises(ValueError):c.jar_metadata(p,'0'*64)
    def test_unknown_collector_is_incomplete_not_zero_risk(self):
        policy={'status':'draft','collectors':[{'id':'new-tool','scopeIds':['C99'],'owner':'fixture','uses':['audit']}]}
        with patch.object(c,'configuration',return_value=policy):r=c.inventory(self.root)
        self.assertFalse(r['complete']);self.assertFalse(r['inventoryComplete']);self.assertTrue(r['errors'])
        self.assertEqual(r['advisoryStatus'],'not-run')
    def test_optional_unused_scope_does_not_run_collector(self):
        policy={'status':'draft','collectors':[{'id':'gcloud','scopeIds':['C14'],'owner':'fixture','uses':['sync-admin']}]}
        with patch.object(c,'configuration',return_value=policy):r=c.inventory(self.root)
        self.assertTrue(r['inventoryComplete']);self.assertFalse(r['complete'])
        self.assertEqual(r['coverage'][0]['status'],'not-applicable')

class SupplierBoundaryTests(unittest.TestCase):
    setUp = CoverageTests.setUp
    write = CoverageTests.write
    # Synthetic, inert JARs exercise policy decisions, not emulator behavior.
    def fixture(self):
        filename='cloud-firestore-emulator-v1.22.0.jar'
        path=self.root/'.build/security-inventory-artifacts'/filename
        path.parent.mkdir(parents=True)
        with zipfile.ZipFile(path,'w') as z:z.writestr('META-INF/MANIFEST.MF','Manifest-Version: 1.0')
        d={'id':'fixture-boundary','state':'accepted','component':'firestore-emulator',
           'kind':'supplier-managed-limited-subdependency-evidence','knownVulnerabilityWaiver':False,
           'subdependencyCoverage':'unavailable-from-supplier','firebaseToolsVersion':'15.34.0',
           'version':'1.22.0','filename':filename,'size':path.stat().st_size,
           'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'entryCount':1,
           'url':'https://example.invalid/'+filename,'noticeSources':['https://example.invalid/notices'],
           'use':'loopback demo Rules'}
        self.write(c.POLICY,{'supplierBoundaries':[d]})
        self.write('node_modules/firebase-tools/package.json',{'name':'firebase-tools','version':'15.34.0'})
        self.write('package-lock.json',{'packages':{'node_modules/firebase-tools':{'version':'15.34.0'}}})
        declaration={'version':d['version'],'expectedSize':d['size'],'expectedChecksumSHA256':d['sha256'],
                     'remoteUrl':d['url'],'downloadPathRelativeToCacheDir':d['filename']}
        self.write('node_modules/firebase-tools/lib/emulator/downloadableEmulatorInfo.json',{'firestore':declaration})
        return path,d,declaration
    def test_accepted_boundary_is_limited_and_does_not_claim_zero_risk(self):
        self.fixture();rows,evidence=c.collect_emulator(self.root)
        self.assertEqual(rows,[]);self.assertEqual(evidence[0]['coverageStatus'],'supplier-managed-limited')
        self.assertFalse(evidence[0]['allDependenciesScanned']);self.assertFalse(evidence[0]['knownVulnerabilityWaiver'])
        self.assertEqual(evidence[0]['advisoryStatus'],'not-queried')
    def test_missing_or_changed_actual_jar_cannot_use_accepted_metadata(self):
        path,_,_=self.fixture();path.write_bytes(b'changed')
        with self.assertRaises(ValueError):c.collect_emulator(self.root)
        path.unlink()
        with self.assertRaises(ValueError):c.collect_emulator(self.root)
    def test_changed_parent_or_remote_version_requires_new_review(self):
        _,_,declaration=self.fixture()
        self.write('node_modules/firebase-tools/package.json',{'name':'firebase-tools','version':'15.35.0'})
        with self.assertRaises(ValueError):c.collect_emulator(self.root)
        self.write('node_modules/firebase-tools/package.json',{'name':'firebase-tools','version':'15.34.0'})
        declaration['version']='1.23.0'
        self.write('node_modules/firebase-tools/lib/emulator/downloadableEmulatorInfo.json',{'firestore':declaration})
        with self.assertRaises(ValueError):c.collect_emulator(self.root)
    def test_boundary_does_not_cover_another_component_or_known_vulnerability(self):
        _,decision,_=self.fixture()
        for key,value in [('component','another-emulator'),('state','pending'),('knownVulnerabilityWaiver',True)]:
            self.write(c.POLICY,{'supplierBoundaries':[{**decision,key:value}]})
            with self.subTest(key=key),self.assertRaises(ValueError):c.collect_emulator(self.root)
    def test_operational_cache_cannot_hide_behind_verified_inventory_copy(self):
        path,decision,_=self.fixture()
        cache=self.root/'.firebase/emulators'/decision['filename'];cache.parent.mkdir(parents=True)
        cache.write_bytes(b'x'*path.stat().st_size)
        with self.assertRaises(ValueError):c.collect_emulator(self.root)
    def test_new_metadata_is_not_silently_hidden_by_supplier_status(self):
        self.fixture()
        with patch.object(c,'jar_metadata',return_value={'entryCount':1,'components':[], 'metadataCandidates':['SBOM.json']}):
            with self.assertRaises(ValueError):c.collect_emulator(self.root)


class HealthTests(unittest.TestCase):
    def setUp(self):
        self.now=dt.datetime(2026,10,24,tzinfo=dt.timezone.utc)
        self.workflow={'path':'.github/workflows/security-checks.yml','state':'active'}
        self.run={'id':1,'path':self.workflow['path'],'event':'schedule','head_branch':'main','head_repository':{'full_name':h.REPOSITORY},'status':'completed','conclusion':'success','updated_at':self.now.isoformat(),'html_url':'https://github.com/fixture'}
        self.artifact={'id':2,'name':'security-monitor-state','expired':False,'workflow_run':{'id':1}}
    def check(self):return h.evaluate(self.workflow,[self.run],[self.artifact],now=self.now)
    def test_recent_success_with_matching_evidence(self):self.assertTrue(self.check()['healthy'])
    def test_disabled_stale_failed_foreign_or_missing_artifact(self):
        for field,value in [('conclusion','failure'),('head_branch','foreign'),('event','push'),('updated_at',(self.now-dt.timedelta(hours=49)).isoformat())]:
            old=self.run[field];self.run[field]=value;self.assertFalse(self.check()['healthy']);self.run[field]=old
        self.artifact['expired']=True;self.assertFalse(self.check()['healthy']);self.artifact['expired']=False
        self.workflow['state']='disabled_inactivity';self.assertFalse(self.check()['healthy'])
    def test_foreign_artifact_cannot_substitute_for_missing_evidence(self):
        self.artifact['workflow_run']['id']=99;self.assertEqual(self.check()['status'],'missing-evidence')
    def test_future_or_unreviewed_threshold_is_invalid(self):
        self.run['updated_at']=(self.now+dt.timedelta(hours=1)).isoformat()
        with self.assertRaises(ValueError):self.check()
        with self.assertRaises(ValueError):h.evaluate(self.workflow,[],[],now=self.now,max_hours=72)


s=load('security-source-review')
class SourceReviewTests(unittest.TestCase):
    def setUp(self):
        self.identity={'number':71,'head':'a'*40,'base':'b'*40,'author':dict(s.MAINTAINER)}
        self.decision={'id':'security-monitoring','revision':1,'state':'approved'}
        self.raw=json.dumps({'schemaVersion':1,'decision':self.decision}).encode()
    def review(self,**changes):
        row={'id':100,'user':dict(s.MAINTAINER),'state':'COMMENTED','commit_id':'a'*40,
             'submitted_at':'2026-01-01T00:00:00Z','body':s.REVIEW_MARKER+'\n'+json.dumps(s.review_document(self.identity,self.decision,self.raw))}
        row.update(changes);return row
    def test_generic_statement_has_no_issue_acceptance(self):
        text=json.dumps(s.review_document(self.identity,self.decision,self.raw))
        self.assertNotIn('Issue',text);self.assertNotIn('retire',text);self.assertIn('no vulnerability exception',text)
    def test_exact_self_review_is_bound_to_head_base_and_raw_policy(self):
        r=self.review();self.assertEqual(s.select_review([[r]],self.identity,self.decision,self.raw)['reviewId'],100)
        for identity,raw in [({**self.identity,'head':'c'*40},self.raw),({**self.identity,'base':'c'*40},self.raw),(self.identity,self.raw+b' ')]:
            with self.assertRaises(ValueError):s.select_review([[r]],identity,self.decision,raw)
    def test_latest_revoke_or_comment_does_not_reuse_old_approval(self):
        old=self.review();revoke=self.review(id=101,body=s.REVIEW_MARKER+'\n'+json.dumps(s.review_document(self.identity,self.decision,self.raw,'revoke')))
        with self.assertRaises(ValueError):s.select_review([[old,revoke]],self.identity,self.decision,self.raw)
        with self.assertRaises(ValueError):s.select_review([[old,self.review(id=101,body='ordinary review')]],self.identity,self.decision,self.raw)
    def test_maintainer_spoofed_identity_does_not_pass(self):
        with self.assertRaises(ValueError):s.select_review([[self.review(user={**s.MAINTAINER,'id':1})]],self.identity,self.decision,self.raw)
    def test_pending_sources_never_authorize(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);p=root/s.POLICY;p.parent.mkdir(parents=True);p.write_text(json.dumps({'schemaVersion':1,'decision':{**self.decision,'state':'pending'}}))
            with self.assertRaises(ValueError):s.source_check(root)
    def test_source_review_module_never_fetches_closed_advisory(self):
        source=(ROOT/'scripts/security-source-review.py').read_text()
        self.assertNotIn('/advisories/',source);self.assertNotIn('fetch_json',source)

a=load('security-toolchain-advisories')
class AdvisoryCoverageTests(unittest.TestCase):
    def rows(self):return [c.component('PyPI','urllib3','2.0.0','pip-vendored'),c.component('PyPI','urllib3','2.0.0','installed')]
    def fetch(self,url,payload=None):
        if payload:return {'results':[{'vulns':[{'id':'GHSA-fixture'}]}]}
        return {'id':'GHSA-fixture','aliases':[],'affected':[{'package':{'ecosystem':'PyPI','name':'urllib3'},'ranges':[{'type':'ECOSYSTEM','events':[{'fixed':'2.1.0'}]}]}],'database_specific':{'severity':'HIGH'}}
    def test_duplicate_identities_query_once_preserve_origins(self):
        result=a.lookup(self.rows(),self.fetch);self.assertEqual(result['queriedIdentities'],1)
        self.assertEqual(result['findings'][0]['origins'],['installed','pip-vendored'])
        self.assertEqual(result['findings'][0]['fixedVersions'],['2.1.0'])
    def test_missing_batch_or_page_does_not_pass(self):
        for result in ({'results':[]},{'results':[{'next_page_token':'next'}]},{}):
            with self.subTest(result=result),self.assertRaises(ValueError):a.lookup(self.rows(),lambda *args:result)
    def test_unknown_ecosystem_is_not_skipped(self):
        with self.assertRaises(ValueError):a.lookup([c.component('native','openssl','3.5.8','python')],self.fetch)
    def test_sbom_candidate_is_not_verified_runtime_impact(self):
        row=self.rows()[0];row['runtimeReachability']='not-established'
        self.assertEqual(a.lookup([row],self.fetch)['findings'][0]['status'],'needs-review')


class EvidenceBoundaryTests(unittest.TestCase):
    def test_healthy_job_without_complete_report_is_rejected(self):
        import io
        for report in ({'scanStatus':'failed'}, {'scanStatus':'complete','errors':[],'releaseTag':'v1','checkedAt':dt.datetime.now(dt.timezone.utc).isoformat()}):
            data=io.BytesIO()
            with zipfile.ZipFile(data,'w') as z:z.writestr('security-report.json',json.dumps(report))
            with self.assertRaises(ValueError):h.retained_report(data.getvalue())
    def test_package_patch_versions_exclude_git_fix_hashes(self):
        row=c.component('PyPI','urllib3','2.0.0','fixture')
        def fetch(url,payload=None):
            if payload:return {'results':[{'vulns':[{'id':'GHSA-fixture'}]}]}
            return {'id':'GHSA-fixture','affected':[{'package':{'ecosystem':'PyPI','name':'urllib3'},'ranges':[
                {'type':'GIT','events':[{'fixed':'a'*40}]},{'type':'ECOSYSTEM','events':[{'fixed':'2.1.0'}]}]}]}
        result=a.lookup([row],fetch);self.assertEqual(result['findings'][0]['fixedVersions'],['2.1.0'])
    def test_npm_alias_preserves_registry_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'package.json').write_text(json.dumps({'name':'tool','version':'1.0.0','dependencies':{'alias':'npm:real-name@^1.0.0'}}))
            child=root/'node_modules/alias';child.mkdir(parents=True);(child/'package.json').write_text(json.dumps({'name':'real-name','version':'1.0.1'}))
            rows=c.npm_rows(root,'fixture');self.assertEqual(rows[0]['resolvedDependencies']['alias']['name'],'real-name')


r=load('security-toolchain-report')
class AggregateCoverageTests(unittest.TestCase):
    def setUp(self):
        self.now=dt.datetime.now(dt.timezone.utc)
        self.entry={'id':'emulator','scopeIds':['C12'],'uses':['audit','firebase'],'advisorySources':['vendor']}
        self.decision={'id':'exact-jar','component':'firestore-emulator','version':'1.22.0','sha256':'a'*64,
                       'size':123,'firebaseToolsVersion':'15.34.0','url':'https://example.invalid/emulator.jar',
                       'state':'accepted','knownVulnerabilityWaiver':False,
                       'kind':'supplier-managed-limited-subdependency-evidence'}
        self.evidence={**self.decision,'source':self.decision['url'],'boundaryId':'exact-jar',
                       'allDependenciesScanned':False,'coverageStatus':'supplier-managed-limited'}
        self.observed={'id':'emulator','scopeIds':['C12'],'status':'supplier-managed-limited','evidence':[self.evidence]}
        self.policy={'status':'approved','collectors':[self.entry],'supplierBoundaries':[self.decision]}
        self.inventory={'purpose':'audit','policyStatus':'approved','components':[],'coverage':[self.observed],'errors':[]}
        self.advisories={'advisoryQueryStatus':'complete','componentDigest':r.digest([]),
                         'checkedAt':self.now.isoformat(),'findings':[]}
        self.provider={'collector':'emulator','source':'vendor','status':'complete','coverageDigest':r.digest(self.observed),
                       'checkedAt':self.now.isoformat(),'identityCoverage':'supplier-boundary','findings':[]}
    def result(self):return r.summarize(self.inventory,self.advisories,self.policy,[self.provider],now=self.now)
    def test_supplier_boundary_completes_required_checks_but_never_all_dependencies(self):
        result=self.result();self.assertTrue(result['checksComplete']);self.assertFalse(result['allDependenciesScanned'])
        self.assertFalse(result['coverage'][0]['closureEligible']);self.assertFalse(result['blocking'])
        self.assertEqual(result['status'],'complete-with-supplier-limitations')
    def test_supplier_boundary_does_not_waive_known_findings(self):
        self.provider['findings']=[{'id':'fixture','severity':'high','status':'affected'}]
        result=self.result();self.assertTrue(result['checksComplete']);self.assertTrue(result['blocking'])
        self.assertEqual(len(result['findings']),1)
    def test_multiple_action_boundaries_require_every_exact_decision_and_runner_receipt(self):
        import copy
        self.entry.update(id='actions',scopeIds=['C11','C19'],advisorySources=['vendor','runner runtime and image'])
        self.observed.update(id='actions',scopeIds=['C11','C19'])
        decisions=[];proofs=[]
        for name in ('first','second'):
            d={'id':name,'kind':'action-bundle-limited-evidence','state':'accepted',
               'component':'actions/'+name,'revision':'a'*40,'archiveSHA256':'b'*64,
               'url':'https://example.invalid/'+name,'entrypoints':{'main':{'path':'dist/index.js','sha256':'c'*64}},
               'workflowSHA256':{'fixture.yml':'d'*64},'knownVulnerabilityWaiver':False,'runnerRuntimeCovered':False}
            decisions.append(d);proofs.append({**d,'source':d['url'],'boundaryId':name,
                'allDependenciesScanned':False,'coverageStatus':'supplier-managed-limited'})
        self.observed['evidence']=proofs;self.policy['supplierBoundaries']=decisions
        self.provider.update(collector='actions',coverageDigest=r.digest(self.observed))
        self.assertTrue(self.result()['blocking'])  # No runner evidence yet.
        runner={**self.provider,'source':'runner runtime and image'}
        result=r.summarize(self.inventory,self.advisories,self.policy,[self.provider,runner],now=self.now)
        self.assertTrue(result['checksComplete']);self.assertFalse(result['allDependenciesScanned'])
        self.assertEqual(len(result['supplierLimitations']),2)
        self.assertFalse(result['coverage'][0]['closureEligible'])
        self.advisories['findings']=[{'id':'fixture','severity':'high','status':'needs-review'}]
        self.assertTrue(r.summarize(self.inventory,self.advisories,self.policy,[self.provider,runner],now=self.now)['blocking'])
        self.policy['supplierBoundaries']=copy.deepcopy(decisions[:1])
        self.assertFalse(r.summarize(self.inventory,self.advisories,self.policy,[self.provider,runner],now=self.now)['checksComplete'])
    def test_drift_missing_query_failed_query_and_unknown_boundary_block(self):
        for key,value in [('status','failed'),('coverageDigest','b'*64),('source','different-source'),('identityCoverage','complete')]:
            old=self.provider[key];self.provider[key]=value
            with self.subTest(key=key):self.assertFalse(self.result()['checksComplete'])
            self.provider[key]=old
        self.policy['supplierBoundaries']=[];self.assertTrue(self.result()['blocking'])
    def test_changed_inventory_and_pending_policy_cannot_pass(self):
        self.inventory['components']=[c.component('npm','new-package','1.0.0','fixture')]
        self.assertFalse(self.result()['checksComplete'])
        self.inventory['components']=[];self.policy['status']='draft'
        self.assertFalse(self.result()['checksComplete'])
    def test_missing_collector_or_stale_evidence_blocks(self):
        self.inventory['coverage']=[];self.assertFalse(self.result()['checksComplete'])
        self.inventory['coverage']=[self.observed]
        self.provider['checkedAt']=(self.now-dt.timedelta(hours=49)).isoformat()
        self.assertFalse(self.result()['checksComplete'])
    def test_inactive_scope_cannot_close_old_risks(self):
        self.inventory['purpose']='development';self.observed['status']='not-applicable'
        result=self.result();self.assertTrue(result['checksComplete']);self.assertFalse(result['coverage'][0]['closureEligible'])
    def test_health_preserves_supplier_limitations(self):
        import io
        report={'scanStatus':'complete','errors':[],'releaseTag':'v1','checkedAt':self.now.isoformat(),
                'toolchainCoverage':self.result()}
        def archive():
            data=io.BytesIO()
            raw=json.dumps(report)
            with zipfile.ZipFile(data,'w') as z:
                z.writestr('security-report.json',raw)
                z.writestr('security-monitor-receipt.json',json.dumps({'schemaVersion':1,'complete':True,
                    'reportSHA256':hashlib.sha256(raw.encode()).hexdigest(),'riskIssues':'success','noticeIssues':'success'}))
            return data.getvalue()
        result=h.retained_report(archive());self.assertEqual(result['coverageStatus'],'complete-with-supplier-limitations')
        report['toolchainCoverage']['allDependenciesScanned']=True
        with self.assertRaises(ValueError):h.retained_report(archive())


class ActionBundleTests(unittest.TestCase):
    def fixture(self, root, license_version='1.0.0'):
        import io,tarfile
        repo='actions/fixture';revision='a'*40
        files={'action.yml':'runs:\n  using: node24\n  main: dist/index.js\n',
               'dist/index.js':'// inert fixture; never executed\n',
               'package-lock.json':json.dumps({'lockfileVersion':3,'packages':{
                   'node_modules/library':{'version':'1.0.0'},'node_modules/build-helper':{'version':'2.0.0','dev':True}}}),
               '.licenses/npm/library.dep.yml':'name: library\nversion: '+license_version+'\ntype: npm\n'}
        data=io.BytesIO()
        with tarfile.open(fileobj=data,mode='w:gz') as archive:
            for name,text in files.items():
                body=text.encode();entry=tarfile.TarInfo('fixture-'+revision+'/'+name);entry.size=len(body);archive.addfile(entry,io.BytesIO(body))
        blob=data.getvalue();relative='.build/security-inventory-actions/actions-fixture-'+revision+'.tgz'
        target=root/relative;target.parent.mkdir(parents=True);target.write_bytes(blob)
        config=root/'Config/Security/action-bundles.json';config.parent.mkdir(parents=True)
        config.write_text(json.dumps({'schemaVersion':1,'bundles':[{'repository':repo,'revision':revision,
            'url':f'https://codeload.github.com/{repo}/tar.gz/{revision}','cacheFile':relative,'archiveSHA256':hashlib.sha256(blob).hexdigest()}]}))
        return repo,revision,target
    def test_production_candidates_preserve_license_provenance_not_runtime_claim(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);repo,rev,_=self.fixture(root);rows,evidence=c.action_bundle(root,repo,rev)
            self.assertEqual([r['name'] for r in rows],['library']);self.assertTrue(rows[0]['licenseConfirmed'])
            self.assertEqual(rows[0]['runtimeReachability'],'not-established');self.assertEqual(evidence['productionLockNodes'],1)
            self.assertEqual(evidence['entrypoints']['main']['path'],'dist/index.js')
            self.assertEqual(len(evidence['entrypoints']['main']['sha256']),64)
    def test_mismatch_or_unreviewed_action_revision_never_becomes_empty_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);repo,rev,target=self.fixture(root)
            with self.assertRaises(ValueError):c.action_bundle(root,repo,'b'*40)
            target.write_bytes(b'changed archive')
            with self.assertRaises(ValueError):c.action_bundle(root,repo,rev)

    def accepted_fixture(self,root):
        repo,revision,target=self.fixture(root)
        _,proof=c.action_bundle(root,repo,revision)
        path=root/'.github/workflows/fixture.yml';path.parent.mkdir(parents=True)
        path.write_text('steps:\n  - uses: '+repo+'@'+revision+'\n')
        use={str(path.relative_to(root)):hashlib.sha256(path.read_bytes()).hexdigest()}
        decision={'id':'action-fixture','kind':'action-bundle-limited-evidence','state':'accepted',
                  'component':repo,'revision':revision,'archiveSHA256':proof['archiveSHA256'],
                  'url':f'https://codeload.github.com/{repo}/tar.gz/{revision}',
                  'entrypoints':proof['entrypoints'],'workflowSHA256':use,
                  'knownVulnerabilityWaiver':False,'runnerRuntimeCovered':False}
        return decision,path

    def test_exact_action_boundary_keeps_candidates_and_does_not_cover_runner(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);decision,_=self.accepted_fixture(root)
            with patch.object(c,'configuration',return_value={'supplierBoundaries':[decision]}):
                rows,evidence=c.collect_actions(root)
            self.assertEqual(len(rows),1)
            self.assertEqual(evidence[0]['coverageStatus'],'supplier-managed-limited')
            self.assertFalse(evidence[0]['allDependenciesScanned'])
            self.assertFalse(evidence[0]['runnerRuntimeCovered'])
            self.assertTrue(r.supplier_matches(evidence[0],decision,'actions'))
            self.assertFalse(r.supplier_matches(evidence[0],decision,'emulator'))

    def test_workflow_drift_or_unaccepted_boundary_blocks(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);decision,path=self.accepted_fixture(root)
            for change in ({'state':'pending'},{'knownVulnerabilityWaiver':True},{'runnerRuntimeCovered':True},{'entrypoints':{}}):
                with patch.object(c,'configuration',return_value={'supplierBoundaries':[{**decision,**change}]}):
                    with self.subTest(change=change),self.assertRaises(ValueError):c.collect_actions(root)
            path.write_text(path.read_text()+'    with:\n      unexpected: true\n')
            with patch.object(c,'configuration',return_value={'supplierBoundaries':[decision]}):
                rows,evidence=c.collect_actions(root)
                self.assertTrue(rows)  # Policy review checks workflow changes separately.
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);repo,rev,_=self.fixture(root,'2.0.0')
            with self.assertRaises(ValueError):c.action_bundle(root,repo,rev)

if __name__=='__main__':unittest.main()
