#!/usr/bin/env python3
"""Read-only Node core and upstream CPython commit advisory queries.

Version mapping is not vendor backport or native-library coverage. Notices
without machine-readable advisories remain an independent required source.
"""
import datetime as dt
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
NODE_REPO = 'nodejs/security-wg'


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def get_bytes(url):
    if not re.fullmatch(r'https://codeload.github.com/nodejs/security-wg/tar.gz/[a-f0-9]{40}', url):
        raise ValueError('Unreviewed database archive URL')
    spec = importlib.util.spec_from_file_location('trust', ROOT/'scripts/python-toolchain.py')
    trust = importlib.util.module_from_spec(spec); spec.loader.exec_module(trust)
    with urllib.request.urlopen(url, context=trust.https_context(ROOT), timeout=30) as response:
        if response.url != url: raise ValueError('Database archive redirected')
        raw = response.read(32*1024*1024+1)
    if len(raw)>32*1024*1024: raise ValueError('Database archive exceeds limit')
    return raw


def node_records(gh, download=get_bytes):
    head = gh('repos/'+NODE_REPO+'/commits/main')
    if not isinstance(head,dict) or not re.fullmatch('[a-f0-9]{40}',head.get('sha','')):
        raise ValueError('Invalid database commit')
    commit=head['sha']
    listing = gh('repos/'+NODE_REPO+'/contents/vuln/core?ref='+commit)
    if not isinstance(listing,list) or not 1<len(listing)<1000:
        raise ValueError('Missing or possibly truncated core advisory listing')
    expected={}
    for item in listing:
        if item.get('name')=='index.json': continue  # May lag individual records.
        name=item.get('name','')
        if (item.get('type')!='file' or not re.fullmatch(r'[0-9]+\.json',name)
                or item.get('path')!='vuln/core/'+name or not re.fullmatch('[a-f0-9]{40}',item.get('sha',''))
                or type(item.get('size')) is not int or not 0<item['size']<=1024*1024 or name in expected):
            raise ValueError('Unknown or duplicate core advisory file')
        expected[name]=item
    if not expected: raise ValueError('Empty core advisory database')
    archive=download('https://codeload.github.com/'+NODE_REPO+'/tar.gz/'+commit)
    if len(archive)>32*1024*1024: raise ValueError('Oversized core database archive')
    result={};total=0;archive_total=0;prefix='security-wg-'+commit+'/vuln/core/'
    with tarfile.open(fileobj=io.BytesIO(archive),mode='r:gz') as tar:
        for count,member in enumerate(tar):
            if count>=20000: raise ValueError('Database archive entry limit exceeded')
            archive_total+=member.size
            if member.size<0 or archive_total>128*1024*1024:
                raise ValueError('Expanded database archive exceeds limit')
            if not member.name.startswith(prefix): continue
            name=member.name.removeprefix(prefix)
            if name=='index.json' or not name and member.isdir(): continue
            if name not in expected or name in result or not member.isfile() or member.size!=expected[name]['size']:
                raise ValueError('Database archive differs from official tree')
            total+=member.size
            if total>16*1024*1024: raise ValueError('Core records exceed limit')
            raw=tar.extractfile(member).read()
            if hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()!=expected[name]['sha']:
                raise ValueError('Core record differs from official Git blob')
            result[name]=json.loads(raw)
    if result.keys()!=expected.keys(): raise ValueError('Core database snapshot incomplete')
    return commit,result


def stable_version(value):
    if not isinstance(value,str) or not re.fullmatch(r'\d+\.\d+\.\d+',value):
        raise ValueError('Unmapped runtime version')
    return tuple(map(int,value.split('.')))


def stable_range(version, expression):
    """Bounded stable-version subset of official npm ranges; unknown stays None."""
    current=stable_version(version)
    if not isinstance(expression,str) or len(expression)>512 or not expression.strip(): return None
    answers=[]
    pattern=r'(>=|<=|>|<|=|\^|~)?\s*(\*|[0-9]+(?:\.(?:[0-9]+|[xX*])){0,2})'
    for branch in expression.split('||'):
        tokens=re.findall(pattern,branch)
        if not tokens or re.sub(pattern,'',branch).strip(' ,'): answers.append(None);continue
        tests=[]
        for op,text in tokens:
            if text=='*': tests.append(True if not op else None);continue
            parts=text.split('.');known=[];wild=False
            for part in parts:
                if part in ('x','X','*'): wild=True
                elif wild: break
                else: known.append(int(part))
            if len(known)+sum(p in ('x','X','*') for p in parts)!=len(parts): tests.append(None);continue
            lower=tuple(known+[0]*(3-len(known)))
            end=list(lower);index=len(known)-1;end[index]+=1;end[index+1:]=[0]*(2-index);upper=tuple(end)
            partial=len(known)<3
            if op in ('^','~'):
                if wild: tests.append(None);continue
                index=(next((i for i,v in enumerate(known) if v),len(known)-1) if op=='^'
                       else 0 if len(known)==1 else 1)
                end=list(lower);end[index]+=1;end[index+1:]=[0]*(2-index)
                tests.append(lower<=current<tuple(end))
            elif op in ('','=',None): tests.append(lower<=current<upper if partial else current==lower)
            elif op=='>=': tests.append(current>=lower)
            elif op=='>': tests.append(current>=upper if partial else current>lower)
            elif op=='<=': tests.append(current<upper if partial else current<=lower)
            elif op=='<': tests.append(current<lower)
        answers.append(False if False in tests else None if None in tests else all(tests))
    return True if True in answers else None if None in answers else False


def runtime_origins(inventory, collector, component):
    rows=[r for r in inventory['coverage'] if r['id']==collector]
    if len(rows)!=1 or rows[0].get('status')!='inventoried': raise ValueError('Runtime inventory unavailable')
    evidence=rows[0]['evidence'];origins=[]
    for row in evidence:
        if row.get('component')==component:
            stable_version(row['vendorVersion'])
            role=row['role']
            if component=='python':
                impl=[e for e in evidence if e.get('role')==role and e.get('component')=='python-implementation']
                if len(impl)!=1 or impl[0].get('vendorVersion')!='cpython': raise ValueError('Not a verified CPython identity')
            origins.append({'origin':role+'/'+('cpython' if component=='python' else 'node'), 'version':row['vendorVersion']})
    required={'python-runtime/cpython','security-tools/cpython'} if component=='python' else {'node-runtime/node'}
    if len(origins)!=len(required) or {r['origin'] for r in origins}!=required: raise ValueError('Missing or duplicate runtime origins')
    return rows[0],origins


def finding(identifier, component, origin, inventory, url, severity, fixed=''):
    return {'id':identifier,'component':component,'version':origin['version'],'scope':'development',
            'severity':'moderate' if severity=='medium' else severity if severity in ('critical','high','moderate','low') else 'unknown',
            'status':'needs-review','queryComplete':True,'url':url,'fixedVersion':fixed,
            'dependencyPaths':[origin['origin']], 'environmentObservations':[{
                'environment':inventory['environment'],'origin':origin['origin'],'versions':[origin['version']]}]}


def scan_node(inventory,gh,download=get_bytes):
    item,origins=runtime_origins(inventory,'node','node');commit,records=node_records(gh,download)
    findings=[]
    for name,row in records.items():
        if not isinstance(row,dict) or not isinstance(row.get('vulnerable'),str) or not isinstance(row.get('patched'),str):
            raise ValueError('Malformed Node core advisory')
        ids=row.get('cve',[])
        if not isinstance(ids,list) or any(not re.fullmatch(r'CVE-\d{4}-\d{4,}',v) for v in ids):
            raise ValueError('Invalid Node advisory identity')
        for origin in origins:
            vulnerable=stable_range(origin['version'],row['vulnerable']);patched=stable_range(origin['version'],row['patched'])
            if vulnerable is False or patched is True: continue
            for identifier in ids or ['NODE-CORE-'+name.removesuffix('.json')]:
                findings.append(finding(identifier,'Node.js',origin,inventory,
                    'https://github.com/'+NODE_REPO+'/blob/'+commit+'/vuln/core/'+name,row.get('severity'),row['patched']))
    return {'status':'complete','source':'Node core advisories','collector':'node','coverageDigest':digest(item),
            'checkedAt':dt.datetime.now(dt.timezone.utc).isoformat(),'upstreamCommit':commit,'queriedRecords':len(records),
            'sources':origins,'findings':findings,'vendorBackportsCovered':False}


def scan_python(inventory,gh,query):
    item,origins=runtime_origins(inventory,'python','python');cache={};findings=[];mapping=[]
    for origin in origins:
        version=origin['version']
        if version not in cache:
            commit=gh('repos/python/cpython/commits/v'+version)['sha']
            if not re.fullmatch('[a-f0-9]{40}',commit): raise ValueError('Invalid upstream CPython commit')
            response=query('https://api.osv.dev/v1/query',{'commit':commit})
            if (not isinstance(response,dict) or set(response)-{'vulns','next_page_token'} or response.get('next_page_token') or
                    not isinstance(response.get('vulns',[]),list) or len(response.get('vulns',[]))>1000):
                raise ValueError('Incomplete CPython commit query')
            cache[version]=(commit,response.get('vulns',[]))
        commit,records=cache[version];mapping.append({**origin,'upstreamCommit':commit})
        seen=set()
        for row in records:
            identifier=row.get('id','')
            if not re.fullmatch(r'[A-Za-z0-9_.-]{1,100}',identifier) or identifier in seen:
                raise ValueError('Invalid or duplicate CPython advisory')
            seen.add(identifier)
            if row.get('withdrawn'):
                stamp=dt.datetime.fromisoformat(row['withdrawn'])
                if stamp.tzinfo is None or stamp>dt.datetime.now(dt.timezone.utc): raise ValueError('Invalid withdrawal')
                continue
            if not any(r.get('type')=='GIT' and r.get('repo')=='https://github.com/python/cpython'
                       for a in row.get('affected',[]) for r in a.get('ranges',[])):
                raise ValueError('Commit finding does not identify CPython')
            severity=row.get('database_specific',{}).get('severity','unknown').lower()
            findings.append(finding(identifier,'CPython',origin,inventory,'https://osv.dev/vulnerability/'+identifier,severity))
    return {'status':'complete','source':'CPython commit advisories','collector':'python','coverageDigest':digest(item),
            'checkedAt':dt.datetime.now(dt.timezone.utc).isoformat(),'sources':mapping,'findings':findings,
            'mappingMeaning':'Observed CPython version mapped to official upstream release commit; downstream patches and native libraries remain separate',
            'vendorBackportsCovered':False}
