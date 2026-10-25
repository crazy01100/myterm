#!/usr/bin/env python3
"""Track coverage/official-notice review separately from vulnerability Issues."""
import argparse
import base64
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import urllib.parse

ROOT=Path(__file__).resolve().parents[1]
MARKER='<!-- myterm-monitor-review:v1 -->'


def load(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/f'{name}.py')
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value


def notice_url(row):
    allowed={**load('security-vendor-notices').SOURCES,**load('security-supplier-notices').NOTICE_SOURCES}
    source=row.get('source');parts=urllib.parse.urlsplit(row.get('url',''))
    if (source not in allowed or parts.scheme!='https' or parts.hostname!=allowed[source][1] or
            parts.port not in (None,443) or parts.username or parts.password or
            any(x in row['url'] for x in ('\n','\r',' ',')','('))):
        raise ValueError('Unreviewed official notice URL')
    if not all(re.fullmatch('[a-f0-9]{64}',row.get(k,'')) for k in ('id','contentSHA256')):
        raise ValueError('Missing official notice identity')
    if source in ('firebase-releases','cryptography-releases'):
        prefix='/firebase/firebase-tools/releases/tag/' if source=='firebase-releases' else '/pyca/cryptography/releases/tag/'
        if not parts.path.startswith(prefix):raise ValueError('Official release notice belongs to another repository')
    if source=='jdk-security' and parts.path!='/groups/vulnerability/advisories/':
        raise ValueError('Unexpected JDK notice path')
    if source=='firestore-releases' and parts.path!='/firestore/docs/release-notes':
        raise ValueError('Unexpected Firestore notice path')


def snapshot(report):
    review=report.get('sourceReview',{})
    if (review.get('sourceVerified') is not True or review.get('grantsRiskException') is not False or
            not re.fullmatch('[a-f0-9]{64}',review.get('policySHA256',''))):
        raise ValueError('Approved source policy required for monitor status publication')
    stamp=dt.datetime.fromisoformat(report['checkedAt'])
    if stamp.tzinfo is None or not 0<=(dt.datetime.now(dt.timezone.utc)-stamp).total_seconds()<=1800:
        raise ValueError('Stale monitor status report')
    notices=report.get('vendorNotices',{}).get('changes',[])
    if len(notices)>2000:raise ValueError('Too many notices')
    for row in notices:notice_url(row)
    notices=sorted(notices,key=lambda n:(n['source'],n['id']))
    gaps=report.get('coverageGaps',[])
    if not isinstance(gaps,list) or len(gaps)>200:raise ValueError('Invalid coverage gaps')
    baselines=[]
    allowed={**load('security-vendor-notices').SOURCES,**load('security-supplier-notices').NOTICE_SOURCES}
    for row in report.get('vendorNotices',{}).get('sources',[]):
        if row.get('reviewState')=='reviewed' and row.get('historyGap') is False:continue
        if (row.get('id') not in allowed or type(row.get('observedItems')) is not int or
                not 0<row['observedItems']<=2000 or
                not re.fullmatch('[a-f0-9]{64}',row.get('observedDigest',''))):
            raise ValueError('Invalid initial notice review evidence')
        baselines.append({k:row[k] for k in ('id','observedItems','observedDigest','reviewState','historyGap')})
    return {'checkedAt':report['checkedAt'],'notices':notices,'gaps':gaps,
            'baselineReviews':baselines,
            'operationalErrorCount':len(report.get('errors',[])),
            'checksComplete':report.get('scanStatus')=='complete' and report.get('toolchainCoverage',{}).get('checksComplete') is True}


def render(state):
    fmt=load('security-issue-format');safe=fmt.safe
    encoded=base64.urlsafe_b64encode(json.dumps(state,sort_keys=True).encode()).decode()
    body=MARKER+'\n<!-- myterm-monitor-state:'+encoded+' -->\n'
    body+='- **檢查時間**：'+fmt.display_time(state['checkedAt'])+'\n'
    body+='- **待確認覆蓋項目**：'+str(len(state['gaps']))+'\n'
    body+='- **未完成檢查**：'+str(state['operationalErrorCount'])+'\n'
    for row in state['gaps'][:50]:
        body+='- '+safe(row['collector'])+'／'+safe(row['source'])+'：'+safe(row['reason'])+'\n'
    if len(state['gaps'])>50:body+='\n其餘覆蓋項目見對應監測報告。\n'
    for row in state.get('baselineReviews',[]):
        url={**load('security-vendor-notices').SOURCES,**load('security-supplier-notices').NOTICE_SOURCES}[row['id']][0]
        body+='\n- **公告來源待審閱**：['+safe(row['id'])+']('+url+')，本次觀測 '+str(row['observedItems'])+' 筆；初始審閱或歷史連續性尚未完成。\n'
    if state['notices']:
        body+='\n## 官方公告待確認\n'
        for row in state['notices'][:50]:body+='- ['+safe(row['title'])+']('+row['url']+')\n'
        if len(state['notices'])>50:body+='\n其餘公告見對應監測報告。\n'
    return body


def synchronize(report,api,*,apply=False,environ=None,root=ROOT):
    state=snapshot(report);env=os.environ if environ is None else environ
    repo=api.request('')
    if apply and (env.get('GITHUB_ACTIONS')!='true' or env.get('GITHUB_EVENT_NAME') not in ('schedule','workflow_dispatch') or
                  env.get('GITHUB_REF')!='refs/heads/'+repo['default_branch']):
        raise ValueError('Monitor status writes require default-branch scheduled/manual Actions')
    managed=[i for i in api.pages('issues?state=open&creator=github-actions%5Bbot%5D') if
             i.get('state')=='open' and 'pull_request' not in i and i.get('user',{}).get('login')=='github-actions[bot]' and
             (i.get('body') or '').startswith(MARKER)]
    if len(managed)>1:raise ValueError('Duplicate monitor review Issues')
    issue=managed[0] if managed else None
    if issue:
        match=re.search(r'<!-- myterm-monitor-state:([A-Za-z0-9_=+-]+) -->',issue['body'])
        if not match:raise ValueError('Unrecognized monitor review state; preserve it')
        old=json.loads(base64.urlsafe_b64decode(match[1]))
        # A notice falling out of the feed is not a resolution. Only an exact
        # explicit baseline review can remove a previously recorded notice.
        policy=json.loads((root/'Config/Security/vendor-notices.json').read_text())
        reviewed={(source,e['id'],e['contentSHA256']) for source,s in policy['sources'].items()
                  if s.get('state')=='reviewed' for e in s['entries']}
        cursor_path=root/'Config/Security/supplier-notice-cursor.json'
        if cursor_path.exists():
            cursor=json.loads(cursor_path.read_text()).get('jdkNoticeCursor','')
            if not re.fullmatch('[a-f0-9]{64}',cursor):raise ValueError('Invalid JDK notice cursor')
            url=load('security-supplier-notices').NOTICE_SOURCES['jdk-security'][0]
            reviewed.add(('jdk-security',hashlib.sha256(url.encode()).hexdigest(),cursor))
        current={(n['source'],n['id']):n for n in state['notices']}
        for n in old.get('notices',[]):
            notice_url(n)
            if (n['source'],n['id'],n['contentSHA256']) not in reviewed:current.setdefault((n['source'],n['id']),n)
        state['notices']=[current[k] for k in sorted(current)]
        baselines={b['id']:b for b in state['baselineReviews']}
        completed={r['id'] for r in report.get('vendorNotices',{}).get('sources',[])
                   if r.get('reviewState')=='reviewed' and r.get('historyGap') is False}
        for b in old.get('baselineReviews',[]):
            if b['id'] not in completed:baselines.setdefault(b['id'],b)
        state['baselineReviews']=[baselines[k] for k in sorted(baselines)]
        if not state['checksComplete']:
            # A failed collector cannot silently remove a previously known gap.
            gaps={(g['collector'],g['source']):g for g in state['gaps']}
            for g in old.get('gaps',[]):gaps.setdefault((g['collector'],g['source']),g)
            state['gaps']=[gaps[k] for k in sorted(gaps)]
        if {k:v for k,v in old.items() if k!='checkedAt'}=={k:v for k,v in state.items() if k!='checkedAt'}:
            return {'action':'unchanged','number':issue['number']}
    resolved=state['checksComplete'] and not state['gaps'] and not state['notices'] and not state['baselineReviews'] and not state['operationalErrorCount']
    if not issue and resolved:return {'action':'none'}
    change={'title':'安全監測：覆蓋範圍與官方公告待確認','body':render(state)}
    if issue and resolved:change.update(state='closed',state_reason='completed')
    if apply:
        if issue:
            token=hashlib.sha256(json.dumps([old,{k:v for k,v in state.items() if k!='checkedAt'}],sort_keys=True).encode()).hexdigest()
            marker='<!-- myterm-monitor-review-change:'+token+' -->'
            comments=api.pages(f"issues/{issue['number']}/comments")
            if not any(c.get('user',{}).get('login')=='github-actions[bot]' and marker in c.get('body','') for c in comments):
                text=('覆蓋與公告待確認事項已處理完成。' if resolved else
                      f"監測紀錄更新：{len(state['notices'])} 則公告、{len(state['baselineReviews'])} 個公告來源及 {len(state['gaps'])} 項覆蓋待確認。")
                api.request(f"issues/{issue['number']}/comments",'POST',{'body':marker+'\n'+text})
            api.request(f"issues/{issue['number']}",'PATCH',change)
        else:issue=api.request('issues','POST',change)
        stored=api.request(f"issues/{issue['number']}")
        if (stored.get('number')!=issue['number'] or
                stored.get('user',{}).get('login')!='github-actions[bot]' or
                stored.get('body')!=change['body'] or stored.get('title')!=change['title'] or
                stored.get('state')!=('closed' if resolved else 'open')):
            raise ValueError('Monitor review publication readback differs')
    return {'action':'resolve' if resolved else ('update' if managed else 'create'),'number':issue['number'] if issue else None}


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--report',type=Path,required=True);parser.add_argument('--apply',action='store_true')
    args=parser.parse_args();repo=os.environ.get('GITHUB_REPOSITORY','')
    if repo!='crazy01100/myterm':raise ValueError('Unreviewed monitoring repository')
    issue_tools=load('sync-security-issues')
    report=json.loads(args.report.read_text())
    actual=load('security-source-review').source_check()
    if args.apply and actual.get('publicationAuthorized') is not True:
        raise ValueError('Only verified default-branch monitoring may publish')
    if actual['policySHA256']!=report.get('sourceReview',{}).get('policySHA256'):
        raise ValueError('Monitor publication source policy differs from scan')
    result=synchronize(report,issue_tools.GitHub(repo),apply=args.apply)
    result['applied']=args.apply
    result['reportSHA256']=hashlib.sha256(args.report.read_bytes()).hexdigest()
    args.report.with_name('security-monitor-status-result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))
