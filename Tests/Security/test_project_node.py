import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
LAUNCHER = ROOT/'scripts/project-node.sh'

class ProjectNodeTests(unittest.TestCase):
    def test_selected_lts_preserves_arguments_and_exit(self):
        result = subprocess.run([str(LAUNCHER),'-e','console.log(process.versions.node); console.log(process.argv[1]); process.exit(7)','space 中文'],capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,7,result.stderr)
        lines=result.stdout.splitlines()
        self.assertTrue(lines[0].startswith('24.'))
        self.assertEqual(lines[1],'space 中文')

    def test_invalid_override_does_not_fall_back(self):
        env={**os.environ,'MYTERM_NODE':'/nonexistent/myterm-test-node'}
        result=subprocess.run([str(LAUNCHER),'-e','console.log("must not execute")'],env=env,capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,69)
        self.assertEqual(result.stdout,'')
        self.assertIn('MYTERM_NODE',result.stderr)

if __name__=='__main__':unittest.main()
