#!/usr/bin/env python3
"""Exact node-gyp consumer evidence for one advisory; never execute patterns."""
import base64
import hashlib
import importlib.util
import io
import json
from pathlib import Path, PurePosixPath
import re
import tarfile

ID = 'GHSA-fc5q-39xc-vjpf'
DECISION = 'picomatch-fixed-build-patterns'
COMPONENT = 'picomatch'
SCOPES = {'development': 220}
REPO = 'crazy01100/myterm'
TRACKING_NAME = 'picomatch'
EVIDENCE = 'Config/Security/applicability/picomatch-build-patterns.json'
VERSIONS = {'project-npm': ['4.0.7'], 'project-npm-tool': ['4.0.4']}
CHAIN = ('firebase-tools@15.36.0 → superstatic@10.0.0 → re2@1.26.1 → '
         'node-gyp@13.0.2 → tinyglobby@0.2.17 → picomatch@4.0.7')
PACKAGES = {'node_modules/'+name: version for name, version in (
    ('firebase-tools', '15.36.0'), ('superstatic', '10.0.0'), ('re2', '1.26.1'),
    ('node-gyp', '13.0.2'), ('tinyglobby', '0.2.17'),
    ('tinyglobby/node_modules/fdir', '6.5.0'), ('tinyglobby/node_modules/picomatch', '4.0.7'))}
SOURCES = {'package.json', 'package-lock.json', 'Config/Security/node-tools.json',
    'scripts/project-node.sh', 'scripts/node-toolchain.py', 'scripts/firebase-tools.sh',
    'scripts/firebase-command-policy.py', 'scripts/verify-firebase-tools.cjs',
    '.github/workflows/security-gate.yml', '.github/workflows/security-checks.yml',
    '.github/workflows/deploy-update-site.yml'}
NPM_SOURCES = {'package.json', 'lib/commands/ci.js',
    'node_modules/@npmcli/arborist/lib/arborist/rebuild.js',
    'node_modules/@npmcli/run-script/lib/run-script-pkg.js',
    'node_modules/node-gyp/package.json', 'node_modules/node-gyp/lib/build.js',
    'node_modules/tinyglobby/package.json', 'node_modules/tinyglobby/dist/index.cjs',
    'node_modules/tinyglobby/dist/index.mjs',
    'node_modules/tinyglobby/node_modules/fdir/package.json',
    'node_modules/tinyglobby/node_modules/fdir/dist/index.cjs',
    'node_modules/tinyglobby/node_modules/picomatch/package.json'}
RESOLUTIONS = {
    'node_modules/firebase-tools': {'superstatic': 'node_modules/superstatic'},
    'node_modules/superstatic': {'re2': 'node_modules/re2'},
    'node_modules/re2': {'node-gyp': 'node_modules/node-gyp'},
    'node_modules/node-gyp': {'tinyglobby': 'node_modules/tinyglobby'},
    'node_modules/tinyglobby': {'picomatch': 'node_modules/tinyglobby/node_modules/picomatch',
                              'fdir': 'node_modules/tinyglobby/node_modules/fdir'},
    'node_modules/tinyglobby/node_modules/fdir': {'picomatch': 'node_modules/tinyglobby/node_modules/picomatch'},
    '.build/npm-runtime/node_modules/node-gyp': {'tinyglobby': '.build/npm-runtime/node_modules/tinyglobby'},
    '.build/npm-runtime/node_modules/tinyglobby': {
        'picomatch': '.build/npm-runtime/node_modules/tinyglobby/node_modules/picomatch',
        'fdir': '.build/npm-runtime/node_modules/tinyglobby/node_modules/fdir'},
    '.build/npm-runtime/node_modules/tinyglobby/node_modules/fdir': {
        'picomatch': '.build/npm-runtime/node_modules/tinyglobby/node_modules/picomatch'},
}
HEX = re.compile('[a-f0-9]{64}')


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name+'.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def digest(value):
    return sha(json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode())


def owned(root, relative):
    root = Path(root).resolve()
    path = root/relative
    if path.resolve() != path.absolute() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError('Redirected picomatch evidence')
    return path


def configuration(root, rule):
    raw = owned(root, EVIDENCE).read_bytes(); data = json.loads(raw)
    if (rule.get('id') != ID or rule.get('decision') != DECISION or rule.get('component') != COMPONENT
            or rule.get('scope') != 'development' or rule.get('originVersions') != VERSIONS
            or set(rule.get('origins', [])) != set(VERSIONS)
            or rule.get('evidenceFile') != EVIDENCE or rule.get('evidenceSHA256') != sha(raw)
            or data.get('schemaVersion') != 1 or data.get('decision') != DECISION
            or data.get('grantsRiskException') is not False
            or set(data.get('sourceFiles', {})) != SOURCES
            or set(data.get('npmSources', {})) != NPM_SOURCES
            or data.get('resolutions') != RESOLUTIONS
            or set(data.get('packages', {})) != set(PACKAGES)):
        raise ValueError('Unreviewed picomatch evidence scope')
    for name, expected in data['sourceFiles'].items():
        if not HEX.fullmatch(expected) or sha(owned(root, name).read_bytes()) != expected:
            raise ValueError('Picomatch consumer or workflow changed: '+name)
    return data


def archive_files(raw, integrity):
    if (len(raw) > 32*1024*1024 or not re.fullmatch(r'sha512-[A-Za-z0-9+/]{86}==', integrity)
            or 'sha512-'+base64.b64encode(hashlib.sha512(raw).digest()).decode() != integrity):
        raise ValueError('Official project package integrity differs')
    files = {}; total = 0
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as archive:
        for index, member in enumerate(archive):
            name = PurePosixPath(member.name)
            if (index > 20000 or name.is_absolute() or not name.parts or name.parts[0] != 'package'
                    or '..' in name.parts or '\\' in member.name or not (member.isfile() or member.isdir())):
                raise ValueError('Unsafe project source archive')
            if member.isdir(): continue
            total += member.size; relative = str(name.relative_to('package'))
            if total > 128*1024*1024 or relative in files or not relative:
                raise ValueError('Oversized or duplicate project source')
            files[relative] = archive.extractfile(member).read()
    return files


def package_files(root, relative, entry):
    integrity = entry['integrity']; encoded = integrity.removeprefix('sha512-')
    if not re.fullmatch(r'[A-Za-z0-9+/]{86}==', encoded): raise ValueError('Invalid package hash')
    key = base64.b64decode(encoded, validate=True).hex()
    cache = owned(root, '.npm-cache/_cacache/content-v2/sha512/'+key[:2]+'/'+key[2:4]+'/'+key[4:])
    if cache.stat().st_size > 32*1024*1024: raise ValueError('Oversized package cache')
    return archive_files(cache.read_bytes(), integrity)


def installed_files(directory):
    result = {}; total = 0
    def visit(path, prefix=''):
        nonlocal total
        for p in path.iterdir():
            if not prefix and p.name == 'node_modules': continue  # Independently resolved below.
            name = prefix+p.name
            if p.is_symlink(): raise ValueError('Redirected installed package source')
            if p.is_dir(): visit(p, name+'/')
            elif p.is_file():
                size = p.stat().st_size; total += size
                if len(result) >= 20000 or size > 32*1024*1024 or total > 128*1024*1024:
                    raise ValueError('Oversized installed package')
                result[name] = p.read_bytes()
            else: raise ValueError('Unexpected installed package entry')
    visit(directory)
    return result


def resolve(root, consumer, name):
    root = Path(root).resolve()
    path = owned(root, consumer)
    while path.is_relative_to(root):
        candidate = path/'node_modules'/name
        if candidate.exists() or candidate.is_symlink():
            return str(owned(root, str(candidate.relative_to(root))).relative_to(root))
        path = path.parent
    raise ValueError('Missing exact dependency resolution')


def verify(root, rule):
    data = configuration(root, rule)
    lock = json.loads(owned(root, 'package-lock.json').read_bytes())['packages']
    verified = {}
    for relative, version in PACKAGES.items():
        row = data['packages'][relative]; entry = lock.get(relative, {})
        if (entry != row['lockEntry'] or entry.get('version') != version
                or not entry.get('resolved', '').startswith('https://registry.npmjs.org/')):
            raise ValueError('Reviewed project dependency graph changed')
        files = package_files(root, relative, entry)
        if digest({n: sha(v) for n, v in files.items()}) != row['sourceDigest']:
            raise ValueError('Unreviewed official project package source')
        actual = installed_files(owned(root, relative))
        if set(actual) != set(files): raise ValueError('Installed package files differ')
        for name, raw in files.items():
            prepared = data['preparedSources'].get(relative+'/'+name)
            expected = prepared['prepared'] if prepared else sha(raw)
            if (prepared and prepared['upstream'] != sha(raw)) or sha(actual[name]) != expected:
                raise ValueError('Installed project consumer differs: '+relative+'/'+name)
        verified[relative] = {'version': version, 'integrity': entry['integrity'], 'sourceDigest': row['sourceDigest']}
    if set(data['preparedSources']) != {'node_modules/firebase-tools/lib/fsAsync.js',
                                       'node_modules/superstatic/lib/utils/patterns.js'}:
        raise ValueError('Unexpected prepared-source allowance')
    npm = load('node-toolchain'); npm.verify(root)
    if npm.policy(root) != data['npmPolicy']: raise ValueError('Reviewed npm changed')
    for name, expected in data['npmSources'].items():
        if sha(owned(root, '.build/npm-runtime/'+name).read_bytes()) != expected:
            raise ValueError('npm consumer source changed')
    for consumer, dependencies in data['resolutions'].items():
        for name, expected in dependencies.items():
            if resolve(root, consumer, name) != expected: raise ValueError('Dependency shadowed or moved')
    return {'case': DECISION, 'evidenceSHA256': rule['evidenceSHA256'],
            'projectPackages': verified, 'npmPolicy': data['npmPolicy'],
            'sourceFiles': data['sourceFiles'], 'npmSources': data['npmSources']}


def target(finding):
    return all(finding.get(k) == v for k, v in {'id': ID, 'component': COMPONENT, 'scope': 'development'}.items())


def covers(proof, finding, environment):
    observations = finding.get('environmentObservations', [])
    seen = {}
    for o in observations:
        if o.get('environment') != environment: return False
        seen.setdefault(o.get('origin'), set()).update(o.get('versions', []))
    return (target(finding) and target(proof) and environment in ('local', 'ci')
            and proof.get('decision') == DECISION and proof.get('originVersions') == VERSIONS
            and set(proof.get('origins', [])) == set(VERSIONS)
            and proof.get('status') == 'not-affected' and proof.get('grantsRiskException') is False
            and proof.get('environment') == environment
            and seen == {k: set(v) for k, v in VERSIONS.items()}
            and set(finding.get('dependencyPaths', [])) == set(VERSIONS) | {CHAIN}
            and {v.strip() for v in finding.get('version', '').split(',')} == {'4.0.4', '4.0.7'})


def filter_baseline(report, findings):
    """Called only after the audit validates every original collector/partition.

    The normal gate still revalidates live project evidence before returning a
    pass. An expanded tool proof alone cannot waive an original collector.
    """
    project = load('security-project-applicability'); project.validate_envelope(report)
    reviews = [r for r in report.get('projectApplicabilityReviews', [])
               if r['proof'].get('decision') == DECISION and covers(r['proof'], r['finding'], report.get('observedEnvironment'))]
    if len(reviews) != 1: return findings
    rows = [(r['collector'], f) for r in report['collectionEvidence']['collectors']
            if r['collector'] != 'expanded-toolchain' for f in r['findings'] if target(f)]
    if (len(rows) != 1 or rows[0][0] != 'npm-project' or rows[0][1].get('version') != '4.0.7'
            or reviews[0]['finding'].get('queryComplete') is not True): return findings
    return [f for f in findings if not (target(f) and digest(f) == digest(rows[0][1]))]


def owned_resolution(snapshot, number):
    r = snapshot.get('applicabilityResolution', {})
    return (number == 220 and target(snapshot.get('finding', {}))
            and r.get('decision') == DECISION and HEX.fullmatch(r.get('proofSHA256', '')) is not None)


def validate_envelope(report):
    load('security-project-applicability').validate_envelope(report)


def publication_state(report, root):
    project = load('security-project-applicability')
    old = [p for p in report.get('projectApplicabilityProofs', []) if p.get('decision') == DECISION]
    row = {'id': ID, 'component': COMPONENT, 'scope': 'development', 'status': 'needs-review'}
    fresh = None
    try:
        if (report.get('observedEnvironment') not in ('local', 'ci')
                or not set(VERSIONS) <= set(report.get('observedOrigins', []))):
            raise ValueError('Required picomatch origins were not observed')
        rule = next(r for r in project.configuration(root) if r['id'] == ID)
        fresh = project.verify(rule, root); fresh['environment'] = report['observedEnvironment']
        if any(target(f) and not covers(fresh, f, report['observedEnvironment']) for f in report.get('rawFindings', [])):
            raise ValueError('Observed picomatch scope or version changed')
        if len(old) != 1 or digest(old[0]) != digest(fresh):
            raise ValueError('Picomatch evidence changed after scan')
        row.update(status='not-affected', reason=rule['reason'])
    except Exception as error:
        detail = str(error) if type(error) is ValueError else type(error).__name__
        row['reason'] = 'picomatch目前用途證據失效或無法核對，恢復待審：'+detail
    changed = bool(old) and (fresh is None or digest(old[0]) != digest(fresh) or row['status'] != 'not-affected')
    return {'outcomes': [row]}, changed
