#!/usr/bin/env python3
"""Run the unchanged test suite with a copy-only Application Support root.

No production settings, cloud config or signing material are copied. This is
not a replacement implementation for AppPaths in the product build.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
ROOT=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='MyTerm-isolated-tests-',dir='/private/tmp') as tmp:
    root=Path(tmp)
    for name in ['Sources','SelfTests','Vendor','scripts']:
        shutil.copytree(ROOT/name,root/name)
    shutil.copytree(ROOT/'Tests/Security',root/'Tests/Security')
    for name in ['Package.swift','Package.resolved']:
        shutil.copy2(ROOT/name,root/name)
    paths=root/'Sources/MySSHClient/Services/AppPaths.swift'
    source=paths.read_text()
    start=source.index('    static let rootDirectory: URL = {')
    end=source.index('    }()',start)+len('    }()')
    replacement=f'    static let rootDirectory = URL(fileURLWithPath: "{root}/application-support", isDirectory: true)'
    paths.write_text(source[:start]+replacement+source[end:])
    print('Isolated Application Support:',root/'application-support',flush=True)
    env = {**os.environ, 'MYTERM_PYTHON': sys.executable, 'PATH': str(Path(sys.executable).parent) + os.pathsep + os.environ.get('PATH', '')}
    subprocess.run([str(root/'scripts/run-tests.sh')],cwd=root,check=True,env=env)
    subprocess.run([str(root/'scripts/run-sftp-security-tests.sh')],cwd=root,check=True,env=env)
    subprocess.run(['zsh',str(root/'scripts/run-sftp-transfer-tests.sh')],cwd=root,check=True,env=env)
    subprocess.run(['zsh',str(root/'scripts/run-command-snippet-tests.sh')],cwd=root,check=True,env=env)
    subprocess.run(['zsh',str(root/'scripts/run-snippet-sync-tests.sh')],cwd=root,check=True,env=env)
