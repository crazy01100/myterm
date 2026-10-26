#!/usr/bin/env python3
"""Project-owned Python tool bootstrap and read-only trust inventory.

Bootstrap downloads only pinned wheels and verifies their independent hashes
before offline installation. Never modifies the shared/base interpreter.
"""
import argparse
import ast
import hashlib
import importlib.metadata
import json
import os
import platform
from pathlib import Path
import re
import ssl
import subprocess
import sys
import sysconfig
import tempfile
from urllib.parse import urlparse
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CONFIG = 'Config/Security/python-tools.json'
ROLES = {'project-runtime': '.build/python-runtime', 'security-tools': '.build/security-tools'}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def configuration(root=ROOT):
    data = json.loads((root / CONFIG).read_text())
    if data.get('schemaVersion') != 2 or set(data.get('packages', {})) != {'pip', 'certifi'}:
        raise ValueError('Unknown Python bootstrap policy')
    for name, row in data['packages'].items():
        url = urlparse(row['url'])
        if (url.scheme != 'https' or url.netloc != 'files.pythonhosted.org' or url.query or url.fragment
                or not re.fullmatch(r'[0-9]+(?:\.[0-9]+)+', row['version'])
                or Path(url.path).name != f"{name}-{row['version']}-py3-none-any.whl"
                or not re.fullmatch('[a-f0-9]{64}', row['sha256'])
                or not re.fullmatch('[a-f0-9]{64}', row.get('caSHA256', ''))):
            raise ValueError('Invalid pinned wheel identity')
    for name, floor in [('pip', (26, 2, 2)), ('certifi', (2026, 10, 19))]:
        if tuple(map(int, data['packages'][name]['version'].split('.'))) < floor:
            raise ValueError('Bootstrap pin is below the official security floor: ' + name)
    vendor_version = data['packages']['pip'].get('vendoredCertifi', '')
    if (not re.fullmatch(r'[0-9]+(?:\.[0-9]+)+', vendor_version)
            or tuple(map(int, vendor_version.split('.'))) < (2026, 10, 19)):
        raise ValueError('Missing or outdated pinned pip certificate version')
    return data


def clean_environment():
    # Do not inherit custom indexes, pip config, Python imports or trust overrides.
    env = {k: v for k, v in os.environ.items() if not k.startswith(('PIP_', 'PYTHON'))
           and k not in ('SSL_CERT_FILE', 'SSL_CERT_DIR', 'REQUESTS_CA_BUNDLE', 'CURL_CA_BUNDLE')}
    env.update(PIP_CONFIG_FILE=os.devnull, PIP_DISABLE_PIP_VERSION_CHECK='1', PYTHONDONTWRITEBYTECODE='1')
    return env


def owned_path(path, root=ROOT):
    root = root.resolve()
    path = Path(path)
    if not path.resolve().is_relative_to(root / '.build') or path.is_symlink():
        raise ValueError('Python tool output must remain inside project .build')
    return path


def verify_wheel(path, name, row, policy):
    if sha(path) != row['sha256']:
        raise ValueError('Pinned wheel hash mismatch: ' + name)
    with zipfile.ZipFile(path) as archive:
        metadata = archive.read(f"{name}-{row['version']}.dist-info/METADATA").decode()
        if f'\nName: {name}\n' not in '\n' + metadata or f"\nVersion: {row['version']}\n" not in '\n' + metadata:
            raise ValueError('Wheel metadata does not match pin')
        member = 'pip/_vendor/certifi/cacert.pem' if name == 'pip' else 'certifi/cacert.pem'
        if hashlib.sha256(archive.read(member)).hexdigest() != row['caSHA256']:
            raise ValueError('Wheel CA bundle differs from reviewed source')
        if name == 'pip':
            vendor = literal_version_text(archive.read('pip/_vendor/certifi/__init__.py').decode())
            if vendor != row['vendoredCertifi']:
                raise ValueError('Wheel vendored certifi version differs from reviewed source')


def prepare(root=ROOT):
    policy = configuration(root)
    cache = owned_path(root / '.build/python-bootstrap', root)
    cache.mkdir(parents=True, exist_ok=True)
    wheels = []
    for name, row in policy['packages'].items():
        target = owned_path(cache / Path(urlparse(row['url']).path).name, root)
        if target.exists():
            verify_wheel(target, name, row, policy)  # Corrupt caches fail, never silently pass.
        else:
            with tempfile.TemporaryDirectory(prefix='download-', dir=cache) as temporary:
                wheel = Path(temporary) / target.name
                subprocess.run(['curl', '--disable', '--fail', '--silent', '--show-error', '--location',
                                '--proto', '=https', '--proto-redir', '=https', '--max-time', '60',
                                '--output', str(wheel), row['url']], check=True, env=clean_environment(), timeout=65)
                verify_wheel(wheel, name, row, policy)
                wheel.replace(target)
        wheels.append(target)
    return wheels


def literal_version(path):
    return literal_version_text(path.read_text())


def literal_version_text(text):
    for node in ast.parse(text).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == '__version__' for t in node.targets):
            value = ast.literal_eval(node.value)
            if isinstance(value, str):
                return value
    raise ValueError('Cannot inspect vendored certifi version')


def inspect_current():
    result = {'python': '.'.join(map(str, sys.version_info[:3])), 'prefix': sys.prefix,
              'basePrefix': sys.base_prefix, 'purelib': sysconfig.get_path('purelib'),
              'ensurepip': None, 'packages': [], 'sslDefaultCA': ssl.get_default_verify_paths().cafile}
    try:
        import ensurepip
        result['ensurepip'] = ensurepip.version()
    except ImportError:
        pass
    for name in ('pip', 'certifi', 'uv'):
        try:
            dist = importlib.metadata.distribution(name)
        except importlib.metadata.PackageNotFoundError:
            continue
        row = {'name': name, 'version': dist.version, 'origin': name}
        if name == 'certifi':
            ca = Path(dist.locate_file('certifi/cacert.pem'))
            row.update(caPath=str(ca), caSHA256=sha(ca))
        result['packages'].append(row)
        if name == 'pip':
            vendor = Path(dist.locate_file('pip/_vendor/certifi'))
            result['packages'].append({'name': 'certifi', 'version': literal_version(vendor / '__init__.py'),
                                       'origin': 'pip/_vendor/certifi', 'caPath': str(vendor / 'cacert.pem'),
                                       'caSHA256': sha(vendor / 'cacert.pem')})
    return result


def validate_current(info, policy, root=ROOT, role=None):
    paths = {key: (root / relative).resolve() for key, relative in ROLES.items()}
    prefix = Path(info['prefix']).resolve()
    if prefix not in paths.values() or (role and prefix != paths[role]):
        raise ValueError('Interpreter is not a managed project tool environment')
    if prefix == Path(info['basePrefix']).resolve() or not Path(info['purelib']).resolve().is_relative_to(prefix):
        raise ValueError('Refusing shared/base interpreter package writes or use')
    runtime_policy=root/'Config/Security/python-runtime.json'
    if platform.system()=='Darwin' and platform.machine()=='arm64' and runtime_policy.is_file():
        runtime=json.loads(runtime_policy.read_text())
        if (Path(info['basePrefix']).resolve()!=(root/'.build/python-base').resolve() or
                info['python']!=runtime['pythonVersion']):
            raise ValueError('Python tools must use the reviewed project-owned base runtime')
    rows = {p['origin']: p for p in info['packages']}
    expected = {'pip': policy['packages']['pip']['version'], 'certifi': policy['packages']['certifi']['version'],
                'pip/_vendor/certifi': policy['packages']['pip']['vendoredCertifi']}
    for origin, version in expected.items():
        if rows.get(origin, {}).get('version') != version:
            raise ValueError('Python tools need trusted setup: ' + origin)
        if 'certifi' in origin:
            row = rows[origin]
            pin = policy['packages']['pip' if origin == 'pip/_vendor/certifi' else 'certifi']
            if row.get('caSHA256') != pin['caSHA256'] or not Path(row['caPath']).resolve().is_relative_to(prefix):
                raise ValueError('Unreviewed CA bundle: ' + origin)
    return rows['certifi']['caPath']


def ca_path(root=ROOT):
    return validate_current(inspect_current(), configuration(root), root)


def https_context(root=ROOT):
    # Explicit cafile avoids silently combining an old OpenSSL/system CA file.
    return ssl.create_default_context(cafile=ca_path(root))


def inspect_environment(python, root=ROOT):
    output = subprocess.run([str(python), '-I', '-B', str(root / 'scripts/python-toolchain.py'), 'inspect'],
                            check=True, capture_output=True, text=True, timeout=20, env=clean_environment()).stdout
    return json.loads(output)


def inventory(root=ROOT):
    rows = []
    for role, relative in ROLES.items():
        target = owned_path(root / relative, root)
        info = inspect_environment(target / 'bin/python3', root)
        if (Path(info['prefix']).resolve() != target.resolve()
                or info['prefix'] == info['basePrefix']
                or not Path(info['purelib']).resolve().is_relative_to(target.resolve())):
            raise ValueError('Unexpected environment ownership: ' + role)
        # No host/user paths in public evidence.
        rows.append({'role': role, 'python': info['python'], 'ensurepip': info['ensurepip'],
                     'packages': [{k: v for k, v in p.items() if k != 'caPath'} for p in info['packages']]})
    return rows


def setup(root=ROOT, rebuild=False):
    wheels = prepare(root)  # Every artifact verified before any environment is changed.
    policy = configuration(root)
    env = clean_environment()
    for role, relative in ROLES.items():
        target = owned_path(root / relative, root)
        python = target / 'bin/python3'
        if target.exists() and not (target / 'pyvenv.cfg').is_file():
            raise ValueError('Existing target is not a venv; preserved')
        if rebuild or not python.exists():
            subprocess.run([sys._base_executable, '-I', '-m', 'venv', *(['--clear'] if rebuild else []), str(target)],
                           check=True, env=env, timeout=120)
        before = inspect_environment(python, root)
        if (Path(before['prefix']).resolve() != target.resolve()
                or before['prefix'] == before['basePrefix']
                or not Path(before['purelib']).resolve().is_relative_to(target.resolve())):
            raise ValueError('Refusing installation outside target venv')
        subprocess.run([str(python), '-I', '-m', 'pip', '--isolated', '--disable-pip-version-check',
                        'install', '--no-index', '--no-deps', '--no-cache-dir', '--upgrade', '--force-reinstall',
                        *map(str, wheels)], check=True, env=env, timeout=120)
        validate_current(inspect_environment(python, root), policy, root, role)
        print(role + ': pinned pip and both CA bundles verified')


def main():
    if sys.version_info < (3, 12):
        print('Python >=3.12 is required.', file=sys.stderr)
        return 1
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('setup', 'inspect', 'inventory', 'verify', 'ca-path'))
    parser.add_argument('--rebuild', action='store_true')
    args = parser.parse_args()
    if args.rebuild and args.action != 'setup':
        parser.error('--rebuild is only valid for explicit setup')
    try:
        if args.action == 'setup':
            setup(rebuild=args.rebuild)
        elif args.action == 'inspect':
            print(json.dumps(inspect_current()))
        elif args.action == 'inventory':
            print(json.dumps(inventory(), indent=2))
        else:
            ca = ca_path()
            print(ca if args.action == 'ca-path' else 'Python tools and CA bundles match the reviewed policy.')
        return 0
    except (OSError, ValueError, KeyError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print('Python toolchain unavailable: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
