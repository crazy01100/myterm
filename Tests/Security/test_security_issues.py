import copy
import datetime as dt
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
def module(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/file);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
s=module('issues','scripts/sync-security-issues.py');a=module('audit_issues','scripts/security-audit.py')
ENV={'GITHUB_ACTIONS':'true','GITHUB_EVENT_NAME':'schedule','GITHUB_REF':'refs/heads/main'}

def report(findings=True):
    return {'schemaVersion':1,'checkedAt':dt.datetime.now(dt.timezone.utc).isoformat(),'scanStatus':'complete','errors':[],'releaseTag':'v1.0.21','upstreamReleases':{},'findings':[{'id':'GHSA-test','component':'owner/component','scope':'released-app','version':'1.0.0','severity':'high','status':'affected','url':'https://github.com/owner/component/security/advisories/GHSA-test'}] if findings else []}

class FakeGitHub:
    def __init__(self):self.private=True;self.issues=[];self.comments=[];self.calls=[];self.fail_patch=False
    def pages(self,path):return copy.deepcopy(self.comments if '/comments' in path else self.issues)
    def request(self,path,method='GET',payload=None):
        if path=='':return {'private':self.private,'default_branch':'main'}
        self.calls.append((path,method,payload))
        if path=='issues' and method=='POST':
            issue={**payload,'number':len(self.issues)+1,'state':'open','user':{'login':s.BOT}};self.issues.append(issue);return issue
        if path.endswith('/comments'):
            self.comments.append({**payload,'user':{'login':s.BOT}});return {}
        if method=='PATCH':
            if self.fail_patch:raise RuntimeError('simulated write failure')
            item=next(i for i in self.issues if i['number']==int(path.split('/')[1]));item.update(payload);return item
        raise AssertionError(path)

class IssueTests(unittest.TestCase):
    def test_repository_metadata_endpoint(self):
        with patch.object(s.subprocess, 'run') as call:
            call.return_value.returncode=0;call.return_value.stdout='{"private":true}'
            s.GitHub('owner/repo').request('')
            self.assertEqual(call.call_args[0][0][2], 'repos/owner/repo')

    def test_create_then_unchanged_is_noop(self):
        api=FakeGitHub();r=report();self.assertEqual(s.synchronize(r,api,True,ENV)[0]['action'],'create')
        r['checkedAt']=dt.datetime.now(dt.timezone.utc).isoformat()
        self.assertEqual(s.synchronize(r,api,True,ENV),[]);self.assertEqual(len(api.calls),1)
    def test_no_risk_succeeds(self):self.assertEqual(s.synchronize(report(False),FakeGitHub(),True,ENV),[])
    def test_expiry_updates_same_issue_and_comments_once(self):
        api=FakeGitHub();r=report();f=r['findings'][0];f.update(acceptedRisk=True,exceptionExpiresAt='2026-09-18T15:59:59+00:00');s.synchronize(r,api,True,ENV)
        f['acceptedRisk']=False;f['exceptionExpired']=True;s.synchronize(r,api,True,ENV);s.synchronize(r,api,True,ENV)
        self.assertEqual(len(api.issues),1);self.assertEqual(len(api.comments),1);self.assertIn('已到期',api.issues[0]['body'])
    def test_resolve_and_reopen_preserve_issue(self):
        api=FakeGitHub();r=report();s.synchronize(r,api,True,ENV);s.synchronize(report(False),api,True,ENV)
        self.assertEqual(api.issues[0]['state'],'closed');s.synchronize(r,api,True,ENV)
        self.assertEqual(len(api.issues),1);self.assertEqual(api.issues[0]['state'],'open')
    def test_incomplete_scan_cannot_close(self):
        api=FakeGitHub();s.synchronize(report(),api,True,ENV);r=report(False);r.update(errors=['query failed'],scanStatus='failed')
        with self.assertRaises(ValueError):s.synchronize(r,api,True,ENV)
        self.assertEqual(api.issues[0]['state'],'open')
    def test_stale_report_rejected(self):
        r=report();r['checkedAt']='2020-01-01T00:00:00+00:00'
        with self.assertRaises(ValueError):s.synchronize(r,FakeGitHub(),True,ENV)
    def test_untrusted_context_and_public_repo_rejected(self):
        for env in [{},{**ENV,'GITHUB_EVENT_NAME':'pull_request'},{**ENV,'GITHUB_REF':'refs/heads/other'}]:
            api=FakeGitHub()
            with self.assertRaises(ValueError):s.synchronize(report(),api,True,env)
            self.assertEqual(api.calls,[])
        api=FakeGitHub();api.private=False
        with self.assertRaises(ValueError):s.synchronize(report(),api,True,ENV)
    def test_public_opt_in_lifecycle(self):
        api=FakeGitHub();api.private=False;r=report()
        self.assertEqual(s.synchronize(report(False),api,True,ENV,allow_public=True),[])
        self.assertEqual(s.synchronize(r,api,True,ENV,allow_public=True)[0]['action'],'create')
        self.assertEqual(s.synchronize(r,api,True,ENV,allow_public=True),[])
        s.synchronize(report(False),api,True,ENV,allow_public=True)
        self.assertEqual(api.issues[0]['state'],'closed')
        s.synchronize(r,api,True,ENV,allow_public=True)
        self.assertEqual(api.issues[0]['state'],'open');self.assertEqual(len(api.issues),1)
    def test_public_opt_in_does_not_allow_untrusted_execution(self):
        for env in [{},{**ENV,'GITHUB_EVENT_NAME':'pull_request'},{**ENV,'GITHUB_REF':'refs/heads/other'}]:
            api=FakeGitHub();api.private=False
            with self.assertRaises(ValueError):s.synchronize(report(),api,True,env,allow_public=True)
            self.assertEqual(api.calls,[])
    def test_public_opt_in_preserves_failure_and_report_boundaries(self):
        api=FakeGitHub();api.private=False;r=report()
        r['privateNotes']='PRIVATE_TEST_SENTINEL'
        r['findings'][0]['internalEvidence']='PRIVATE_TEST_SENTINEL'
        s.synchronize(r,api,True,ENV,allow_public=True)
        self.assertNotIn('PRIVATE_TEST_SENTINEL',api.issues[0]['body'])
        invalid=report(False);invalid.update(scanStatus='failed',errors=['offline'])
        with self.assertRaises(ValueError):s.synchronize(invalid,api,True,ENV,allow_public=True)
        self.assertEqual(api.issues[0]['state'],'open')
        api.fail_patch=True
        with self.assertRaises(RuntimeError):s.synchronize(report(False),api,True,ENV,allow_public=True)
    def test_unknown_visibility_is_rejected_even_with_opt_in(self):
        api=FakeGitHub();api.private=None
        with self.assertRaises(ValueError):s.synchronize(report(),api,True,ENV,allow_public=True)
        self.assertEqual(api.calls,[])
    def test_human_issue_never_modified(self):
        api=FakeGitHub();s.synchronize(report(),api,True,ENV);api.issues[0]['user']['login']='human';s.synchronize(report(False),api,True,ENV)
        self.assertEqual(api.issues[0]['state'],'open')
    def test_write_failure_is_error_and_retry_does_not_duplicate_comment(self):
        api=FakeGitHub();r=report();s.synchronize(r,api,True,ENV);r['findings'][0]['version']='1.0.1';api.fail_patch=True
        with self.assertRaises(RuntimeError):s.synchronize(r,api,True,ENV)
        api.fail_patch=False;s.synchronize(r,api,True,ENV);self.assertEqual(len(api.comments),1)
    def test_dry_run_never_writes(self):
        api=FakeGitHub();self.assertEqual(s.synchronize(report(),api)[0]['action'],'create');self.assertEqual(api.calls,[])
    @patch.object(a, "write_summary")
    def test_monitor_exit_codes_and_gate_are_distinct(self, _summary):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'report.json'
            for has_risk in [False,True]:
                r=report(has_risk)
                with patch.object(a,'run',return_value=r),patch('sys.argv',['audit','--monitor','--output',str(path)]):self.assertEqual(a.main(),0)
            r=report(False);r.update(errors=['offline'],scanStatus='failed')
            with patch.object(a,'run',return_value=r),patch('sys.argv',['audit','--monitor','--output',str(path)]):self.assertEqual(a.main(),1)
            r=report();r['findings'][0]['scope']='current-source'
            with patch.object(a,'run',return_value=r),patch('sys.argv',['audit','--output',str(path)]):self.assertEqual(a.main(),1)

if __name__=='__main__':unittest.main()
