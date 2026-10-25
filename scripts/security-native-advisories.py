#!/usr/bin/env python3
"""Official native-vendor metadata. Never infer C library versions from crate names."""
from concurrent.futures import ThreadPoolExecutor
import datetime as dt
import importlib.util
import json
from pathlib import Path
import re
import urllib.request

ROOT=Path(__file__).resolve().parents[1]


def fetch(url):
    if not re.fullmatch(r'https://openssl-library\.org/news/(?:vulnerabilities-[34]\.[0-9]+/|secjson/cve-[0-9]{4}-[0-9]+\.json)',url):
        raise ValueError('Unreviewed native advisory source')
    spec=importlib.util.spec_from_file_location('trust',ROOT/'scripts/python-toolchain.py')
    trust=importlib.util.module_from_spec(spec);spec.loader.exec_module(trust)
    with urllib.request.urlopen(url,context=trust.https_context(ROOT),timeout=35) as response:
        if response.url!=url:raise ValueError('Native advisory redirected')
        raw=response.read(4*1024*1024+1)
    if len(raw)>4*1024*1024:raise ValueError('Native advisory exceeds limit')
    return json.loads(raw) if url.endswith('.json') else raw.decode()


def version(value):
    if not isinstance(value,str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',value):
        raise ValueError('Unmapped native version format')
    return tuple(map(int,value.split('.')))


def openssl_range(current, entry):
    parsed=version(current)
    start=entry.get('version','')
    # The old letter-suffixed branches cannot contain a 3.x/4.x release.
    if parsed[0]>=3 and re.fullmatch(r'[01]\.[0-9]+\.[0-9]+[a-z]*',start):
        end=entry.get('lessThan',entry.get('lessThanOrEqual',''))
        if re.fullmatch(r'[01]\.[0-9]+\.[0-9]+[a-z]*',end):return False
    if entry.get('versionType') not in ('semver',None) or entry.get('changes'):
        raise ValueError('Unknown native affected range')
    if entry.get('status') not in ('affected','unaffected'):
        raise ValueError('Unknown native affected status')
    if parsed<version(start):return False
    if 'lessThan' in entry:return parsed<version(entry['lessThan'])
    if 'lessThanOrEqual' in entry:return parsed<=version(entry['lessThanOrEqual'])
    return parsed==version(start)


def openssl_sources(inventory):
    sources=[]
    for collector in inventory['coverage']:
        for row in collector.get('evidence',[]):
            if row.get('component') not in ('openssl','cryptography-openssl'):continue
            match=re.fullmatch(r'(?:OpenSSL )?([34]\.[0-9]+\.[0-9]+)(?: .*)?',row.get('vendorVersion',''))
            if not match:raise ValueError('Cannot map OpenSSL identity')
            sources.append({'version':match[1],'origin':row['role']+'/'+row['component'],'collector':collector['id']})
    if not sources:raise ValueError('No native OpenSSL identities')
    return sources


def scan_openssl(inventory, fetcher=fetch):
    sources=openssl_sources(inventory)
    identifiers=set();indexes=[]
    for branch in sorted({'.'.join(s['version'].split('.')[:2]) for s in sources}):
        url=f'https://openssl-library.org/news/vulnerabilities-{branch}/'
        page=fetcher(url)
        found=set(re.findall(r'href=["\']#(CVE-[0-9]{4}-[0-9]+)["\']',page))
        if not found or len(found)>500:raise ValueError('Native index missing or exceeds limit')
        identifiers.update(found);indexes.append(url)
    def detail(identifier):
        url='https://openssl-library.org/news/secjson/'+identifier.lower()+'.json'
        record=fetcher(url)
        if record.get('cveMetadata',{}).get('cveId')!=identifier or record['cveMetadata'].get('state')!='PUBLISHED':
            raise ValueError('Native advisory identity/state changed')
        cna=record['containers']['cna']
        packages=[p for p in cna['affected'] if p.get('product')=='OpenSSL' and p.get('vendor')=='OpenSSL']
        if len(packages)!=1 or packages[0].get('defaultStatus')!='unaffected':
            raise ValueError('Unsupported native affected product')
        severity='unknown'
        for metric in cna.get('metrics',[]):
            other=metric.get('other',{})
            if other.get('type')=='https://openssl-library.org/policies/general/security-policy/':
                value=other.get('content',{}).get('text','').lower()
                severity=value if value in ('critical','high','moderate','low') else 'unknown'
        rows=[]
        for source in sources:
            ranges=[r for r in packages[0]['versions'] if openssl_range(source['version'],r)]
            if len({r['status'] for r in ranges})>1:raise ValueError('Conflicting native affected status')
            if ranges and ranges[0]['status']=='affected':
                rows.append({'id':identifier,'component':'OpenSSL','version':source['version'],
                             'scope':'development','severity':severity,'status':'needs-review',
                             'url':url,'title':cna.get('title',identifier),
                             'fixedVersion':', '.join(sorted({r['lessThan'] for r in ranges if 'lessThan' in r})),
                             'dependencyPaths':[source['origin']],
                             'environmentObservations':[{'environment':inventory['environment'],'origin':source['origin'],'versions':[source['version']]}]})
        return rows
    findings=[]
    with ThreadPoolExecutor(max_workers=4) as pool:
        for rows in pool.map(detail,sorted(identifiers)):findings.extend(rows)
    return {'schemaVersion':1,'checkedAt':dt.datetime.now(dt.timezone.utc).isoformat(),
            'source':'OpenSSL official CNA records','queriedAdvisories':len(identifiers),
            'sources':sources,'indexes':indexes,'findings':findings,
            'scope':'OpenSSL identities only; not other native libraries or a reachability verdict'}
