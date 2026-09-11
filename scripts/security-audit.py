#!/usr/bin/env python3
"""Read-only dependency audit. Query failures and unknown ranges are not a pass."""
import argparse
import base64
import datetime as dt
import importlib.util
import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('inventory',ROOT/'scripts/dependency-inventory.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)


def gh(path):
    result=subprocess.run(['gh','api',path],capture_output=True,text=True,timeout=60)
    if result.returncode:raise ValueError('GitHub API request failed: '+path.split('?')[0])
    return json.loads(result.stdout)


def get_json(url,payload=None):
    data=None if payload is None else json.dumps(payload).encode()
    req=urllib.request.Request(url,data=data,headers={'Content-Type':'application/json','User-Agent':'MyTerm-security-audit'})
    with urllib.request.urlopen(req,timeout=45) as response:
        raw=response.read(8*1024*1024+1)
    if len(raw)>8*1024*1024:raise ValueError('Advisory response too large')
    return json.loads(raw)


def affected(version,expression):
    # GitHub ranges use comparators. Unknown syntax is sent for review, never ignored.
    def number(s):
        if not re.fullmatch(r'v?\d+(?:\.\d+){0,2}',s):raise ValueError('Unknown version format')
        values=tuple(map(int,s.lstrip('v').split('.')))
        return values+(0,)*(3-len(values))
    try:
        if not isinstance(expression,str):return None
        current=number(version)
        if expression.strip()=='*':return True
        answers=[]
        for branch in expression.split('||'):
            tokens=re.findall(r'(>=|<=|>|<|=)?\s*(v?\d+(?:\.\d+){0,2})',branch)
            remainder=re.sub(r'(>=|<=|>|<|=)?\s*v?\d+(?:\.\d+){0,2}', '', branch)
            if not tokens or remainder.strip(' ,'):return None
            answers.append(all({'=':current==number(value),'>':current>number(value),'<':current<number(value),'>=':current>=number(value),'<=':current<=number(value)}[op or '='] for op,value in tokens))
        return any(answers)
    except (ValueError,TypeError):return None


def repository_advisories(repo):
    found=[]
    for page in range(1,21):
        items=gh(f'repos/{repo}/security-advisories?state=published&per_page=100&page={page}')
        if not isinstance(items,list):raise ValueError('Invalid repository advisory response')
        found.extend(items)
        if len(items)<100:return found
    raise ValueError('Too many advisory pages')


def vendor_is_patched(repo,revision,patched):
    # Compare commit ancestry against the upstream fixed release, not a fabricated Vendor version.
    commit=re.search(r'(?<![a-f0-9])[a-f0-9]{40}(?![a-f0-9])',patched)
    candidates=[commit[0]] if commit else [patched,'v'+patched]
    for tag in candidates:
        try:
            result=gh(f'repos/{repo}/compare/{tag}...{revision}')
            return result.get('status') in ['ahead','identical']
        except ValueError:pass
    return None


def source_at(repo,path,ref):
    data=gh(f'repos/{repo}/contents/{path}?ref={ref}')
    return base64.b64decode(data['content']).decode()


def released_inventory(repo):
    release=gh(f'repos/{repo}/releases/latest')
    ref=gh(f'repos/{repo}/commits/{release["tag_name"]}')['sha']
    lock=json.loads(source_at(repo,'Package.resolved',ref))
    items=[{'name':p['location'].removesuffix('.git'),'version':p['state']['version'],'revision':p['state']['revision']} for p in lock['pins']]
    upstream=source_at(repo,'Vendor/SwiftTerm/UPSTREAM.md',ref)
    items.append({'name':'https://github.com/migueldeicaza/SwiftTerm','revision':re.search(r'Revision: `([a-f0-9]{40})`',upstream).group(1),'vendored':True})
    wrapper=next(p for p in lock['pins'] if p['identity']=='swift-sodium')
    header=source_at('jedisct1/swift-sodium','Clibsodium.xcframework/macos-arm64_arm64e_x86_64/Headers/Clibsodium/sodium/version.h',wrapper['state']['revision'])
    items.append({'name':'https://github.com/jedisct1/libsodium','version':re.search(r'SODIUM_VERSION_STRING "([^"]+)"',header).group(1)})
    return release['tag_name'],items


def scan_runtime(items,scope,report,cache):
    for component in items:
        repo=component['name'].removeprefix('https://github.com/')
        try:
            if repo not in cache:
                cache[repo]=repository_advisories(repo)
                try:
                    release=gh(f'repos/{repo}/releases/latest')
                    report['upstreamReleases'][repo]={'tag':release['tag_name'],'publishedAt':release['published_at']}
                except ValueError:
                    # A repo can have tags but no published releases. Record tags explicitly.
                    tags=gh(f'repos/{repo}/tags?per_page=1')
                    report['upstreamReleases'][repo]={'tag':tags[0]['name'] if tags else None,'publishedAt':None}
            for advisory in cache[repo]:
                if advisory.get('withdrawn_at'):continue
                for vuln in advisory.get('vulnerabilities',[]):
                    if component.get('vendored'):
                        patched=vuln.get('patched_versions')
                        safe=vendor_is_patched(repo,component['revision'],patched) if patched else None
                        match=False if safe else None
                    else:
                        match=affected(component['version'],vuln.get('vulnerable_version_range',''))
                    if match is not False:
                        report['findings'].append({'id':advisory['ghsa_id'],'component':repo,'version':component.get('version',component.get('revision')),'scope':scope,'severity':advisory.get('severity','unknown'),'status':'affected' if match else 'needs-review','url':advisory['html_url']})
        except (ValueError,KeyError,subprocess.TimeoutExpired) as error:
            report['errors'].append(str(error))


def scan_npm(report):
    result=subprocess.run(['npm','audit','--package-lock-only','--ignore-scripts','--json'],cwd=ROOT,capture_output=True,text=True,timeout=180,env={**os.environ,'npm_config_cache':str(ROOT/'.npm-cache')})
    data=json.loads(result.stdout)
    if data.get('error') or 'metadata' not in data:raise ValueError('npm audit unavailable')
    report['npmCounts']=data['metadata']['vulnerabilities']
    packages=json.loads((ROOT/'package-lock.json').read_text())['packages']
    for node in data.get('vulnerabilities',{}).values():
        for advisory in node['via']:
            if isinstance(advisory,dict):
                report['findings'].append({'id':advisory['url'].split('/')[-1],'component':advisory['name'],'version':','.join(sorted({packages[n]['version'] for n in node['nodes']})),'scope':'development','severity':advisory['severity'],'status':'affected','url':advisory['url']})


def scan_verifier(report):
    requirements=(ROOT/'Tests/Security/requirements.txt').read_text()
    packages=re.findall(r'^([\w-]+)==([\w.]+)',requirements,re.M)
    for name,version in packages:
        result=get_json('https://api.osv.dev/v1/query',{'package':{'ecosystem':'PyPI','name':name},'version':version})
        for advisory in result.get('vulns',[]):
            if advisory.get('withdrawn'):continue
            report['findings'].append({'id':advisory['id'],'component':name,'version':version,'scope':'verification-tool','severity':advisory.get('database_specific',{}).get('severity','unknown').lower(),'status':'affected','url':'https://osv.dev/vulnerability/'+advisory['id']})


def scan_actions(report,cache):
    for path in sorted((ROOT/'.github/workflows').glob('*.yml')):
        for repo,revision in re.findall(r'uses:\s*([\w.-]+/[\w.-]+)@([a-f0-9]{40})',path.read_text()):
            try:
                advisories=cache[repo] if repo in cache else repository_advisories(repo)
                for advisory in advisories:
                    if advisory.get('withdrawn_at'):continue
                    for vuln in advisory.get('vulnerabilities',[]):
                        patched=vuln.get('patched_versions')
                        safe=vendor_is_patched(repo,revision,patched) if patched else None
                        if not safe:report['findings'].append({'id':advisory['ghsa_id'],'component':repo,'version':revision,'scope':'github-actions','severity':advisory.get('severity','unknown'),'status':'needs-review','url':advisory['html_url']})
            except (ValueError,KeyError) as error:report['errors'].append(str(error))


def run(include_release=None):
    report={'schemaVersion':1,'checkedAt':dt.datetime.now(dt.timezone.utc).isoformat(),'findings':[],'errors':[],'upstreamReleases':{}}
    cache={}
    try:scan_runtime(module.inventory(require_binary=False),'current-source',report,cache)
    except (ValueError,OSError) as error:report['errors'].append(str(error))
    if include_release:
        try:
            tag,items=released_inventory(include_release)
            report['releaseTag']=tag;scan_runtime(items,'released-app',report,cache)
        except Exception as error:report['errors'].append('Released inventory unavailable: '+type(error).__name__)
    for function in [scan_npm,scan_verifier]:
        try:function(report)
        except Exception as error:report['errors'].append(function.__name__+' unavailable: '+type(error).__name__)
    scan_actions(report,cache)
    unique={json.dumps(f,sort_keys=True):f for f in report['findings']}
    report['findings']=[unique[k] for k in sorted(unique)]
    try:apply_exceptions(report,json.loads((ROOT/'Config/Security/exceptions.json').read_text()))
    except (ValueError,KeyError,OSError) as error:report['errors'].append('Invalid exception configuration: '+str(error))
    report['scanStatus']='failed' if report['errors'] else 'complete'
    return report


def apply_exceptions(report, document, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    if document.get('schemaVersion') != 1:
        raise ValueError('Unsupported exception schema')
    for finding in report['findings']:
        for exception in document.get('exceptions', []):
            if all(finding.get(k) == exception.get(k) for k in ['id','component','version','scope']):
                expires = dt.datetime.fromisoformat(exception['expiresAt'])
                accepted = dt.datetime.fromisoformat(exception['acceptedAt'])
                if expires.tzinfo is None or accepted.tzinfo is None:
                    raise ValueError('Exception timestamps must include timezone')
                if exception['scope'] != 'development' or not exception.get('acceptedBy') or not exception.get('reason'):
                    raise ValueError('Exception requires an explicit development-scope acceptance')
                if not 0 < (expires-accepted).total_seconds() <= 31*86400:
                    raise ValueError('Exception duration exceeds 31 days')
                finding['exceptionExpired'] = now >= expires
                finding['acceptedRisk'] = accepted <= now < expires
                finding['exceptionExpiresAt'] = exception['expiresAt']


def blocking(report):
    return bool(report['errors'] or any(f['scope']!='released-app' and not f.get('acceptedRisk',False) and (f['status']=='needs-review' or f['severity'] not in ['low','info']) for f in report['findings']))


def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--include-release');p.add_argument('--monitor',action='store_true');p.add_argument('--previous',type=Path)
    args=p.parse_args();report=run(args.include_release)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    previous=json.loads(args.previous.read_text()) if args.previous and args.previous.exists() else None
    report['lastSuccessfulScanAt']=report['checkedAt'] if not report['errors'] else (previous or {}).get('lastSuccessfulScanAt')
    report['stalePreviousScan']=bool(previous and previous.get('lastSuccessfulScanAt') and (dt.datetime.now(dt.timezone.utc)-dt.datetime.fromisoformat(previous['lastSuccessfulScanAt'])).total_seconds()>48*3600)
    fingerprint=lambda r:json.dumps({k:r.get(k) for k in ['findings','errors','upstreamReleases','releaseTag','stalePreviousScan']},sort_keys=True)
    changed=previous is None or fingerprint(previous)!=fingerprint(report)
    report['changed']=changed
    args.output.write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
    print(json.dumps({'status':report['scanStatus'],'findings':len(report['findings']),'errors':len(report['errors']),'changed':changed,'release':report.get('releaseTag')}))
    if args.monitor:
        return int(changed and bool(report['findings'] or report['errors'] or (previous and report['upstreamReleases']!=previous.get('upstreamReleases')) or report['stalePreviousScan']))
    return int(blocking(report))

if __name__=='__main__':sys.exit(main())
