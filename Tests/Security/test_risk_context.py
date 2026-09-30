import copy
import datetime as dt
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
def load(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/file);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
c=load('context_test','security-risk-context.py');f=load('format_test','security-issue-format.py');a=load('audit_test','security-audit.py')

class ContextTests(unittest.TestCase):
    def test_patch_branch_mapping(self):
        finding={'component':'example','version':'1.0.0,2.0.0'}
        rows=[{'package':{'ecosystem':'npm','name':'example'},'vulnerable_version_range':r,'first_patched_version':v} for r,v in [('>= 1.0.0, < 1.0.2','1.0.2'),('>= 2.0.0, < 2.0.3','2.0.3')]]
        rows.append({'package':{'ecosystem':'npm','name':'other'},'vulnerable_version_range':'*','first_patched_version':'99.0.0'})
        result=c.fixed_versions(finding,{'vulnerabilities':rows},a.affected)
        self.assertEqual([p['fixedVersions'] for p in result],[['1.0.2'],['2.0.3']])
    def test_no_patch_distinguished_from_unmatched_or_unknown(self):
        finding={'component':'x','version':'1.0.0'}
        row={'package':{'ecosystem':'npm','name':'x'},'vulnerable_version_range':'< 2.0.0','first_patched_version':None}
        self.assertEqual(c.fixed_versions(finding,{'vulnerabilities':[row]},a.affected)[0]['status'],'unavailable')
        row['vulnerable_version_range']='before commit';self.assertEqual(c.fixed_versions(finding,{'vulnerabilities':[row]},a.affected)[0]['status'],'needs-review')
        row['vulnerable_version_range']='> 2.0.0';self.assertEqual(c.fixed_versions(finding,{'vulnerabilities':[row]},a.affected)[0]['status'],'not-listed')
    def test_dependency_paths_use_nested_resolution_and_cycles(self):
        packages={'':{'devDependencies':{'cli':'1'}},'node_modules/cli':{'version':'1','dependencies':{'x':'1','cycle':'1'}},'node_modules/x':{'version':'2'},'node_modules/cli/node_modules/x':{'version':'1'},'node_modules/cycle':{'version':'1','dependencies':{'cli':'1'}}}
        self.assertEqual(c.dependency_paths(packages,'x',['1']),['cli@1 → x@1'])
        self.assertEqual(c.dependency_paths(packages,'x',['2']),[])
    def test_assessment_stale_by_hash_and_historical_label(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name);(root/'Config/Security').mkdir(parents=True);(root/'scripts').mkdir();(root/'scripts/source').write_text('reviewed')
            row={'id':'x','component':'x','scope':'development','versions':['1'],'status':'not-affected','reason':'fixed input only','usage':'entry → parser','reviewedCommit':'a'*40,'reviewedAt':'2026-10-01T00:00:00+00:00','evidence':[],'historicalScanTimes':['2026-09-30T00:00:00Z'],'inputs':{'scripts/source':c.hashlib.sha256(b'reviewed').hexdigest()}}
            (root/'Config/Security/impact-assessments.json').write_text(json.dumps({'schemaVersion':1,'assessments':[row]}))
            finding={'id':'x','component':'x','scope':'development','version':'1'}
            self.assertEqual(c.impact(finding,root)['status'],'not-affected')
            (root/'scripts/source').write_text('changed');self.assertEqual(c.impact(finding,root)['status'],'needs-review')
            self.assertEqual(c.impact(finding,root,historical=True)['status'],'needs-review')
            finding['observedAt']='2026-09-30T00:00:00Z'
            self.assertTrue(c.impact(finding,root,historical=True)['historical'])
            finding['version']='2';self.assertEqual(c.impact(finding,root)['status'],'needs-review')
    def test_invalid_assessment_path_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name);(root/'Config/Security').mkdir(parents=True)
            row={'id':'x','component':'x','scope':'development','versions':['1'],'status':'affected','reason':'test','reviewedCommit':'a'*40,'inputs':{'../secret':'a'*64}}
            (root/'Config/Security/impact-assessments.json').write_text(json.dumps({'schemaVersion':1,'assessments':[row]}))
            with self.assertRaises(ValueError):c.impact({'id':'x','component':'x','scope':'development','version':'1'},root)
    def test_query_failure_is_not_no_patch(self):
        with self.assertRaises(ValueError):c.enrich({'id':'GHSA-test','component':'x','version':'1','scope':'development'},lambda _:(_ for _ in ()).throw(ValueError('offline')),a.affected)
    def test_time_conversion_crosses_date(self):
        self.assertEqual(f.display_time('2026-09-30T18:02:03.123Z'),'2026-10-01 02:02:03（UTC+8）')
        with self.assertRaises(ValueError):f.display_time('2026-09-30T18:02:03')
    def test_render_concise_and_roundtrips_history(self):
        finding={'id':'GHSA-test','component':'x','scope':'development','version':'1.0.0','severity':'high','status':'affected','url':'https://github.com/advisories/GHSA-test','patches':[{'currentVersion':'1.0.0','fixedVersions':['1.0.1'],'status':'available'}],'impact':{'status':'needs-review','reason':'inspect [input]','internalEvidence':'SECRET'},'internalEvidence':'SECRET'}
        _,body=f.render('a'*64,finding,{'checkedAt':'2026-09-30T18:02:03Z'},resolutions=['2026-10-01T01:02:03Z'])
        self.assertEqual(body.count('(https://github.com/advisories/GHSA-test)'),1)
        self.assertNotIn('不代表',body);self.assertNotIn('建議動作',body)
        self.assertIn('1.0.0 → 1.0.1',body);self.assertIn('inspect \\[input\\]',body)
        snap=f.parse_body(body);self.assertEqual(snap['checkedAt'],'2026-09-30T18:02:03Z');self.assertEqual(snap['resolutions'],['2026-10-01T01:02:03Z']);self.assertNotIn('SECRET',json.dumps(snap))
    def test_impact_does_not_exempt_gate(self):
        finding={'scope':'development','severity':'high','status':'affected','impact':{'status':'not-affected'}}
        self.assertTrue(a.blocking({'errors':[],'findings':[finding]}))
    def test_npm_combines_advisory_version_branches(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name);(root/'scripts').mkdir();(root/'scripts/security-risk-context.py').write_text((ROOT/'scripts/security-risk-context.py').read_text())
            packages={'':{'devDependencies':{'x':'1'}},'node_modules/x':{'version':'1.0.0'},'node_modules/y/node_modules/x':{'version':'2.0.0'}}
            (root/'package-lock.json').write_text(json.dumps({'packages':packages}))
            data={'metadata':{'vulnerabilities':{}},'vulnerabilities':{}}
            for i,(node,ran) in enumerate([('node_modules/x','< 2.0.0'),('node_modules/y/node_modules/x','>= 2.0.0, < 3.0.0')]):
                data['vulnerabilities'][str(i)]={'nodes':[node],'via':[{'url':'https://github.com/advisories/GHSA-test','name':'x','severity':'high','range':ran}]}
            adv={'ghsa_id':'GHSA-test','vulnerabilities':[]}
            with patch.object(a,'ROOT',root),patch.object(a,'github_npm_advisories',return_value=[]),patch.object(a.subprocess,'run') as run,patch.object(a,'gh',return_value=adv):
                run.return_value.stdout=json.dumps(data);report={'findings':[]};a.scan_npm(report)
            self.assertEqual(len(report['findings']),1);self.assertEqual(report['findings'][0]['version'],'1.0.0,2.0.0')

class AdvisoryCrossCheckTests(unittest.TestCase):
    def advisory(self, name='@scope/x', ran='< 1.0.2'):
        return {'ghsa_id':'GHSA-test','severity':'medium','html_url':'https://github.com/advisories/GHSA-test','vulnerabilities':[{'package':{'ecosystem':'npm','name':name},'vulnerable_version_range':ran,'first_patched_version':'1.0.2'}]}
    def test_scoped_nested_queries_paginate_deduplicate_and_skip_withdrawn(self):
        from urllib.parse import parse_qs, urlparse
        adv=self.advisory();withdrawn={**adv,'ghsa_id':'GHSA-old','withdrawn_at':'2026-01-01'}
        packages={'':{'version':'0'},'node_modules/@scope/x':{'version':'1.0.0'},'node_modules/p/node_modules/@scope/x':{'version':'1.0.0'}}
        with patch.object(a.subprocess,'run') as run:
            run.return_value.returncode=0;run.return_value.stdout=json.dumps([[adv,withdrawn],[adv]])
            self.assertEqual(a.github_npm_advisories(packages),[adv])
        args=run.call_args.args[0];self.assertIn('--paginate',args);self.assertIn('--slurp',args)
        self.assertEqual(parse_qs(urlparse(args[-1]).query)['affects'],['@scope/x@1.0.0'])
    def test_failed_or_malformed_batch_is_not_empty_success(self):
        from types import SimpleNamespace
        packages={'node_modules/x':{'version':'1.0.0'}}
        for result in [SimpleNamespace(returncode=1,stdout='[]'),SimpleNamespace(returncode=0,stdout='{}'),SimpleNamespace(returncode=0,stdout='[{}]'),SimpleNamespace(returncode=0,stdout='[]'),SimpleNamespace(returncode=0,stdout='[[{}]]')]:
            with self.subTest(result=result),patch.object(a.subprocess,'run',return_value=result),self.assertRaises(ValueError):a.github_npm_advisories(packages)
    def test_partial_batch_failure_aborts(self):
        from types import SimpleNamespace
        from urllib.parse import parse_qs, urlparse
        packages={'node_modules/pkg'+str(i):{'version':'1.0.0'} for i in range(45)}
        def result(args,**kwargs):
            identities=parse_qs(urlparse(args[-1]).query)['affects'][0].split(',')
            return SimpleNamespace(returncode=int(len(identities)<40),stdout='[[]]')
        with patch.object(a.subprocess,'run',side_effect=result),self.assertRaises(ValueError):a.github_npm_advisories(packages)
    def scan(self, advisory, npm=None):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name);(root/'scripts').mkdir();(root/'scripts/security-risk-context.py').write_text((ROOT/'scripts/security-risk-context.py').read_text())
            (root/'package-lock.json').write_text(json.dumps({'packages':{'':{'devDependencies':{'@scope/x':'1.0.0'}},'node_modules/@scope/x':{'version':'1.0.0'}}}))
            data={'metadata':{'vulnerabilities':{}},'vulnerabilities':npm or {}}
            with patch.object(a,'ROOT',root),patch.object(a,'github_npm_advisories',return_value=[advisory]),patch.object(a.subprocess,'run') as run:
                run.return_value.stdout=json.dumps(data);report={'findings':[],'errors':[]};a.scan_npm(report);return report
    def test_github_only_advisory_detected_when_npm_is_empty(self):
        report=self.scan(self.advisory());self.assertEqual(len(report['findings']),1)
        self.assertEqual(report['findings'][0]['severity'],'moderate');self.assertTrue(a.blocking(report))
        self.assertEqual(report['findings'][0]['patches'][0]['fixedVersions'],['1.0.2'])
    def test_dual_feed_duplicate_produces_one_finding(self):
        npm={'x':{'nodes':['node_modules/@scope/x'],'via':[{'url':'https://github.com/advisories/GHSA-test','name':'@scope/x','severity':'moderate','range':'< 1.0.2'}]}}
        self.assertEqual(len(self.scan(self.advisory(),npm)['findings']),1)
    def test_unknown_range_requires_review_and_patched_version_not_flagged(self):
        self.assertEqual(self.scan(self.advisory(ran='before commit'))['findings'][0]['status'],'needs-review')
        self.assertEqual(self.scan(self.advisory(ran='< 1.0.0'))['findings'],[])

if __name__=='__main__':unittest.main()
