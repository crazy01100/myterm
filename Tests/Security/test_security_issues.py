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
    def test_real_api_spaces_writes_without_delaying_reads(self):
        import subprocess
        clock=[10.0];pauses=[]
        def sleep(seconds):pauses.append(seconds);clock[0]+=seconds
        with patch.object(s.time,'monotonic',side_effect=lambda:clock[0]),patch.object(s.time,'sleep',side_effect=sleep), \
             patch.object(s.subprocess,'run',return_value=subprocess.CompletedProcess([],0,'{}','')) as call:
            api=s.GitHub('owner/repo')
            api.request('issues','POST',{});api.request('issues/1','GET');api.request('issues/1','PATCH',{})
            api.request('issues/1/comments','POST',{})
        self.assertEqual(pauses,[1.0,1.0]);self.assertEqual(call.call_count,4)

    def test_api_failure_reports_only_status_and_limit_classification(self):
        import subprocess
        with patch.object(s.subprocess,'run',return_value=subprocess.CompletedProcess([],1,'','private detail; secondary rate limit (HTTP 403)')):
            with self.assertRaisesRegex(RuntimeError,r'HTTP 403 \(rate-limited\)') as caught:
                s.GitHub('owner/repo').request('issues','POST',{})
        self.assertNotIn('private detail',str(caught.exception))

    def test_repeated_origins_retain_every_version_and_publish_once(self):
        api=FakeGitHub();r=report();f=r['findings'][0];f['version']='1.0.0'
        f['environmentObservations']=[{'environment':'ci','origin':'action/fixture','versions':versions}
                                      for versions in (['1.0.0','2.0.0'],['1.0.0'],['2.0.0'])]
        s.synchronize(r,api,True,ENV)
        self.assertEqual(s.synchronize(r,api,True,ENV),[])
        stored=s.fmt.parse_issue(api.issues[0])['finding']
        self.assertEqual(stored['version'],'1.0.0, 2.0.0')
        self.assertEqual(stored['environmentObservations'],[{'environment':'ci','origin':'action/fixture','versions':['1.0.0','2.0.0']}])
        f['environmentObservations']=[{'environment':'local','origin':'tool/fixture','versions':['3.0.0']}]
        s.synchronize(r,api,True,ENV)
        self.assertEqual(s.synchronize(r,api,True,ENV),[])
        self.assertEqual(len(s.fmt.parse_issue(api.issues[0])['finding']['environmentObservations']),2)

    def test_official_jdk_notice_publishes_once_without_accepting_risk(self):
        api=FakeGitHub();r=report();f=r['findings'][0]
        f.update(id='CVE-2099-1234',component='Temurin',scope='development',
                 status='needs-review',url='https://openjdk.org/groups/vulnerability/advisories/2099-01-01')
        actions=s.synchronize(r,api,True,ENV)
        self.assertEqual(actions[0]['action'],'create')
        self.assertIn(f['url'],api.issues[0]['body'])
        self.assertEqual(s.synchronize(r,api,True,ENV),[])
        self.assertEqual(s.fmt.parse_issue(api.issues[0])['finding']['status'],'needs-review')

    def test_jdk_notice_does_not_allow_lookalike_hosts_or_unrelated_urls(self):
        valid='https://openjdk.org/groups/vulnerability/advisories/2099-01-01'
        for url in (valid.replace('openjdk.org','openjdkXorg'),valid.replace('openjdk.org','openjdk.org.example.com'),
                    valid.replace('https:','http:'),valid+'?redirect=1',valid+'#fragment',
                    valid.replace('/groups/vulnerability/advisories/','/unrelated/')):
            api=FakeGitHub();r=report();r['findings'][0]['url']=url
            with self.subTest(url=url),self.assertRaises(ValueError):s.synchronize(r,api,True,ENV)
            self.assertEqual(api.calls,[])

    def test_partial_verified_scan_adds_risk_but_never_resolves_or_lowers_old_risk(self):
        api=FakeGitHub();original=report();s.synchronize(original,api,True,ENV)
        partial=report(False);partial.update(scanStatus='failed',errors=['one provider unavailable'],publicationMode='additive',
            sourceReview={'sourceVerified':True,'grantsRiskException':False,'policySHA256':'a'*64})
        f=copy.deepcopy(original['findings'][0]);f.update(queryComplete=True,id='GHSA-other')
        partial['findings']=[f];s.synchronize(partial,api,True,ENV)
        self.assertEqual(len(api.issues),2);self.assertTrue(all(i['state']=='open' for i in api.issues))
        f.update(id='GHSA-test',severity='low',version='2.0.0')
        s.synchronize(partial,api,True,ENV)
        old=s.fmt.parse_issue(api.issues[0])['finding']
        self.assertEqual(old['severity'],'high');self.assertEqual(old['version'],'1.0.0, 2.0.0')

    def test_partial_mode_without_source_approval_or_query_receipt_cannot_publish(self):
        api=FakeGitHub();partial=report();partial.update(scanStatus='failed',errors=['incomplete'],publicationMode='additive')
        with self.assertRaises(ValueError):s.synchronize(partial,api,True,ENV)
        self.assertEqual(api.calls,[])
        partial['sourceReview']={'sourceVerified':True,'grantsRiskException':False,'policySHA256':'a'*64}
        self.assertEqual(s.synchronize(partial,api,True,ENV),[])
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


class FormatMigrationTests(unittest.TestCase):
    def legacy(self,api,r,closed=False):
        s.synchronize(r,api,True,ENV)
        f=r['findings'][0];key=s.digest([f[k] for k in ['id','component','scope']])
        api.issues[0]['body']=f'''<!-- myterm-security-risk:v1 key={key} digest={'a'*64} -->
## 掃描已完成，以下風險需要追蹤。此紀錄不代表監測程式故障。

- **公告**：{f['id']}
- **元件**：{f['component']}
- **受影響範圍**：已發布 App
- **版本／revision**：{f['version']}
- **判斷**：版本命中；不代表已驗證攻擊可達
- **上游修補資訊**：請依公告確認相容的修補版本
- **正式版本**：v1.0.21

[查看上游公告]({f['url']})

建議動作：核對公告前提與相容修補，更新受影響相依並執行相稱測試；未修復的例外不得自動展延。

本次紀錄的掃描時間：2026-09-30T18:02:03+00:00
'''
        if closed:
            api.issues[0]['state']='closed';api.issues[0]['body']+='\n## 解除紀錄\n本次完整來源／正式版掃描已不再命中此風險。時間：2026-10-01T01:02:03+00:00。不代表所有使用者裝置均已更新。'
    def test_format_only_preserves_time_without_comment(self):
        api=FakeGitHub();r=report();self.legacy(api,r)
        s.synchronize(r,api,True,ENV)
        self.assertEqual(api.comments,[]);self.assertIn('2026-10-01 02:02:03',api.issues[0]['body'])
        self.assertEqual(s.synchronize(r,api,True,ENV),[])
    def test_closed_migration_never_reopens_and_preserves_resolutions(self):
        api=FakeGitHub();r=report();self.legacy(api,r,True);api.comments=[{'body':'human context','user':{'login':'human'}}]
        s.synchronize(report(False),api,True,ENV,refresh_format=True)
        self.assertEqual(api.issues[0]['state'],'closed');self.assertIn('2026-10-01 09:02:03',api.issues[0]['body']);self.assertEqual(len(api.comments),1)
        self.assertEqual(s.synchronize(report(False),api,True,ENV,refresh_format=True),[])
    def test_unknown_legacy_addition_preserved(self):
        api=FakeGitHub();r=report();self.legacy(api,r);api.issues[0]['body']+='Human-added context'
        old=copy.deepcopy(api.issues);actions=s.synchronize(report(False),api,True,ENV,refresh_format=True)
        self.assertEqual(actions[0]['action'],'needs-review');self.assertEqual(api.issues,old)
    def test_enrichment_failure_cannot_close(self):
        api=FakeGitHub();r=report();self.legacy(api,r)
        with self.assertRaises(ValueError):s.synchronize(report(False),api,True,ENV,enrich=lambda _:(_ for _ in ()).throw(ValueError('offline')))
        self.assertEqual(api.issues[0]['state'],'open')



class EnvironmentCoverageTests(unittest.TestCase):
    def test_ci_cannot_close_a_local_observation_or_disappeared_origin(self):
        api=FakeGitHub();r=report()
        r['findings'][0]['environmentObservations']=[{'environment':'local','origin':'project-npm-tool','versions':['1.0.0']}]
        s.synchronize(r,api,True,ENV)
        clear=report(False);clear.update(observedEnvironment='ci',observedOrigins=['project-npm-tool'],toolchainCoverage={'checksComplete':True})
        self.assertEqual(s.synchronize(clear,api,True,ENV)[0]['action'],'needs-review')
        self.assertEqual(api.issues[0]['state'],'open')
        clear['observedEnvironment']='local';clear['observedOrigins']=[]
        self.assertEqual(s.synchronize(clear,api,True,ENV)[0]['action'],'needs-review')
        clear['observedOrigins']=['project-npm-tool']
        self.assertEqual(s.synchronize(clear,api,True,ENV)[0]['action'],'preserve')
        clear['originCoverage']={'project-npm-tool':{'closureEligible':True}}
        self.assertEqual(s.synchronize(clear,api,True,ENV)[0]['action'],'resolve')
    def test_new_ci_observation_preserves_unverified_local_risk(self):
        api=FakeGitHub();r=report()
        r['findings'][0]['environmentObservations']=[{'environment':'local','origin':'project-npm-tool','versions':['1.0.0']}]
        s.synchronize(r,api,True,ENV)
        r['findings'][0].update(version='2.0.0',environmentObservations=[{'environment':'ci','origin':'project-npm-tool','versions':['2.0.0']}])
        s.synchronize(r,api,True,ENV)
        snapshot=s.fmt.parse_issue(api.issues[0])['finding']
        self.assertEqual({o['environment'] for o in snapshot['environmentObservations']},{'ci','local'})
        self.assertEqual(snapshot['version'],'1.0.0, 2.0.0')
    def test_legacy_and_new_collector_merge_without_dropping_origin(self):
        old=report()['findings'][0];new={**old,'version':'2.0.0','dependencyPaths':['project-npm-tool'],
             'environmentObservations':[{'environment':'ci','origin':'project-npm-tool','versions':['2.0.0']}]}
        result=a.merge_findings([old,new]);self.assertEqual(len(result),1)
        self.assertEqual(result[0]['version'],'1.0.0, 2.0.0');self.assertEqual(result[0]['dependencyPaths'],['project-npm-tool'])

if __name__=='__main__':unittest.main()
