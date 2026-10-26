"""Reviewed entry paths and ordinary metadata; no exploit inputs."""
import copy
import hashlib
import io
import json
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from test_project_applicability import load, ROOT
from test_security_issues import FakeGitHub, ENV

usage = load('security-usage-applicability')
project = load('security-project-applicability')
issues = load('sync-security-issues')


class UsageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.policy = json.loads((ROOT/usage.CONFIG).read_text())
        self.rule = next(copy.deepcopy(r) for r in self.policy['rules'] if r['id']=='GHSA-3wwx-pv8p-q78v')
        self.data = json.loads((ROOT/usage.EVIDENCE).read_text())
        for name in self.data['workflows']:
            p = self.root/name; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes((ROOT/name).read_bytes())
        row = next(x for x in self.data['actions'] if x['repository']=='actions/checkout')
        entry = next(x for x in self.data['actionEntryPaths'] if x['action']==row['repository'])
        archive = self.root/row['cacheFile']; archive.parent.mkdir(parents=True)
        body = b'inert reviewed action fixture'
        with tarfile.open(archive, 'w:gz') as out:
            info = tarfile.TarInfo('official/'+entry['entrypoint']); info.size=len(body)
            out.addfile(info, io.BytesIO(body))
        row['archiveSHA256']=hashlib.sha256(archive.read_bytes()).hexdigest()
        entry['sha256']=entry['undiciSurface']['sha256']=hashlib.sha256(body).hexdigest()
        p=self.root/'Config/Security/action-bundles.json';p.parent.mkdir(parents=True,exist_ok=True)
        p.write_text(json.dumps({'bundles':self.data['actions']}))
        self.data['cases'][self.rule['case']]['sourceFiles'][str(p.relative_to(self.root))]=hashlib.sha256(p.read_bytes()).hexdigest()
        self.archive=archive;self.entry=entry;self.write_evidence()

    def write_evidence(self):
        p=self.root/usage.EVIDENCE;p.parent.mkdir(parents=True,exist_ok=True)
        p.write_text(json.dumps(self.data));self.rule['evidenceSHA256']=hashlib.sha256(p.read_bytes()).hexdigest()

    def test_same_exact_entry_accepts_but_changed_or_new_workflow_is_rejected(self):
        usage.verify(self.root,self.rule)
        p=self.root/'.github/workflows/security-checks.yml';p.write_text(p.read_text()+'\n# changed input')
        with self.assertRaisesRegex(ValueError,'consumer or configuration changed'):usage.verify(self.root,self.rule)
        p.write_bytes((ROOT/p.relative_to(self.root)).read_bytes())
        (p.parent/'new-consumer.yml').write_text('new workflow')
        with self.assertRaisesRegex(ValueError,'New or missing workflow'):usage.verify(self.root,self.rule)

    def test_bundle_identity_and_source_redirection_are_rejected(self):
        self.archive.write_bytes(b'altered archive')
        with self.assertRaisesRegex(ValueError,'archive changed'):usage.verify(self.root,self.rule)
        p=self.root/'.github/workflows/security-checks.yml';p.unlink();p.symlink_to(ROOT/'.github/workflows/security-checks.yml')
        with self.assertRaisesRegex(ValueError,'redirected'):usage.verify(self.root,self.rule)

    def test_undici_escape_dynamic_require_or_affected_api_is_not_accepted(self):
        original=copy.deepcopy(self.entry['undiciSurface'])
        for field,value in [('dynamicInternalRequires',['unknown']),
                            ('consumers',[{'properties':['WebSocket'],'escapes':[]}]),
                            ('consumers',[{'properties':['fetch'],'escapes':['unknown']}]),
                            ('features',[{'callersOutsideUndiciEntry':['unreviewed']}])]:
            self.entry['undiciSurface']=copy.deepcopy(original);self.entry['undiciSurface'][field]=value
            self.write_evidence()
            with self.assertRaisesRegex(ValueError,'Affected or unknown'):usage.verify(self.root,self.rule)

    def test_multi_origin_versions_require_complete_same_environment(self):
        rule=next(r for r in self.policy['rules'] if r['id']=='GHSA-4qv8-2p9j-2685' and r['scope']=='github-actions')
        proof={**rule,'version':None,'status':'not-affected','grantsRiskException':False,'environment':'ci',
               'ruleSHA256':'a'*64,'evidence':{}}
        versions=sorted({v for a in rule['originVersions'].values() for v in a})
        finding={**{k:rule[k] for k in ('id','component','scope')},'version':', '.join(versions),
                 'dependencyPaths':rule['origins'],'environmentObservations':[
                     {'environment':'ci','origin':o,'versions':v} for o,v in rule['originVersions'].items()]}
        self.assertTrue(project.covers(proof,finding,'ci'))
        for change in ({'version':'99.0.0'},{'scope':'development'},
                       {'dependencyPaths':rule['origins'][:-1]},
                       {'environmentObservations':[{**o,'environment':'local'} for o in finding['environmentObservations']]}):
            self.assertFalse(project.covers(proof,{**finding,**change},'ci'))
        different=copy.deepcopy(finding);different['environmentObservations'][0]['versions']=['99.0.0']
        self.assertFalse(project.covers(proof,different,'ci'))
        # Multiple affected installations in one origin may have separate observations.
        split=copy.deepcopy(finding)
        split['environmentObservations']=[{**o,'versions':[v]} for o in finding['environmentObservations'] for v in o['versions']]
        self.assertTrue(project.covers(proof,split,'ci'))

    def test_shared_advisory_cannot_borrow_another_scope_decision(self):
        rules=[r for r in self.policy['rules'] if r['id']=='GHSA-4qv8-2p9j-2685']
        self.assertEqual(len(rules),2)
        proofs=[{**r,'environment':'ci','status':'not-affected','grantsRiskException':False,
                 'ruleSHA256':'a'*64,'evidence':{}} for r in rules]
        project.validate_envelope({'observedEnvironment':'ci','projectApplicabilityProofs':proofs})
        with self.assertRaises(ValueError):
            project.validate_envelope({'observedEnvironment':'ci','projectApplicabilityProofs':[proofs[0],proofs[0]]})

    def test_new_usage_resolution_closes_once_and_reopens_same_issue_on_drift(self):
        import datetime as dt
        rule=self.rule;version=next(iter(rule['originVersions'].values()))[0]
        finding={'id':rule['id'],'component':rule['component'],'scope':rule['scope'],'version':version,
                 'severity':'moderate','status':'needs-review','queryComplete':True,
                 'url':'https://github.com/advisories/'+rule['id'],'dependencyPaths':rule['origins'],
                 'environmentObservations':[{'environment':'ci','origin':o,'versions':v} for o,v in rule['originVersions'].items()]}
        original={'schemaVersion':1,'checkedAt':dt.datetime.now(dt.timezone.utc).isoformat(),
                  'scanStatus':'complete','errors':[],'releaseTag':'v1.10.0','findings':[finding],
                  'rawFindings':[finding],'applicabilityReviews':[],'supplierFixReviews':[],
                  'observedEnvironment':'ci','observedOrigins':rule['origins'],'toolchainCoverage':{'checksComplete':True}}
        proof={**rule,'version':None,'environment':'ci','status':'not-affected','grantsRiskException':False,
               'ruleSHA256':'a'*64,'evidence':{}}
        current=copy.deepcopy(original);current.update(findings=[],projectApplicabilityProofs=[proof],
                         projectApplicabilityReviews=[{'finding':finding,'proof':proof}])
        api=FakeGitHub();issues.synchronize(original,api,True,ENV)
        self.assertEqual(issues.synchronize(current,api,True,ENV)[0]['action'],'close-not-applicable')
        self.assertTrue(project.owned_resolution(issues.fmt.parse_issue(api.issues[0])))
        self.assertEqual(issues.synchronize(current,api,True,ENV),[])
        issues.synchronize(original,api,True,ENV)
        self.assertEqual(len(api.issues),1);self.assertEqual(api.issues[0]['state'],'open')

    def test_pip_and_npm_verification_failures_are_not_converted_into_exclusions(self):
        from types import SimpleNamespace
        for case in ('offline-pip','npm-no-eventsource'):
            rule=next(r for r in self.policy['rules'] if r['case']==case)
            group=self.data['cases'][case]
            fake=SimpleNamespace(configuration=lambda _: {'pipVersion':self.data['pipVersion'],
                                 'wheelSHA256':self.data['pipWheelSHA256']},
                                 verify_environments=lambda *_: (_ for _ in ()).throw(ValueError('asset drift')),
                                 verify=lambda *_: (_ for _ in ()).throw(ValueError('asset drift')))
            with patch.object(usage,'evidence',return_value=(self.data,group)),patch.object(usage,'load',return_value=fake):
                with self.assertRaisesRegex(ValueError,'asset drift'):usage.verify(self.root,rule)


if __name__=='__main__':unittest.main()
