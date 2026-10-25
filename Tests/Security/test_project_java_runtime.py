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
