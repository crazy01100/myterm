"""Inert archive/manifest and subprocess fixtures; no vulnerability payloads."""
import base64
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]


def load(name):
    spec=importlib.util.spec_from_file_location(name, ROOT/'scripts'/f'{name}.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module


n=load('node-toolchain');w=load('python-verifier-wheels')


class OfficialNpmTests(unittest.TestCase):
    def archive(self):
        data=io.BytesIO()
        with tarfile.open(fileobj=data,mode='w:gz') as archive:
            for name,body in [('package.json',json.dumps({'name':'npm','version':'11.21.1'})),('bin/npm-cli.js','// inert fixture')]:
                raw=body.encode();item=tarfile.TarInfo('package/'+name);item.size=len(raw);item.mode=0o755 if name.startswith('bin/') else 0o644
                archive.addfile(item,io.BytesIO(raw))
        blob=data.getvalue();integrity='sha512-'+base64.b64encode(hashlib.sha512(blob).digest()).decode()
        return blob,{'version':'11.21.1','integrity':integrity,'url':'https://registry.npmjs.org/npm/-/npm-11.21.1.tgz'}

    def test_official_identity_hash_and_executable_permissions(self):
        blob,row=self.archive();files=n.archive_files(blob,row)
        self.assertEqual(files['bin/npm-cli.js'][1],0o755)
        with self.assertRaises(ValueError):n.archive_files(blob+b'changed',row)
        with self.assertRaises(ValueError):n.archive_files(blob,{**row,'version':'11.21.2'})

    def test_existing_tampered_install_is_not_silently_replaced(self):
        blob,row=self.archive()
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);cfg=root/n.CONFIG;cfg.parent.mkdir(parents=True)
            cfg.write_text(json.dumps({'schemaVersion':1,'nodeVersion':'24.22.1','npm':row}))
            cache=root/'.build/node-toolchain';cache.mkdir(parents=True);(cache/'npm-11.21.1.tgz').write_bytes(blob)
            cli=n.setup(root);self.assertEqual(cli,n.verify(root))
            cli.write_text('changed fixture')
            with self.assertRaises(ValueError):n.setup(root)
            self.assertEqual(cli.read_text(),'changed fixture')

    def test_unreviewed_download_host_or_major_version_rejected(self):
        _,row=self.archive()
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);cfg=root/n.CONFIG;cfg.parent.mkdir(parents=True)
            for change in ({'url':'https://example.invalid/npm.tgz'},{'version':'12.2.1'}):
                cfg.write_text(json.dumps({'schemaVersion':1,'nodeVersion':'24.22.1','npm':{**row,**change}}))
                with self.assertRaises(ValueError):n.policy(root)


class OfflineVerifierTests(unittest.TestCase):
    def test_unpinned_urls_build_flags_and_duplicate_dependencies_rejected(self):
        good='example==1.0.0 --hash=sha256:'+'a'*64
        self.assertEqual(w.requirements(good)['example']['version'],'1.0.0')
        for bad in ('example>=1','example @ https://example.invalid',good+' --extra-index-url https://example.invalid',good+'\n'+good):
            with self.subTest(bad=bad),self.assertRaises(ValueError):w.requirements(bad)

    def test_missing_platform_wheel_never_selects_source_or_online_fallback(self):
        rows=[{'name':'example','version':'1.0.0','filename':'example.whl'}]
        parser=lambda name:('example','1.0.0',None,{'foreign-platform'})
        with self.assertRaises(ValueError):w.select(rows,['current-platform'],parser)

    def test_verified_local_inputs_and_hashes_are_the_only_pip_install_source(self):
        with tempfile.TemporaryDirectory(prefix='wheel fixtures ') as directory:
            path=Path(directory)/'example.whl';path.write_bytes(b'inert wheel fixture')
            row={'sha256':hashlib.sha256(path.read_bytes()).hexdigest()}
            w.verify(path,row)
            calls=[]
            def run(args,**kwargs):
                calls.append(args)
                if 'install' in args:
                    requirement=Path(args[args.index('-r')+1]).read_text()
                    self.assertIn(path.resolve().as_uri(),requirement);self.assertIn(row['sha256'],requirement)
                    self.assertNotIn('https:',requirement)
            with patch.object(w.subprocess,'run',side_effect=run):w.install('/fixture/python',[path],[row],{})
            self.assertIn('--no-index',calls[0]);self.assertIn('--no-deps',calls[0]);self.assertIn('--require-hashes',calls[0])
            self.assertIn('--no-build-isolation',calls[0]);self.assertEqual(calls[1][-1],'check')
            with self.assertRaises(ValueError):w.verify(path,{'sha256':'0'*64})

    def test_checked_in_wheel_manifest_matches_existing_requirements(self):
        wheels=w.configuration(ROOT)
        self.assertEqual({r['name'] for r in wheels},{'cryptography','cffi','pycparser','typing-extensions'})


if __name__=='__main__':unittest.main()
