"""Synthetic release decisions and evidence substitution; no exploit traffic."""
import copy
import datetime as dt
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]

def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT/'scripts'/f'{name}.py')
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value

r = module('security-release-policy')
a = module('security-audit')
CONFIG = json.loads((ROOT/r.CONFIG).read_text())
SHA = 'a'*40


def fixtures():
    policy = copy.deepcopy(CONFIG)
    advisory = {}
    findings = []
    for rule in policy['rules']:
        record = {'ghsa_id': rule['id'], 'description': 'Synthetic fixture', 'severity': 'high'}
        advisory['advisories/'+rule['id']] = record
        rule['advisorySHA256'] = r.advisory_digest(record)
        findings.append({'id': rule['id'], 'component': rule['component'], 'scope': rule['scope'],
            'severity': 'high', 'status': 'needs-review', 'queryComplete': True,
            'version': ', '.join(sorted({v for vs in rule['originVersions'].values() for v in vs})),
            'dependencyPaths': list(rule['originVersions']),
            'environmentObservations': [{'origin': o, 'versions': v, 'environment': 'local'}
                                        for o, v in rule['originVersions'].items()]})
    report = {'checkedAt': dt.datetime.now(dt.timezone.utc).isoformat(), 'scanStatus': 'complete',
        'errors': [], 'findings': findings, 'sourceReview': {'checkoutCommit': SHA},
        'observedEnvironment': 'local', 'toolchainCoverage': {'checksComplete': True},
        'packageMonitoring': {'queriesComplete': True},
        'vendorNotices': {'checksComplete': True, 'changes': [], 'requiresNoticeReview': False}}
    ctx = {'stage': 'candidate', 'version': '1.10.1', 'build': '20261029120000',
           'checkoutCommit': SHA, 'observedEnvironment': 'local'}
    return policy, advisory, report, ctx


class ReleaseClassificationTests(unittest.TestCase):
    def setUp(self):
        self.data, self.advisories, self.report, self.ctx = fixtures()
        for name, value in (('policy', self.data), ('verify_sources', 'f'*64), ('action_assets', {})):
            p = patch.object(r, name, return_value=value); p.start(); self.addCleanup(p.stop)

    def classify(self):
        return r.classify(self.report, self.ctx, reader=self.advisories.__getitem__)

    def test_four_reviewed_risks_remain_in_report_without_exception_flags(self):
        before = copy.deepcopy(self.report)
        decision = self.classify()
        self.assertEqual(len(decision['nonBlockingFindings']), 4)
        self.assertEqual(self.report, before)
        self.assertFalse(decision['grantsRiskException'])
        self.assertEqual(decision['nonBlockingFindings'][0]['classification'], 'diagnostic-transport-integrity')

    def test_next_version_uses_new_evidence_not_a_version_waiver(self):
        first = self.classify()
        self.ctx.update(version='1.10.2', build='20261229120000')
        second = self.classify()
        self.assertEqual(first['nonBlockingFindings'], second['nonBlockingFindings'])
        self.assertEqual(second['context']['version'], '1.10.2')
        self.assertNotIn('expiresAt', second)

    def test_stale_scan_is_not_reused_even_though_classification_has_no_expiry(self):
        self.report['checkedAt'] = (dt.datetime.now(dt.timezone.utc)-dt.timedelta(days=32)).isoformat()
        with self.assertRaises(ValueError): self.classify()

    def test_fresh_evidence_after_31_days_does_not_expire_policy(self):
        future = dt.datetime.now(dt.timezone.utc)+dt.timedelta(days=90)
        self.report['checkedAt'] = future.isoformat()
        with patch.object(r.dt, 'datetime', wraps=dt.datetime) as clock:
            clock.now.return_value = future
            self.assertEqual(len(self.classify()['nonBlockingFindings']), 4)

    def test_origin_version_environment_or_query_drift_rejected(self):
        original = copy.deepcopy(self.report)
        for mode in ('origin', 'version', 'environment', 'query', 'path', 'aggregate', 'duplicate'):
            with self.subTest(mode=mode):
                self.report = copy.deepcopy(original); f = self.report['findings'][0]
                if mode == 'origin': f['environmentObservations'][0]['origin'] = 'unexpected'
                if mode == 'version': f['environmentObservations'][0]['versions'] = ['9.9.9']
                if mode == 'environment': f['environmentObservations'][0]['environment'] = 'ci'
                if mode == 'query': f['queryComplete'] = False
                if mode == 'path': f['dependencyPaths'].append('unreviewed')
                if mode == 'aggregate': f['version'] = '9.9.9'
                if mode == 'duplicate': f['environmentObservations'] *= 2
                with self.assertRaises(ValueError): self.classify()

    def test_new_or_changed_advisory_never_inherits_classification(self):
        f = copy.deepcopy(self.report['findings'][0]); f['id'] = 'GHSA-new'; self.report['findings'].append(f)
        self.assertEqual(len(self.classify()['nonBlockingFindings']), 4)
        self.advisories['advisories/'+self.data['rules'][0]['id']]['description'] = 'New credential impact'
        with self.assertRaises(ValueError): self.classify()

    def test_withdrawal_is_not_silently_treated_as_a_risk_exception(self):
        self.advisories['advisories/'+self.data['rules'][0]['id']]['withdrawn_at'] = '2026-10-29'
        with self.assertRaises(ValueError): self.classify()

    def test_old_release_cannot_borrow_current_source_inventory(self):
        self.ctx.update(stage='deploy', assetVerification='verified-signatures-and-release-identity',
                        deliveryInventory=[{'name': 'https://github.com/example/app', 'version': '1.0.0'}])
        self.report['deliveryInventoryDigest'] = r.digest([{'name': 'https://github.com/example/app', 'version': '2.0.0'}])
        with self.assertRaisesRegex(ValueError, 'actual signed'): self.classify()

    def test_same_id_in_app_or_different_component_not_classified(self):
        f = self.report['findings'][0]
        f['scope'] = 'current-source'
        self.assertEqual(len(self.classify()['nonBlockingFindings']), 3)
        f['scope'] = 'github-actions'; f['component'] = 'another-package'
        self.assertEqual(len(self.classify()['nonBlockingFindings']), 3)

    def test_missing_coverage_commit_and_stage_evidence_rejected(self):
        for field in ('toolchainCoverage', 'packageMonitoring', 'vendorNotices', 'sourceReview'):
            with self.subTest(field=field):
                before = self.report.pop(field)
                with self.assertRaises(ValueError): self.classify()
                self.report[field] = before
        self.ctx['stage'] = 'publish'
        with self.assertRaises(ValueError): self.classify()
        self.ctx['assetVerification'] = 'verified-signatures-and-release-identity'
        self.ctx['deliveryInventory'] = [{'name': 'https://github.com/example/app', 'version': '1.0.0'}]
        self.report['deliveryInventoryDigest'] = r.digest(self.ctx['deliveryInventory'])
        self.assertEqual(len(self.classify()['nonBlockingFindings']), 4)

    def test_changed_or_new_notice_remains_pending(self):
        notice = copy.deepcopy(self.data['notices'][0]); notice['contentSHA256'] = '0'*64
        self.report['vendorNotices'].update(changes=[notice], requiresNoticeReview=True)
        self.assertEqual(self.classify()['unreviewedNotices'], [notice])
        self.assertTrue(self.report['vendorNotices']['requiresNoticeReview'])

    def test_reviewed_notice_does_not_clear_monitor_state(self):
        notice = copy.deepcopy(self.data['notices'][0])
        self.report['vendorNotices'].update(changes=[notice], requiresNoticeReview=True)
        with patch.object(r.subprocess, 'run') as run:
            run.return_value.stdout = 'v24.22.1\n'
            self.assertEqual(len(self.classify()['reviewedNotices']), 1)
        self.assertTrue(self.report['vendorNotices']['requiresNoticeReview'])

    def test_node_notice_requires_actual_runtime_match(self):
        self.report['vendorNotices']['changes'] = [self.data['notices'][0]]
        with patch.object(r.subprocess, 'run') as run:
            run.return_value.stdout = 'v24.22.0\n'
            with self.assertRaises(ValueError): self.classify()

    def test_notice_baseline_review_cannot_be_hidden_by_empty_changes(self):
        self.report['vendorNotices']['requiresNoticeReview'] = True
        with self.assertRaises(ValueError): self.classify()


class ReleaseSourceTests(unittest.TestCase):
    def test_real_reviewed_source_and_official_archives_are_consistent(self):
        # Metadata only; does not execute inspected Action bundles.
        data = r.policy(ROOT)
        self.assertEqual(len(r.verify_sources(ROOT, data)), 64)
        self.assertEqual(len(r.action_assets(ROOT, data)), 4)

    def test_changed_source_and_new_workflow_stop_reuse(self):
        data = copy.deepcopy(CONFIG)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name in data['sourceFiles']:
                path = root/name; path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes((ROOT/name).read_bytes())
            r.verify_sources(root, data)
            path = root/'scripts/publish-release.sh'; path.write_text('changed trust path')
            with self.assertRaises(ValueError): r.verify_sources(root, data)
            path.write_bytes((ROOT/'scripts/publish-release.sh').read_bytes())
            (root/'.github/workflows/unreviewed.yml').write_text('new workflow')
            with self.assertRaises(ValueError): r.verify_sources(root, data)

    def test_invalid_context_never_runs_release(self):
        for stage, version in (('merge', '1.10.1'), ('publish', ''), ('candidate', '../../bad')):
            with self.assertRaises(ValueError): r.context(stage, version)

    def test_dirty_or_pr_context_is_rejected(self):
        helper = r.load('security-source-review')
        with patch.object(helper, 'source_check', return_value={'localChanges': True}), patch.object(r, 'load', return_value=helper):
            with self.assertRaisesRegex(ValueError, 'clean'): r.context('candidate', '1.10.1', '123')

    def test_publication_entry_is_policy_sensitive(self):
        self.assertTrue(r.load('security-source-review').policy_sensitive('scripts/publish-release.sh'))


class ReleaseIntegrityTests(unittest.TestCase):
    def test_failed_or_wrong_commit_run_rejected(self):
        run = {'head_sha': SHA, 'path': '.github/workflows/security-gate.yml', 'event': 'push',
               'head_branch': 'main', 'head_repository': {'full_name': r.REPOSITORY},
               'status': 'completed', 'conclusion': 'success'}
        r.require_success(run, SHA, run['path'], 'push')
        for field, value in (('head_sha', 'b'*40), ('conclusion', 'failure'), ('status', 'queued'),
                             ('head_branch', 'feature'), ('event', 'pull_request')):
            bad = {**run, field: value}
            with self.assertRaises(ValueError): r.require_success(bad, SHA, run['path'], 'push')

    def test_latest_codeql_error_not_hidden_by_earlier_success(self):
        analyses = [{'id': i, 'category': '/language:'+lang, 'commit_sha': SHA, 'ref': 'refs/heads/main',
                     'created_at': '2026-10-29T00:00:00Z', 'results_count': 0, 'error': '', 'warning': ''}
                    for i, lang in enumerate(('swift', 'python', 'javascript-typescript', 'actions'), 1)]
        self.assertEqual(len(r.require_analyses(analyses, SHA)), 4)
        analyses.append({**analyses[0], 'id': 9, 'created_at': '2026-10-29T00:01:00Z', 'error': 'processing failed'})
        with self.assertRaises(ValueError): r.require_analyses(analyses, SHA)

    def test_sarif_execution_and_results_must_be_complete(self):
        good = {'version': '2.1.0', 'runs': [{'tool': {'driver': {'name': 'CodeQL'}}, 'results': [],
                                            'invocations': [{'executionSuccessful': True}]}]}
        r.validate_sarif(good)
        for bad in ({}, {'version': '2.1.0', 'runs': []},
                    {'version': '2.1.0', 'runs': [{**good['runs'][0], 'results': [{'ruleId': 'risk'}]}]},
                    {'version': '2.1.0', 'runs': [{**good['runs'][0], 'invocations': [{'executionSuccessful': False}]}]}):
            with self.assertRaises(ValueError): r.validate_sarif(bad)
        r.validate_sarif({'version': '2.1.0', 'runs': [{k: v for k, v in good['runs'][0].items() if k != 'invocations'}]})

    def test_independent_log_digest_is_required_and_unambiguous(self):
        def blob(lines):
            out = io.BytesIO()
            with zipfile.ZipFile(out, 'w') as z:
                z.writestr('0_monitor.txt', lines)
                z.writestr('monitor/2_scan.txt', lines)  # duplicate step log is not counted twice
            return out.getvalue()
        line = '2026-10-29T00:00:00Z MYTERM_SECURITY_REPORT_SHA256='+'a'*64+'\n'
        self.assertEqual(r.log_digest(blob(line)), 'a'*64)
        for lines in ('', line+line):
            with self.assertRaises(ValueError): r.log_digest(blob(lines))


class ReleaseReadinessTests(unittest.TestCase):
    def fixture(self, changed_report=False):
        report = b'{"independent":"scan"}'
        digest = hashlib.sha256(report).hexdigest()
        log = io.BytesIO(); artifact = io.BytesIO()
        with zipfile.ZipFile(log, 'w') as z:
            z.writestr('0_monitor.txt', '2026-10-29T00:00:00Z MYTERM_SECURITY_REPORT_SHA256='+digest+'\n')
        with zipfile.ZipFile(artifact, 'w') as z:
            z.writestr('security-report.json', b'{"substituted":true}' if changed_report else report)
        run = {'id': 1, 'created_at': '2026-10-29T00:00:00Z', 'head_sha': SHA, 'path': '.github/workflows/security-gate.yml',
               'head_branch': 'main', 'event': 'push', 'head_repository': {'full_name': r.REPOSITORY},
               'status': 'completed', 'conclusion': 'success'}
        analyses = [{'id': i, 'category': '/language:'+lang, 'commit_sha': SHA, 'ref': 'refs/heads/main',
                     'created_at': '2026-10-29T00:00:00Z', 'results_count': 0, 'error': '', 'warning': ''}
                    for i, lang in enumerate(('swift', 'python', 'javascript-typescript', 'actions'), 1)]
        def read(path):
            if '/actions/runs?' in path:
                return {'workflow_runs': [{**run, 'path': 'dynamic/github-code-scanning/codeql', 'event': 'dynamic'}]}
            return {'workflow_runs': [run]} if '/actions/workflows/' in path else analyses
        health = r.load('security-monitor-health')
        health.check = lambda *args: {'healthy': True, 'headSHA': SHA, 'runId': 3, 'runAttempt': 2, 'artifactId': 5}
        downloader = lambda path: log.getvalue() if path.endswith('/logs') else artifact.getvalue()
        sarif = lambda ident: {'version': '2.1.0', 'runs': [{'tool': {'driver': {'name': 'CodeQL'}}, 'results': []}]}
        return health, read, downloader, sarif

    def test_publish_checks_independent_digest_and_all_analyses(self):
        health, read, download, sarif = self.fixture()
        with patch.object(r, 'load', return_value=health):
            result = r.remote_readiness(SHA, reader=read, downloader=download, sarif_reader=sarif)
        self.assertEqual(result['monitorAttempt'], 2)
        self.assertEqual(len(result['analyses']), 4)

    def test_replaced_report_rejected_despite_successful_health_receipt(self):
        health, read, download, sarif = self.fixture(changed_report=True)
        with patch.object(r, 'load', return_value=health):
            with self.assertRaisesRegex(ValueError, 'independent'):
                r.remote_readiness(SHA, reader=read, downloader=download, sarif_reader=sarif)

    def test_wrong_monitor_commit_and_unreadable_analysis_stop_release(self):
        health, read, download, sarif = self.fixture()
        health.check = lambda *args: {'healthy': True, 'headSHA': 'b'*40}
        with patch.object(r, 'load', return_value=health):
            with self.assertRaisesRegex(ValueError, 'this commit'):
                r.remote_readiness(SHA, reader=read, downloader=download, sarif_reader=sarif)
            with self.assertRaises(ValueError):
                r.remote_readiness(SHA, reader=read, downloader=download, sarif_reader=lambda _: {})


class PublicationEntryTests(unittest.TestCase):
    def test_draft_validation_publication_and_failures_use_the_same_entry(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); (root/'scripts').mkdir(); (root/'bin').mkdir()
            entry = root/'scripts/publish-release.sh'; entry.write_bytes((ROOT/'scripts/publish-release.sh').read_bytes())
            entry.chmod(0o755)
            driver = r'''
import json,os,sys
from pathlib import Path
args=sys.argv[1:];name=Path(sys.argv[0]).name;root=Path.cwd()
def record(value):
 with (root/'calls').open('a') as out:out.write(value+'\n')
if name=='git':
 if args[:2]==['branch','--show-current']:print('main')
 elif args[:1]==['rev-parse']:print('a'*40)
elif name=='project-gh.sh':
 record(' '.join(args[:2]))
 if args[:2]==['release','edit']:pass
 elif args[:2]==['release','download']:pass
 elif args[:2]==['release','view']:
  if os.environ.get('FIXTURE_LOOKUP_FAIL')=='1':sys.exit(1)
  count=root/'lookup-count'
  n=int(count.read_text())+1 if count.exists() else 1;count.write_text(str(n))
  print('null' if os.environ.get('FIXTURE_BAD_ID')=='1' else
        2 if os.environ.get('FIXTURE_CHANGED_ID')=='1' and n>1 else 1)
 elif args[-1]=='.sha':print('a'*40)
 else:
  # GitHub's REST by-tag endpoint cannot return an unpublished Draft.
  endpoint=next((arg for arg in args if arg.startswith('repos/')), '')
  if '/releases/tags/' in endpoint:sys.exit('Not Found (HTTP 404)')
  if endpoint not in ('repos/crazy01100/myterm/releases/1','repos/crazy01100/myterm/releases/2'):
   sys.exit('Unexpected metadata endpoint')
  r={'id':int(endpoint.rsplit('/',1)[1]),'draft':True,'tag_name':'v1.10.1','target_commitish':'a'*40,'assets':[]}
  if os.environ.get('FIXTURE_BAD_DRAFT')=='1':r['draft']=False
  print(json.dumps(r))
elif name=='project-python.sh':
 if args[0]=='scripts/security-audit.py':
  record('audit');sys.exit(int(os.environ.get('FIXTURE_AUDIT_FAIL','0')))
 else:os.execv(sys.executable,[sys.executable,*args])
else:record('verify-assets')
'''
            for name in ('git', 'project-gh.sh', 'project-python.sh', 'verify-release-assets.sh'):
                path = root/('bin' if name=='git' else 'scripts')/name
                path.write_text('#!'+sys.executable+'\n'+driver);path.chmod(0o755)
            env = {**os.environ, 'PATH': str(root/'bin')+':'+os.environ['PATH']}
            for mode in ('validate', 'publish', 'audit-failed', 'bad-draft',
                         'lookup-failed', 'bad-id', 'changed-id'):
                with self.subTest(mode=mode):
                    (root/'calls').write_text('')
                    (root/'lookup-count').unlink(missing_ok=True)
                    env.update(FIXTURE_AUDIT_FAIL='1' if mode=='audit-failed' else '0',
                               FIXTURE_BAD_DRAFT='1' if mode=='bad-draft' else '0',
                               FIXTURE_LOOKUP_FAIL='1' if mode=='lookup-failed' else '0',
                               FIXTURE_BAD_ID='1' if mode=='bad-id' else '0',
                               FIXTURE_CHANGED_ID='1' if mode=='changed-id' else '0')
                    command = [str(entry), '--version', '1.10.1', '--build', '123']
                    if mode != 'validate':command.append('--publish')
                    result = subprocess.run(command,cwd=root,env=env,capture_output=True,text=True,timeout=20)
                    calls = (root/'calls').read_text().splitlines()
                    if mode in ('validate','publish'):
                        self.assertEqual(result.returncode,0,result.stderr)
                        self.assertIn('audit',calls)
                        self.assertEqual(calls.count('release view'),2)
                    else:self.assertNotEqual(result.returncode,0)
                    self.assertEqual('release edit' in calls,mode=='publish')
                    if mode=='publish':self.assertLess(calls.index('audit'),calls.index('release edit'))


class ReleaseGateTests(unittest.TestCase):
    def test_existing_exception_still_expires_at_31_days(self):
        report = {'findings': [{'id': 'fixture', 'component': 'fixture', 'scope': 'development', 'version': '1',
                                'status': 'affected', 'severity': 'high'}]}
        start = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
        entry = {**report['findings'][0], 'acceptedAt': start.isoformat(),
                 'expiresAt': (start+dt.timedelta(days=31)).isoformat(), 'acceptedBy': 'owner', 'reason': 'temporary'}
        a.apply_exceptions(report, {'schemaVersion': 1, 'exceptions': [entry]}, now=start+dt.timedelta(days=32))
        self.assertFalse(report['findings'][0]['acceptedRisk'])
        self.assertTrue(a.blocking(report|{'errors': []}))

    def test_release_and_merge_modes_cannot_be_combined(self):
        with patch('sys.argv', ['audit', '--output', '/tmp/unused', '--merge-gate', '--release-stage', 'candidate']):
            with self.assertRaises(SystemExit): a.main()

    def test_gate_consumes_classification_but_preserves_findings_and_unreviewed_risks(self):
        _, _, report, ctx = fixtures()
        before = copy.deepcopy(report['findings'])
        helper = module('security-release-policy')
        decision = {'nonBlockingFindings': [{'findingIndex': i} for i in range(4)], 'unreviewedNotices': []}
        # Patch only the external evidence boundaries; exercise the real gate.
        with patch.object(a, 'baseline_findings', return_value=[]), \
             patch.object(a.importlib.util, 'module_from_spec', return_value=helper), \
             patch.object(helper, 'classify', return_value=decision), \
             patch.object(a.importlib.util, 'spec_from_file_location') as spec:
            spec.return_value.loader.exec_module = lambda m: None
            noop = type('Noop', (), {'revalidate': lambda *args: None})()
            with patch.object(a, 'pip_applicability', return_value=noop), \
                 patch.object(a, 'openssl_supplier', return_value=noop), \
                 patch.object(a, 'project_applicability', return_value=noop), \
                 patch.object(a, 'supplier_notices', return_value=noop):
                self.assertFalse(a.blocking(report, release_context=ctx))
                self.assertEqual(report['findings'], before)
                report['findings'].append({**before[0], 'id': 'new-unreviewed'})
                self.assertTrue(a.blocking(report, release_context=ctx))
                report['findings'].pop()
                decision['unreviewedNotices'] = [{'id': 'new-notice'}]
                self.assertTrue(a.blocking(report, release_context=ctx))

    def test_signed_delivery_dependencies_are_scanned_separately(self):
        delivered = [{'name': 'https://github.com/example/library', 'version': '1.0.0'}]
        seen = []
        def runtime(items, scope, report, cache):
            seen.append((scope, items))
            if scope == 'delivery-app':
                report['findings'].append({'id': 'GHSA-old-asset', 'component': 'example/library',
                    'version': '1.0.0', 'scope': scope, 'severity': 'high', 'status': 'affected'})
        noop = type('Noop', (), {'classify': lambda *args: None})()
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'false'}), \
             patch.object(a.module, 'inventory', return_value=[]), \
             patch.object(a, 'scan_runtime', side_effect=runtime), \
             patch.object(a, 'scan_npm'), patch.object(a, 'scan_verifier'), \
             patch.object(a, 'scan_actions'), patch.object(a, 'scan_toolchain'), \
             patch.object(a, 'pip_applicability', return_value=noop), \
             patch.object(a, 'openssl_supplier', return_value=noop), \
             patch.object(a, 'project_applicability', return_value=noop):
            report = a.run(delivery_inventory=delivered)
        self.assertIn(('delivery-app', delivered), seen)
        self.assertEqual(report['deliveryInventoryDigest'], r.digest(delivered))
        self.assertTrue(a.blocking(report))
        self.assertEqual(report['findings'][0]['scope'], 'delivery-app')

    def test_release_decisions_do_not_bypass_operational_failures(self):
        for change in ({'errors': ['network']}, {'coverageGaps': ['missing']},
                       {'coverageErrors': ['incomplete']}, {'conditionalBlocks': ['blocked']}):
            report = fixtures()[2]; report.update(change)
            self.assertTrue(a.blocking(report, release_context=fixtures()[3]))

    def test_entrypoints_preserve_assets_tests_and_credentials_order(self):
        candidate = (ROOT/'scripts/prepare-release-build.sh').read_text()
        self.assertIn('--release-stage candidate', candidate)
        self.assertIn('run-isolated-tests.py', candidate)
        publish = (ROOT/'scripts/publish-release.sh').read_text()
        self.assertLess(publish.index('release download'), publish.index('--release-stage publish'))
        self.assertLess(publish.index('--release-stage publish'), publish.index('release edit'))
        deployment = (ROOT/'.github/workflows/deploy-update-site.yml').read_text()
        self.assertLess(deployment.index('verify-signed-release.py'), deployment.index('--release-stage deploy'))
        self.assertLess(deployment.index('--release-stage deploy'), deployment.index('CLOUDFLARE_API_TOKEN:'))
        self.assertNotIn('continue-on-error', deployment)
        self.assertNotIn('--merge-gate', deployment)


if __name__ == '__main__': unittest.main()
