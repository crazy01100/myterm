"""Run the isolated administrator-tool safety suite during normal CI discovery."""
from pathlib import Path
import subprocess
import unittest


class InvitationToolTests(unittest.TestCase):
    def test_administrator_boundaries(self):
        root = Path(__file__).resolve().parents[2]
        result = subprocess.run(
            [str(root / "scripts/project-node.sh"), "--test", "Tests/Security/invite-sync-user.test.mjs"],
            cwd=root, capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
