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
REPOSITORY = 'crazy01100/myterm'
MAINTAINER = {'login': 'crazy01100', 'id': 43394184, 'type': 'User'}
REVIEW_MARKER = 'MYTERM-CONDITIONAL-REVIEW-V1'
RETIREMENT_STATEMENT = ('I approve retirement of the specified Issue #43 conditional acceptance '
                        'because the official advisory was withdrawn. This is not a package fix. '
                        'Close Issue #43 only after main verification. All security checks must still pass.')
RETIREMENT_FILES = {'scripts/security-conditional-risk.py', 'scripts/security-audit.py',
                    'scripts/security-test-profile.py', 'scripts/sync-security-issues.py',
                    'scripts/firebase-command-policy.py', 'scripts/firebase-tools.sh',
                    '.github/workflows/security-gate.yml', '.github/workflows/security-checks.yml'}
REVIEW_STATEMENT = ('I accept the specified Issue #43 baseline, allowed uses and residual risk. '
                    'Keep Issue #43 open. All security checks must still pass.')


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


def withdrawal_snapshot(advisory):
    """Reviewed official withdrawal, never absence from a feed or a patch claim."""
    fields = ('ghsa_id', 'cve_id', 'html_url', 'summary', 'description', 'severity',
              'withdrawn_at', 'vulnerabilities')
    if not isinstance(advisory, dict) or any(k not in advisory for k in fields):
        raise ValueError('Incomplete withdrawal metadata')
    if (advisory['ghsa_id'] != IDENTITY['id'] or advisory['cve_id'] != 'CVE-2026-93687'
            or advisory['html_url'] != 'https://github.com/advisories/' + IDENTITY['id']):
        raise ValueError('Withdrawal identity mismatch')
    withdrawn = dt.datetime.fromisoformat(advisory['withdrawn_at'] or '')
    if withdrawn.tzinfo is None or withdrawn > dt.datetime.now(dt.timezone.utc):
        raise ValueError('Invalid withdrawal date')
    if not isinstance(advisory['description'], str) or not advisory['description'].strip():
        raise ValueError('Missing withdrawal explanation')
    rows = advisory['vulnerabilities']
    if not isinstance(rows, list) or not rows or any(
            row.get('package') != {'ecosystem': 'npm', 'name': 'braces'} for row in rows):
        raise ValueError('Withdrawal package mismatch')
    return {k: advisory[k] for k in fields}


def retirement_sources(root, decision):
    files = decision['retirement']['sourceFiles']
    if not isinstance(files, dict) or set(files) != RETIREMENT_FILES:
        raise ValueError('Incomplete retirement enforcement sources')
    for name, expected in files.items():
        if not isinstance(expected, str) or not re.fullmatch('[a-f0-9]{64}', expected):
            raise ValueError('Invalid retirement source fingerprint')
        if file_hash(root, name) != expected:
            raise ValueError('Retirement enforcement source changed: ' + name)
    return digest(files)


def evaluate_retirement(root, decision, result, fetch, now):
    retirement = decision['retirement']
    approved = dt.datetime.fromisoformat(retirement['approvedAt'])
    if (retirement.get('reason') != 'official-advisory-withdrawn'
            or retirement.get('approvedBy') != 'project maintainer'
            or approved.tzinfo is None or approved > now
            or not re.fullmatch('[a-f0-9]{64}', retirement.get('proposalSHA256', ''))):
        raise ValueError('Missing or invalid retirement approval')
    source = retirement_sources(root, decision)
    evidence = verify_ci_baseline(root, decision)
    advisory = withdrawal_snapshot(fetch(ADVISORY_URL))
    if (advisory['withdrawn_at'] != retirement['withdrawnAt']
            or digest(advisory) != retirement['advisoryDigest']):
        raise ValueError('Official withdrawal changed; review required')
    if retirement_sources(root, decision) != source:
        raise ValueError('Retirement sources changed during review')
    if load_policy(root) != decision:
        raise ValueError('Retirement policy changed during review')
    if evidence is not None:
        if verify_ci_baseline(root, decision) != evidence:
            raise ValueError('PR review changed during retirement verification')
        result['prReview'] = evidence
    result.update(status='retired', accepted=False, retirementVerified=True,
                  sourceDigest=source, advisoryDigest=digest(advisory),
                  withdrawnAt=advisory['withdrawn_at'],
                  reason='官方公告已撤回；條件式接受已退役，普通安全門檻仍生效。')
    return result


def verified(result):
    return result.get('accepted') is True or (result.get('status') == 'retired'
                                            and result.get('retirementVerified') is True)


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


def strict_json(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('Duplicate review field')
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=pairs)


def is_maintainer(user):
    return (isinstance(user, dict) and type(user.get('id')) is int
            and all(user.get(k) == v for k, v in MAINTAINER.items()))


def gh_read(root, endpoint, *, raw=False, pages=False):
    """GET only. No review creation, check writing, rerun or merge capability."""
    args = ['gh', 'api', '--method', 'GET']
    if pages:
        args += ['--paginate', '--slurp']
    if raw:
        args += ['-H', 'Accept: application/vnd.github.raw+json']
    result = subprocess.run(args + [endpoint], cwd=root, capture_output=True,
                            timeout=25, check=True)
    return result.stdout if raw else strict_json(result.stdout)


def pr_identity(pr, number, head, base):
    if (type(number) is not int or number < 1
            or not isinstance(head, str) or not re.fullmatch('[a-f0-9]{40}', head)
            or not isinstance(base, str) or not re.fullmatch('[a-f0-9]{40}', base)):
        raise ValueError('Invalid exact PR reference')
    if (pr['number'] != number or pr['state'] != 'open' or pr['draft'] is not False
            or pr['base']['ref'] != 'main'
            or pr['base']['repo']['full_name'] != REPOSITORY
            or pr['head']['repo']['full_name'] != REPOSITORY
            or pr['head']['sha'] != head or pr['base']['sha'] != base):
        raise ValueError('PR must be open, ready, same-repository main and match exact head/base')
    user = pr['user']
    if not isinstance(user, dict) or type(user.get('id')) is not int or not user.get('login'):
        raise ValueError('Missing PR author identity')
    return {'number': number, 'head': head, 'base': base, 'author': user}


def review_document(identity, decision, policy_bytes, action=None):
    action = action or ('retire' if decision.get('state') == 'retired' else 'accept')
    expected_action = 'retire' if decision.get('state') == 'retired' else 'accept'
    if action not in (expected_action, 'revoke'):
        raise ValueError('Unknown review action')
    if (any(decision.get(k) != v for k, v in IDENTITY.items())
            or type(decision.get('revision')) is not int or decision['revision'] < 1):
        raise ValueError('Invalid review decision identity')
    return {'schemaVersion': 1, 'action': action, 'repository': REPOSITORY,
            'pr': identity['number'], 'head': identity['head'], 'base': identity['base'],
            'decisionId': IDENTITY['id'], 'revision': decision['revision'],
            'policySHA256': hashlib.sha256(policy_bytes).hexdigest(),
            'statement': (RETIREMENT_STATEMENT if action == 'retire' else REVIEW_STATEMENT
                          if action == 'accept' else 'I revoke this baseline acceptance.')}


def review_candidates(pages, *, self_authored=False):
    if not isinstance(pages, list) or not pages or any(not isinstance(page, list) for page in pages):
        raise ValueError('Incomplete review pages')
    candidates = []
    seen = set()
    for page in pages:
        for review in page:
            if not isinstance(review, dict) or type(review.get('id')) is not int or review['id'] <= 0:
                raise ValueError('Invalid review response')
            if review['id'] in seen:
                raise ValueError('Duplicated review page; retry fresh query')
            seen.add(review['id'])
            user = review.get('user')
            if (not isinstance(user, dict) or type(user.get('id')) is not int
                    or not isinstance(user.get('login'), str) or not user['login']
                    or user.get('type') not in ('User', 'Bot', 'Mannequin')):
                raise ValueError('Missing review author')
            if review.get('state') not in ('APPROVED', 'CHANGES_REQUESTED', 'DISMISSED', 'COMMENTED', 'PENDING'):
                raise ValueError('Unknown review state')
            # A renamed/deleted identity is not silently treated as someone else.
            if user.get('id') == MAINTAINER['id'] or user.get('login') == MAINTAINER['login']:
                if not is_maintainer(user):
                    raise ValueError('Maintainer identity mismatch')
                body = review.get('body') or ''
                if not isinstance(body, str):
                    raise ValueError('Invalid review body')
                if (review.get('state') in ('APPROVED', 'CHANGES_REQUESTED', 'DISMISSED')
                        or REVIEW_MARKER in body
                        or (self_authored and review.get('state') == 'COMMENTED')):
                    candidates.append(review)
    return candidates


def select_review(pages, identity, decision, policy_bytes):
    self_authored = is_maintainer(identity['author'])
    latest = max(review_candidates(pages, self_authored=self_authored),
                 key=lambda item: item['id'], default=None)
    if latest is None:
        raise ValueError('Changed baseline needs maintainer review on this exact PR head')
    submitted = dt.datetime.fromisoformat(latest.get('submitted_at') or '')
    if submitted.tzinfo is None or submitted > dt.datetime.now(dt.timezone.utc):
        raise ValueError('Review has not been validly submitted')
    if latest.get('commit_id') != identity['head']:
        raise ValueError('Maintainer review is stale')
    state = latest.get('state')
    if state == 'APPROVED' and not self_authored:
        mode = 'github-approved'
    elif state == 'COMMENTED' and self_authored:
        body = latest['body']
        if not body.startswith(REVIEW_MARKER + '\n') or len(body) > 8192:
            raise ValueError('Invalid explicit review format')
        actual = strict_json(body[len(REVIEW_MARKER) + 1:])
        expected = review_document(identity, decision, policy_bytes)
        # Canonical encoding distinguishes JSON booleans and integers, too.
        if digest(actual) != digest(expected):
            raise ValueError('Explicit review revoked, malformed or does not match current baseline')
        mode = 'maintainer-self-review'
    else:
        raise ValueError('Review is not a valid approval or has been withdrawn')
    return {'reviewId': latest['id'], 'mode': mode, 'submittedAt': latest['submitted_at'],
            'reviewerId': MAINTAINER['id'], 'head': identity['head'], 'base': identity['base'],
            'policySHA256': hashlib.sha256(policy_bytes).hexdigest()}


def inspect_pr_review(root, decision, number, head, base, *, template=False, action=None):
    # Validate untrusted CLI/event arguments before constructing API paths.
    if (type(number) is not int or number < 1
            or not isinstance(head, str) or not re.fullmatch('[a-f0-9]{40}', head)
            or not isinstance(base, str) or not re.fullmatch('[a-f0-9]{40}', base)):
        raise ValueError('Invalid exact PR reference')
    endpoint = f'repos/{REPOSITORY}/pulls/{number}'
    identity = pr_identity(gh_read(root, endpoint), number, head, base)
    policy_bytes = (root / POLICY).read_bytes()
    remote_bytes = gh_read(root, f'repos/{REPOSITORY}/contents/{POLICY}?ref={head}', raw=True)
    if policy_bytes != remote_bytes or strict_json(policy_bytes)['decision'] != decision:
        raise ValueError('Local policy is not the policy at the exact PR head')
    trusted = gh_read(root, f'repos/{REPOSITORY}/contents/{POLICY}?ref={base}', raw=True)
    baseline_changed = decision != strict_json(trusted)['decision']
    if template:
        if not is_maintainer(identity['author']):
            raise ValueError('Use native APPROVED review for another author')
        result = REVIEW_MARKER + '\n' + json.dumps(
            review_document(identity, decision, policy_bytes, action), ensure_ascii=False, indent=2)
    else:
        reviews = gh_read(root, endpoint + '/reviews?per_page=100', pages=True)
        # Even an unchanged baseline may have a new explicit revocation. When
        # changed, a qualifying review is mandatory; otherwise honour blockers.
        owner_decisions = review_candidates(reviews, self_authored=is_maintainer(identity['author']))
        result = (select_review(reviews, identity, decision, policy_bytes)
                  if baseline_changed or owner_decisions else {'mode': 'unchanged-reviewed-base'})
        if gh_read(root, endpoint + '/reviews?per_page=100', pages=True) != reviews:
            raise ValueError('Reviews changed during verification; retry fresh query')
    if pr_identity(gh_read(root, endpoint), number, head, base) != identity:
        raise ValueError('PR identity changed during verification')
    if (root / POLICY).read_bytes() != policy_bytes:
        raise ValueError('Local policy changed during verification')
    return result


def verify_ci_baseline(root, decision, environ=None):
    """Review evidence only; never a substitute for source/advisory verification."""
    env = os.environ if environ is None else environ
    if env.get('GITHUB_EVENT_NAME') != 'pull_request':
        return
    event = read_json(Path(env['GITHUB_EVENT_PATH']))['pull_request']
    number = event.get('number')
    identity = pr_identity(event, number, event['head'].get('sha'), event['base'].get('sha'))
    return inspect_pr_review(root, decision, number, identity['head'], identity['base'])


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
        if type(decision.get('revision')) is not int or decision['revision'] < 1:
            raise ValueError('Invalid decision revision')
        if decision.get('state') == 'retired':
            return evaluate_retirement(root, decision, result, fetch, now)
        if decision.get('state') not in ('pending', 'active'):
            raise ValueError('Conditional decision is inactive')
        if not decision.get('residualRisk') or not decision.get('allowedUses'):
            raise ValueError('Decision scope incomplete')
        if decision['state'] == 'active':
            accepted = dt.datetime.fromisoformat(decision['acceptedAt'])
            if accepted.tzinfo is None or accepted > now or decision.get('acceptedBy') != 'project maintainer':
                raise ValueError('Missing or invalid maintainer acceptance')
        if decision['state'] == 'active':
            evidence = verify_ci_baseline(root, decision)
            if evidence is not None:
                result['prReview'] = evidence
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
        if result.get('prReview') is not None and verify_ci_baseline(root, decision) != result['prReview']:
            raise ValueError('PR review changed during conditional verification')
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
    if not verified(result):
        report.setdefault('conditionalBlocks', []).append('Issue 43: ' + result['reason'])
        if result.get('unavailable'):
            report['errors'].append('Official conditional review unavailable')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--purpose', choices=PURPOSES)
    parser.add_argument('--task', help='Current task/build/run identifier; not an authorization flag')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--inspect-pending', action='store_true', help='Read-only draft inspection; never authorizes execution')
    parser.add_argument('--pr-review', choices=('template', 'verify'),
                        help='Read-only exact-commit review helper; never submits a review or merges')
    parser.add_argument('--pr', type=int)
    parser.add_argument('--expected-head')
    parser.add_argument('--expected-base')
    parser.add_argument('--review-action', choices=('accept', 'retire', 'revoke'))
    args = parser.parse_args(argv)
    if args.pr_review:
        if (args.purpose or args.task or args.output or args.inspect_pending
                or args.pr is None or not args.expected_head or not args.expected_base
                or (args.pr_review != 'template' and args.review_action is not None)):
            parser.error('Review helper requires only PR, expected head/base and optional template action')
    elif (not args.purpose or not args.task or not args.task.strip() or len(args.task) > 200
          or args.pr is not None or args.expected_head or args.expected_base or args.review_action is not None):
        parser.error('A purpose and concise task identifier are required; review flags cannot authorize work')
    try:
        decision = load_policy()
        if args.pr_review:
            evidence = inspect_pr_review(ROOT, decision, args.pr, args.expected_head, args.expected_base,
                                         template=args.pr_review == 'template', action=args.review_action)
            if args.pr_review == 'template':
                print(evidence)
                return 0  # Text only; not a submitted or accepted decision.
            result = evaluate(ROOT, decision)
            # Check again after official metadata reads; do not return a stale
            # approval if someone revoked it while those requests were running.
            if inspect_pr_review(ROOT, decision, args.pr, args.expected_head, args.expected_base) != evidence:
                raise ValueError('Review evidence changed during pre-merge check')
            print(json.dumps({'prReview': evidence, 'conditionalReview': result,
                              'mergeAuthorized': False,
                              'remainingChecks': 'Required CI, CodeQL, threads and exact-head merge preconditions'},
                             ensure_ascii=False, indent=2))
            return 0 if verified(result) else 1
        if decision['state'] == 'pending' and not args.inspect_pending:
            print('Issue 43 conditional policy pending approval; existing time-limited rules remain in force.')
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
        return 0 if verified(result) else 1
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        print('Conditional review unavailable: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
