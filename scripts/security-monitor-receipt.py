#!/usr/bin/env python3
"""Bind successful Issue publication to this exact monitor report/run."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re


def build(report_path, env):
    result={'schemaVersion':1,'checkedAt':dt.datetime.now(dt.timezone.utc).isoformat(),
            'complete':False,'riskIssues':env.get('RISK_ISSUES_OUTCOME','missing'),
            'noticeIssues':env.get('NOTICE_ISSUES_OUTCOME','missing')}
    try:
        if (env.get('GITHUB_ACTIONS')!='true' or env.get('GITHUB_REPOSITORY')!='crazy01100/myterm'
                or env.get('GITHUB_REF')!='refs/heads/main'
                or env.get('GITHUB_EVENT_NAME') not in ('schedule','workflow_dispatch')
                or not re.fullmatch('[a-f0-9]{40}',env.get('GITHUB_SHA',''))):
            raise ValueError('Untrusted monitor context')
        run=int(env['GITHUB_RUN_ID']);attempt=int(env['GITHUB_RUN_ATTEMPT'])
        if run<1 or attempt<1:raise ValueError('Invalid run identity')
        result.update(runId=run,runAttempt=attempt,headSHA=env['GITHUB_SHA'])
        if report_path.stat().st_size>8*1024*1024:raise ValueError('Oversized report')
        raw=report_path.read_bytes();report=json.loads(raw)
        result['reportSHA256']=hashlib.sha256(raw).hexdigest()
        for filename in ('security-issues-result.json','security-monitor-status-result.json'):
            path=report_path.with_name(filename)
            if path.stat().st_size>8*1024*1024:raise ValueError('Oversized publication result')
            published=json.loads(path.read_bytes())
            if (published.get('applied') is not True
                    or published.get('reportSHA256')!=result['reportSHA256']):
                raise ValueError('Publication was not applied to this report')
        result['complete']=(report.get('scanStatus')=='complete' and report.get('errors')==[]
            and env.get('SCAN_OUTCOME')=='success'
            and result['riskIssues']==result['noticeIssues']=='success')
    except (OSError,ValueError,KeyError,TypeError) as error:
        result['error']=type(error).__name__
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--report',type=Path,required=True)
    args=p.parse_args();result=build(args.report,os.environ)
    path=args.report.with_name('security-monitor-receipt.json');path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(result,indent=2)+'\n')
    raise SystemExit(0 if result['complete'] else 1)
