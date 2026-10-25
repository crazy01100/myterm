#!/usr/bin/env python3
"""Prepare/verify an unmodified official npm bundle in project-owned storage."""
import argparse
import base64
import hashlib
import importlib.util
import io
import json
from pathlib import Path, PurePosixPath
import re
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
CONFIG = 'Config/Security/node-tools.json'
MAX_ARCHIVE = 32 * 1024 * 1024


def policy(root):
    data = json.loads((root/CONFIG).read_text())
    row = data['npm']
    if (data.get('schemaVersion') != 1 or not re.fullmatch(r'24\.\d+\.\d+', data['nodeVersion'])
            or not re.fullmatch(r'11\.\d+\.\d+', row['version'])
            or row['url'] != f"https://registry.npmjs.org/npm/-/npm-{row['version']}.tgz"
            or not re.fullmatch(r'sha512-[A-Za-z0-9+/]{86}==', row['integrity'])):
        raise ValueError('Unreviewed Node/npm policy')
    return data


def owned(root, relative):
    path = root/relative
    if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()/'.build'):
        raise ValueError('npm tooling must remain inside project .build')
    return path


def archive_files(blob, row):
    if len(blob) > MAX_ARCHIVE or 'sha512-'+base64.b64encode(hashlib.sha512(blob).digest()).decode() != row['integrity']:
        raise ValueError('Official npm archive integrity mismatch')
    files = {}
    total = 0
    with tarfile.open(fileobj=io.BytesIO(blob), mode='r:gz') as archive:
        for index, member in enumerate(archive):
            name = PurePosixPath(member.name)
            if (index > 10000 or name.is_absolute() or not name.parts or name.parts[0] != 'package'
                    or '..' in name.parts or not (member.isfile() or member.isdir())):
                raise ValueError('Unexpected npm archive member')
            if member.isdir():
                continue
            relative = str(name.relative_to('package'))
            total += member.size
            if relative in files or member.size > MAX_ARCHIVE or total > 128*1024*1024:
                raise ValueError('Duplicate or oversized npm archive member')
            files[relative] = (archive.extractfile(member).read(), 0o755 if member.mode & 0o111 else 0o644)
    manifest = json.loads(files['package.json'][0])
    if manifest.get('name') != 'npm' or manifest.get('version') != row['version'] or 'bin/npm-cli.js' not in files:
        raise ValueError('npm archive identity differs from reviewed policy')
    return files


def verified_files(root):
    row = policy(root)['npm']
    archive = owned(root, '.build/node-toolchain/'+Path(row['url']).name)
    if archive.stat().st_size > MAX_ARCHIVE:
        raise ValueError('npm archive exceeds limit')
    return archive_files(archive.read_bytes(), row)


def verify(root=ROOT):
    files = verified_files(root)
    target = owned(root, '.build/npm-runtime')
    actual = set()
    for path in target.rglob('*'):
        if path.is_symlink():
            raise ValueError('Unexpected npm installation link')
        if path.is_file():
            relative = path.relative_to(target).as_posix()
            actual.add(relative)
            if relative not in files or path.stat().st_size != len(files[relative][0]) or path.read_bytes() != files[relative][0]:
                raise ValueError('npm installation differs from official archive')
            if path.stat().st_mode & 0o777 != files[relative][1]:
                raise ValueError('npm installation permissions differ from official archive')
    if actual != set(files):
        raise ValueError('npm installation is incomplete')
    return target/'bin/npm-cli.js'


def setup(root=ROOT):
    row = policy(root)['npm']
    cache = owned(root, '.build/node-toolchain')
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache/Path(row['url']).name
    if not archive.exists():
        spec=importlib.util.spec_from_file_location('python_toolchain',root/'scripts/python-toolchain.py')
        trust=importlib.util.module_from_spec(spec);spec.loader.exec_module(trust)
        request=urllib.request.Request(row['url'], headers={'User-Agent':'MyTerm-toolchain'})
        with urllib.request.urlopen(request, context=trust.https_context(root), timeout=45) as response:
            if response.url != row['url']:
                raise ValueError('Unexpected npm archive redirect')
            blob=response.read(MAX_ARCHIVE+1)
        archive_files(blob, row)  # Check before making even a cached file usable.
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as stage:
            stage.write(blob)
            temporary=Path(stage.name)
        temporary.replace(archive)
    files=verified_files(root)
    target=owned(root, '.build/npm-runtime')
    if target.exists():
        return verify(root)  # Never silently overwrite an altered installation.
    with tempfile.TemporaryDirectory(prefix='npm-', dir=cache) as directory:
        stage=Path(directory)/'package';stage.mkdir()
        for name, (content, mode) in files.items():
            path=stage/name;path.parent.mkdir(parents=True, exist_ok=True);path.write_bytes(content);path.chmod(mode)
        stage.rename(target)
    return verify(root)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('setup','verify'))
    args=parser.parse_args()
    print(setup() if args.command=='setup' else verify())


if __name__=='__main__':
    main()
