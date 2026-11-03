import base64
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('update_lab_key', ROOT / 'scripts/update-lab-key.py')
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)


class UpdateLabKeyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        lab.prepare(self.root)
        self.public = self.root / 'test-public-key.txt'
        self.app = self.root / 'MyTerm.app'
        self.resources = self.app / 'Contents/Resources'
        self.resources.mkdir(parents=True)
        self.info = {
            'CFBundleIdentifier': 'tw.local.MySSHClient.UpdateLab',
            'MyTermApplicationSupportDirectory': 'MyTerm Update Lab',
            'MyTermLocalSecretVaultKeychainService': 'tw.local.MySSHClient.UpdateLab.local-secret-vault-root',
            'MyTermUpdateLabMode': True,
            'SUPublicEDKey': self.public.read_text(),
        }
        self.write()

    def write(self):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))

    def test_key_pair_and_private_file_permissions(self):
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
        private_file = self.root / 'test-private-key.txt'
        self.assertEqual(private_file.stat().st_mode & 0o777, 0o600)
        key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(private_file.read_bytes()))
        public = Ed25519PublicKey.from_public_bytes(base64.b64decode(self.public.read_bytes()))
        public.verify(key.sign(b'update lab fixture'), b'update lab fixture')
        lab.verify(self.app, self.public)
        with self.assertRaises(FileExistsError):
            lab.prepare(self.root)
        lab.verify(self.app, self.public)

    def test_production_development_or_incomplete_identity_rejected(self):
        for field, wrong in [
            ('CFBundleIdentifier', 'tw.local.MySSHClient'),
            ('CFBundleIdentifier', 'tw.local.MySSHClient.Development'),
            ('MyTermUpdateLabMode', False),
            ('MyTermUpdateLabMode', 1),
            ('MyTermApplicationSupportDirectory', 'MyTerm'),
            ('MyTermLocalSecretVaultKeychainService', 'production'),
        ]:
            with self.subTest(field=field, value=wrong):
                good = self.info[field]
                self.info[field] = wrong
                self.write()
                with self.assertRaises(ValueError):
                    lab.verify(self.app, self.public)
                self.info[field] = good

    def test_wrong_key_or_cloud_configuration_rejected(self):
        self.info['SUPublicEDKey'] = base64.b64encode(bytes(32)).decode()
        self.write()
        with self.assertRaises(ValueError):
            lab.verify(self.app, self.public)
        self.info['SUPublicEDKey'] = self.public.read_text()
        self.write()
        for name in ('MyTermCloudConfig.plist', 'GoogleService-Info.plist'):
            file = self.resources / name
            file.write_bytes(b'fixture')
            with self.assertRaises(ValueError):
                lab.verify(self.app, self.public)
            file.unlink()

    def test_explicit_flag_propagates_to_both_package_checks(self):
        verify = (ROOT / 'scripts/verify-app.sh').read_text()
        package = (ROOT / 'scripts/package-app.sh').read_text()
        prepare = (ROOT / 'scripts/prepare-local-update-lab.sh').read_text()
        self.assertIn('update_lab_key=0', verify)
        self.assertIn('elif [[ -f "$sparkle_public_key_file" ]]', verify)
        self.assertIn('Config/Release/SparklePublicKey.txt', verify)
        self.assertIn('verify_arguments+=(--update-lab-key)', package)
        self.assertIn('extracted_verify_arguments+=(--update-lab-key)', package)
        self.assertIn('--ed-key-file "$private_key_file"', prepare)
        self.assertNotIn('MyTerm.Release.ed25519', prepare)


if __name__ == '__main__':
    unittest.main()
