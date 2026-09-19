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

    def test_swift_test_peers_do_not_pin_system_python(self):
        for path in (ROOT/'SelfTests').glob('*.swift'):
            with self.subTest(path=path.name):
                self.assertNotRegex(path.read_text(), r'/(?:usr/bin|usr/local/bin)/python[0-9.]*')

    def prepare_sftp_runner(self):
        runner = self.root/'scripts/run-sftp-security-tests.sh'
        shutil.copy2(ROOT/'scripts/run-sftp-security-tests.sh', runner)
        binary_dir = self.root/'fake-bin'
        binary_dir.mkdir()
        compiler = binary_dir/'swiftc'
        compiler.write_text('''#!/bin/sh
touch "$MYTERM_COMPILER_CALLED"
while [ "$#" -gt 0 ]; do
  if [ "$1" = '-o' ]; then shift; output="$1"; break; fi
  shift
done
cat > "$output" <<'SH'
#!/bin/sh
printf '%s\\n' "$@" > "$MYTERM_ARGUMENT_CAPTURE"
SH
chmod +x "$output"
''')
        compiler.chmod(0o755)
        self.env['PATH'] = str(binary_dir)+os.pathsep+self.env.get('PATH', '')
        self.env['MYTERM_COMPILER_CALLED'] = str(self.root/'compiler-called')
        self.env['MYTERM_ARGUMENT_CAPTURE'] = str(self.root/'arguments')
        return runner

    @unittest.skipUnless(shutil.which('zsh'), 'macOS zsh runner integration')
    def test_sftp_runner_passes_validated_interpreter_as_one_argument(self):
        runner = self.prepare_sftp_runner()
        selected = self.root/'python with spaces'
        selected.symlink_to(sys.executable)
        self.env['MYTERM_PYTHON'] = str(selected)
        result = subprocess.run([str(runner)], env=self.env, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = (self.root/'arguments').read_text().splitlines()
        self.assertEqual(len(arguments), 2)
        self.assertEqual(Path(arguments[0]).resolve(), (self.root/'Tests/Security/fake_sftp.py').resolve())
        self.assertEqual(arguments[1], str(selected))

    @unittest.skipUnless(shutil.which('zsh'), 'macOS zsh runner integration')
    def test_sftp_runner_rejects_invalid_runtime_before_compiling(self):
        runner = self.prepare_sftp_runner()
        self.env['MYTERM_PYTHON'] = str(self.root/'missing-python')
        result = subprocess.run([str(runner)], env=self.env, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 69, result.stderr)
        self.assertFalse((self.root/'compiler-called').exists())
        self.assertFalse((self.root/'arguments').exists())

if __name__ == '__main__': unittest.main()
