#!/usr/bin/env python3
"""Separate technical evidence from exact approval. GET-only; no installs or reruns."""
import argparse
import datetime as dt
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = 'crazy01100/myterm'
WORKFLOW = '.github/workflows/security-gate.yml'
TECHNICAL_JOB = 'Technical security validation'
ENVIRONMENT = 'policy-approval'
RECEIPT = 'security-technical-receipt.json'
SHA = re.compile('[a-f0-9]{40}')
HEX = re.compile('[a-f0-9]{64}')
MAX_AGE = 48 * 3600  # Same retained-evidence horizon as monitor health, not a risk exception.


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT/'scripts'/f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


review = load('security-source-review')


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def git(*args, root=ROOT):
    return subprocess.run(['git', *args], cwd=root, capture_output=True, text=True,
                          check=True, timeout=20).stdout.strip()


def api(endpoint, *, raw=False):
    return review.gh_read(ROOT, 'repos/'+REPOSITORY+'/'+endpoint, raw=raw)


def download(endpoint):
    return subprocess.run([str(ROOT/'scripts/project-gh.sh'), 'api', '--method', 'GET',
                           '--allow-escape-sequences', 'repos/'+REPOSITORY+'/'+endpoint],
                          capture_output=True, check=True, timeout=60).stdout


def positive(value):
    if not re.fullmatch('[1-9][0-9]*', str(value)):
        raise ValueError('Missing positive run identity')
    return int(value)


def context(env=None, *, root=ROOT, reader=api):
    env = os.environ if env is None else env
    if env.get('GITHUB_ACTIONS') != 'true' or env.get('GITHUB_REPOSITORY') != REPOSITORY:
        raise ValueError('Original repository CI context required')
    event = review.strict_json(Path(env['GITHUB_EVENT_PATH']).read_bytes())
    kind = env.get('GITHUB_EVENT_NAME')
    tested = git('rev-parse', 'HEAD', root=root)
    if not SHA.fullmatch(tested) or env.get('GITHUB_SHA') != tested or git('status', '--porcelain', root=root):
        raise ValueError('Clean matching checkout required')
    result = {'repository': REPOSITORY, 'event': kind, 'testedCommit': tested,
              'runId': positive(env.get('GITHUB_RUN_ID')),
              'currentAttempt': positive(env.get('GITHUB_RUN_ATTEMPT'))}
    if kind == 'pull_request':
        pr = event['pull_request']; number = pr['number']
        if env.get('GITHUB_REF') != f'refs/pull/{number}/merge':
            raise ValueError('PR merge ref required')
        identity = review.pr_identity(pr, number, pr['head']['sha'], pr['base']['sha'])
        current = reader(f'pulls/{number}')
        if review.pr_identity(current, number, identity['head'], identity['base']) != identity:
            raise ValueError('PR changed during verification')
        for commit in (identity['head'], identity['base']):
            git('merge-base', '--is-ancestor', commit, tested, root=root)
        result.update(pr=number, head=identity['head'], base=identity['base'])
    elif kind == 'push' and env.get('GITHUB_REF') == 'refs/heads/main':
        if event.get('after') != tested or not SHA.fullmatch(event.get('before', '')):
            raise ValueError('Invalid main push identity')
        result.update(pr=None, head=tested, base=event['before'])
    else:
        raise ValueError('Unsupported gate event')
    return result


def base_classifier(source):
    return review.base_classifier(source)


def required(ctx, *, root=ROOT):
    if ctx['event'] == 'push':
        return False
    predicate = base_classifier(git('show', ctx['base']+':scripts/security-source-review.py', root=root))
    raw = git('diff', '--no-renames', '--name-only', '-z', ctx['base'], ctx['head'], root=root)
    paths = raw.rstrip('\0').split('\0') if raw else []
    values = [predicate(path) for path in paths]
    if any(type(v) is not bool for v in values):
        raise ValueError('Unknown policy classification')
    return any(values)


def report_valid(report):
    if (report.get('scanStatus') != 'complete' or report.get('errors') != []
            or report.get('coverageErrors') != [] or report.get('coverageGaps') != []
            or report.get('packageMonitoring', {}).get('queriesComplete') is not True
            or report.get('toolchainCoverage', {}).get('checksComplete') is not True
            or report.get('gateEvaluation') != {'purpose': 'merge', 'blocking': False,
                                               'authorizesRelease': False, 'grantsRiskException': False}):
        raise ValueError('Technical scan is incomplete or blocking')
    stamp = dt.datetime.fromisoformat(report['checkedAt'])
    if stamp.tzinfo is None or not 0 <= (dt.datetime.now(dt.timezone.utc)-stamp).total_seconds() <= MAX_AGE:
        raise ValueError('Technical evidence expired; refresh required evidence')


def record(root=ROOT):
    ctx = context(root=root)
    raw = (root/'build/security-report.json').read_bytes()
    report = review.strict_json(raw); report_valid(report)
    source = (root/'build/security-source-review.json').read_bytes()
    policy = review.strict_json(source)
    if (policy.get('checkoutCommit') != ctx['testedCommit'] or policy.get('sourceVerified') is not True
            or policy.get('policySHA256') != sha((root/review.POLICY).read_bytes())):
        raise ValueError('Technical source identity differs')
    result = {**ctx, 'schemaVersion': 1, 'technicalAttempt': ctx['currentAttempt'],
              'policyRequired': required(ctx, root=root), 'reportSHA256': sha(raw),
              'sourceReviewSHA256': sha(source)}
    result.pop('currentAttempt')
    if result['policyRequired']:
        # Fail before scheduling the environment job: GitHub otherwise creates
        # an unconfigured environment automatically if it was deleted.
        environment_valid(api('environments/'+ENVIRONMENT), api('environments/'+ENVIRONMENT+'/deployment-branch-policies'))
    (root/'build'/RECEIPT).write_text(json.dumps(result, indent=2)+'\n')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as out:
        out.write('policy_required='+str(result['policyRequired']).lower()+'\n')
    return result


def artifact_content(blob, ctx):
    if len(blob) > 16*1024*1024:
        raise ValueError('Oversized evidence artifact')
    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        names = z.namelist()
        if len(names) != len(set(names)) or len(names) > 10 or sum(i.file_size for i in z.infolist()) > 32*1024*1024:
            raise ValueError('Invalid evidence archive')
        receipt = review.strict_json(z.read(RECEIPT))
        raw = z.read('security-report.json'); source = z.read('security-source-review.json')
    if receipt.get('schemaVersion') != 1 or type(receipt.get('policyRequired')) is not bool:
        raise ValueError('Invalid technical receipt')
    for field in ('repository', 'event', 'pr', 'head', 'base', 'testedCommit', 'runId'):
        if receipt.get(field) != ctx[field]:
            raise ValueError('Technical receipt belongs to another '+field)
    attempt = receipt.get('technicalAttempt')
    if type(attempt) is not int or not 1 <= attempt <= ctx['currentAttempt']:
        raise ValueError('Invalid technical attempt')
    if sha(raw) != receipt.get('reportSHA256') or sha(source) != receipt.get('sourceReviewSHA256'):
        raise ValueError('Technical receipt content mismatch')
    provenance = review.strict_json(source)
    if (provenance.get('checkoutCommit') != ctx['testedCommit'] or provenance.get('sourceVerified') is not True
            or provenance.get('policySHA256') != sha((ROOT/review.POLICY).read_bytes())):
        raise ValueError('Retained source policy differs')
    report = review.strict_json(raw); report_valid(report)
    return receipt


def audit_log_digest(raw):
    if len(raw) > 32*1024*1024:
        raise ValueError('Oversized technical log')
    # Fixture tests also print synthetic digests; only this real step counts.
    sections = re.split(r'##\[group\]Run ', raw.decode('utf-8'))
    sections = [s for s in sections if s.startswith('./scripts/project-python.sh scripts/security-audit.py --merge-gate ')]
    matches = re.findall(r'MYTERM_SECURITY_REPORT_SHA256=([a-f0-9]{64})', sections[0]) if len(sections) == 1 else []
    if len(matches) != 1:
        raise ValueError('Missing independent technical scan digest')
    return matches[0]


def evidence(ctx, reader=api, downloader=download):
    run = reader('actions/runs/'+str(ctx['runId']))
    if (run.get('head_sha') != ctx['head'] or run.get('event') != ctx['event']
            or run.get('path', '').split('@')[0] != WORKFLOW
            or run.get('head_repository', {}).get('full_name') != REPOSITORY
            or run.get('run_attempt') != ctx['currentAttempt']):
        raise ValueError('Workflow run identity mismatch')
    data = reader(f'actions/runs/{ctx["runId"]}/artifacts?per_page=100')
    if data.get('total_count') != len(data.get('artifacts', [])):
        raise ValueError('Incomplete artifact listing')
    rows = [a for a in data['artifacts'] if a.get('name') == 'security-check-report']
    release = load('security-release-policy')
    asset = release.latest_run(rows)
    if asset.get('expired') is not False or not 0 < asset.get('size_in_bytes', 0) <= 16*1024*1024:
        raise ValueError('Missing retained technical artifact')
    blob = downloader(f'actions/artifacts/{positive(asset["id"])}/zip')
    if asset.get('digest') != 'sha256:'+sha(blob):
        raise ValueError('Artifact differs from GitHub digest')
    receipt = artifact_content(blob, ctx)
    jobs = reader(f'actions/runs/{ctx["runId"]}/attempts/{receipt["technicalAttempt"]}/jobs?per_page=100')
    if jobs.get('total_count') != len(jobs.get('jobs', [])):
        raise ValueError('Incomplete technical job listing')
    matches = [j for j in jobs['jobs'] if j.get('name') == TECHNICAL_JOB]
    if len(matches) != 1 or matches[0].get('status') != 'completed' or matches[0].get('conclusion') != 'success':
        raise ValueError('Technical job has not succeeded')
    job = matches[0]
    if audit_log_digest(downloader(f'actions/jobs/{positive(job["id"])}/logs')) != receipt['reportSHA256']:
        raise ValueError('Artifact differs from independent technical log')
    receipt.update(artifactId=asset['id'], technicalJobId=job['id'])
    return receipt


def environment_valid(data, branches):
    rules = data.get('protection_rules', [])
    reviewers = [r for r in rules if r.get('type') == 'required_reviewers']
    if (data.get('name') != ENVIRONMENT or data.get('can_admins_bypass') is not False
            or len(reviewers) != 1 or reviewers[0].get('prevent_self_review') is not False
            or reviewers[0].get('reviewers') is None
            or len(reviewers[0]['reviewers']) != 1
            or reviewers[0]['reviewers'][0].get('type') != 'User'
            or not review.is_maintainer(reviewers[0]['reviewers'][0].get('reviewer'))
            or any(r.get('type') not in ('required_reviewers', 'branch_policy') for r in rules)
            or data.get('deployment_branch_policy') != {'protected_branches': False, 'custom_branch_policies': True}
            or branches.get('total_count') != 1
            or len(branches.get('branch_policies', [])) != 1
            or branches['branch_policies'][0].get('name') != 'refs/pull/*/merge'
            or branches['branch_policies'][0].get('type') != 'branch'):
        raise ValueError('Policy approval environment is not protected as reviewed')


def approval(ctx):
    environment_valid(api('environments/'+ENVIRONMENT), api('environments/'+ENVIRONMENT+'/deployment-branch-policies'))
    policy = review.read_json(ROOT/review.POLICY)
    return review.inspect_pr_review(ROOT, policy['decision'], ctx['pr'], ctx['head'], ctx['base'])


def aggregate(technical, policy, needs_approval):
    if technical != 'success' or type(needs_approval) is not bool:
        raise ValueError('Technical validation did not succeed')
    if policy != ('success' if needs_approval else 'skipped'):
        raise ValueError('Policy approval result is missing, failed or unexpectedly skipped')


def codeql(ctx, reader=api):
    if ctx['event'] != 'pull_request':
        return {}  # Main CodeQL remains an independent required post-merge verification.
    release = load('security-release-policy')
    ref = f'refs/pull/{ctx["pr"]}/head'
    rows = reader('code-scanning/analyses?ref='+ref.replace('/', '%2F')+'&per_page=100')
    analyses = release.require_analyses(rows, ctx['head'], ref=ref)
    for identifier in analyses.values():
        release.validate_sarif(release.sarif_result(identifier, ROOT))
    return analyses


def verify(mode, env=None):
    env = os.environ if env is None else env
    ctx = context(env); needs_approval = required(ctx)
    if mode == 'approve' and not needs_approval:
        raise ValueError('Unexpected policy approval job')
    if mode == 'finish':
        aggregate(env.get('TECHNICAL_RESULT'), env.get('POLICY_RESULT'), needs_approval)
    receipt = evidence(ctx)
    if receipt['policyRequired'] != needs_approval:
        raise ValueError('Technical classification differs from trusted base')
    reviewed = approval(ctx) if needs_approval else None
    # Policy approval is requested only after CodeQL completes. Ordinary PRs
    # have no human waiting stage, so their independent CodeQL remains required
    # by the pre-merge --pr-review verify command, without a premature red job.
    analyses = codeql(ctx) if mode == 'finish' and needs_approval else {}
    if context(env) != ctx or required(ctx) != needs_approval:
        raise ValueError('PR changed before final result')
    if needs_approval and approval(ctx) != reviewed:
        raise ValueError('Review changed before final result')
    return {'technicalEvidence': receipt, 'prReview': reviewed, 'analyses': analyses,
            'mergeAuthorized': False, 'remainingChecks': 'Re-read current PR, review and unresolved threads before exact-head merge'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('record', 'approve', 'finish'))
    args = parser.parse_args()
    try:
        result = record() if args.mode == 'record' else verify(args.mode)
        print(json.dumps(result))
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as out:
                out.write('## '+('Technical evidence saved' if args.mode == 'record' else 'Exact evidence verified')+'\n\n')
                out.write('```json\n'+json.dumps(result, indent=2)+'\n```\n')
        return 0
    except (ValueError, KeyError, TypeError, OSError, SyntaxError, NameError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print('Security gate evidence unavailable: '+str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
