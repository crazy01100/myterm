#!/usr/bin/env python3
"""Private regression tests for the public-source boundary; never exported."""
import importlib.util
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import os

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('public_export', ROOT/'scripts/export-public-source.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)/'private'
        self.root.mkdir()
        self.out = Path(self.temp.name)/'public'
        self.manifest = self.root/'manifest.json'
        (self.root/'README.md').write_text('Public content\n')

    def export(self, files):
        self.manifest.write_text(json.dumps({'schemaVersion':1,'files':files}))
        return module.export(self.root,self.manifest,self.out)

    def test_only_explicit_files_no_history_or_local_data(self):
        (self.root/'.git').mkdir()
        (self.root/'.git/config').write_text('private remote')
        (self.root/'secret.txt').write_text('not approved')
        self.export([{'path':'README.md'}])
        self.assertEqual([p.name for p in self.out.iterdir()],['README.md'])

    def test_rejects_private_paths(self):
        for name in ['.git/config','Config/Local/session.json','Config/Release/SparklePublicKey.txt',
                     'docs/plan.md','AGENTS.md','.DS_Store','build/archive.zip','update-site/appcast.xml',
                     '../escape','/absolute']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.export([{'path':name}])
        self.assertFalse(self.out.exists())

    def test_overlay_drift_fails_before_output(self):
        (self.root/'overlay.md').write_text('reviewed translation')
        digest=hashlib.sha256((self.root/'README.md').read_bytes()).hexdigest()
        (self.root/'README.md').write_text('new unreviewed instructions')
        with self.assertRaisesRegex(ValueError,'re-review'):
            self.export([{'path':'README.md','overlay':'overlay.md','baseSHA256':digest}])
        self.assertFalse(self.out.exists())

    def test_markers_and_credentials_fail_even_in_binary(self):
        for content in [b'\0'+module.PRIVATE_MARKERS[0],b'ghp_'+b'A'*36]:
            (self.root/'README.md').write_bytes(content)
            with self.assertRaises(ValueError): self.export([{'path':'README.md'}])
        self.assertFalse(self.out.exists())

    def test_symlink_escape_and_output_overwrite_rejected(self):
        (self.root/'link.md').symlink_to(self.root/'README.md')
        with self.assertRaisesRegex(ValueError,'Symlink'):
            self.export([{'path':'link.md'}])
        self.out.mkdir(); (self.out/'keep').write_text('existing work')
        with self.assertRaisesRegex(ValueError,'exists'):
            self.export([{'path':'README.md'}])
        self.assertEqual((self.out/'keep').read_text(),'existing work')

    def test_duplicate_and_bad_schema_rejected(self):
        with self.assertRaisesRegex(ValueError,'Duplicate'):
            self.export([{'path':'README.md'},{'path':'README.md'}])
        self.manifest.write_text('{"schemaVersion":2,"files":[]}')
        with self.assertRaisesRegex(ValueError,'Unsupported'):
            module.export(self.root,self.manifest,self.out)


class ConfigurationTests(unittest.TestCase):
    def test_update_base_has_no_default_and_rejects_unsafe_forms(self):
        script=ROOT/'PublicSource/overrides/scripts/update-source-config.sh'
        env={k:v for k,v in os.environ.items() if not k.startswith('MYTERM_')}
        for value,valid in [('',False),('http://updates.example.org',False),
                            ('https://user:pass@updates.example.org',False),
                            ('https://@updates.example.org',False),
                            ('https://updates.example.org:invalid',False),
                            ('https://updates.example.org/?token=x',False),
                            ('https://updates.example.org/#fragment',False),
                            ('https://updates.example.org/path/',True)]:
            with self.subTest(value=value):
                result=subprocess.run(['sh','-c','. "$1"; validate_update_source','test',str(script)],
                    env={**env,'MYTERM_UPDATE_BASE_URL':value,'project_dir':str(ROOT),'MYTERM_PYTHON':sys.executable},capture_output=True)
                self.assertEqual(result.returncode==0,valid)


if __name__=='__main__': unittest.main()
