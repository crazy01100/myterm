#!/usr/bin/env python3
"""Purpose-based release classification. No finding removal, expiry waiver or writes.

The audit calls this only on its freshly collected in-process report. Decisions
bind reviewed consumers and official bytes, not an App version or elapsed days.
A caller-provided JSON receipt is never authority to release.
"""
import datetime as dt
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CONFIG = 'Config/Security/release-decisions.json'
REPOSITORY = 'crazy01100/myterm'
STAGES = ('candidate', 'publish', 'deploy')
TARGETS = {
    'GHSA-35p6-xmwp-9g52': ('undici', 'diagnostic-transport-integrity'),
    'GHSA-8gc5-j5rx-235r': ('fast-xml-parser', 'tool-availability'),
    'GHSA-xjj6-f33q-929c': ('undici', 'tool-availability'),
    'GHSA-qrxm-fqhp-jwvm': ('undici', 'tool-availability'),
}
ADVISORY_FIELDS = ('ghsa_id', 'html_url', 'withdrawn_at', 'summary', 'description',
                   'vulnerabilities', 'severity', 'cvss', 'cwes')


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name+'.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def advisory_digest(record):
    return digest({k: record.get(k) for k in ADVISORY_FIELDS})


def owned(root, name):
    path = root/name
    if (Path(name).is_absolute() or '..' in Path(name).parts or path.is_symlink()
            or not path.is_file() or not path.resolve().is_relative_to(root.resolve())):
        raise ValueError('Release evidence source missing or redirected: '+name)
    return path


def policy(root):
    data = load('security-source-review').strict_json(owned(root, CONFIG).read_bytes())
    if (data.get('schemaVersion') != 1 or data.get('policy') != 'purpose-based-release'
            or data.get('repository') != REPOSITORY or data.get('preserveFindings') is not True
            or data.get('grantsRiskException') is not False or
            {r['id'] for r in data['rules']} != set(TARGETS) or len(data['rules']) != len(TARGETS)):
        raise ValueError('Invalid release classification policy')
    for r in data['rules']:
        if ((r.get('component'), r.get('classification')) != TARGETS[r['id']]
                or r.get('scope') != 'github-actions' or not r.get('originVersions')
                or not re.fullmatch('[a-f0-9]{64}', r.get('advisorySHA256', ''))):
            raise ValueError('Unreviewed release classification')
    return data


def verify_sources(root, data):
    files = data['sourceFiles']
    workflows = sorted(str(p.relative_to(root)) for p in (root/'.github/workflows').iterdir()
                       if p.suffix in ('.yml', '.yaml'))
    if workflows != data['workflows'] or not set(workflows) <= set(files):
        raise ValueError('Release workflow set changed')
    required = {'scripts/release.sh', 'scripts/prepare-release-build.sh', 'scripts/publish-release.sh',
                'scripts/verify-signed-release.py', 'scripts/prepare-pages-deployment.sh',
                'scripts/verify-public-update-site.sh', 'Config/Security/action-bundles.json',
                'Config/Security/node-tools.json', 'package-lock.json'}
    if not required <= set(files):
        raise ValueError('Missing reviewed release consumers')
    for name, expected in files.items():
        if not re.fullmatch('[a-f0-9]{64}', expected) or hashlib.sha256(owned(root, name).read_bytes()).hexdigest() != expected:
            raise ValueError('Reviewed release use changed: '+name)
    return digest(files)


def action_assets(root, data):
    inventory = load('security-toolchain-inventory')
    bundles = json.loads(owned(root, 'Config/Security/action-bundles.json').read_bytes())['bundles']
    result = {}
    for b in bundles:
        rows, proof = inventory.action_bundle(root, b['repository'], b['revision'])
        origin = 'action/'+b['repository']+'@'+b['revision']
        result[origin] = {name: sorted({r['version'] for r in rows if r['name'] == name})
                          for name in ('undici', 'fast-xml-parser')}
    for rule in data['rules']:
        if any(result.get(origin, {}).get(rule['component']) != versions
               for origin, versions in rule['originVersions'].items()):
            raise ValueError('Reviewed Action package/asset identity changed')
    return result


def context(stage, version, build=None, assets=None, *, root=ROOT):
    if stage not in STAGES or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:[.-][0-9A-Za-z]+)*', version or ''):
        raise ValueError('Missing or invalid release purpose/version')
    if build is not None and not re.fullmatch('[1-9][0-9]*', build):
        raise ValueError('Invalid release Build')
    def git(*args):
        return subprocess.run(['git', *args], cwd=root, capture_output=True, text=True,
                              check=True, timeout=20).stdout.strip()
    source = load('security-source-review').source_check(root)
    if source['localChanges'] or source.get('validationOnly'):
        raise ValueError('Release requires a clean non-PR checkout')
    if git('remote', 'get-url', 'origin') not in (
            'git@github.com:'+REPOSITORY+'.git', 'https://github.com/'+REPOSITORY+'.git',
            'https://github.com/'+REPOSITORY):
        raise ValueError('Unexpected release repository')
    sha = source['checkoutCommit']
    if stage in ('candidate', 'publish'):
        if os.environ.get('GITHUB_ACTIONS') == 'true' or git('branch', '--show-current') != 'main' or git('rev-parse', 'origin/main') != sha or build is None:
            raise ValueError('Local release requires matching main and Build')
        release_sha = sha
    else:
        event = os.environ.get('GITHUB_EVENT_NAME')
        expected_ref = 'refs/tags/v'+version if event == 'release' else 'refs/heads/main'
        if (os.environ.get('GITHUB_ACTIONS') != 'true' or
                event not in ('release', 'workflow_dispatch') or
                os.environ.get('GITHUB_REF') != expected_ref or
                os.environ.get('MYTERM_RELEASE_TAG') != 'v'+version):
            raise ValueError('Untrusted deployment context')
        release_sha = git('rev-list', '-n', '1', 'refs/tags/v'+version)
        git('merge-base', '--is-ancestor', release_sha, sha)
    result = {'stage': stage, 'version': version, 'build': build, 'checkoutCommit': sha,
              'releaseCommit': release_sha, 'observedEnvironment': 'ci' if stage == 'deploy' else 'local'}
    if stage in ('publish', 'deploy'):
        if assets is None:
            raise ValueError('Verified release assets are required at this stage')
        command = [str(root/'scripts/security-python.sh'), str(root/'scripts/verify-signed-release.py'),
                   '--assets', str(assets), '--public-key-file', str(root/'Config/Release/SparklePublicKey.txt'),
                   '--base-url', 'https://mtus.lieniapp.work', '--version', version, '--commit', release_sha]
        if build is not None: command += ['--build', build]
        verified = json.loads(subprocess.run(command, cwd=root, check=True, capture_output=True, timeout=60).stdout)
        result['assetVerification'] = 'verified-signatures-and-release-identity'
        # Consume the verifier's authenticated bytes, not a second manifest read.
        result['build'] = verified['build']
        result['deliveryInventory'] = verified['dependencies']
        result['assetHashes'] = verified['hashes']
    return result


def classify(report, ctx, *, root=ROOT, reader=None):
    """Return a separate decision; never mutate report/findings/acceptedRisk."""
    reader = reader or (lambda path: load('security-source-review').gh_read(root, path))
    data = policy(root)
    source_digest = verify_sources(root, data)
    action_assets(root, data)
    now = dt.datetime.now(dt.timezone.utc)
    stamp = dt.datetime.fromisoformat(report['checkedAt'])
    if (ctx.get('stage') not in STAGES or stamp.tzinfo is None or
            not 0 <= (now-stamp).total_seconds() <= 3600 or report.get('scanStatus') != 'complete'
            or report.get('sourceReview', {}).get('checkoutCommit') != ctx['checkoutCommit']
            or report.get('observedEnvironment') != ctx['observedEnvironment']
            or report.get('toolchainCoverage', {}).get('checksComplete') is not True
            or report.get('packageMonitoring', {}).get('queriesComplete') is not True
            or report.get('vendorNotices', {}).get('checksComplete') is not True):
        raise ValueError('Release requires fresh matching scan and complete queries')
    if ctx['stage'] in ('publish', 'deploy') and ctx.get('assetVerification') != 'verified-signatures-and-release-identity':
        raise ValueError('Missing verified release assets')
    if ctx['stage'] in ('publish', 'deploy') and (
            not ctx.get('deliveryInventory') or report.get('deliveryInventoryDigest') != digest(ctx['deliveryInventory'])):
        raise ValueError('The actual signed delivery inventory was not scanned')
    decisions = []; notices = []; unresolved_notices = []
    rules = {r['id']: r for r in data['rules']}
    for index, finding in enumerate(report['findings']):
        rule = rules.get(finding.get('id'))
        if rule is None or any(finding.get(k) != rule[k] for k in ('component', 'scope')):
            continue
        if finding.get('queryComplete') is not True:
            raise ValueError('Incomplete release risk query')
        observations = finding.get('environmentObservations', [])
        paths = finding.get('dependencyPaths', [])
        if (not observations or len(paths) != len(set(paths)) or
                set(paths) != {o['origin'] for o in observations} or
                len(observations) != len(paths) or
                any(o.get('environment') != ctx['observedEnvironment'] or
                    rule['originVersions'].get(o.get('origin')) != o.get('versions') for o in observations) or
                set(finding['version'].split(', ')) != {v for o in observations for v in o['versions']}):
            raise ValueError('Unreviewed risk origin/version/environment')
        advisory = reader('advisories/'+rule['id'])
        if advisory.get('withdrawn_at') or advisory_digest(advisory) != rule['advisorySHA256']:
            raise ValueError('Release advisory content changed: '+rule['id'])
        decisions.append({'findingIndex': index, 'id': rule['id'], 'scope': rule['scope'],
                          'classification': rule['classification'], 'issueDisposition': 'retain-open',
                          'reason': 'Reviewed conditions verified; mandatory stage checks still apply'})
    for notice in report['vendorNotices'].get('changes', []):
        match = next((n for n in data['notices'] if all(notice.get(k) == n[k]
                      for k in ('id', 'source', 'url', 'contentSHA256'))), None)
        if match is None:
            unresolved_notices.append(notice)
            continue
        if notice['source'] == 'node-blog':
            expected = json.loads(owned(root, 'Config/Security/node-tools.json').read_bytes())['nodeVersion']
            actual = subprocess.run([str(root/'scripts/project-node.sh'), '--version'],
                                    capture_output=True, text=True, check=True, timeout=20).stdout.strip()
            if actual != 'v'+expected: raise ValueError('Reviewed Node use changed')
        elif notice['source'] == 'firebase-releases':
            lock = json.loads(owned(root, 'package-lock.json').read_bytes())['packages']
            for name, version in (('node_modules/body-parser', '1.20.9'),
                                  ('node_modules/@modelcontextprotocol/sdk/node_modules/body-parser', '2.4.0')):
                actual = json.loads(owned(root, name+'/package.json').read_bytes())['version']
                if actual != version or lock[name]['version'] != version:
                    raise ValueError('Reviewed body-parser fix is not installed')
        else: raise ValueError('Unreviewed notice source')
        notices.append(match)
    if report['vendorNotices'].get('requiresNoticeReview') and not report['vendorNotices'].get('changes'):
        raise ValueError('Notice baseline requires review')
    return {'schemaVersion': 1, 'context': ctx, 'sourceDigest': source_digest,
            'nonBlockingFindings': decisions, 'reviewedNotices': notices,
            'unreviewedNotices': unresolved_notices, 'grantsRiskException': False,
            'authorizesRelease': False, 'preservesFindings': True}


def require_success(run, commit, path, event):
    if (run.get('head_sha') != commit or run.get('path', '').split('@')[0] != path
            or run.get('head_branch') != 'main' or run.get('event') != event
            or run.get('head_repository', {}).get('full_name') != REPOSITORY
            or run.get('status') != 'completed' or run.get('conclusion') != 'success'):
        raise ValueError('Required exact-commit workflow has not succeeded')


def latest_run(runs):
    if not runs: raise ValueError('Missing required workflow run')
    for run in runs:
        stamp = dt.datetime.fromisoformat(run['created_at'])
        if stamp.tzinfo is None or stamp > dt.datetime.now(dt.timezone.utc):
            raise ValueError('Invalid workflow creation time')
    ordered = sorted(runs, key=lambda r: dt.datetime.fromisoformat(r['created_at']))
    if len(ordered) > 1 and ordered[-1]['created_at'] == ordered[-2]['created_at']:
        raise ValueError('Ambiguous latest workflow run')
    return ordered[-1]


def require_analyses(analyses, commit):
    expected = {'/language:swift', '/language:python', '/language:javascript-typescript', '/language:actions'}
    groups = {}
    for item in analyses:
        if item.get('commit_sha') != commit or item.get('ref') != 'refs/heads/main': continue
        category = item.get('category')
        if category in expected: groups.setdefault(category, []).append(item)
    latest = {category: latest_run(rows) for category, rows in groups.items()}
    if set(latest) != expected or any(r.get('error') or r.get('warning') or r.get('results_count') != 0 for r in latest.values()):
        raise ValueError('Required CodeQL analysis is incomplete or has findings/errors')
    return {k: v['id'] for k, v in latest.items()}


def log_digest(blob):
    if len(blob) > 32*1024*1024: raise ValueError('Monitor logs exceed limit')
    found = []
    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        total = 0
        for info in z.infolist():
            total += info.file_size
            if total > 64*1024*1024: raise ValueError('Expanded monitor logs exceed limit')
            # GitHub log archives contain both per-step and aggregated job logs.
            # Only the aggregated job logs at archive root are authoritative here.
            if '/' not in info.filename and info.filename.endswith('.txt'):
                text = z.read(info).decode('utf-8')
                found.extend(re.findall(r'(?m)^\S+ MYTERM_SECURITY_REPORT_SHA256=([a-f0-9]{64})\s*$', text))
    if len(found) != 1: raise ValueError('Missing or ambiguous independently logged report digest')
    return found[0]


def sarif_result(identifier, root):
    raw = subprocess.run([str(root/'scripts/project-gh.sh'), 'api', '--method', 'GET',
        '-H', 'Accept: application/sarif+json', 'repos/'+REPOSITORY+'/code-scanning/analyses/'+str(identifier)],
        capture_output=True, check=True, timeout=60).stdout
    if len(raw) > 32*1024*1024: raise ValueError('CodeQL result exceeds limit')
    return json.loads(raw)


def validate_sarif(value):
    runs = value.get('runs', [])
    if value.get('version') != '2.1.0' or not runs:
        raise ValueError('Missing readable CodeQL results')
    for run in runs:
        invocations = run.get('invocations', [])
        # GitHub's exported SARIF omits invocations on successful analyses.
        # The analysis API's exact-commit error/warning/result fields are checked
        # separately; if invocation diagnostics are present, never ignore them.
        if (run.get('tool', {}).get('driver', {}).get('name') != 'CodeQL'
                or run.get('results') != []
                or any(i.get('executionSuccessful') is not True or any(
                    n.get('level') in ('error', 'warning')
                    for field in ('toolExecutionNotifications', 'toolConfigurationNotifications')
                    for n in i.get(field, [])) for i in invocations)):
            raise ValueError('CodeQL has findings or incomplete execution')


def remote_readiness(commit, *, root=ROOT, reader=None, downloader=None, sarif_reader=None):
    """GET-only control-plane checks; upload-artifact output is not sole authority."""
    reader = reader or (lambda endpoint: load('security-source-review').gh_read(root, endpoint))
    def download(endpoint):
        return subprocess.run([str(root/'scripts/project-gh.sh'), 'api', '--method', 'GET', endpoint],
                              capture_output=True, check=True, timeout=60).stdout
    downloader = downloader or download
    sarif_reader = sarif_reader or (lambda identifier: sarif_result(identifier, root))
    prefix = 'repos/'+REPOSITORY
    runs = reader(prefix+'/actions/workflows/security-gate.yml/runs?branch=main&event=push&head_sha='+commit+'&per_page=100')['workflow_runs']
    if not runs: raise ValueError('Missing main security gate')
    run = latest_run(runs)
    require_success(run, commit, '.github/workflows/security-gate.yml', 'push')
    dynamic = reader(prefix+'/actions/runs?branch=main&event=dynamic&head_sha='+commit+'&per_page=100')['workflow_runs']
    codeql = [r for r in dynamic if r.get('path', '').split('@')[0] == 'dynamic/github-code-scanning/codeql']
    if not codeql: raise ValueError('Missing main CodeQL workflow')
    codeql_run = latest_run(codeql)
    require_success(codeql_run, commit, 'dynamic/github-code-scanning/codeql', 'dynamic')
    analyses = reader(prefix+'/code-scanning/analyses?ref=refs%2Fheads%2Fmain&per_page=100')
    analyzed = require_analyses(analyses, commit)
    # Main analyses must be readable. The control-plane error field alone has
    # previously failed to identify a GitHub result-processing failure.
    for identifier in analyzed.values():
        validate_sarif(sarif_reader(identifier))
    retained = {}
    def retained_bytes(identifier):
        if identifier not in retained:
            retained[identifier] = downloader(prefix+'/actions/artifacts/'+str(identifier)+'/zip')
        return retained[identifier]
    health = load('security-monitor-health').check(reader, retained_bytes)
    if not health.get('healthy') or health.get('headSHA') != commit:
        raise ValueError('Fresh complete monitor for this commit is required')
    log = downloader(prefix+'/actions/runs/'+str(health['runId'])+'/attempts/'+str(health['runAttempt'])+'/logs')
    expected = log_digest(log)
    artifact = retained_bytes(health['artifactId'])
    # Do not trust a digest co-located with the payload. Compare actual bytes to
    # the audit process output obtained independently from GitHub run logs.
    with zipfile.ZipFile(io.BytesIO(artifact)) as z:
        info = z.getinfo('security-report.json')
        if info.file_size > 8*1024*1024: raise ValueError('Oversized monitor report')
        if hashlib.sha256(z.read(info)).hexdigest() != expected:
            raise ValueError('Retained report differs from independent execution log')
    return {'gateRun': run['id'], 'codeqlRun': codeql_run['id'], 'analyses': analyzed, 'monitorRun': health['runId'],
            'monitorAttempt': health['runAttempt'], 'monitorArtifact': health['artifactId'],
            'reportSHA256': expected, 'commit': commit}
