"""Synthetic monitor status and publication fixtures; no network or exploits."""
import copy
import datetime as dt
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
import zipfile
import os
import runpy
from unittest.mock import patch
from test_security_issues import FakeGitHub

ROOT=Path(__file__).resolve().parents[2]
def load(name):
    s=importlib.util.spec_from_file_location(name,ROOT/'scripts'/f'{name}.py')
    m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
h=load('security-monitor-health');r=load('security-monitor-receipt');n=load('sync-security-health')
ENV={'GITHUB_ACTIONS':'true','GITHUB_REPOSITORY':'crazy01100/myterm','GITHUB_REF':'refs/heads/main',
     'GITHUB_EVENT_NAME':'schedule','GITHUB_SHA':'a'*40,'GITHUB_RUN_ID':'1','GITHUB_RUN_ATTEMPT':'2',
     'SCAN_OUTCOME':'success','RISK_ISSUES_OUTCOME':'success','NOTICE_ISSUES_OUTCOME':'success'}

class MonitorHealthTests(unittest.TestCase):
    def setUp(self):
        self.now=dt.datetime.now(dt.timezone.utc)
        self.workflow={'path':'.github/workflows/security-checks.yml','state':'active'}
        self.run={'id':1,'path':self.workflow['path'],'event':'schedule','head_branch':'main',
            'head_repository':{'full_name':h.REPOSITORY},'status':'completed','conclusion':'success',
            'updated_at':self.now.isoformat(),'html_url':'https://github.com/crazy01100/myterm/actions/runs/1',
            'run_attempt':2,'head_sha':'a'*40}
        self.artifact={'id':2,'name':'security-monitor-state','expired':False,'workflow_run':{'id':1},'created_at':self.now.isoformat()}
    def test_latest_attempt_artifact_uses_creation_time_not_id_or_list_order(self):
        old={**self.artifact,'id':99,'created_at':(self.now-dt.timedelta(minutes=5)).isoformat()}
        for artifacts in ([old,self.artifact],[self.artifact,old]):
            self.assertEqual(h.evaluate(self.workflow,[self.run],artifacts,now=self.now)['artifactId'],2)
    def test_missing_future_or_ambiguous_artifact_time_fails_closed(self):
        for rows in ([{**self.artifact,'created_at':None}],
                     [{**self.artifact,'created_at':(self.now+dt.timedelta(minutes=1)).isoformat()}],
                     [self.artifact,{**self.artifact,'id':3}]):
            with self.subTest(rows=rows),self.assertRaises(ValueError):h.latest_artifact(rows,now=self.now)
    def test_restore_selects_newest_created_report_even_with_lower_id(self):
        old={**self.artifact,'id':99,'created_at':(self.now-dt.timedelta(minutes=5)).isoformat()}
        blob=io.BytesIO()
        with zipfile.ZipFile(blob,'w') as archive:archive.writestr('security-report.json',json.dumps({'source':'latest-attempt'}))
        run={**self.run,'head_repository':{'id':11}}
        responses={'repos/owner/repo/actions/artifacts?name=security-monitor-state&per_page=10':json.dumps({'artifacts':[old,self.artifact]}).encode(),
                   'repos/owner/repo':json.dumps({'default_branch':'main','id':11}).encode(),
                   'repos/owner/repo/actions/runs/1':json.dumps(run).encode(),
                   'repos/owner/repo/actions/artifacts/2/zip':blob.getvalue()}
        with tempfile.TemporaryDirectory() as directory:
            target=Path(directory)/'previous.json'
            with patch.dict(os.environ,{'GITHUB_REPOSITORY':'owner/repo','GITHUB_RUN_ID':'10'}), \
                 patch('sys.argv',['restore',str(target)]), \
                 patch('subprocess.check_output',side_effect=lambda args,**kw:responses[args[-1]]):
                runpy.run_path(str(ROOT/'scripts/restore-security-monitor.py'),run_name='__main__')
            self.assertEqual(json.loads(target.read_text()),{'source':'latest-attempt'})
    def test_new_failure_is_not_hidden_by_previous_success(self):
        failed={**self.run,'id':3,'conclusion':'failure'}
        self.run['updated_at']=(self.now-dt.timedelta(hours=12)).isoformat()
        self.assertEqual(h.evaluate(self.workflow,[self.run,failed],[self.artifact],now=self.now)['status'],'latest-run-failed')
    def test_24_hour_delay_and_48_hour_stale_thresholds(self):
        for hours,status in [(12,'healthy'),(24,'healthy'),(25,'delayed'),(48,'delayed'),(49,'stale')]:
            self.run['updated_at']=(self.now-dt.timedelta(hours=hours)).isoformat()
            self.assertEqual(h.evaluate(self.workflow,[self.run],[self.artifact],now=self.now)['status'],status)
    def test_receipt_binds_report_and_exact_run_attempt(self):
        report={'scanStatus':'complete','errors':[],'releaseTag':'v1','checkedAt':self.now.isoformat(),
            'findings':[{'severity':'high'}], 'toolchainCoverage':{'schemaVersion':1,'checksComplete':True,
            'errors':[],'inventoryDigest':'b'*64,'coverage':[{'checksComplete':True}],
            'supplierLimitations':[],'status':'complete'}}
        raw=json.dumps(report).encode()
        receipt={'schemaVersion':1,'complete':True,'reportSHA256':hashlib.sha256(raw).hexdigest(),
                 'riskIssues':'success','noticeIssues':'success','runId':1,'runAttempt':2,'headSHA':'a'*40}
        def archive():
            out=io.BytesIO()
            with zipfile.ZipFile(out,'w') as z:
                z.writestr('security-report.json',raw);z.writestr('security-monitor-receipt.json',json.dumps(receipt))
            return out.getvalue()
        expected={'runId':1,'runAttempt':2,'headSHA':'a'*40}
        self.assertIn('scanCheckedAt',h.retained_report(archive(),expected_run=expected)) # Findings are not failure.
        for field,value in [('reportSHA256','c'*64),('runAttempt',1),('headSHA','d'*40),('noticeIssues','failure')]:
            original=receipt[field];receipt[field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):h.retained_report(archive(),expected_run=expected)
            receipt[field]=original

class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.path=Path(self.tmp.name)/'security-report.json';self.path.write_text(json.dumps({'scanStatus':'complete','errors':[]}))
        self.proof={'applied':True,'reportSHA256':hashlib.sha256(self.path.read_bytes()).hexdigest()}
        for name in ('security-issues-result.json','security-monitor-status-result.json'):
            self.path.with_name(name).write_text(json.dumps(self.proof))
    def test_both_publishers_and_trusted_run_are_required(self):
        self.assertTrue(r.build(self.path,ENV)['complete'])
        for change in ({'NOTICE_ISSUES_OUTCOME':'failure'},{'SCAN_OUTCOME':'failure'},
                       {'GITHUB_REPOSITORY':'someone/fork'},{'GITHUB_EVENT_NAME':'pull_request'}):
            self.assertFalse(r.build(self.path,{**ENV,**change})['complete'])
    def test_missing_dry_run_or_previous_report_publication_cannot_pass(self):
        p=self.path.with_name('security-issues-result.json')
        for proof in ({**self.proof,'applied':False},{**self.proof,'reportSHA256':'0'*64}):
            p.write_text(json.dumps(proof));self.assertFalse(r.build(self.path,ENV)['complete'])
        p.unlink();self.assertFalse(r.build(self.path,ENV)['complete'])

class API(FakeGitHub):
    def request(self,path,method='GET',payload=None):
        if method=='GET' and path.startswith('issues/'):
            return copy.deepcopy(next(i for i in self.issues if i['number']==int(path.split('/')[1])))
        return super().request(path,method,payload)

class NotificationTests(unittest.TestCase):
    def setUp(self):
        self.now=dt.datetime.now(dt.timezone.utc);self.api=API()
        self.report={'checkedAt':self.now.isoformat(),'healthy':False,'status':'latest-run-failed','runId':1}
        self.review={'sourceVerified':True,'grantsRiskException':False}
    def sync(self):return n.synchronize(self.report,self.api,source_review=self.review,env=ENV,apply=True,now=self.now)
    def test_create_deduplicate_recovery_and_reopen_only_health_issue(self):
        self.assertEqual(self.sync()['action'],'create');self.assertEqual(self.sync()['action'],'unchanged')
        self.report.update(status='healthy',healthy=True)
        self.assertEqual(self.sync()['action'],'recover');self.assertEqual(self.api.issues[0]['state'],'closed')
        self.assertEqual(self.sync()['action'],'unchanged')
        self.report.update(status='delayed',healthy=False);self.sync()
        self.assertEqual(len(self.api.issues),1);self.assertEqual(self.api.issues[0]['state'],'open')
    def test_unchanged_failure_reminds_only_after_24_hours(self):
        self.sync();self.now+=dt.timedelta(hours=12);self.report['checkedAt']=self.now.isoformat()
        self.assertEqual(self.sync()['action'],'unchanged')
        self.now+=dt.timedelta(hours=12);self.report['checkedAt']=self.now.isoformat();self.sync()
        self.assertEqual(len(self.api.comments),1);self.sync();self.assertEqual(len(self.api.comments),1)
    def test_comment_success_patch_failure_retries_without_duplicate_comment(self):
        self.sync();self.report['status']='delayed';self.api.fail_patch=True
        with self.assertRaises(RuntimeError):self.sync()
        self.api.fail_patch=False;self.sync();self.assertEqual(len(self.api.comments),1)
    def test_foreign_or_unapproved_report_cannot_write(self):
        self.review['sourceVerified']=False
        with self.assertRaises(ValueError):self.sync()
        self.assertEqual(self.api.calls,[])
    def test_vulnerability_issue_is_never_touched(self):
        self.api.issues=[{'number':7,'state':'open','body':'<!-- myterm-security-risk:v1 -->',
                          'user':{'login':'github-actions[bot]'}}]
        self.sync();self.assertEqual(self.api.issues[0]['state'],'open')
        self.assertTrue(all(not call[0].startswith('issues/7') for call in self.api.calls))

if __name__=='__main__':unittest.main()
