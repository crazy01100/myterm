"""Inert metadata/content fixtures only; no TLS or vulnerability payloads."""
import copy
import gzip
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]

def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT/'scripts'/f'{name}.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module

s = load('security-openssl-supplier')
pip = load('security-pip-applicability')
audit = load('security-audit')

class SupplierTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.policy = json.loads((ROOT/s.CONFIG).read_text())
        self.p = self.policy['packages'][0]
        self.identifier = next(iter(self.p['fixes']))
        self.advisory = {'cveMetadata': {'cveId': self.identifier, 'state': 'PUBLISHED'}, 'containers': {'cna': {'title': 'fixture'}}}
        self.p['fixes'] = {self.identifier: {'fixedVersion': '3.5.5-1ubuntu3.4', 'advisorySHA256': s.digest(self.advisory)}}
        f = self.root/s.CONFIG; f.parent.mkdir(parents=True); f.write_text(json.dumps(self.policy))
        self.finding = {'id': self.identifier, 'component': 'OpenSSL', 'scope': 'development', 'version': '3.5.5',
                        'severity': 'high', 'status': 'needs-review', 'queryComplete': True,
                        'url': 'https://openssl-library.org/news/secjson/'+self.identifier.lower()+'.json',
                        'dependencyPaths': sorted(s.ORIGINS), 'environmentObservations': [
                            {'environment': 'ci', 'origin': o, 'versions': ['3.5.5']} for o in sorted(s.ORIGINS)]}
        self.proof = {'environments': [{'origin': x} for x in sorted(s.ORIGINS)], 'package': {'packageSHA256': 'a'*64, 'url': self.p['url']}}
        self.env = patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}); self.env.start(); self.addCleanup(self.env.stop)

    def report(self):
        return {'findings': [copy.deepcopy(self.finding)], 'rawFindings': [copy.deepcopy(self.finding)],
                'applicabilityReviews': [], 'observedEnvironment': 'ci', 'errors': []}

    def classify(self, report):
        with patch.object(s, 'verify_environments', return_value=self.proof):
            s.classify(report, self.root, lambda _: self.advisory)

    def test_raw_match_preserved_and_live_evidence_revalidated(self):
        r = self.report(); self.classify(r)
        self.assertEqual(r['findings'], []); self.assertEqual(r['rawFindings'], [self.finding])
        self.assertEqual(r['supplierFixReviews'][0]['status'], 'supplier-fixed')
        pip.validate_envelope(r)
        with patch.object(s, 'verify_environments', return_value=self.proof):
            s.revalidate(r, self.root, lambda _: self.advisory)
        with patch.object(s, 'verify_environments', side_effect=ValueError('drift')):
            with self.assertRaises(ValueError): s.revalidate(r, self.root, lambda _: self.advisory)

    def test_changed_cna_and_network_error_preserve_original_and_block(self):
        for fetch in (lambda _: {**self.advisory, 'changed': True}, lambda _: (_ for _ in ()).throw(OSError('offline'))):
            r = self.report()
            with patch.object(s, 'verify_environments', return_value=self.proof): s.classify(r, self.root, fetch)
            self.assertEqual(r['findings'], [self.finding]); self.assertTrue(r['errors'])
            self.assertTrue(audit.blocking(r, merge_gate=True))

    def test_unknown_origin_version_scope_and_cross_environment_never_excluded(self):
        for changes in ({'version': '3.5.4'}, {'scope': 'released-app'}, {'queryComplete': False},
                        {'id': 'CVE-2099-9999'}, {'dependencyPaths': ['action/fixture']},
                        {'environmentObservations': [{'environment': 'local', 'origin': o, 'versions': ['3.5.5']} for o in s.ORIGINS]}):
            r = self.report(); r['findings'][0].update(changes)
            with patch.object(s, 'verify_environments', side_effect=AssertionError('Must not prove other targets')):
                s.classify(r, self.root, lambda _: self.advisory)
            self.assertEqual(len(r['findings']), 1); self.assertFalse(r['supplierFixReviews'])

    def test_missing_loaded_identity_is_not_a_waiver(self):
        r = self.report()
        with patch.object(s, 'verify_environments', side_effect=ValueError('unmapped')):
            s.classify(r, self.root, lambda _: self.advisory)
        self.assertEqual(r['findings'], [self.finding]); self.assertTrue(r['errors'])

    def test_partition_cannot_drop_raw_matches(self):
        r = self.report(); self.classify(r); r['supplierFixReviews'] = []
        with self.assertRaises(ValueError): pip.validate_envelope(r)

    def test_closure_requires_this_cve_and_all_old_environments_and_origins(self):
        r = self.report(); self.classify(r)
        self.assertTrue(s.covers_previous(r, self.finding))
        for changes in ({'id': 'CVE-2099-9999'}, {'dependencyPaths': ['security-tools/cryptography-openssl']},
                        {'environmentObservations': []}, {'environmentObservations': [
                            {'environment': 'local', 'origin': 'python-runtime/openssl', 'versions': ['3.5.5']}]}):
            self.assertFalse(s.covers_previous(r, {**self.finding, **changes}))

    def test_changelog_requires_security_entry_and_exact_standalone_cve(self):
        text = f'openssl (3.5.5-1ubuntu3.4) resolute-security; urgency=medium\n\n  * SECURITY UPDATE: fixture\n    - {self.identifier}\n'
        self.assertEqual(s.changelog_fixes(text), {self.identifier: '3.5.5-1ubuntu3.4'})
        self.assertEqual(s.changelog_fixes(text.replace('SECURITY UPDATE:', 'NOTE:')), {})
        self.assertEqual(s.changelog_fixes(text.replace('    - '+self.identifier, '    - references '+self.identifier)), {})
        newer = text.replace('ubuntu3.4', 'ubuntu3.7')
        self.assertEqual(s.changelog_fixes(newer+text)[self.identifier], '3.5.5-1ubuntu3.7')

    def test_package_version_uses_dpkg_epoch_revision_not_lexical_order(self):
        for left, right, code in [('1:3.5.5-1ubuntu3.10', '1:3.5.5-1ubuntu3.9', 0),
                                  ('3.5.5-1ubuntu3.9', '1:3.5.5-1ubuntu3.4', 1),
                                  ('3.5.5-1ubuntu3.7~rc1', '3.5.5-1ubuntu3.7', 1)]:
            with patch.object(s.subprocess, 'run', return_value=subprocess.CompletedProcess([], code)) as call:
                self.assertEqual(s.version_ge(left, right), code == 0)
                self.assertEqual(call.call_args.args[0], ['/usr/bin/dpkg', '--compare-versions', left, 'ge', right])
        with self.assertRaises(ValueError): s.version_ge('--help', '1')

    def test_process_mapping_rejects_deleted_replaced_or_missing_libraries(self):
        paths = list(self.p['libraries']); dev = os.makedev(8, 1)
        stat = SimpleNamespace(st_ino=42, st_dev=dev, st_size=3, st_mtime_ns=1)
        maps = '\n'.join('1000-2000 r-xp 0 08:01 42 '+x for x in paths)
        self.assertEqual(s.loaded_libraries(maps, lambda _: stat, lambda _: b'abc'), {p: s.sha(b'abc') for p in paths})
        for text in (maps+' (deleted)', maps.replace(' 42 ', ' 43 '), maps.splitlines()[0]):
            with self.assertRaises(ValueError): s.loaded_libraries(text, lambda _: stat, lambda _: b'abc')

    def test_official_archive_members_must_match_loaded_hash_manifest(self):
        p = copy.deepcopy(self.p)
        ch = gzip.compress(f'openssl ({p["version"]}) resolute-security; urgency=medium\n  * SECURITY UPDATE: fixture\n    - {self.identifier}\n'.encode())
        p['changelogSHA256'] = s.sha(ch); p['fixes'][self.identifier]['fixedVersion'] = p['version']
        files = {k.lstrip('/'): b'abc' for k in p['libraries']}; files[p['changelogPath']] = ch
        p['libraries'] = {k: s.sha(b'abc') for k in p['libraries']}
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode='w') as archive:
            for name, raw in files.items():
                info = tarfile.TarInfo('./'+name); info.size = len(raw); archive.addfile(info, io.BytesIO(raw))
        with patch.object(s, 'package_cache', return_value=Path('/inert/package.deb')), \
             patch.object(s, 'command', return_value=output.getvalue()), patch.object(s, 'version_ge', return_value=True):
            self.assertEqual(s.verify_package(self.root, p)['packageSHA256'], p['sha256'])
            p['libraries'][next(iter(p['libraries']))] = '0'*64
            with self.assertRaises(ValueError): s.verify_package(self.root, p)

    def test_issue_resolves_only_complete_same_environment_fix_and_records_reason(self):
        from test_security_issues import FakeGitHub, ENV, report
        sync = load('sync-security-issues'); api = FakeGitHub()
        original = report(False); original.update(self.report())
        original.update(observedOrigins=sorted(s.ORIGINS), toolchainCoverage={'checksComplete': True},
                        originCoverage={o: {'closureEligible': False} for o in s.ORIGINS})
        sync.synchronize(original, api, True, ENV)
        fixed = copy.deepcopy(original); self.classify(fixed)
        self.assertEqual(sync.synchronize(fixed, api, True, ENV)[0]['action'], 'resolve')
        self.assertEqual(api.issues[0]['state'], 'closed')
        self.assertIn('官方供應商封裝', api.comments[0]['body'])
        self.assertEqual(sync.synchronize(fixed, api, True, ENV), [])
        self.assertEqual(len(api.comments), 1)

    def test_partial_report_or_previous_local_observation_never_closes(self):
        from test_security_issues import FakeGitHub, ENV, report
        sync = load('sync-security-issues')
        for extra_local in (False, True):
            api = FakeGitHub(); original = report(False); original.update(self.report())
            if extra_local:
                original['findings'][0]['environmentObservations'].append(
                    {'environment': 'local', 'origin': 'python-runtime/openssl', 'versions': ['3.5.5']})
                original['rawFindings'] = copy.deepcopy(original['findings'])
            sync.synchronize(original, api, True, ENV)
            fixed = report(False); fixed.update(self.report()); self.classify(fixed)
            fixed.update(observedOrigins=sorted(s.ORIGINS), toolchainCoverage={'checksComplete': True},
                         originCoverage={o: {'closureEligible': False} for o in s.ORIGINS})
            if not extra_local:
                fixed.update(scanStatus='failed', errors=['metadata unavailable'], publicationMode='additive',
                             sourceReview={'sourceVerified': True, 'grantsRiskException': False, 'policySHA256': 'a'*64})
            sync.synchronize(fixed, api, True, ENV)
            self.assertEqual(api.issues[0]['state'], 'open')
            self.assertEqual(api.comments, [])

    def test_cached_package_hash_drift_and_links_are_rejected(self):
        cache = self.root/'.build/openssl-supplier'; cache.mkdir(parents=True)
        target = cache/(self.p['sha256']+'.deb'); target.write_bytes(b'changed')
        with self.assertRaises(ValueError): s.package_cache(self.root, self.p)
        target.unlink(); target.symlink_to(self.root/s.CONFIG)
        with self.assertRaises(ValueError): s.package_cache(self.root, self.p)

    def test_non_linux_probe_does_not_enumerate_platform_or_packages(self):
        with patch.object(s.sys, 'platform', 'darwin'), patch.object(s, 'command', side_effect=AssertionError('No commands')):
            self.assertEqual(s.probe()['status'], 'not-applicable')

if __name__ == '__main__': unittest.main()
