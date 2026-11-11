"""Synthetic version candidates and two-phase publication; no exploit inputs."""
import copy
import datetime as dt
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_security_issues import ENV
from test_monitor_integration import ReadbackGitHub

ROOT=Path(__file__).resolve().parents[2]
def load(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/f'{name}.py')
    m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m

t=load('security-risk-triage');a=load('security-audit');s=load('sync-security-issues')
m=load('sync-security-monitor-status');receipt=load('security-monitor-receipt');release=load('security-release-policy')


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
        cfg=self.root/'Config/Security';cfg.mkdir(parents=True)
        for name in ('risk-triage.json','node-tools.json','vendor-notices.json','supplier-notice-cursor.json','exceptions.json','release-decisions.json'):
            (cfg/name).write_bytes((ROOT/'Config/Security'/name).read_bytes())
        self.policy=json.loads((cfg/'risk-triage.json').read_text())
        f={'id':'CVE-2026-107496','component':'OpenSSL','scope':'development','version':'3.5.9',
           'status':'needs-review','severity':'low','queryComplete':True,'matchBasis':'version-only',
           'url':'https://openssl-library.org/news/secjson/cve-2026-107496.json',
           'fixedVersion':'3.5.10','dependencyPaths':['node-runtime/openssl'],
           'environmentObservations':[{'environment':'ci','origin':'node-runtime/openssl','versions':['3.5.9']}]}
        self.r={'schemaVersion':1,'checkedAt':dt.datetime.now(dt.timezone.utc).isoformat(),'scanStatus':'complete',
                'errors':[],'coverageErrors':[],'coverageGaps':[],'releaseTag':'v1.10.1','findings':[f],
                'sourceReview':{'sourceVerified':True,'grantsRiskException':False,'policySHA256':'a'*64,'checkoutCommit':'b'*40},
                'observedEnvironment':'ci','observedOrigins':['node-runtime/openssl'],
                'toolchainCoverage':{'checksComplete':True},'packageMonitoring':{'queriesComplete':True},
                'vendorNotices':{'checksComplete':True,'changes':[],'sources':[],'requiresNoticeReview':False}}
        self.rebuild();self.api=ReadbackGitHub()
    def rebuild(self):
        f=copy.deepcopy(self.r['findings']);self.r['rawFindings']=f
        self.r.update(applicabilityReviews=[],supplierFixReviews=[],projectApplicabilityReviews=[],projectApplicabilityProofs=[])
        self.r['collectionEvidence']={'schemaVersion':1,'baselineCommit':'22c3361bd0cce52086527a979ae61c3201d93763',
            'collectors':[{'collector':c,'status':'complete','findings':[]} for c in
                          ['app-source','npm-project','python-verifier','actions-repository','released-app']]+
                         [{'collector':'expanded-toolchain','status':'complete','findings':copy.deepcopy(f)}]}
        self.r['riskTriage']=t.build(self.r,self.root)
    def save(self):return m.synchronize(self.r,self.api,apply=True,environ=ENV,root=self.root)
    def issues(self):return s.synchronize(self.r,self.api,True,ENV,root=self.root)
    def seed(self):
        f=self.r['findings'][0];title,body=s.fmt.render(s.digest([f[k] for k in ('id','component','scope')]),f,self.r)
        self.api.issues.append({'number':198,'state':'open','title':title,'body':body,'user':{'login':s.BOT}})
    def promote(self):
        self.policy['projectRisks']=[{**{k:self.r['findings'][0][k] for k in ('id','component','scope')},
                                     'status':'unresolved-critical','reason':'Verified signing consumer accepts affected input'}]
        (self.root/t.CONFIG).write_text(json.dumps(self.policy));self.rebuild()
    def test_raw_observation_retained_and_not_accepted_or_inapplicable(self):
        before=copy.deepcopy(self.r);rows=t.candidates(self.r,self.root)
        self.assertEqual(len(rows),1);self.assertEqual(self.r,before)
        self.assertFalse(self.r['riskTriage']['grantsRiskException']);self.assertNotIn('acceptedRisk',rows[0]['finding'])
    def test_complete_version_only_new_tool_finding_routes_without_new_id_rule(self):
        self.r['findings'][0].update(id='CVE-2099-11111',severity='high');self.rebuild()
        self.assertEqual(len(t.candidates(self.r,self.root)),1)
    def test_original_collectors_and_app_never_inherit_tool_candidate(self):
        for scope in ('current-source','delivery-app','released-app'):
            with self.subTest(scope=scope):
                self.r['findings'][0]['scope']=scope;self.rebuild()
                self.assertEqual(t.candidates(self.r,self.root),[])
        self.r['findings'][0]['scope']='development';self.rebuild()
        self.r['collectionEvidence']['collectors'][1]['findings']=copy.deepcopy(self.r['findings'])
        self.r['riskTriage']=t.build(self.r,self.root);self.assertEqual(t.candidates(self.r,self.root),[])
    def test_eight_existing_classifications_stay_individual(self):
        for rule in self.policy['retainIndividual']:
            self.r['findings'][0].update(rule);self.rebuild()
            self.assertEqual(t.candidates(self.r,self.root),[])
    def test_existing_individual_risk_cannot_be_dropped_from_policy(self):
        self.policy['retainIndividual'].pop()
        (self.root/t.CONFIG).write_text(json.dumps(self.policy))
        with self.assertRaises(ValueError):t.build(self.r,self.root)
    def test_unresolved_version_is_not_candidate(self):
        self.r['findings'][0]['matchBasis']='unresolved-version';self.rebuild()
        self.assertEqual(t.candidates(self.r,self.root),[])
    def test_cross_environment_or_unobserved_origin_rejected(self):
        for change in ('env','origin','version'):
            r=copy.deepcopy(self.r)
            if change=='env':r['findings'][0]['environmentObservations'][0]['environment']='local'
            if change=='origin':r['observedOrigins']=[]
            if change=='version':r['findings'][0]['version']='9.0'
            with self.subTest(change=change),self.assertRaises(ValueError):t.build(r,self.root)
    def test_missing_or_modified_triage_cannot_suppress_risk(self):
        self.r['riskTriage']['rows']=[]
        with self.assertRaises(ValueError):t.verify(self.r,self.root)
    def test_concrete_impact_stays_individual_and_blocks(self):
        self.promote();row=self.r['riskTriage']['rows'][0]
        self.assertEqual(row['disposition'],'individual');self.assertEqual(row['releaseEffect'],'block')
    def test_existing_positive_impact_annotation_not_downgraded(self):
        self.r['findings'][0]['impact']={'status':'affected'};self.rebuild()
        self.assertEqual(self.r['riskTriage']['rows'][0]['releaseEffect'],'block')
    def test_cannot_close_before_saved_aggregate(self):
        self.seed()
        with self.assertRaises(ValueError):self.issues()
        self.assertEqual(self.api.issues[0]['state'],'open')
    def test_transfer_deduplicates_then_reopens_same_issue_on_concrete_risk(self):
        self.seed();self.save();actions=self.issues()
        self.assertEqual(actions[0]['action'],'transfer-candidate')
        self.assertEqual(self.api.issues[0]['state_reason'],'not_planned')
        self.assertTrue(t.owned_transfer(s.fmt.parse_issue(self.api.issues[0])))
        comments=len(self.api.comments)
        self.assertEqual(self.save()['action'],'unchanged');self.assertEqual(self.issues(),[])
        self.assertEqual(len(self.api.comments),comments)
        self.promote();self.save();self.issues()
        self.assertEqual(self.api.issues[0]['state'],'open');self.assertEqual(len(self.api.issues),2)
    def test_new_candidate_uses_aggregate_without_individual_issue(self):
        self.save();self.assertEqual(self.issues(),[]);self.assertEqual(len(self.api.issues),1)
    def test_altered_aggregate_cannot_close_risk(self):
        self.seed();self.save();self.api.issues[1]['body']='unrecognized content'
        with self.assertRaises(ValueError):self.issues()
        self.assertEqual(self.api.issues[0]['state'],'open')
    def test_aggregate_failure_preserves_issue_and_retry_is_idempotent(self):
        self.seed();self.save();self.api.fail_patch=True
        with self.assertRaises(RuntimeError):self.issues()
        self.assertEqual(self.api.issues[0]['state'],'open')
        comments=len(self.api.comments);self.api.fail_patch=False;self.issues()
        self.assertEqual(len(self.api.comments),comments);self.assertEqual(self.api.issues[0]['state'],'closed')
    def test_candidate_not_observed_is_retained_not_marked_fixed(self):
        self.seed();self.save();self.issues();self.r['findings']=[];self.rebuild();self.save();self.issues()
        self.assertTrue(t.owned_transfer(s.fmt.parse_issue(self.api.issues[0])))
        self.assertIn('CVE-2026-107496',self.api.issues[1]['body'])
    def test_new_version_updates_aggregate_without_reopening(self):
        self.seed();self.save();self.issues()
        f=self.r['findings'][0];f['version']='3.5.10';f['environmentObservations'][0]['versions']=['3.5.10'];self.rebuild()
        self.save();self.issues();self.assertEqual(self.api.issues[0]['state'],'closed')
        self.assertIn('3.5.10',self.api.issues[1]['body'])
    def test_complete_preannouncement_only_and_changed_detail_fails_closed(self):
        notice=copy.deepcopy(self.policy['preannouncements'][0]);self.assertTrue(t.preannouncement(notice,self.r,self.root))
        notice['contentSHA256']='0'*64;self.assertFalse(t.preannouncement(notice,self.r,self.root))
        notice=copy.deepcopy(self.policy['preannouncements'][0]);self.r['errors']=['source unavailable']
        self.assertFalse(t.preannouncement(notice,self.r,self.root))
    def test_release_classifies_candidate_and_preannouncement_without_editing_findings(self):
        self.r['vendorNotices']['changes']=[copy.deepcopy(self.policy['preannouncements'][0])]
        self.r['vendorNotices']['requiresNoticeReview']=True
        self.rebuild();before=copy.deepcopy(self.r)
        ctx={'stage':'candidate','version':'1.11.0','build':'20261112000100',
             'checkoutCommit':'b'*40,'observedEnvironment':'ci'}
        with patch.object(release,'verify_sources',return_value='f'*64),patch.object(release,'action_assets'),patch.object(release,'npm_asset'):
            decision=release.classify(self.r,ctx,root=self.root)
            self.assertEqual(len(decision['nonBlockingFindings']),1)
            self.assertEqual(decision['unreviewedNotices'],[])
            self.assertEqual(decision['preannouncements'][0]['classification'],'awaiting-details')
            self.assertEqual(self.r,before)
            self.r['vendorNotices']['changes'][0]['contentSHA256']='0'*64
            changed=release.classify(self.r,ctx,root=self.root)
            self.assertEqual(len(changed['unreviewedNotices']),1)
            self.assertEqual(changed['preannouncements'],[])
    def test_release_refuses_concrete_delivery_risk_even_if_candidate_before(self):
        self.promote()
        ctx={'stage':'candidate','version':'1.11.0','build':'20261112000100',
             'checkoutCommit':'b'*40,'observedEnvironment':'ci'}
        with patch.object(release,'verify_sources',return_value='f'*64),patch.object(release,'action_assets'),patch.object(release,'npm_asset'):
            with self.assertRaisesRegex(ValueError,'Concrete project delivery risk'):
                release.classify(self.r,ctx,root=self.root)
    def test_failed_scan_does_not_reopen_transferred_or_create_duplicate(self):
        self.seed();self.save();self.issues()
        self.r.update(scanStatus='failed',errors=['required query failed'],publicationMode='additive')
        self.rebuild();self.save()
        with self.assertRaises(ValueError):self.issues()
        self.assertEqual(self.api.issues[0]['state'],'closed')
    def test_candidate_history_survives_feed_absence_and_repeated_restore(self):
        self.save();self.r['findings']=[];self.rebuild();self.save()
        self.assertEqual(self.save()['action'],'unchanged')
        self.assertIn('CVE-2026-107496',self.api.issues[0]['body'])
    def test_missing_candidate_digest_rejects_complete_receipt(self):
        env={'GITHUB_ACTIONS':'true','GITHUB_REPOSITORY':'crazy01100/myterm',
             'GITHUB_REF':'refs/heads/main','GITHUB_EVENT_NAME':'workflow_dispatch','GITHUB_SHA':'b'*40,
             'GITHUB_RUN_ID':'1','GITHUB_RUN_ATTEMPT':'1','SCAN_OUTCOME':'success',
             'RISK_ISSUES_OUTCOME':'success','NOTICE_ISSUES_OUTCOME':'success'}
        path=self.root/'report.json';path.write_text(json.dumps(self.r))
        h=hashlib.sha256(path.read_bytes()).hexdigest()
        for n in ('security-issues-result.json','security-monitor-status-result.json'):
            (self.root/n).write_text(json.dumps({'applied':True,'reportSHA256':h}))
        self.assertFalse(receipt.build(path,env)['complete'])
        expected=t.digest(t.candidate_payload(self.r))
        for n in ('security-issues-result.json','security-monitor-status-result.json'):
            (self.root/n).write_text(json.dumps({'applied':True,'reportSHA256':h,'candidateDigest':expected}))
        self.assertTrue(receipt.build(path,env)['complete'])
    def test_monitor_order_saves_candidates_before_closing_and_receipt(self):
        text=(ROOT/'.github/workflows/security-checks.yml').read_text()
        self.assertLess(text.index('id: notice_issues'),text.index('id: risk_issues'))
        self.assertIn("steps.notice_issues.outcome == 'success'",text)
    def test_candidate_gate_does_not_remove_raw_results(self):
        before=copy.deepcopy(self.r['findings'])
        with patch.object(a,'ROOT',self.root),patch.object(a,'pip_applicability'),patch.object(a,'openssl_supplier'),patch.object(a,'project_applicability'),patch.object(a,'supplier_notices'):
            self.assertFalse(a.blocking(self.r))
        self.assertEqual(self.r['findings'],before)

if __name__=='__main__':unittest.main()
