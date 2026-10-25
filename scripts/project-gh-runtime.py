#!/usr/bin/env python3
"""Pinned, project-owned GitHub CLI. No global installation or authentication writes."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import platform
import re
import stat
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CONFIG = 'Config/Security/github-cli.json'
LIMIT = 64 * 1024 * 1024


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def owned(root, relative):
    path = root / relative
    if path.is_symlink() or not path.resolve().is_relative_to(root.resolve() / '.build'):
        raise ValueError('GitHub CLI storage escaped project .build')
    return path


def policy(root=ROOT):
    data = json.loads((root / CONFIG).read_text())
    if data.get('schemaVersion') != 1 or not re.fullmatch(r'2\.\d+\.\d+', data.get('version', '')):
        raise ValueError('Unreviewed GitHub CLI policy')
    if set(data.get('platforms', {})) != {'Darwin-arm64', 'Linux-x86_64', 'Linux-aarch64'}:
        raise ValueError('Unexpected GitHub CLI platform coverage')
    for identifier, row in data['platforms'].items():
        suffix = {'Darwin-arm64': 'macOS_arm64.zip', 'Linux-x86_64': 'linux_amd64.tar.gz',
                  'Linux-aarch64': 'linux_arm64.tar.gz'}[identifier]
        name = 'gh_' + data['version'] + '_' + suffix
        if (row.get('filename') != name or row.get('url') !=
                f'https://github.com/cli/cli/releases/download/v{data["version"]}/{name}'
                or row.get('archiveRoot') != name.removesuffix('.zip').removesuffix('.tar.gz')
                or type(row.get('size')) is not int or not 0 < row['size'] <= LIMIT):
            raise ValueError('Invalid official GitHub CLI source')
        for field in ('sha256', 'manifestSHA256'):
            if not re.fullmatch('[a-f0-9]{64}', row.get(field, '')):
                raise ValueError('Missing GitHub CLI fingerprint')
    return data


def selected(root=ROOT):
    data = policy(root)
    identity = platform.system() + '-' + platform.machine()
    if identity not in data['platforms']:
        raise ValueError('No reviewed GitHub CLI for this platform')
    return data, identity, data['platforms'][identity]


def files_in_archive(path, row):
    if path.is_symlink() or path.stat().st_size != row['size'] or sha(path) != row['sha256']:
        raise ValueError('GitHub CLI archive size/hash mismatch')
    result = {}; seen = set(); total = 0

    def accept(name, size, mode, directory, content):
        nonlocal total
        parts = PurePosixPath(name)
        if (parts.is_absolute() or '..' in parts.parts or '\\' in name or '\x00' in name
                or str(parts) in seen or len(seen) >= 5000 or not parts.parts):
            raise ValueError('Invalid GitHub CLI archive path')
        seen.add(str(parts)); total += size
        if size < 0 or total > 256 * 1024 * 1024:
            raise ValueError('Oversized GitHub CLI archive')
        # Tarballs contain a versioned directory; macOS ZIPs use the same layout.
        prefix = row['archiveRoot']
        if parts.parts[0] != prefix:
            raise ValueError('Unexpected GitHub CLI archive root')
        if directory:
            return
        relative = str(PurePosixPath(*parts.parts[1:]))
        if not relative or relative == '.':
            raise ValueError('Missing GitHub CLI file path')
        body = content()
        if len(body) != size:
            raise ValueError('Truncated GitHub CLI member')
        result[relative] = (body, 0o755 if mode & 0o111 else 0o644)

    if path.name.endswith('.zip'):
        with zipfile.ZipFile(path) as archive:
            for item in archive.infolist():
                mode = item.external_attr >> 16
                if stat.S_ISLNK(mode) or stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR):
                    raise ValueError('Unexpected GitHub CLI ZIP member')
                accept(item.filename, item.file_size, mode, item.is_dir(), lambda: archive.read(item))
    else:
        with tarfile.open(path, 'r:gz') as archive:
            for item in archive:
                if not (item.isfile() or item.isdir()):
                    raise ValueError('Unexpected GitHub CLI tar member')
                accept(item.name, item.size, item.mode, item.isdir(), lambda: archive.extractfile(item).read())
    if 'bin/gh' not in result or result['bin/gh'][1] != 0o755:
        raise ValueError('GitHub CLI executable missing')
    return result


def manifest(files):
    return json.dumps({name: {'sha256': hashlib.sha256(body).hexdigest(), 'mode': mode}
                       for name, (body, mode) in files.items()}, sort_keys=True, separators=(',', ':')).encode()


def verify(root=ROOT):
    data, identity, row = selected(root)
    target = owned(root, '.build/gh-runtime/' + identity)
    raw = owned(root, '.build/gh-runtime/' + identity + '-manifest.json').read_bytes()
    if hashlib.sha256(raw).hexdigest() != row['manifestSHA256']:
        raise ValueError('GitHub CLI installed manifest changed')
    expected = json.loads(raw); seen = set()
    for path in target.rglob('*'):
        if path.is_symlink():
            raise ValueError('GitHub CLI installed link rejected')
        if path.is_dir():
            continue
        name = path.relative_to(target).as_posix(); seen.add(name)
        if (name not in expected or not path.is_file() or sha(path) != expected[name]['sha256']
                or stat.S_IMODE(path.stat().st_mode) != expected[name]['mode']):
            raise ValueError('GitHub CLI installation changed')
    if seen != set(expected):
        raise ValueError('GitHub CLI installation incomplete')
    return target / 'bin/gh'


def setup(root=ROOT):
    data, identity, row = selected(root)
    target = owned(root, '.build/gh-runtime/' + identity)
    if target.exists():
        return verify(root)  # Never overwrite a changed or partial installation.
    cache = owned(root, '.build/gh-downloads'); cache.mkdir(parents=True, exist_ok=True)
    archive = owned(root, '.build/gh-downloads/' + row['filename'])
    if not archive.exists():
        with tempfile.TemporaryDirectory(dir=cache, prefix='download-') as directory:
            temporary = Path(directory) / row['filename']
            # Bootstrap is hash-pinned and credential-free; no pip/npm or gh download.
            subprocess.run(['curl', '--disable', '--fail', '--silent', '--show-error', '--location',
                            '--proto', '=https', '--proto-redir', '=https', '--max-time', '120',
                            '--max-filesize', str(row['size']), '--output', str(temporary), row['url']],
                           check=True, timeout=125)
            files_in_archive(temporary, row)
            temporary.replace(archive)
    files = files_in_archive(archive, row); raw = manifest(files)
    if hashlib.sha256(raw).hexdigest() != row['manifestSHA256']:
        raise ValueError('GitHub CLI archive manifest changed')
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=target.parent, prefix='install-') as directory:
        stage = Path(directory) / 'package'; stage.mkdir()
        for name, (body, mode) in files.items():
            path = stage / name; path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(body); path.chmod(mode)
        stage.rename(target)
    owned(root, '.build/gh-runtime/' + identity + '-manifest.json').write_bytes(raw)
    binary = verify(root)
    result = subprocess.run([str(binary), '--version'], capture_output=True, text=True, check=True, timeout=15)
    if not result.stdout.startswith('gh version ' + data['version'] + ' '):
        raise ValueError('GitHub CLI version differs from reviewed artifact')
    return binary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('setup', 'verify'))
    args = parser.parse_args()
    print(setup() if args.operation == 'setup' else verify())
