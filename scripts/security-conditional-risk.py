#!/usr/bin/env python3
"""Issue 43 policy checks only. Never import or execute npm packages.

No cached acceptance receipts: every invocation re-reads sources and official
metadata. Repository review is the authority for a decision, not this script.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
POLICY = 'Config/Security/conditional-acceptances.json'
IDENTITY = {'id': 'GHSA-vfj7-8cjw-p6xm', 'component': 'braces',
            'version': '3.0.3', 'scope': 'development'}
PURPOSES = ('development', 'firebase', 'ci', 'monitor', 'release', 'publish', 'redeploy')
ADVISORY_URL = 'https://api.github.com/advisories/' + IDENTITY['id']
REGISTRY_URL = 'https://registry.npmjs.org/braces'
CLI_URL = 'https://registry.npmjs.org/firebase-tools/latest'


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'),
                                     ensure_ascii=False).encode()).hexdigest()


def read_json(path):
    return json.loads(path.read_text())


def load_policy(root=ROOT):
    doc = read_json(root / POLICY)
    if not isinstance(doc, dict) or doc.get('schemaVersion') != 1 or set(doc) != {'schemaVersion', 'decision'}:
        raise ValueError('Unknown conditional policy schema')
    decision = doc['decision']
    if not isinstance(decision, dict) or any(decision.get(k) != v for k, v in IDENTITY.items()):
        raise ValueError('Conditional policy is restricted to Issue 43')
    if decision.get('state') not in ('pending', 'active', 'revoked', 'retired'):
        raise ValueError('Unknown conditional decision state')
    return decision


def fetch_json(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'MyTerm-policy-review',
                                                  'Accept': 'application/json'})
    with urllib.request.urlopen(request, timeout=20) as response:
        raw = response.read(8 * 1024 * 1024 + 1)
    if len(raw) > 8 * 1024 * 1024:
        raise ValueError('Official metadata exceeds size limit')
    return json.loads(raw)


def advisory_snapshot(advisory):
    fields = ('ghsa_id', 'summary', 'description', 'severity', 'withdrawn_at', 'vulnerabilities')
    if not isinstance(advisory, dict) or any(k not in advisory for k in fields):
        raise ValueError('Incomplete advisory')
    if advisory['ghsa_id'] != IDENTITY['id'] or advisory['withdrawn_at'] is not None:
        raise ValueError('Advisory changed or withdrawn; review required')
    rows = advisory['vulnerabilities']
    if not isinstance(rows, list) or not rows:
        raise ValueError('Missing vulnerability ranges')
    for row in rows:
        if row.get('package') != {'ecosystem': 'npm', 'name': 'braces'}:
            raise ValueError('Unexpected affected package')
        if 'first_patched_version' not in row or row['first_patched_version'] is not None:
            raise ValueError('Official patch available or patch data missing')
        if row.get('vulnerable_version_range') != '<= 3.0.3':
            raise ValueError('Affected range changed')
    return {k: advisory[k] for k in fields}


def registry_snapshot(registry):
    if not isinstance(registry, dict):
        raise ValueError('Incomplete npm metadata')
    versions = registry.get('versions')
    tags = registry.get('dist-tags')
    if not isinstance(versions, dict) or not versions or not isinstance(tags, dict):
        raise ValueError('Incomplete npm metadata')
    if tags.get('latest') != '3.0.3' or any(v not in versions for v in tags.values()):
        raise ValueError('Official version changed; review required')
    return {'versions': sorted(versions), 'dist-tags': tags}


def dependency_graph(packages):
    """All reachable predecessor edges of braces, not just one shortest path."""
    edges = set()
    seen = set()
    todo = ['']
    while todo:
        key = todo.pop()
        if key in seen:
            continue
        seen.add(key)
        row = packages[key]
        deps = {**row.get('dependencies', {}), **row.get('optionalDependencies', {})}
        if not key:
            deps.update(row.get('devDependencies', {}))
        for name in sorted(deps):
            parent = key
            while True:
                candidate = (parent + '/' if parent else '') + 'node_modules/' + name
                if candidate in packages:
                    edges.add((key, candidate)); todo.append(candidate); break
                if not parent:
                    break
                parent = parent.rsplit('/node_modules/', 1)[0] if '/node_modules/' in parent else ''
    targets = {key for key in seen if key.rsplit('node_modules/', 1)[-1] == 'braces'}
    if not targets:
        raise ValueError('braces removed; review resolution separately')
    ancestors = set(targets)
    while True:
        expanded = ancestors | {a for a, b in edges if b in ancestors}
        if expanded == ancestors:
            break
        ancestors = expanded
    return {'nodes': {key: packages[key].get('version') for key in sorted(ancestors)},
            'edges': [list(edge) for edge in sorted(edges) if edge[1] in ancestors]}


def file_hash(root, name):
    relative = Path(name)
    if relative.is_absolute() or '..' in relative.parts:
        raise ValueError('Invalid baseline path')
    path = root / relative
    if not path.resolve().is_relative_to(root.resolve()) or not path.is_file():
        raise ValueError('Baseline file missing or outside checkout: ' + name)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_local(root, decision):
    baseline = decision['baseline']
    hashes = baseline['files']
    required = {'package.json', 'package-lock.json', 'firebase.json', 'firestore.rules',
                'firestore.indexes.json', 'Package.swift', 'Package.resolved',
                'scripts/firebase-tools.sh', 'scripts/firebase-command-policy.py',
                'scripts/build-app.sh', 'scripts/package-app.sh',
                'scripts/security-conditional-risk.py'}
    if not required <= hashes.keys():
        raise ValueError('Incomplete source boundary')
    for name, expected in hashes.items():
        if not isinstance(expected, str) or not re.fullmatch('[a-f0-9]{64}', expected):
            raise ValueError('Invalid source fingerprint')
        if file_hash(root, name) != expected:
            raise ValueError('Source baseline changed: ' + name)
    packages = read_json(root / 'package-lock.json')['packages']
    graph = dependency_graph(packages)
    if graph != baseline['dependencyGraph']:
        raise ValueError('Dependency paths changed')
    for key, version in graph['nodes'].items():
        if key:
            installed = read_json(root / key / 'package.json')
            if installed.get('version') != version:
                raise ValueError('Installed package differs from reviewed graph')
    config = read_json(root / 'firebase.json')
    for row in config.get('emulators', {}).values():
        if isinstance(row, dict) and row.get('host', '127.0.0.1') not in ('127.0.0.1', 'localhost', '::1'):
            raise ValueError('Emulator is not restricted to loopback')
    firestore = config.get('firestore', {})
    for entry in firestore if isinstance(firestore, list) else [firestore]:
        value = entry.get('rules')
        if not isinstance(value, str) or not value:
            raise ValueError('Rules path missing')
        path = Path(os.path.normpath(str(root.absolute()) + '/' + value))
        if any('{' in item or '}' in item for item in (str(root.absolute()), value, str(path), str(path.resolve()))):
            raise ValueError('Rules path is outside reviewed restrictions')
        # Rules contents must be an explicitly reviewed in-checkout file.
        if not path.resolve().is_relative_to(root.resolve()):
            raise ValueError('Rules target outside reviewed checkout')
        if path.relative_to(root.absolute()).as_posix() not in hashes:
            raise ValueError('Rules target has no reviewed content fingerprint')
    return digest({'files': hashes, 'dependencyGraph': graph})


def verify_ci_baseline(root, decision, environ=None):
    """Unreviewed PR content cannot invent its own baseline/allowed scope.

    Activation of an already-reviewed pending baseline still requires the
    maintainer's normal PR review; this check does not authenticate a human.
    """
    env = os.environ if environ is None else environ
    if env.get('GITHUB_EVENT_NAME') != 'pull_request':
        return
    event = read_json(Path(env['GITHUB_EVENT_PATH']))['pull_request']
    base = event['base']; head = event['head']
    if base['repo']['full_name'] != 'crazy01100/myterm' or head['repo']['full_name'] != base['repo']['full_name']:
        raise ValueError('Unreviewed fork cannot use this maintainer decision')
    sha = base['sha']
    if not re.fullmatch('[a-f0-9]{40}', sha):
        raise ValueError('Invalid PR base identity')
    data = subprocess.run(['gh', 'api', 'repos/crazy01100/myterm/contents/' + POLICY + '?ref=' + sha,
                           '-H', 'Accept: application/vnd.github.raw+json'],
                          cwd=root, capture_output=True, text=True, timeout=25, check=True)
    trusted = json.loads(data.stdout)['decision']
    fields = tuple(IDENTITY) + ('revision', 'baseline', 'allowedUses', 'residualRisk')
    if any(decision.get(k) != trusted.get(k) for k in fields):
        number = event.get('number')
        head_sha = head.get('sha', '')
        if not isinstance(number, int) or not re.fullmatch('[a-f0-9]{40}', head_sha):
            raise ValueError('PR conditional baseline differs from reviewed base; maintainer review required')
        reviews = subprocess.run(['gh', 'api', '--paginate', '--slurp',
                                  f'repos/crazy01100/myterm/pulls/{number}/reviews'],
                                 cwd=root, capture_output=True, text=True, timeout=25, check=True)
        pages = json.loads(reviews.stdout)
        if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
            raise ValueError('Invalid maintainer review response')
        owner_reviews = [review for page in pages for review in page
                         if review.get('user', {}).get('login') == 'crazy01100'
                         and review.get('state') in ('APPROVED', 'CHANGES_REQUESTED', 'DISMISSED')]
        latest = max(owner_reviews, key=lambda review: review.get('id', 0), default={})
        if latest.get('state') != 'APPROVED' or latest.get('commit_id') != head_sha:
            raise ValueError('Changed baseline needs maintainer approval on this exact PR head')


def evaluate(root, decision, fetch=fetch_json, now=None):
    """Fresh, side-effect-free review. A pending draft can never authorize work."""
    now = now or dt.datetime.now(dt.timezone.utc)
    result = {'decisionId': 'issue-43', 'revision': decision.get('revision'),
              'state': decision.get('state'), 'status': 'needs-review',
              'checkedAt': now.isoformat(), 'accepted': False,
              'scope': '受審專案的 Firebase 開發工具；本機 Emulator／Firestore Rules 部署'}
    try:
        if any(decision.get(k) != v for k, v in IDENTITY.items()):
            raise ValueError('Decision identity mismatch')
        if decision.get('state') not in ('pending', 'active'):
            raise ValueError('Conditional decision is inactive')
        if not isinstance(decision.get('revision'), int) or decision['revision'] < 1:
            raise ValueError('Invalid decision revision')
        if not decision.get('residualRisk') or not decision.get('allowedUses'):
            raise ValueError('Decision scope incomplete')
        if decision['state'] == 'active':
            accepted = dt.datetime.fromisoformat(decision['acceptedAt'])
            if accepted.tzinfo is None or accepted > now or decision.get('acceptedBy') != 'project maintainer':
                raise ValueError('Missing or invalid maintainer acceptance')
        if decision['state'] == 'active':
            verify_ci_baseline(root, decision)
        local = verify_local(root, decision)
        try:
            advisory_data, registry_data, cli = fetch(ADVISORY_URL), fetch(REGISTRY_URL), fetch(CLI_URL)
        except (ValueError, TypeError, OSError) as error:
            raise OSError('Official metadata query failed') from error
        advisory = advisory_snapshot(advisory_data)
        registry = registry_snapshot(registry_data)
        if not isinstance(cli, dict) or not isinstance(cli.get('version'), str) or cli.get('dependencies', {}).get('chokidar') != decision['baseline']['upstreamChokidarRange']:
            raise ValueError('Latest official Firebase dependency changed; review required')
        if digest(advisory) != decision['baseline']['advisoryDigest']:
            raise ValueError('Advisory content changed; review required')
        if digest(registry) != decision['baseline']['registryDigest']:
            raise ValueError('npm publication metadata changed; review required')
        # Close the ordinary read/query interval; this is not a sandbox/TOCTOU proof.
        if verify_local(root, decision) != local:
            raise ValueError('Local sources changed during review')
        result.update(status='matched', sourceDigest=local, advisoryDigest=digest(advisory),
                      registryDigest=digest(registry), upstreamFirebaseVersion=cli['version'],
                      accepted=decision['state'] == 'active',
                      reason='限定條件符合；仍屬尚未修補、實際影響待確認的風險。')
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        result['reason'] = str(error)
        result['unavailable'] = isinstance(error, (OSError, subprocess.SubprocessError))
    return result


def attach(report, decision, result):
    for finding in report['findings']:
        if all(finding.get(k) == v for k, v in IDENTITY.items()):
            finding['conditionalAcceptance'] = result
            # Drafts leave existing time-limited policy untouched. Active/revoked
            # decisions cannot fall back to an older time-limited acceptance.
            if decision['state'] != 'pending':
                finding['acceptedRisk'] = result['accepted'] and not report['errors']
                finding.pop('exceptionExpiresAt', None)
                finding.pop('exceptionExpired', None)


def review_report(report, root=ROOT, fetch=fetch_json):
    decision = load_policy(root)
    if decision['state'] == 'pending':
        return  # Draft is not an acceptance and has no production effect.
    result = evaluate(root, decision, fetch)
    report['conditionalReviews'] = [result]
    attach(report, decision, result)
    # A disappearing finding must not silently close Issue 43 or pass this gate.
    # Removal/fix/withdrawal needs a separately reviewed retirement decision.
    if decision['state'] != 'retired' and not any(all(f.get(k) == v for k, v in IDENTITY.items()) for f in report['findings']):
        report['errors'].append('Issue 43 finding changed or disappeared; review retirement before proceeding')
    if decision['state'] != 'retired' and result['status'] != 'matched':
        report.setdefault('conditionalBlocks', []).append('Issue 43: ' + result['reason'])
        if result.get('unavailable'):
            report['errors'].append('Official conditional review unavailable')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--purpose', choices=PURPOSES, required=True)
    parser.add_argument('--task', required=True, help='Current task/build/run identifier; not an authorization flag')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--inspect-pending', action='store_true', help='Read-only draft inspection; never authorizes execution')
    args = parser.parse_args(argv)
    if not args.task.strip() or len(args.task) > 200:
        parser.error('A concise current task identifier is required')
    try:
        decision = load_policy()
        if decision['state'] == 'pending' and not args.inspect_pending:
            print('Issue 43 conditional policy pending approval; existing time-limited rules remain in force.')
            return 0
        if decision['state'] == 'retired' and not args.inspect_pending:
            print('Issue 43 conditional policy retired; normal security gates remain in force.')
            return 0
        result = evaluate(ROOT, decision)
        result.update(purpose=args.purpose, task=args.task)
        commit = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
        result['commit'] = commit
        result['checkoutDigest'] = digest(str(ROOT.resolve()))
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(result, ensure_ascii=False))
        return 0 if result['accepted'] else 1
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        print('Conditional review unavailable: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
