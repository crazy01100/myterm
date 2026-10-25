"""Synthetic collector evidence; no vulnerability payloads or live queries."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('merge_scope_audit',ROOT/'scripts/security-audit.py')
a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)


def finding(**changes):
    return {'id':'GHSA-fixture','component':'fixture','version':'1.0.0',
            'scope':'development','severity':'high','status':'affected',
            'url':'https://example.invalid/advisory','fixedVersion':'1.0.1',**changes}


def report_for(original=None,expanded=None):
    report={'checkedAt':'2026-10-25T00:00:00+00:00','scanStatus':'complete','errors':[],'findings':[],
            'toolchainCoverage':{'checksComplete':True},
            'packageMonitoring':{'queriesComplete':True},
            'vendorNotices':{'checksComplete':True},
            'collectionEvidence':{'schemaVersion':1,
                'baselineCommit':'22c3361bd0cce52086527a979ae61c3201d93763','collectors':[]}}
    for collector in sorted(a.BASELINE_COLLECTORS)+['expanded-toolchain']:
        start=len(report['findings'])
        report['findings'].extend(copy.deepcopy(expanded or []) if collector=='expanded-toolchain'
                                 else copy.deepcopy(original or []) if collector=='npm-project' else [])
        a.record_collection(report,collector,start,True)
    report['findings']=a.merge_findings(report['findings'])
    return report


class MonitorMergeScopeTests(unittest.TestCase):
    def test_expanded_high_is_preserved_but_not_a_merge_block(self):
        report=report_for(expanded=[finding()]);before=copy.deepcopy(report)
        self.assertFalse(a.blocking(report,merge_gate=True))
        self.assertTrue(a.blocking(report))  # Release/deployment stays strict.
        self.assertEqual(report,before)
        self.assertNotIn('acceptedRisk',report['findings'][0])

    def test_each_original_collector_blocks_independently(self):
        for collector in a.BASELINE_COLLECTORS:
            with self.subTest(collector=collector):
                report=report_for(expanded=[finding()])
                next(r for r in report['collectionEvidence']['collectors']
                     if r['collector']==collector)['findings']=[a.risk_projection(finding())]
                self.assertTrue(a.blocking(report,merge_gate=True))

    def test_same_advisory_in_both_scopes_cannot_remove_core_risk(self):
        report=report_for(original=[finding()],expanded=[finding(version='2.0.0',severity='low')])
        report['findings'][0]['acceptedRisk']=True  # Supplied flags are not authority.
        self.assertTrue(a.blocking(report,merge_gate=True))
        self.assertEqual(len(report['findings']),1)

    def test_expanded_severity_does_not_raise_core_low_severity(self):
        report=report_for(original=[finding(severity='low')],expanded=[finding(version='2.0.0')])
        self.assertFalse(a.blocking(report,merge_gate=True))
        self.assertEqual(report['findings'][0]['severity'],'high')

    def test_original_unknown_still_blocks(self):
        self.assertTrue(a.blocking(report_for(original=[finding(severity='low',status='needs-review')]),merge_gate=True))

    def test_new_notice_remains_visible_without_granting_release(self):
        report=report_for()
        report['vendorNotices'].update(requiresNoticeReview=True,changes=[{'title':'Fixture'}])
        self.assertFalse(a.blocking(report,merge_gate=True))
        self.assertTrue(a.blocking(report))
        self.assertTrue(report['vendorNotices']['changes'])

    def test_operational_and_coverage_failures_still_block(self):
        variants=[{'errors':['query unavailable']},{'coverageGaps':[{'collector':'python'}]},
                  {'coverageErrors':['missing provider']},{'toolchainCoverage':{'checksComplete':False}},
                  {'packageMonitoring':{'queriesComplete':False}},
                  {'vendorNotices':{'checksComplete':False}}]
        for change in variants:
            with self.subTest(change=change):
                report=report_for(expanded=[finding()]);report.update(change)
                self.assertTrue(a.blocking(report,merge_gate=True))

    def test_missing_duplicate_failed_or_unknown_collectors_fail_closed(self):
        for mutation in ('missing','duplicate','failed','unknown','empty'):
            with self.subTest(mutation=mutation):
                report=report_for();rows=report['collectionEvidence']['collectors']
                if mutation=='missing':rows.pop()
                if mutation=='duplicate':rows.append(copy.deepcopy(rows[0]))
                if mutation=='failed':rows[0]['status']='failed'
                if mutation=='unknown':rows[0]['collector']='monitor-only'
                if mutation=='empty':del report['collectionEvidence']
                self.assertTrue(a.blocking(report,merge_gate=True))

    def test_missing_expanded_receipts_fail_closed(self):
        for key in ('toolchainCoverage','packageMonitoring','vendorNotices'):
            report=report_for();del report[key]
            self.assertTrue(a.blocking(report,merge_gate=True))

    def test_report_or_baseline_tampering_fails_closed(self):
        for mutation in ('drop','lower','add','baseline'):
            with self.subTest(mutation=mutation):
                report=report_for(expanded=[finding()])
                if mutation=='drop':report['findings']=[]
                if mutation=='lower':report['findings'][0]['severity']='low'
                if mutation=='add':report['findings'].append(finding(id='GHSA-other'))
                if mutation=='baseline':report['collectionEvidence']['baselineCommit']='0'*40
                self.assertTrue(a.blocking(report,merge_gate=True))

    def test_original_cannot_be_removed_by_applicability_classification(self):
        report=report_for(original=[finding()])
        report['rawFindings']=copy.deepcopy(report['findings']);report['findings']=[]
        self.assertTrue(a.blocking(report,merge_gate=True))

    def test_run_captures_collectors_before_merging(self):
        def expanded(report):
            report['findings'].append(finding(version='2.0.0'))
            report.update({key:value for key,value in report_for().items()
                           if key in ('toolchainCoverage','packageMonitoring','vendorNotices')})
        with patch.dict(os.environ,{'GITHUB_ACTIONS':'false'}), \
             patch.object(a.module,'inventory',return_value=[]), \
             patch.object(a,'scan_runtime'),patch.object(a,'scan_actions'), \
             patch.object(a,'scan_npm',side_effect=lambda r:r['findings'].append(finding())), \
             patch.object(a,'scan_verifier'),patch.object(a,'scan_toolchain',side_effect=expanded):
            report=a.run()
        self.assertEqual(report['errors'],[])
        self.assertEqual(len(report['rawFindings']),1)
        core=a.baseline_findings(report)
        self.assertEqual(core[0]['version'],'1.0.0')
        self.assertEqual(report['findings'][0]['version'],'1.0.0, 2.0.0')
        self.assertTrue(a.blocking(report,merge_gate=True))

    def test_cli_merge_mode_is_explicit_and_mutually_exclusive(self):
        with tempfile.TemporaryDirectory() as temp,patch.object(a,'run',return_value=report_for(expanded=[finding()])), \
             patch.object(a,'write_summary'),patch('builtins.print'):
            output=str(Path(temp)/'report.json')
            with patch('sys.argv',['audit','--output',output,'--merge-gate']):
                self.assertEqual(a.main(),0)
            self.assertEqual(json.loads(Path(output).read_text())['gateEvaluation']['purpose'],'merge')
            with patch('sys.argv',['audit','--output',output]):self.assertEqual(a.main(),1)
            with patch('sys.argv',['audit','--output',output,'--monitor','--merge-gate']):
                with self.assertRaises(SystemExit) as caught:a.main()
                self.assertEqual(caught.exception.code,2)

    def test_only_merge_workflow_selects_merge_policy(self):
        gate=(ROOT/'.github/workflows/security-gate.yml').read_text()
        self.assertIn('security-audit.py --merge-gate --output',gate)
        self.assertNotIn('continue-on-error',gate)
        self.assertNotIn('security-audit.py --monitor',gate)
        for name in ('scripts/release.sh','scripts/prepare-release-build.sh',
                     '.github/workflows/deploy-update-site.yml'):
            self.assertNotIn('--merge-gate',(ROOT/name).read_text())

    def test_summary_uses_same_gate_result_as_exit_and_saved_report(self):
        report=report_for(expanded=[finding()])
        report['gateEvaluation']={'purpose':'merge','blocking':False}
        with tempfile.TemporaryDirectory() as temp, \
             patch.dict(os.environ,{'GITHUB_STEP_SUMMARY':str(Path(temp)/'summary.md')}), \
             patch.object(a,'blocking',side_effect=AssertionError('Do not requery during formatting')):
            a.write_summary(report,False,merge_gate=True)
            self.assertIn('合併安全門檻通過',(Path(temp)/'summary.md').read_text())


if __name__=='__main__':unittest.main()
