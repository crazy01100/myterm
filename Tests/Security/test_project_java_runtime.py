"""Inert runtime archives and file-integrity fixtures; no JVM or certificate-chain tests."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('java_runtime',ROOT/'scripts/project-java-runtime.py')
j=importlib.util.module_from_spec(spec);spec.loader.exec_module(j)


class JavaRuntimeTests(unittest.TestCase):
    def test_derived_manifest_allows_only_reviewed_cacerts_change(self):
        row=j.configuration(ROOT);policy=j.trust_configuration(ROOT,row)
        name=str(j.java_home(Path('.'),row)/'lib/security/cacerts')
        original={name:{'sha256':row['truststoreSHA256'],'executable':False},
                  'bin/fixture':{'sha256':'a'*64,'executable':True}}
        derived=j.installed_manifest(ROOT,row,original)
        self.assertEqual(derived['bin/fixture'],original['bin/fixture'])
        self.assertEqual(derived[name]['sha256'],policy['derivedTruststoreSHA256'])
        self.assertEqual(original[name]['sha256'],row['truststoreSHA256'])
        with self.assertRaises(ValueError):j.installed_manifest(ROOT,row,{**original,name:{'sha256':'0'*64,'executable':False}})

    def test_trust_policy_cannot_expand_to_arbitrary_roots_or_a_waiver(self):
        row=j.configuration(ROOT);policy=j.trust_configuration(ROOT,row)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);path=root/j.TRUST;path.parent.mkdir(parents=True)
            for change in ({'excludedRootCNs':['unrelated root']}, {'removedCertificateSHA256':['0'*64]},
                           {'grantsRiskException':True}, {'id':'CVE-2099-1234'},
                           {'upstreamTruststoreSHA256':'0'*64},{'derivedTruststoreSHA256':row['truststoreSHA256']}):
                path.write_text(json.dumps({**policy,**change}))
                with self.subTest(change=change),self.assertRaises(ValueError):j.trust_configuration(root,row)

    def test_inventory_preserves_legacy_roots_without_common_name(self):
        text=('Alias name: legacy\nEntry type: trustedCertEntry\nOwner: OU=Legacy, O=Fixture\n'
              'SHA256: '+':'.join(['AB']*32)+'\n')
        entry=j.certificate_inventory(text)[0]
        self.assertIsNone(entry['cn']);self.assertEqual(entry['sha256'],'ab'*32)
        with self.assertRaises(ValueError):j.certificate_inventory(text.replace('SHA256:','SHA1:'))
        with self.assertRaises(ValueError):j.certificate_inventory(text+text)

    def test_setup_refuses_unknown_drift_instead_of_repairing(self):
        row=j.configuration(ROOT)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/j.TARGET).mkdir(parents=True)
            with patch.object(j,'configuration',return_value=row),patch.object(j,'verify',side_effect=ValueError('drift')), \
                 patch.object(j,'upstream_manifest',return_value={}),patch.object(j,'verify_tree',side_effect=ValueError('modified')), \
                 patch.object(j,'derive_trust') as derive:
                with self.assertRaises(ValueError):j.setup(root)
                derive.assert_not_called()

    def test_derivation_changes_only_the_pinned_certificate_and_checks_final_bytes(self):
        from types import SimpleNamespace
        upstream=b'official inert truststore';derived=b'reviewed inert result'
        policy={'upstreamTruststoreSHA256':hashlib.sha256(upstream).hexdigest(),
                'derivedTruststoreSHA256':hashlib.sha256(derived).hexdigest(),
                'removedCertificateSHA256':['40f6af0346a99aa1cd1d555a4e9cce62c7f9634603ee406615833dc8c8d00367']}
        def entry(alias,cn,sha):return f'Alias name: {alias}\nEntry type: trustedCertEntry\nOwner: CN={cn}, O=Fixture\nSHA256: {sha.upper()}\n'
        kept=entry('keep','Unrelated Root','a'*64)
        removed=entry('remove','emSign Root CA - G1',policy['removedCertificateSHA256'][0])
        for wrong_hash in (False,True):
            with self.subTest(wrong_hash=wrong_hash),tempfile.TemporaryDirectory() as directory:
                home=Path(directory);target=home/'lib/security/cacerts';target.parent.mkdir(parents=True);target.write_bytes(upstream)
                def keytool(args,**kwargs):
                    staged=Path(args[args.index('-keystore')+1])
                    if '-delete' in args:
                        self.assertEqual(args[-1],'remove');staged.write_bytes(b'wrong' if wrong_hash else derived)
                        return SimpleNamespace(stdout='')
                    return SimpleNamespace(stdout=kept+(removed if staged.read_bytes()==upstream else ''))
                with patch.object(j,'trust_configuration',return_value=policy),patch.object(j.subprocess,'run',side_effect=keytool):
                    if wrong_hash:
                        with self.assertRaises(ValueError):j.derive_trust(home,home,{})
                        self.assertEqual(target.read_bytes(),upstream)
                    else:
                        j.derive_trust(home,home,{})
                        self.assertEqual(target.read_bytes(),derived)
                self.assertFalse(list(target.parent.glob('.myterm-trust-*')))

    def test_platform_policy_and_home_are_separate(self):
        for system,machine,expected,home in [('Darwin','arm64','aarch64-apple-darwin','Contents/Home'),
                                            ('Linux','x86_64','x86_64-linux-gnu','.')]:
            with patch.object(j.platform,'system',return_value=system),patch.object(j.platform,'machine',return_value=machine):
                row=j.configuration(ROOT)
                self.assertEqual(row['platform'],expected)
                self.assertEqual(j.java_home(Path('/fixture'),row),Path('/fixture')/home)
        with patch.object(j.platform,'system',return_value='Unknown'),self.assertRaises(ValueError):j.configuration(ROOT)

    def test_linux_license_links_are_exact_and_cannot_redirect(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);target=root/'legal/java.base/LICENSE';target.parent.mkdir(parents=True);target.write_bytes(b'license')
            link=root/'legal/java.sql/LICENSE';link.parent.mkdir();link.symlink_to('../java.base/LICENSE')
            files={'legal/java.base/LICENSE':{'sha256':j.digest_file(target),'executable':False},
                   'legal/java.sql/LICENSE':{'symlink':'../java.base/LICENSE'}}
            j.verify_tree(root,files)
            link.unlink();link.symlink_to('/etc/passwd')
            with self.assertRaises(ValueError):j.verify_tree(root,files)

    def test_ci_prepares_isolated_java_and_wrapper_never_uses_path_java(self):
        wrapper=(ROOT/'scripts/project-java.sh').read_text()
        self.assertNotIn('command -v java',wrapper)
        for name in ('security-gate.yml','security-checks.yml','deploy-update-site.yml'):
            self.assertIn('scripts/project-java-runtime.py setup',(ROOT/'.github/workflows'/name).read_text())

    def test_reviewed_source_identity_rejects_other_vendor_or_unpinned_source(self):
        approved=j.configuration(ROOT)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);path=root/j.config_path();path.parent.mkdir(parents=True)
            for change in ({'url':'https://example.invalid/java.tar.gz'},{'vendor':'unreviewed'},
                           {'version':'25.0.1+1'},{'fileManifestSHA256':'missing'}):
                path.write_text(json.dumps({**approved,**change}))
                with self.subTest(change=change),self.assertRaises(ValueError):j.configuration(root)

    def test_installed_runtime_bytes_modes_additions_and_missing_files_are_detected(self):
        with tempfile.TemporaryDirectory() as directory:
            target=Path(directory);path=target/'java';path.write_bytes(b'inert runtime fixture')
            files={'java':{'sha256':j.digest_file(path),'executable':False}}
            j.verify_tree(target,files)
            path.chmod(0o755)
            with self.assertRaises(ValueError):j.verify_tree(target,files)
            path.chmod(0o644);path.write_bytes(b'changed')
            with self.assertRaises(ValueError):j.verify_tree(target,files)
            path.unlink()
            with self.assertRaises(ValueError):j.verify_tree(target,files)
            path.write_bytes(b'inert runtime fixture');(target/'unexpected').write_bytes(b'inert extra')
            with self.assertRaises(ValueError):j.verify_tree(target,files)

    def test_runtime_storage_and_members_cannot_redirect_to_external_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'.build').mkdir();outside=root/'outside';outside.mkdir()
            (root/j.TARGET).symlink_to(outside,target_is_directory=True)
            with self.assertRaises(ValueError):j.storage(root,j.TARGET)
            (outside/'alias').symlink_to(root/'missing')
            with self.assertRaises(ValueError):j.verify_tree(outside,{})

    def test_archive_requires_both_source_hash_and_exact_file_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'fixture.tar.gz';body=b'inert Java placeholder'
            with tarfile.open(path,'w:gz') as archive:
                item=tarfile.TarInfo('jdk-fixture/Contents/Home/bin/java');item.size=len(body);item.mode=0o755
                archive.addfile(item,io.BytesIO(body))
            files={'Contents/Home/bin/java':{'sha256':hashlib.sha256(body).hexdigest(),'executable':True}}
            raw=json.dumps(files,sort_keys=True,separators=(',',':')).encode()
            row={'size':path.stat().st_size,'sha256':j.digest_file(path),'archiveRoot':'jdk-fixture',
                 'fileManifestSHA256':hashlib.sha256(raw).hexdigest()}
            self.assertEqual(j.archive_manifest(path,row)[0],files)
            for change in ({'sha256':'0'*64},{'fileManifestSHA256':'0'*64},{'archiveRoot':'other'}):
                with self.subTest(change=change),self.assertRaises(ValueError):j.archive_manifest(path,{**row,**change})

    def test_jvm_injection_environment_is_not_used_by_managed_entry(self):
        from unittest.mock import patch
        with patch.dict(j.os.environ,{'JAVA_TOOL_OPTIONS':'fixture','JDK_JAVA_OPTIONS':'fixture','_JAVA_OPTIONS':'fixture'}):
            result=j.clean_environment()
        self.assertFalse({'JAVA_TOOL_OPTIONS','JDK_JAVA_OPTIONS','_JAVA_OPTIONS'}&set(result))


if __name__=='__main__':unittest.main()
