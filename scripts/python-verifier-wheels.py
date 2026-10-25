#!/usr/bin/env python3
"""Install hash-pinned verification tools from preverified local wheels only."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
CONFIG = 'Config/Security/verifier-wheels.json'
REQUIREMENTS = 'Tests/Security/requirements.txt'
MAX_WHEEL = 64 * 1024 * 1024


def requirements(text):
    result = {}
    text = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('#'))
    for line in text.replace('\\\n', ' ').splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r'\s*([A-Za-z0-9_-]+)==([0-9]+(?:\.[0-9]+)+)((?:\s+--hash=sha256:[a-f0-9]{64})+)\s*', line)
        if not match:
            raise ValueError('Only exact versions and SHA256 hashes are supported')
        name = re.sub(r'[-_.]+', '-', match[1]).lower()
        if name in result:
            raise ValueError('Duplicate verification dependency')
        result[name] = {'version': match[2], 'hashes': set(re.findall(r'sha256:([a-f0-9]{64})', match[3]))}
    if not result:
        raise ValueError('Empty verification requirements')
    return result


def configuration(root):
    text = (root/REQUIREMENTS).read_bytes()
    expected = requirements(text.decode())
    policy = json.loads((root/CONFIG).read_text())
    if policy.get('schemaVersion') != 1 or policy.get('requirementsSHA256') != hashlib.sha256(text).hexdigest():
        raise ValueError('Verification wheel manifest differs from requirements')
    wheels = policy.get('wheels', [])
    seen = set()
    for row in wheels:
        url = urllib.parse.urlsplit(row['url'])
        pin = expected.get(row['name'], {})
        if (url.scheme != 'https' or url.netloc != 'files.pythonhosted.org' or url.query or url.fragment
                or Path(url.path).name != row['filename'] or '/' in row['filename']
                or not row['filename'].endswith('.whl') or row['filename'] in seen
                or row['version'] != pin.get('version') or row['sha256'] not in pin.get('hashes', set())):
            raise ValueError('Wheel is not an approved official binary identity')
        seen.add(row['filename'])
    if {r['name'] for r in wheels} != set(expected):
        raise ValueError('Missing verification wheel identities')
    return wheels


def select(wheels, tags, parse_filename):
    rank = {tag: index for index, tag in enumerate(tags)}
    selected = {}
    for row in wheels:
        name, version, _, wheel_tags = parse_filename(row['filename'])
        if str(name) != row['name'] or str(version) != row['version']:
            raise ValueError('Wheel filename differs from reviewed metadata')
        positions = [rank[t] for t in wheel_tags if t in rank]
        if not positions:
            continue
        candidate = (min(positions), row['filename'], row)
        old = selected.get(row['name'])
        if old is None or candidate[:2] < old[:2]:
            selected[row['name']] = candidate
    if set(selected) != {r['name'] for r in wheels}:
        raise ValueError('No approved binary wheel for this interpreter/platform; no online fallback')
    return [selected[name][2] for name in sorted(selected)]


def verify(path, row):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_WHEEL:
        raise ValueError('Missing or unsafe verification wheel')
    if hashlib.sha256(path.read_bytes()).hexdigest() != row['sha256']:
        raise ValueError('Verification wheel hash mismatch')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('Pinned wheel downloads must not redirect')


def prepare(root, selected, context):
    cache = root/'.build/python-verifier-wheels'
    if cache.is_symlink() or not cache.resolve().is_relative_to(root.resolve()/'.build'):
        raise ValueError('Verification wheels must remain in project storage')
    cache.mkdir(parents=True, exist_ok=True)
    opener = urllib.request.build_opener(NoRedirect(), urllib.request.HTTPSHandler(context=context))
    paths = []
    for row in selected:
        target = cache/row['filename']
        if not target.exists():
            request = urllib.request.Request(row['url'], headers={'User-Agent':'MyTerm-verification-tools'})
            with tempfile.TemporaryDirectory(dir=cache, prefix='download-') as directory:
                stage = Path(directory)/row['filename']
                with opener.open(request, timeout=45) as response, stage.open('wb') as output:
                    total = 0
                    while chunk := response.read(1024*1024):
                        total += len(chunk)
                        if total > MAX_WHEEL:
                            raise ValueError('Verification wheel exceeds limit')
                        output.write(chunk)
                verify(stage, row)
                stage.replace(target)
        verify(target, row)
        paths.append(target)
    return paths


def install(python, paths, selected, env):
    # pip never receives a remote URL or index. Hash checking is repeated by pip.
    with tempfile.TemporaryDirectory(prefix='install-', dir=paths[0].parent) as directory:
        req = Path(directory)/'selected.txt'
        req.write_text(''.join(f'{p.resolve().as_uri()} --hash=sha256:{r["sha256"]}\n' for p, r in zip(paths, selected)))
        subprocess.run([str(python), '-I', '-m', 'pip', '--isolated', '--disable-pip-version-check',
                        'install', '--no-index', '--no-deps', '--no-build-isolation', '--no-cache-dir', '--force-reinstall',
                        '--require-hashes', '--only-binary=:all:', '-r', str(req)],
                       check=True, timeout=120, env=env)
        subprocess.run([str(python), '-I', '-m', 'pip', '--isolated', '--disable-pip-version-check', '--no-cache-dir', 'check'],
                       check=True, timeout=30, env=env)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('python_toolchain', ROOT/'scripts/python-toolchain.py')
    trust = importlib.util.module_from_spec(spec);spec.loader.exec_module(trust)
    import sys
    trust.validate_current(trust.inspect_current(), trust.configuration(ROOT), ROOT, 'security-tools')
    # The already hash-pinned pip supplies only wheel-tag parsing, with no HTTP.
    from pip._vendor.packaging.tags import sys_tags
    from pip._vendor.packaging.utils import parse_wheel_filename
    selected = select(configuration(ROOT), list(sys_tags()), parse_wheel_filename)
    paths = prepare(ROOT, selected, trust.https_context(ROOT))
    if not args.prepare_only:
        install(sys.executable, paths, selected, trust.clean_environment())
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps({'schemaVersion':1,'method':'verified-official-wheels-offline-pip',
                                          'installed':not args.prepare_only,'wheels':selected}, indent=2)+'\n')


if __name__ == '__main__':
    main()
