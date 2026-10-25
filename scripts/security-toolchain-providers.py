#!/usr/bin/env python3
"""Bind actual query evidence to each declared coverage domain.

Unmapped vendor/native evidence is an explicit blocking review item. It is
never replaced with an empty successful advisory response.
"""
import datetime as dt
import hashlib
import json
import re


def firestore_notices(inventory, policy, advisories):
    """Actual parent-vendor notices, never an invented Maven child query."""
    items=[r for r in inventory['coverage'] if r['id']=='emulator']
    if len(items)!=1 or items[0].get('status')!='supplier-managed-limited':
        raise ValueError('Firestore artifact identity unavailable')
    item=items[0]
    if len(item.get('evidence',[]))!=1:raise ValueError('Ambiguous Firestore artifact')
    ev=item['evidence'][0]
    matches=[d for d in policy['supplierBoundaries'] if d.get('id')==ev.get('boundaryId')]
    fields=('component','version','firebaseToolsVersion','size','sha256')
    if (ev.get('component')!='firestore-emulator' or ev.get('allDependenciesScanned') is not False
            or len(matches)!=1 or matches[0].get('state')!='accepted'
            or matches[0].get('knownVulnerabilityWaiver') is not False
            or any(matches[0].get(k)!=ev.get(k) for k in fields)
            or matches[0].get('url')!=ev.get('source')):
        raise ValueError('Firestore supplier boundary differs')
    if not isinstance(advisories,list):raise ValueError('Missing vendor advisory response')
    findings=[];seen=set()
    for advisory in advisories:
        if not isinstance(advisory,dict):raise ValueError('Invalid vendor advisory')
        identifier=advisory.get('ghsa_id','')
        if not re.fullmatch(r'GHSA-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}',identifier) or identifier in seen:
            raise ValueError('Invalid or duplicate vendor advisory')
        seen.add(identifier)
        if advisory.get('withdrawn_at'):
            stamp=dt.datetime.fromisoformat(advisory['withdrawn_at'])
            if stamp.tzinfo is None or stamp>dt.datetime.now(dt.timezone.utc):raise ValueError('Invalid withdrawal')
            continue
        # Parent-repository publication does not by itself establish that the
        # opaque JAR is affected or unaffected. Keep it pending, including low.
        severity=advisory.get('severity','unknown')
        if severity=='medium':severity='moderate'
        if severity not in ('critical','high','moderate','low'):severity='unknown'
        findings.append({'id':identifier,'component':'firestore-emulator','version':ev['version'],
                         'scope':'development','severity':severity,'status':'needs-review',
                         'url':'https://github.com/firebase/firebase-tools/security/advisories/'+identifier,
                         'queryComplete':True,'dependencyPaths':['emulator/firestore'],
                         'environmentObservations':[{'environment':inventory['environment'],
                            'origin':'emulator/firestore','versions':[ev['version']]}]})
    receipt={'status':'complete','checkedAt':dt.datetime.now(dt.timezone.utc).isoformat(),
             'coverageDigest':digest(item),'source':'Firestore vendor advisories',
             'reason':'Official Firebase repository advisories queried for exact supplier artifact; shaded Maven identities remain unavailable',
             'publishedAdvisories':len(advisories),'allDependenciesScanned':False}
    return receipt,findings


def digest(value):
    return hashlib.sha256(json.dumps(value,sort_keys=True).encode()).hexdigest()


def bind_parents(inventory,queries):
    result={}
    for item in inventory['coverage']:
        for query in queries:
            if query.get('collector')!=item['id'] or query.get('status')!='complete':continue
            evidence=item.get('evidence',[]);matches=False
            if item['id']=='npm-project':
                matches=bool(evidence and evidence[0].get('lockSHA256')==query.get('lockSHA256') and query.get('lockSHA256'))
            elif item['id']=='app':
                matches=any(e.get('sourceSHA256')==query.get('sourceSHA256') for e in evidence if e.get('sourceSHA256'))
            elif item['id']=='actions':
                refs=sorted([[e['action'],e['revision']] for e in evidence])
                uses={name:value for e in evidence for name,value in e.get('workflowSHA256',{}).items()}
                matches=bool(refs and refs==query.get('references') and uses==query.get('workflowSHA256'))
            if matches:
                for source in query['sources']:
                    result[(item['id'],source)]={'status':'complete','checkedAt':query['checkedAt'],'coverageDigest':digest(item)}
    return result


def receipts(inventory, policy, package_result, native_result, notices, parent_results):
    checked=dt.datetime.now(dt.timezone.utc).isoformat()
    output=[]
    observed={r['id']:r for r in inventory['coverage']}
    packages_ok=(package_result.get('advisoryQueryStatus')=='complete' and
                 package_result.get('componentDigest')==digest(inventory['components']))
    if 'domains' in package_result:
        packages_ok &= package_result.get('observedEnvironment')==inventory.get('environment')
    feeds={r['id']:r for r in notices.get('sources',[])}
    native={(r['collector'],r['origin'],r['version']) for r in native_result.get('sources',[])}
    reasons={
        'vendor security notices':'Native/App vendor build and embedded component review remains required',
        'Cloudflare security notices':'Deployment native binaries and vendor advisories require review',
        'OSV Maven':'Supplier provides no Maven identities; accepted JAR boundary does not supply an advisory query',
        'JDK vendor security notices':'Actual JDK vendor/build and trust data require environment-specific review',
    }
    feed_sources={'Python security notices':'python-blog','Node security releases':'node-blog',
                  'Firebase release notes':'firebase-releases','Firestore release notes':'firestore-releases'}
    for entry in policy['collectors']:
        if inventory['purpose'] not in entry['uses']:continue
        item=observed.get(entry['id'],{})
        limited=item.get('status')=='supplier-managed-limited'
        for source in entry['advisorySources']:
            row={'collector':entry['id'],'source':source,'checkedAt':checked,
                 'coverageDigest':digest(item),'identityCoverage':'supplier-boundary' if limited else 'complete',
                 'status':'needs-review','reason':reasons.get(source,'No matching verified query evidence'),
                 'findings':[]}
            if item.get('status') not in ('inventoried','supplier-managed-limited'):
                row.update(status='unavailable',reason='Collector identity evidence unavailable')
            elif source=='OSV' and packages_ok:
                row.update(status='complete',reason='Exact enumerated package identities queried',checkedAt=package_result['checkedAt'])
            elif source=='OSV' and isinstance(package_result.get('domains'),list):
                selected=[c for c in inventory['components'] if c.get('collector')==entry['id']]
                proofs=[p for p in package_result['domains'] if p.get('collector')==entry['id']]
                if (selected and len(proofs)==1 and proofs[0].get('status')=='complete'
                        and proofs[0].get('observedEnvironment')==inventory.get('environment')
                        and proofs[0].get('componentDigest')==digest(selected)
                        and proofs[0].get('coverageDigest')==digest(item)):
                    row.update(status='complete',reason='This package domain queried; other failed domains remain incomplete',
                               checkedAt=proofs[0]['checkedAt'])
            elif source=='OpenSSL security notices' and native_result.get('status')=='complete':
                expected=[]
                for ev in item.get('evidence',[]):
                    if ev.get('component') in ('openssl','cryptography-openssl'):
                        value=ev['vendorVersion'].removeprefix('OpenSSL ').split()[0]
                        expected.append((entry['id'],ev['role']+'/'+ev['component'],value))
                if expected and set(expected)<=native:
                    row.update(status='complete',reason='Exact OpenSSL origins queried against official CNA records',checkedAt=native_result['checkedAt'])
            elif source in feed_sources:
                feed=feeds.get(feed_sources[source])
                if feed and feed.get('reviewState')=='reviewed' and not feed.get('historyGap'):
                    row.update(status='complete',checkedAt=feed['checkedAt'],
                               reason='Official feed changes checked; findings still require their own applicability review')
            elif source=='upstream bundle manifests' and entry['id']=='actions' and limited:
                row.update(status='complete',reason='Exact accepted archives/entrypoints and candidate manifests verified; full bundle reachability unavailable')
            else:
                parent=parent_results.get((entry['id'],source))
                if parent and parent.get('status')=='complete' and parent.get('coverageDigest')==digest(item):
                    row.update(status='complete',checkedAt=parent['checkedAt'],reason='Matching parent/query evidence verified')
                    if parent.get('allDependenciesScanned') is False:
                        row.update(allDependenciesScanned=False,closureEligible=False,
                                   limitation=parent.get('limitation','Parent supplier notice coverage only'))
            output.append(row)
    return output
