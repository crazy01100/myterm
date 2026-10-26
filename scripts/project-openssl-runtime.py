#!/usr/bin/env python3
"""Prepare exact official OpenSSL libraries for project CI Python, never system install."""
import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CONFIG = 'Config/Security/openssl-supplier.json'
CHECKSUMS = 'Config/Security/openssl-runtime.sha256'
RELATIVE = '.build/openssl-runtime'


def supplier():
    spec = importlib.util.spec_from_file_location('openssl_supplier', Path(__file__).resolve().parent/'security-openssl-supplier.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def owned(root, path):
    root = root.resolve(); path = Path(path)
    if not path.is_relative_to(root/'.build'):
        raise ValueError('OpenSSL runtime escapes project storage')
    for parent in (path, *path.parents):
        if parent == root:
            break
        if parent.is_symlink():
            raise ValueError('Linked OpenSSL runtime path')
    return path


def paths(root, p):
    return {name: root/RELATIVE/'lib'/Path(name).name for name in p['libraries']}


def verify(root=ROOT, p=None):
    p = p or supplier().configuration(root)['packages'][0]
    target = owned(root, root/RELATIVE)
    lib = owned(root, target/'lib')
    expected = paths(root, p)
    if (not lib.is_dir() or set(target.iterdir()) != {lib}
            or set(lib.iterdir()) != set(expected.values())):
        raise ValueError('Missing or additional isolated OpenSSL files')
    for member, file in expected.items():
        owned(root, file)
        if not file.is_file() or file.stat().st_size > 16*1024*1024 or hashlib.sha256(file.read_bytes()).hexdigest() != p['libraries'][member]:
            raise ValueError('Isolated OpenSSL content differs from official package')
    manifest = ''.join(p['libraries'][member]+'  '+Path(member).name+'\n' for member in sorted(expected))
    if (root/CHECKSUMS).read_text() != manifest:
        raise ValueError('Prelaunch OpenSSL checksums differ from package policy')
    return {'status': 'verified', 'source': 'project-isolated-official-package',
            'packageSHA256': p['sha256'], 'version': p['version'], 'libraries': p['libraries']}


def library_bytes(raw, p):
    """Read only two hash-bound regular members; never extract paths or execute scripts."""
    wanted = {name.lstrip('/'): name for name in p['libraries']}; found = {}
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:') as archive:
        for member in archive:
            name = member.name.removeprefix('./')
            if name not in wanted:
                continue
            if name in found or not member.isfile() or not 0 < member.size < 16*1024*1024:
                raise ValueError('Duplicate or linked isolated library')
            data = archive.extractfile(member).read(16*1024*1024+1)
            if hashlib.sha256(data).hexdigest() != p['libraries'][wanted[name]]:
                raise ValueError('Official library content mismatch')
            found[name] = data
    if set(found) != set(wanted):
        raise ValueError('Incomplete official OpenSSL package')
    return {Path(name).name: data for name, data in found.items()}


def setup(root=ROOT):
    if platform.system() != 'Linux' or platform.machine() != 'x86_64' or os.environ.get('GITHUB_ACTIONS') != 'true':
        raise ValueError('This runtime preparation is limited to Linux x86_64 project CI')
    helper = supplier(); p = helper.configuration(root)['packages'][0]
    target = owned(root, root/RELATIVE)
    if target.exists():
        return verify(root, p)  # Never silently replace a drifted runtime.
    cache = owned(root, root/'.build/openssl-supplier'); cache.mkdir(parents=True, exist_ok=True)
    archive = owned(root, cache/(p['sha256']+'.deb'))
    if not archive.exists():
        with tempfile.TemporaryDirectory(dir=cache, prefix='bootstrap-') as directory:
            stage = Path(directory)/'official.deb'
            subprocess.run(['/usr/bin/curl', '--disable', '--fail', '--silent', '--show-error',
                            '--proto', '=https', '--max-time', '60', '--max-filesize', str(p['size']),
                            '--output', str(stage), p['url']], check=True, timeout=65)
            if stage.stat().st_size != p['size'] or hashlib.sha256(stage.read_bytes()).hexdigest() != p['sha256']:
                raise ValueError('Official OpenSSL bootstrap checksum mismatch')
            stage.replace(archive)
    helper.verify_package(root, p)  # Cache, both library hashes and all declared fix records.
    raw = helper.command(['/usr/bin/dpkg-deb', '--fsys-tarfile', str(archive)])
    files = library_bytes(raw, p)
    with tempfile.TemporaryDirectory(dir=cache, prefix='runtime-') as directory:
        stage = Path(directory)/'runtime'; (stage/'lib').mkdir(parents=True)
        for name, data in files.items():
            file = stage/'lib'/name; file.write_bytes(data); file.chmod(0o444)
        stage.rename(target)
    return verify(root, p)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('setup', 'verify'))
    args = parser.parse_args()
    print(json.dumps(setup() if args.action == 'setup' else verify(), sort_keys=True))
