import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('verify_release', ROOT/'scripts/verify-signed-release.py')
v = importlib.util.module_from_spec(spec); spec.loader.exec_module(v)

class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.assets=self.root/'assets';self.assets.mkdir()
        self.key=Ed25519PrivateKey.generate()
        self.pub=base64.b64encode(self.key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)).decode()
        self.version='9.9.9';self.build='999';self.archive='MyTerm-9.9.9-build-999-arm64.zip'
        self.commit='a'*40
        self.dependencies=[{'name':'https://github.com/sparkle-project/Sparkle','version':'2.9.6'}]
        self.make()

    def sig(self,data):return base64.b64encode(self.key.sign(data)).decode()
    def make(self):
        (self.assets/self.archive).write_bytes(b'inert archive fixture')
        (self.assets/'release-notes.html').write_bytes(b'<html>Fixture</html>')
        root=ET.Element('rss');item=ET.SubElement(ET.SubElement(root,'channel'),'item')
        for name,value in [('shortVersionString',self.version),('version',self.build),('minimumSystemVersion','26.0'),('hardwareRequirements','arm64')]:ET.SubElement(item,v.SP+name).text=value
        data=(self.assets/self.archive).read_bytes()
        ET.SubElement(item,'enclosure',{'url':'https://updates.example.test/downloads/'+self.archive,'length':str(len(data)),v.SP+'edSignature':self.sig(data)})
        data=(self.assets/'release-notes.html').read_bytes()
        ET.SubElement(item,v.SP+'releaseNotesLink',{'length':str(len(data)),v.SP+'edSignature':self.sig(data)}).text='https://updates.example.test/releases/9.9.9.html'
        ET.SubElement(item,v.MT+'sourceCommit').text=self.commit
        ET.SubElement(item,v.MT+'dependencies').text=json.dumps(self.dependencies)
        self.content=ET.tostring(root,encoding='utf-8',xml_declaration=True)
        self.sign_feed()

    def sign_feed(self):
        (self.assets/'appcast.xml').write_bytes(self.content+v.PREFIX+f'edSignature: {self.sig(self.content)}\nlength: {len(self.content)}\n-->\n'.encode())
        self.hashes()

    def hashes(self):
        manifest={'schemaVersion':1,'product':'MyTerm','version':self.version,'build':self.build,'tag':'v'+self.version,'archive':self.archive,'downloadURL':'https://updates.example.test/downloads/'+self.archive,'commit':self.commit,'dependencies':self.dependencies}
        for name,field in [(self.archive,'archiveSHA256'),('appcast.xml','appcastSHA256'),('release-notes.html','releaseNotesSHA256')]:manifest[field]=hashlib.sha256((self.assets/name).read_bytes()).hexdigest()
        (self.assets/'release-manifest.json').write_text(json.dumps(manifest))
        self.checksums()

    def checksums(self):
        (self.assets/'CHECKSUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in self.assets.iterdir() if p.name!='CHECKSUMS.txt'))

    def verify(self,**kw):return v.verify(self.assets,kw.get('key',self.pub),self.version,kw.get('base','https://updates.example.test'),self.build,kw.get('commit',self.commit))
    def reject(self,**kw):
        with self.assertRaises((ValueError,v.InvalidSignature,ET.ParseError)):self.verify(**kw)

    def test_valid(self):self.assertEqual(self.verify()['build'],'999')
    def test_namespaced_and_dual_notes_lengths(self):
        for legacy in [False, True]:
            root=ET.fromstring(self.content);note=root.find('./channel/item/'+v.SP+'releaseNotesLink')
            note.set(v.SP+'length',str(len((self.assets/'release-notes.html').read_bytes())))
            if not legacy:note.attrib.pop('length',None)
            else:note.set('length',note.get(v.SP+'length'))
            self.content=ET.tostring(root);self.sign_feed()
            self.assertEqual(self.verify()['version'],self.version)

    def test_conflicting_or_missing_notes_lengths_rejected(self):
        original=self.content
        for attrs in [{'length':'1',v.SP+'length':'20'},{'length':'20',v.SP+'length':'1'},{}]:
            root=ET.fromstring(original);note=root.find('./channel/item/'+v.SP+'releaseNotesLink')
            note.attrib.pop('length',None);note.attrib.pop(v.SP+'length',None)
            note.attrib.update(attrs)
            self.content=ET.tostring(root);self.sign_feed();self.reject()

    def test_binder_emits_equal_old_and_new_notes_lengths(self):
        # Run the real binder/inventory against an isolated resolved-source fixture,
        # so a clean CI checkout does not need the developer's Swift build cache.
        project=self.root/'project';scripts=project/'scripts';scripts.mkdir(parents=True)
        for name in ['bind-release-metadata.py','dependency-inventory.py']:
            shutil.copyfile(ROOT/'scripts'/name,scripts/name)
        revision='b'*40
        (project/'Package.resolved').write_text(json.dumps({'pins':[{
            'identity':'swift-sodium','location':'https://example.test/swift-sodium.git',
            'state':{'version':'1.0.0','revision':revision}}]}))
        vendor=project/'Vendor/SwiftTerm';vendor.mkdir(parents=True)
        (vendor/'UPSTREAM.md').write_text('Revision: `'+revision+'`')
        config=project/'Config/Security';config.mkdir(parents=True)
        (config/'native-components.json').write_text(json.dumps({'libsodium':{
            'swiftSodiumRevision':revision,'version':'1.0.0'}}))
        header=project/'.build/checkouts/swift-sodium/Clibsodium.xcframework/macos-arm64_arm64e_x86_64/Headers/Clibsodium/sodium/version.h'
        header.parent.mkdir(parents=True)
        header.write_text('#define SODIUM_VERSION_STRING "1.0.0"\n')
        feed=self.root/'unsigned.xml';feed.write_bytes(self.content)
        notes=self.assets/'release-notes.html'
        subprocess.run([os.sys.executable,str(scripts/'bind-release-metadata.py'),
            '--feed',str(feed),'--notes',str(notes),'--signature',self.sig(notes.read_bytes()),
            '--base-url','https://updates.example.test','--version',self.version,'--commit',self.commit],check=True)
        node=ET.parse(feed).find('./channel/item/'+v.SP+'releaseNotesLink')
        self.assertEqual(node.get('length'),str(notes.stat().st_size))
        self.assertEqual(node.get(v.SP+'length'),node.get('length'))
        dependencies=json.loads(ET.parse(feed).find('./channel/item/'+v.MT+'dependencies').text)
        self.assertEqual(len(dependencies),3)
        self.assertIn({'ecosystem':'native','name':'https://github.com/jedisct1/libsodium','version':'1.0.0'},dependencies)
    def test_wrong_key(self):self.reject(key=base64.b64encode(b'x'*32).decode())
    def test_changed_archive_even_with_updated_hashes(self):
        (self.assets/self.archive).write_bytes(b'inert archive fixturE');self.hashes();self.reject()
    def test_changed_notes_even_with_updated_hashes(self):
        (self.assets/'release-notes.html').write_bytes(b'<html>Changed</html>');self.hashes();self.reject()
    def test_changed_feed(self):
        p=self.assets/'appcast.xml';p.write_bytes(p.read_bytes().replace(b'9.9.9',b'9.9.8'));self.hashes();self.reject()
    def test_trailing_xml(self):
        p=self.assets/'appcast.xml';p.write_bytes(p.read_bytes()+b'<item/>');self.hashes();self.reject()
    def test_duplicate_signature_block(self):
        p=self.assets/'appcast.xml';p.write_bytes(p.read_bytes()+v.PREFIX+b'-->');self.hashes();self.reject()
    def test_missing_manifest(self):
        (self.assets/'release-manifest.json').unlink();self.reject()
    def test_wrong_manifest_commit(self):
        p=self.assets/'release-manifest.json';d=json.loads(p.read_text());d['commit']='b'*40;p.write_text(json.dumps(d));self.checksums();self.reject()
    def test_wrong_expected_commit(self):self.reject(commit='b'*40)
    def test_wrong_base_url(self):self.reject(base='https://attacker.example.test')
    def test_unsafe_checksum(self):
        p=self.assets/'CHECKSUMS.txt';p.write_text(p.read_text()+'0'*64+'  ../../private\n');self.reject()
    def test_duplicate_item_signed(self):
        root=ET.fromstring(self.content);channel=root.find('channel');channel.append(ET.fromstring(ET.tostring(channel.find('item'))));self.content=ET.tostring(root);self.sign_feed();self.reject()
    def test_symlink_asset(self):
        p=self.assets/self.archive;outside=self.root/'outside';p.rename(outside);p.symlink_to(outside);self.reject()
    def test_length_and_signature_encoding(self):
        p=self.assets/'appcast.xml';data=p.read_bytes();p.write_bytes(data.replace(b'length: ',b'length: 1'));self.hashes();self.reject()
        p.write_bytes(data.replace(b'edSignature: ',b'edSignature: ?'));self.hashes();self.reject()
    @unittest.skipUnless(os.environ.get('SPARKLE_SIGN_UPDATE'), 'Official Sparkle tool only available on macOS')
    def test_official_sparkle_feed_signing(self):
        seed=self.key.private_bytes(serialization.Encoding.Raw,serialization.PrivateFormat.Raw,serialization.NoEncryption())
        path=self.root/'ephemeral-test-seed';path.write_bytes(base64.b64encode(seed));path.chmod(0o600)
        feed=self.assets/'appcast.xml';feed.write_bytes(self.content)
        subprocess.run([os.environ['SPARKLE_SIGN_UPDATE'],'--ed-key-file',str(path),str(feed)],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.hashes();self.assertEqual(self.verify()['commit'],self.commit)

if __name__=='__main__':unittest.main()
