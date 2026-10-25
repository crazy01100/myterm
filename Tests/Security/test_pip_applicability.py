"""Synthetic subset/advisory proofs only; no vulnerability payload or network."""
import copy
import importlib.util
import json
import hashlib
from pathlib import Path
import tempfile
import unittest
import zipfile
from types import SimpleNamespace
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
def load(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/f'{name}.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
m=load('security-pip-applicability')


class ApplicabilityTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
        self.advisories={i:{'ghsa_id':i,'html_url':'https://github.com/advisories/'+i,'withdrawn_at':None,
                            'summary':'fixture subset condition','description':'Affected implementation fixture',
                            'vulnerabilities':[{'package':{'name':'setuptools','ecosystem':'pip'},
                                                'vulnerable_version_range':'<99.0.0'}]} for i in m.IDS}
        self.rule={'schemaVersion':1,'decision':'pip-setuptools-subset','state':'approved','grantsRiskException':False,
                   'pipVersion':'26.2.2','componentVersion':'70.3.0','wheelSHA256':'a'*64,
                   'vendorManifestSHA256':'b'*64,'advisories':{i:m.advisory_digest(a) for i,a in self.advisories.items()}}
        p=self.root/m.CONFIG;p.parent.mkdir(parents=True);p.write_text(json.dumps(self.rule))
        self.proof={'pipVersion':'26.2.2','wheelSHA256':'a'*64,'environments':[
            {'role':r,'origin':r+'/pip-vendored','vendorFiles':2,'vendorManifestSHA256':'b'*64} for r in m.ROLES],
                    'globalSitePackages':False}
        self.findings=[{'id':i,'component':'setuptools','version':'70.3.0','scope':'verification-tool',
                        'severity':'high','status':'needs-review','queryComplete':True,
                        'url':'https://github.com/advisories/'+i,'dependencyPaths':sorted(m.ORIGINS),
                        'environmentObservations':[{'environment':'local','origin':o,'versions':['70.3.0']} for o in sorted(m.ORIGINS)]}
                       for i in sorted(m.IDS)]
        self.report={'findings':copy.deepcopy(self.findings),'observedEnvironment':'local','errors':[]}
        self.env=patch.dict(m.os.environ,{'GITHUB_ACTIONS':'false'});self.env.start();self.addCleanup(self.env.stop)

    def fetch(self,path):
        if path.startswith('repos/msgpack/msgpack-python/commits/'):
            return copy.deepcopy(self.msgpack_patch)
        return copy.deepcopy(self.advisories[path.removeprefix('advisories/')])

    def add_msgpack(self):
        self.msgpack_patch={'sha':m.MSGPACK_PATCH,'files':[
            {'filename':name,'sha':'c'*40,'status':'modified'}
            for name in ('msgpack/_unpacker.pyx','msgpack/unpack_template.h')]}
        self.advisories[m.MSGPACK_ID]={**copy.deepcopy(next(iter(self.advisories.values()))),
            'ghsa_id':m.MSGPACK_ID,'html_url':'https://github.com/advisories/'+m.MSGPACK_ID,
            'vulnerabilities':[{'package':{'name':'msgpack','ecosystem':'pip'},'vulnerable_version_range':'<=1.2.0'}]}
        self.rule['msgpack']={'decision':'pip-msgpack-pure-python','state':'approved','id':m.MSGPACK_ID,
            'componentVersion':'1.1.2','patchCommit':m.MSGPACK_PATCH,
            'patchSHA256':m.msgpack_patch_digest(self.msgpack_patch),
            'advisorySHA256':m.advisory_digest(self.advisories[m.MSGPACK_ID])}
        (self.root/m.CONFIG).write_text(json.dumps(self.rule))
        self.findings.append({**copy.deepcopy(self.findings[0]),'id':m.MSGPACK_ID,'component':'msgpack','version':'1.1.2',
            'url':'https://github.com/advisories/'+m.MSGPACK_ID,
            'environmentObservations':[{'environment':'local','origin':o,'versions':['1.1.2']} for o in sorted(m.ORIGINS)]})
        self.report['findings']=copy.deepcopy(self.findings)
    def classify(self,report=None):
        report=self.report if report is None else report
        with patch.object(m,'verify_environments',return_value=copy.deepcopy(self.proof)):
            m.classify(report,self.root,self.fetch)
        return report

    def test_exact_three_are_separated_without_erasing_raw_matches_or_changing_severity(self):
        other={**self.findings[0],'id':'GHSA-unreviewed','component':'other'}
        self.report['findings'].append(other);original=copy.deepcopy(self.report['findings']);self.classify()
        self.assertEqual(self.report['rawFindings'],original);self.assertEqual(self.report['findings'],[other])
        self.assertEqual(len(self.report['applicabilityReviews']),3)
        self.assertTrue(all(r['grantsRiskException'] is False and r['finding']['severity']=='high' for r in self.report['applicabilityReviews']))
        m.validate_envelope(self.report)

    def test_coverage_keeps_raw_matches_and_never_clears_missing_provider_proof(self):
        rows=[{'id':f['id'],'component':'setuptools','ecosystem':'PyPI','versions':['70.3.0'],
               'origins':sorted(m.ORIGINS),'status':'needs-review','severity':'high'} for f in self.findings]
        self.report['toolchainCoverage']={'findings':rows,'checksComplete':False,'blocking':True}
        self.classify()
        coverage=self.report['toolchainCoverage']
        self.assertEqual(coverage['rawFindings'],rows);self.assertEqual(coverage['findings'],[])
        self.assertTrue(coverage['blocking']);self.assertFalse(coverage['checksComplete'])

    def test_advisory_change_withdrawal_or_lookup_failure_retains_original_risk(self):
        for changed in ({'description':'new condition'},{'vulnerabilities':[]},{'withdrawn_at':'2026-01-01T00:00:00Z'}):
            report={'findings':[copy.deepcopy(self.findings[0])],'observedEnvironment':'local'}
            with patch.object(m,'verify_environments',return_value=self.proof):
                m.classify(report,self.root,lambda _: {**self.fetch('advisories/'+self.findings[0]['id']),**changed})
            self.assertEqual(len(report['findings']),1);self.assertEqual(report['applicabilityReviews'],[])
        with patch.object(m,'verify_environments',return_value=self.proof):
            m.classify(self.report,self.root,lambda _: (_ for _ in ()).throw(OSError('offline')))
        self.assertEqual(self.report['findings'],self.findings)

    def test_other_version_origin_scope_or_environment_cannot_borrow_the_decision(self):
        for change in ({'version':'70.3.1'},{'scope':'development'},{'queryComplete':False},
                       {'dependencyPaths':['external/setuptools']},
                       {'environmentObservations':[{'environment':'ci','origin':o,'versions':['70.3.0']} for o in sorted(m.ORIGINS)]}):
            report={'findings':[{**self.findings[0],**change}],'observedEnvironment':'local'}
            self.classify(report);self.assertEqual(len(report['findings']),1)
        with patch.dict(m.os.environ,{'GITHUB_ACTIONS':'true'}):self.classify()
        self.assertEqual(self.report['findings'],self.findings)

    def test_failed_source_proof_is_not_an_exception(self):
        with patch.object(m,'verify_environments',side_effect=ValueError('wheel/source changed')):
            m.classify(self.report,self.root,self.fetch)
        self.assertEqual(self.report['findings'],self.findings);self.assertEqual(self.report['applicabilityReviews'],[])

    def test_environment_wrapper_roles_and_official_archive_are_both_checked(self):
        files={'pip/_vendor/pkg_resources/__init__.py':b'inert source','pip/_vendor/vendor.txt':b'setuptools==70.3.0'}
        cache=self.root/'.build/python-bootstrap';cache.mkdir(parents=True);archive=cache/'fixture.whl'
        with zipfile.ZipFile(archive,'w') as z:
            for name,body in files.items():z.writestr(name,body)
        wheel_sha=hashlib.sha256(archive.read_bytes()).hexdigest()
        rule={**self.rule,'wheelSHA256':wheel_sha,'vendorManifestSHA256':m.vendor_manifest(files)}
        pip={'version':'26.2.2','sha256':wheel_sha,'url':'https://example.invalid/fixture.whl'}
        calls=[]
        def inspect(python,root):return {'purelib':str(python.parents[1]/'lib/site-packages')}
        def validate(info,policy,root,role):
            expected='project-runtime' if '/python-runtime/' in info['purelib'] else 'security-tools'
            if role!=expected:raise ValueError('Wrong trust role')
            calls.append(role)
        def wheel(path,*args):
            if hashlib.sha256(path.read_bytes()).hexdigest()!=wheel_sha:raise ValueError('Changed wheel')
        trust=SimpleNamespace(configuration=lambda root:{'packages':{'pip':pip}},verify_wheel=wheel,
                              inspect_environment=inspect,validate_current=validate)
        for role in m.ROLES:
            target=self.root/'.build'/role;target.mkdir()
            (target/'pyvenv.cfg').write_text('include-system-site-packages = false\n')
            for name,body in files.items():
                path=target/'lib/site-packages'/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(body)
        spec=SimpleNamespace(loader=SimpleNamespace(exec_module=lambda _:None))
        with patch.object(m.importlib.util,'spec_from_file_location',return_value=spec), \
                patch.object(m.importlib.util,'module_from_spec',return_value=trust):
            proof=m.verify_environments(self.root,rule)
            self.assertEqual(calls,['project-runtime','security-tools']);self.assertEqual(len(proof['environments']),2)
            (self.root/'.build/security-tools/pyvenv.cfg').write_text('include-system-site-packages = true\n')
            with self.assertRaises(ValueError):m.verify_environments(self.root,rule)
            archive.write_bytes(b'changed')
            with self.assertRaises(ValueError):m.verify_environments(self.root,rule)

    def test_revalidation_rejects_tampering_and_changed_current_evidence(self):
        self.classify()
        with patch.object(m,'verify_environments',return_value=self.proof):m.revalidate(self.report,self.root,self.fetch)
        with patch.object(m,'verify_environments',side_effect=ValueError('source drift')),self.assertRaises(ValueError):
            m.revalidate(self.report,self.root,self.fetch)
        altered=copy.deepcopy(self.report);altered['applicabilityReviews'][0]['evidence']={}
        with patch.object(m,'verify_environments',return_value=self.proof),self.assertRaises(ValueError):
            m.revalidate(altered,self.root,self.fetch)
        altered=copy.deepcopy(self.report);altered['rawFindings'].pop()
        with self.assertRaises(ValueError):m.validate_envelope(altered)

    def test_absence_alone_does_not_verify_an_installation(self):
        site=self.root/'site';site.mkdir();vendor=site/'pip/_vendor';vendor.mkdir(parents=True)
        files={'pip/_vendor/pkg_resources/__init__.py':b'inert source', 'pip/_vendor/vendor.txt':b'setuptools==70.3.0'}
        def restore():
            for name,body in files.items():
                p=site/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(body)
        with self.assertRaises(ValueError):m.verify_installed(site,files)
        restore();m.verify_installed(site,files)
        source=site/'pip/_vendor/pkg_resources/__init__.py';source.write_bytes(b'changed')
        with self.assertRaises(ValueError):m.verify_installed(site,files)
        restore()
        for path in (site/'setuptools.py',site/'fixture.pth',vendor/'setuptools/package_index.py',vendor/'unexpected.py'):
            path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(b'inert fixture')
            with self.assertRaises(ValueError):m.verify_installed(site,files)
            path.unlink()
            if path.parent.name=='setuptools':path.parent.rmdir()
        source.unlink();source.symlink_to(self.root/'missing')
        with self.assertRaises(ValueError):m.verify_installed(site,files)

    def test_gate_revalidates_instead_of_trusting_not_affected_text(self):
        audit=load('security-audit');self.classify()
        with patch.object(audit,'ROOT',self.root),patch.object(audit,'pip_applicability',return_value=m), \
                patch.object(audit,'gh',side_effect=self.fetch),patch.object(m,'verify_environments',return_value=self.proof):
            self.assertFalse(audit.blocking(self.report))
            self.report['applicabilityReviews'][0]['evidence']={}
            self.assertTrue(audit.blocking(self.report))
        report={'errors':[],'findings':[dict(self.findings[0],impact={'status':'not-affected'})]}
        self.assertTrue(audit.blocking(report))

    def test_complete_issue_scan_does_not_close_prior_risk_as_a_version_fix(self):
        from test_security_issues import FakeGitHub,ENV,report
        sync=load('sync-security-issues');api=FakeGitHub();original=report(False)
        original.update(findings=copy.deepcopy(self.findings),observedEnvironment='local')
        sync.synchronize(original,api,True,ENV)
        self.classify();self.report.update({k:v for k,v in original.items() if k not in ('findings','observedEnvironment')})
        actions=sync.synchronize(self.report,api,True,ENV)
        self.assertTrue(all(i['state']=='open' for i in api.issues));self.assertTrue(all(a['action']=='preserve' for a in actions))

    def test_msgpack_exact_four_preserve_raw_and_do_not_exclude_other_components(self):
        self.add_msgpack()
        rows=[{'id':f['id'],'component':f['component'],'ecosystem':'PyPI','versions':[f['version']],
               'origins':sorted(m.ORIGINS),'status':'needs-review','severity':'high'} for f in self.findings]
        unrelated={**rows[-1],'component':'another-package'}
        self.report['toolchainCoverage']={'findings':rows+[unrelated],'checksComplete':False}
        self.classify();self.assertEqual(len(self.report['rawFindings']),4)
        self.assertEqual(self.report['findings'],[]);self.assertEqual(len(self.report['applicabilityReviews']),4)
        self.assertEqual(self.report['toolchainCoverage']['findings'],[unrelated])
        self.assertTrue(self.report['toolchainCoverage']['blocking']);m.validate_envelope(self.report)

    def test_msgpack_is_not_authorized_by_the_old_setuptools_rule(self):
        self.add_msgpack();self.rule.pop('msgpack');(self.root/m.CONFIG).write_text(json.dumps(self.rule))
        self.classify();self.assertEqual(self.report['findings'],[self.findings[-1]])

    def test_msgpack_patch_or_advisory_drift_retains_only_its_original_match(self):
        self.add_msgpack()
        for change in ('patch','advisory','withdrawn','query-failure'):
            report={'findings':copy.deepcopy(self.findings),'observedEnvironment':'local'}
            def fetch(path):
                value=self.fetch(path)
                if change=='patch' and path.startswith('repos/'):
                    value['files'][0]['sha']='d'*40
                if path.endswith(m.MSGPACK_ID):
                    if change=='advisory':value['description']='new condition'
                    if change=='withdrawn':value['withdrawn_at']='2026-01-01T00:00:00Z'
                if change=='query-failure' and path.startswith('repos/'):raise OSError('offline')
                return value
            with patch.object(m,'verify_environments',return_value=self.proof):m.classify(report,self.root,fetch)
            self.assertEqual(report['findings'],[self.findings[-1]])

    def test_msgpack_missing_fallback_or_native_decoder_cannot_use_subset_proof(self):
        files={'pip/_vendor/msgpack/'+name:b'inert fixture' for name in m.MSGPACK_FILES}
        m.verify_msgpack_subset(files)
        for name in ('_cmsgpack.so','_cmsgpack.py','_unpacker.pyx','nested/unknown.py'):
            with self.subTest(name=name),self.assertRaises(ValueError):
                m.verify_msgpack_subset({**files,'pip/_vendor/msgpack/'+name:b'inert fixture'})
        missing=dict(files);missing.pop('pip/_vendor/msgpack/fallback.py')
        with self.assertRaises(ValueError):m.verify_msgpack_subset(missing)
        site=self.root/'site';site.mkdir()
        for name,body in files.items():
            p=site/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(body)
        m.verify_installed(site,files)
        (site/'pip/_vendor/msgpack/fallback.py').write_bytes(b'changed')
        with self.assertRaises(ValueError):m.verify_installed(site,files)

    def test_msgpack_other_version_origin_or_component_cannot_borrow_decision(self):
        self.add_msgpack()
        for change in ({'version':'1.2.0'},{'component':'setuptools'},
                       {'dependencyPaths':['python-runtime/installed/msgpack']},
                       {'environmentObservations':[{'environment':'ci','origin':o,'versions':['1.1.2']} for o in sorted(m.ORIGINS)]}):
            report={'findings':[{**self.findings[-1],**change}],'observedEnvironment':'local'}
            self.classify(report);self.assertEqual(len(report['findings']),1)

    def test_msgpack_revalidation_and_issue_retention(self):
        self.add_msgpack();self.test_complete_issue_scan_does_not_close_prior_risk_as_a_version_fix()
        with patch.object(m,'verify_environments',return_value=self.proof):m.revalidate(self.report,self.root,self.fetch)
        self.msgpack_patch['files'].pop()
        with patch.object(m,'verify_environments',return_value=self.proof),self.assertRaises(ValueError):
            m.revalidate(self.report,self.root,self.fetch)

    def test_msgpack_changed_rule_or_patch_schema_is_rejected(self):
        self.add_msgpack()
        for change in ({'state':'pending'},{'id':'GHSA-other'},{'componentVersion':'1.2.0'},{'patchCommit':'a'*40}):
            rule={**self.rule,'msgpack':{**self.rule['msgpack'],**change}}
            (self.root/m.CONFIG).write_text(json.dumps(rule))
            with self.subTest(change=change),self.assertRaises(ValueError):m.configuration(self.root)
        duplicate=copy.deepcopy(self.msgpack_patch);duplicate['files'].append(duplicate['files'][0])
        with self.assertRaises(ValueError):m.msgpack_patch_digest(duplicate)


if __name__=='__main__':unittest.main()
