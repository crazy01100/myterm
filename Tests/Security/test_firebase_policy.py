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
    def test_rules_paths_reject_braces_before_cli(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            for value in ['{a,b}.rules','{'*4500+'x'+'}'*4500,'a/../{bad}.rules']:
                with self.subTest(value=value[:40]),self.assertRaises(ValueError):
                    p.validate_rules_watch_paths({'firestore':{'rules':value}},root)
            with self.assertRaises(ValueError):
                p.validate_rules_watch_paths({'firestore':[{'rules':'safe.rules'},{'rules':'{a,b}.rules'}]},root)
    def test_project_and_symlink_names_checked(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            with self.assertRaises(ValueError):
                p.validate_rules_watch_paths({'firestore':{'rules':'/file.rules'}},root/'{bad}')
            target=root/'{target}';target.mkdir();(target/'file.rules').write_text('fixture')
            (root/'safe').symlink_to(target,target_is_directory=True)
            with self.assertRaises(ValueError):
                p.validate_rules_watch_paths({'firestore':{'rules':'safe/file.rules'}},root)
    def test_normal_rules_paths_and_auth_only_remain_available(self):
        with tempfile.TemporaryDirectory(prefix='MyTerm space ') as d:
            root=Path(d)
            p.validate_rules_watch_paths({'firestore':{'rules':'規則 (local)/firestore.rules'}},root)
            p.validate_rules_watch_paths({'firestore':[{'rules':'firestore.rules'}]},root)
            (root/'firebase.json').write_text(json.dumps({'firestore':{'rules':'{bad}.rules'}}))
            p.validate(['emulators:start','--project','demo-myterm','--only','auth'],root)
            for command in ['emulators:start','emulators:exec']:
                args=[command,'--project','demo-myterm','--only','firestore']
                if command=='emulators:exec':args+=['node --test Tests/FirebaseRules/firestore.rules.test.mjs']
                with self.assertRaises(ValueError):p.validate(args,root)
    def test_invalid_rules_config_rejected(self):
        for config in [{'firestore':'invalid'},{'firestore':[1]},{'firestore':{'rules':[]}}]:
            with self.assertRaises(ValueError):p.validate_rules_watch_paths(config,ROOT)

if __name__=='__main__':unittest.main()
