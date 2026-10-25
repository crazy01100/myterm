"""Metadata-only fixtures; no runtime installation or vulnerability payloads."""
import copy
import gzip
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('runtime',ROOT/'scripts/security-runtime-advisories.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)


class RuntimeAdvisoryTests(unittest.TestCase):
    def test_archive_url_rejects_lookalike_hosts_and_paths_before_network(self):
        base='https://codeload.github.com/nodejs/security-wg/tar.gz/'+'a'*40
        with patch.object(m.urllib.request,'urlopen',side_effect=AssertionError('Network forbidden')) as fetch:
            for url in (base.replace('codeload.github','codeloadXgithub'),
                        base.replace('github.com','githubXcom'),base.replace('tar.gz','tarXgz'),
                        base+'?x=1',base.replace('https:','http:')):
                with self.subTest(url=url),self.assertRaises(ValueError):m.get_bytes(url)
            fetch.assert_not_called()

    def inventory(self):
        return {'environment':'fixture','coverage':[
            {'id':'node','status':'inventoried','evidence':[{'component':'node','vendorVersion':'24.22.1','role':'node-runtime'}]},
            {'id':'python','status':'inventoried','evidence':[
                {'component':component,'vendorVersion':value,'role':role}
                for role in ('python-runtime','security-tools')
                for component,value in (('python','3.12.15'),('python-implementation','cpython'))]}]}

    def database(self, rows=None):
        commit='a'*40
        rows=rows or {'1.json':{'cve':['CVE-2099-1234'],'vulnerable':'24.x','patched':'^24.22.1','severity':'high'},
                      '2.json':{'cve':['CVE-2099-1235'],'vulnerable':'24.x','patched':'^24.23.0','severity':'low'}}
        contents={name:json.dumps(value).encode() for name,value in rows.items()}
        listing=[{'name':name,'path':'vuln/core/'+name,'type':'file','size':len(raw),
                  'sha':hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()} for name,raw in contents.items()]
        listing.append({'name':'index.json','type':'file'})
        def archive(changes=None, link=False):
            data=io.BytesIO()
            with tarfile.open(fileobj=data,mode='w:gz') as tar:
                for name,raw in (contents if changes is None else changes).items():
                    info=tarfile.TarInfo('security-wg-'+commit+'/vuln/core/'+name)
                    if link:info.type=tarfile.SYMTYPE;info.linkname='/outside'
                    else:info.size=len(raw)
                    tar.addfile(info,None if link else io.BytesIO(raw))
            return data.getvalue()
        calls=[]
        def gh(endpoint):
            calls.append(endpoint)
            if endpoint.endswith('/commits/main'):return {'sha':commit}
            self.assertTrue(endpoint.endswith('?ref='+commit));return copy.deepcopy(listing)
        return gh,archive,contents,listing,calls

    def test_stable_ranges_respect_patch_branch_and_partial_comparators(self):
        cases=[('24.22.1','24.x',True),('24.22.1','^24.22.1',True),('24.22.0','^24.22.1',False),
               ('24.22.1','^22.23.4 || ^24.23.0',False),('24.22.1','<=10',False),
               ('10.9.0','<=10',True),('11.0.0','>10',True),('0.0.5','^0.0',True),
               ('0.0.5','^0.0.4',False),('24.22.1','~24.21.0',False),
               ('6.1.0','>=6.0.0 <6.2.0 || 5.x || 4.x',True),('24.22.1','unsupported',None)]
        for version,expression,want in cases:
            with self.subTest(expression=expression):self.assertIs(m.stable_range(version,expression),want)
        with self.assertRaises(ValueError):m.stable_range('24.22.1-rc.1','24.x')

    def test_complete_snapshot_does_not_trust_lagging_index(self):
        gh,archive,_,_,calls=self.database()
        result=m.scan_node(self.inventory(),gh,lambda _:archive())
        self.assertEqual(result['queriedRecords'],2)
        self.assertEqual([f['id'] for f in result['findings']],['CVE-2099-1235'])
        self.assertEqual(result['findings'][0]['status'],'needs-review')
        self.assertFalse(result['vendorBackportsCovered']);self.assertEqual(len(calls),2)

    def test_missing_changed_or_linked_archive_record_is_rejected(self):
        gh,archive,contents,_,_=self.database()
        for raw in (archive({'1.json':contents['1.json']}),archive({**contents,'2.json':b'changed'}),archive(link=True)):
            with self.assertRaises(ValueError):m.node_records(gh,lambda _:raw)

    def test_duplicate_unknown_or_truncated_listing_cannot_claim_zero(self):
        gh,archive,_,listing,_=self.database()
        listing.append(listing[0])
        with self.assertRaises(ValueError):m.node_records(gh,lambda _:archive())
        listing.pop();listing[0]['path']='other/1.json'
        with self.assertRaises(ValueError):m.node_records(gh,lambda _:archive())
        with self.assertRaises(ValueError):m.node_records(lambda _:[])

    def test_oversized_unused_member_is_rejected_before_reading_its_body(self):
        gh,_,_,_,_=self.database()
        header=tarfile.TarInfo('unrelated-entry');header.size=129*1024*1024
        raw=gzip.compress(header.tobuf(format=tarfile.USTAR_FORMAT)+b'\0'*1024)
        with self.assertRaisesRegex(ValueError,'Expanded database archive'):
            m.node_records(gh,lambda _:raw)

    def test_unknown_range_retains_review(self):
        rows={'1.json':{'cve':['CVE-2099-1234'],'vulnerable':'unknown','patched':'unknown'}}
        gh,archive,_,_,_=self.database(rows)
        result=m.scan_node(self.inventory(),gh,lambda _:archive())
        self.assertEqual(len(result['findings']),1);self.assertEqual(result['findings'][0]['severity'],'unknown')

    def test_python_versions_are_queried_once_with_both_origins_retained(self):
        calls=[]
        def gh(endpoint):calls.append(endpoint);return {'sha':'b'*40}
        def query(url,payload):calls.append(payload);return {}
        result=m.scan_python(self.inventory(),gh,query)
        self.assertEqual(result['findings'],[]);self.assertEqual(len(result['sources']),2)
        self.assertEqual(len(calls),2);self.assertEqual(calls[1],{'commit':'b'*40})
        self.assertFalse(result['vendorBackportsCovered'])

    def python_advisory(self):
        return {'id':'PSF-2099-1','affected':[{'ranges':[{'type':'GIT','repo':'https://github.com/python/cpython'}]}]}

    def test_python_findings_preserve_scope_and_unknown_severity(self):
        result=m.scan_python(self.inventory(),lambda _: {'sha':'b'*40},lambda *a:{'vulns':[self.python_advisory()]})
        self.assertEqual(len(result['findings']),2)
        self.assertEqual({f['dependencyPaths'][0] for f in result['findings']},{'python-runtime/cpython','security-tools/cpython'})
        self.assertTrue(all(f['severity']=='unknown' and f['status']=='needs-review' for f in result['findings']))

    def test_python_wrong_repo_duplicate_or_incomplete_query_blocks(self):
        wrong=self.python_advisory();wrong['affected'][0]['ranges'][0]['repo']='https://github.com/other/repo'
        cases=[{'error':'query failure'},{'next_page_token':'more'},{'vulns':[wrong]},
               {'vulns':[self.python_advisory(),self.python_advisory()]},
               {'vulns':[{**self.python_advisory(),'withdrawn':'2099-01-01T00:00:00Z'}]}]
        for response in cases:
            with self.subTest(response=response),self.assertRaises(ValueError):
                m.scan_python(self.inventory(),lambda _: {'sha':'b'*40},lambda *a:response)

    def test_missing_or_non_cpython_identity_cannot_use_upstream_mapping(self):
        inventory=self.inventory();inventory['coverage'][1]['evidence'][1]['vendorVersion']='pypy'
        with self.assertRaises(ValueError):m.scan_python(inventory,lambda _:None,lambda *a:None)
        inventory=self.inventory();inventory['coverage'][0]['evidence']=[]
        with self.assertRaises(ValueError):m.scan_node(inventory,lambda _:None)


if __name__=='__main__':unittest.main()
