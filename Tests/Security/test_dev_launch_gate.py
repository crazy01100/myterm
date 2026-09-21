"""Exercise the real gate and runner in a disposable copy; never operate on Apps."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('dev_launch_gate', ROOT / 'scripts/check-dev-launch.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class DevLaunchGateTests(unittest.TestCase):
    def test_production(self):
        self.assertEqual(gate.production_pids(' 42 ' + gate.PRODUCTION + '\n 7 /sbin/launchd'), [42])

    def test_other_processes_and_spaces(self):
        self.assertEqual(gate.production_pids('12 /tmp/MyTerm Dev.app/Contents/MacOS/MySSHClient\n13 /bin/zsh'), [])

    def test_similar_name_is_not_production(self):
        self.assertEqual(gate.production_pids('12 ' + gate.PRODUCTION + '-helper'), [])

    def test_multiple_instances(self):
        self.assertEqual(gate.production_pids('12 ' + gate.PRODUCTION + '\n13 ' + gate.PRODUCTION), [12, 13])

    def test_invalid_or_empty_fail_closed(self):
        for listing in ['', '\n', 'denied', '12']:
            with self.subTest(listing=listing), self.assertRaises(ValueError):
                gate.production_pids(listing)

    def test_query_failure(self):
        with patch.object(gate.subprocess, 'run', side_effect=PermissionError()):
            self.assertEqual(gate.main(), 70)

    def test_production_stops_with_reminder(self):
        with patch.object(gate.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '12 ' + gate.PRODUCTION)), patch('sys.stderr') as stderr:
            self.assertEqual(gate.main(), 70)
            self.assertIn(gate.REMINDER, ''.join(str(call) for call in stderr.write.call_args_list))

    def test_no_production_permits(self):
        with patch.object(gate.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '1 /sbin/launchd')):
            self.assertEqual(gate.main(), 0)

    def exercise_runner(self, blocked_pass):
        if not shutil.which("zsh"):
            self.skipTest("macOS Dev runner integration requires zsh; pure gate tests still run")
        with tempfile.TemporaryDirectory(prefix='MyTerm-launch-gate-') as tmp:
            root = Path(tmp)
            scripts = root / 'scripts'; scripts.mkdir()
            def executable(path, content):
                path.write_text(content); path.chmod(0o700)
            fake_ps = root / 'ps'
            executable(fake_ps, '#!/bin/sh\nn=0\n[ ! -f "$0.count" ] || n=$(cat "$0.count")\nn=$((n+1))\nprintf "%s" "$n" > "$0.count"\n' +
                       f'if [ "$n" -ge {blocked_pass} ]; then printf "42 {gate.PRODUCTION}\\n"; else printf "1 /sbin/launchd\\n"; fi\n')
            fake_pgrep = root / 'pgrep'; executable(fake_pgrep, '#!/bin/sh\nexit 1\n')
            fake_open = root / 'open'; executable(fake_open, '#!/bin/sh\ntouch "' + str(root / 'opened') + '"\n')
            # Only temporary test copies replace OS probes. Production has no bypass option.
            helper = (ROOT / 'scripts/check-dev-launch.py').read_text().replace("'/bin/ps'", repr(str(fake_ps)))
            (scripts / 'check-dev-launch.py').write_text(helper)
            executable(scripts / 'project-python.sh', '#!/bin/sh\nexec "' + sys.executable + '" "$@"\n')
            executable(scripts / 'build-app.sh', '#!/bin/sh\ntouch "' + str(root / 'built') + '"\n')
            executable(scripts / 'verify-app.sh', '#!/bin/sh\nexit 0\n')
            runner = (ROOT / 'scripts/run-dev-app.sh').read_text().replace('/usr/bin/pgrep', str(fake_pgrep)).replace('/usr/bin/open', str(fake_open))
            (scripts / 'run-dev-app.sh').write_text(runner)
            result = subprocess.run(['/bin/zsh', str(scripts / 'run-dev-app.sh'), '--version', '1.0.0-dev.1', '--build', '1'], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 70, result.stdout + result.stderr)
            self.assertIn(gate.REMINDER, result.stderr)
            self.assertFalse((root / 'opened').exists())
            self.assertEqual((root / 'built').exists(), blocked_pass == 2)

    def test_running_production_stops_before_build(self):
        self.exercise_runner(1)

    def test_production_opened_during_build_stops_before_launch(self):
        self.exercise_runner(2)


if __name__ == '__main__':
    unittest.main()
