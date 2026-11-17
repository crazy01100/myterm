"""Synthetic control-plane evidence; no package installs, notifications or exploits."""
import copy
import datetime as dt
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ci_gate', ROOT/'scripts/security-ci-gate.py')
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


class GateTests(unittest.TestCase):
    def setUp(self):
        self.ctx = {'repository': c.REPOSITORY, 'event': 'pull_request', 'pr': 216,
                    'head': 'a'*40, 'base': 'b'*40, 'testedCommit': 'c'*40,
                    'runId': 1, 'currentAttempt': 2}
        self.report = {'scanStatus': 'complete', 'errors': [], 'coverageErrors': [], 'coverageGaps': [],
                       'packageMonitoring': {'queriesComplete': True}, 'toolchainCoverage': {'checksComplete': True},
                       'gateEvaluation': {'purpose': 'merge', 'blocking': False,
                                          'authorizesRelease': False, 'grantsRiskException': False},
                       'checkedAt': now()}
        self.source = {'checkoutCommit': 'c'*40, 'sourceVerified': True,
                       'policySHA256': c.sha((ROOT/c.review.POLICY).read_bytes())}

    def archive(self, mutate=None, source=None):
        raw = json.dumps(self.report).encode(); source = json.dumps(source or self.source).encode()
        receipt = {k: v for k, v in self.ctx.items() if k != 'currentAttempt'}
        receipt.update(schemaVersion=1, technicalAttempt=1, policyRequired=True,
                       reportSHA256=c.sha(raw), sourceReviewSHA256=c.sha(source))
        if mutate: mutate(receipt)
        out = io.BytesIO()
        with zipfile.ZipFile(out, 'w') as z:
            z.writestr(c.RECEIPT, json.dumps(receipt)); z.writestr('security-report.json', raw)
            z.writestr('security-source-review.json', source)
        return out.getvalue()

    def test_real_reviewed_base_predicate_is_used_without_top_level_execution(self):
        predicate = c.base_classifier("raise RuntimeError('must not execute')\n"+
                                     "def policy_sensitive(path):\n return path.startswith('scripts/security-')\n")
        self.assertTrue(predicate('scripts/security-ci-gate.py'))
        self.assertFalse(predicate('README.md'))
        with patch.object(c, 'git', side_effect=["def policy_sensitive(path):\n return path.startswith('Config/')\n", 'Config/removed.json\0']):
            self.assertTrue(c.required(self.ctx))

    def test_classification_rejects_missing_or_unknown_base_rule(self):
        with self.assertRaises(ValueError): c.base_classifier('x=1')
        with patch.object(c, 'git', side_effect=["def policy_sensitive(path):\n return 'false'\n", 'README.md\0']):
            with self.assertRaises(ValueError): c.required(self.ctx)

    def test_main_and_ordinary_changes_do_not_require_manual_policy_review(self):
        self.assertFalse(c.required({**self.ctx, 'event': 'push'}))
        source = (ROOT/'scripts/security-source-review.py').read_text()
        for names in ('README.md\0', 'Tests/Security/test_ci_gate.py\0', 'Config/Security/vendor-notices.json\0'):
            with patch.object(c, 'git', side_effect=[source, names]): self.assertFalse(c.required(self.ctx))

    def test_workflow_classifier_and_policy_edits_always_require_review(self):
        source = (ROOT/'scripts/security-source-review.py').read_text()
        for name in (c.WORKFLOW, 'scripts/security-source-review.py', 'scripts/security-ci-gate.py', c.review.POLICY):
            with patch.object(c, 'git', side_effect=[source, name+'\0']): self.assertTrue(c.required(self.ctx))

    def test_final_result_accepts_only_explicit_success_and_valid_not_required(self):
        c.aggregate('success', 'success', True); c.aggregate('success', 'skipped', False)
        for tech in (None, 'failure', 'cancelled', 'skipped', 'neutral'):
            with self.subTest(tech=tech), self.assertRaises(ValueError): c.aggregate(tech, 'success', True)
        for policy in (None, 'skipped', 'failure', 'cancelled', 'neutral'):
            with self.subTest(policy=policy), self.assertRaises(ValueError): c.aggregate('success', policy, True)
        for unknown in (None, 'false', 0):
            with self.assertRaises(ValueError): c.aggregate('success', 'skipped', unknown)
        with self.assertRaises(ValueError): c.aggregate('success', 'success', False)

    def test_approval_only_rerun_can_use_original_successful_technical_attempt(self):
        receipt = c.artifact_content(self.archive(), self.ctx)
        self.assertEqual(receipt['technicalAttempt'], 1)

    def test_receipt_cannot_be_reused_for_another_commit_base_run_or_event(self):
        for key in ('repository', 'head', 'base', 'testedCommit', 'pr', 'runId', 'event'):
            with self.subTest(key=key), self.assertRaises(ValueError):
                c.artifact_content(self.archive(lambda r: r.update({key: 'different'})), self.ctx)
        for value in (0, 3, True, '1'):
            with self.assertRaises(ValueError):
                c.artifact_content(self.archive(lambda r: r.update(technicalAttempt=value)), self.ctx)

    def test_receipt_content_and_source_policy_must_match(self):
        for key in ('reportSHA256', 'sourceReviewSHA256'):
            with self.assertRaises(ValueError):
                c.artifact_content(self.archive(lambda r: r.update({key: '0'*64})), self.ctx)
        for key, value in (('sourceVerified', False), ('checkoutCommit', 'd'*40), ('policySHA256', '0'*64)):
            with self.assertRaises(ValueError):
                c.artifact_content(self.archive(source={**self.source, key: value}), self.ctx)

    def test_incomplete_or_expired_scan_never_becomes_approved(self):
        for key, value in (('scanStatus', 'partial'), ('errors', ['failed']), ('coverageGaps', ['missing']),
                           ('coverageErrors', ['query']), ('packageMonitoring', {}), ('toolchainCoverage', {}),
                           ('gateEvaluation', {}), ('checkedAt', (dt.datetime.now(dt.timezone.utc)-dt.timedelta(hours=49)).isoformat()),
                           ('checkedAt', (dt.datetime.now(dt.timezone.utc)+dt.timedelta(hours=1)).isoformat())):
            with self.subTest(key=key), self.assertRaises(ValueError): c.report_valid({**self.report, key: value})

    def test_independent_digest_ignores_synthetic_test_digests(self):
        raw = ('t MYTERM_SECURITY_REPORT_SHA256='+'1'*64+'\n'+
               't ##[group]Run ./scripts/project-python.sh scripts/security-audit.py --merge-gate --output build/security-report.json\n'+
               't ##[endgroup]\nt MYTERM_SECURITY_REPORT_SHA256='+'2'*64+'\n'+
               't ##[group]Run next\nt MYTERM_SECURITY_REPORT_SHA256='+'3'*64+'\n').encode()
        self.assertEqual(c.audit_log_digest(raw), '2'*64)
        for invalid in (b'', b't MYTERM_SECURITY_REPORT_SHA256='+b'2'*64, raw+raw):
            with self.assertRaises(ValueError): c.audit_log_digest(invalid)

    def remote(self, *, bad_job=False, mismatch_log=False, expired=False, wrong_run=False, incomplete=False):
        blob = self.archive(); digest = c.artifact_content(blob, self.ctx)['reportSHA256']
        run = {'head_sha': 'd'*40 if wrong_run else 'a'*40, 'event': 'pull_request', 'path': c.WORKFLOW,
               'head_repository': {'full_name': c.REPOSITORY}, 'run_attempt': 2}
        assets = {'total_count': 3 if incomplete else 2, 'artifacts': [
            {'id': 99, 'name': 'security-check-report', 'created_at': '2026-01-01T00:00:00Z'},
            {'id': 10, 'name': 'security-check-report', 'created_at': now(), 'expired': expired,
             'size_in_bytes': len(blob), 'digest': 'sha256:'+c.sha(blob)}]}
        jobs = {'total_count': 1, 'jobs': [{'id': 77, 'name': c.TECHNICAL_JOB,
                 'status': 'completed', 'conclusion': 'failure' if bad_job else 'success'}]}
        def reader(path):
            if path == 'actions/runs/1': return run
            if '/artifacts?' in path: return assets
            self.assertIn('/attempts/1/jobs?', path); return jobs
        def downloader(path):
            if path == 'actions/artifacts/10/zip': return blob
            self.assertEqual(path, 'actions/jobs/77/logs')
            return ('t ##[group]Run ./scripts/project-python.sh scripts/security-audit.py --merge-gate --output build/security-report.json\n'+
                    't MYTERM_SECURITY_REPORT_SHA256='+('0'*64 if mismatch_log else digest)+'\n').encode()
        return reader, downloader

    def test_evidence_uses_created_time_and_original_attempt_not_largest_artifact_id(self):
        result = c.evidence(self.ctx, *self.remote())
        self.assertEqual(result['artifactId'], 10); self.assertEqual(result['technicalJobId'], 77)

    def test_failed_job_log_replacement_expired_or_wrong_run_still_block(self):
        for field in ('bad_job', 'mismatch_log', 'expired', 'wrong_run', 'incomplete'):
            with self.subTest(field=field), self.assertRaises(ValueError):
                c.evidence(self.ctx, *self.remote(**{field: True}))

    def environment(self):
        return {'name': c.ENVIRONMENT, 'can_admins_bypass': False,
                'deployment_branch_policy': {'protected_branches': False, 'custom_branch_policies': True},
                'protection_rules': [{'type': 'required_reviewers', 'prevent_self_review': False,
                    'reviewers': [{'type': 'User', 'reviewer': c.review.MAINTAINER}]}]}, {
                'total_count': 1, 'branch_policies': [{'name': 'refs/pull/*/merge', 'type': 'branch'}]}

    def test_environment_requires_exact_owner_no_bypass_and_only_pr_ref(self):
        env, branches = self.environment(); c.environment_valid(env, branches)
        for key, value in (('name', 'production'), ('can_admins_bypass', True), ('protection_rules', []), ('deployment_branch_policy', None)):
            with self.assertRaises(ValueError): c.environment_valid({**env, key: value}, branches)
        bad = copy.deepcopy(env); bad['protection_rules'][0]['reviewers'][0]['reviewer'] = {'id': 7, 'login': 'other', 'type': 'User'}
        with self.assertRaises(ValueError): c.environment_valid(bad, branches)
        for refs in ({'total_count': 0, 'branch_policies': []}, {'total_count': 1, 'branch_policies': [{'name': '*', 'type': 'branch'}]}):
            with self.assertRaises(ValueError): c.environment_valid(env, refs)

    def test_changed_head_or_review_during_final_verification_blocks(self):
        for drift in ('head', 'review', 'classification'):
            contexts = [self.ctx, {**self.ctx, 'head': 'd'*40} if drift == 'head' else self.ctx]
            with patch.object(c, 'context', side_effect=contexts), patch.object(c, 'required', side_effect=[True, False if drift == 'classification' else True]), \
                 patch.object(c, 'evidence', return_value={'policyRequired': True}), \
                 patch.object(c, 'approval', side_effect=[{'reviewId': 1}, {'reviewId': 2 if drift == 'review' else 1}]), \
                 patch.object(c, 'codeql', return_value={}):
                with self.assertRaises(ValueError): c.verify('finish', {'TECHNICAL_RESULT': 'success', 'POLICY_RESULT': 'success'})

    def test_forged_not_required_output_cannot_skip_approval(self):
        with patch.object(c, 'context', return_value=self.ctx), patch.object(c, 'required', return_value=True), \
             patch.object(c, 'evidence') as evidence:
            with self.assertRaises(ValueError): c.verify('finish', {'TECHNICAL_RESULT': 'success', 'POLICY_RESULT': 'skipped'})
            evidence.assert_not_called()

    def test_recorded_classification_drift_is_rejected(self):
        with patch.object(c, 'context', return_value=self.ctx), patch.object(c, 'required', return_value=True), \
             patch.object(c, 'evidence', return_value={'policyRequired': False}):
            with self.assertRaises(ValueError): c.verify('approve')

    def test_ordinary_pr_does_not_turn_in_progress_independent_codeql_into_a_failed_job(self):
        with patch.object(c, 'context', return_value=self.ctx), patch.object(c, 'required', return_value=False), \
             patch.object(c, 'evidence', return_value={'policyRequired': False}), \
             patch.object(c, 'approval') as approve, patch.object(c, 'codeql') as codeql:
            c.verify('finish', {'TECHNICAL_RESULT': 'success', 'POLICY_RESULT': 'skipped'})
            approve.assert_not_called(); codeql.assert_not_called()
        # The standard pre-merge verifier enforces CodeQL for both PR types.
        with patch.object(c.review, 'gh_read', return_value=[]), self.assertRaises(ValueError):
            c.review.verify_pr_codeql(ROOT, 216, 'a'*40)

    def test_native_review_binds_base_and_policy_in_addition_to_head(self):
        r = c.review; raw = (ROOT/r.POLICY).read_bytes(); decision = json.loads(raw)['decision']
        identity = {'number': 216, 'head': 'a'*40, 'base': 'b'*40, 'author': {'login': 'dependabot[bot]', 'id': 3, 'type': 'Bot'}}
        body = r.REVIEW_MARKER+'\n'+json.dumps(r.review_document(identity, decision, raw))
        row = {'id': 1, 'user': r.MAINTAINER, 'state': 'APPROVED', 'body': body, 'commit_id': 'a'*40, 'submitted_at': now()}
        self.assertEqual(r.select_review([[row]], identity, decision, raw)['mode'], 'github-approved')
        for change in ({'body': 'Approved'}, {'commit_id': 'd'*40}, {'state': 'DISMISSED'}):
            with self.assertRaises(ValueError): r.select_review([[{**row, **change}]], identity, decision, raw)
        for change in ({'base': 'e'*40}, {'head': 'd'*40}):
            with self.assertRaises(ValueError): r.select_review([[row]], {**identity, **change}, decision, raw)

    def test_main_codeql_requirement_remains_exact_and_pr_ref_is_separate(self):
        release = c.load('security-release-policy')
        rows = [{'id': i, 'created_at': now(), 'commit_sha': 'a'*40, 'ref': 'refs/pull/216/head',
                 'category': '/language:'+language, 'error': '', 'warning': '', 'results_count': 0}
                for i, language in enumerate(['swift', 'python', 'javascript-typescript', 'actions'], 1)]
        self.assertEqual(len(release.require_analyses(rows, 'a'*40, ref='refs/pull/216/head')), 4)
        with self.assertRaises(ValueError): release.require_analyses(rows, 'a'*40)
        for field, value in (('error', 'failed'), ('warning', 'incomplete'), ('results_count', 1)):
            bad = copy.deepcopy(rows); bad[0][field] = value
            with self.assertRaises(ValueError): release.require_analyses(bad, 'a'*40, ref='refs/pull/216/head')

    def test_workflow_has_no_expensive_work_after_environment_approval(self):
        text = (ROOT/c.WORKFLOW).read_text()
        technical, tail = text.split('\n  policy:\n')
        policy, gate = tail.split('\n  gate:\n')
        self.assertIn('environment: policy-approval', policy)
        self.assertIn('security-ci-gate.py record', technical)
        self.assertIn('security-technical-receipt.json', technical)
        self.assertIn('security-ci-gate.py approve', policy)
        self.assertIn('security-ci-gate.py finish', gate)
        self.assertIn('needs: [technical, policy]', gate)
        self.assertIn('if: always()', gate)
        self.assertIn('name: Release policy (unresolved risks block approval)', gate)
        for forbidden in ('npm ci', 'setup-security-tools.sh', 'security-audit.py', 'unittest', 'project-java-runtime.py', 'security-prepare-inventory.py', '--ci-review'):
            self.assertNotIn(forbidden, tail)
        self.assertNotIn('write', text.split('concurrency:')[0])

    def pr(self):
        return {'number':216,'state':'open','draft':False,
                'base':{'ref':'main','sha':'b'*40,'repo':{'full_name':c.REPOSITORY}},
                'head':{'sha':'a'*40,'repo':{'full_name':c.REPOSITORY}},
                'user':{'login':'dependabot[bot]','id':3,'type':'Bot'}}

    def test_context_binds_live_pr_checkout_and_both_parents(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); event=root/'event.json';event.write_text(json.dumps({'pull_request':self.pr()}))
            env={'GITHUB_ACTIONS':'true','GITHUB_REPOSITORY':c.REPOSITORY,'GITHUB_EVENT_NAME':'pull_request',
                 'GITHUB_EVENT_PATH':str(event),'GITHUB_REF':'refs/pull/216/merge','GITHUB_SHA':'c'*40,
                 'GITHUB_RUN_ID':'1','GITHUB_RUN_ATTEMPT':'2'}
            with patch.object(c,'git',side_effect=['c'*40,'','','']) as git:
                self.assertEqual(c.context(env,root=root,reader=lambda _:self.pr()),self.ctx)
                self.assertEqual(git.call_count,4)
            for change in ({'GITHUB_REPOSITORY':'foreign/repo'},{'GITHUB_SHA':'d'*40},
                           {'GITHUB_REF':'refs/heads/main'},{'GITHUB_RUN_ATTEMPT':'0'}):
                with patch.object(c,'git',side_effect=['c'*40,'','','']),self.assertRaises(ValueError):
                    c.context({**env,**change},root=root,reader=lambda _:self.pr())
            for part in ('head','base'):
                live=self.pr();live[part]['sha']='e'*40
                with patch.object(c,'git',side_effect=['c'*40,'']),self.assertRaises(ValueError):
                    c.context(env,root=root,reader=lambda _:live)
            with patch.object(c,'git',side_effect=['c'*40,' M source']),self.assertRaises(ValueError):
                c.context(env,root=root,reader=lambda _:self.pr())

    def test_main_context_does_not_need_pr_or_manual_approval(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);event=root/'event.json';event.write_text(json.dumps({'before':'b'*40,'after':'c'*40}))
            env={'GITHUB_ACTIONS':'true','GITHUB_REPOSITORY':c.REPOSITORY,'GITHUB_EVENT_NAME':'push',
                 'GITHUB_EVENT_PATH':str(event),'GITHUB_REF':'refs/heads/main','GITHUB_SHA':'c'*40,
                 'GITHUB_RUN_ID':'1','GITHUB_RUN_ATTEMPT':'1'}
            with patch.object(c,'git',side_effect=['c'*40,'']):
                result=c.context(env,root=root,reader=lambda _:self.fail('No PR query for main'))
                self.assertIsNone(result['pr']);self.assertFalse(c.required(result));self.assertEqual(result['head'],'c'*40)

    def test_record_verifies_environment_before_scheduling_and_binds_output(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);(root/'build').mkdir();(root/c.review.POLICY).parent.mkdir(parents=True)
            (root/c.review.POLICY).write_bytes((ROOT/c.review.POLICY).read_bytes())
            (root/'build/security-report.json').write_text(json.dumps(self.report))
            (root/'build/security-source-review.json').write_text(json.dumps(self.source))
            output=root/'output';env,branches=self.environment()
            with patch.object(c,'context',return_value=self.ctx),patch.object(c,'required',return_value=True), \
                 patch.object(c,'api',side_effect=[env,branches]),patch.dict(c.os.environ,{'GITHUB_OUTPUT':str(output)}):
                result=c.record(root)
            self.assertEqual(result['technicalAttempt'],2)
            self.assertEqual(output.read_text(),'policy_required=true\n')
            output.unlink();(root/'build'/c.RECEIPT).unlink()
            with patch.object(c,'context',return_value=self.ctx),patch.object(c,'required',return_value=True), \
                 patch.object(c,'api',side_effect=[{},branches]),patch.dict(c.os.environ,{'GITHUB_OUTPUT':str(output)}),self.assertRaises(ValueError):
                c.record(root)
            self.assertFalse(output.exists());self.assertFalse((root/'build'/c.RECEIPT).exists())


if __name__ == '__main__': unittest.main()
