#!/usr/bin/env python3
"""Explicit policy/mock suites only: no npm loading or vulnerability probes."""
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
SUITES=('test_conditional_risk.py','test_audit_policy.py','test_security_issues.py',
        'test_risk_context.py','test_dev_launch_gate.py','test_security_test_profile.py')
if __name__=='__main__':
    for suite in SUITES:
        subprocess.run([sys.executable,'-m','unittest','discover','-s','Tests/Security',
                        '-p',suite,'-v'],cwd=ROOT,check=True)
