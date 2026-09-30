#!/usr/bin/env python3
"""Concise public risk records with lossless scan/resolution timestamps."""
import base64
import datetime as dt
import hashlib
import html
import json
import re
from zoneinfo import ZoneInfo

FORMAT = '<!-- myterm-security-format:2 -->\n'
SNAPSHOT = re.compile(r'<!-- myterm-security-snapshot:([A-Za-z0-9_=+-]+) -->')
FIELDS = ['id','component','scope','version','severity','status','url','fixedVersion','patches',
          'releaseTag','acceptedRisk','exceptionExpiresAt','exceptionExpired','dependencyPaths','impact']
SCOPES = {'current-source':'目前來源','released-app':'已發布 App','development':'開發工具','verification-tool':'驗簽工具','github-actions':'GitHub Actions'}
LEVELS = {'critical':'嚴重風險','high':'高風險','moderate':'中風險','medium':'中風險','low':'低風險','unknown':'待確認'}
IMPACTS = {'affected':'已確認受影響','not-affected':'已確認不受影響','needs-review':'待確認'}


def digest(value):
    return hashlib.sha256(json.dumps(value,sort_keys=True,ensure_ascii=False).encode()).hexdigest()


def safe(value):
    value=html.escape(str(value)).replace('@','&#64;').replace('\r',' ').replace('\n',' ')
    for char in ['\\','[',']','*','_','`']: value=value.replace(char,'\\'+char)
    return value


def display_time(value):
    stamp=dt.datetime.fromisoformat(value)
    if stamp.tzinfo is None: raise ValueError('Timestamp must include timezone')
    return stamp.astimezone(ZoneInfo('Asia/Taipei')).strftime('%Y-%m-%d %H:%M:%S（UTC+8）')


def public_finding(f):
    result={k:f[k] for k in FIELDS if k in f}
    if 'impact' in result:
        result['impact']={k:v for k,v in result['impact'].items() if k in ['status','reason','usage','reviewedCommit','reviewedAt','evidence','historical']}
    return result


def semantic(f):
    # Enrichment/formatting changes do not manufacture a risk-state transition.
    return {k:f[k] for k in ['id','component','scope','version','severity','status','releaseTag','acceptedRisk','exceptionExpiresAt','exceptionExpired'] if k in f}


def render(key,f,report,resolved=False,resolutions=None):
    f=public_finding(f);resolutions=list(resolutions or [])
    if resolved and not resolutions: resolutions=[report['checkedAt']]
    snapshot={'finding':f,'checkedAt':report['checkedAt'],'resolutions':resolutions}
    encoded=base64.urlsafe_b64encode(json.dumps(snapshot,ensure_ascii=False,sort_keys=True).encode()).decode()
    marker=f'<!-- myterm-security-risk:v1 key={key} digest={digest({"risk":f,"resolved":bool(resolutions)})} -->\n'
    title=f"[{LEVELS.get(f['severity'],'待確認')}] {f['component']}：{SCOPES[f['scope']]}安全風險（{f['id']}）"
    if len(title)>240: raise ValueError('Issue title too long')
    body=marker+FORMAT+'<!-- myterm-security-snapshot:'+encoded+' -->\n'
    body+='- **公告**：['+safe(f['id'])+']('+f['url']+')\n'
    rows=[('元件',f['component']),('受影響範圍',SCOPES[f['scope']]),('目前版本',f['version']),('判斷','版本命中' if f['status']=='affected' else '待確認')]
    if f.get('patches'):
        values=[]
        for patch in f['patches']:
            value='、'.join(patch['fixedVersions']) if patch['status']=='available' else ('上游尚未提供' if patch['status']=='unavailable' else '待確認')
            values.append(patch['currentVersion']+' → '+value)
        rows.append(('修補版本','；'.join(values)))
    else: rows.append(('修補版本',f.get('fixedVersion') or '待確認'))
    impact=f.get('impact',{})
    rows.append(('實際影響',IMPACTS.get(impact.get('status'),'待確認')))
    if impact.get('usage'): rows.append(('使用路徑',impact['usage']))
    elif f.get('dependencyPaths'): rows.append(('相依路徑','；'.join(f['dependencyPaths'])))
    if impact.get('reason'): rows.append(('評估依據',impact['reason']))
    if impact.get('reviewedCommit'):
        rows.append(('評估基準'+('（歷史）' if impact.get('historical') else ''),impact['reviewedCommit'][:12]))
        rows.append(('評估時間',display_time(impact['reviewedAt'])))
    if f.get('releaseTag'): rows.append(('正式版本',f['releaseTag']))
    if f.get('exceptionExpiresAt'):
        rows.extend([('暫時例外','有效' if f.get('acceptedRisk') else '已到期或無效'),('例外期限',display_time(f['exceptionExpiresAt']))])
    rows.append(('掃描時間',display_time(report['checkedAt'])))
    body+='\n'.join('- **'+k+'**：'+safe(v) for k,v in rows)+'\n'
    links=[]
    for index,url in enumerate(impact.get('evidence',[]),1):
        if not re.fullmatch(r'https://github\.com/[A-Za-z0-9_./#-]+',url): raise ValueError('Invalid evidence URL')
        links.append(f'[來源 {index}]({url})')
    if links: body+='\n評估來源：'+'、'.join(links)+'\n'
    if resolutions:
        body+='\n## 解除紀錄\n'
        for stamp in resolutions: body+='- '+display_time(stamp)+'：本次掃描已不再命中此風險。\n'
    return title,body


def parse_body(body):
    match=SNAPSHOT.search(body)
    if match:
        if len(match[1])>100000: raise ValueError('Oversized Issue snapshot')
        result=json.loads(base64.urlsafe_b64decode(match[1]))
        display_time(result['checkedAt'])
        for value in result['resolutions']: display_time(value)
        result['finding']=public_finding(result['finding'])
        return result
    # Only the known legacy renderer is migrated; unknown human additions remain untouched.
    lines=body.splitlines()
    rows={}
    allowed=('<!-- myterm-security-risk:v1 ', '## 掃描已完成，', '## 本次完整掃描已不再命中',
             '- **', '[查看上游公告](', '建議動作：', '本次紀錄的掃描時間：', '## 解除紀錄',
             '本次完整來源／正式版掃描已不再命中此風險。時間：')
    for line in lines:
        if line and not line.startswith(allowed): raise ValueError('Unrecognized legacy Issue content')
        row=re.fullmatch(r'- \*\*([^*]+)\*\*：(.*)',line)
        if row: rows[row[1]]=html.unescape(row[2])
    link=re.search(r'\[查看上游公告\]\((https://[^)]+)\)',body)
    checked=re.search(r'本次紀錄的掃描時間：([^\s]+)',body)
    if not link or not checked: raise ValueError('Legacy Issue missing source or timestamp')
    inverse={v:k for k,v in SCOPES.items()}
    f={'id':rows['公告'],'component':rows['元件'],'scope':inverse[rows['受影響範圍']],
       'version':rows['版本／revision'],'status':'affected' if rows['判斷'].startswith('版本命中') else 'needs-review',
       'severity':'unknown','url':link[1]}
    if '正式版本' in rows:f['releaseTag']=rows['正式版本']
    if '例外期限' in rows:
        f.update(exceptionExpiresAt=rows['例外期限'],acceptedRisk=rows.get('暫時例外','').startswith('有效'))
    if rows.get('上游修補資訊') and not rows['上游修補資訊'].startswith('請依公告'):f['fixedVersion']=rows['上游修補資訊']
    resolutions=re.findall(r'本次完整來源／正式版掃描已不再命中此風險。時間：([^。\s]+)',body)
    result={'finding':f,'checkedAt':checked[1],'resolutions':resolutions}
    display_time(result['checkedAt'])
    for value in resolutions:display_time(value)
    return result


def parse_issue(issue):
    snapshot=parse_body(issue['body'])
    if FORMAT not in issue['body']:
        levels={v:k for k,v in LEVELS.items()};levels['中風險']='moderate'
        label=re.match(r'\[([^]]+)\]',issue['title'])
        snapshot['finding']['severity']=levels.get(label[1] if label else '', 'unknown')
    return snapshot
