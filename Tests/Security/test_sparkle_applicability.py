"""Metadata/lifecycle and inert, freshly signed ZIP fixtures; no updater runs."""
import base64
import copy
import datetime as dt
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT/path)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


m = module('sparkle_review_tests', 'scripts/security-sparkle-applicability.py')
s = module('sparkle_issue_tests', 'scripts/sync-security-issues.py')
fixtures = module('sparkle_inert_fixtures', 'Tests/Security/test_signed_release.py')
issue_tests = module('sparkle_issue_fixtures', 'Tests/Security/test_security_issues.py')
v = fixtures.v
ENV = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': m.REPO,
       'GITHUB_EVENT_NAME': 'schedule', 'GITHUB_REF': 'refs/heads/main'}


class API(issue_tests.FakeGitHub):
    def request(self, path, method='GET', payload=None):
        if method == 'GET' and path.startswith('issues/'):
            return copy.deepcopy(next(i for i in self.issues if i['number'] == int(path.split('/')[1])))
        return super().request(path, method, payload)


class SparkleTests(unittest.TestCase):
    def setUp(self):
        self.f = fixtures.ReleaseTests(); self.f.setUp(); self.addCleanup(self.f.doCleanups)
        self.root = self.f.root
        for name in m.SOURCE_FILES:
            dest = self.root/name; dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT/name, dest)
        (self.root/'Config/Release/SparklePublicKey.txt').write_text(self.f.pub+'\n')
        self.policy = json.loads((ROOT/m.CONFIG).read_text())
        self.advisory = {'ghsa_id': m.ID, 'html_url': 'https://github.com/'+m.COMPONENT+'/security/advisories/'+m.ID,
                         'description': 'Synthetic reviewed package-only advisory', 'summary': 'Fixture',
                         'severity': 'medium', 'withdrawn_at': None, 'vulnerabilities': [{'vulnerable_version_range': 'All'}]}
        self.policy['advisorySHA256'] = m.advisory_digest(self.advisory)
        self.policy['publicKeySHA256'] = m.sha((self.root/'Config/Release/SparklePublicKey.txt').read_bytes())
        self.policy['sourceSHA256'] = {n: m.sha((self.root/n).read_bytes()) for n in sorted(m.SOURCE_FILES)}
        self.write_policy()
        self.info = {'CFBundleIdentifier': m.BUNDLE, 'CFBundleShortVersionString': self.f.version,
                     'CFBundleVersion': self.f.build, 'SURequireSignedFeed': True,
                     'SUVerifyUpdateBeforeExtraction': True, 'SUFeedURL': m.BASE_URL+'/appcast.xml',
                     'SUPublicEDKey': self.f.pub}
        self.zip_extra = {}; self.install_type = None; self.make_assets()
        self.real_load = s.load

    def write_policy(self):
        p = self.root/m.CONFIG; p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(self.policy))

    def make_assets(self):
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as z:
            z.writestr('MyTerm.app/Contents/Info.plist', plistlib.dumps(self.info))
            z.writestr('MyTerm.app/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist',
                       plistlib.dumps({'CFBundleIdentifier': 'org.sparkle-project.Sparkle', 'CFBundleShortVersionString': m.VERSION}))
            for name, raw in self.zip_extra.items(): z.writestr(name, raw)
        (self.f.assets/self.f.archive).write_bytes(data.getvalue())
        self.f.dependencies = [{'name': 'https://github.com/'+m.COMPONENT, 'version': m.VERSION, 'revision': m.REVISION}]
        tree = ET.fromstring(self.f.content); item = tree.find('channel/item'); enclosure = item.find('enclosure')
        enclosure.set('url', m.BASE_URL+'/downloads/'+self.f.archive)
        enclosure.set('length', str(len(data.getvalue()))); enclosure.set(v.SP+'edSignature', self.f.sig(data.getvalue()))
        if self.install_type: enclosure.set(v.SP+'installationType', self.install_type)
        item.find(v.SP+'releaseNotesLink').text = m.BASE_URL+'/releases/'+self.f.version+'.html'
        item.find(v.MT+'dependencies').text = json.dumps(self.f.dependencies)
        self.f.content = ET.tostring(tree); self.f.sign_feed(); self.f.hashes()
        manifest_path = self.f.assets/'release-manifest.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['downloadURL'] = m.BASE_URL+'/downloads/'+self.f.archive
        manifest_path.write_text(json.dumps(manifest)); self.f.checksums()
        self.release = {'id': 123, 'tag_name': 'v'+self.f.version, 'draft': False, 'prerelease': False,
            'assets': [{'id': i+1, 'name': p.name, 'size': p.stat().st_size, 'updated_at': '2026-01-01T00:00:00Z'}
                       for i, p in enumerate(sorted(self.f.assets.iterdir()))]}

    def verify_command(self, command, **kwargs):
        # Run the real existing signature verifier in process with fixture keys;
        # no installer, shell script, network or released App is executed.
        if command[:2] == ['git', 'rev-parse']:
            return subprocess.CompletedProcess(command, 0, self.f.commit+'\n', '')
        path = Path(command[command.index('--assets')+1])
        result = v.verify(path, self.f.pub, self.f.version, m.BASE_URL, self.f.build, self.f.commit)
        return subprocess.CompletedProcess(command, 0, json.dumps(result).encode(), b'')

    def read(self, path):
        if '/security-advisories/' in path: return copy.deepcopy(self.advisory)
        if path.endswith('/releases/latest'): return copy.deepcopy(self.release)
        if '/commits/' in path: return {'sha': self.f.commit}
        raise AssertionError(path)

    def fetch(self, asset): return (self.f.assets/asset['name']).read_bytes()

    def finding(self, scope):
        return {'id': m.ID, 'component': m.COMPONENT, 'scope': scope, 'version': m.VERSION,
                'status': 'needs-review', 'severity': 'medium', 'queryComplete': True,
                'url': self.advisory['html_url'], **({'releaseTag': 'v'+self.f.version} if scope == 'released-app' else {})}

    def report(self, include=True):
        findings = [self.finding('current-source')] + ([self.finding('released-app')] if include else [])
        return {'schemaVersion': 1, 'checkedAt': dt.datetime.now(dt.timezone.utc).isoformat(),
                'scanStatus': 'complete', 'errors': [], 'findings': findings,
                'applicabilityReviews': [], 'projectApplicabilityReviews': [], 'supplierFixReviews': [],
                'sparkleReleaseRequested': include, 'releaseTag': 'v'+self.f.version,
                'sourceReview': {'sourceVerified': True, 'grantsRiskException': False, 'policySHA256': 'a'*64,
                                 'checkoutCommit': self.f.commit}}

    def classify(self, report):
        with patch.object(m.subprocess, 'run', side_effect=self.verify_command):
            m.classify(report, self.root, self.read, self.fetch)

    def evaluate(self, report):
        with patch.object(m.subprocess, 'run', side_effect=self.verify_command):
            return m.evaluate(report, self.root, self.read, self.fetch)

    def api(self):
        api = API()
        for scope, number in m.SCOPES.items():
            f = self.finding(scope); key = s.digest([f[k] for k in ('id', 'component', 'scope')])
            title, body = s.render(key, f, self.report())
            api.issues.append({'number': number, 'title': title, 'body': body, 'state': 'open', 'user': {'login': s.BOT}})
        return api

    def test_independent_source_and_authenticated_release(self):
        r = self.report(); raw = copy.deepcopy(r['findings']); self.classify(r)
        self.assertEqual(r['errors'], []); self.assertEqual(r['findings'], []); self.assertEqual(r['rawFindings'], raw)
        self.assertEqual(len(r['sparkleApplicabilityReviews']), 2)
        m.validate_envelope(r); s.validate_report(r)
        r = json.loads(json.dumps(r))
        with patch.object(m.subprocess, 'run', side_effect=self.verify_command):
            m.revalidate(r, self.root, self.read, self.fetch)

    def test_source_condition_drift_does_not_borrow_release(self):
        (self.root/'scripts/build-app.sh').write_text('changed standard build')
        r = self.report(); self.classify(r)
        self.assertEqual([f['scope'] for f in r['findings']], ['current-source'])
        self.assertEqual(r['sparkleApplicability']['outcomes'][1]['status'], 'not-affected')

    def test_released_plist_drift_does_not_borrow_source(self):
        self.info['SURequireSignedFeed'] = False; self.make_assets()
        r = self.report(); self.classify(r)
        self.assertEqual([f['scope'] for f in r['findings']], ['released-app'])

    def test_lab_wrong_key_product_and_extraction_flags_fail(self):
        for change in [{'MyTermUpdateLabMode': True}, {'CFBundleIdentifier': 'other.app'},
                       {'SUPublicEDKey': 'other'}, {'SURequireSignedFeed': 1},
                       {'SUVerifyUpdateBeforeExtraction': False}, {'SUFeedURL': 'https://other.test/feed'}]:
            with self.subTest(change=change):
                old = self.info.copy(); self.info.update(change); self.make_assets()
                self.assertEqual(self.evaluate(self.report())['outcomes'][1]['status'], 'needs-review')
                self.info = old

    def test_pkg_and_unsafe_archive_shape_fail_even_when_signed(self):
        for name in ['MyTerm.app/Contents/old.pkg', 'Other.app/Contents/Info.plist', '../escape', '/absolute']:
            with self.subTest(name=name):
                self.zip_extra = {name: b'inert metadata fixture'}; self.make_assets()
                self.assertEqual(self.evaluate(self.report())['outcomes'][1]['status'], 'needs-review')

    def test_signed_package_installation_type_rejected(self):
        self.install_type = 'package'; self.make_assets()
        self.assertEqual(self.evaluate(self.report())['outcomes'][1]['status'], 'needs-review')

    def test_changed_archive_and_feed_signatures_rejected(self):
        for name in [self.f.archive, 'appcast.xml']:
            p = self.f.assets/name; raw = p.read_bytes(); p.write_bytes(raw+b'changed')
            self.release['assets'] = [{**a, 'size': (self.f.assets/a['name']).stat().st_size} for a in self.release['assets']]
            self.assertEqual(self.evaluate(self.report())['outcomes'][1]['status'], 'needs-review')
            p.write_bytes(raw); self.make_assets()

    def test_missing_extra_assets_and_moved_tag_rejected(self):
        original = copy.deepcopy(self.release)
        for change in [{'assets': self.release['assets'][:-1]}, {'draft': True}, {'prerelease': True}, {'tag_name': 'v8.8.8'}]:
            self.release = {**copy.deepcopy(original), **change}
            self.assertEqual(self.evaluate(self.report())['outcomes'][1]['status'], 'needs-review')

    def test_tag_changes_during_download_cannot_pass(self):
        reads = [0]
        def read(path):
            if path.endswith('/commits/v'+self.f.version):
                reads[0] += 1; return {'sha': self.f.commit if reads[0] == 1 else 'b'*40}
            return self.read(path)
        with patch.object(m.subprocess, 'run', side_effect=self.verify_command):
            result = m.evaluate(self.report(), self.root, read, self.fetch)
        self.assertEqual(result['outcomes'][1]['status'], 'needs-review')

    def test_advisory_changed_withdrawn_or_unavailable_invalidates(self):
        for field, value in [('description', 'new conditions'), ('withdrawn_at', '2026-11-17T00:00:00Z')]:
            old = self.advisory.copy(); self.advisory[field] = value
            self.assertTrue(all(r['status'] == 'needs-review' for r in self.evaluate(self.report())['outcomes']))
            self.advisory = old
        result = m.evaluate(self.report(), self.root, lambda _: (_ for _ in ()).throw(OSError('offline')))
        self.assertTrue(all(r['status'] == 'needs-review' for r in result['outcomes']))

    def test_unrelated_observations_and_unknown_versions_are_preserved(self):
        r = self.report(); extra = [{**self.finding('current-source'), **change} for change in
            [{'id': 'GHSA-other'}, {'component': 'other/package'}, {'scope': 'development'},
             {'version': '2.11.0-beta.1'}, {'queryComplete': False}]]
        r['findings'] = extra.copy(); self.classify(r)
        self.assertEqual(r['findings'], extra)

    def test_scope_tag_and_proof_substitution_cannot_close(self):
        r = self.report(); self.classify(r)
        for f in [{**self.finding('released-app'), 'releaseTag': 'v1.0.0'},
                  {**self.finding('released-app'), 'version': '2.11.0'}]:
            self.assertIsNone(m.previous_decision(r, f))
        bad = copy.deepcopy(r); bad['sparkleApplicability']['outcomes'][0]['scope'] = 'released-app'
        with self.assertRaises(ValueError): m.validate_envelope(bad)
        bad = copy.deepcopy(r); bad['sparkleApplicabilityReviews'][0]['finding']['component'] = 'other'
        with self.assertRaises(ValueError): m.validate_envelope(bad)
        bad = copy.deepcopy(r); bad['sparkleApplicabilityReviews'] = []
        with self.assertRaises(ValueError): s.validate_report(bad)
        bad = copy.deepcopy(r); del bad['sparkleApplicability']
        with self.assertRaises(ValueError): s.validate_report(bad)

    def test_close_once_then_reopen_original_after_drift(self):
        r = self.report(); self.classify(r); api = self.api()
        actions = s.synchronize(r, api, True, ENV)
        self.assertEqual([a['action'] for a in actions], ['close-not-applicable']*2)
        self.assertEqual(s.synchronize(r, api, True, ENV), [])
        (self.root/'scripts/build-app.sh').write_text('changed build')
        current = self.evaluate(r)
        changes = s.reopen_sparkle(r, current, api, apply=True, environ=ENV)
        self.assertEqual([a['number'] for a in changes], [217])
        self.assertEqual([i['state'] for i in api.issues], ['open', 'closed'])
        self.assertEqual(s.reopen_sparkle(r, current, api, apply=True, environ=ENV), [])
        self.assertEqual(len(api.issues), 2)

    def test_failure_reopens_but_never_creates_or_closes_other_issue(self):
        r = self.report(); self.classify(r); api = self.api(); s.synchronize(r, api, True, ENV)
        api.issues.append({'number': 999, 'state': 'open', 'title': 'other', 'body': 'untouched'})
        current = copy.deepcopy(r['sparkleApplicability'])
        for row in current['outcomes']: row.update(status='needs-review', reason='evidence unavailable')
        changed = s.reopen_sparkle(r, current, api, apply=True, environ=ENV)
        self.assertEqual([x['number'] for x in changed], [217, 218])
        self.assertEqual(api.issues[-1]['body'], 'untouched')

    def test_untrusted_owner_number_context_or_missing_marker_cannot_reopen(self):
        r = self.report(); self.classify(r); api = self.api(); s.synchronize(r, api, True, ENV)
        current = copy.deepcopy(r['sparkleApplicability'])
        for row in current['outcomes']: row.update(status='needs-review', reason='unavailable')
        for env in [{}, {**ENV, 'GITHUB_EVENT_NAME': 'pull_request'}, {**ENV, 'GITHUB_REPOSITORY': 'other/repo'}]:
            with self.assertRaises(ValueError): s.reopen_sparkle(r, current, api, apply=True, environ=env)
        api.issues[0]['user']['login'] = 'human'; api.issues[1]['body'] = 'unrecognized'
        self.assertEqual(s.reopen_sparkle(r, current, api, apply=True, environ=ENV), [])

    def test_write_failure_remains_failure_and_retry_deduplicates(self):
        r = self.report(); self.classify(r); api = self.api(); s.synchronize(r, api, True, ENV)
        current = copy.deepcopy(r['sparkleApplicability'])
        current['outcomes'][0].update(status='needs-review', reason='unavailable')
        api.fail_patch = True
        with self.assertRaises(RuntimeError): s.reopen_sparkle(r, current, api, apply=True, environ=ENV)
        count = len(api.comments); api.fail_patch = False
        s.reopen_sparkle(r, current, api, apply=True, environ=ENV)
        self.assertEqual(len(api.comments), count)

    def test_scan_receipt_cannot_survive_source_drift(self):
        r = self.report(); self.classify(r)
        (self.root/'scripts/build-app.sh').write_text('different')
        with patch.object(m.subprocess, 'run', side_effect=self.verify_command), self.assertRaises(ValueError):
            m.revalidate(r, self.root, self.read, self.fetch)

    def test_actual_delivery_cannot_borrow_source_or_other_build(self):
        r = self.report(); r['findings'] = [{**self.finding('current-source'), 'scope': 'delivery-app'}]
        with patch.object(m.subprocess, 'run', side_effect=self.verify_command):
            proof = m.asset_evidence(self.root, self.f.assets, self.policy, version=self.f.version, build=self.f.build, commit=self.f.commit)
        ctx = {'stage': 'publish', 'version': self.f.version, 'build': self.f.build, 'releaseCommit': self.f.commit,
               'assetHashes': proof['hashes'], 'deliveryInventory': proof['dependencies'], 'sparkleDeliveryEvidence': proof}
        self.assertEqual(len(m.delivery_decision(r, ctx, self.root, self.read)), 1)
        for field, value in [('build', 'other'), ('releaseCommit', 'b'*40), ('assetHashes', {}), ('sparkleDeliveryEvidence', {})]:
            with self.assertRaises(ValueError): m.delivery_decision(r, {**ctx, field: value}, self.root, self.read)

    def test_notice_failure_cli_only_reopens_and_cannot_report_success(self):
        r = self.report(); self.classify(r); api = self.api(); s.synchronize(r, api, True, ENV)
        (self.root/'scripts/build-app.sh').write_text('changed')
        partial = self.report(); self.classify(partial)
        path = self.root/'report.json'; path.write_text(json.dumps(partial))
        def load(name): return m if name == 'security-sparkle-applicability' else self.real_load(name)
        with patch.object(s, 'load', side_effect=load), patch.object(m, 'evaluate', return_value=partial['sparkleApplicability']), \
             patch.object(s, 'GitHub', return_value=api), patch.dict(os.environ, ENV), \
             patch('sys.argv', ['sync', '--report', str(path), '--apply', '--reopen-sparkle-only']):
            with self.assertRaisesRegex(ValueError, 'Notice publication failed'): s.main()
        self.assertEqual([i['state'] for i in api.issues], ['open', 'closed'])
        result = json.loads(path.with_name('security-issues-result.json').read_text())
        self.assertFalse(result['complete']); self.assertEqual(result['changes'][0]['number'], 217)

    def test_missing_evidence_reopens_after_successful_scan_before_other_writes(self):
        r = self.report(); self.classify(r); api = self.api(); s.synchronize(r, api, True, ENV)
        current = copy.deepcopy(r['sparkleApplicability'])
        current['outcomes'][1].update(status='needs-review', evidenceStatus='unavailable', reason='offline')
        def load(name): return m if name == 'security-sparkle-applicability' else self.real_load(name)
        with patch.object(s, 'load', side_effect=load), patch.object(m, 'evaluate', return_value=current):
            changes, changed = s.check_sparkle_for_publication(r, api, apply=True, environ=ENV)
        self.assertTrue(changed); self.assertEqual([c['number'] for c in changes], [218])

    def test_absence_without_valid_proof_never_labels_it_fixed(self):
        r = self.report(); api = self.api(); r['findings'] = []; r['rawFindings'] = []
        actions = s.synchronize(r, api, True, ENV)
        self.assertTrue(all(a['action'] == 'preserve' for a in actions))
        self.assertTrue(all(i['state'] == 'open' for i in api.issues))


if __name__ == '__main__': unittest.main()
