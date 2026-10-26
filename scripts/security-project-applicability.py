#!/usr/bin/env python3
"""Four reviewed platform/subset decisions; preserve raw matches and fail closed.

Reviewed source graphs are bound to exact official bytes, not inferred from a
missing binary string or a package version. They are not recomputed by executing
the inspected third-party packages. No dependency installation is performed.
"""
import base64
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
CONFIG = 'Config/Security/project-applicability.json'
TARGETS = {
    'PSF-2025-2': ('cpython-windows-only', 'CPython', 'development'),
    'GO-2026-5932': ('gh-openpgp-absent', 'golang.org/x/crypto', 'development'),
    'GHSA-f23m-r3pf-42rh': ('upload-lodash-subset', 'lodash', 'github-actions'),
    'GHSA-r5fr-rjxr-66jc': ('upload-lodash-subset', 'lodash', 'github-actions'),
}
HEX = re.compile('[a-f0-9]{64}')


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name+'.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                     separators=(',', ':')).encode()).hexdigest()


def configuration(root):
    policy = json.loads((root/CONFIG).read_text())
    rules = policy.get('rules', [])
    if (policy.get('schemaVersion') != 1 or policy.get('state') != 'approved'
            or policy.get('grantsRiskException') is not False or len(rules) != 4
            or {r.get('id') for r in rules} != set(TARGETS)):
        raise ValueError('Unreviewed project applicability scope')
    for rule in rules:
        if (tuple(rule.get(k) for k in ('decision', 'component', 'scope')) != TARGETS[rule['id']]
                or not HEX.fullmatch(rule.get('advisorySHA256', ''))
                or not rule.get('origins') or len(set(rule['origins'])) != len(rule['origins'])):
            raise ValueError('Invalid project applicability rule')
        expected = ({'python-runtime/cpython', 'security-tools/cpython'} if rule['id'] == 'PSF-2025-2'
                    else {'platform/project-gh'} if rule['id'] == 'GO-2026-5932' else None)
        if expected is not None and set(rule['origins']) != expected:
            raise ValueError('Applicability origin scope changed')
    return rules


def advisory_digest(record, kind):
    fields = (('ghsa_id', 'html_url', 'withdrawn_at', 'summary', 'description', 'vulnerabilities')
              if kind == 'ghsa' else ('id', 'details', 'aliases', 'affected', 'withdrawn'))
    return digest({key: record.get(key) for key in fields})


def fetch_advisory(rule, root):
    ident = rule['id']; reader = load('security-source-review')
    if ident.startswith('GHSA-'):
        return reader.gh_read(root, 'advisories/'+ident)
    if ident.startswith('PSF-'):
        value = reader.gh_read(root, 'repos/psf/advisory-database/contents/advisories/python/'+ident+'.json')
        return json.loads(base64.b64decode(value['content']))
    if ident != 'GO-2026-5932':
        raise ValueError('Unreviewed Go advisory source')
    url = 'https://vuln.go.dev/ID/GO-2026-5932.json'
    with urllib.request.urlopen(url, context=load('python-toolchain').https_context(root), timeout=30) as response:
        if response.url != url:
            raise ValueError('Go advisory redirected')
        raw = response.read(2*1024*1024+1)
    if len(raw) > 2*1024*1024:
        raise ValueError('Oversized Go advisory')
    return json.loads(raw)


def evidence_file(root, rule):
    names = {'gh-openpgp-absent': 'gh-openpgp.json', 'upload-lodash-subset': 'upload-lodash.json'}
    expected = 'Config/Security/applicability/'+names[rule['decision']]
    path = root/expected
    if rule.get('evidenceFile') != expected or path.is_symlink():
        raise ValueError('Unexpected applicability evidence source')
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != rule.get('evidenceSHA256'):
        raise ValueError('Reviewed subset/build graph changed')
    return json.loads(raw)


def python_platforms(root, rule):
    trust = load('python-toolchain'); policy = trust.configuration(root); result = []
    for role in ('python-runtime', 'security-tools'):
        executable = root/'.build'/role/'bin/python3'
        info = trust.inspect_environment(executable, root)
        trust.validate_current(info, policy, root, 'project-runtime' if role == 'python-runtime' else role)
        process = subprocess.run([str(executable), '-I', '-S', '-B', '-c',
            'import json,sys;print(json.dumps({"platform":sys.platform,"version":".".join(map(str,sys.version_info[:3]))}))'],
            capture_output=True, text=True, check=True, timeout=15)
        platform = json.loads(process.stdout)
        if platform.get('platform') not in ('darwin', 'linux') or platform.get('version') != info['python']:
            raise ValueError('Windows or unknown Python platform is not excluded')
        result.append({'origin': role+'/cpython', **platform})
    return {'interpreters': result}


def gh_subset(root, rule):
    runtime = load('project-gh-runtime'); binary = runtime.verify(root)
    policy, platform, asset = runtime.selected(root)
    graph = evidence_file(root, rule)
    if graph.get('kind') != 'reviewed-official-gh-build-graph' or policy['version'] != graph.get('version'):
        raise ValueError('Reviewed GitHub CLI version changed')
    entry = graph['platforms'][platform]; blob = binary.read_bytes()
    if hashlib.sha256(blob).hexdigest() != entry['binarySHA256']:
        raise ValueError('GitHub CLI differs from the reviewed build graph')
    info = load('go-build-inventory').parse(blob)
    versions = [m['version'] for m in info['modules'] if m['name'] == 'golang.org/x/crypto']
    paths = entry['packagePaths']
    if (info['compiler'] != entry['compiler'] or versions != [rule['version']]
            or len(paths) != entry['packageCount'] or len(paths) != len(set(paths))
            or entry.get('affectedPackagePresent') is not False
            or entry.get('moduleVersionsMatch') is not True or entry.get('customBuildTags') is not False
            or any(p == 'golang.org/x/crypto/openpgp' or p.startswith('golang.org/x/crypto/openpgp/') for p in paths)):
        raise ValueError('Affected OpenPGP package or different build conditions')
    return {'platform': platform, 'binarySHA256': entry['binarySHA256'], 'archiveSHA256': asset['sha256'],
            'sourceCommit': entry['sourceCommit'], 'compiler': info['compiler'],
            'packagePathsSHA256': digest(paths), 'evidenceSHA256': rule['evidenceSHA256']}


def action_subset(root, rule):
    row = rule['action']
    current = [x for x in json.loads((root/'Config/Security/action-bundles.json').read_text())['bundles']
               if x['repository'] == 'actions/upload-artifact']
    if current != [row] or rule['origins'] != ['action/actions/upload-artifact@'+row['revision']]:
        raise ValueError('Reviewed official Action identity changed')
    archive = root/row['cacheFile']
    if archive.is_symlink() or not archive.resolve().is_relative_to(root.resolve()/'.build'):
        raise ValueError('Unowned Action evidence')
    raw = archive.read_bytes()
    if hashlib.sha256(raw).hexdigest() != row['archiveSHA256']:
        raise ValueError('Official Action archive changed')
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as source:
        members = [x for x in source if x.name.endswith('/'+rule['entrypoint'])]
        if len(members) != 1 or not members[0].isfile():
            raise ValueError('Missing or ambiguous Action entrypoint')
        body = source.extractfile(members[0]).read()
    if hashlib.sha256(body).hexdigest() != rule['bundleSHA256']:
        raise ValueError('Reviewed Action bundle changed')
    evidence = evidence_file(root, rule)
    if (evidence.get('kind') != 'reviewed-official-action-subset'
            or evidence.get('bundleSHA256') != rule['bundleSHA256']
            or evidence.get('unresolvedDependencies') != [] or evidence.get('unmappedLodashCandidates') != []):
        raise ValueError('Incomplete lodash subset evidence')
    # Reviewed ambiguous aliases are forwarding modules targeting non-lodash code.
    aliases = {x['module'] for x in evidence['ambiguousReexports'] if x['targetLodashSource'] is None}
    if aliases != set(evidence['ambiguousIdentityCandidates']):
        raise ValueError('Unresolved lodash module identity')
    sources = {name for match in evidence['matches'] if match['module'] not in aliases for name in match['source']}
    affected = ({'package/unset.js', 'package/omit.js', 'package/_baseUnset.js'}
                if rule['id'] == 'GHSA-f23m-r3pf-42rh' else {'package/template.js'})
    if sources & affected or not sources:
        raise ValueError('Affected lodash implementation is included')
    return {'repository': row['repository'], 'revision': row['revision'],
            'archiveSHA256': row['archiveSHA256'], 'bundleSHA256': rule['bundleSHA256'],
            'evidenceSHA256': rule['evidenceSHA256'], 'sourceModules': len(sources)}


def verify(rule, root, fetch=None):
    record = (fetch or fetch_advisory)(rule, root)
    if (record.get('ghsa_id', record.get('id')) != rule['id'] or record.get('withdrawn_at') or record.get('withdrawn')
            or advisory_digest(record, rule['advisoryKind']) != rule['advisorySHA256']):
        raise ValueError('Official applicability conditions changed')
    proof = {'cpython-windows-only': python_platforms, 'gh-openpgp-absent': gh_subset,
             'upload-lodash-subset': action_subset}[rule['decision']](root, rule)
    return {'id': rule['id'], 'decision': rule['decision'], 'component': rule['component'],
            'scope': rule['scope'], 'origins': rule['origins'], 'version': rule.get('version'),
            'status': 'not-affected', 'reason': rule['reason'], 'evidence': proof,
            'advisorySHA256': rule['advisorySHA256'], 'grantsRiskException': False,
            'ruleSHA256': hashlib.sha256((root/CONFIG).read_bytes()).hexdigest()}


def covers(proof, finding, environment):
    observations = finding.get('environmentObservations', [])
    return (all(finding.get(k) == proof.get(k) for k in ('id', 'component', 'scope'))
            and set(finding.get('dependencyPaths', [])) == set(proof['origins'])
            and bool(observations) and {o.get('origin') for o in observations} == set(proof['origins'])
            and all(o.get('environment') == environment and o.get('versions')
                    and (proof.get('version') is None or set(o['versions']) == {proof['version']}) for o in observations)
            and (proof.get('version') is None or finding.get('version') == proof['version']))


def classify(report, root=ROOT, fetch=None, verifier=None):
    if 'projectApplicabilityProofs' in report or 'projectApplicabilityReviews' in report:
        raise ValueError('Project applicability requires a fresh scan')
    report['projectApplicabilityProofs'] = []; report['projectApplicabilityReviews'] = []
    environment = 'ci' if os.environ.get('GITHUB_ACTIONS') == 'true' else 'local'
    if report.get('observedEnvironment') != environment or 'toolchainCoverage' not in report:
        return
    origins = set(report.get('observedOrigins', []))
    for rule in configuration(root):
        if not set(rule['origins']) <= origins:
            continue
        try:
            proof = (verifier or verify)(rule, root, fetch)
            proof['environment'] = environment
            report['projectApplicabilityProofs'].append(proof)
            for finding in list(report['findings']):
                if finding.get('queryComplete') is True and covers(proof, finding, environment):
                    report['projectApplicabilityReviews'].append({'finding': copy.deepcopy(finding), 'proof': proof})
                    report['findings'].remove(finding)
        except Exception as error:
            report.setdefault('errors', []).append('Project applicability unavailable: '+rule['id']+' '+type(error).__name__
                                                  + (' ('+str(error)+')' if type(error) is ValueError else ''))
    coverage = report.get('toolchainCoverage')
    if coverage is not None and report['projectApplicabilityReviews']:
        coverage.setdefault('rawFindings', copy.deepcopy(coverage.get('findings', [])))
        excluded = report['projectApplicabilityReviews']
        coverage['findings'] = [f for f in coverage.get('findings', []) if not any(
            f.get('id') == r['finding']['id'] and f.get('component') == r['finding']['component']
            and set(f.get('origins', [])) == set(r['proof']['origins'])
            and f.get('versions') == [r['finding']['version']] for r in excluded)]
        coverage['blocking'] = (coverage.get('checksComplete') is not True or any(
            f.get('status') == 'needs-review' or f.get('severity') not in ('low', 'info') for f in coverage['findings']))


def validate_envelope(report):
    proofs = report.get('projectApplicabilityProofs', [])
    reviews = report.get('projectApplicabilityReviews', [])
    if not isinstance(proofs, list) or not isinstance(reviews, list) or len(proofs) > 4 or len(reviews) > 4:
        raise ValueError('Invalid project applicability envelope')
    seen = set()
    for p in proofs:
        if (p.get('id') not in TARGETS or p['id'] in seen
                or tuple(p.get(k) for k in ('decision', 'component', 'scope')) != TARGETS[p['id']]
                or p.get('status') != 'not-affected' or p.get('grantsRiskException') is not False
                or p.get('environment') != report.get('observedEnvironment') or not isinstance(p.get('evidence'), dict)
                or any(not HEX.fullmatch(p.get(k, '')) for k in ('ruleSHA256', 'advisorySHA256'))):
            raise ValueError('Unrecognized project applicability proof')
        seen.add(p['id'])
    for r in reviews:
        if r.get('proof') not in proofs or not covers(r['proof'], r.get('finding', {}), report.get('observedEnvironment')):
            raise ValueError('Project applicability does not cover the finding')


def revalidate(report, root=ROOT, fetch=None):
    validate_envelope(report)
    if not report.get('projectApplicabilityProofs') and not report.get('projectApplicabilityReviews'):
        return
    fresh = {'findings': copy.deepcopy(report['rawFindings']), 'observedEnvironment': report.get('observedEnvironment'),
             'observedOrigins': report.get('observedOrigins', []), 'toolchainCoverage': {}, 'errors': []}
    classify(fresh, root, fetch)
    if (fresh['errors'] or any(digest(fresh[k]) != digest(report.get(k, []))
                             for k in ('projectApplicabilityProofs', 'projectApplicabilityReviews'))):
        raise ValueError('Project applicability evidence changed; preserve Issues and rescan')


def previous_decision(report, finding):
    for proof in report.get('projectApplicabilityProofs', []):
        if covers(proof, finding, report.get('observedEnvironment')):
            return proof
    return None


def owned_resolution(snapshot):
    value = snapshot.get('applicabilityResolution', {})
    finding = snapshot.get('finding', {})
    return (finding.get('id') in TARGETS and value.get('decision') == TARGETS[finding['id']][0]
            and HEX.fullmatch(value.get('proofSHA256', '')) is not None)
