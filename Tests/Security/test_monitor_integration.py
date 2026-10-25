"""Synthetic monitoring receipts and in-memory Issue publication; no network."""
import copy
import datetime as dt
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from test_security_issues import FakeGitHub, ENV

ROOT=Path(__file__).resolve().parents[2]
def load(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/f'{name}.py')
    m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
p=load('security-toolchain-providers');m=load('sync-security-monitor-status')


class ReadbackGitHub(FakeGitHub):
    def request(self,path,method='GET',payload=None):
        if method=='GET' and path.startswith('issues/') and path.count('/')==1:
            return copy.deepcopy(next(i for i in self.issues if i['number']==int(path.split('/')[1])))
        return super().request(path,method,payload)


class ProviderTests(unittest.TestCase):
    def test_stable_version_respects_prerelease_boundary_and_upper_bound(self):
        audit=load('security-audit');rule='>= 4.0.0-beta.3, < 4.5.5'
        self.assertTrue(audit.affected('4.0.0',rule));self.assertTrue(audit.affected('4.5.4',rule))
        self.assertFalse(audit.affected('4.5.5',rule));self.assertFalse(audit.affected('5.11.2',rule))
        self.assertIsNone(audit.affected('4.0.0-beta.4',rule))
    def test_exact_parent_evidence_is_bound_and_drift_is_not_relabelled_success(self):
        now=dt.datetime.now(dt.timezone.utc).isoformat()
        item={'id':'npm-project','evidence':[{'lockSHA256':'a'*64}]}
        query={'collector':'npm-project','status':'complete','lockSHA256':'a'*64,'checkedAt':now,'sources':['npm audit']}
        self.assertIn(('npm-project','npm audit'),p.bind_parents({'coverage':[item]},[query]))
        query['lockSHA256']='b'*64
        self.assertEqual(p.bind_parents({'coverage':[item]},[query]),{})
    def test_missing_native_mapping_is_explicit_and_osv_cannot_cover_it(self):
        now=dt.datetime.now(dt.timezone.utc).isoformat()
        item={'id':'python','status':'inventoried','evidence':[]}
        inventory={'purpose':'audit','coverage':[item],'components':[]}
        policy={'collectors':[{'id':'python','uses':['audit'],'advisorySources':['OSV','native component vendor notices']}]}
        package={'advisoryQueryStatus':'complete','componentDigest':p.digest([]),'checkedAt':now}
        rows=p.receipts(inventory,policy,package,{}, {}, {})
        self.assertEqual([r['status'] for r in rows],['complete','needs-review'])
        self.assertEqual(rows[0]['coverageDigest'],p.digest(item))
        package['componentDigest']='0'*64
        self.assertEqual(p.receipts(inventory,policy,package,{}, {}, {})[0]['status'],'needs-review')

    def test_parent_receipt_must_match_current_domain_identity(self):
        item={'id':'actions','status':'supplier-managed-limited','evidence':[]}
        inventory={'purpose':'audit','coverage':[item],'components':[]}
        policy={'collectors':[{'id':'actions','uses':['audit'],'advisorySources':['GitHub repository advisories']}]}
        parent={('actions','GitHub repository advisories'):{'status':'complete','coverageDigest':'0'*64,'checkedAt':dt.datetime.now(dt.timezone.utc).isoformat()}}
        self.assertEqual(p.receipts(inventory,policy,{}, {}, {},parent)[0]['status'],'needs-review')


class MonitorStatusTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
        cfg=self.root/'Config/Security/vendor-notices.json';cfg.parent.mkdir(parents=True)
        cfg.write_text(json.dumps({'sources':{'python-blog':{'state':'reviewed','entries':[]}}}))
        self.notice={'source':'python-blog','id':'a'*64,'contentSHA256':'b'*64,
                     'title':'Official change without CVE','url':'https://blog.python.org/2099/fixture.html'}
        self.report={'schemaVersion':1,'checkedAt':dt.datetime.now(dt.timezone.utc).isoformat(),
                     'sourceReview':{'sourceVerified':True,'grantsRiskException':False,'policySHA256':'c'*64},
                     'errors':[],'scanStatus':'complete','toolchainCoverage':{'checksComplete':True},
                     'vendorNotices':{'changes':[self.notice]},'coverageGaps':[]}
        self.api=ReadbackGitHub()
    def sync(self):return m.synchronize(self.report,self.api,apply=True,environ=ENV,root=self.root)

    def test_notice_deduplicates_and_feed_absence_does_not_close_it(self):
        self.assertEqual(self.sync()['action'],'create');self.assertEqual(self.sync()['action'],'unchanged')
        self.report['vendorNotices']['changes']=[]
        self.assertEqual(self.sync()['action'],'unchanged');self.assertEqual(self.api.issues[0]['state'],'open')

    def test_exact_review_and_complete_coverage_are_both_needed_to_close(self):
        self.sync();self.report['vendorNotices']['changes']=[]
        cfg=self.root/'Config/Security/vendor-notices.json'
        cfg.write_text(json.dumps({'sources':{'python-blog':{'state':'reviewed','entries':[self.notice]}}}))
        self.report['errors']=['fixture unavailable'];self.report['scanStatus']='failed'
        self.sync();self.assertEqual(self.api.issues[0]['state'],'open')
        self.report['errors']=[];self.report['scanStatus']='complete'
        self.assertEqual(self.sync()['action'],'resolve');self.assertEqual(self.api.issues[0]['state'],'closed')

    def test_jdk_notice_requires_exact_cursor_and_preserves_other_notices(self):
        import hashlib
        url='https://openjdk.org/groups/vulnerability/advisories/'
        jdk={'source':'jdk-security','id':hashlib.sha256(url.encode()).hexdigest(),
             'contentSHA256':'d'*64,'title':'JDK security update','url':url}
        self.report['vendorNotices']['changes'].append(jdk);self.sync()
        self.report['vendorNotices']['changes']=[]
        cursor=self.root/'Config/Security/supplier-notice-cursor.json'
        cursor.write_text(json.dumps({'jdkNoticeCursor':'e'*64}))
        self.assertEqual(self.sync()['action'],'unchanged')
        cursor.write_text(json.dumps({'jdkNoticeCursor':'d'*64}))
        self.assertEqual(self.sync()['action'],'update')
        self.assertEqual(self.api.issues[0]['state'],'open')
        self.assertNotIn('JDK security update',self.api.issues[0]['body'])
        self.assertIn('Official change without CVE',self.api.issues[0]['body'])

    def test_os_notice_is_not_a_supported_publication_source(self):
        self.report['vendorNotices']['changes']=[{**self.notice,'source':'macos','url':'https://support.apple.com/fixture'}]
        with self.assertRaises(ValueError):self.sync()
        self.assertEqual(self.api.calls,[])

    def test_unapproved_stale_or_foreign_notice_never_writes(self):
        original=copy.deepcopy(self.report)
        for change in ({'sourceReview':{}},{'checkedAt':'2020-01-01T00:00:00+00:00'},
                       {'vendorNotices':{'changes':[{**self.notice,'url':'https://example.invalid/notice'}]}}):
            self.report={**original,**change}
            with self.subTest(change=change),self.assertRaises(ValueError):self.sync()
        self.assertEqual(self.api.calls,[])

    def test_publication_readback_mismatch_is_not_success(self):
        original=self.api.request
        def stale_readback(path,method='GET',payload=None):
            result=original(path,method,payload)
            if method=='GET' and path.startswith('issues/'):
                result['body']='stale body'
            return result
        self.api.request=stale_readback
        with self.assertRaisesRegex(ValueError,'readback'):self.sync()

    def test_comment_then_patch_failure_does_not_duplicate_notification(self):
        self.sync()
        self.report['vendorNotices']['changes'][0]['contentSHA256']='d'*64
        self.api.fail_patch=True
        with self.assertRaises(RuntimeError):self.sync()
        self.assertEqual(len(self.api.comments),1)
        self.api.fail_patch=False
        self.assertEqual(self.sync()['action'],'update')
        self.assertEqual(len(self.api.comments),1)

    def test_pending_baseline_is_visible_and_query_failure_cannot_erase_it(self):
        self.report['vendorNotices']['changes']=[]
        row={'id':'python-blog','reviewState':'pending','historyGap':False,
             'observedItems':50,'observedDigest':'d'*64}
        self.report['vendorNotices']['sources']=[row]
        self.assertEqual(self.sync()['action'],'create')
        self.assertIn('公告來源待審閱',self.api.issues[0]['body'])
        self.report['vendorNotices']['sources']=[]
        self.assertEqual(self.sync()['action'],'unchanged')
        self.report['vendorNotices']['sources']=[{**row,'reviewState':'reviewed'}]
        self.assertEqual(self.sync()['action'],'resolve')


class AssessmentGateTests(unittest.TestCase):
    def test_local_notes_never_waive_risk_and_do_not_transfer_to_ci(self):
        impact=load('security-toolchain-impact')
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);path=root/'Config/Security/toolchain-assessments.json';path.parent.mkdir(parents=True)
            row={'id':'fixture','component':'example','scope':'development','versions':['1.0.0'],
                 'status':'needs-review','gateEffect':'none','usage':'fixture','reason':'static evidence','evidence':[]}
            document={'schemaVersion':1,'environment':'local','grantsRiskException':False,'inventoryDigest':'a'*64,
                      'inputFiles':{},'assessments':[row]};path.write_text(json.dumps(document))
            finding={'id':'fixture','component':'example','scope':'development','version':'1.0.0','severity':'high','status':'affected'}
            report={'observedEnvironment':'local','toolchainCoverage':{'inventoryDigest':'a'*64},'findings':[copy.deepcopy(finding)]}
            impact.annotate(report,root)
            self.assertEqual(report['findings'][0]['status'],'affected');self.assertEqual(report['findings'][0]['severity'],'high')
            self.assertNotIn('acceptedRisk',report['findings'][0]);self.assertEqual(report['findings'][0]['impact']['reason'],'static evidence')
            report['observedEnvironment']='ci';report['findings']=[copy.deepcopy(finding)]
            impact.annotate(report,root);self.assertNotIn('impact',report['findings'][0])
            report['observedEnvironment']='local';report['toolchainCoverage']['inventoryDigest']='b'*64
            impact.annotate(report,root);self.assertIn('重新確認',report['findings'][0]['impact']['reason'])


if __name__=='__main__':unittest.main()
