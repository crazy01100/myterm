#!/usr/bin/env python3
"""Read-only dependency audit. Query failures and unknown ranges are not a pass."""
import argparse
import base64
import copy
import datetime as dt
import importlib.util
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.request
from urllib.parse import urlencode
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
_tool_spec = importlib.util.spec_from_file_location('python_toolchain', ROOT / 'scripts/python-toolchain.py')
python_tools = importlib.util.module_from_spec(_tool_spec)
_tool_spec.loader.exec_module(python_tools)

spec=importlib.util.spec_from_file_location('inventory',ROOT/'scripts/dependency-inventory.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)


def gh(path):
    result=subprocess.run([str(Path(__file__).resolve().parent/'project-gh.sh'),'api',path],capture_output=True,text=True,timeout=60)
    if result.returncode:raise ValueError('GitHub API request failed: '+path.split('?')[0])
    return json.loads(result.stdout)


def get_json(url,payload=None):
    data=None if payload is None else json.dumps(payload).encode()
    req=urllib.request.Request(url,data=data,headers={'Content-Type':'application/json','User-Agent':'MyTerm-security-audit'})
    with urllib.request.urlopen(req,timeout=45,context=python_tools.https_context(ROOT)) as response:
        raw=response.read(8*1024*1024+1)
    if len(raw)>8*1024*1024:raise ValueError('Advisory response too large')
    return json.loads(raw)


def affected(version,expression):
    # GitHub ranges use comparators. Unknown syntax is sent for review, never ignored.
    def number(s, *, boundary=False):
        match=re.fullmatch(r'(v?\d+(?:\.\d+){0,2})(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?',s)
        if not match or match[2] and not boundary:raise ValueError('Unknown version format')
        values=tuple(map(int,match[1].lstrip('v').split('.')))
        # Stable releases sort after prereleases at the same numeric core.
        # The caller keeps ambiguous prerelease-to-prerelease ordering pending.
        return values+(0,)*(3-len(values))+(0 if match[2] else 1,)
    try:
        if not isinstance(expression,str):return None
        current=number(version,boundary=True)
        if expression.strip()=='*':return True
        answers=[]
        for branch in expression.split('||'):
            pattern=r'(>=|<=|>|<|=)?\s*(v?\d+(?:\.\d+){0,2}(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)'
            tokens=re.findall(pattern,branch)
            remainder=re.sub(pattern, '', branch)
            if not tokens or remainder.strip(' ,'):return None
            # Distinct numeric cores can be ordered even for prereleases.
            # Two prerelease suffixes at the same core need npm's full ordering;
            # retain review rather than guessing their lexical/numeric order.
            if current[-1]==0 and any(number(value,boundary=True)[:3]==current[:3]
                    and number(value,boundary=True)[-1]==0 for _,value in tokens):return None
            answers.append(all({'=':current==number(value,boundary=True),'>':current>number(value,boundary=True),'<':current<number(value,boundary=True),'>=':current>=number(value,boundary=True),'<=':current<=number(value,boundary=True)}[op or '='] for op,value in tokens))
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
                        report['findings'].append({'id':advisory['ghsa_id'],'component':repo,'version':component.get('version',component.get('revision')),'scope':scope,'severity':advisory.get('severity','unknown'),'status':'affected' if match else 'needs-review','url':advisory['html_url'],'fixedVersion':vuln.get('patched_versions')})
        except (ValueError,KeyError,subprocess.TimeoutExpired) as error:
            report['errors'].append(str(error))


def github_npm_advisories(packages):
    # npm's audit feed can lag behind GitHub-reviewed advisories. Query all
    # installed package/version identities in bounded public batches as well.
    identities=sorted({key.rsplit('node_modules/',1)[-1]+'@'+item['version']
                       for key,item in packages.items() if key and 'version' in item})
    batches=[identities[i:i+40] for i in range(0,len(identities),40)]
    def fetch(batch):
        endpoint='/advisories?'+urlencode({'ecosystem':'npm','affects':','.join(batch),'per_page':100})
        result=subprocess.run([str(Path(__file__).resolve().parent/'project-gh.sh'),'api','--paginate','--slurp',endpoint],capture_output=True,text=True,timeout=120)
        if result.returncode or len(result.stdout)>16*1024*1024:
            raise ValueError('GitHub npm advisory lookup failed')
        pages=json.loads(result.stdout)
        if not isinstance(pages,list) or not pages or any(not isinstance(page,list) for page in pages):
            raise ValueError('Invalid GitHub advisory pages')
        return [item for page in pages for item in page]
    found={}
    with ThreadPoolExecutor(max_workers=4) as pool:
        for rows in pool.map(fetch,batches):
            for row in rows:
                if not isinstance(row,dict):raise ValueError('Invalid GitHub advisory entry')
                if row.get('withdrawn_at'):continue
                if (any(not isinstance(row.get(key),str) or not row[key] for key in ['ghsa_id','severity','html_url'])
                    or not isinstance(row.get('vulnerabilities'),list) or not row['vulnerabilities']):
                    raise ValueError('Incomplete GitHub advisory entry')
                found[row['ghsa_id']]=row
    return list(found.values())


def withdrawn_npm_advisory(finding, advisory):
    """A stale npm entry is excluded only with positive official evidence."""
    if advisory.get('ghsa_id') != finding['id']:
        raise ValueError('Advisory identity mismatch')
    if 'withdrawn_at' not in advisory:
        raise ValueError('Missing official advisory withdrawal status')
    if advisory['withdrawn_at'] is None:
        return None
    when = dt.datetime.fromisoformat(advisory['withdrawn_at'])
    if when.tzinfo is None or when > dt.datetime.now(dt.timezone.utc):
        raise ValueError('Invalid official withdrawal date')
    if not any(row.get('package') == {'ecosystem':'npm','name':finding['component']}
               for row in advisory.get('vulnerabilities', [])):
        raise ValueError('Withdrawn advisory package mismatch')
    return {'id':finding['id'], 'component':finding['component'],
            'withdrawnAt':advisory['withdrawn_at'],
            'url':'https://github.com/advisories/'+finding['id'], 'source':'GitHub Advisory Database'}


def scan_npm(report):
    lock_hash=hashlib.sha256((ROOT/'package-lock.json').read_bytes()).hexdigest()
    result=subprocess.run([str(ROOT/'scripts/project-node.sh'),'--npm','audit','--package-lock-only','--ignore-scripts','--json'],cwd=ROOT,capture_output=True,text=True,timeout=180,env={**os.environ,'npm_config_cache':str(ROOT/'.npm-cache')})
    data=json.loads(result.stdout)
    if data.get('error') or 'metadata' not in data:raise ValueError('npm audit unavailable')
    report['npmCounts']=data['metadata']['vulnerabilities']
    packages=json.loads((ROOT/'package-lock.json').read_text())['packages']
    details_spec=importlib.util.spec_from_file_location('risk_context',ROOT/'scripts/security-risk-context.py')
    details=importlib.util.module_from_spec(details_spec);details_spec.loader.exec_module(details)
    cache={};findings={}
    for node in data.get('vulnerabilities',{}).values():
        for advisory in node['via']:
            if isinstance(advisory,dict):
                versions=sorted({packages[n]['version'] for n in node['nodes'] if affected(packages[n]['version'],advisory.get('range','')) is not False})
                if not versions: continue
                finding={'id':advisory['url'].split('/')[-1],'component':advisory['name'],'version':','.join(versions),'scope':'development','severity':advisory['severity'],'status':'needs-review' if any(affected(v,advisory.get('range','')) is None for v in versions) else 'affected','url':advisory['url']}
                key=(finding['id'],finding['component'])
                if key in findings:
                    if findings[key]['status']=='needs-review':finding['status']='needs-review'
                    finding['version']=','.join(sorted(set(versions+findings[key]['version'].split(','))))
                findings[key]=finding
    versions_by_name={}
    for key,item in packages.items():
        if key and 'version' in item:
            versions_by_name.setdefault(key.rsplit('node_modules/',1)[-1],set()).add(item['version'])
    for advisory in github_npm_advisories(packages):
        cache[advisory['ghsa_id']]=advisory
        for vulnerability in advisory.get('vulnerabilities',[]):
            package=vulnerability.get('package',{});name=package.get('name')
            if package.get('ecosystem')!='npm' or name not in versions_by_name:continue
            matches={v:affected(v,vulnerability.get('vulnerable_version_range','')) for v in versions_by_name[name]}
            versions=sorted(v for v,match in matches.items() if match is not False)
            if not versions:continue
            finding={'id':advisory['ghsa_id'],'component':name,'version':','.join(versions),'scope':'development',
                     'severity':'moderate' if advisory['severity']=='medium' else advisory['severity'],
                     'status':'needs-review' if any(matches[v] is None for v in versions) else 'affected',
                     'url':advisory['html_url']}
            key=(finding['id'],name)
            if key in findings:
                finding['version']=','.join(sorted(set(versions+findings[key]['version'].split(','))))
                if findings[key]['status']=='needs-review':finding['status']='needs-review'
            findings[key]=finding
    report['npmAdvisorySources']=['npm audit','GitHub Advisory Database (all locked package versions)']
    for finding in findings.values():
        if re.fullmatch(r'GHSA-[a-z0-9-]+', finding['id']):
            if finding['id'] not in cache:
                cache[finding['id']] = gh('advisories/' + finding['id'])
            withdrawn = withdrawn_npm_advisory(finding, cache[finding['id']])
            if withdrawn:
                report.setdefault('withdrawnAdvisories', []).append(withdrawn)
                continue
        report['findings'].append(details.enrich(finding,gh,affected,cache=cache))
    if hashlib.sha256((ROOT/'package-lock.json').read_bytes()).hexdigest()!=lock_hash:
        raise ValueError('npm lock changed during advisory lookup')
    report.setdefault('parentQueries',[]).append({'collector':'npm-project','sources':['npm audit','GitHub global advisories'],
        'lockSHA256':lock_hash,'checkedAt':dt.datetime.now(dt.timezone.utc).isoformat(),'status':'complete'})


def scan_verifier(report):
    requirements=(ROOT/'Tests/Security/requirements.txt').read_text()
    observations = {}
    def observe(name, version, origin):
        # Normalize date versions as PyPI does, without loading vendored code.
        if re.fullmatch(r'[0-9]+(?:\.[0-9]+)+', version):
            version='.'.join(str(int(part)) for part in version.split('.'))
        observations.setdefault((name,version),set()).add(origin)
    for name,version in re.findall(r'^([\w-]+)==([\w.]+)',requirements,re.M):
        observe(name,version,'pinned verification requirements')
    policy=python_tools.configuration(ROOT)
    for name,row in policy['packages'].items():
        observe(name,row['version'],'reviewed bootstrap source')
    observe('certifi',policy['packages']['pip']['vendoredCertifi'],'reviewed pip → vendored certifi')
    environments=python_tools.inventory(ROOT)
    report['pythonTooling']={'environments':environments,'advisoryScope':'source pins and current runner environments; not other Macs',
                            'networkCA':'reviewed standalone certifi for project Python HTTPS',
                            'caSHA256':policy['packages']['certifi']['caSHA256'],
                            'caBundles':{origin:{'version':version,'caSHA256':pin['caSHA256']}
                                for origin,version,pin in [('certifi',policy['packages']['certifi']['version'],policy['packages']['certifi']),
                                    ('pip/_vendor/certifi',policy['packages']['pip']['vendoredCertifi'],policy['packages']['pip'])]}}
    for env in environments:
        origins={row['origin'] for row in env['packages']}
        if not {'pip','certifi','pip/_vendor/certifi'} <= origins:
            raise ValueError('Incomplete managed Python environment: '+env['role'])
        for row in env['packages']:
            observe(row['name'],row['version'],('current CI runner / ' if os.environ.get('GITHUB_ACTIONS')=='true' else 'local checkout / ')+env['role']+' → '+row['origin'])
            # A known old version is a finding, not missing evidence. A claimed
            # current version with altered certificates is an operational error.
            if row['name']=='certifi':
                origin=row['origin']
                if origin not in ('certifi','pip/_vendor/certifi'):
                    raise ValueError('Unknown certificate origin: '+origin)
                pin=policy['packages']['pip' if origin=='pip/_vendor/certifi' else 'certifi']
                expected=pin['vendoredCertifi'] if origin=='pip/_vendor/certifi' else pin['version']
                if row['version']==expected and row.get('caSHA256')!=pin['caSHA256']:
                    raise ValueError('CA content differs from reviewed version: '+env['role']+' / '+origin)
    grouped={}
    for (name,version),origins in sorted(observations.items()):
        result=get_json('https://api.osv.dev/v1/query',{'package':{'ecosystem':'PyPI','name':name},'version':version})
        for advisory in result.get('vulns',[]):
            if advisory.get('withdrawn'):continue
            aliases=[advisory['id'],*advisory.get('aliases',[])]
            identifier=next((x for x in sorted(aliases) if x.startswith('GHSA-')),advisory['id'])
            key=(identifier,name)
            severity=advisory.get('database_specific',{}).get('severity','unknown').lower()
            if severity not in ('critical','high','moderate','medium','low','info'):severity='unknown'
            entry=grouped.setdefault(key,{'versions':set(),'origins':set(),'fixed':set(),'severity':severity})
            if entry['severity']!=severity:entry['severity']='unknown'  # Never downgrade conflicting sources.
            entry['versions'].add(version);entry['origins'].update(origins)
            for affected_row in advisory.get('affected',[]):
                if affected_row.get('package',{}).get('name')!=name:continue
                for ran in affected_row.get('ranges',[]):
                    for event in ran.get('events',[]):
                        if event.get('fixed'):entry['fixed'].add(event['fixed'])
    for (identifier,name),entry in sorted(grouped.items()):
        url=('https://github.com/advisories/'+identifier if identifier.startswith('GHSA-') else 'https://osv.dev/vulnerability/'+identifier)
        finding={'id':identifier,'component':name,'version':','.join(sorted(entry['versions'])),
                 'scope':'verification-tool','severity':entry['severity'],'status':'affected','url':url,
                 'dependencyPaths':sorted(entry['origins'])}
        if entry['fixed']:finding['fixedVersion']=', '.join(sorted(entry['fixed']))
        report['findings'].append(finding)


def scan_actions(report,cache):
    references=set();errors_before=len(report['errors'])
    workflows={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT/'.github/workflows').glob('*.yml'))}
    for path in sorted((ROOT/'.github/workflows').glob('*.yml')):
        for repo,revision in re.findall(r'uses:\s*([\w.-]+/[\w.-]+)@([a-f0-9]{40})',path.read_text()):
            if (repo,revision) in references:continue
            references.add((repo,revision))
            try:
                advisories=cache[repo] if repo in cache else repository_advisories(repo)
                cache[repo]=advisories
                for advisory in advisories:
                    if advisory.get('withdrawn_at'):continue
                    for vuln in advisory.get('vulnerabilities',[]):
                        patched=vuln.get('patched_versions')
                        safe=vendor_is_patched(repo,revision,patched) if patched else None
                        if not safe:report['findings'].append({'id':advisory['ghsa_id'],'component':repo,'version':revision,'scope':'github-actions','severity':advisory.get('severity','unknown'),'status':'needs-review','url':advisory['html_url'],'fixedVersion':vuln.get('patched_versions')})
            except (ValueError,KeyError,subprocess.SubprocessError) as error:report['errors'].append(str(error))
    current={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT/'.github/workflows').glob('*.yml'))}
    if current!=workflows:report['errors'].append('Workflows changed during action advisory lookup')
    if len(report['errors'])==errors_before:
        report.setdefault('parentQueries',[]).append({'collector':'actions','sources':['GitHub repository advisories'],
            'references':[list(x) for x in sorted(references)],'workflowSHA256':workflows,
            'checkedAt':dt.datetime.now(dt.timezone.utc).isoformat(),'status':'complete'})


def run(include_release=None):
    report={'schemaVersion':1,'checkedAt':dt.datetime.now(dt.timezone.utc).isoformat(),'findings':[],'errors':[],'upstreamReleases':{}}
    report['collectionEvidence']={'schemaVersion':1,
        'baselineCommit':'22c3361bd0cce52086527a979ae61c3201d93763','collectors':[]}
    cache={}
    def attest(start,error_count,collector):
        if len(report['errors'])==error_count:
            for finding in report['findings'][start:]:finding['queryComplete']=True
        record_collection(report,collector,start,len(report['errors'])==error_count)
    start=len(report['findings']);error_count=len(report['errors'])
    try:
        source_files=('Package.swift','Package.resolved','Vendor/SwiftTerm/UPSTREAM.md','Config/Security/native-components.json')
        hashes={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in source_files}
        scan_runtime(module.inventory(require_binary=False),'current-source',report,cache)
        if hashes!={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in source_files}:
            raise ValueError('Runtime sources changed during query')
        if len(report['errors'])==error_count:
            report.setdefault('parentQueries',[]).append({'collector':'app','sources':['GitHub repository advisories'],
                'sourceSHA256':hashes,'status':'complete','checkedAt':dt.datetime.now(dt.timezone.utc).isoformat()})
    except (ValueError,OSError) as error:report['errors'].append(str(error))
    attest(start,error_count,'app-source')
    if include_release:
        start=len(report['findings']);error_count=len(report['errors'])
        try:
            tag,items=released_inventory(include_release)
            report['releaseTag']=tag;scan_runtime(items,'released-app',report,cache)
        except Exception as error:report['errors'].append('Released inventory unavailable: '+type(error).__name__)
        attest(start,error_count,'released-app')
    for collector,function in [('npm-project',scan_npm),('python-verifier',scan_verifier)]:
        start=len(report['findings']);error_count=len(report['errors'])
        try:
            function(report)
        except Exception as error:report['errors'].append(function.__name__+' unavailable: '+type(error).__name__)
        attest(start,error_count,collector)
    start=len(report['findings']);error_count=len(report['errors'])
    scan_actions(report,cache);attest(start,error_count,'actions-repository')
    start=len(report['findings']);error_count=len(report['errors'])
    try:
        scan_toolchain(report)
    except Exception as error:
        report['errors'].append('Toolchain coverage unavailable: '+type(error).__name__)
    record_collection(report,'expanded-toolchain',start,len(report['errors'])==error_count)
    report['findings']=merge_findings(report['findings'])
    try:
        impact_spec=importlib.util.spec_from_file_location('toolchain_impact',ROOT/'scripts/security-toolchain-impact.py')
        impact=importlib.util.module_from_spec(impact_spec);impact_spec.loader.exec_module(impact)
        impact.annotate(report,ROOT)
    except (OSError,ValueError,KeyError,TypeError) as error:
        report['errors'].append('Toolchain impact evidence unavailable: '+type(error).__name__)
    try:apply_exceptions(report,json.loads((ROOT/'Config/Security/exceptions.json').read_text()))
    except (ValueError,KeyError,OSError) as error:report['errors'].append('Invalid exception configuration: '+str(error))
    try:
        pip_applicability().classify(report,ROOT,gh)
    except Exception as error:
        report['errors'].append('Precise pip applicability unavailable: '+type(error).__name__)
    try:
        spec=importlib.util.spec_from_file_location('source_review',ROOT/'scripts/security-source-review.py')
        policy=importlib.util.module_from_spec(spec);spec.loader.exec_module(policy)
        report['sourceReview']=policy.source_check(ROOT)
    except (ValueError,KeyError,TypeError,OSError) as error:
        report['errors'].append('Security source policy unavailable: '+str(error))
    report['scanStatus']='failed' if report['errors'] else 'complete'
    return report


def query_toolchain_github(npm_components, environment):
    findings=[]
    packages={f"tool-{i}/node_modules/{c['name']}":{'version':c['version']} for i,c in enumerate(npm_components)}
    advisories=github_npm_advisories(packages)
    for advisory in advisories:
        for vulnerability in advisory['vulnerabilities']:
            package=vulnerability.get('package',{})
            if package.get('ecosystem')!='npm':continue
            for component in npm_components:
                if component['name']!=package.get('name'):continue
                match=affected(component['version'],vulnerability.get('vulnerable_version_range',''))
                if match is False:continue
                origin=component['origin']
                findings.append({'id':advisory['ghsa_id'],'component':component['name'],
                    'version':component['version'],'scope':'github-actions' if origin.startswith('action/') else 'development',
                    'severity':'moderate' if advisory['severity']=='medium' else advisory['severity'],
                    'status':'needs-review' if match is None or component.get('runtimeReachability')=='not-established' else 'affected',
                    'url':advisory['html_url'],'fixedVersion':vulnerability.get('first_patched_version') or '',
                    'queryComplete':True,'dependencyPaths':[origin],
                    'environmentObservations':[{'environment':environment,'origin':origin,'versions':[component['version']]}]})
    return {'advisoryQueryStatus':'complete','checkedAt':dt.datetime.now(dt.timezone.utc).isoformat(),
            'componentDigest':provider_digest(npm_components),'findings':findings}

def scan_toolchain(report):
    def load(name):
        spec=importlib.util.spec_from_file_location(name, ROOT/'scripts'/f'{name}.py')
        result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result
    inventory_module=load('security-toolchain-inventory')
    advisory_module=load('security-toolchain-advisories')
    coverage_module=load('security-toolchain-report')
    observed=inventory_module.inventory(ROOT, purpose='audit')
    # A failed provider must not prevent collecting other providers' evidence.
    # Failure remains blocking; completed results are diagnostic, not a waiver.
    queried={'findings':[], 'advisoryQueryStatus':'failed'}
    try:
        queried=advisory_module.grouped_lookup(observed, advisory_module.lookup)
        report['errors'].extend('Toolchain package query: '+e for e in queried['errors'])
    except Exception as error:
        report['errors'].append('Toolchain package query unavailable: '+type(error).__name__)
    github_result={'status':'failed'}
    try:
        github_result=advisory_module.grouped_lookup(observed,
            lambda c:query_toolchain_github(c,observed['environment']),
            include=lambda c:c['ecosystem']=='npm' and c.get('collector')!='npm-project')
        github_result['status']=github_result['advisoryQueryStatus']
        report['findings'].extend(github_result['findings'])
        report['errors'].extend('Toolchain GitHub package query: '+e for e in github_result['errors'])
    except Exception as error:
        report['errors'].append('Toolchain GitHub package query unavailable: '+type(error).__name__)
    report['githubToolchainQuery']=github_result
    report['packageMonitoring']={'schemaVersion':1,'observedEnvironment':observed['environment'],
        'scope':'Enumerated packages used by this project; supplier/native coverage remains separate',
        'osv':{k:v for k,v in queried.items() if k!='findings'},
        'github':{k:v for k,v in github_result.items() if k!='findings'},
        'queriesComplete':queried.get('advisoryQueryStatus')=='complete' and github_result.get('status')=='complete',
        'allDependenciesScanned':False,'grantsRiskException':False}
    report['nativeAdvisories']={'status':'failed'}
    try:
        native=load('security-native-advisories').scan_openssl(observed)
        report['nativeAdvisories']={'status':'complete', **native}
        report['findings'].extend({**f,'queryComplete':True} for f in native['findings'])
    except Exception as error:
        report['errors'].append('Native OpenSSL query unavailable: '+type(error).__name__)
    report['vendorNotices']={'checksComplete':False}
    try:
        notices=load('security-vendor-notices').scan(ROOT)
        report['vendorNotices']=notices
        report['errors'].extend(notices['errors'])
    except Exception as error:
        report['errors'].append('Official notice query unavailable: '+type(error).__name__)
    # Provider/native adapters are independent proofs. No adapter receipt is
    # fabricated from a successful package query or empty findings list.
    provider_module=load('security-toolchain-providers')
    parent_evidence=provider_module.bind_parents(observed,report.get('parentQueries',[]))
    try:
        supplier=load('security-supplier-notices').scan(observed,ROOT)
        report['supplierNotices']=supplier
        report['candidateFindings']=supplier.get('candidateFindings',[])
        report['vendorNotices'].setdefault('changes',[]).extend(supplier.get('notices',[]))
        if supplier.get('notices'):report['vendorNotices']['requiresNoticeReview']=True
        report['findings'].extend(supplier['findings'])
        for receipt in supplier['receipts']:
            parent_evidence[(receipt['collector'],receipt['source'])]=receipt
    except Exception as error:
        report['errors'].append('Supplier notice query unavailable: '+type(error).__name__)
    report['runtimeAdvisories']={}
    for runtime in ('node','python'):
        try:
            runtime_module=load('security-runtime-advisories')
            result=(runtime_module.scan_node(observed,gh) if runtime=='node'
                    else runtime_module.scan_python(observed,gh,advisory_module.get_json))
            report['runtimeAdvisories'][runtime]=result
            parent_evidence[(result['collector'],result['source'])]=result
            report['findings'].extend(result['findings'])
        except Exception as error:
            report['runtimeAdvisories'][runtime]={'status':'failed'}
            report['errors'].append(runtime+' runtime advisory query unavailable: '+type(error).__name__)
    try:
        receipt,findings=provider_module.firestore_notices(observed,inventory_module.configuration(ROOT),
                                                           repository_advisories('firebase/firebase-tools'))
        parent_evidence[('emulator','Firestore vendor advisories')]=receipt
        report['firestoreVendorQuery']=receipt
        report['findings'].extend(findings)
    except Exception as error:
        report['errors'].append('Firestore vendor notice query unavailable: '+type(error).__name__)
    for receipt in github_result.get('domains',[]):
        if receipt['status']=='complete' and receipt['collector'] in ('node','deployment'):
            parent_evidence[(receipt['collector'],'GitHub global advisories')]=receipt
    providers=provider_module.receipts(
        observed, inventory_module.configuration(ROOT), queried, report['nativeAdvisories'],
        report['vendorNotices'], parent_evidence)
    report['providerEvidence']=providers
    coverage=coverage_module.summarize(observed, queried, inventory_module.configuration(ROOT), providers)
    report['toolchainCoverage']=coverage
    domains={d['id']:d for d in coverage['coverage']}
    report['originCoverage']={c['origin']:{'collector':c.get('collector'),
        'closureEligible':domains.get(c.get('collector'),{}).get('closureEligible',False)} for c in observed['components']}
    for source in report['nativeAdvisories'].get('sources',[]):
        report['originCoverage'][source['origin']]={'collector':source['collector'],
            'closureEligible':domains.get(source['collector'],{}).get('closureEligible',False)}
    report['observedEnvironment']=observed['environment']
    report['observedOrigins']=sorted({c['origin'] for c in observed['components']} |
                                   {s['origin'] for s in report['nativeAdvisories'].get('sources',[])})
    if report.get('firestoreVendorQuery',{}).get('status')=='complete':
        report['originCoverage']['emulator/firestore']={'collector':'emulator','closureEligible':False}
        report['observedOrigins']=sorted(set(report['observedOrigins'])|{'emulator/firestore'})
    for result in report['runtimeAdvisories'].values():
        for source in result.get('sources',[]):
            # Version-to-upstream mapping alone does not verify downstream builds.
            report['originCoverage'][source['origin']]={'collector':result['collector'],'closureEligible':False}
            report['observedOrigins']=sorted(set(report['observedOrigins'])|{source['origin']})
    for finding in queried['findings']:
        groups={}
        for observation in finding['observations']:
            origin=observation['origin']
            scope=('verification-tool' if origin.startswith(('python-runtime','security-tools')) else
                   'github-actions' if origin.startswith('action/') else 'development')
            groups.setdefault(scope,{}).setdefault(origin,set()).add(observation['version'])
        for scope,origins in groups.items():
            versions=sorted({v for values in origins.values() for v in values})
            report['findings'].append({'id':finding['id'],'component':finding['component'],'scope':scope,
                'queryComplete':True,
                'version':', '.join(versions),'severity':finding['severity'],'status':finding['status'],
                'url':finding['url'],'fixedVersion':', '.join(finding['fixedVersions']),
                'dependencyPaths':sorted(origins),
                'environmentObservations':[{'environment':observed['environment'],'origin':origin,
                                            'versions':sorted(values)} for origin,values in sorted(origins.items())]})
    report['coverageErrors']=coverage['errors']
    report['coverageGaps']=[{'collector':p['collector'],'source':p['source'],'status':p['status'],'reason':p['reason']}
                            for p in providers if p['status']!='complete']
    if not coverage['checksComplete']:
        report['errors'].append('Toolchain declared coverage is incomplete; no closure or gate authorization')


def provider_digest(value):
    return hashlib.sha256(json.dumps(value,sort_keys=True).encode()).hexdigest()


def merge_findings(findings):
    """One Issue identity, preserving every observed version and tool origin."""
    merged={}
    severity_order={'unknown':6,'critical':5,'high':4,'moderate':3,'medium':3,'low':2,'info':1}
    for finding in findings:
        key=tuple(finding[k] for k in ('id','component','scope'))
        if key not in merged:
            merged[key]=dict(finding)
            continue
        row=merged[key]
        row['queryComplete']=row.get('queryComplete') is True and finding.get('queryComplete') is True
        for field in ('version','fixedVersion'):
            values={s.strip() for f in (row,finding) for s in (f.get(field) or '').split(',') if s.strip()}
            if values:row[field]=', '.join(sorted(values))
        for field in ('dependencyPaths','environmentObservations','patches'):
            values={json.dumps(v,sort_keys=True):v for f in (row,finding) for v in f.get(field,[])}
            if values:row[field]=[values[k] for k in sorted(values)]
        row['severity']=max((row['severity'],finding['severity']),key=lambda s:severity_order.get(s,6))
        if finding['status']=='needs-review':row['status']='needs-review'
    return [merged[key] for key in sorted(merged)]


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


def pip_applicability():
    spec=importlib.util.spec_from_file_location('pip_applicability',ROOT/'scripts/security-pip-applicability.py')
    helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper);return helper


BASELINE_COLLECTORS=frozenset(('app-source','npm-project','python-verifier','actions-repository'))
RISK_FIELDS=('id','component','version','scope','severity','status','url','fixedVersion')


def risk_projection(finding):
    return {key:finding.get(key) for key in RISK_FIELDS}


def record_collection(report,collector,start,complete):
    # The audit dispatcher assigns provenance, not advisory data or an ID allowlist.
    # Snapshot before aggregation, applicability notes or exceptions can alter rows.
    report['collectionEvidence']['collectors'].append({'collector':collector,
        'status':'complete' if complete else 'failed',
        'findings':[risk_projection(f) for f in report['findings'][start:]]})


def baseline_findings(report):
    """Validate the fresh scan's partition, then evaluate original collectors.

    This is traceability evidence, not a signature or authorization to consume
    arbitrary reports. The CLI always scans in-process; protected source/PR review
    governs changes to this dispatcher and the merge workflow.
    """
    if (report.get('toolchainCoverage',{}).get('checksComplete') is not True or
            report.get('packageMonitoring',{}).get('queriesComplete') is not True or
            report.get('vendorNotices',{}).get('checksComplete') is not True):
        raise ValueError('Expanded monitoring did not complete')
    evidence=report['collectionEvidence']
    if evidence.get('schemaVersion')!=1 or evidence.get('baselineCommit')!='22c3361bd0cce52086527a979ae61c3201d93763':
        raise ValueError('Missing baseline collector evidence')
    rows=evidence['collectors'];names=[r['collector'] for r in rows]
    expected=BASELINE_COLLECTORS|{'expanded-toolchain'}|({'released-app'} if report.get('releaseTag') else set())
    if len(names)!=len(set(names)) or set(names)!=expected or any(r['status']!='complete' for r in rows):
        raise ValueError('Incomplete collector partition')
    raw=report.get('rawFindings',report['findings'])
    collected=merge_findings([f for row in rows for f in row['findings']])
    project=lambda items:sorted(json.dumps(risk_projection(f),sort_keys=True) for f in items)
    if project(collected)!=project(raw):
        raise ValueError('Risk report differs from collector evidence')
    # Do not let an expanded collector's matching ID/version, subset decision,
    # or annotation remove an original collector's independent finding.
    original={'findings':merge_findings([copy.deepcopy(f) for row in rows
                                       if row['collector'] in BASELINE_COLLECTORS for f in row['findings']])}
    apply_exceptions(original,json.loads((ROOT/'Config/Security/exceptions.json').read_text()))
    return original['findings']


def blocking(report, *, merge_gate=False):
    if (report['errors'] or report.get('conditionalBlocks') or report.get('coverageErrors')
            or report.get('coverageGaps') or
            ('toolchainCoverage' in report and report['toolchainCoverage'].get('checksComplete') is not True)):
        return True
    try:
        findings=baseline_findings(report) if merge_gate else report['findings']
    except (KeyError,ValueError,TypeError,OSError):return True
    if (not merge_gate and report.get('vendorNotices',{}).get('requiresNoticeReview') or
            any(f['scope']!='released-app' and not f.get('acceptedRisk',False) and
                (f['status']=='needs-review' or f['severity'] not in ['low','info']) for f in findings)):
        return True
    # An exclusion in JSON is not authority to pass a gate. Recheck the exact
    # sources and live advisory before allowing an otherwise clean scan.
    try:pip_applicability().revalidate(report,ROOT,gh)
    except Exception:return True
    return False


def write_summary(report, monitor, *, merge_gate=False):
    path = os.environ.get('GITHUB_STEP_SUMMARY')
    if not path:
        return
    import html
    evaluated=report.get('gateEvaluation')
    gate_blocked=(evaluated['blocking'] if evaluated is not None else
                  False if monitor else blocking(report,merge_gate=merge_gate))
    if report['errors']:
        title = '安全檢查運作異常：本次無法判定完整結果'
    elif monitor:
        title = f"掃描完成：發現 {len(report['findings'])} 項風險，交由 Issue 追蹤"
    elif gate_blocked:
        title = ('合併' if merge_gate else '發布')+'安全門檻未通過'
    else:
        title = ('合併' if merge_gate else '發布')+'安全門檻通過'
    lines = ['## '+title, '', '掃描成功不等於沒有漏洞；正式版風險與目前來源分別記錄。', '']
    if merge_gate:
        lines += ['合併保留既有 App、根 npm、Python 驗簽與 Actions 本體門檻；擴充工具風險仍告警，查詢／覆蓋失敗仍阻擋。此結果不授權發布或部署。', '']
    packages = report.get('packageMonitoring', {})
    if packages:
        lines += ['### 專案套件查詢', '']
        for source in ('osv', 'github'):
            for domain in packages.get(source, {}).get('domains', []):
                if domain.get('status') in ('not-applicable', 'not-package-enumerable'):
                    continue
                detail = f"{source} / {domain['collector']}: {domain['status']} ({domain['packageIdentities']})"
                lines.append('- '+html.escape(detail))
        lines.append('')
    for finding in report['findings']:
        detail = '／'.join(str(finding.get(k, '')) for k in ['severity', 'component', 'version', 'scope', 'id'])
        lines.append('- '+html.escape(detail))
    for review in report.get('applicabilityReviews',[]):
        lines.append('- 精確封裝不適用（原版本命中保留）：'+html.escape(review['finding']['id']))
    for error in report['errors']:
        lines.append('- 運作異常：'+html.escape(str(error)))
    for notice in report.get('vendorNotices',{}).get('changes',[]):
        lines.append('- 官方公告待確認：'+html.escape(notice['title'])+' — '+html.escape(notice['url']))
    if report.get('stalePreviousScan'):
        lines.append('- 前次成功掃描距今超過 48 小時；本次結果請依上方狀態判讀。')
    with open(path, 'a') as output:
        output.write('\n'.join(lines)+'\n')


def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--include-release');p.add_argument('--previous',type=Path)
    mode=p.add_mutually_exclusive_group()
    mode.add_argument('--monitor',action='store_true')
    mode.add_argument('--merge-gate',action='store_true',help='Preserve original collector risk gates; expanded risks remain monitored. Not for release/deploy.')
    args=p.parse_args();report=run(args.include_release)
    gate_blocked=blocking(report,merge_gate=args.merge_gate) if not args.monitor else bool(report['errors'])
    report['gateEvaluation']={'purpose':'monitor' if args.monitor else 'merge' if args.merge_gate else 'release',
        'blocking':gate_blocked,'grantsRiskException':False,'authorizesRelease':False}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    previous=json.loads(args.previous.read_text()) if args.previous and args.previous.exists() else None
    report['lastSuccessfulScanAt']=report['checkedAt'] if not report['errors'] else (previous or {}).get('lastSuccessfulScanAt')
    report['stalePreviousScan']=bool(previous and previous.get('lastSuccessfulScanAt') and (dt.datetime.now(dt.timezone.utc)-dt.datetime.fromisoformat(previous['lastSuccessfulScanAt'])).total_seconds()>48*3600)
    fingerprint=lambda r:json.dumps({**{k:r.get(k) for k in ['findings','rawFindings','applicabilityReviews','errors','upstreamReleases','releaseTag','stalePreviousScan','toolchainCoverage','packageMonitoring','observedEnvironment','observedOrigins']},
        'noticeChanges':r.get('vendorNotices',{}).get('changes',[])},sort_keys=True)
    changed=previous is None or fingerprint(previous)!=fingerprint(report)
    report['changed']=changed
    args.output.write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
    print(json.dumps({'status':report['scanStatus'],'findings':len(report['findings']),'errors':len(report['errors']),'changed':changed,'release':report.get('releaseTag')}))
    write_summary(report, args.monitor, merge_gate=args.merge_gate)
    return int(gate_blocked)

if __name__=='__main__':sys.exit(main())
