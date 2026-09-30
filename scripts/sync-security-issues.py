#!/usr/bin/env python3
"""Synchronize completed scans to bot-owned risk Issues; public posting is opt-in."""
import argparse
import datetime as dt
import hashlib
import importlib.util
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


def load(name):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(name+'.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module


fmt=load('security-issue-format')
render=fmt.render


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


def synchronize(report, api, apply=False, environ=None, allow_public=False, refresh_format=False, enrich=None):
    validate_report(report)
    desired = risks(report)
    metadata = api.request('')
    if metadata.get('private') is not True:
        if metadata.get('private') is not False or not allow_public:
            raise ValueError('Public risk Issues require explicit --allow-public approval')
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
    # Prepare every write first: a malformed record or enrichment failure must not
    # partially migrate/close Issues. Unknown legacy additions are explicitly skipped.
    actions=[];operations=[]
    for key,issue in managed.items():
        if key not in desired and issue['state']=='closed' and not refresh_format:continue
        try: old=fmt.parse_issue(issue)
        except (ValueError,KeyError,TypeError) as error:
            actions.append({'action':'needs-review','number':issue['number'],'reason':'Unrecognized Issue format; preserved'})
            continue
        if digest([old['finding'][k] for k in ['id','component','scope']]) != key:
            raise ValueError('Issue snapshot identity differs from its marker')
        f=desired.pop(key,None)
        if f is not None:
            changed=fmt.semantic(old['finding'])!=fmt.semantic(f) or issue['state']!='open'
            current_report=report if changed else {'checkedAt':old['checkedAt']}
            title,body=render(key,f,current_report)
            if body==issue['body'] and title==issue['title'] and issue['state']=='open':continue
            action='update' if changed else 'format'
            comment=None
            if changed:
                change_marker='<!-- myterm-security-change:'+digest([issue['body'],fmt.semantic(f)])+' -->'
                comment=change_marker+'\n前次風險紀錄：\n\n'+issue['body']
            operations.append((issue,{'title':title,'body':body,'state':'open'},comment))
        else:
            f=old['finding']
            if enrich:f=enrich({**f,'observedAt':old['checkedAt']})
            historical={'schemaVersion':1,'scanStatus':'complete','errors':[],'releaseTag':report['releaseTag'],
                        'checkedAt':report['checkedAt'],'findings':[f]}
            validate_report(historical)
            resolved=issue['state']=='open'
            resolutions=old['resolutions']+([report['checkedAt']] if resolved else [])
            title,body=render(key,f,{'checkedAt':old['checkedAt']},resolutions=resolutions)
            # A closed record without a known resolution time is never assigned one.
            change={'title':title,'body':body}
            if resolved:change.update(state='closed',state_reason='completed')
            if body==issue['body'] and title==issue['title'] and not resolved:continue
            action='resolve' if resolved else 'format'
            operations.append((issue,change,None))
        actions.append({'action':action,'number':issue['number'],'key':key})
    for key,f in desired.items():
        if key in managed:continue  # An unrecognized managed record must not be duplicated.
        title,body=render(key,f,report)
        action={'action':'create','key':key,'title':title};actions.append(action)
        operations.append((None,{'title':title,'body':body},action))
    if apply:
        for issue,change,comment in operations:
            if issue is None:
                comment['number']=api.request('issues','POST',change)['number'];continue
            if comment:
                change_marker=comment.split('\n',1)[0]
                comments=api.pages(f"issues/{issue['number']}/comments")
                if not any(c.get('user',{}).get('login')==BOT and change_marker in (c.get('body') or '') for c in comments):
                    api.request(f"issues/{issue['number']}/comments",'POST',{'body':comment})
            api.request(f"issues/{issue['number']}",'PATCH',change)
    return actions


def main():
    p=argparse.ArgumentParser();p.add_argument('--report',type=Path,required=True);p.add_argument('--apply',action='store_true')
    p.add_argument('--allow-public',action='store_true',help='Allow reviewed public-advisory metadata in public Issues')
    p.add_argument('--refresh-format',action='store_true',help='Refresh managed historical records without changing their state')
    args=p.parse_args()
    repo=os.environ.get('GITHUB_REPOSITORY','')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',repo): raise ValueError('GITHUB_REPOSITORY is required')
    report=json.loads(args.report.read_text())
    audit=load('security-audit');context=load('security-risk-context');cache={}
    enrich=lambda finding:context.enrich(finding,audit.gh,audit.affected,historical=True,cache=cache)
    actions=synchronize(report,GitHub(repo),args.apply,allow_public=args.allow_public,refresh_format=args.refresh_format,enrich=enrich)
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
