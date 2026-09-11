#!/usr/bin/env python3
"""Synchronize completed scans to private, bot-owned risk Issues. No scanning bypass."""
import argparse
import datetime as dt
import hashlib
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys

BOT = 'github-actions[bot]'
MARKER = re.compile(r'^<!-- myterm-security-risk:v1 key=([0-9a-f]{64}) digest=([0-9a-f]{64}) -->\n')
SCOPES = {'current-source':'目前來源', 'released-app':'已發布 App', 'development':'開發工具', 'verification-tool':'驗簽工具', 'github-actions':'GitHub Actions'}
LEVELS = {'critical':'嚴重風險', 'high':'高風險', 'moderate':'中風險', 'medium':'中風險', 'low':'低風險', 'unknown':'待確認'}


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def safe(value):
    return html.escape(str(value)).replace('@', '&#64;')


def validate_report(report, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    if report.get('schemaVersion') != 1 or report.get('scanStatus') != 'complete' or report.get('errors') != []:
        raise ValueError('Scan incomplete; existing risk Issues must remain unchanged')
    if not report.get('releaseTag') or not isinstance(report.get('findings'), list):
        raise ValueError('A complete source-and-release monitor report is required')
    checked = dt.datetime.fromisoformat(report['checkedAt'])
    if checked.tzinfo is None or not 0 <= (now-checked).total_seconds() <= 1800:
        raise ValueError('Report is stale or has an invalid timestamp')
    for f in report['findings']:
        if not all(isinstance(f.get(k), str) and f[k] for k in ['id','component','version','severity','scope','status','url']):
            raise ValueError('Invalid finding fields')
        if f['scope'] not in SCOPES or f['status'] not in ['affected', 'needs-review']:
            raise ValueError('Unknown finding scope/status')
        if not re.fullmatch(r'https://(?:github\.com/[A-Za-z0-9_./-]+|osv\.dev/vulnerability/[A-Za-z0-9_-]+)', f['url']):
            raise ValueError('Unexpected advisory URL')


def risks(report):
    result = {}
    for f in report['findings']:
        key = digest([f[k] for k in ['id','component','scope']])
        snapshot = dict(f)
        if f['scope'] == 'released-app': snapshot['releaseTag'] = report['releaseTag']
        if key in result: raise ValueError('Ambiguous duplicate risk identity')
        result[key] = snapshot
    return result


def render(key, f, report, resolved=False):
    fingerprint = digest({'risk':f, 'resolved':resolved})
    marker = f'<!-- myterm-security-risk:v1 key={key} digest={fingerprint} -->\n'
    level = LEVELS.get(f['severity'], '待確認')
    title = f"[{level}] {f['component']}：{SCOPES[f['scope']]}安全風險（{f['id']}）"
    if len(title) > 240: raise ValueError('Issue title too long')
    state = '本次完整掃描已不再命中；保留歷史供追蹤。' if resolved else '掃描已完成，以下風險需要追蹤。此紀錄不代表監測程式故障。'
    rows = [('公告',f['id']),('元件',f['component']),('受影響範圍',SCOPES[f['scope']]),('版本／revision',f['version']),('判斷', '版本命中；不代表已驗證攻擊可達' if f['status']=='affected' else '適用範圍尚待人工確認'),('上游修補資訊',f.get('fixedVersion') or '請依公告確認相容的修補版本')]
    if f.get('releaseTag'): rows.append(('正式版本',f['releaseTag']))
    if f.get('exceptionExpiresAt'):
        rows += [('暫時例外','有效，仍須追蹤修復' if f.get('acceptedRisk') else '已到期或無效，恢復發布阻擋'),('例外期限',f['exceptionExpiresAt'])]
    body = marker+'## '+state+'\n\n'+'\n'.join('- **'+k+'**：'+safe(v) for k,v in rows)
    body += '\n\n[查看上游公告]('+f['url']+')\n\n'
    if resolved:
        body += '解除只表示本次監測範圍已不再命中，不證明所有使用者裝置均已更新。'
    elif f['scope']=='released-app':
        body += '建議動作：確認修補版本，經建置、簽章與發布驗收後，讓使用者更新 App。只更新 main 不會修復已發布版本。'
    else:
        body += '建議動作：核對公告前提與相容修補，更新受影響相依並執行相稱測試；未修復的例外不得自動展延。'
    body += '\n\n本次紀錄的掃描時間：'+safe(report['checkedAt'])+'\n'
    return title, body


class GitHub:
    def __init__(self, repo): self.repo = repo

    def request(self, path, method='GET', payload=None):
        endpoint = 'repos/'+self.repo+('/'+path if path else '')
        cmd = ['gh','api',endpoint,'--method',method]
        if payload is not None: cmd += ['--input','-']
        result = subprocess.run(cmd, input=None if payload is None else json.dumps(payload), capture_output=True, text=True, timeout=60)
        if result.returncode: raise RuntimeError(f'GitHub {method} {path.split("?")[0]} failed; risk tracking is incomplete')
        return json.loads(result.stdout) if result.stdout.strip() else None

    def pages(self, path):
        result = []
        for page in range(1, 101):
            items = self.request(path+('&' if '?' in path else '?')+f'per_page=100&page={page}')
            if not isinstance(items,list): raise ValueError('Unexpected GitHub list response')
            result.extend(items)
            if len(items)<100: return result
        raise ValueError('GitHub pagination limit reached')


def synchronize(report, api, apply=False, environ=None):
    validate_report(report)
    desired = risks(report)
    metadata = api.request('')
    if not metadata.get('private'): raise ValueError('Risk Issue automation requires a private repository')
    if apply:
        env = os.environ if environ is None else environ
        if env.get('GITHUB_ACTIONS')!='true' or env.get('GITHUB_EVENT_NAME') not in ['schedule','workflow_dispatch'] or env.get('GITHUB_REF')!='refs/heads/'+metadata['default_branch']:
            raise ValueError('Issue writes require a default-branch scheduled/manual Actions run')
    managed = {}
    for issue in api.pages('issues?state=all&creator=github-actions%5Bbot%5D'):
        match = MARKER.match(issue.get('body') or '')
        if 'pull_request' in issue or issue.get('user',{}).get('login')!=BOT or not match: continue
        if match[1] in managed: raise ValueError('Duplicate managed Issues require review')
        managed[match[1]] = issue
    actions = []
    for key,f in desired.items():
        title,body = render(key,f,report)
        issue = managed.get(key)
        if issue is None:
            action = {'action':'create','key':key,'title':title}
            if apply: action['number'] = api.request('issues','POST',{'title':title,'body':body})['number']
            actions.append(action)
        elif MARKER.match(issue['body'])[2] != MARKER.match(body)[2] or issue['state']!='open':
            actions.append({'action':'update','number':issue['number'],'key':key})
            if apply:
                change_marker = '<!-- myterm-security-change:'+digest([issue['body'],body.split('\n\n本次紀錄')[0]])+' -->'
                comments = api.pages(f"issues/{issue['number']}/comments")
                if not any(c.get('user',{}).get('login')==BOT and change_marker in (c.get('body') or '') for c in comments):
                    api.request(f"issues/{issue['number']}/comments",'POST',{'body':change_marker+'\n風險狀態有變更：\n\n'+body})
                api.request(f"issues/{issue['number']}",'PATCH',{'title':title,'body':body,'state':'open'})
    # Only a fully validated, successful scan can clear bot-owned risks.
    for key,issue in managed.items():
        if key in desired or issue['state']=='closed': continue
        actions.append({'action':'resolve','number':issue['number'],'key':key})
        if apply:
            note = '\n\n## 解除紀錄\n本次完整來源／正式版掃描已不再命中此風險。時間：'+safe(report['checkedAt'])+'。不代表所有使用者裝置均已更新。'
            api.request(f"issues/{issue['number']}",'PATCH',{'body':issue['body']+note,'state':'closed','state_reason':'completed'})
    return actions


def main():
    p=argparse.ArgumentParser();p.add_argument('--report',type=Path,required=True);p.add_argument('--apply',action='store_true');args=p.parse_args()
    repo=os.environ.get('GITHUB_REPOSITORY','')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',repo): raise ValueError('GITHUB_REPOSITORY is required')
    report=json.loads(args.report.read_text());actions=synchronize(report,GitHub(repo),args.apply)
    result={'applied':args.apply,'riskCount':len(report['findings']),'changes':actions}
    args.report.with_name('security-issues-result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    summary=os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary,'a') as output:
            output.write(f"\n## 風險 Issue 追蹤完成\n本次 {len(report['findings'])} 項風險；建立／更新／解除 {len(actions)} 筆紀錄。沒有變化的紀錄不重複寫入。\n")
            for action in actions:
                if action.get('number'): output.write(f"- {action['action']}: https://github.com/{repo}/issues/{action['number']}\n")
    print(json.dumps(result,ensure_ascii=False))

if __name__=='__main__':
    try: main()
    except Exception as error:
        print('Risk Issue tracking failed: '+str(error),file=sys.stderr)
        sys.exit(1)
