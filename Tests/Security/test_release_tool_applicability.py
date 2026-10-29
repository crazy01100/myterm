"""Exact tool/metadata boundaries for the approved eight alerts; no exploits."""
import copy
import hashlib
import json
import struct
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from test_project_applicability import ROOT, load

project = load('security-project-applicability')
usage = load('security-usage-applicability')
inventory = load('go-build-inventory')


def table(names):
    strings = b'\0'.join(n.encode() for n in names) + b'\0'
    end = 72 + len(strings)
    # One concrete function; additional names represent inline functions.
    return (b'\xf1\xff\xff\xff\0\0\x01\x08'
            + struct.pack('<8Q', 1, 1, 0x1000, 72, end, end, end, end)
            + strings + struct.pack('<III', 0, 12, 16) + struct.pack('<Ii', 0, 0))


class FunctionTableTests(unittest.TestCase):
    def test_inlined_names_are_not_omitted_and_unrelated_binary_strings_not_used(self):
        names = ['runtime.main', 'golang.org/x/net/html.Parse']
        self.assertEqual(inventory.function_names(table(names)), sorted(names))
        self.assertEqual(inventory.function_names(b'unrelated Parse\0' + table(['runtime.main'])), ['runtime.main'])

    def test_ambiguous_truncated_and_out_of_bounds_tables_fail_closed(self):
        raw = table(['runtime.main'])
        invalid = [b'no table', raw[:32], raw[:-2], raw + raw]
        changed = bytearray(raw); struct.pack_into('<Q', changed, 32, len(raw) + 1); invalid.append(bytes(changed))
        changed = bytearray(raw); struct.pack_into('<i', changed, len(raw) - 4, 1); invalid.append(bytes(changed))
        for blob in invalid:
            with self.subTest(size=len(blob)), self.assertRaises(ValueError):
                inventory.function_names(blob)


class ReleaseToolTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.rules = project.configuration(ROOT)

    def write(self, name, data):
        p = self.root/name; p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(data)); return hashlib.sha256(p.read_bytes()).hexdigest()

    def test_scope_contains_exact_eight_new_decisions_and_four_remain_unhandled(self):
        ids = {'GHSA-j586-36cw-2gc2', 'GO-2026-6860', 'GO-2026-6866',
               'GHSA-2m5v-pch6-74hx', 'GHSA-9fm3-97px-rjf6', 'GHSA-qrxm-fqhp-jwvm'}
        self.assertEqual(sum(r['id'] in ids for r in self.rules), 8)
        for ident, component in [('GHSA-35p6-xmwp-9g52', 'undici'), ('GHSA-8gc5-j5rx-235r', 'fast-xml-parser'),
                                 ('GHSA-xjj6-f33q-929c', 'undici'), ('GHSA-qrxm-fqhp-jwvm', 'undici')]:
            self.assertIsNone(project.target({'id':ident, 'component':component, 'scope':'github-actions'}))

    def gh_fixture(self, names):
        rule = copy.deepcopy(next(r for r in self.rules if r['id']=='GO-2026-6860'))
        binary = self.root/'gh'; binary.write_bytes(table(names))
        sha = hashlib.sha256(binary.read_bytes()).hexdigest()
        graph = {'version':'2.103.2', 'platforms':{'Linux-x86_64':{
            'binarySHA256':sha, 'compiler':'go1.27.3', 'sourceCommit':'a'*40,
            'moduleVersionsMatch':True, 'customBuildTags':False}}}
        graph_sha = self.write('Config/Security/applicability/gh-openpgp.json', graph)
        evidence = {'kind':'reviewed-official-gh-html-functions','version':'2.103.2',
            'buildGraphSHA256':graph_sha,'affectedSourceConsumersInBuild':[], 'platforms':{'Linux-x86_64':{
                'binarySHA256':sha,'sourceCommit':'a'*40,'functionNamesSHA256':project.digest(sorted(names)),
                'functionNameCount':len(names),'htmlFunctionNames':sorted(names)}}}
        rule['evidenceSHA256'] = self.write(rule['evidenceFile'], evidence)
        runtime = SimpleNamespace(verify=lambda _:binary, selected=lambda _:({'version':'2.103.2'},'Linux-x86_64',{'sha256':'b'*64}))
        info = SimpleNamespace(parse=lambda _:{'compiler':'go1.27.3','modules':[{'name':'golang.org/x/net','version':'v0.60.0'}]},
                               function_names=inventory.function_names)
        return rule,binary,evidence,runtime,info

    def test_gh_accepts_exact_tokenizer_but_rejects_parse_render_even_with_updated_hash(self):
        for affected in (None, 'Parse', 'Render', '(*parser).addText', 'childTextNodesAreLiteral'):
            names = ['golang.org/x/net/html.(*Tokenizer).Next']
            if affected:names.append('golang.org/x/net/html.'+affected)
            rule,binary,evidence,runtime,info = self.gh_fixture(names)
            with patch.object(project,'load',side_effect=lambda n:runtime if n=='project-gh-runtime' else info):
                if affected:
                    with self.assertRaisesRegex(ValueError,'HTML function table'):project.gh_html_subset(self.root,rule)
                else:project.gh_html_subset(self.root,rule)

    def test_gh_binary_graph_module_and_platform_drift_rejected(self):
        rule,binary,evidence,runtime,info = self.gh_fixture(['golang.org/x/net/html.(*Tokenizer).Next'])
        with patch.object(project,'load',side_effect=lambda n:runtime if n=='project-gh-runtime' else info):
            binary.write_bytes(b'changed')
            with self.assertRaises(ValueError):project.gh_html_subset(self.root,rule)
        rule,binary,evidence,runtime,info = self.gh_fixture(['golang.org/x/net/html.(*Tokenizer).Next'])
        info.parse=lambda _:{'compiler':'go1.27.3','modules':[{'name':'golang.org/x/net','version':'v0.61.0'}]}
        with patch.object(project,'load',side_effect=lambda n:runtime if n=='project-gh-runtime' else info):
            with self.assertRaises(ValueError):project.gh_html_subset(self.root,rule)
        p=self.root/'Config/Security/applicability/gh-openpgp.json';p.write_text('{}')
        with patch.object(project,'load',return_value=runtime):
            with self.assertRaisesRegex(ValueError,'graph changed'):project.gh_html_subset(self.root,rule)

    def test_new_msgpack_requires_unchanged_complete_c_patch_and_managed_assets(self):
        rule=copy.deepcopy(next(r for r in self.rules if r['id']=='GHSA-j586-36cw-2gc2'))
        evidence=json.loads((ROOT/rule['evidenceFile']).read_text())
        paths=['msgpack/_unpacker.pyx','msgpack/unpack.h','msgpack/unpack_container_header.h','msgpack/unpack_template.h']
        commit={'sha':'620b0eb4c89cd72d4098564537624d9dbb2ce141',
                'files':[{'filename':p,'sha':'a'*40,'status':'modified'} for p in paths]}
        evidence['patchFilesSHA256']=project.digest({p:'a'*40 for p in paths})
        rule['evidenceSHA256']=self.write(rule['evidenceFile'],evidence)
        pip=SimpleNamespace(configuration=lambda _:{'pipVersion':evidence['pipVersion'],'wheelSHA256':evidence['wheelSHA256'],'msgpack':{}},
                            verify_environments=lambda *_:{'verified':True})
        pip.configuration=lambda _:{'pipVersion':evidence['pipVersion'],'wheelSHA256':evidence['wheelSHA256'],'msgpack':{'componentVersion':'1.1.2'}}
        reader=SimpleNamespace(gh_read=lambda *_:commit)
        with patch.object(project,'load',side_effect=lambda n:pip if n=='security-pip-applicability' else reader):
            project.pip_msgpack_subset(self.root,rule)
            commit['files'].append({'filename':'msgpack/fallback.py','sha':'b'*40,'status':'modified'})
            with self.assertRaisesRegex(ValueError,'C patch changed'):project.pip_msgpack_subset(self.root,rule)
            pip.verify_environments=lambda *_: (_ for _ in ()).throw(ValueError('native module introduced'))
            with self.assertRaisesRegex(ValueError,'native module'):project.pip_msgpack_subset(self.root,rule)

    def test_shared_new_advisory_scope_does_not_release_actions_https_risk(self):
        rule=next(r for r in self.rules if r['id']=='GHSA-qrxm-fqhp-jwvm')
        self.assertEqual(rule['scope'],'development')
        self.assertEqual(rule['case'],'npm-no-install-scripts')
        self.assertNotIn(('GHSA-qrxm-fqhp-jwvm','undici','github-actions'), usage.targets())


if __name__=='__main__':unittest.main()
