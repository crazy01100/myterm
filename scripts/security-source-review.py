#!/usr/bin/env python3
"""Version-controlled policy provenance and exact policy-change PR review. GET-only."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
POLICY='Config/Security/source-review.json'
REPOSITORY='crazy01100/myterm'
MAINTAINER={'login':'crazy01100','id':43394184,'type':'User'}
REVIEW_MARKER='MYTERM-POLICY-REVIEW-V2'
REVIEW_STATEMENT='I approve the security policy changes and exact PR head/base. This grants no vulnerability exception. All required security checks must still pass.'

def read_json(path):
    return strict_json(path.read_bytes())

def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'),
                                     ensure_ascii=False).encode()).hexdigest()

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
    args = [str(Path(__file__).resolve().parent/'project-gh.sh'), 'api', '--method', 'GET']
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
        raise ValueError('Changed source policy needs maintainer review on this exact PR head')
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
    baseline_changed = reviewed_base_changed(root, {**decision,'_reviewHead':head}, base)
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
        if baseline_changed:
            result=select_review(reviews,identity,decision,policy_bytes)
        else:
            # Ordinary PR comments do not introduce a policy-approval ritual.
            latest=max(owner_decisions,key=lambda r:r['id'],default=None)
            if latest and (latest['state'] in ('CHANGES_REQUESTED','DISMISSED') or
                    (REVIEW_MARKER in latest.get('body','') and '"revoke"' in latest['body'])):
                raise ValueError('Maintainer has blocked or revoked this PR')
            result={'mode':'unchanged-reviewed-base'}
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

def review_document(identity, decision, policy_bytes, action=None):
    action = action or 'approve-policy'
    if action not in ('approve-policy','revoke') or decision.get('id')!='security-monitoring':
        raise ValueError('Invalid source review identity/action')
    return {'schemaVersion':2,'action':action,'repository':REPOSITORY,'pr':identity['number'],
            'head':identity['head'],'base':identity['base'],'policyId':decision['id'],
            'policySHA256':hashlib.sha256(policy_bytes).hexdigest(),
            'statement':REVIEW_STATEMENT if action=='approve-policy' else 'I revoke this source policy approval.'}


# Mandatory policy-sensitive paths. Ordinary docs/tests/cursor records are not
# manual fingerprint revisions. Changing this classifier is itself protected.
def policy_sensitive(path):
    if path.startswith('.github/workflows/'):return True
    if path.startswith('Config/Security/'):
        return path not in ('Config/Security/vendor-notices.json','Config/Security/supplier-notice-cursor.json')
    return path.startswith(('scripts/security-','scripts/sync-security-',
                            'scripts/project-','scripts/setup-','scripts/python-',
                            'scripts/node-toolchain','scripts/firebase-')) or path in (
        'scripts/release.sh','scripts/prepare-release-build.sh','scripts/publish-release.sh','scripts/verify-signed-release.py',
        'scripts/cleanup-build-artifacts.sh','scripts/restore-security-monitor.py',
        'scripts/run-policy-tests.py')


def reviewed_base_changed(root, decision, base):
    tree=gh_read(root,f'repos/{REPOSITORY}/git/trees/{base}?recursive=1')
    if tree.get('truncated') or not isinstance(tree.get('tree'),list):
        raise ValueError('Incomplete base source tree')
    if not any(e.get('path')==POLICY for e in tree['tree']):
        migration=decision.get('migration',{})
        if migration.get('fromPolicy')!='Config/Security/conditional-acceptances.json' or not re.fullmatch('[a-f0-9]{64}',migration.get('previousPolicySHA256','')):
            raise ValueError('Initial policy migration needs explicit provenance')
        trusted=gh_read(root,f'repos/{REPOSITORY}/contents/{migration['fromPolicy']}?ref={base}',raw=True)
        if hashlib.sha256(trusted).hexdigest()!=migration['previousPolicySHA256']:
            raise ValueError('Initial policy migration base differs')
        return True
    # Compare both trees, including deletion/rename; never trust the new policy
    # document to decide whether its own change requires approval.
    head=decision.get('_reviewHead')
    if not re.fullmatch('[a-f0-9]{40}',head or ''):raise ValueError('Missing exact review head')
    current=gh_read(root,f'repos/{REPOSITORY}/git/trees/{head}?recursive=1')
    if current.get('truncated') or not isinstance(current.get('tree'),list):raise ValueError('Incomplete head source tree')
    project=lambda t:{e['path']:(e.get('sha'),e.get('mode')) for e in t if policy_sensitive(e['path'])}
    return project(tree['tree'])!=project(current['tree'])


def source_check(root=ROOT):
    """Verify policy shape and checkout provenance, not per-file human approval.

    Dirty local development is allowed. Remote side-effect writers must run on
    a clean original-repository default-branch checkout. PR CI is validation
    only; approval is a separate final check, never a precondition for tests.
    """
    raw=(root/POLICY).read_bytes();policy=strict_json(raw)
    if set(policy)!={'schemaVersion','decision'} or policy['schemaVersion']!=2:
        raise ValueError('Policy migration has not been applied')
    decision=policy['decision']
    required={'id':'security-monitoring','state':'version-controlled',
              'mode':'project-policy-review','operatingSystemMonitoring':False,
              'grantsRiskException':False,'review':'exact-head-base'}
    if any(type(decision.get(k)) is not type(v) or decision.get(k)!=v for k,v in required.items()):
        raise ValueError('Invalid project policy contract')
    def git(*args):
        return subprocess.run(['git',*args],cwd=root,capture_output=True,text=True,check=True,timeout=15).stdout.strip()
    commit=git('rev-parse','HEAD')
    if not re.fullmatch('[a-f0-9]{40}',commit):raise ValueError('Missing checkout commit')
    dirty=bool(git('status','--porcelain','--untracked-files=normal'))
    ci=os.environ.get('GITHUB_ACTIONS')=='true'
    event=os.environ.get('GITHUB_EVENT_NAME')
    if ci:
        if (os.environ.get('GITHUB_REPOSITORY')!=REPOSITORY or
                event not in ('pull_request','push','schedule','workflow_dispatch','release') or
                os.environ.get('GITHUB_SHA')!=commit or dirty):
            raise ValueError('CI policy provenance requires a clean matching checkout')
    if (root/POLICY).read_bytes()!=raw:raise ValueError('Policy changed during verification')
    return {'policyId':decision['id'],'mode':decision['mode'],'sourceVerified':True,
            'checkoutCommit':commit,'localChanges':dirty,'validationOnly':event=='pull_request',
            'publicationAuthorized':bool(ci and event in ('schedule','workflow_dispatch') and os.environ.get('GITHUB_REF')=='refs/heads/main'),
            'grantsRiskException':False,'policySHA256':hashlib.sha256(raw).hexdigest()}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--purpose',choices=('development','firebase','ci','monitor','release','publish','redeploy'))
    p.add_argument('--ci-review',action='store_true',help='Final exact PR policy approval check, independent of validation')
    p.add_argument('--task');p.add_argument('--output',type=Path)
    p.add_argument('--pr-review',choices=('template','verify'));p.add_argument('--pr',type=int)
    p.add_argument('--expected-head');p.add_argument('--expected-base')
    p.add_argument('--review-action',choices=('approve-policy','revoke'))
    args=p.parse_args()
    try:
        if args.ci_review:
            if os.environ.get('GITHUB_EVENT_NAME')!='pull_request':raise ValueError('PR context required')
            result=verify_ci_baseline(ROOT,read_json(ROOT/POLICY)['decision'])
        elif args.pr_review:
            if args.purpose or args.task or args.output or args.pr is None or not args.expected_head or not args.expected_base:
                p.error('Review requires only exact PR references and optional template action')
            decision=read_json(ROOT/POLICY)['decision']
            evidence=inspect_pr_review(ROOT,decision,args.pr,args.expected_head,args.expected_base,
                                       template=args.pr_review=='template',action=args.review_action)
            if args.pr_review=='template':print(evidence);return 0
            result=source_check()
            if inspect_pr_review(ROOT,decision,args.pr,args.expected_head,args.expected_base)!=evidence:
                raise ValueError('Review changed during verification')
            result.update(prReview=evidence,mergeAuthorized=False,remainingChecks='Required CI, CodeQL and unresolved threads')
        else:
            if not args.purpose or not args.task or not args.task.strip() or len(args.task)>200 or any((args.pr,args.expected_head,args.expected_base,args.review_action)):
                p.error('Purpose and task are required; review flags cannot authorize work')
            result=source_check();result.update(purpose=args.purpose,task=args.task)
        if args.output:
            args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps(result));return 0
    except (ValueError,KeyError,TypeError,OSError,subprocess.SubprocessError) as error:
        print('Source review unavailable: '+str(error),file=sys.stderr);return 1

if __name__=='__main__':raise SystemExit(main())
