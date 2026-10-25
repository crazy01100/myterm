"""Policy/provenance regression using local metadata mocks only."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('review',ROOT/'scripts/security-source-review.py')
s=importlib.util.module_from_spec(spec);spec.loader.exec_module(s)

class ProjectPolicyTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
  self.policy=json.loads((ROOT/s.POLICY).read_text());p=self.root/s.POLICY;p.parent.mkdir(parents=True);p.write_text(json.dumps(self.policy))
  self.env={'GITHUB_ACTIONS':'true','GITHUB_REPOSITORY':s.REPOSITORY,'GITHUB_SHA':'a'*40,'GITHUB_EVENT_NAME':'pull_request','GITHUB_REF':'refs/pull/71/merge'}
 def check(self,env=None,dirty=''):
  with patch.dict(s.os.environ,env or {},clear=True),patch.object(s.subprocess,'run',side_effect=[subprocess.CompletedProcess([],0,'a'*40),subprocess.CompletedProcess([],0,dirty)]):
   return s.source_check(self.root)
 def test_local_edits_do_not_require_new_fingerprint_or_allow_publication(self):
  result=self.check(dirty=' M scripts/security-audit.py')
  self.assertTrue(result['sourceVerified']);self.assertTrue(result['localChanges']);self.assertFalse(result['publicationAuthorized'])
 def test_pr_is_read_only_without_approval_precondition(self):
  with patch.object(s,'verify_ci_baseline',side_effect=AssertionError('Approval is a separate check')):
   result=self.check(self.env)
  self.assertTrue(result['validationOnly']);self.assertFalse(result['publicationAuthorized'])
 def test_release_validation_does_not_authorize_monitor_publication(self):
  result=self.check({**self.env,'GITHUB_EVENT_NAME':'release','GITHUB_REF':'refs/tags/v1.10.0'})
  self.assertTrue(result['sourceVerified']);self.assertFalse(result['publicationAuthorized'])
 def test_only_clean_original_default_branch_monitor_can_publish(self):
  env={**self.env,'GITHUB_EVENT_NAME':'schedule','GITHUB_REF':'refs/heads/main'}
  self.assertTrue(self.check(env)['publicationAuthorized'])
  self.assertFalse(self.check({**env,'GITHUB_REF':'refs/heads/topic'})['publicationAuthorized'])
  self.assertFalse(self.check({**env,'GITHUB_EVENT_NAME':'push'})['publicationAuthorized'])
  for changes in ({'GITHUB_REPOSITORY':'foreign/repo'},{'GITHUB_SHA':'b'*40},{'GITHUB_EVENT_NAME':'pull_request_target'}):
   with self.subTest(changes=changes),self.assertRaises(ValueError):self.check({**env,**changes})
  with self.assertRaises(ValueError):self.check(env,dirty=' M file')
 def test_invalid_contract_or_missing_git_cannot_pass(self):
  self.policy['decision']['grantsRiskException']=True;(self.root/s.POLICY).write_text(json.dumps(self.policy))
  with self.assertRaises(ValueError):self.check()
  (self.root/s.POLICY).write_text((ROOT/s.POLICY).read_text())
  with patch.object(s.subprocess,'run',side_effect=subprocess.CalledProcessError(1,'git')),self.assertRaises(subprocess.CalledProcessError):s.source_check(self.root)
 def trees(self,changes):
  base=[{'path':s.POLICY,'sha':'1'*40,'mode':'100644'},{'path':'scripts/security-audit.py','sha':'2'*40,'mode':'100644'}]
  head=copy.deepcopy(base);changes(head)
  with patch.object(s,'gh_read',side_effect=[{'tree':base,'truncated':False},{'tree':head,'truncated':False}]):
   return s.reviewed_base_changed(self.root,{'_reviewHead':'a'*40},'b'*40)
 def test_document_test_and_notice_cursor_edits_need_no_policy_revision(self):
  for path in ('README.md','Tests/Security/test_fixture.py','Config/Security/vendor-notices.json','Config/Security/supplier-notice-cursor.json'):
   with self.subTest(path=path):self.assertFalse(self.trees(lambda h:h.append({'path':path,'sha':'3'*40,'mode':'100644'})))
 def test_policy_changes_deletions_renames_and_executable_mode_require_review(self):
  for mutate in (lambda h:h.pop(),lambda h:h[1].update(path='scripts/renamed.py'),lambda h:h[1].update(sha='3'*40),lambda h:h[1].update(mode='100755'),lambda h:h.append({'path':'.github/workflows/new.yml','sha':'3'*40,'mode':'100644'})):
   self.assertTrue(self.trees(mutate))
 def test_truncated_tree_is_not_unchanged(self):
  with patch.object(s,'gh_read',return_value={'tree':[],'truncated':True}),self.assertRaises(ValueError):
   s.reviewed_base_changed(self.root,{'_reviewHead':'a'*40},'b'*40)

if __name__=='__main__':unittest.main()
