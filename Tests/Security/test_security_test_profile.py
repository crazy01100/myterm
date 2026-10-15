"""Pure selector/temporary-Git tests. No npm, application or vulnerability test."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('profile',ROOT/'scripts/security-test-profile.py')
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)

class ProfileTests(unittest.TestCase):
    def test_exact_policy_files(self):self.assertEqual(p.profile([('M','scripts/security-audit.py'),('A','scripts/run-policy-tests.py')]),'policy-only')
    def test_dependencies_rules_and_app_force_full(self):
        for name in ['package.json','package-lock.json','firebase.json','firestore.rules','Sources/MySSHClient/App.swift','Tests/Security/dependency-advisories.test.cjs']:
            self.assertEqual(p.profile([('M','README.md'),('M',name)]),'full')
    def test_no_changes_deletion_rename_or_unknown_force_full(self):
        for changes in [[],[('D','README.md')],[('R','README.md')],[('M','unknown.md')]]:self.assertEqual(p.profile(changes),'full')
    def test_invalid_event_or_refs_rejected(self):
        for event,data in [('unknown',{}),('push',{'before':'0'*40,'after':'b'*40}),('push',{'before':'a'*40,'after':'c'*40})]:
            with self.assertRaises(ValueError):p.refs(event,data,'b'*40)
    def test_current_push_uses_exact_before_after(self):self.assertEqual(p.refs('push',{'before':'a'*40,'after':'b'*40},'b'*40),('a'*40,'b'*40))
    def test_monitor_uses_parent_of_current_commit(self):self.assertEqual(p.refs('workflow_dispatch',{},'b'*40,lambda *_:'a'*40),('a'*40,'b'*40))
    def test_real_git_comparison_and_no_override(self):
        with tempfile.TemporaryDirectory(prefix='MyTerm-policy-git-') as d:
            root=Path(d)
            def git(*args):return subprocess.run(['git',*args],cwd=root,check=True,capture_output=True,text=True).stdout.strip()
            git('init');git('config','user.name','Policy Fixture');git('config','user.email','fixture@example.invalid')
            (root/'README.md').write_text('base');git('add','.');git('commit','-m','base');base=git('rev-parse','HEAD')
            (root/'README.md').write_text('policy docs');git('add','.');git('commit','-m','docs');head=git('rev-parse','HEAD')
            event=root/'event.json';event.write_text(json.dumps({'before':base,'after':head}))
            env={'GITHUB_EVENT_NAME':'push','GITHUB_EVENT_PATH':str(event),'SECURITY_TEST_PROFILE':'full'}
            self.assertEqual(p.select(root,env)['profile'],'policy-only')
            (root/'package.json').write_text('{}');git('add','package.json');git('commit','-m','dependency');newhead=git('rev-parse','HEAD')
            event.write_text(json.dumps({'before':head,'after':newhead}));env['SECURITY_TEST_PROFILE']='policy-only'
            self.assertEqual(p.select(root,env)['profile'],'full')
    def test_unavailable_git_history_fails(self):
        with tempfile.TemporaryDirectory(prefix='MyTerm-policy-no-git-') as d:
            root=Path(d);event=root/'event.json';event.write_text('{}')
            with self.assertRaises(subprocess.SubprocessError):p.select(root,{'GITHUB_EVENT_NAME':'workflow_dispatch','GITHUB_EVENT_PATH':str(event)})

if __name__=='__main__':unittest.main()
