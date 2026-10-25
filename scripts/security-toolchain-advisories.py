#!/usr/bin/env python3
"""Read-only advisory lookup for explicit component identities.

An empty findings list never upgrades missing inventory or native coverage.
"""
from concurrent.futures import ThreadPoolExecutor
import datetime as dt
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import urllib.request

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('python_toolchain',ROOT/'scripts/python-toolchain.py')
tools=importlib.util.module_from_spec(spec);spec.loader.exec_module(tools)
ECOSYSTEMS={'PyPI','npm','crates.io','Maven','Go'}


def get_json(url,payload=None):
    data=None if payload is None else json.dumps(payload).encode()
    request=urllib.request.Request(url,data=data,headers={'Content-Type':'application/json','User-Agent':'MyTerm-coverage-audit'})
    with urllib.request.urlopen(request,context=tools.https_context(ROOT),timeout=45) as response:
        raw=response.read(8*1024*1024+1)
    if len(raw)>8*1024*1024:raise ValueError('Advisory response exceeds limit')
    return json.loads(raw)


def identities(components):
    result={}
    for c in components:
        if c.get('ecosystem') not in ECOSYSTEMS:raise ValueError('Unsupported ecosystem cannot be silently skipped')
        version=c['version']
        if c['ecosystem']=='PyPI' and re.fullmatch(r'[0-9]+(?:\.[0-9]+)+',version):
            version='.'.join(str(int(x)) for x in version.split('.'))
        key=(c['ecosystem'],c['name'],version)
        result.setdefault(key,[]).append(c)
    if len(result)>10000:raise ValueError('Too many package identities')
    return result


def component_digest(components):
    return hashlib.sha256(json.dumps(components, sort_keys=True).encode()).hexdigest()


def grouped_lookup(inventory, query, *, include=lambda c: True):
    """Isolate actual collector failures while retaining each successful query.

    Not-applicable and non-package domains are recorded, never passed to query
    as an empty inventory. No result grants closure or a risk exception.
    """
    coverage = inventory['coverage']
    domains = {row['id']: row for row in coverage}
    if len(domains) != len(coverage):
        raise ValueError('Duplicate query domains')
    components = [c for c in inventory['components'] if include(c)]
    if any(c.get('collector') not in domains for c in components):
        raise ValueError('Package has no inventory domain')
    results = []; findings = []; errors = []; withdrawals = set()
    for name, domain in domains.items():
        selected = [c for c in components if c['collector'] == name]
        receipt = {'collector': name, 'componentDigest': component_digest(selected),
                   'coverageDigest': component_digest(domain),
                   'observedEnvironment': inventory['environment'],
                   'origins': sorted({c['origin'] for c in selected}),
                   'packageIdentities': len(identities(selected)),
                   'closureEligible': False}
        if domain.get('status') == 'not-applicable' and not selected:
            receipt['status'] = 'not-applicable'
        elif domain.get('status') not in ('inventoried', 'supplier-managed-limited'):
            receipt.update(status='unavailable', error='InventoryUnavailable')
            errors.append(name + ': inventory unavailable')
        elif not selected:
            receipt['status'] = 'not-package-enumerable'
        else:
            try:
                result = query(selected)
                if (result.get('advisoryQueryStatus') != 'complete'
                        or result.get('componentDigest') != receipt['componentDigest']
                        or not isinstance(result.get('findings'), list)):
                    raise ValueError('Query does not match this domain')
                stamp = dt.datetime.fromisoformat(result['checkedAt'])
                age = (dt.datetime.now(dt.timezone.utc)-stamp).total_seconds()
                if stamp.tzinfo is None or not 0 <= age <= 48*3600:
                    raise ValueError('Query timestamp is stale or invalid')
                receipt.update(status='complete', checkedAt=result['checkedAt'],
                               findingCount=len(result['findings']))
                findings.extend(result['findings'])
                withdrawals.update(result.get('withdrawnAdvisories', []))
            except Exception as error:
                # No subprocess output, package input or local paths in errors.
                receipt.update(status='failed', error=type(error).__name__)
                errors.append(name + ': ' + type(error).__name__)
        results.append(receipt)
    return {'schemaVersion': 1, 'checkedAt': dt.datetime.now(dt.timezone.utc).isoformat(),
            'observedEnvironment': inventory['environment'],
            'advisoryQueryStatus': 'failed' if errors else 'complete',
            'componentDigest': component_digest(components),
            'queriedIdentities': sum(r['packageIdentities'] for r in results if r['status']=='complete'),
            'domains': results, 'findings': findings, 'errors': errors,
            'withdrawnAdvisories': sorted(withdrawals),
            'allDependenciesScanned': False, 'closureEligible': False}


def lookup(components,fetch=get_json):
    observed=identities(components);keys=sorted(observed)
    batches=[keys[i:i+100] for i in range(0,len(keys),100)]
    def query(batch):
        queries=[{'package':{'ecosystem':e,'name':n},'version':v} for e,n,v in batch]
        response=fetch('https://api.osv.dev/v1/querybatch',{'queries':queries})
        if not isinstance(response,dict) or not isinstance(response.get('results'),list) or len(response['results'])!=len(batch):
            raise ValueError('Incomplete advisory batch')
        result=[]
        for key,row in zip(batch,response['results']):
            if not isinstance(row,dict) or row.get('next_page_token'):
                raise ValueError('Incomplete advisory pagination')
            vulns=row.get('vulns',[])
            if not isinstance(vulns,list):raise ValueError('Malformed vulnerability list')
            for item in vulns:
                identifier=item.get('id')
                if not isinstance(identifier,str) or not re.fullmatch('[A-Za-z0-9_.-]{1,200}',identifier):
                    raise ValueError('Invalid advisory identity')
                result.append((key,identifier))
        return result
    matches=[]
    with ThreadPoolExecutor(max_workers=4) as pool:
        for rows in pool.map(query,batches):matches.extend(rows)
    ids=sorted({identifier for _,identifier in matches})
    if len(ids)>1000:raise ValueError('Too many matched advisories')
    def details(identifier):
        row=fetch('https://api.osv.dev/v1/vulns/'+identifier)
        if not isinstance(row,dict) or row.get('id')!=identifier or not isinstance(row.get('affected'),list):
            raise ValueError('Incomplete advisory details')
        return identifier,row
    with ThreadPoolExecutor(max_workers=4) as pool:details_by_id=dict(pool.map(details,ids))
    findings={};withdrawn=[]
    for key,identifier in matches:
        row=details_by_id[identifier]
        if row.get('withdrawn'):
            timestamp=dt.datetime.fromisoformat(row['withdrawn'])
            if timestamp.tzinfo is None or timestamp>dt.datetime.now(dt.timezone.utc):raise ValueError('Invalid withdrawal metadata')
            withdrawn.append(identifier);continue
        aliases=row.get('aliases',[])
        if not isinstance(aliases,list) or any(not isinstance(a,str) for a in aliases):raise ValueError('Malformed advisory aliases')
        preferred=next((a for a in sorted([identifier,*aliases]) if re.fullmatch('GHSA-[a-z0-9-]+',a)),identifier)
        eco,name,version=key
        affected=[x for x in row['affected'] if x.get('package',{}).get('ecosystem')==eco and x.get('package',{}).get('name')==name]
        # PyPI source spellings may differ only in standardized separators.
        if eco=='PyPI' and not affected:
            norm=lambda s:re.sub('[-_.]+','-',s).lower()
            affected=[x for x in row['affected'] if x.get('package',{}).get('ecosystem')==eco and norm(x.get('package',{}).get('name',''))==norm(name)]
        if not affected:raise ValueError('Matched advisory has no matching package identity')
        severity=row.get('database_specific',{}).get('severity','unknown').lower()
        if severity=='medium':severity='moderate'
        if severity not in ('critical','high','moderate','low','info'):severity='unknown'
        group=findings.setdefault((preferred,eco,name),{'id':preferred,'ecosystem':eco,'component':name,'versions':set(),
            'origins':set(),'observations':set(),'severity':severity,'status':'affected','fixedVersions':set(),
            'url':'https://github.com/advisories/'+preferred if preferred.startswith('GHSA-') else 'https://osv.dev/vulnerability/'+preferred})
        if group['severity']!=severity:group['severity']='unknown'
        group['versions'].add(version)
        for c in observed[key]:
            group['origins'].add(c['origin'])
            group['observations'].add((c['origin'],version))
            if c.get('runtimeReachability')=='not-established':group['status']='needs-review'
        for a in affected:
            for ran in a.get('ranges',[]):
                if ran.get('type') not in ('SEMVER','ECOSYSTEM'):
                    continue  # Git commit fixes are not package patch versions.
                for event in ran.get('events',[]):
                    if isinstance(event.get('fixed'),str):group['fixedVersions'].add(event['fixed'])
    output=[]
    for key,row in sorted(findings.items()):
        item={k:sorted(v) if isinstance(v,set) else v for k,v in row.items()}
        item['observations']=[{'origin':origin,'version':version} for origin,version in sorted(row['observations'])]
        output.append(item)
    return {'schemaVersion':1,'checkedAt':dt.datetime.now(dt.timezone.utc).isoformat(),'advisoryQueryStatus':'complete',
            'componentDigest':component_digest(components),
            'queriedIdentities':len(keys),'findings':output,'withdrawnAdvisories':sorted(set(withdrawn)),
            'scope':'Explicit package identities only; not native/vendor coverage or proof of exploitability'}
