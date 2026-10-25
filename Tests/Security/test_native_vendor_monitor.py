"""Native/feed metadata fixtures only; no services or vulnerability payloads."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT/'scripts'/f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


n = load('security-native-advisories')
v = load('security-vendor-notices')
p = load('setup-project-python')


class NativeAdvisoryTests(unittest.TestCase):
    def fixture(self):
        inventory = {'environment': 'local', 'coverage': [
            {'id': 'python', 'evidence': [
                {'component': 'openssl', 'vendorVersion': 'OpenSSL 3.5.8 fixture', 'role': 'python-runtime'},
                {'component': 'openssl', 'vendorVersion': 'OpenSSL 3.5.9 fixture', 'role': 'security-tools'},
                {'component': 'cryptography-openssl', 'vendorVersion': 'OpenSSL 4.0.3 fixture', 'role': 'security-tools'}]}]}
        record = {'cveMetadata': {'cveId': 'CVE-2099-1234', 'state': 'PUBLISHED'},
                  'containers': {'cna': {'title': 'Metadata fixture', 'metrics': [], 'affected': [
                      {'vendor': 'OpenSSL', 'product': 'OpenSSL', 'defaultStatus': 'unaffected',
                       'versions': [{'version': '3.5.0', 'lessThan': '3.5.9', 'status': 'affected', 'versionType': 'semver'}]}]}}}
        return inventory, record

    def fetcher(self, record):
        return lambda url: copy.deepcopy(record) if url.endswith('.json') else '<a href="#CVE-2099-1234">fixture</a>'

    def test_patch_boundary_and_each_native_origin_are_kept_separate(self):
        inventory, record = self.fixture()
        result = n.scan_openssl(inventory, self.fetcher(record))
        self.assertEqual(result['queriedAdvisories'], 1)
        self.assertEqual(len(result['findings']), 1)
        found = result['findings'][0]
        self.assertEqual(found['version'], '3.5.8')
        self.assertEqual(found['fixedVersion'], '3.5.9')
        self.assertEqual(found['dependencyPaths'], ['python-runtime/openssl'])
        self.assertEqual(found['status'], 'needs-review')
        self.assertEqual(found['severity'], 'unknown')

    def test_missing_index_rejected_not_interpreted_as_zero_advisories(self):
        inventory, _ = self.fixture()
        with self.assertRaises(ValueError):
            n.scan_openssl(inventory, lambda _: '<html>maintenance</html>')

    def test_changed_identity_state_or_default_status_blocks(self):
        inventory, original = self.fixture()
        for field, value in [('state', 'REJECTED'), ('cveId', 'CVE-2099-9999')]:
            record = copy.deepcopy(original); record['cveMetadata'][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                n.scan_openssl(inventory, self.fetcher(record))
        record = copy.deepcopy(original)
        record['containers']['cna']['affected'][0]['defaultStatus'] = 'unknown'
        with self.assertRaises(ValueError): n.scan_openssl(inventory, self.fetcher(record))

    def test_inclusive_ranges_legacy_branches_and_unknown_syntax(self):
        row = {'version': '3.5.0', 'lessThanOrEqual': '3.5.8', 'status': 'affected'}
        self.assertTrue(n.openssl_range('3.5.8', row))
        self.assertFalse(n.openssl_range('3.5.9', row))
        self.assertFalse(n.openssl_range('3.5.8', {'version': '1.0.2a', 'lessThan': '1.0.2z', 'status': 'affected'}))
        for change in ({'changes': [{}]}, {'versionType': 'custom'}, {'status': 'unknown'}, {'lessThanOrEqual': '*'}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                n.openssl_range('3.5.8', {**row, **change})

    def test_conflicting_affected_ranges_block(self):
        inventory, record = self.fixture()
        ranges = record['containers']['cna']['affected'][0]['versions']
        ranges.append({**ranges[0], 'status': 'unaffected'})
        with self.assertRaises(ValueError): n.scan_openssl(inventory, self.fetcher(record))


class OfficialNoticeTests(unittest.TestCase):
    def feed(self, identifier='python-blog', body='Original text', title='Official update'):
        urls = {'python-blog': 'https://blog.python.org/2099/01/update.html',
                'node-blog': 'https://nodejs.org/en/blog/release/fixture',
                'firebase-releases': 'https://github.com/firebase/firebase-tools/releases/tag/v1',
                'firestore-releases': 'https://docs.cloud.google.com/firestore/docs/release-notes#fixture',
                'cryptography-releases': 'https://github.com/pyca/cryptography/releases/tag/v1'}
        return (f'<feed xmlns="http://www.w3.org/2005/Atom"><entry><title>{title}</title>'
                f'<link rel="alternate" href="{urls[identifier]}"/><published>2099-01-01T00:00:00Z</published>'
                f'<content>{body}</content></entry></feed>').encode()

    def test_amended_notice_is_detected_without_cve_or_new_url(self):
        old = v.entries(self.feed(), 'python-blog')
        new = v.entries(self.feed(body='Correction'), 'python-blog')
        self.assertEqual(old[0]['id'], new[0]['id'])
        self.assertEqual(len(v.compare(new, old)['changes']), 1)
        self.assertNotIn('body', new[0])

    def test_feed_rollover_is_not_resolution(self):
        old = v.entries(self.feed(), 'python-blog')
        self.assertTrue(v.compare([{**old[0], 'id': 'a'*64}], old)['historyGap'])
        self.assertFalse(v.compare(old, old)['changes'])
        with self.assertRaises(ValueError): v.compare(old, old+old)

    def test_entities_wrong_provider_and_duplicate_items_rejected(self):
        good = self.feed()
        item = good[good.index(b'<entry>'):good.index(b'</entry>')+len(b'</entry>')]
        bad = [b'<!DOCTYPE feed [<!ENTITY x "inert">]>'+good,
               good.replace(b'blog.python.org', b'example.invalid'),
               good.replace(b'</feed>', item+b'</feed>')]
        for raw in bad:
            with self.subTest(raw=raw[:50]), self.assertRaises(ValueError): v.entries(raw, 'python-blog')

    def test_one_unavailable_feed_retains_other_sources_and_pending_baseline_blocks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); cfg = root/v.CONFIG; cfg.parent.mkdir(parents=True)
            policy = {'schemaVersion': 1, 'sources': {
                key: {'state': 'reviewed', 'entries': v.entries(self.feed(key), key)} for key in v.SOURCES}}
            cfg.write_text(json.dumps(policy))
            def fetch(key):
                if key == 'node-blog': raise OSError('fixture unavailable')
                return self.feed(key)
            result = v.scan(root, fetch)
            self.assertFalse(result['checksComplete']); self.assertEqual(len(result['sources']), len(v.SOURCES)-2)
            policy['sources']['python-blog']['state'] = 'pending'; cfg.write_text(json.dumps(policy))
            self.assertFalse(v.scan(root, self.feed)['checksComplete'])

    def test_firestore_updated_timestamp_and_exact_page(self):
        raw=self.feed('firestore-releases').replace(b'published>',b'updated>')
        self.assertEqual(v.entries(raw,'firestore-releases')[0]['publishedAt'],'2099-01-01T00:00:00Z')
        with self.assertRaises(ValueError):
            v.entries(raw.replace(b'/firestore/docs/release-notes',b'/unrelated'),'firestore-releases')

    def test_pending_cursor_cannot_suppress_unchanged_initial_notices(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);cfg=root/v.CONFIG;cfg.parent.mkdir(parents=True)
            policy={'schemaVersion':1,'sources':{key:{'state':'reviewed','entries':v.entries(self.feed(key),key)} for key in v.SOURCES}}
            policy['sources']['python-blog']['state']='pending'
            cfg.write_text(json.dumps(policy))
            result=v.scan(root,self.feed)
            self.assertFalse(result['checksComplete'])
            self.assertTrue(result['requiresNoticeReview'])
            self.assertEqual(result['changes'],[])
            self.assertEqual(result['sources'][0]['reviewState'],'pending')
            self.assertEqual(len(result['sources'][0]['observedDigest']),64)
            # Only an explicit exact review removes the unchanged notice.
            policy['sources']['python-blog']['state']='reviewed';cfg.write_text(json.dumps(policy))
            self.assertEqual(v.scan(root,self.feed)['changes'],[])

    def test_unknown_baseline_state_is_not_treated_as_reviewed(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);cfg=root/v.CONFIG;cfg.parent.mkdir(parents=True)
            cfg.write_text(json.dumps({'schemaVersion':1,'sources':{key:{'state':'accepted-by-default','entries':[]} for key in v.SOURCES}}))
            result=v.scan(root,self.feed)
            self.assertFalse(result['checksComplete'])
            self.assertEqual(result['sources'],[])

    def test_partial_review_survives_source_edits_without_hiding_new_notices(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);cfg=root/v.CONFIG;cfg.parent.mkdir(parents=True)
            scope=root/'scope';scope.write_bytes(b'local-only')
            policy={'schemaVersion':1,'sources':{key:{'state':'reviewed','entries':v.entries(self.feed(key),key)} for key in v.SOURCES}}
            policy['sources']['firebase-releases'].update(entries=[],sourceBindings={'scope':hashlib.sha256(scope.read_bytes()).hexdigest()})
            cfg.write_text(json.dumps(policy));result=v.scan(root,self.feed)
            self.assertTrue(result['checksComplete']);self.assertTrue(result['requiresNoticeReview'])
            self.assertEqual([r['source'] for r in result['changes']],['firebase-releases'])
            scope.write_bytes(b'cloud-enabled');result=v.scan(root,self.feed)
            self.assertTrue(result['checksComplete'])
            self.assertEqual([r['source'] for r in result['changes']],['firebase-releases'])


class FirestoreSupplierTests(unittest.TestCase):
    def fixture(self):
        provider=load('security-toolchain-providers')
        policy=json.loads((ROOT/'Config/Security/toolchain-inventory.json').read_text())
        boundary=next(r for r in policy['supplierBoundaries'] if r['component']=='firestore-emulator')
        evidence={**boundary,'source':boundary['url'],'boundaryId':boundary['id'],'allDependenciesScanned':False,'coverageStatus':'supplier-managed-limited'}
        inventory={'environment':'fixture','coverage':[{'id':'emulator','status':'supplier-managed-limited','evidence':[evidence]}]}
        return provider,policy,inventory

    def test_empty_official_query_is_not_full_child_coverage(self):
        provider,policy,inventory=self.fixture()
        receipt,findings=provider.firestore_notices(inventory,policy,[])
        self.assertEqual(receipt['status'],'complete');self.assertEqual(findings,[])
        self.assertFalse(receipt['allDependenciesScanned'])
        self.assertEqual(receipt['coverageDigest'],provider.digest(inventory['coverage'][0]))

    def test_artifact_drift_or_unaccepted_boundary_rejected(self):
        for field,value in [('sha256','0'*64),('version','1.99.0'),('allDependenciesScanned',True)]:
            provider,policy,inventory=self.fixture();inventory['coverage'][0]['evidence'][0][field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):provider.firestore_notices(inventory,policy,[])
        provider,policy,inventory=self.fixture();policy['supplierBoundaries'][0]['state']='pending'
        with self.assertRaises(ValueError):provider.firestore_notices(inventory,policy,[])

    def test_new_parent_advisory_blocks_even_low_severity(self):
        provider,policy,inventory=self.fixture()
        _,findings=provider.firestore_notices(inventory,policy,[{'ghsa_id':'GHSA-aaaa-bbbb-cccc','severity':'low'}])
        self.assertEqual(findings[0]['status'],'needs-review')
        self.assertTrue(load('security-audit').blocking({'findings':findings,'errors':[]}))

    def test_malformed_duplicate_or_invalid_withdrawal_rejected(self):
        provider,policy,inventory=self.fixture();advisory={'ghsa_id':'GHSA-aaaa-bbbb-cccc'}
        for data in (None,[None],[{}],[advisory,advisory],[{**advisory,'withdrawn_at':'tomorrow'}],[{**advisory,'withdrawn_at':'2099-01-01T00:00:00+00:00'}]):
            with self.subTest(data=data),self.assertRaises((ValueError,TypeError)):
                provider.firestore_notices(inventory,policy,data)


class PythonBaseTests(unittest.TestCase):
    def test_only_approved_artifact_identity_is_accepted(self):
        original = p.configuration(ROOT)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); cfg = root/p.CONFIG; cfg.parent.mkdir(parents=True)
            for change in ({'url': 'https://example.invalid/python.tgz'}, {'pythonVersion': '3.13.1'}, {'size': 0}):
                cfg.write_text(json.dumps({**original, **change}))
                with self.subTest(change=change), self.assertRaises(ValueError): p.configuration(root)

    def test_archive_hash_and_size_required_before_any_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'fixture'; path.write_bytes(b'ordinary fixture')
            row = {'size': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
            p.verify_archive(path, row)
            for change in ({'size': 1}, {'sha256': '0'*64}):
                with self.assertRaises(ValueError): p.verify_archive(path, {**row, **change})

    def test_version_probe_rejects_old_or_unmapped_openssl(self):
        policy = p.configuration(ROOT)
        for tls in ('OpenSSL 3.5.8 fixture', 'LibreSSL 3.5.9', 'OpenSSL 5.0.0 fixture'):
            with patch.object(p.subprocess, 'run', return_value=SimpleNamespace(stdout=json.dumps({
                    'python': policy['pythonVersion'], 'openssl': tls, 'base': '/fixture'}))):
                with self.subTest(tls=tls), self.assertRaises(ValueError): p.probe('/fixture/python', policy)


class AuditProviderIsolationTests(unittest.TestCase):
    def test_package_failure_preserves_native_and_notice_results_but_blocks_gate(self):
        audit = load('security-audit')
        observed = {'environment':'local', 'components':[], 'coverage':[]}
        finding = {'id':'CVE-2099-1234', 'component':'OpenSSL', 'version':'3.5.8',
                   'scope':'development','severity':'high','status':'needs-review'}
        native = {'findings':[finding], 'sources':[{'origin':'python-runtime/openssl','collector':'python'}]}
        notices = {'changes':[{'title':'Update', 'url':'https://blog.python.org/update'}],
                   'requiresNoticeReview':True,'checksComplete':True,'errors':[]}
        def unavailable(_): raise OSError('fixture offline')
        modules = {
            'security-toolchain-inventory': SimpleNamespace(inventory=lambda *a,**k:observed, configuration=lambda _:{}),
            'security-toolchain-advisories': SimpleNamespace(lookup=unavailable),
            'security-toolchain-report': SimpleNamespace(summarize=lambda *a:{'errors':['incomplete'], 'checksComplete':False,'coverage':[]}),
            'security-toolchain-providers': SimpleNamespace(receipts=lambda *a:[],bind_parents=lambda *a:{},
                firestore_notices=lambda *a:({'status':'complete','allDependenciesScanned':False},[])),
            'security-native-advisories': SimpleNamespace(scan_openssl=lambda _:native),
            'security-vendor-notices': SimpleNamespace(scan=lambda _:notices),
        }
        def spec(name, _): return SimpleNamespace(name=name, loader=SimpleNamespace(exec_module=lambda _:None))
        report = {'findings':[], 'errors':[]}
        with patch.object(audit.importlib.util,'spec_from_file_location',side_effect=spec), \
                patch.object(audit.importlib.util,'module_from_spec',side_effect=lambda s:modules[s.name]), \
                patch.object(audit,'repository_advisories',return_value=[]):
            audit.scan_toolchain(report)
        self.assertEqual(report['findings'],[{**finding,'queryComplete':True}])
        self.assertTrue(report['vendorNotices']['requiresNoticeReview'])
        self.assertIn('python-runtime/openssl',report['observedOrigins'])
        self.assertIn('emulator/firestore',report['observedOrigins'])
        self.assertFalse(report['originCoverage']['emulator/firestore']['closureEligible'])
        self.assertTrue(audit.blocking(report))

    def test_official_notice_without_cve_requires_review(self):
        audit=load('security-audit')
        self.assertTrue(audit.blocking({'findings':[],'errors':[],
                                      'vendorNotices':{'requiresNoticeReview':True}}))


class PlatformIdentityTests(unittest.TestCase):
    def test_platform_collects_project_cli_without_reading_os_or_java(self):
        collector=load('security-toolchain-inventory')
        with patch.object(collector,'collect_project_gh',return_value=([],[{'component':'github-cli-build'}],Path('/fixture/gh'))), \
                patch.object(collector.subprocess,'run',side_effect=AssertionError('No OS/Java probe')):
            rows,evidence=collector.collect_platform(ROOT)
        self.assertEqual(evidence,[{'component':'github-cli-build'}])


if __name__ == '__main__':
    unittest.main()
