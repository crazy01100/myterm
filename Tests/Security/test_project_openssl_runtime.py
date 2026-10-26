"""Project CI isolation fixtures: hashes, launch ordering and process maps, no attacks."""
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]

def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT/'scripts'/f'{name}.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module

r = load('project-openssl-runtime')
s = load('security-openssl-supplier')

class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.p = copy.deepcopy(s.configuration(ROOT)['packages'][0])
        self.files = {'libssl.so.3': b'ordinary fixture ssl', 'libcrypto.so.3': b'ordinary fixture crypto'}
        self.p['libraries'] = {key: hashlib.sha256(self.files[Path(key).name]).hexdigest() for key in self.p['libraries']}
        (self.root/'Config/Security').mkdir(parents=True)
        (self.root/r.CHECKSUMS).write_text(''.join(self.p['libraries'][key]+'  '+Path(key).name+'\n' for key in sorted(self.p['libraries'])))
        (self.root/r.CONFIG).write_text(json.dumps({'schemaVersion': 1, 'grantsRiskException': False, 'packages': [self.p]}))
        (self.root/'scripts').mkdir()
        shutil.copy2(ROOT/'scripts/python-openssl-env.sh', self.root/'scripts/python-openssl-env.sh')
        lib = self.root/r.RELATIVE/'lib'; lib.mkdir(parents=True)
        for name, data in self.files.items(): (lib/name).write_bytes(data)

    def shell_check(self, **changes):
        env = {k: v for k, v in os.environ.items() if k not in ('MYTERM_CI_OPENSSL','LD_LIBRARY_PATH','LD_PRELOAD','LD_AUDIT','OPENSSL_CONF','OPENSSL_MODULES')}
        env.update(changes)
        return subprocess.run(['/bin/bash', '-c', 'set -e; project_dir="$1"; source "$project_dir/scripts/python-openssl-env.sh"; myterm_verify_python_openssl; printf "%s" "$LD_LIBRARY_PATH"', 'fixture', str(self.root)],
                              env=env, text=True, capture_output=True, timeout=10)

    def test_prelaunch_checks_and_python_verifier_share_exact_manifest(self):
        self.assertEqual(r.verify(self.root, self.p)['status'], 'verified')
        result = self.shell_check(); self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, str(self.root/r.RELATIVE/'lib'))
        self.assertNotIn(str(self.root), os.environ.get('LD_LIBRARY_PATH', ''))

    def test_loader_path_is_scoped_and_not_duplicated_for_child_launchers(self):
        lib = str(self.root/r.RELATIVE/'lib')
        for before in ('/fixture/python/lib', lib+':/fixture/python/lib'):
            result = self.shell_check(LD_LIBRARY_PATH=before)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, lib+':/fixture/python/lib')

    def test_drift_links_and_additional_loader_targets_fail_before_execution(self):
        lib = self.root/r.RELATIVE/'lib'; target = lib/'libssl.so.3'
        for action in ('changed', 'link', 'extra'):
            with self.subTest(action=action):
                if action == 'changed': target.write_bytes(b'drift')
                elif action == 'link': target.unlink(); target.symlink_to(lib/'libcrypto.so.3')
                else: (lib/'libpython.so').write_bytes(b'additional')
                self.assertNotEqual(self.shell_check().returncode, 0)
                with self.assertRaises(ValueError): r.verify(self.root, self.p)
                if action == 'link': target.unlink()
                target.write_bytes(self.files['libssl.so.3'])
                (lib/'libpython.so').unlink(missing_ok=True)

    def test_custom_loader_and_provider_overrides_are_not_silently_inherited(self):
        for name in ('OPENSSL_CONF','OPENSSL_MODULES'):
            with self.subTest(name=name): self.assertNotEqual(self.shell_check(**{name:'/fixture/unreviewed'}).returncode,0)

    def test_manifest_must_match_official_package_even_if_files_match_manifest(self):
        (self.root/r.CHECKSUMS).write_text('0'*64+'  libssl.so.3\n')
        with self.assertRaises(ValueError): r.verify(self.root, self.p)
        self.assertNotEqual(self.shell_check().returncode, 0)

    def archive(self, duplicate=False, link=False):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode='w') as archive:
            for key in self.p['libraries']:
                data = self.files[Path(key).name]; info = tarfile.TarInfo('.'+key); info.size = len(data)
                if link: info.type=tarfile.SYMTYPE; info.linkname='/outside'; info.size=0
                archive.addfile(info, io.BytesIO(data))
                if duplicate: archive.addfile(info, io.BytesIO(data))
        return output.getvalue()

    def test_archive_reads_only_hash_bound_regular_library_members(self):
        self.assertEqual(r.library_bytes(self.archive(), self.p), self.files)
        for raw in (self.archive(duplicate=True), self.archive(link=True)):
            with self.assertRaises(ValueError): r.library_bytes(raw, self.p)
        wrong=copy.deepcopy(self.p); wrong['libraries'][next(iter(wrong['libraries']))]='0'*64
        with self.assertRaises(ValueError): r.library_bytes(self.archive(),wrong)

    def test_setup_verifies_before_publishing_and_never_overwrites_drift(self):
        helper=load('security-openssl-supplier')
        with patch.object(r, 'supplier', return_value=helper), patch.object(r.platform,'system',return_value='Linux'), \
             patch.object(r.platform,'machine',return_value='x86_64'), patch.dict(os.environ,{'GITHUB_ACTIONS':'true'}):
            self.assertEqual(r.setup(self.root)['status'],'verified')
            (self.root/r.RELATIVE/'lib/libssl.so.3').write_bytes(b'bad')
            with self.assertRaises(ValueError): r.setup(self.root)
            shutil.rmtree(self.root/r.RELATIVE)
            cache=self.root/'.build/openssl-supplier'; cache.mkdir(); (cache/(self.p['sha256']+'.deb')).write_bytes(b'fixture')
            with patch.object(helper,'verify_package',side_effect=ValueError('invalid official hash')):
                with self.assertRaises(ValueError): r.setup(self.root)
            self.assertFalse((self.root/r.RELATIVE).exists())
            with patch.object(helper,'verify_package',return_value={}), patch.object(helper,'command',return_value=self.archive()):
                self.assertEqual(r.setup(self.root)['status'],'verified')

    def test_actual_process_maps_identify_project_copy_without_dpkg_claim(self):
        paths=r.paths(self.root,self.p)
        maps=[]
        for path in paths.values():
            st=path.stat(); maps.append(f'1000-2000 r-xp 0 {os.major(st.st_dev):02x}:{os.minor(st.st_dev):02x} {st.st_ino} {path}')
        original=Path.read_text
        def read(path,*args,**kwargs):
            return '\n'.join(maps) if str(path)=='/proc/self/maps' else original(path,*args,**kwargs)
        with patch.object(s,'ROOT',self.root),patch.object(s,'load',return_value=r),patch.object(s.sys,'platform','linux'), \
             patch.object(s.ssl,'OPENSSL_VERSION','OpenSSL 3.5.5 fixture'),patch.object(Path,'read_text',read), \
             patch.object(s,'command',side_effect=AssertionError('Must not claim system package ownership')):
            proof=s.probe()
        self.assertEqual(proof['installation'],'project-isolated-official-package')
        self.assertEqual(proof['libraries'],self.p['libraries'])
        self.assertEqual(proof['loadedPaths'],{k:str(v) for k,v in paths.items()})

    def test_missing_or_mixed_mappings_cannot_borrow_isolated_identity(self):
        paths=r.paths(self.root,self.p)
        mixed={str(next(iter(paths.values()))):'a'*64,'/usr/lib/x86_64-linux-gnu/libcrypto.so.3':'b'*64}
        with patch.object(s,'ROOT',self.root),patch.object(s,'load',return_value=r),patch.object(s.sys,'platform','linux'), \
             patch.object(s,'loaded_libraries',return_value=mixed),patch.object(Path,'read_text',autospec=True,side_effect=lambda p,*a,**k: '{}' if str(p)=='/proc/self/maps' else self.original_config(p)):
            with self.assertRaisesRegex(ValueError,'Mixed isolated'): s.probe()

    def original_config(self,path):
        return json.dumps({'schemaVersion':1,'grantsRiskException':False,'packages':[self.p]})

    def test_all_full_workflows_prepare_before_any_project_python_entry(self):
        for name in ('security-gate.yml','security-checks.yml','deploy-update-site.yml'):
            text=(ROOT/'.github/workflows'/name).read_text()
            self.assertIn('MYTERM_CI_OPENSSL: required',text)
            prepare=text.index('scripts/project-openssl-runtime.py setup')
            self.assertLess(prepare,text.index('./scripts/project-python.sh'))
            self.assertLess(prepare,text.index('./scripts/setup-security-tools.sh'))
            self.assertNotIn('LD_LIBRARY_PATH',text)
        health=(ROOT/'.github/workflows/security-monitor-health.yml').read_text()
        self.assertNotIn('project-openssl-runtime',health)
        self.assertNotIn('MYTERM_CI_OPENSSL',health)

    def test_bootstrap_and_inventory_children_keep_selected_loader_environment(self):
        helper=load('python-toolchain')
        with patch.dict(os.environ,{'LD_LIBRARY_PATH':'/fixture/project/lib:/fixture/python/lib','MYTERM_CI_OPENSSL':'required'}):
            clean=helper.clean_environment()
        self.assertEqual(clean['LD_LIBRARY_PATH'],'/fixture/project/lib:/fixture/python/lib')
        self.assertEqual(clean['MYTERM_CI_OPENSSL'],'required')
        for file in ('project-python.sh','security-python.sh'):
            self.assertIn('source "$project_dir/scripts/python-openssl-env.sh"',(ROOT/'scripts'/file).read_text())

if __name__=='__main__': unittest.main()
