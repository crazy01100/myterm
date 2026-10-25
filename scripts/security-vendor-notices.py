#!/usr/bin/env python3
"""Watch official notices that need not have a CVE or package advisory yet."""
import datetime as dt
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
CONFIG='Config/Security/vendor-notices.json'
SOURCES={
    'python-blog':('https://blog.python.org/feeds/posts/default?alt=atom&max-results=25','blog.python.org'),
    'node-blog':('https://nodejs.org/en/feed/blog.xml','nodejs.org'),
    'firebase-releases':('https://github.com/firebase/firebase-tools/releases.atom','github.com'),
    'cryptography-releases':('https://github.com/pyca/cryptography/releases.atom','github.com'),
    'firestore-releases':('https://docs.cloud.google.com/feeds/fs-release-notes.xml','docs.cloud.google.com'),
}


def fetch(identifier):
    url,host=SOURCES[identifier]
    spec=importlib.util.spec_from_file_location('python_toolchain',ROOT/'scripts/python-toolchain.py')
    trust=importlib.util.module_from_spec(spec);spec.loader.exec_module(trust)
    request=urllib.request.Request(url,headers={'User-Agent':'MyTerm-official-notice-monitor'})
    with urllib.request.urlopen(request,context=trust.https_context(ROOT),timeout=30) as response:
        destination=urllib.parse.urlsplit(response.url)
        if (destination.scheme!='https' or destination.hostname!=host or destination.port not in (None,443)
                or destination.username or destination.password):
            raise ValueError('Official feed redirected outside its provider')
        raw=response.read(4*1024*1024+1)
    if len(raw)>4*1024*1024:raise ValueError('Official feed exceeds limit')
    return raw


def entries(raw, identifier):
    if re.search(br'<!\s*(?:DOCTYPE|ENTITY)\b',raw,re.I):
        raise ValueError('Feed DTD/entity declarations are not supported')
    root=ET.fromstring(raw)
    atom='{http://www.w3.org/2005/Atom}'
    items=root.findall(atom+'entry') if root.tag==atom+'feed' else root.findall('./channel/item')
    if not items or len(items)>2000:raise ValueError('Missing or oversized official feed')
    output=[];seen=set()
    for item in items:
        is_atom=item.tag==atom+'entry';prefix=atom if is_atom else ''
        def content(name):return ''.join(item.find(prefix+name).itertext()) if item.find(prefix+name) is not None else ''
        title=content('title').strip()
        if is_atom:
            links=[x.get('href','') for x in item.findall(atom+'link') if x.get('rel','alternate')=='alternate']
            url=links[0] if len(links)==1 else ''
            stamp=content('published') or content('updated');body=content('content') or content('summary')
        else:
            url=content('link').strip();stamp=content('pubDate');body=content('description')
        parsed=urllib.parse.urlsplit(url)
        if (parsed.scheme!='https' or parsed.hostname!=SOURCES[identifier][1] or parsed.port not in (None,443) or parsed.username or parsed.password
                or not title or len(title)>1000 or not stamp or len(stamp)>100 or len(body)>1024*1024):
            raise ValueError('Invalid official notice identity')
        if identifier in ('firebase-releases','cryptography-releases'):
            path='/firebase/firebase-tools/releases/tag/' if identifier=='firebase-releases' else '/pyca/cryptography/releases/tag/'
            if not parsed.path.startswith(path):raise ValueError('Unexpected vendor release link')
        if identifier=='firestore-releases' and parsed.path!='/firestore/docs/release-notes':
            raise ValueError('Unexpected Firestore release link')
        key=hashlib.sha256(url.encode()).hexdigest()
        if key in seen:raise ValueError('Duplicate official notice')
        seen.add(key)
        # Preserve a content fingerprint so an amended notice is not silently
        # treated as already reviewed. Do not republish entire upstream articles.
        digest=hashlib.sha256(json.dumps({'title':title,'url':url,'body':body},sort_keys=True).encode()).hexdigest()
        output.append({'id':key,'title':title,'url':url,'publishedAt':stamp,'contentSHA256':digest})
    return output


def compare(current, baseline):
    for rows in (current,baseline):
        if not isinstance(rows,list) or len(rows)>2000:
            raise ValueError('Invalid official notice history')
        if any(not isinstance(row,dict) or any(not isinstance(row.get(key),str) or not re.fullmatch('[a-f0-9]{64}',row[key])
               for key in ('id','contentSHA256')) for row in rows):
            raise ValueError('Invalid official notice fingerprint')
        if len({row['id'] for row in rows})!=len(rows):
            raise ValueError('Duplicate official notice history')
    prior={r['id']:r for r in baseline}
    observed={r['id']:r for r in current}
    changes=[row for key,row in observed.items() if key not in prior or row['contentSHA256']!=prior[key]['contentSHA256']]
    # Absence never resolves a notice. A completely rolled-over feed requires
    # explicit history review instead of assuming the latest window is complete.
    return {'changes':changes,'historyGap':bool(prior and not prior.keys()&observed.keys())}


def scan(root=ROOT,fetcher=fetch):
    policy=json.loads((root/CONFIG).read_text())
    if policy.get('schemaVersion')!=1 or set(policy.get('sources',{}))!=set(SOURCES):
        raise ValueError('Official notice source coverage changed')
    result={'schemaVersion':1,'checkedAt':dt.datetime.now(dt.timezone.utc).isoformat(),'sources':[],'changes':[],'errors':[]}
    for identifier in SOURCES:
        if identifier=='firestore-releases':continue  # Product/cloud administration feed is outside tool monitoring.
        try:
            baseline=policy['sources'][identifier]
            if baseline.get('state') not in ('pending','reviewed'):
                raise ValueError('Unknown notice review state')
            # Notice cursors acknowledge content, not the entire source tree.
            # Artifact integrity and actual-version advisories are independent.
            current=entries(fetcher(identifier),identifier)
            delta=compare(current,baseline['entries'])
            result['sources'].append({'id':identifier,'checkedAt':result['checkedAt'],'observedItems':len(current),
                                      'reviewState':baseline['state'],'historyGap':delta['historyGap'],
                                      'observedDigest':hashlib.sha256(json.dumps(
                                          sorted((r['id'],r['contentSHA256']) for r in current)).encode()).hexdigest()})
            result['changes'].extend({'source':identifier,**row} for row in delta['changes'])
            if baseline['state']!='reviewed' or delta['historyGap']:
                result['errors'].append(identifier+': baseline/history review required')
        except (OSError,ValueError,KeyError,TypeError,ET.ParseError):
            result['errors'].append(identifier+': official feed unavailable')
    result['checksComplete']=not result['errors']
    # Initial captures are not accepted reviews, even if the feed is unchanged.
    # Keep a compact source-level review item instead of flooding an Issue with
    # every historical release entry. Exact initial fingerprints remain in policy.
    result['requiresNoticeReview']=bool(result['changes']) or any(
        r['reviewState']!='reviewed' or r['historyGap'] for r in result['sources'])
    return result
