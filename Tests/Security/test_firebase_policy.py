import importlib.util
from pathlib import Path
import tempfile,json,unittest
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('policy',ROOT/'scripts/firebase-command-policy.py')
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)
class FirebasePolicyTests(unittest.TestCase):
    def test_documented_rules_command(self):
        p.validate(['emulators:exec','--project','demo-myterm','--only','firestore','node --test Tests/FirebaseRules/firestore.rules.test.mjs'])
    def test_explicit_firestore_deploy(self):p.validate(['deploy','--project','example-project','--only','firestore:rules,firestore:indexes'])
    def test_account_and_version(self):
        for args in [['--version'],['login'],['login','--no-localhost'],['logout'],['projects:list']]:p.validate(args)
    def test_forbidden_reachable_paths(self):
        for args in [['auth:import','untrusted.json'],['deploy','--project','example-project','--only','hosting'],['emulators:start','--project','demo-myterm','--only','hosting'],['deploy','--project','example-project','--only','firestore','--only','hosting']]:
            with self.subTest(args=args),self.assertRaises(ValueError):p.validate(args)
    def test_arbitrary_shell_and_production_emulator_rejected(self):
        for args in [['emulators:exec','--project','demo-myterm','--only','firestore','firebase auth:import input.json'],['emulators:start','--project','example-project','--only','firestore'],['deploy','--project','example-project','--only','firestore','--config','other.json']]:
            with self.subTest(args=args),self.assertRaises(ValueError):p.validate(args)
    def test_network_exposure_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);(root/'firebase.json').write_text(json.dumps({'emulators':{'firestore':{'host':'0.0.0.0'}}}))
            with self.assertRaises(ValueError):p.validate(['emulators:start','--project','demo-myterm','--only','firestore'],root)
if __name__=='__main__':unittest.main()
