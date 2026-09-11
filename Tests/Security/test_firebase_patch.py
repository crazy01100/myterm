import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('firebase_patch', ROOT/'scripts/patch-firebase-stream-json.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)

class FirebasePatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name, version in [('firebase-tools','15.30.0'),('stream-json','3.6.0')]:
            folder = self.root/'node_modules'/name
            folder.mkdir(parents=True)
            (folder/'package.json').write_text(json.dumps({'version':version}))
        self.patches = {}
        self.files = []
        for name in ['first.js','second.js']:
            file = self.root/'node_modules/firebase-tools'/name
            file.write_text('old API\n'); self.files.append(file)
            self.patches[name] = {'before':p.digest(b'old API\n'),'after':p.digest(b'new API\n'),'replacements':{'old API':'new API'}}

    def run_patch(self, check=False):
        return p.apply(self.root, check, self.patches)

    def test_clean_install_and_idempotent_recheck(self):
        with self.assertRaises(ValueError):self.run_patch(check=True)
        self.assertEqual(self.run_patch(),2)
        self.assertEqual(self.run_patch(),0)
        self.assertEqual(self.run_patch(check=True),0)

    def test_drift_rejected_before_any_writes(self):
        self.files[1].write_text('unexpected upstream content')
        with self.assertRaises(ValueError):self.run_patch()
        self.assertEqual(self.files[0].read_text(),'old API\n')

    def test_version_drift_rejected(self):
        (self.root/'node_modules/firebase-tools/package.json').write_text('{"version":"99.0.0"}')
        with self.assertRaises(ValueError):self.run_patch()
        self.assertEqual(self.files[0].read_text(),'old API\n')

    def test_modified_patch_and_wrong_output_rejected(self):
        self.run_patch(); self.files[0].write_text('new API\nextra')
        with self.assertRaises(ValueError):self.run_patch(check=True)
        self.files[0].write_text('old API\n')
        self.patches['first.js']['after']=hashlib.sha256(b'wrong').hexdigest()
        with self.assertRaises(ValueError):self.run_patch()
        self.assertEqual(self.files[0].read_text(),'old API\n')

    def test_interrupted_install_resumes_only_reviewed_files(self):
        self.files[0].write_text('new API\n')
        self.assertEqual(self.run_patch(),1)
        self.assertEqual(self.run_patch(check=True),0)

if __name__ == '__main__':unittest.main()
