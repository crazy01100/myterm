#!/usr/bin/env python3
"""Evidence-bound applicability of explicitly reviewed pip vendor subsets.

Keep original version matches. Never grant an exception or close an Issue.
"""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CONFIG = 'Config/Security/pip-applicability.json'
IDS = {'GHSA-5rjg-fvgr-3xxf', 'GHSA-h35f-9h28-mq5c', 'GHSA-xmj3-9gf7-h52w'}
MSGPACK_ID = 'GHSA-6v7p-g79w-8964'
MSGPACK_PATCH = '2c56ddb5d0025ed481d962c0f5d62d19dec7476d'
MSGPACK_FILES = {'__init__.py', 'COPYING', 'exceptions.py', 'fallback.py', 'ext.py'}
ROLES = ('python-runtime', 'security-tools')
ORIGINS = {role + '/pip-vendored' for role in ROLES}
ADVISORY_FIELDS = ('ghsa_id', 'html_url', 'withdrawn_at', 'summary', 'description', 'vulnerabilities')


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                     separators=(',', ':')).encode()).hexdigest()


def advisory_digest(row):
    return digest({name: row.get(name) for name in ADVISORY_FIELDS})


def msgpack_patch_digest(row):
    paths = {'msgpack/_unpacker.pyx', 'msgpack/unpack_template.h'}
    files = [f for f in row['files'] if f['filename'] in paths]
    if (row.get('sha') != MSGPACK_PATCH or len(files) != 2
            or {f['filename'] for f in files} != paths
            or any(f.get('status') != 'modified' or not re.fullmatch('[a-f0-9]{40}', f.get('sha', '')) for f in files)):
        raise ValueError('Official msgpack patch identity changed')
    return digest({f['filename']: f['sha'] for f in files})


def configuration(root):
    data = json.loads((root / CONFIG).read_text())
    if (data.get('schemaVersion') != 1 or data.get('decision') != 'pip-setuptools-subset'
            or data.get('state') != 'approved' or data.get('grantsRiskException') is not False
            or set(data.get('advisories', {})) != IDS or data.get('pipVersion') != '26.2.2'
            or data.get('componentVersion') != '70.3.0'):
        raise ValueError('Unreviewed pip applicability scope')
    for value in [data.get('wheelSHA256', ''), data.get('vendorManifestSHA256', ''),
                  *data['advisories'].values()]:
        if not re.fullmatch('[a-f0-9]{64}', value):
            raise ValueError('Missing exact applicability evidence')
    msgpack = data.get('msgpack')
    if msgpack is not None:
        if (msgpack.get('decision') != 'pip-msgpack-pure-python' or msgpack.get('state') != 'approved'
                or msgpack.get('id') != MSGPACK_ID or msgpack.get('componentVersion') != '1.1.2'
                or msgpack.get('patchCommit') != MSGPACK_PATCH
                or any(not re.fullmatch('[a-f0-9]{64}', msgpack.get(k, '')) for k in ('advisorySHA256', 'patchSHA256'))):
            raise ValueError('Unreviewed msgpack applicability scope')
    return data


def vendor_manifest(files):
    return digest({name: hashlib.sha256(body).hexdigest() for name, body in files.items()})


def verify_installed(site, files):
    """Compare this interpreter's subset; absence alone is never sufficient."""
    if (any(site.glob('*.pth')) or any(site.glob('*setuptools*.dist-info'))
            or any(site.glob('sitecustomize*')) or any(site.glob('usercustomize*'))
            or (site / 'setuptools').exists() or (site / 'setuptools.py').exists()):
        raise ValueError('External setuptools or Python path hooks require review')
    vendor = site / 'pip/_vendor'
    if vendor.is_symlink() or not vendor.resolve().is_relative_to(site.resolve()):
        raise ValueError('Vendor directory is not owned by this environment')
    seen = set()
    for path in vendor.rglob('*'):
        if path.is_symlink():
            raise ValueError('Vendor source contains links')
        if path.is_dir():
            continue
        if '__pycache__' in path.parts:
            continue  # Derived bytecode is not source-package identity evidence.
        name = path.relative_to(site).as_posix(); seen.add(name)
        if (name not in files or not path.is_file() or path.stat().st_size != len(files[name])
                or path.read_bytes() != files[name]):
            raise ValueError('Installed vendor source differs from official wheel')
    if seen != set(files) or (vendor / 'setuptools').exists():
        raise ValueError('Missing vendor sources or affected module was introduced')


def verify_msgpack_subset(files):
    names = {name.removeprefix('pip/_vendor/msgpack/') for name in files
             if name.startswith('pip/_vendor/msgpack/')}
    if names != MSGPACK_FILES:
        raise ValueError('Reviewed pure-Python msgpack subset changed')


def verify_environments(root, rule):
    spec = importlib.util.spec_from_file_location('pip_trust', root / 'scripts/python-toolchain.py')
    trust = importlib.util.module_from_spec(spec); spec.loader.exec_module(trust)
    policy = trust.configuration(root); pip = policy['packages']['pip']
    if pip['version'] != rule['pipVersion'] or pip['sha256'] != rule['wheelSHA256']:
        raise ValueError('Reviewed pip wheel changed')
    archive = root / '.build/python-bootstrap' / Path(pip['url']).name
    if archive.is_symlink() or not archive.resolve().is_relative_to(root.resolve() / '.build'):
        raise ValueError('Unowned wheel evidence')
    if archive.stat().st_size > 16 * 1024 * 1024:
        raise ValueError('Oversized wheel evidence')
    trust.verify_wheel(archive, 'pip', pip, policy)
    with zipfile.ZipFile(archive) as source:
        names = source.namelist()
        if len(names) != len(set(names)):
            raise ValueError('Duplicate wheel entries')
        files = {name: source.read(name) for name in names
                 if name.startswith('pip/_vendor/') and not name.endswith('/')}
    if (vendor_manifest(files) != rule['vendorManifestSHA256']
            or any(name.startswith('pip/_vendor/setuptools/') for name in files)
            or 'pip/_vendor/pkg_resources/__init__.py' not in files):
        raise ValueError('Official vendor subset changed')
    if rule.get('msgpack'):
        verify_msgpack_subset(files)
    environments = []
    for role in ROLES:
        target = root / '.build' / role
        if target.is_symlink() or not target.resolve().is_relative_to(root.resolve() / '.build'):
            raise ValueError('Managed environment escaped project ownership')
        config = (target / 'pyvenv.cfg').read_text()
        if not re.search(r'^include-system-site-packages\s*=\s*false\s*$', config, re.M | re.I):
            raise ValueError('Global site packages may enter the managed environment')
        info = trust.inspect_environment(target / 'bin/python3', root)
        trust_role = 'project-runtime' if role == 'python-runtime' else role
        trust.validate_current(info, policy, root, trust_role)
        site = Path(info['purelib'])
        if rule.get('msgpack') and (any(site.glob('*msgpack*.dist-info'))
                                   or (site/'msgpack').exists() or (site/'msgpack.py').exists()):
            raise ValueError('External msgpack requires separate review')
        verify_installed(site, files)
        environments.append({'role': role, 'origin': role + '/pip-vendored',
                             'vendorFiles': len(files), 'vendorManifestSHA256': vendor_manifest(files)})
    return {'wheelSHA256': rule['wheelSHA256'], 'pipVersion': rule['pipVersion'],
            'environments': environments, 'globalSitePackages': False}


def target(identifier, rule):
    if identifier in IDS:
        return 'setuptools', rule['componentVersion'], 'pip-setuptools-subset'
    if identifier == MSGPACK_ID and rule.get('msgpack'):
        return 'msgpack', rule['msgpack']['componentVersion'], 'pip-msgpack-pure-python'
    return None


def matches(finding, environment, rule):
    expected = target(finding.get('id'), rule)
    if expected is None:
        return False
    component, version, _ = expected
    observations = finding.get('environmentObservations', [])
    return (finding.get('component') == component
            and finding.get('scope') == 'verification-tool'
            and finding.get('version') == version
            and finding.get('queryComplete') is True
            and finding.get('url') == 'https://github.com/advisories/' + finding['id']
            and set(finding.get('dependencyPaths', [])) == ORIGINS
            and len(observations) == len(ROLES)
            and {o.get('origin') for o in observations} == ORIGINS
            and all(o.get('environment') == environment and o.get('versions') == [version]
                    for o in observations))


def classify(report, root, fetch):
    """Called on a fresh scan, not on a previously classified or supplied report."""
    if any(key in report for key in ('rawFindings', 'applicabilityReviews')):
        raise ValueError('Applicability must use the original fresh scan')
    report['rawFindings'] = copy.deepcopy(report['findings'])
    report['applicabilityReviews'] = []
    environment = 'ci' if os.environ.get('GITHUB_ACTIONS') == 'true' else 'local'
    if report.get('observedEnvironment') != environment:
        return  # A different machine's evidence cannot grant this decision.
    try:
        rule = configuration(root)
        candidates = [f for f in report['findings'] if matches(f, environment, rule)]
        if not candidates:
            return
        proof = verify_environments(root, rule)
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as error:
        report['applicabilityReviewError'] = type(error).__name__
        return  # Original findings stay blocking.
    remaining = []
    for finding in report['findings']:
        if finding not in candidates:
            remaining.append(finding); continue
        try:
            advisory = fetch('advisories/' + finding['id'])
            msgpack = finding['id'] == MSGPACK_ID
            expected_hash = rule['msgpack']['advisorySHA256'] if msgpack else rule['advisories'][finding['id']]
            if (advisory.get('ghsa_id') != finding['id'] or advisory.get('withdrawn_at') is not None
                    or advisory_digest(advisory) != expected_hash):
                raise ValueError('Official advisory conditions changed')
            if msgpack and msgpack_patch_digest(fetch('repos/msgpack/msgpack-python/commits/' + MSGPACK_PATCH)) != rule['msgpack']['patchSHA256']:
                raise ValueError('Official patch evidence changed')
        except Exception:
            remaining.append(finding); continue
        report['applicabilityReviews'].append({
            'decision': target(finding['id'], rule)[2], 'status': 'not-affected',
            'reason': ('此精確 pip 封裝只有 msgpack 純 Python 實作，不含公告所修補的 C 解碼器；原版本命中保留。'
                       if msgpack else '此精確 pip 子集不包含公告指向的 setuptools 程式；原版本命中保留。'),
            'finding': copy.deepcopy(finding), 'environment': environment,
            'advisorySHA256': advisory_digest(advisory), 'evidence': proof,
            'ruleSHA256': hashlib.sha256((root / CONFIG).read_bytes()).hexdigest(),
            'grantsRiskException': False})
    report['findings'] = remaining
    coverage = report.get('toolchainCoverage')
    if coverage is not None and report['applicabilityReviews']:
        coverage['rawFindings'] = copy.deepcopy(coverage['findings'])
        excluded = {(r['finding']['id'], r['finding']['component'], r['finding']['version']) for r in report['applicabilityReviews']}
        coverage['findings'] = [f for f in coverage['findings'] if not (
            len(f.get('versions', [])) == 1 and (f.get('id'), f.get('component'), f['versions'][0]) in excluded
            and f.get('ecosystem') == 'PyPI'
            and set(f.get('origins', [])) == ORIGINS)]
        coverage['blocking'] = (coverage.get('checksComplete') is not True or any(
            f.get('status') == 'needs-review' or f.get('severity') not in ('low', 'info')
            for f in coverage['findings']))


def validate_envelope(report):
    if 'applicabilityReviews' not in report and 'rawFindings' not in report:
        return  # Existing report format without any exclusions.
    reviews = report.get('applicabilityReviews'); raw = report.get('rawFindings')
    if not isinstance(reviews, list) or not isinstance(raw, list) or len(reviews) > 4:
        raise ValueError('Missing raw applicability evidence')
    ids = set()
    for row in reviews:
        finding = row.get('finding', {})
        if (finding.get('id') not in IDS | {MSGPACK_ID} or finding['id'] in ids
                or row.get('decision') != ('pip-msgpack-pure-python' if finding['id'] == MSGPACK_ID else 'pip-setuptools-subset')
                or row.get('status') != 'not-affected'
                or row.get('grantsRiskException') is not False
                or not isinstance(row.get('evidence'), dict)):
            raise ValueError('Unrecognized applicability decision')
        ids.add(finding['id'])
    original = [digest(f) for f in raw]
    partition = ([digest(f) for f in report['findings']] + [digest(r['finding']) for r in reviews]
                 + [digest(r['finding']) for r in report.get('supplierFixReviews', [])]
                 + [digest(r['finding']) for r in report.get('projectApplicabilityReviews', [])])
    if len(original) != len(set(original)) or sorted(original) != sorted(partition):
        raise ValueError('Raw version matches were removed or modified')


def revalidate(report, root, fetch):
    """Before publication, recompute exclusions from live evidence, not text flags."""
    validate_envelope(report)
    if not report.get('applicabilityReviews'):
        return
    fresh = {'findings': copy.deepcopy(report['rawFindings']),
             'observedEnvironment': report.get('observedEnvironment')}
    classify(fresh, root, fetch)
    if (digest(fresh['applicabilityReviews']) != digest(report['applicabilityReviews'])
            or sorted(map(digest, fresh['findings'])) != sorted(map(digest,
                report['findings'] + [r['finding'] for r in report.get('supplierFixReviews', [])]
                + [r['finding'] for r in report.get('projectApplicabilityReviews', [])]))):
        raise ValueError('Applicability evidence changed; preserve Issues and rescan')
