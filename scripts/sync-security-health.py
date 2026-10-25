#!/usr/bin/env python3
"""Publish only monitor-health transitions, never vulnerability decisions."""
import argparse
import base64
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[1]
REPOSITORY='crazy01100/myterm'
MARKER='<!-- myterm-monitor-health:v1 -->'
STATUS={'healthy':'正常','delayed':'超過24小時未完成有效掃描','stale':'超過48小時未完成有效掃描',
        'disabled':'排程已停用','no-success':'沒有有效的成功掃描','latest-run-failed':'最新一輪監測失敗',
        'missing-evidence':'掃描報告遺失','incomplete-evidence':'掃描或通知收據不完整','unavailable':'健康查詢失敗'}

def load(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/f'{name}.py')
    m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m

def synchronize(report,api,*,source_review,env,apply=False,now=None):
    now=now or dt.datetime.now(dt.timezone.utc)
    stamp=dt.datetime.fromisoformat(report['checkedAt'])
    if (stamp.tzinfo is None or not 0<=(now-stamp).total_seconds()<=1800
            or report.get('status') not in STATUS
            or report.get('healthy') is not (report['status']=='healthy')
            or source_review.get('sourceVerified') is not True
            or source_review.get('grantsRiskException') is not False):
        raise ValueError('Untrusted health report or source policy')
    if (env.get('GITHUB_REPOSITORY')!=REPOSITORY or env.get('GITHUB_ACTIONS')!='true'
            or env.get('GITHUB_EVENT_NAME') not in ('schedule','workflow_dispatch')
            or env.get('GITHUB_REF')!='refs/heads/main'):
        raise ValueError('Health publication requires trusted default-branch monitor')
    metadata=api.request('')
    if metadata.get('default_branch')!='main':raise ValueError('Default branch changed')
    matches=[x for x in api.pages('issues?state=all&creator=github-actions%5Bbot%5D')
             if 'pull_request' not in x and x.get('user',{}).get('login')=='github-actions[bot]'
             and (x.get('body') or '').startswith(MARKER)]
    if len(matches)>1:raise ValueError('Duplicate health Issues require review')
    issue=matches[0] if matches else None;old={}
    if issue:
        match=re.search(r'<!-- health-state:([A-Za-z0-9_=+-]+) -->',issue['body'])
        if not match:raise ValueError('Unrecognized health Issue state')
        old=json.loads(base64.urlsafe_b64decode(match[1]))
        previous=dt.datetime.fromisoformat(old['notifiedAt'])
        if previous.tzinfo is None or previous>now:raise ValueError('Invalid notification timestamp')
        same=old.get('status')==report['status']
        correct_state=issue['state']==('closed' if report['healthy'] else 'open')
        if same and correct_state and (report['healthy'] or now-previous<dt.timedelta(hours=24)):
            return {'action':'unchanged','number':issue['number'],'applied':apply}
    if not issue and report['healthy']:return {'action':'none','applied':apply}
    state={'status':report['status'],'notifiedAt':now.isoformat()}
    encoded=base64.urlsafe_b64encode(json.dumps(state,sort_keys=True).encode()).decode()
    label=STATUS[report['status']]
    time=now.astimezone(dt.timezone(dt.timedelta(hours=8))).strftime('%Y-%m-%d %H:%M:%S（UTC+8）')
    body=MARKER+'\n<!-- health-state:'+encoded+' -->\n'
    body+=f'- **狀態**：{label}\n- **檢查時間**：{time}\n'
    run=report.get('runId')
    if type(run) is int and run>0:body+=f'- **執行紀錄**：[#{run}](https://github.com/{REPOSITORY}/actions/runs/{run})\n'
    body+='- **檢查範圍**：掃描排程、報告與 Issue 寫入收據\n'
    change={'title':'MyTerm 安全監測健康狀態','body':body,'state':'closed' if report['healthy'] else 'open'}
    if report['healthy']:change['state_reason']='completed'
    if apply:
        if issue:
            token=hashlib.sha256(json.dumps([old,report['status'],now.date().isoformat() if old.get('status')==report['status'] else 'transition'],sort_keys=True).encode()).hexdigest()
            marker='<!-- myterm-health-change:'+token+' -->'
            comments=api.pages(f"issues/{issue['number']}/comments")
            if not any(c.get('user',{}).get('login')=='github-actions[bot]' and marker in c.get('body','') for c in comments):
                api.request(f"issues/{issue['number']}/comments",'POST',{'body':marker+'\n'+label+'。檢查時間：'+time})
            api.request(f"issues/{issue['number']}",'PATCH',change)
        else:
            issue=api.request('issues','POST',change)
        actual=api.request(f"issues/{issue['number']}")
        if any(actual.get(k)!=change[k] for k in ('body','state')):raise ValueError('Health notification readback differs')
    return {'action':'recover' if report['healthy'] else ('update' if matches else 'create'),
            'number':issue['number'] if issue else None,'applied':apply}

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--report',type=Path,required=True);p.add_argument('--apply',action='store_true')
    args=p.parse_args()
    if args.report.stat().st_size>65536:raise ValueError('Oversized health report')
    report=json.loads(args.report.read_text())
    review=load('security-source-review').source_check()
    if args.apply and review.get('publicationAuthorized') is not True:
        raise ValueError('Only verified default-branch monitoring may publish')
    api=load('sync-security-issues').GitHub(REPOSITORY)
    result=synchronize(report,api,source_review=review,env=os.environ,apply=args.apply)
    args.report.with_name('security-health-notification.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))
