import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class ProjectPythonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root/'scripts').mkdir()
        self.launcher = self.root/'scripts/project-python.sh'
        shutil.copy2(ROOT/'scripts/project-python.sh', self.launcher)
        self.env = {**os.environ}
        self.env.pop('MYTERM_PYTHON', None)

    def run_python(self, *args):
        return subprocess.run([str(self.launcher), *args], env=self.env, text=True, capture_output=True, timeout=10)

    def test_explicit_supported_interpreter_preserves_arguments_and_exit(self):
        self.env['MYTERM_PYTHON'] = sys.executable
        result = self.run_python('-c', 'import sys; print(sys.argv[1]); sys.exit(7)', 'space 中文')
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(result.stdout.strip(), 'space 中文')

    def test_invalid_explicit_override_does_not_fall_back(self):
        self.env['MYTERM_PYTHON'] = str(self.root/'missing-python')
        result = self.run_python('-c', 'raise Exception("must not execute")')
        self.assertEqual(result.returncode, 69)
        self.assertIn('MYTERM_PYTHON', result.stderr)

    def test_project_environment_precedes_path(self):
        target = self.root/'.build/python-runtime/bin/python3'
        target.parent.mkdir(parents=True)
        target.symlink_to(sys.executable)
        result = self.run_python('-c', 'import sys; print(sys.executable)')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(target))

    def test_unsupported_override_is_rejected(self):
        probe = self.root/'unsupported-python'
        probe.write_text('#!/bin/sh\nexit 1\n')
        probe.chmod(0o755)
        self.env['MYTERM_PYTHON'] = str(probe)
        result = self.run_python('-c', 'print("must not execute")')
        self.assertEqual(result.returncode, 69)
        self.assertEqual(result.stdout, '')

if __name__ == '__main__': unittest.main()
