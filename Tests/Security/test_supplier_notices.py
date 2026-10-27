"""Actual-tool supplier metadata fixtures; no network, installs or payloads."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

ROOT=Path(__file__).resolve().parents[2]
def load(name):
 s=importlib.util.spec_from_file_location(name,ROOT/'scripts'/f'{name}.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
m=load('security-supplier-notices')

class SupplierTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
  self.java={'component':'java','vendor':'Fixture vendor','runtimeVersion':'21.0.13+9-LTS'}
  self.inventory={'environment':'local','purpose':'audit','components':[], 'coverage':[
   {'id':'deployment','status':'inventoried'},
   {'id':'emulator','status':'inventoried','tools':[self.java]}]}
  self.content={'workers':{'advisories':[]},'workerd':{'advisories':[]},'jdk':{'index':'fixture'}}
  self.fact={'id':'CVE-2099-1234','component':'Java','version':'21.0.13+9','status':'needs-review','severity':'high'}
  self.policy={'schemaVersion':2,'grantsRiskException':False,'reviewedJDKs':[dict(self.java)],
   'jdkNoticeCursor':m.digest(self.content['jdk']),'jdkFindings':[self.fact],
   'candidateFindings':[{'id':'CVE-2099-5678','component':'SQLite','classification':'bundled-only-use-unconfirmed','gateEffect':'none'}]}
  self.path=self.root/m.CONFIG;self.path.parent.mkdir(parents=True);self.save()
 def save(self):
  self.path.write_text(json.dumps(self.policy))
  (self.root/m.CURSOR).write_text(json.dumps({'jdkNoticeCursor':self.policy['jdkNoticeCursor']}))
 def scan(self):return m.scan(self.inventory,self.root,lambda key:copy.deepcopy(self.content[key]))
 def test_complete_queries_do_not_waive_known_risk_or_claim_exhaustive_coverage(self):
  result=self.scan();self.assertEqual(result['errors'],[]);self.assertEqual(len(result['receipts']),2)
  self.assertFalse(result['allDependenciesScanned'])
  self.assertTrue(all(r['status']=='complete' and r['closureEligible'] is False for r in result['receipts']))
  self.assertEqual([r['id'] for r in result['findings']],[self.fact['id']])
 def test_changed_notice_is_normal_triage_not_source_revision(self):
  self.content['jdk']={'index':'amended'};result=self.scan()
  self.assertEqual(result['errors'],[]);self.assertEqual(len(result['notices']),1)
  self.assertEqual(result['notices'][0]['source'],'jdk-security')
  self.assertEqual(len(result['findings']),1)
 def test_unavailable_supplier_preserves_independent_risks(self):
  def fetch(key):
   if key=='workers':raise OSError('offline')
   return self.content[key]
  result=m.scan(self.inventory,self.root,fetch)
  self.assertEqual([r['collector'] for r in result['receipts'] if r['status']!='complete'],['deployment'])
  self.assertEqual(len(result['findings']),1)
 def test_jdk_query_failure_preserves_known_risk(self):
  def fetch(key):
   if key=='jdk':raise OSError('offline')
   return self.content[key]
  result=m.scan(self.inventory,self.root,fetch)
  self.assertEqual(len(result['findings']),1);self.assertFalse(result['findings'][0]['queryComplete'])
  self.assertTrue(result['errors'])
 def test_ci_receipt_uses_actual_ci_java_not_local_os_identity(self):
  self.inventory['environment']='ci';result=self.scan()
  self.assertEqual(result['errors'],[])
  self.assertEqual(result['findings'][0]['environmentObservations'][0]['environment'],'ci')
 def test_unknown_jdk_does_not_inherit_another_version_review(self):
  self.java['runtimeVersion']='22.0.1';result=self.scan()
  self.assertEqual([r['collector'] for r in result['receipts'] if r['status']!='complete'],['emulator'])
  self.assertEqual(result['findings'],[])
  receipt=next(r for r in result['receipts'] if r['collector']=='emulator')
  self.assertEqual(receipt['observedTool']['runtimeVersion'],'22.0.1')
  self.assertEqual(set(receipt['observedTool']),{'component','version','vendor','runtimeVersion','origin','use'})
 def test_os_metadata_has_no_query_or_gate_effect(self):
  before=self.scan()
  self.inventory['coverage'].append({'id':'platform','status':'inventoried','evidence':[{'osVersion':'changed'}]})
  after=self.scan()
  self.assertEqual(before['findings'],after['findings']);self.assertEqual(after['errors'],[])
  self.assertEqual(set(after['observed']),{'workers','workerd','jdk'})
 def test_candidate_not_published_as_actual_vulnerability(self):
  result=self.scan()
  self.assertEqual(result['candidateFindings'],self.policy['candidateFindings'])
  self.assertNotIn('SQLite',[f['component'] for f in result['findings']])
 def test_missing_actual_tool_and_waiver_rejected(self):
  self.inventory['coverage'][1]['tools']=[]
  self.assertEqual(len(self.scan()['errors']),1)
  self.policy['grantsRiskException']=True;self.save()
  with self.assertRaises(ValueError):self.scan()
 def test_actual_deployment_package_advisory_preserved(self):
  self.inventory['components']=[{'collector':'deployment','name':'fixture','version':'1.0.0','origin':'deployment/fixture'}]
  self.content['workers']['advisories']=[{'ghsa_id':'GHSA-2345-6789-abcd','severity':'high', 'vulnerabilities':[
   {'package':{'name':'fixture'},'vulnerable_version_range':'< 2.0.0','patched_versions':'2.0.0'}]}]
  self.assertIn('GHSA-2345-6789-abcd',[f['id'] for f in self.scan()['findings']])
 def test_canonical_ranges_resolve_ambiguous_repository_text_without_waiver(self):
  self.inventory['components']=[{'collector':'deployment','name':'fixture','version':'4.152.0','origin':'deployment/fixture'}]
  original={'ghsa_id':'GHSA-2345-6789-abcd','severity':'high','vulnerabilities':[
   {'package':{'name':'fixture'},'vulnerable_version_range':'3.0.0 - 3.114.16, 4.0.0 - 4.59.0'}]}
  self.content['workers']['advisories']=[original]
  canonical={**original,'withdrawn_at':None,'vulnerabilities':[
   {'package':{'name':'fixture'},'vulnerable_version_range':'>= 4.0.0, < 4.59.1','first_patched_version':'4.59.1'}]}
  result=m.scan(self.inventory,self.root,lambda k:self.content[k],lambda i:canonical)
  self.assertEqual(result['errors'],[])
  self.assertNotIn(original['ghsa_id'],[f['id'] for f in result['findings']])
  self.assertIn('canonical:'+original['ghsa_id'],result['observed'])
  canonical['ghsa_id']='GHSA-aaaa-bbbb-cccc'
  self.assertTrue(m.scan(self.inventory,self.root,lambda k:self.content[k],lambda i:canonical)['errors'])
 def test_prerelease_core_outside_stable_range_is_not_a_match(self):
  audit=load('security-audit')
  self.assertFalse(audit.affected('5.20261019.2-beta','>= 3.20230821.0, < 3.20231030.2'))
  self.assertIsNone(audit.affected('4.0.0-beta.4','>= 4.0.0-beta.3, < 4.5.5'))
  self.assertFalse(audit.affected('3.0.0-beta','>= 3.0.0, < 4.0.0'))
  self.assertTrue(audit.affected('3.0.0-beta','< 3.0.0'))
 def test_html_projection_excludes_executable_content(self):
  parser=m.Text();parser.feed('<script>secret</script><table><tr><td>tool notice</td></tr></table>')
  self.assertNotIn('secret',parser.parts);self.assertEqual(parser.rows,['tool notice'])
 def test_java_mitigation_requires_actual_environment_verified_store_and_complete_query(self):
  original_load=m.load
  proof={'id':m.JAVA_TRUST_CVE,'version':'21.0.13+9','derivedTruststoreSHA256':'a'*64}
  self.java.update(vendor='Eclipse Adoptium',origin='emulator/java',runtimeVersion='21.0.13+9-LTS',trustRemediation=proof)
  self.fact.update(id=m.JAVA_TRUST_CVE,component='Temurin',scope='development')
  self.policy['reviewedJDKs']=[dict(self.java)];self.save()
  def loader(name):return SimpleNamespace(trust_evidence=lambda root:copy.deepcopy(proof)) if name=='project-java-runtime' else original_load(name)
  with patch.object(m,'load',side_effect=loader),patch.dict(m.os.environ,{'GITHUB_ACTIONS':'false'}):
   result=self.scan();self.assertEqual(result['findings'],[]);self.assertEqual(len(result['remediations']),1)
   envelope={'supplierNotices':result,'observedEnvironment':'local','findings':[]}
   m.revalidate(envelope,self.root)
   result['remediations'][0]['evidence']['derivedTruststoreSHA256']='b'*64
   with self.assertRaises(ValueError):m.revalidate(envelope,self.root)
   self.java['trustRemediation']={**proof,'derivedTruststoreSHA256':'b'*64}
   mismatch=self.scan();self.assertTrue(mismatch['errors']);self.assertEqual(mismatch['findings'][0]['id'],m.JAVA_TRUST_CVE)
   self.java['trustRemediation']=proof;self.inventory['environment']='ci'
   mismatch=self.scan();self.assertTrue(mismatch['errors']);self.assertEqual(len(mismatch['findings']),1)
   self.inventory['environment']='local'
   def unavailable(key):
    if key=='jdk':raise OSError('offline')
    return self.content[key]
   failed=m.scan(self.inventory,self.root,unavailable)
   self.assertEqual(len(failed['findings']),1);self.assertEqual(failed['remediations'],[])
   self.assertTrue(failed['errors'])

if __name__=='__main__':unittest.main()
