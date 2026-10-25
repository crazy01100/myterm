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


def validate_report(report, now=None, additive=False):
    load('security-pip-applicability').validate_envelope(report)
    now = now or dt.datetime.now(dt.timezone.utc)
    incomplete=report.get('scanStatus')!='complete' or report.get('errors')!=[] or report.get('toolchainCoverage',{}).get('checksComplete',True) is not True
    if additive:
        review=report.get('sourceReview',{})
        if (review.get('sourceVerified') is not True or review.get('grantsRiskException') is not False or
                not re.fullmatch('[a-f0-9]{64}',review.get('policySHA256',''))):
            raise ValueError('Additive reporting requires verified approved source policy')
        if report.get('scanStatus') not in ('complete','failed') or not isinstance(report.get('errors'),list):
            raise ValueError('Invalid partial scan envelope')
    if report.get('schemaVersion') != 1 or incomplete and not additive:
        raise ValueError('Scan incomplete; existing risk Issues must remain unchanged')
    if not isinstance(report.get('findings'), list) or (not report.get('releaseTag') and
            (not additive or any(f.get('scope')=='released-app' for f in report['findings']))):
        raise ValueError('A complete source-and-release monitor report is required')
    if not additive and 'toolchainCoverage' in report and report['toolchainCoverage'].get('checksComplete') is not True:
        raise ValueError('Required toolchain checks are incomplete')
    checked = dt.datetime.fromisoformat(report['checkedAt'])
    if checked.tzinfo is None or not 0 <= (now-checked).total_seconds() <= 1800:
        raise ValueError('Report is stale or has an invalid timestamp')
    for f in report['findings']:
        if not all(isinstance(f.get(k), str) and f[k] for k in ['id','component','version','severity','scope','status','url']):
            raise ValueError('Invalid finding fields')
        if f['scope'] not in SCOPES or f['status'] not in ['affected', 'needs-review']:
            raise ValueError('Unknown finding scope/status')
        if not re.fullmatch(r'https://(?:github\.com/[A-Za-z0-9_./-]+|osv\.dev/vulnerability/[A-Za-z0-9_-]+|openssl-library\.org/news/secjson/cve-[0-9]{4}-[0-9]+\.json|openjdk\.org/groups/vulnerability/advisories/[0-9]{4}-[0-9]{2}-[0-9]{2})', f['url']):
            raise ValueError('Unexpected advisory URL')
        for observation in f.get('environmentObservations',[]):
            if (observation.get('environment') not in ('local','ci','deployment') or
                    not re.fullmatch(r'[A-Za-z0-9@._+-][A-Za-z0-9@._/+-]{0,199}',observation.get('origin','')) or
                    not isinstance(observation.get('versions'),list) or not observation['versions'] or
                    any(not isinstance(v,str) or not re.fullmatch(r'[A-Za-z0-9._+-]{1,128}',v) for v in observation['versions'])):
                raise ValueError('Invalid environment observation')


def merge_observations(*groups):
    combined={}
    for group in groups:
        for observation in group:
            key=(observation['environment'],observation['origin'])
            combined.setdefault(key,set()).update(observation['versions'])
    return [{'environment':env,'origin':origin,'versions':sorted(versions)}
            for (env,origin),versions in sorted(combined.items())]


def normalize_observations(finding):
    if finding.get('environmentObservations'):
        finding['environmentObservations']=merge_observations(finding['environmentObservations'])
        versions={v.strip() for v in finding['version'].split(',')}
        versions.update(v for o in finding['environmentObservations'] for v in o['versions'])
        finding['version']=', '.join(sorted(versions))


def risks(report):
    result = {}
    for f in report['findings']:
        key = digest([f[k] for k in ['id','component','scope']])
        snapshot = dict(f)
        normalize_observations(snapshot)
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
        cmd = [str(Path(__file__).resolve().parent/'project-gh.sh'),'api',endpoint,'--method',method]
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
    additive=report.get('publicationMode')=='additive'
    validate_report(report,additive=additive)
    if additive and refresh_format:raise ValueError('Partial scans cannot rewrite historical formatting')
    selected={**report,'findings':[f for f in report['findings'] if not additive or f.get('queryComplete') is True]}
    desired = risks(selected)
    excluded_keys={digest([row['finding'][k] for k in ['id','component','scope']])
                   for row in report.get('applicabilityReviews',[])}
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
        # Withdrawn/cancelled decisions remain historical. A renewed advisory
        # gets a new record; ordinary completed fixes retain reopen semantics.
        if issue['state']=='closed' and issue.get('state_reason')=='not_planned':continue
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
            if additive:
                previous=old['finding']
                f['version']=', '.join(sorted({v.strip() for row in (f,previous) for v in row['version'].split(',')}))
                levels={'unknown':6,'critical':5,'high':4,'moderate':3,'medium':3,'low':2,'info':1}
                f['severity']=max((f['severity'],previous['severity']),key=lambda x:levels.get(x,6))
                if previous['status']=='needs-review':f['status']='needs-review'
                f['acceptedRisk']=False
            if old['finding'].get('environmentObservations'):
                f['environmentObservations']=merge_observations(
                    f.get('environmentObservations',[]),old['finding']['environmentObservations'])
                normalize_observations(f)
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
            if key in excluded_keys:
                # A precise subset decision is not a package upgrade. Preserve
                # prior Issues for same-scope/main verification and maintenance.
                actions.append({'action':'preserve','number':issue['number'],
                                'reason':'Exact subset decision requires final main/scope review; not a version fix'})
                continue
            if additive:
                if issue['state']=='open':actions.append({'action':'preserve','number':issue['number'],'reason':'Partial scan cannot resolve existing risk'})
                continue
            observations=f.get('environmentObservations',[])
            if issue['state']=='open' and observations and (report.get('toolchainCoverage',{}).get('checksComplete') is not True or any(
                    o['environment']!=report.get('observedEnvironment') or o['origin'] not in report.get('observedOrigins',[])
                    for o in observations)):
                actions.append({'action':'needs-review','number':issue['number'],
                                'reason':'Previous environment or tool origin lacks matching current coverage'})
                continue
            if issue['state']=='open' and observations:
                origins=report.get('originCoverage',{})
                if any(origins.get(o['origin'],{}).get('closureEligible') is not True for o in observations):
                    actions.append({'action':'preserve','number':issue['number'],'reason':'Origin lacks explicit closure eligibility'})
                    continue
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
    if 'toolchainCoverage' in report:
        actual=load('security-source-review').source_check()
        if args.apply and actual.get('publicationAuthorized') is not True:
            raise ValueError('Only verified default-branch monitoring may publish')
        if actual['policySHA256']!=report.get('sourceReview',{}).get('policySHA256'):
            raise ValueError('Publication source policy differs from scan')
    if report.get('errors') or report.get('toolchainCoverage',{}).get('checksComplete',True) is not True:
        report['publicationMode']='additive'
    audit=load('security-audit');context=load('security-risk-context');cache={}
    load('security-pip-applicability').revalidate(report,Path(__file__).resolve().parents[1],audit.gh)
    enrich=lambda finding:context.enrich(finding,audit.gh,audit.affected,historical=True,cache=cache)
    actions=synchronize(report,GitHub(repo),args.apply,allow_public=args.allow_public,refresh_format=args.refresh_format,enrich=enrich)
    result={'applied':args.apply,'riskCount':len(report['findings']),'changes':actions,
            'reportSHA256':hashlib.sha256(args.report.read_bytes()).hexdigest()}
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
