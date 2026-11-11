#!/usr/bin/env python3
"""Separate complete tool-version observations from project risk and publication.

No finding is removed, accepted, or declared inapplicable. Candidate status
never substitutes for provenance, source integrity, or mandatory stage checks.
"""
import copy
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
CONFIG = 'Config/Security/risk-triage.json'
FIELDS = ('id', 'component', 'scope')


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def identity(f):
    return tuple(f.get(k) for k in FIELDS)


def key(f):
    return digest(list(identity(f)))


def configuration(root=ROOT):
    path = root / CONFIG
    if path.is_symlink():
        raise ValueError('Redirected triage policy')
    data = json.loads(path.read_bytes())
    if (data.get('schemaVersion') != 1 or data.get('policy') != 'project-tool-candidates'
            or data.get('grantsRiskException') is not False
            or data.get('candidateCollector') != 'expanded-toolchain'):
        raise ValueError('Invalid tool triage policy')
    for field in ('retainIndividual', 'migrationIssues', 'projectRisks'):
        rows = data[field]
        if (not isinstance(rows, list) or len(rows) > 1000
                or len({identity(r) for r in rows}) != len(rows)
                or any(not all(isinstance(r.get(k), str) and r[k] for k in FIELDS) for r in rows)):
            raise ValueError('Invalid triage identities')
    if any(type(r.get('number')) is not int or r['number'] < 1 for r in data['migrationIssues']):
        raise ValueError('Invalid migration Issue')
    existing=json.loads((root/'Config/Security/release-decisions.json').read_bytes())['rules']
    if {identity(r) for r in data['retainIndividual']} != {identity(r) for r in existing}:
        raise ValueError('Existing individual release-risk tracking changed')
    for row in data['projectRisks']:
        if row.get('status') not in ('applicable', 'suspected-applicable', 'unresolved-critical') or not row.get('reason'):
            raise ValueError('Invalid concrete project risk')
    for n in data['preannouncements']:
        if (n.get('source') != 'node-blog' or n.get('runtime') != 'node'
                or not re.fullmatch(r'https://nodejs\.org/en/blog/vulnerability/[a-z0-9-]+', n.get('url', ''))
                or any(not re.fullmatch('[a-f0-9]{64}', n.get(k, '')) for k in ('id', 'contentSHA256'))
                or not re.fullmatch(r'24\.\d+\.\d+', n.get('runtimeVersion', ''))):
            raise ValueError('Invalid reviewed preannouncement')
    return data


def complete(report):
    return (report.get('scanStatus') == 'complete' and report.get('errors') == []
            and not report.get('coverageErrors') and not report.get('coverageGaps')
            and report.get('toolchainCoverage', {}).get('checksComplete') is True
            and report.get('packageMonitoring', {}).get('queriesComplete') is True
            and report.get('sourceReview', {}).get('sourceVerified') is True)


def build(report, root=ROOT):
    policy = configuration(root)
    protected = {identity(r) for r in policy['retainIndividual']}
    explicit = {identity(r): r for r in policy['projectRisks']}
    migration = {identity(r): r['number'] for r in policy['migrationIssues']}
    collectors = report.get('collectionEvidence', {}).get('collectors', [])
    expanded = [r for r in collectors if r.get('collector') == policy['candidateCollector']]
    baseline = {identity(f) for r in collectors if r.get('collector') != policy['candidateCollector']
                for f in r.get('findings', [])}
    eligible = (complete(report) and len(expanded) == 1 and expanded[0].get('status') == 'complete')
    expanded_matches = {identity(f): f for f in expanded[0]['findings']} if eligible else {}
    env = report.get('observedEnvironment')
    observed = set(report.get('observedOrigins', []))
    rows = []
    for index, finding in enumerate(report['findings']):
        ident = identity(finding)
        impact = finding.get('impact', {}).get('status')
        concrete = explicit.get(ident)
        row = {'findingIndex': index, 'key': key(finding), 'identity': list(ident),
               'disposition': 'individual', 'releaseEffect': 'existing-policy'}
        if concrete or impact in ('affected', 'applicable', 'suspected-applicable', 'unresolved-critical'):
            row.update(releaseEffect='block', reason=(concrete or {}).get('reason', 'Concrete project impact requires review'))
        elif (eligible and ident not in baseline and ident not in protected
                and finding.get('scope') in ('development', 'verification-tool', 'github-actions')
                and finding.get('matchBasis') == 'version-only'
                and expanded_matches.get(ident, {}).get('matchBasis') == 'version-only'
                and finding.get('queryComplete') is True):
            observations = finding.get('environmentObservations', [])
            paths = set(finding.get('dependencyPaths', []))
            if (env not in ('local', 'ci', 'deployment') or not observations or not paths or not paths <= observed
                    or {o.get('origin') for o in observations} != paths
                    or any(o.get('environment') != env or not o.get('versions') for o in observations)
                    or {v.strip() for v in finding['version'].split(',')} !=
                        {v for o in observations for v in o['versions']}):
                raise ValueError('Candidate environment/origin evidence is incomplete')
            row.update(disposition='candidate', releaseEffect='warn',
                       reason='版本命中；尚未建立受影響操作與正常專案用途的具體連結。不是已修補或不適用。')
            if ident in migration:
                row['originalIssue'] = migration[ident]
        rows.append(row)
    return {'schemaVersion': 1, 'policySHA256': digest(policy), 'findingDigest': digest(report['findings']),
            'rawFindingDigest': digest(report.get('rawFindings', report['findings'])),
            'checksComplete': bool(eligible), 'grantsRiskException': False, 'rows': rows,
            'counts': {'observed': len(rows), 'candidates': sum(r['disposition'] == 'candidate' for r in rows),
                       'individual': sum(r['disposition'] == 'individual' for r in rows),
                       'concreteBlocks': sum(r['releaseEffect'] == 'block' for r in rows)}}


def verify(report, root=ROOT):
    value = report.get('riskTriage')
    if value is None:
        return None  # Legacy evidence has no candidate/notice exemption.
    if value != build(report, root):
        raise ValueError('Triage does not match current findings, provenance or policy')
    return value


def candidates(report, root=ROOT):
    triage = verify(report, root)
    if triage is None:
        return []
    return [{**copy.deepcopy(row), 'finding': copy.deepcopy(report['findings'][row['findingIndex']])}
            for row in triage['rows'] if row['disposition'] == 'candidate']


def candidate_payload(report):
    """Canonical publication projection; no I/O, also used by receipt readers."""
    value=report.get('riskTriage')
    if value is None:return []
    if (value.get('schemaVersion')!=1 or value.get('grantsRiskException') is not False
            or value.get('findingDigest')!=digest(report['findings'])):
        raise ValueError('Candidate receipt finding identity differs')
    rows=[]
    for r in value['rows']:
        if r['disposition']!='candidate':continue
        f=report['findings'][r['findingIndex']]
        if r['key']!=key(f):raise ValueError('Candidate receipt key differs')
        rows.append({**{k:v for k,v in r.items() if k!='findingIndex'},'finding':f})
    return sorted(rows,key=lambda r:r['key'])


def preannouncement(notice, report, root=ROOT):
    # Only this reviewed content can remain a preannouncement. New details or
    # missing queries cannot inherit its treatment via title/keyword matching.
    if not complete(report) or report.get('vendorNotices', {}).get('checksComplete') is not True:
        return False
    for row in configuration(root)['preannouncements']:
        if all(notice.get(k) == row[k] for k in ('id', 'source', 'url', 'contentSHA256')):
            actual = json.loads((root/'Config/Security/node-tools.json').read_text())['nodeVersion']
            if actual != row['runtimeVersion']:
                raise ValueError('Preannouncement runtime changed')
            return True
    return False


def owned_transfer(snapshot):
    row = snapshot.get('candidateTransfer', {})
    return (row.get('kind') == 'candidate-monitoring' and type(row.get('aggregateIssue')) is int
            and row['aggregateIssue'] > 0 and row.get('key') == key(snapshot.get('finding', {})))


def require_saved(report, api, root=ROOT):
    """Read the bot-owned aggregate before any candidate is suppressed/closed."""
    wanted = candidates(report, root)
    if not wanted:
        return None
    prefix = '<!-- myterm-monitor-review:v1 -->'
    issues = [i for i in api.pages('issues?state=open&creator=github-actions%5Bbot%5D')
              if i.get('state') == 'open' and i.get('user', {}).get('login') == 'github-actions[bot]'
              and i.get('body', '').startswith(prefix) and 'pull_request' not in i]
    if len(issues) != 1:
        raise ValueError('Candidate aggregate has not been saved')
    issue = api.request('issues/'+str(issues[0]['number']))
    if (issue.get('user', {}).get('login') != 'github-actions[bot]' or issue.get('state') != 'open'
            or not issue.get('body', '').startswith(prefix)):
        raise ValueError('Candidate aggregate readback changed')
    import base64
    match = re.search(r'<!-- myterm-monitor-state:([A-Za-z0-9_=+-]+) -->', issue['body'])
    if not match or len(match[1]) > 900000:
        raise ValueError('Missing bounded candidate state')
    state = json.loads(base64.urlsafe_b64decode(match[1]))
    if (state.get('triagePolicySHA256')!=report['riskTriage']['policySHA256']
            or state.get('candidateDigest')!=digest(candidate_payload(report))):
        raise ValueError('Candidate aggregate publication identity differs')
    saved = {r['key']: r for r in state.get('candidates', [])}
    for row in wanted:
        stored = saved.get(row['key'])
        if stored is None or stored.get('finding') != row['finding'] or stored.get('reason') != row['reason']:
            raise ValueError('Candidate aggregate differs from this scan')
    return issue['number']
