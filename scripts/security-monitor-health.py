#!/usr/bin/env python3
"""Independent GET-only monitor health; never loads project packages or tests."""
import argparse
import datetime as dt
import hashlib
import json
import io
import zipfile
from pathlib import Path
import subprocess

REPOSITORY = 'crazy01100/myterm'
WORKFLOW = 'security-checks.yml'


def fetch(endpoint):
    r = subprocess.run([str(Path(__file__).resolve().parent/'project-gh.sh'), 'api', '--method', 'GET', endpoint], check=True,
                       capture_output=True, text=True, timeout=25)
    if len(r.stdout) > 8 * 1024 * 1024:
        raise ValueError('Health response exceeds limit')
    return json.loads(r.stdout)


def evaluate(workflow, runs, artifacts, *, now=None, max_hours=48):
    now = now or dt.datetime.now(dt.timezone.utc)
    if now.tzinfo is None or max_hours != 48:
        raise ValueError('Unreviewed health threshold')
    result = {'schemaVersion': 1, 'checkedAt': now.isoformat(), 'healthy': False,
              'status': 'unavailable', 'reason': '', 'maxAgeHours': max_hours,
              'scope': 'GitHub monitor workflow; not independent of GitHub availability'}
    if workflow.get('path') != '.github/workflows/'+WORKFLOW or workflow.get('state') != 'active':
        result.update(status='disabled', reason='Expected security monitor is not active')
        return result
    if not isinstance(runs, list) or not isinstance(artifacts, list):
        raise ValueError('Missing health evidence')
    good = []; trusted = []
    for run in runs:
        if (run.get('path', '').split('@')[0] == '.github/workflows/'+WORKFLOW
                and run.get('event') in ('schedule', 'workflow_dispatch')
                and run.get('head_branch') == 'main' and run.get('head_repository', {}).get('full_name') == REPOSITORY):
            timestamp = dt.datetime.fromisoformat(run['updated_at'])
            if timestamp.tzinfo is None or timestamp > now:
                raise ValueError('Invalid monitor timestamp')
            trusted.append((timestamp, run))
            if run.get('status')=='completed' and run.get('conclusion')=='success':
                good.append((timestamp, run))
    completed=[r for r in trusted if r[1].get('status')=='completed']
    if completed:
        _, latest=max(completed,key=lambda x:(x[0],x[1]['id']))
        if latest.get('conclusion')!='success':
            result.update(status='latest-run-failed',reason='Latest completed trusted monitor did not succeed',
                          runId=latest['id'],runURL=latest['html_url'])
            return result
    if not good:
        result.update(status='no-success', reason='No successful trusted monitor in bounded recent history')
        return result
    timestamp, run = max(good, key=lambda x: x[0])
    result.update(runId=run['id'], runURL=run['html_url'], lastSuccessfulRunAt=timestamp.isoformat())
    if now - timestamp > dt.timedelta(hours=max_hours):
        result.update(status='stale', reason='No successful monitor within 48 hours')
        return result
    if now - timestamp > dt.timedelta(hours=24):
        result.update(status='delayed', reason='No successful monitor within 24 hours')
        return result
    evidence = [a for a in artifacts if a.get('name') == 'security-monitor-state'
                and a.get('expired') is False and a.get('workflow_run', {}).get('id') == run['id']]
    if not evidence:
        result.update(status='missing-evidence', reason='Successful monitor has no retained evidence artifact')
        return result
    result.update(status='healthy', healthy=True, reason='Recent successful monitor and retained evidence found',
                  artifactId=max(evidence, key=lambda a: a['id'])['id'],
                  runAttempt=run.get('run_attempt'), headSHA=run.get('head_sha'))
    return result


def retained_report(blob, *, expected_run=None):
    if len(blob)>8*1024*1024:
        raise ValueError('Health artifact exceeds limit')
    with zipfile.ZipFile(io.BytesIO(blob)) as archive:
        if len(archive.namelist())!=len(set(archive.namelist())):
            raise ValueError('Duplicate health evidence entries')
        if not {'security-report.json','security-monitor-receipt.json'} <= set(archive.namelist()):
            raise ValueError('Missing scan or publication receipt')
        info=archive.getinfo('security-report.json')
        if info.file_size>8*1024*1024:
            raise ValueError('Health report exceeds limit')
        raw=archive.read(info); report=json.loads(raw)
        receipt_info=archive.getinfo('security-monitor-receipt.json')
        if receipt_info.file_size>65536:raise ValueError('Oversized notification receipt')
        receipt=json.loads(archive.read(receipt_info))
    if (receipt.get('schemaVersion')!=1 or receipt.get('complete') is not True
            or receipt.get('reportSHA256')!=hashlib.sha256(raw).hexdigest()
            or receipt.get('riskIssues')!='success' or receipt.get('noticeIssues')!='success'):
        raise ValueError('Monitor notification receipt is incomplete')
    if expected_run is not None:
        for field in ('runId','runAttempt','headSHA'):
            if expected_run.get(field) is None or receipt.get(field)!=expected_run[field]:
                raise ValueError('Notification receipt belongs to another run or attempt')
    if report.get('scanStatus')!='complete' or report.get('errors')!=[] or not report.get('releaseTag'):
        raise ValueError('Retained monitor scan was incomplete')
    coverage=report.get('toolchainCoverage',{})
    rows=coverage.get('coverage',[])
    limits=coverage.get('supplierLimitations',[])
    if (coverage.get('schemaVersion')!=1 or coverage.get('checksComplete') is not True
            or coverage.get('errors')!=[] or not coverage.get('inventoryDigest') or not rows
            or any(r.get('checksComplete') is not True for r in rows)
            or coverage.get('status')!=('complete-with-supplier-limitations' if limits else 'complete')
            or (limits and coverage.get('allDependenciesScanned') is not False)):
        raise ValueError('Retained monitor lacks completed required checks and explicit supplier limits')
    stamp=dt.datetime.fromisoformat(report['checkedAt'])
    if stamp.tzinfo is None or not 0 <= (dt.datetime.now(dt.timezone.utc)-stamp).total_seconds() <= 48*3600:
        raise ValueError('Retained monitor report is stale')
    return {'coverageDigest':coverage['inventoryDigest'],'scanCheckedAt':report['checkedAt'],
            'coverageStatus':coverage['status'],'supplierLimitations':limits}


def artifact_bytes(identifier):
    if type(identifier) is not int or identifier<1:raise ValueError('Invalid artifact identity')
    return subprocess.run([str(Path(__file__).resolve().parent/'project-gh.sh'),'api','--method','GET',f'repos/{REPOSITORY}/actions/artifacts/{identifier}/zip'],
                          check=True,capture_output=True,timeout=25).stdout


def check(fetcher=fetch,download=artifact_bytes):
    workflow = fetcher(f'repos/{REPOSITORY}/actions/workflows/{WORKFLOW}')
    # Bounded search. A crowded history cannot become a false healthy result.
    runs = fetcher(f'repos/{REPOSITORY}/actions/workflows/{WORKFLOW}/runs?branch=main&per_page=100')['workflow_runs']
    artifacts = fetcher(f'repos/{REPOSITORY}/actions/artifacts?name=security-monitor-state&per_page=100')['artifacts']
    result=evaluate(workflow, runs, artifacts)
    if result['healthy']:
        try:
            result.update(retained_report(download(result['artifactId']),expected_run=result))
        except (OSError,ValueError,KeyError,TypeError,zipfile.BadZipFile,subprocess.SubprocessError):
            result.update(healthy=False,status='incomplete-evidence',reason='Retained artifact does not prove a complete recent scan')
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    try:
        result = check()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        result = {'schemaVersion': 1, 'healthy': False, 'status': 'unavailable',
                  'checkedAt':dt.datetime.now(dt.timezone.utc).isoformat(),
                  'reason': 'Health evidence unavailable: '+type(error).__name__}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result))
    return int(not result['healthy'])


if __name__ == '__main__':
    raise SystemExit(main())
