import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

@unittest.skipUnless(shutil.which('zsh'), 'zsh required for release helper')
class SparkleToolSelectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root/'scripts').mkdir()
        shutil.copy2(ROOT/'scripts/project-python.sh',self.root/'scripts/project-python.sh')
        (self.root/'Package.resolved').write_text(json.dumps({'pins':[{'identity':'sparkle','state':{'version':'2.10.0'}}]}))

    def artifact(self, cache, version):
        artifact = self.root/cache/'artifacts/sparkle/Sparkle'
        tool = artifact/'bin/sign_update'
        tool.parent.mkdir(parents=True)
        tool.write_text('#!/bin/sh\nexit 0\n');tool.chmod(0o755)
        info = artifact/'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Resources/Info.plist'
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({'CFBundleShortVersionString':version}))
        return tool

    def select(self):
        return subprocess.run(['zsh','-c','source "$1"; find_sparkle_tool "$2" sign_update','test',
            str(ROOT/'scripts/sparkle-key-common.sh'),str(self.root)],capture_output=True,text=True,
            env={**os.environ,'MYTERM_PYTHON':sys.executable})

    def test_release_cache_wins_over_stale_debug_cache(self):
        self.artifact('.build','2.9.6');expected=self.artifact('.build-app','2.10.0')
        result=self.select();self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.strip(),str(expected))

    def test_matching_debug_cache_is_valid_fallback(self):
        self.artifact('.build-app','2.9.6');expected=self.artifact('.build','2.10.0')
        self.assertEqual(self.select().stdout.strip(),str(expected))

    def test_stale_or_unknown_cache_fails_closed(self):
        self.artifact('.build','2.9.6')
        self.assertNotEqual(self.select().returncode,0)
        (self.root/'Package.resolved').write_text('{}')
        self.assertNotEqual(self.select().returncode,0)
