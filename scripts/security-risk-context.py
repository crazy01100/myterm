#!/usr/bin/env python3
"""Public advisory metadata and evidence-bound impact assessments (no policy exemptions)."""
import hashlib
import json
from collections import deque
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
IMPACT_STATES = {'affected': '已確認受影響', 'not-affected': '已確認不受影響', 'needs-review': '待確認'}


def fixed_versions(finding, advisory, affected):
    """Match each installed version to this package's actual advisory range."""
    result = []
    for version in finding['version'].split(','):
        matches = []
        unknown = False
        for row in advisory.get('vulnerabilities', []):
            package = row.get('package', {})
            if package.get('ecosystem') != 'npm' or package.get('name') != finding['component']:
                continue
            match = affected(version, row.get('vulnerable_version_range'))
            unknown |= match is None
            if match is True:
                matches.append(row.get('first_patched_version'))
        if matches:
            result.append({'currentVersion': version, 'fixedVersions': sorted(set(v for v in matches if v)),
                           'status': 'available' if any(matches) else 'unavailable'})
        else:
            result.append({'currentVersion': version, 'fixedVersions': [],
                           'status': 'needs-review' if unknown else 'not-listed'})
    return result


def dependency_paths(packages, component, versions):
    """Representative shortest lockfile paths; not a function reachability claim."""
    queue = deque([('', [])]); seen = set(); found = []
    while queue:
        key, chain = queue.popleft()
        if key in seen: continue
        seen.add(key)
        entry = packages[key]
        name = key.rsplit('node_modules/', 1)[-1]
        if name == component and entry.get('version') in versions:
            found.append(' → '.join(chain))
        deps = {**entry.get('dependencies', {}), **entry.get('optionalDependencies', {})}
        if not key: deps.update(entry.get('devDependencies', {}))
        for dep in sorted(deps):
            parent = key
            while True:
                candidate = (parent + '/' if parent else '') + 'node_modules/' + dep
                if candidate in packages:
                    queue.append((candidate, chain + [dep + '@' + packages[candidate].get('version', '?')]))
                    break
                if not parent: break
                parent = parent.rsplit('/node_modules/', 1)[0] if '/node_modules/' in parent else ''
    return sorted(set(found))


def impact(finding, root=ROOT, historical=False):
    pending = {'status': 'needs-review'}
    path = root/'Config/Security/impact-assessments.json'
    if not path.exists(): return pending
    document = json.loads(path.read_text())
    if document.get('schemaVersion') != 1: raise ValueError('Unknown impact assessment schema')
    matches = [r for r in document['assessments'] if
               all(r.get(k) == finding.get(k) for k in ['id', 'component', 'scope']) and
               sorted(r['versions']) == sorted(finding['version'].split(','))]
    if not matches: return pending
    if len(matches) != 1: raise ValueError('Duplicate impact assessment')
    row = matches[0]
    if row['status'] not in IMPACT_STATES or not row.get('reason') or not row.get('inputs'):
        raise ValueError('Incomplete impact assessment')
    if not re.fullmatch('[a-f0-9]{40}', row['reviewedCommit']): raise ValueError('Invalid assessment commit')
    valid = True
    for name, expected in row['inputs'].items():
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts or not re.fullmatch('[a-f0-9]{64}', expected):
            raise ValueError('Invalid assessment input')
        if name not in ['package-lock.json','package.json','firebase.json'] and not name.startswith(('scripts/','Sources/','Config/Security/','node_modules/')):
            raise ValueError('Assessment input is outside the source boundary')
        source = root/relative
        if not source.resolve().is_relative_to(root.resolve()): raise ValueError('Assessment input escapes source root')
        if not source.is_file() or hashlib.sha256(source.read_bytes()).hexdigest() != expected: valid = False
    historical_match = historical and finding.get('observedAt') in row.get('historicalScanTimes', [])
    if not valid and not historical_match:
        return {'status': 'needs-review', 'reason': '相關來源或相依已變更，原評估待重新確認。'}
    # Historical findings retain an explicitly labelled review of their old source.
    result = {k: row[k] for k in ['status', 'reason', 'usage', 'reviewedCommit', 'reviewedAt', 'evidence']}
    result['historical'] = historical
    return result


def enrich(finding, fetch, affected, root=ROOT, historical=False, cache=None):
    result = dict(finding)
    cache = cache if cache is not None else {}
    if finding['scope'] == 'development' and re.fullmatch(r'GHSA-[a-z0-9-]+', finding['id']):
        identifier = finding['id']
        if identifier not in cache: cache[identifier] = fetch('advisories/' + identifier)
        advisory = cache[identifier]
        if advisory.get('ghsa_id') != identifier: raise ValueError('Advisory identity mismatch')
        result['patches'] = fixed_versions(finding, advisory, affected)
        packages = json.loads((root/'package-lock.json').read_text())['packages']
        paths = dependency_paths(packages, finding['component'], finding['version'].split(','))
        if paths: result['dependencyPaths'] = paths
    result['impact'] = impact(finding, root, historical)
    return result
