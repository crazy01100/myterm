"""Synthetic metadata and in-memory Issue lifecycle; no exploit inputs."""
import copy
import datetime as dt
import hashlib
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
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT/'scripts'/f'{name}.py')
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m


s = load('security-project-applicability')
envelope = load('security-pip-applicability')
from test_security_issues import FakeGitHub, ENV
issues = load('sync-security-issues')


class ApplicabilityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.policy = json.loads((ROOT/s.CONFIG).read_text())
        usage = self.root/'Config/Security/usage-applicability.json'
        usage.parent.mkdir(parents=True, exist_ok=True)
        usage.write_bytes((ROOT/'Config/Security/usage-applicability.json').read_bytes())
        self.rule = self.policy['rules'][0]
        self.advisory = {'id': 'PSF-2025-2', 'details': 'Windows-only fixture', 'aliases': ['CVE-2024-3220'], 'affected': []}
        self.rule['advisorySHA256'] = s.advisory_digest(self.advisory, 'psf')
        self.write_policy()
        self.finding = {'id': 'PSF-2025-2', 'component': 'CPython', 'scope': 'development', 'version': '3.12.15',
            'severity': 'unknown', 'status': 'needs-review', 'queryComplete': True,
            'url': 'https://osv.dev/vulnerability/PSF-2025-2', 'dependencyPaths': self.rule['origins'],
            'environmentObservations': [{'environment': 'ci', 'origin': o, 'versions': ['3.12.15']} for o in self.rule['origins']]}
        env = patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}); env.start(); self.addCleanup(env.stop)
        self.platforms = {'interpreters': [{'origin': o, 'platform': 'linux', 'version': '3.12.16'} for o in self.rule['origins']]}

    def write_policy(self):
        p = self.root/s.CONFIG; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(json.dumps(self.policy))

    def report(self, findings=None):
        findings = [self.finding] if findings is None else findings
        return {'schemaVersion': 1, 'checkedAt': dt.datetime.now(dt.timezone.utc).isoformat(), 'scanStatus': 'complete',
            'errors': [], 'releaseTag': 'v1.10.0', 'findings': copy.deepcopy(findings), 'rawFindings': copy.deepcopy(findings),
            'applicabilityReviews': [], 'supplierFixReviews': [], 'toolchainCoverage': {'checksComplete': True},
            'observedEnvironment': 'ci', 'observedOrigins': self.rule['origins']}

    def classify(self, r):
        with patch.object(s, 'python_platforms', return_value=self.platforms):
            s.classify(r, self.root, lambda *_: self.advisory)

    def test_raw_matches_retained_and_live_evidence_revalidated(self):
        r = self.report(); self.classify(r)
        self.assertEqual(r['findings'], []); self.assertEqual(r['rawFindings'], [self.finding])
        envelope.validate_envelope(r); s.validate_envelope(r)
        with patch.object(s, 'python_platforms', return_value=self.platforms):
            s.revalidate(r, self.root, lambda *_: self.advisory)
        with patch.object(s, 'python_platforms', side_effect=ValueError('drift')):
            with self.assertRaises(ValueError): s.revalidate(r, self.root, lambda *_: self.advisory)

    def test_changed_advisory_or_failed_query_retains_findings(self):
        for fetch in (lambda *_: {**self.advisory, 'details': 'changed'},
                      lambda *_: (_ for _ in ()).throw(OSError('offline'))):
            r = self.report(); s.classify(r, self.root, fetch)
            self.assertEqual(r['findings'], [self.finding]); self.assertTrue(r['errors'])
            self.assertFalse(r['projectApplicabilityProofs'])

    def test_go_advisory_uses_only_fixed_official_source_and_rejects_redirect(self):
        rule=self.policy['rules'][1];url='https://vuln.go.dev/ID/GO-2026-5932.json'
        response=MagicMock();response.__enter__.return_value=response;response.url=url
        response.read.return_value=b'{"id":"GO-2026-5932"}'
        trust=SimpleNamespace(https_context=lambda _:'verified-context')
        with patch.object(s,'load',return_value=trust),patch.object(s.urllib.request,'urlopen',return_value=response) as request:
            self.assertEqual(s.fetch_advisory(rule,self.root),{'id':'GO-2026-5932'})
            self.assertEqual(request.call_args.args,(url,))
            self.assertEqual(request.call_args.kwargs['context'],'verified-context')
            response.url='https://example.com/redirect'
            with self.assertRaises(ValueError):s.fetch_advisory(rule,self.root)
            with self.assertRaises(ValueError):s.fetch_advisory({**rule,'id':'GO-unreviewed'},self.root)

    def test_other_platforms_and_unknown_process_version_are_rejected(self):
        trust = SimpleNamespace(configuration=lambda _: {}, inspect_environment=lambda *_: {'python': '3.12.15'},
                                validate_current=lambda *_: None)
        for platform, version in (('win32','3.12.15'),('unknown','3.12.15'),('linux','9.0.0')):
            with patch.object(s, 'load', return_value=trust), patch.object(s.subprocess, 'run',
                    return_value=subprocess.CompletedProcess([],0,json.dumps({'platform':platform,'version':version}),'')):
                with self.assertRaises(ValueError): s.python_platforms(self.root,self.rule)

    def test_mixed_environments_origins_scopes_and_incomplete_queries_are_not_excluded(self):
        variants = [{'scope':'released-app'}, {'queryComplete':False}, {'id':'PSF-other'},
                    {'dependencyPaths':['unreviewed']}, {'environmentObservations':[
                        {'environment':'local','origin':o,'versions':['3.12.15']} for o in self.rule['origins']]}]
        for change in variants:
            f = {**self.finding, **change}; r = self.report([f]); self.classify(r)
            self.assertEqual(r['findings'], [f]); self.assertFalse(r['projectApplicabilityReviews'])

    def test_coverage_proof_exists_without_current_version_match(self):
        r = self.report([]); self.classify(r)
        self.assertEqual(len(r['projectApplicabilityProofs']),1)
        self.assertFalse(r['projectApplicabilityReviews'])
        self.assertIsNotNone(s.previous_decision(r,self.finding))

    def test_missing_prior_origin_or_other_environment_cannot_close(self):
        r = self.report([]); self.classify(r)
        f = copy.deepcopy(self.finding)
        f['environmentObservations'].append({'environment':'local','origin':self.rule['origins'][0],'versions':['3.12.15']})
        self.assertIsNone(s.previous_decision(r,f))
        f=copy.deepcopy(self.finding);f['dependencyPaths'].append('third/cpython')
        self.assertIsNone(s.previous_decision(r,f))

    def test_unrecognized_rule_and_forged_envelope_rejected(self):
        r = self.report(); self.classify(r)
        r['projectApplicabilityProofs'][0]['grantsRiskException']=True
        with self.assertRaises(ValueError): s.validate_envelope(r)
        r = self.report(); self.classify(r);r['projectApplicabilityReviews']=[]
        with self.assertRaises(ValueError): envelope.validate_envelope(r)
        self.policy['rules'][0]['origins'].append('unexpected/cpython');self.write_policy()
        with self.assertRaises(ValueError): s.configuration(self.root)

    def test_close_not_applicable_then_same_scan_is_noop_and_drift_reopens_same_issue(self):
        api=FakeGitHub();original=self.report();issues.synchronize(original,api,True,ENV)
        current=self.report();self.classify(current)
        result=issues.synchronize(current,api,True,ENV)
        self.assertEqual(result[0]['action'],'close-not-applicable')
        self.assertEqual(api.issues[0]['state_reason'],'not_planned')
        self.assertIn('[不適用]',api.issues[0]['title'])
        self.assertIn('不是套件已修補',api.issues[0]['body'])
        self.assertEqual(issues.synchronize(current,api,True,ENV),[])
        self.assertEqual(len(api.comments),1)
        issues.synchronize(original,api,True,ENV)
        self.assertEqual(len(api.issues),1);self.assertEqual(api.issues[0]['state'],'open')
        self.assertNotIn('applicabilityResolution',issues.fmt.parse_issue(api.issues[0]))
        self.assertEqual(issues.synchronize(original,api,True,ENV),[])

    def test_historical_version_closes_only_when_current_origin_proven(self):
        api=FakeGitHub();issues.synchronize(self.report(),api,True,ENV)
        current=self.report([]);self.classify(current)
        issues.synchronize(current,api,True,ENV)
        self.assertEqual(api.issues[0]['state'],'closed')
        self.assertTrue(s.owned_resolution(issues.fmt.parse_issue(api.issues[0])))

    def test_partial_scan_never_closes_but_confirmed_risk_can_reopen(self):
        api=FakeGitHub();original=self.report();issues.synchronize(original,api,True,ENV)
        partial=self.report();self.classify(partial)
        partial.update(scanStatus='failed',errors=['source failed'],publicationMode='additive',
                       sourceReview={'sourceVerified':True,'grantsRiskException':False,'policySHA256':'a'*64})
        issues.synchronize(partial,api,True,ENV)
        self.assertEqual(api.issues[0]['state'],'open')
        current=self.report();self.classify(current);issues.synchronize(current,api,True,ENV)
        partial=copy.deepcopy(original);partial.update(scanStatus='failed',errors=['proof failed'],publicationMode='additive',
                       sourceReview={'sourceVerified':True,'grantsRiskException':False,'policySHA256':'a'*64})
        issues.synchronize(partial,api,True,ENV)
        self.assertEqual(len(api.issues),1);self.assertEqual(api.issues[0]['state'],'open')

    def test_other_manual_not_planned_record_is_not_reopened(self):
        api=FakeGitHub();original=self.report();issues.synchronize(original,api,True,ENV)
        api.issues[0].update(state='closed',state_reason='not_planned')
        issues.synchronize(original,api,True,ENV)
        self.assertEqual(api.issues[0]['state'],'closed')

    def test_resolution_links_only_verified_repository_commit_and_run(self):
        r=self.report();r['sourceReview']={'checkoutCommit':'a'*40}
        env={**ENV,'GITHUB_REPOSITORY':'crazy01100/myterm','GITHUB_RUN_ID':'123'}
        text=issues.verification_links(r,env)
        self.assertIn('/commit/'+'a'*40,text);self.assertIn('/actions/runs/123',text)
        self.assertEqual(issues.verification_links(r,{**env,'GITHUB_RUN_ID':'bad/path'}),'')
        self.assertEqual(issues.verification_links(r,{**env,'GITHUB_REPOSITORY':'other/repository'}),'')

    def action_fixture(self):
        rule=copy.deepcopy(self.policy['rules'][3]);row=rule['action'];body=b'fixture commonjs bundle'
        archive=self.root/row['cacheFile'];archive.parent.mkdir(parents=True,exist_ok=True)
        with tarfile.open(archive,'w:gz') as tar:
            item=tarfile.TarInfo('official/'+rule['entrypoint']);item.size=len(body);tar.addfile(item,io.BytesIO(body))
        row['archiveSHA256']=hashlib.sha256(archive.read_bytes()).hexdigest()
        rule['bundleSHA256']=hashlib.sha256(body).hexdigest()
        config=self.root/'Config/Security/action-bundles.json';config.write_text(json.dumps({'bundles':[row]}))
        evidence={'kind':'reviewed-official-action-subset','bundleSHA256':rule['bundleSHA256'],
                  'unresolvedDependencies':[],'unmappedLodashCandidates':[],'ambiguousReexports':[],
                  'ambiguousIdentityCandidates':[],'matches':[{'module':1,'source':['package/defaults.js']}]}
        path=self.root/rule['evidenceFile'];path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text(json.dumps(evidence));rule['evidenceSHA256']=hashlib.sha256(path.read_bytes()).hexdigest()
        return rule,evidence,path,archive

    def test_exact_bundle_required_and_added_affected_function_rejected(self):
        rule,e,path,archive=self.action_fixture();s.action_subset(self.root,rule)
        archive.write_bytes(b'drift')
        with self.assertRaises(ValueError):s.action_subset(self.root,rule)
        rule,e,path,archive=self.action_fixture();e['matches'].append({'module':2,'source':['package/template.js']})
        path.write_text(json.dumps(e));rule['evidenceSHA256']=hashlib.sha256(path.read_bytes()).hexdigest()
        with self.assertRaises(ValueError):s.action_subset(self.root,rule)

    def test_unresolved_module_graph_or_evidence_change_rejected(self):
        rule,e,path,archive=self.action_fixture();path.write_text('{}')
        with self.assertRaises(ValueError):s.action_subset(self.root,rule)
        rule,e,path,archive=self.action_fixture();e['unresolvedDependencies']=['unknown']
        path.write_text(json.dumps(e));rule['evidenceSHA256']=hashlib.sha256(path.read_bytes()).hexdigest()
        with self.assertRaises(ValueError):s.action_subset(self.root,rule)

    def test_gh_binary_must_match_reviewed_graph_and_exclude_openpgp(self):
        rule=copy.deepcopy(self.policy['rules'][1]);binary=self.root/'gh';binary.write_bytes(b'fixture')
        item={'binarySHA256':hashlib.sha256(b'fixture').hexdigest(),'compiler':'go1.27.3','sourceCommit':'a'*40,
              'packageCount':1,'packagePaths':['github.com/cli/cli/v2/cmd/gh'],'affectedPackagePresent':False,
              'moduleVersionsMatch':True,'customBuildTags':False}
        graph={'kind':'reviewed-official-gh-build-graph','version':'2.103.2','platforms':{'Linux-x86_64':item}}
        path=self.root/rule['evidenceFile'];path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(graph))
        rule['evidenceSHA256']=hashlib.sha256(path.read_bytes()).hexdigest()
        runtime=SimpleNamespace(verify=lambda _:binary,selected=lambda _:({'version':'2.103.2'},'Linux-x86_64',{'sha256':'b'*64}))
        info=SimpleNamespace(parse=lambda _:{'compiler':'go1.27.3','modules':[{'name':'golang.org/x/crypto','version':'v0.58.0'}]})
        with patch.object(s,'load',side_effect=lambda name:runtime if name=='project-gh-runtime' else info):
            s.gh_subset(self.root,rule);binary.write_bytes(b'drift')
            with self.assertRaises(ValueError):s.gh_subset(self.root,rule)
            binary.write_bytes(b'fixture');item['packagePaths']=['golang.org/x/crypto/openpgp']
            path.write_text(json.dumps(graph));rule['evidenceSHA256']=hashlib.sha256(path.read_bytes()).hexdigest()
            with self.assertRaises(ValueError):s.gh_subset(self.root,rule)


if __name__ == '__main__':
    unittest.main()
