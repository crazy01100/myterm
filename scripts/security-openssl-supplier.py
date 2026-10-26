#!/usr/bin/env python3
"""Exact, project-Python-only OpenSSL supplier fixes. No installs or OS inventory."""
import copy
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
import sys
import tarfile
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ROOT = Path(__file__).resolve().parents[1]
CONFIG = 'Config/Security/openssl-supplier.json'
ROLES = ('python-runtime', 'security-tools')
ORIGINS = {r + '/openssl' for r in ROLES}
MAX_ARCHIVE = 16 * 1024 * 1024


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT/'scripts'/f'{name}.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def command(args):
    result = subprocess.run(args, capture_output=True, check=True, timeout=30,
                            env={**os.environ, 'LC_ALL': 'C'})
    if len(result.stdout) > 64 * 1024 * 1024:
        raise ValueError('Supplier evidence exceeds limit')
    return result.stdout


def loaded_libraries(maps, stat=os.stat, read=lambda p: Path(p).read_bytes()):
    """Bind mapped inode/device to the file being hashed; reject replaced/deleted libs."""
    found = {}
    for line in maps.splitlines():
        fields = line.split(None, 5)
        if len(fields) != 6 or not re.search(r'/lib(?:ssl|crypto)\.so(?:\.|$)', fields[5]):
            continue
        _, _, _, device, inode, path = fields
        if not re.fullmatch(r'/usr/lib/[A-Za-z0-9_-]+/lib(?:ssl|crypto)\.so\.3', path):
            raise ValueError('Unknown or deleted mapped OpenSSL library')
        st = stat(path)
        major, minor = [int(x, 16) for x in device.split(':')]
        if st.st_ino != int(inode) or (os.major(st.st_dev), os.minor(st.st_dev)) != (major, minor):
            raise ValueError('Mapped OpenSSL inode differs from disk')
        if path in found:
            continue
        if st.st_size > MAX_ARCHIVE:
            raise ValueError('Oversized mapped library')
        raw = read(path); after = stat(path)
        if (st.st_dev, st.st_ino, st.st_mtime_ns, st.st_size) != (after.st_dev, after.st_ino, after.st_mtime_ns, after.st_size):
            raise ValueError('OpenSSL changed during observation')
        found[path] = sha(raw)
    if sorted(Path(p).name for p in found) != ['libcrypto.so.3', 'libssl.so.3']:
        raise ValueError('Missing or ambiguous process OpenSSL mappings')
    return found


def probe():
    # ssl is already imported in this same interpreter, not a shell openssl binary.
    if not sys.platform.startswith('linux'):
        return {'status': 'not-applicable', 'reason': 'Existing non-Linux vendor identity remains authoritative'}
    libraries = loaded_libraries(Path('/proc/self/maps').read_text())
    packages = []
    for path in sorted(libraries):
        owner = command(['/usr/bin/dpkg-query', '-S', path]).decode().strip()
        match = re.fullmatch(r'(libssl3t64:amd64): ' + re.escape(path), owner)
        if not match:
            raise ValueError('Mapped library has no unique supported supplier package')
        fmt = '${binary:Package}\t${source:Package}\t${Version}\t${source:Version}\t${Architecture}\t${Status}'
        row = command(['/usr/bin/dpkg-query', '-W', '-f='+fmt, match[1]]).decode().split('\t')
        if len(row) != 6 or row[0] != match[1] or row[1] != 'openssl' or row[2] != row[3] or row[4:] != ['amd64', 'install ok installed']:
            raise ValueError('Unexpected OpenSSL package identity')
        packages.append({'package': 'libssl3t64', 'sourcePackage': row[1], 'version': row[2], 'architecture': row[4]})
    if packages[0] != packages[1] or libraries != loaded_libraries(Path('/proc/self/maps').read_text()):
        raise ValueError('Mixed or changed OpenSSL package contents')
    return {'status': 'observed', **packages[0], 'libraries': libraries, 'upstreamVersion': ssl.OPENSSL_VERSION.split()[1]}


def configuration(root):
    rule = json.loads((root/CONFIG).read_text())
    if rule.get('schemaVersion') != 1 or rule.get('grantsRiskException') is not False or len(rule.get('packages', [])) != 1:
        raise ValueError('Unknown supplier policy')
    for p in rule['packages']:
        if (p.get('provider') != 'Ubuntu' or p.get('package') != 'libssl3t64' or p.get('sourcePackage') != 'openssl'
                or p.get('architecture') != 'amd64' or not re.fullmatch(r'[0-9][0-9a-z.+~-]*', p.get('version', ''))
                or p.get('url') != f"https://archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl3t64_{p['version']}_amd64.deb"
                or set(p.get('libraries', {})) != {'/usr/lib/x86_64-linux-gnu/libssl.so.3', '/usr/lib/x86_64-linux-gnu/libcrypto.so.3'}
                or not 0 < p.get('size', 0) < MAX_ARCHIVE or not p.get('fixes')):
            raise ValueError('Unsupported supplier package')
        for h in [p['sha256'], p['changelogSHA256'], *p['libraries'].values(), *[x['advisorySHA256'] for x in p['fixes'].values()]]:
            if not re.fullmatch('[a-f0-9]{64}', h):
                raise ValueError('Missing official package or advisory hash')
        if any(not re.fullmatch(r'CVE-[0-9]{4}-[0-9]+', key) for key in p['fixes']):
            raise ValueError('Invalid supplier CVE')
    return rule


def version_ge(left, right):
    """Use the package manager's epoch/revision semantics, never string ordering."""
    if any(not re.fullmatch(r'(?:[0-9]+:)?[0-9][0-9A-Za-z.+:~\-]*', v) for v in (left, right)):
        raise ValueError('Invalid Debian version')
    result = subprocess.run(['/usr/bin/dpkg', '--compare-versions', left, 'ge', right], capture_output=True, timeout=5)
    if result.returncode not in (0, 1):
        raise ValueError('Cannot compare supplier revisions')
    return result.returncode == 0


def package_cache(root, p):
    cache = root/'.build/openssl-supplier'
    if cache.is_symlink() or not cache.resolve().is_relative_to(root.resolve()/'.build'):
        raise ValueError('Unowned supplier cache')
    cache.mkdir(parents=True, exist_ok=True)
    target = cache/(p['sha256']+'.deb')
    if target.is_symlink():
        raise ValueError('Linked supplier evidence')
    if not target.exists():
        trust = load('python-toolchain')
        with urllib.request.urlopen(p['url'], context=trust.https_context(root), timeout=35) as response:
            if response.url != p['url']:
                raise ValueError('Supplier package redirected')
            raw = response.read(MAX_ARCHIVE+1)
        if len(raw) != p['size'] or sha(raw) != p['sha256']:
            raise ValueError('Official package differs from pinned checksum')
        target.write_bytes(raw)
    if target.stat().st_size != p['size'] or sha(target.read_bytes()) != p['sha256']:
        raise ValueError('Supplier cache differs from official package')
    return target


def verify_package(root, p):
    archive = package_cache(root, p)
    # Read members only. No installation, extraction, maintainer scripts or code execution.
    raw = command(['/usr/bin/dpkg-deb', '--fsys-tarfile', str(archive)])
    wanted = {path.lstrip('/'): h for path, h in p['libraries'].items()}
    wanted[p['changelogPath']] = p['changelogSHA256']
    found = {}; changelog = None
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:') as source:
        for member in source:
            name = member.name.removeprefix('./')
            if name not in wanted:
                continue
            if name in found or not member.isfile() or member.size > MAX_ARCHIVE:
                raise ValueError('Duplicate, linked or oversized supplier member')
            data = source.extractfile(member).read(MAX_ARCHIVE+1)
            if sha(data) != wanted[name]:
                raise ValueError('Supplier member hash mismatch')
            found[name] = True
            if name == p['changelogPath']:
                with gzip.GzipFile(fileobj=io.BytesIO(data)) as compressed:
                    changelog = compressed.read(4*1024*1024+1).decode()
    if set(found) != set(wanted) or changelog is None or len(changelog) > 4*1024*1024:
        raise ValueError('Missing supplier file or changelog')
    fixes = changelog_fixes(changelog)
    for identifier, fix in p['fixes'].items():
        if fixes.get(identifier) != fix['fixedVersion'] or not version_ge(p['version'], fix['fixedVersion']):
            raise ValueError('Official changelog does not establish the approved fix')
    return {'packageSHA256': p['sha256'], 'changelogSHA256': p['changelogSHA256'], 'url': p['url']}


def changelog_fixes(text):
    fixes = {}
    for block in re.split(r'(?m)(?=^openssl \()', text):
        match = re.match(r'openssl \(([^)]+)\) resolute(?:-security)?;', block)
        if match and 'SECURITY UPDATE:' in block:
            for identifier in re.findall(r'(?m)^    - (CVE-[0-9]{4}-[0-9]+)\s*$', block):
                # Newest fix wins. Do not silently accept a later correction/revert.
                fixes.setdefault(identifier, match[1])
    return fixes


def verify_environments(root, p):
    proof = []
    for role in ROLES:
        python = root/'.build'/role/'bin/python3'
        observed = json.loads(command([str(python), '-I', '-B', str(ROOT/'scripts/security-openssl-supplier.py'), '--probe']))
        fields = ('package', 'sourcePackage', 'version', 'architecture', 'libraries', 'upstreamVersion')
        if observed.get('status') != 'observed' or any(observed.get(k) != p[k] for k in fields):
            raise ValueError('Loaded OpenSSL differs from pinned official package')
        proof.append({'origin': role+'/openssl', **observed})
    return {'environments': proof, 'package': verify_package(root, p)}


def matches(f, environment, p):
    observations = f.get('environmentObservations', [])
    return (f.get('id') in p['fixes'] and f.get('component') == 'OpenSSL' and f.get('scope') == 'development'
            and f.get('version') == p['upstreamVersion'] and f.get('queryComplete') is True
            and f.get('url') == 'https://openssl-library.org/news/secjson/'+f['id'].lower()+'.json'
            and set(f.get('dependencyPaths', [])) == ORIGINS and len(observations) == 2
            and {o.get('origin') for o in observations} == ORIGINS
            and all(o.get('environment') == environment and o.get('versions') == [p['upstreamVersion']] for o in observations))


def classify(report, root, fetch=None):
    if 'supplierFixReviews' in report:
        raise ValueError('Supplier classification must use a fresh scan')
    report['supplierFixReviews'] = []
    environment = 'ci' if os.environ.get('GITHUB_ACTIONS') == 'true' else 'local'
    if report.get('observedEnvironment') != environment:
        return
    p = configuration(root)['packages'][0]
    candidates = [f for f in report['findings'] if matches(f, environment, p)]
    if not candidates:
        return
    fetch = fetch or load('security-native-advisories').fetch
    try:
        evidence = verify_environments(root, p)
    except Exception as error:
        report.setdefault('errors', []).append('OpenSSL supplier identity unavailable: '+type(error).__name__)
        return
    def review(f):
        try:
            record = fetch(f['url'])
            if (record.get('cveMetadata', {}).get('cveId') != f['id'] or record['cveMetadata'].get('state') != 'PUBLISHED'
                    or digest(record) != p['fixes'][f['id']]['advisorySHA256']):
                raise ValueError('Upstream advisory changed')
            return {'status': 'supplier-fixed', 'finding': copy.deepcopy(f), 'environment': environment,
                    'fixedVersion': p['fixes'][f['id']]['fixedVersion'], 'evidence': evidence,
                    'advisorySHA256': digest(record), 'policySHA256': sha((root/CONFIG).read_bytes()),
                    'grantsRiskException': False}
        except Exception as error:
            return {'error': 'OpenSSL supplier advisory check failed: '+f['id']+' '+type(error).__name__}
    with ThreadPoolExecutor(max_workers=4) as pool:
        reviews = list(pool.map(review, candidates))
    for r in reviews:
        if 'error' in r:
            report.setdefault('errors', []).append(r['error'])
        else:
            report['supplierFixReviews'].append(r)
            report['findings'].remove(r['finding'])


def validate_envelope(report):
    reviews = report.get('supplierFixReviews', [])
    if (not isinstance(reviews, list) or len(reviews) > 500
            or reviews and not isinstance(report.get('rawFindings'), list)):
        raise ValueError('Invalid supplier fix envelope')
    ids = set()
    for r in reviews:
        f = r.get('finding', {})
        if (r.get('status') != 'supplier-fixed' or r.get('grantsRiskException') is not False
                or f.get('component') != 'OpenSSL' or f.get('id') in ids or f.get('scope') != 'development'
                or set(f.get('dependencyPaths', [])) != ORIGINS or not isinstance(r.get('evidence'), dict)):
            raise ValueError('Unsupported supplier fix')
        ids.add(f['id'])


def revalidate(report, root, fetch=None):
    validate_envelope(report)
    if not report.get('supplierFixReviews'):
        return
    fresh = {'findings': [copy.deepcopy(r['finding']) for r in report['supplierFixReviews']],
             'observedEnvironment': report.get('observedEnvironment'), 'errors': []}
    classify(fresh, root, fetch)
    if fresh['errors'] or fresh['findings'] or digest(fresh['supplierFixReviews']) != digest(report['supplierFixReviews']):
        raise ValueError('Supplier evidence changed; preserve Issues and rescan')


def covers_previous(report, finding):
    """Only this CVE and every previous environment/origin; never general closure permission."""
    for review in report.get('supplierFixReviews', []):
        current = review['finding']
        if any(finding.get(k) != current.get(k) for k in ('id', 'component', 'scope')):
            continue
        observations = finding.get('environmentObservations', [])
        known = {(o['environment'], o['origin']) for o in current['environmentObservations']}
        if (observations and all((o['environment'], o['origin']) in known for o in observations)
                and set(finding.get('dependencyPaths', [])) <= ORIGINS):
            return True
    return False


if __name__ == '__main__':
    if sys.argv[1:] != ['--probe']:
        raise SystemExit('Only the read-only Python process probe is supported')
    print(json.dumps(probe(), sort_keys=True))
