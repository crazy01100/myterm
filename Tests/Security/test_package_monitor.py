"""Project package query isolation. Synthetic metadata only; no exploit inputs."""
import copy
import datetime as dt
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
def load(name):
    s=importlib.util.spec_from_file_location(name,ROOT/'scripts'/f'{name}.py')
    m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
a=load('security-toolchain-advisories');p=load('security-toolchain-providers')

class PackageMonitorTests(unittest.TestCase):
    def setUp(self):
        self.inventory={'environment':'local','purpose':'audit','components':[
            {'collector':'python','ecosystem':'PyPI','name':'example','version':'1.0','origin':'python-runtime'},
            {'collector':'node','ecosystem':'npm','name':'example','version':'2.0.0','origin':'project-npm-tool'}],
            'coverage':[{'id':'python','status':'inventoried'},{'id':'node','status':'inventoried'},
                        {'id':'app','status':'inventoried'},{'id':'pillow','status':'not-applicable'}]}
        self.calls=[]
    def query(self,components):
        self.calls.append(components)
        return {'advisoryQueryStatus':'complete','checkedAt':dt.datetime.now(dt.timezone.utc).isoformat(),
                'componentDigest':a.component_digest(components),
                'findings':[{'id':'fixture','collector':components[0]['collector']}],
                'withdrawnAdvisories':[]}
    def test_failure_does_not_erase_other_domain_findings(self):
        def query(c):
            if c[0]['collector']=='python':raise TimeoutError('private content')
            return self.query(c)
        r=a.grouped_lookup(self.inventory,query)
        self.assertEqual(r['advisoryQueryStatus'],'failed')
        self.assertEqual(r['findings'],[{'id':'fixture','collector':'node'}])
        self.assertEqual(r['errors'],['python: TimeoutError'])
        self.assertFalse(r['closureEligible'])
    def test_empty_and_optional_domains_do_not_query_or_fake_success(self):
        r=a.grouped_lookup(self.inventory,self.query)
        self.assertEqual(len(self.calls),2)
        self.assertEqual([x['status'] for x in r['domains']],
                         ['complete','complete','not-package-enumerable','not-applicable'])
        self.assertFalse(r['allDependenciesScanned'])
    def test_unavailable_inventory_keeps_other_domains(self):
        self.inventory['coverage'][0]['status']='unavailable'
        r=a.grouped_lookup(self.inventory,self.query)
        self.assertEqual(len(self.calls),1);self.assertEqual(r['domains'][0]['status'],'unavailable')
        self.assertEqual(r['advisoryQueryStatus'],'failed')
    def test_filter_keeps_npm_origin_without_relabeling_python(self):
        r=a.grouped_lookup(self.inventory,self.query,include=lambda c:c['ecosystem']=='npm')
        self.assertEqual(r['domains'][0]['status'],'not-package-enumerable')
        self.assertEqual(self.calls[0][0]['origin'],'project-npm-tool')
    def test_foreign_digest_and_stale_query_fail_closed(self):
        for change in ({'componentDigest':'bad'},{'checkedAt':'2000-01-01T00:00:00+00:00'},
                       {'checkedAt':'2026-01-01T00:00:00'},{'findings':None}):
            with self.subTest(change=change):
                r=a.grouped_lookup(self.inventory,lambda c:{**self.query(c),**change})
                self.assertEqual(r['findings'],[]);self.assertEqual(r['advisoryQueryStatus'],'failed')
    def test_duplicate_or_unknown_domain_is_rejected(self):
        bad=copy.deepcopy(self.inventory);bad['coverage'].append(bad['coverage'][0])
        with self.assertRaises(ValueError):a.grouped_lookup(bad,self.query)
        bad=copy.deepcopy(self.inventory);bad['components'][0]['collector']='unknown'
        with self.assertRaises(ValueError):a.grouped_lookup(bad,self.query)
        self.assertEqual(self.calls,[])
    def test_scoped_provider_receipt_cannot_hide_other_domain_failure(self):
        r=a.grouped_lookup(self.inventory,lambda c:self.query(c) if c[0]['collector']=='node' else {})
        policy={'collectors':[{'id':n,'uses':['audit'],'advisorySources':['OSV']} for n in ('python','node')]}
        out=p.receipts(self.inventory,policy,r,{}, {},{})
        self.assertEqual([x['status'] for x in out],['needs-review','complete'])
        r['domains'][1]['observedEnvironment']='ci'
        self.assertEqual(p.receipts(self.inventory,policy,r,{}, {},{})[1]['status'],'needs-review')
    def test_complete_foreign_environment_does_not_supply_receipts(self):
        r=a.grouped_lookup(self.inventory,self.query)
        r['observedEnvironment']='ci'
        for d in r['domains']:d['observedEnvironment']='ci'
        policy={'collectors':[{'id':n,'uses':['audit'],'advisorySources':['OSV']} for n in ('python','node')]}
        self.assertEqual([x['status'] for x in p.receipts(self.inventory,policy,r,{}, {},{})],
                         ['needs-review','needs-review'])
    def test_monitor_frequency_and_regressions_remain_in_ci(self):
        monitor=(ROOT/'.github/workflows/security-checks.yml').read_text()
        self.assertIn("cron: '23 1,13 * * *'",monitor)
        self.assertNotIn('test:development-tools',monitor)
        self.assertNotIn('unittest discover',monitor)
        gate=(ROOT/'.github/workflows/security-gate.yml').read_text()
        self.assertIn('test:development-tools',gate)
        self.assertIn('unittest discover',gate)
    def test_github_results_retain_versions_and_actual_origins(self):
        audit=load('security-audit')
        advisory={'ghsa_id':'GHSA-test-test-test','severity':'high','html_url':'https://github.com/advisories/GHSA-test-test-test',
                  'vulnerabilities':[{'package':{'ecosystem':'npm','name':'example'},
                    'vulnerable_version_range':'< 3.0.0','first_patched_version':'3.0.0'}]}
        component={**self.inventory['components'][1],'origin':'action/fixture@commit',
                   'runtimeReachability':'not-established'}
        with patch.object(audit,'github_npm_advisories',return_value=[advisory]):
            result=audit.query_toolchain_github([component],'ci')
        f=result['findings'][0]
        self.assertEqual(f['status'],'needs-review');self.assertEqual(f['scope'],'github-actions')
        self.assertEqual(f['severity'],'high');self.assertEqual(f['fixedVersion'],'3.0.0')
        self.assertEqual(f['environmentObservations'],[{'environment':'ci','origin':component['origin'],'versions':['2.0.0']}])
    def test_github_does_not_reclassify_unaffected_versions(self):
        audit=load('security-audit')
        advisory={'ghsa_id':'fixture','severity':'high','html_url':'https://example.invalid',
                  'vulnerabilities':[{'package':{'ecosystem':'npm','name':'example'},'vulnerable_version_range':'< 1.0.0'}]}
        with patch.object(audit,'github_npm_advisories',return_value=[advisory]):
            result=audit.query_toolchain_github([self.inventory['components'][1]],'local')
        self.assertEqual(result['findings'],[])

if __name__=='__main__':unittest.main()
