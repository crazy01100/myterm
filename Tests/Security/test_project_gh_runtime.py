"""Inert archive/build-info fixtures; no network, authentication or exploit execution."""
import hashlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT=Path(__file__).resolve().parents[2]
def load(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/f'{name}.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
g=load('project-gh-runtime');go=load('go-build-inventory')


def build_info(lines):
    def string(raw):
        size=len(raw);prefix=b''
        while size>=128:prefix+=bytes([(size&127)|128]);size>>=7
        return prefix+bytes([size])+raw
    return go.MAGIC+b'\x08\x02'+bytes(16)+string(b'go1.27.3')+string(bytes(16)+lines.encode()+bytes(16))


class GitHubRuntimeTests(unittest.TestCase):
    def test_pinned_policy_rejects_foreign_sources_and_missing_platforms(self):
        original=g.policy(ROOT)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);p=root/g.CONFIG;p.parent.mkdir(parents=True)
            original['platforms']['Darwin-arm64']['url']='https://example.invalid/gh.zip'
            p.write_text(json.dumps(original))
            with self.assertRaises(ValueError):g.policy(root)

    def test_archive_is_bounded_and_rejects_links_paths_or_hash_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'fixture.zip'
            for name,mode in [('gh-fixture/bin/gh',stat.S_IFREG|0o755),
                              ('gh-fixture/../bin/gh',stat.S_IFREG|0o755),
                              ('gh-fixture/bin/gh',stat.S_IFLNK|0o777)]:
                with zipfile.ZipFile(path,'w') as archive:
                    item=zipfile.ZipInfo(name);item.external_attr=mode<<16;archive.writestr(item,b'inert fixture')
                row={'size':path.stat().st_size,'sha256':g.sha(path),'archiveRoot':'gh-fixture'}
                if '..' in name or stat.S_ISLNK(mode):
                    with self.assertRaises(ValueError):g.files_in_archive(path,row)
                else:
                    self.assertEqual(g.files_in_archive(path,row)['bin/gh'][0],b'inert fixture')
                    with self.assertRaises(ValueError):g.files_in_archive(path,{**row,'sha256':'0'*64})

    def test_installed_tree_drift_never_falls_back_or_overwrites(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);identity='fixture';target=root/'.build/gh-runtime'/identity
            (target/'bin').mkdir(parents=True);exe=target/'bin/gh';exe.write_bytes(b'inert fixture');exe.chmod(0o755)
            raw=g.manifest({'bin/gh':(exe.read_bytes(),0o755)})
            (target.parent/(identity+'-manifest.json')).write_bytes(raw)
            row={'manifestSHA256':hashlib.sha256(raw).hexdigest()}
            with patch.object(g,'selected',return_value=({},identity,row)):
                self.assertEqual(g.verify(root),exe)
                for change in ('mode','content','extra','symlink'):
                    exe.write_bytes(b'inert fixture');exe.chmod(0o755)
                    if change=='mode':exe.chmod(0o644)
                    elif change=='content':exe.write_bytes(b'changed')
                    elif change=='extra':(target/'extra').write_bytes(b'extra')
                    else:exe.unlink();exe.symlink_to('/nonexistent')
                    with self.subTest(change=change),self.assertRaises(ValueError):g.setup(root)
                    if (target/'extra').exists():(target/'extra').unlink()

    def test_go_build_graph_retains_pseudo_versions_and_stdlib_identity(self):
        raw=build_info('path\tgithub.com/cli/cli/v2/cmd/gh\nmod\tgithub.com/cli/cli/v2\tv2.103.2\t\n'
                       'dep\texample.org/mod\tv0.0.0-20261023000000-abcdef123456\th1:fixture\n')
        result=go.parse(raw)
        self.assertEqual(result['compiler'],'go1.27.3');self.assertEqual(len(result['modules']),2)
        self.assertEqual(result['modules'][1]['version'],'v0.0.0-20261023000000-abcdef123456')
        for malformed in (raw[:40],raw.replace(b'v2.103.2',b'(devel)'),
                          build_info('path\texample.org/main/cmd\nmod\texample.org/main\tv1.0.0\t\n=>\t./local\t\n')):
            with self.assertRaises((ValueError,UnicodeError)):go.parse(malformed)

    def test_go_ecosystem_is_queried_without_dropping_runtime(self):
        osv=load('security-toolchain-advisories');seen=[]
        components=[{'ecosystem':'Go','name':'stdlib','version':'1.27.3','origin':'platform/project-gh'}]
        def fetch(url,payload):seen.extend(payload['queries']);return {'results':[{}]}
        result=osv.lookup(components,fetch)
        self.assertEqual(seen[0]['package'],{'ecosystem':'Go','name':'stdlib'})
        self.assertEqual(result['queriedIdentities'],1)

    def test_live_consumers_use_project_entry_and_health_stays_package_independent(self):
        for name in ('security-audit.py','security-monitor-health.py','restore-security-monitor.py',
                     'security-source-review.py','sync-security-issues.py'):
            source=(ROOT/'scripts'/name).read_text()
            self.assertNotIn("['gh',",source);self.assertIn('project-gh.sh',source)
        source=(ROOT/'.github/workflows/security-monitor-health.yml').read_text()
        self.assertIn('project-gh-runtime.py setup',source);self.assertNotIn('setup-security-tools.sh',source)

    def test_accepted_action_boundaries_are_not_mistaken_for_emulator_downloads(self):
        prepare=load('security-prepare-inventory')
        self.assertEqual(len(prepare.declarations(ROOT)),5)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);cfg=root/'Config/Security';cfg.mkdir(parents=True)
            (cfg/'action-bundles.json').write_bytes((ROOT/'Config/Security/action-bundles.json').read_bytes())
            policy=json.loads((ROOT/'Config/Security/toolchain-inventory.json').read_text())
            row=next(r for r in policy['supplierBoundaries'] if r.get('kind')=='action-bundle-limited-evidence')
            row['archiveSHA256']='0'*64
            (cfg/'toolchain-inventory.json').write_text(json.dumps(policy))
            with self.assertRaises(ValueError):prepare.declarations(root)


if __name__=='__main__':unittest.main()
