import datetime as dt
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('audit',ROOT/'scripts/security-audit.py')
a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)

class AuditPolicyTests(unittest.TestCase):
    def test_fixed_version_does_not_match(self):self.assertFalse(a.affected('2.9.6','<= 2.9.5'))
    def test_compound_range(self):
        self.assertTrue(a.affected('2.9.5','>= 2.2.0, <= 2.9.5'))
        self.assertFalse(a.affected('2.1.9','>= 2.2.0, <= 2.9.5'))
    def test_unknown_is_not_safe(self):
        for value in ['before commit','^2.9.5','>= 2.9.5-beta',None]:self.assertIsNone(a.affected('2.9.6',value))
    def test_vendor_commit_ancestry(self):
        with patch.object(a,'gh',return_value={'status':'ahead'}) as call:
            self.assertTrue(a.vendor_is_patched('owner/repo','b'*40,'Anything after '+'a'*40))
            self.assertIn('a'*40,call.call_args[0][0])
    def test_api_failure_is_not_safe_vendor(self):
        with patch.object(a,'gh',side_effect=ValueError('offline')):self.assertIsNone(a.vendor_is_patched('o/r','b'*40,'1.2.3'))
    def test_query_error_blocks(self):self.assertTrue(a.blocking({'errors':['offline'],'findings':[]}))
    def test_released_old_version_does_not_block_its_fix(self):
        self.assertFalse(a.blocking({'errors':[],'findings':[{'scope':'released-app','severity':'high','status':'affected'}]}))
    def test_current_unknown_blocks(self):
        self.assertTrue(a.blocking({'errors':[],'findings':[{'scope':'current-source','severity':'low','status':'needs-review'}]}))
    def test_exception_exact_scope_version_and_expiry(self):
        finding={'id':'GHSA-example','component':'fixture','version':'1.0.0','scope':'development','severity':'moderate','status':'affected'}
        exception={**finding,'acceptedBy':'test-user','reason':'test-only policy fixture','acceptedAt':'2026-09-11T00:00:00+00:00','expiresAt':'2026-09-18T00:00:00+00:00'}
        report={'errors':[],'findings':[finding.copy()]}
        a.apply_exceptions(report,{'schemaVersion':1,'exceptions':[exception]},dt.datetime(2026,9,12,tzinfo=dt.timezone.utc))
        self.assertFalse(a.blocking(report))
        a.apply_exceptions(report,{'schemaVersion':1,'exceptions':[exception]},dt.datetime(2026,9,18,tzinfo=dt.timezone.utc))
        self.assertTrue(a.blocking(report))
        report['findings']=[{**finding,'version':'1.0.1'}]
        a.apply_exceptions(report,{'schemaVersion':1,'exceptions':[exception]},dt.datetime(2026,9,12,tzinfo=dt.timezone.utc))
        self.assertTrue(a.blocking(report))
    def test_exception_not_open_ended(self):
        f={'id':'x','component':'x','version':'1','scope':'development','severity':'moderate','status':'affected'}
        e={**f,'acceptedBy':'test','reason':'fixture','acceptedAt':'2026-01-01T00:00:00+00:00','expiresAt':'2027-01-01T00:00:00+00:00'}
        with self.assertRaises(ValueError):a.apply_exceptions({'findings':[f]}, {'schemaVersion':1,'exceptions':[e]})

if __name__=='__main__':unittest.main()
