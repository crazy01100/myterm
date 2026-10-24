"""Metadata/ordering fixtures only; no compromised certificates or attack inputs."""
import copy
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
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/f'{name}.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
p=load('python-toolchain')
a=load('security-audit')

class PythonToolchainTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.policy=p.configuration()
        path=self.root/p.CONFIG;path.parent.mkdir(parents=True);path.write_text(json.dumps(self.policy))

    def info(self,role='project-runtime'):
        prefix=self.root/p.ROLES[role]
        ca=str(prefix/'lib/certifi/cacert.pem')
        return {'python':'3.12.14','prefix':str(prefix),'basePrefix':'/fixture/shared',
                'purelib':str(prefix/'lib'),'packages':[
                    {'name':'pip','origin':'pip','version':'26.2.2'},
                    {'name':'certifi','origin':'certifi','version':'2026.10.19','caPath':ca,'caSHA256':self.policy['caSHA256']},
                    {'name':'certifi','origin':'pip/_vendor/certifi','version':'2026.10.19','caPath':ca,'caSHA256':self.policy['caSHA256']}]}

    def test_owned_venv_and_both_ca_copies_required(self):
        info=self.info();self.assertTrue(p.validate_current(info,self.policy,self.root))
        for index in (1,2):
            changed=copy.deepcopy(info);changed['packages'][index]['caSHA256']='0'*64
            with self.assertRaises(ValueError):p.validate_current(changed,self.policy,self.root)
        for origin in ['pip','certifi','pip/_vendor/certifi']:
            changed=copy.deepcopy(info);changed['packages']=[r for r in changed['packages'] if r['origin']!=origin]
            with self.assertRaises(ValueError):p.validate_current(changed,self.policy,self.root)

    def test_shared_interpreter_external_sites_and_role_mismatch_rejected(self):
        for change in [{'basePrefix':self.info()['prefix']},{'purelib':'/fixture/shared/lib'}, {'prefix':'/fixture/shared'}]:
            with self.subTest(change=change),self.assertRaises(ValueError):
                p.validate_current({**self.info(),**change},self.policy,self.root)
        with self.assertRaises(ValueError):p.validate_current(self.info(),self.policy,self.root,'security-tools')

    def test_path_escape_and_symlink_preserved(self):
        (self.root/'.build').mkdir();target=self.root/'.build/escape';target.symlink_to('/tmp')
        with self.assertRaises(ValueError):p.owned_path(target,self.root)
        with self.assertRaises(ValueError):p.owned_path(self.root/'.build/../outside',self.root)

    def test_bad_hash_metadata_or_ca_never_becomes_installable(self):
        wheel=self.root/'fixture.whl';ca=b'ordinary metadata fixture'
        with zipfile.ZipFile(wheel,'w') as z:
            z.writestr('certifi-2026.10.19.dist-info/METADATA','Name: certifi\nVersion: 2026.10.19\n')
            z.writestr('certifi/cacert.pem',ca)
        row={'version':'2026.10.19','sha256':p.sha(wheel)};policy={'caSHA256':hashlib.sha256(ca).hexdigest()}
        p.verify_wheel(wheel,'certifi',row,policy)
        with self.assertRaises(ValueError):p.verify_wheel(wheel,'certifi',{**row,'sha256':'0'*64},policy)
        with self.assertRaises(ValueError):p.verify_wheel(wheel,'certifi',row,{'caSHA256':'0'*64})

    def test_download_failure_precedes_any_environment_change(self):
        with patch.object(p,'prepare',side_effect=ValueError('hash mismatch')),patch.object(p.subprocess,'run') as run:
            with self.assertRaises(ValueError):p.setup(self.root,rebuild=True)
        run.assert_not_called();self.assertFalse((self.root/'.build/python-runtime').exists())

    def test_clean_environment_does_not_inherit_index_or_ca_overrides(self):
        with patch.dict('os.environ',{'PIP_INDEX_URL':'private fixture','SSL_CERT_FILE':'wrong','PYTHONPATH':'wrong','PATH':'/usr/bin'},clear=True):
            env=p.clean_environment()
        self.assertNotIn('PIP_INDEX_URL',env);self.assertNotIn('SSL_CERT_FILE',env);self.assertNotIn('PYTHONPATH',env)
        self.assertEqual(env['PATH'],'/usr/bin')

    def test_security_floor_and_artifact_identity(self):
        for name,value in [('url','http://example.invalid/pip.whl'),('sha256','bad'),('version','25.0.1')]:
            changed=copy.deepcopy(self.policy);changed['packages']['pip'][name]=value
            (self.root/p.CONFIG).write_text(json.dumps(changed))
            with self.assertRaises(ValueError):p.configuration(self.root)

    def test_installs_only_offline_wheels_and_failure_stops_before_next_role(self):
        import subprocess
        for relative in p.ROLES.values():
            target=self.root/relative;(target/'bin').mkdir(parents=True)
            (target/'pyvenv.cfg').write_text('fixture');(target/'bin/python3').write_text('fixture')
        wheels=[self.root/'pip.whl',self.root/'certifi.whl']
        sequence=[]
        for role in p.ROLES:sequence.extend([self.info(role),self.info(role)])
        with patch.object(p,'prepare',return_value=wheels),patch.object(p,'inspect_environment',side_effect=sequence),patch.object(p.subprocess,'run') as run:
            p.setup(self.root)
        self.assertEqual(run.call_count,2)
        for call in run.call_args_list:
            args=call.args[0];self.assertIn('--no-index',args);self.assertIn('--no-deps',args)
            self.assertIn('--isolated',args);self.assertEqual(args[-2:],list(map(str,wheels)))
        with patch.object(p,'prepare',return_value=wheels),patch.object(p,'inspect_environment',return_value=self.info()) as inspect,patch.object(p.subprocess,'run',side_effect=subprocess.CalledProcessError(1,'fixture')),patch.object(p,'validate_current') as validate:
            with self.assertRaises(subprocess.CalledProcessError):p.setup(self.root)
        self.assertEqual(inspect.call_count,1);validate.assert_not_called()

    def test_https_context_uses_explicit_reviewed_bundle(self):
        with patch.object(p,'ca_path',return_value='/fixture/reviewed.pem'),patch.object(p.ssl,'create_default_context') as create:
            p.https_context(self.root)
        create.assert_called_once_with(cafile='/fixture/reviewed.pem')

class PythonInventoryAuditTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
        (self.root/'Tests/Security').mkdir(parents=True);(self.root/'Tests/Security/requirements.txt').write_text('cryptography==50.0.2\n')
        self.policy=p.configuration();self.environments=[]
        for role in p.ROLES:
            self.environments.append({'role':role,'packages':[
                {'name':'pip','version':'25.0.1','origin':'pip'},
                {'name':'certifi','version':'2026.10.19','origin':'certifi','caSHA256':self.policy['caSHA256']},
                {'name':'certifi','version':'2024.08.30','origin':'pip/_vendor/certifi','caSHA256':'old fixture'}]})

    def scan(self,fetch):
        report={'errors':[],'findings':[]}
        with patch.object(a,'ROOT',self.root),patch.object(a.python_tools,'configuration',return_value=self.policy),patch.object(a.python_tools,'inventory',return_value=self.environments),patch.object(a,'get_json',side_effect=fetch):
            a.scan_verifier(report)
        return report

    def test_vendored_copy_detected_even_when_standalone_is_fixed_and_aliases_merge(self):
        calls=[]
        def fetch(url,payload):
            calls.append(payload)
            if payload['package']['name']=='certifi' and payload['version']=='2024.8.30':
                return {'vulns':[{'id':'PYSEC-fixture','aliases':['GHSA-fixture'],'database_specific':{'severity':'CRITICAL'},
                    'affected':[{'package':{'name':'certifi'},'ranges':[{'events':[{'introduced':'0'},{'fixed':'2026.10.19'}]}]}]},
                    {'id':'GHSA-fixture','database_specific':{'severity':'CRITICAL'}}]}
            return {'vulns':[]}
        report=self.scan(fetch);self.assertEqual(len(report['findings']),1)
        f=report['findings'][0];self.assertEqual(f['id'],'GHSA-fixture');self.assertEqual(f['severity'],'critical')
        self.assertEqual(len(f['dependencyPaths']),2);self.assertEqual(f['fixedVersion'],'2026.10.19');self.assertTrue(a.blocking(report))
        self.assertTrue(any(x['version']=='26.2.2' for x in calls))
        self.assertNotIn(str(self.root),json.dumps(report))

    def test_missing_env_current_ca_tamper_and_query_failure_do_not_pass(self):
        self.environments[0]['packages'][1]['caSHA256']='changed'
        with self.assertRaises(ValueError):self.scan(lambda *args:{'vulns':[]})
        self.environments[0]['packages'][1]['caSHA256']=self.policy['caSHA256']
        with self.assertRaises(OSError):self.scan(lambda *args:(_ for _ in ()).throw(OSError('offline')))
        self.environments[0]['packages'].pop()
        with self.assertRaises(ValueError):self.scan(lambda *args:{'vulns':[]})

if __name__=='__main__':unittest.main()
