#!/usr/bin/env python3
"""Coverage decisions for toolchain evidence, separate from risk acceptance.

Metadata enumeration, package advisory lookup and supplier/native review are
different proofs. No absent collector or vendor decision can waive a finding.
"""
import datetime as dt
import hashlib
import json


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def fresh(stamp, now):
    try:
        parsed = dt.datetime.fromisoformat(stamp)
        return parsed.tzinfo is not None and 0 <= (now-parsed).total_seconds() <= 48*3600
    except (TypeError, ValueError):
        return False


def supplier_matches(evidence, decision, collector):
    if (decision.get('state')!='accepted' or decision.get('knownVulnerabilityWaiver') is not False or
            evidence.get('allDependenciesScanned') is not False or
            evidence.get('source')!=decision.get('url')):
        return False
    kind=decision.get('kind')
    if collector=='emulator' and kind=='supplier-managed-limited-subdependency-evidence':
        fields=('component','version','sha256','size','firebaseToolsVersion')
    elif collector=='actions' and kind=='action-bundle-limited-evidence':
        fields=('component','revision','archiveSHA256','entrypoints')
        if decision.get('runnerRuntimeCovered') is not False or evidence.get('runnerRuntimeCovered') is not False:
            return False
    else:
        return False
    return all(decision.get(key) is not None and evidence.get(key)==decision[key] for key in fields)


def summarize(inventory, advisories, policy, provider_results, *, now=None):
    """Provider results must bind exact identities, source and observation time.

    The caller supplies trusted provider adapters' results, never user-entered
    declarations. Draft evidence cannot authorize a gate or close any Issue.
    """
    now = now or dt.datetime.now(dt.timezone.utc)
    errors = list(inventory.get('errors', []))
    components = inventory.get('components', [])
    observed = inventory.get('coverage', [])
    expected = policy.get('collectors', [])
    if policy.get('status') != 'approved' or inventory.get('policyStatus') != 'approved':
        errors.append('Coverage policy has not been activated after source review')
    if len({r['id'] for r in observed}) != len(observed) or {r['id'] for r in observed} != {r['id'] for r in expected}:
        errors.append('Missing or duplicate coverage collectors')
    if (advisories.get('advisoryQueryStatus') != 'complete' or
            advisories.get('componentDigest') != digest(components) or
            not fresh(advisories.get('checkedAt'), now)):
        errors.append('Package queries do not prove this current component inventory')
    limitations = []
    rows = []
    for entry in expected:
        matches = [r for r in observed if r['id'] == entry['id']]
        row = {'id': entry['id'], 'scopeIds': entry['scopeIds'], 'checksComplete': False,
               'closureEligible': False}
        if len(matches) != 1:
            rows.append(row)
            continue
        item = matches[0]
        if item.get('scopeIds') != entry['scopeIds']:
            errors.append(entry['id']+': scope identities differ')
            rows.append(row)
            continue
        applicable = inventory.get('purpose') in entry['uses']
        if not applicable:
            if item.get('status') != 'not-applicable':
                errors.append(entry['id']+': inconsistent optional-use evidence')
            else:
                row.update(checksComplete=True, status='not-applicable')
            rows.append(row)
            continue
        if item.get('status') not in ('inventoried', 'supplier-managed-limited'):
            errors.append(entry['id']+': inventory unavailable')
            rows.append(row)
            continue
        limited = item['status'] == 'supplier-managed-limited'
        valid_boundary = not limited
        if limited:
            evidence = [e for e in item.get('evidence', []) if e.get('coverageStatus') == 'supplier-managed-limited']
            decisions = policy.get('supplierBoundaries', [])
            ids=[e.get('boundaryId') for e in evidence]
            valid_boundary = bool(evidence) and len(ids)==len(set(ids))
            if entry['id']=='emulator':valid_boundary &= len(evidence)==1
            if entry['id']=='actions':
                # Every observed Action needs its own accepted exact boundary.
                valid_boundary &= len(evidence)==len(item.get('evidence',[]))
            for ev in evidence:
                decisions_matching = [d for d in decisions if d.get('id') == ev.get('boundaryId')]
                if len(decisions_matching) != 1:
                    valid_boundary = False
                    continue
                decision = decisions_matching[0]
                valid_boundary &= supplier_matches(ev,decision,entry['id'])
                limitations.append({'collector': entry['id'], 'boundaryId': ev.get('boundaryId'),
                                    'subdependencyCoverage': 'unavailable-from-supplier',
                                    'allDependenciesScanned': False})
        source_results = [r for r in provider_results if r.get('collector') == entry['id']]
        supplier_notice_limits=[r for r in source_results if r.get('allDependenciesScanned') is False]
        for result in supplier_notice_limits:
            limitations.append({'collector':entry['id'],'source':result['source'],
                                'subdependencyCoverage':result.get('limitation','Parent supplier notices only'),
                                'allDependenciesScanned':False})
        expected_sources = entry['advisorySources']
        provider_ok = len(source_results) == len(expected_sources) and set(r.get('source') for r in source_results) == set(expected_sources)
        for result in source_results:
            provider_ok &= (result.get('status') == 'complete' and
                            result.get('coverageDigest') == digest(item) and
                            fresh(result.get('checkedAt'), now) and
                            result.get('identityCoverage') == ('supplier-boundary' if limited else 'complete'))
        if not provider_ok or not valid_boundary:
            errors.append(entry['id']+': advisory or supplier evidence incomplete')
        row.update(checksComplete=bool(provider_ok and valid_boundary),
                   closureEligible=bool(provider_ok and valid_boundary and not limited and not supplier_notice_limits),
                   status='supplier-managed-limited' if limited else ('reviewed' if provider_ok and valid_boundary else 'needs-review'))
        rows.append(row)
    findings = list(advisories.get('findings', []))
    for result in provider_results:
        findings.extend(result.get('findings', []))
    # This new coverage layer grants no exception. Existing reviewed exception
    # evaluation, if applicable, belongs in the main audit after aggregation.
    blocking_findings = [f for f in findings if f.get('status') != 'not-affected' and
                         (f.get('status') == 'needs-review' or f.get('severity') not in ('low','info'))]
    complete = not errors and bool(rows) and all(r['checksComplete'] for r in rows)
    return {'schemaVersion': 1, 'checksComplete': complete,
            'allDependenciesScanned': bool(complete and not limitations),
            'status': 'incomplete' if not complete else ('complete-with-supplier-limitations' if limitations else 'complete'),
            'inventoryDigest': digest({'components': components, 'coverage': observed}),
            'coverage': rows, 'supplierLimitations': limitations,
            'errors': errors, 'findings': findings, 'blocking': not complete or bool(blocking_findings)}
