import importlib.util
from html.parser import HTMLParser
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import test_signed_release as fixtures

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('release_notes',ROOT/'scripts/render-release-notes.py')
r=importlib.util.module_from_spec(spec);spec.loader.exec_module(r)

class Parsed(HTMLParser):
    def __init__(self,source):
        super().__init__();self.tags=[];self.text=[];self.feed(source)
    def handle_starttag(self,tag,attrs):self.tags.append((tag,dict(attrs)))
    def handle_data(self,data):self.text.append(data)

class ReleaseNotesTests(unittest.TestCase):
    def test_version_heading_is_present_once_with_or_without_input_title(self):
        for prefix in ['', '# MyTerm 9.9.9\n\n', '\ufeff\n## MyTerm v9.9.9\n\n']:
            parsed=Parsed(r.render(prefix+'## 改善\n- 連線更穩定', '9.9.9'))
            self.assertEqual(sum(tag=='h1' for tag,_ in parsed.tags),1)
            # HTML title is metadata; visible heading is a single h1.
            self.assertEqual(parsed.text.count('MyTerm 9.9.9'),1)
            self.assertIn('連線更穩定',parsed.text)
    def test_title_mismatch_is_reported(self):
        with self.assertRaises(ValueError):r.render('# MyTerm 1.0.0\n\n- Fix', '9.9.9')
    def test_empty_and_invalid_version_rejected(self):
        for source,version in [('', '9.9.9'),('# MyTerm 9.9.9','9.9.9'),('- fix','<script>')]:
            with self.assertRaises(ValueError):r.render(source,version)
    def test_no_site_navigation_or_site_styles(self):
        parsed=Parsed(r.render('- Fix','9.9.9'))
        self.assertFalse(any(tag in ['a','nav','script','iframe'] for tag,_ in parsed.tags))
        self.assertEqual([attrs['href'] for tag,attrs in parsed.tags if tag=='link'],['/assets/release-notes.css'])
    def test_untrusted_markup_is_text(self):
        parsed=Parsed(r.render('## <img src=x onerror=bad>\n\n- <script>bad</script> & safe','9.9.9'))
        self.assertFalse(any(tag in ['img','script'] for tag,_ in parsed.tags))
        self.assertIn('<script>bad</script> & safe',parsed.text)
    def test_paragraph_lists_and_author_sections_are_preserved(self):
        parsed=Parsed(r.render('First line\nsecond line\n\n## 相容性\n- macOS\n- arm64\n\n1. Update\n2. Restart\n\n## 驗證與維護\nAuthor text','9.9.9'))
        self.assertIn('First line second line',parsed.text)
        self.assertEqual(sum(tag=='li' for tag,_ in parsed.tags),4)
        self.assertIn('ul',[tag for tag,_ in parsed.tags]);self.assertIn('ol',[tag for tag,_ in parsed.tags])
        self.assertIn('驗證與維護',parsed.text) # Authoring policy does not silently discard input.
    def test_cli_writes_the_same_utf8_output(self):
        with tempfile.TemporaryDirectory() as d:
            source=Path(d)/'notes.md';output=Path(d)/'notes.html';source.write_text('# MyTerm 9.9.9\n\n- 安全修正')
            subprocess.run([sys.executable,str(ROOT/'scripts/render-release-notes.py'),'--source',str(source),'--output',str(output),'--version','9.9.9'],check=True)
            self.assertEqual(output.read_text(),r.render(source.read_text(),'9.9.9'))
    def test_rendered_notes_remain_signed_and_tampering_is_rejected(self):
        fixture=fixtures.ReleaseTests();fixture.setUp();self.addCleanup(fixture.doCleanups)
        content=r.render('# MyTerm 9.9.9\n\n## 修正\n- 安全修正','9.9.9').encode()
        path=fixture.assets/'release-notes.html';path.write_bytes(content)
        root=ET.fromstring(fixture.content);note=root.find('./channel/item/'+fixtures.v.SP+'releaseNotesLink')
        note.set('length',str(len(content)));note.set(fixtures.v.SP+'edSignature',fixture.sig(content))
        fixture.content=ET.tostring(root);fixture.sign_feed()
        self.assertEqual(fixture.verify()['version'],'9.9.9')
        path.write_bytes(content.replace('安全修正'.encode(),'內容竄改'.encode()));fixture.hashes();fixture.reject()

if __name__=='__main__':unittest.main()
