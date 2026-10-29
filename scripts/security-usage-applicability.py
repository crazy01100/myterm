#!/usr/bin/env python3
"""Verify reviewed project entry paths, never infer safety from version alone."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile

CONFIG = 'Config/Security/usage-applicability.json'
EVIDENCE = 'Config/Security/applicability/project-usage.json'
HEX = re.compile('[a-f0-9]{64}')


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name+'.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def key(row):
    return row.get('id'), row.get('component'), row.get('scope')


def targets():
    # This file is part of the exact policy PR, not a caller-supplied allowlist.
    return TARGETS


def configuration(root):
    data = json.loads((root/CONFIG).read_text())
    rules = data.get('rules', [])
    if (data.get('schemaVersion') != 1 or data.get('state') != 'approved'
            or data.get('grantsRiskException') is not False
            or len(rules) != len(TARGETS) or {key(r) for r in rules} != set(TARGETS)):
        raise ValueError('Unreviewed project usage scope')
    for rule in rules:
        if (rule.get('decision') != 'reviewed-project-usage' or rule.get('advisoryKind') != 'ghsa'
                or rule.get('case') != TARGETS[key(rule)]
                or not HEX.fullmatch(rule.get('advisorySHA256', ''))
                or not HEX.fullmatch(rule.get('evidenceSHA256', ''))
                or rule.get('evidenceFile') != EVIDENCE
                or not rule.get('origins') or len(set(rule['origins'])) != len(rule['origins'])
                or set(rule.get('originVersions', {})) != set(rule['origins'])
                or any(not v or not all(isinstance(x, str) and x for x in v)
                       for v in rule['originVersions'].values())):
            raise ValueError('Invalid reviewed usage decision')
    return rules


def owned_file(root, relative):
    name = Path(relative)
    if name.is_absolute() or '..' in name.parts:
        raise ValueError('Unowned usage evidence')
    path = root/name
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError('Usage source missing or redirected')
    return path


def evidence(root, rule):
    raw = owned_file(root, EVIDENCE).read_bytes()
    if hashlib.sha256(raw).hexdigest() != rule['evidenceSHA256']:
        raise ValueError('Reviewed usage evidence changed')
    data = json.loads(raw)
    group = data['cases'][rule['case']]
    if (data.get('schemaVersion') != 1 or data.get('kind') != 'reviewed-project-entry-paths'
            or not group.get('conclusion') or not group.get('sourceFiles')):
        raise ValueError('Incomplete usage evidence')
    actual_workflows = {str(p.relative_to(root)) for p in (root/'.github/workflows').iterdir()
                        if p.suffix in ('.yml', '.yaml')}
    if actual_workflows != set(data['workflows']):
        raise ValueError('New or missing workflow requires usage review')
    for name, expected in {**data['workflows'], **group['sourceFiles']}.items():
        if not HEX.fullmatch(expected) or hashlib.sha256(owned_file(root, name).read_bytes()).hexdigest() != expected:
            raise ValueError('Project consumer or configuration changed: '+name)
    return data, group


def action_bytes(root, row, entries):
    raw = owned_file(root, row['cacheFile']).read_bytes()
    if not row['cacheFile'].startswith('.build/') or hashlib.sha256(raw).hexdigest() != row['archiveSHA256']:
        raise ValueError('Official Action archive changed')
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as archive:
        members = archive.getmembers()
        for item in entries:
            matches = [m for m in members if m.name.endswith('/'+item['entrypoint'])]
            if (len(matches) != 1 or not matches[0].isfile()
                    or hashlib.sha256(archive.extractfile(matches[0]).read()).hexdigest() != item['sha256']):
                raise ValueError('Reviewed Action entrypoint changed')


def verify_actions(root, data, group, origins):
    configured = json.loads((root/'Config/Security/action-bundles.json').read_text())['bundles']
    if configured != data['actions']:
        raise ValueError('Official Action selection changed')
    verified = []
    for row in configured:
        origin = 'action/'+row['repository']+'@'+row['revision']
        if origin not in origins:
            continue
        entries = [x for x in data['actionEntryPaths'] if x['action'] == row['repository']]
        if not entries:
            raise ValueError('Missing reviewed Action entry paths')
        action_bytes(root, row, entries)
        if group['consumer'] == 'undici-actions':
            for entry in entries:
                graph = entry['undiciSurface']
                if (graph['sha256'] != entry['sha256'] or graph['dynamicInternalRequires']
                        or not graph['consumers'] or any(c['escapes'] or
                            set(c['properties']) - {'fetch', 'ProxyAgent', 'kT'} for c in graph['consumers'])
                        or any(f['callersOutsideUndiciEntry'] for f in graph['features'])):
                    raise ValueError('Affected or unknown Undici consumer')
                if group.get('condition') == 'no-websocket-consumer' and not any(
                        f.get('api') == 'WebSocket' for f in graph['features']):
                    raise ValueError('Missing WebSocket consumer evidence')
                if group.get('condition') == 'no-custom-tls-callback':
                    tls = entry.get('tlsOptionsReview', {})
                    if (tls.get('entrypointSHA256') != entry['sha256']
                            or tls.get('customTlsCallbackCallers') != [] or not tls.get('proxyAgentCallSites')):
                        raise ValueError('Missing or affected TLS option evidence')
        verified.append({'origin': origin, 'archiveSHA256': row['archiveSHA256'],
                         'entrypoints': {e['entrypoint']: e['sha256'] for e in entries}})
    if {x['origin'] for x in verified} != set(origins):
        raise ValueError('Usage evidence does not cover every Action origin')
    return verified


def verify(root, rule):
    data, group = evidence(root, rule)
    kind = group['consumer']
    if kind in ('undici-actions', 'artifact-input', 'xml-options', 'node-version-input'):
        assets = verify_actions(root, data, group, rule['origins'])
    elif kind == 'npm-entry':
        npm = load('node-toolchain'); npm.verify(root)
        policy = npm.policy(root)
        if policy != data['npmPolicy'] or rule['origins'] != ['project-npm-tool']:
            raise ValueError('Reviewed npm identity changed')
        node = subprocess.run([str(root/'scripts/project-node.sh'), '--version'],
                              capture_output=True, text=True, check=True, timeout=20).stdout.strip()
        if node != 'v'+policy['nodeVersion']:
            raise ValueError('Reviewed Node validation semantics changed')
        assets = {'npm': policy['npm'], 'nodeVersion': node}
    elif kind == 'offline-pip':
        pip = load('security-pip-applicability')
        policy = pip.configuration(root)
        if policy['pipVersion'] != data['pipVersion'] or policy['wheelSHA256'] != data['pipWheelSHA256']:
            raise ValueError('Reviewed pip identity changed')
        assets = pip.verify_environments(root, policy)
        if set(rule['origins']) != {x['origin'] for x in assets['environments']}:
            raise ValueError('Unverified pip origin')
    else:
        raise ValueError('Unknown project usage boundary')
    return {'case': rule['case'], 'evidenceSHA256': rule['evidenceSHA256'],
            'consumer': kind, 'verifiedAssets': assets,
            'workflowFiles': data['workflows'], 'consumerFiles': group['sourceFiles']}


# Explicit reviewed advisory/component/scope identities are populated with this change.
TARGETS = {('GHSA-2mjp-6q6p-2qxm', 'undici', 'github-actions'): 'undici-fetch-only',
 ('GHSA-2m5v-pch6-74hx', 'undici', 'development'): 'npm-no-custom-tls-callback',
 ('GHSA-2m5v-pch6-74hx', 'undici', 'github-actions'): 'undici-no-custom-tls-callback',
 ('GHSA-9fm3-97px-rjf6', 'undici', 'development'): 'npm-no-websocket-consumer',
 ('GHSA-9fm3-97px-rjf6', 'undici', 'github-actions'): 'undici-no-websocket-consumer',
 ('GHSA-qrxm-fqhp-jwvm', 'undici', 'development'): 'npm-no-install-scripts',
 ('GHSA-3jxr-9vmj-r5cp', 'brace-expansion', 'github-actions'): 'fixed-artifact-patterns',
 ('GHSA-3wwx-pv8p-q78v', 'undici', 'github-actions'): 'undici-fetch-only',
 ('GHSA-4992-7rv2-5pvq', 'undici', 'github-actions'): 'undici-fetch-only',
 ('GHSA-4qv8-2p9j-2685', 'undici', 'development'): 'npm-no-eventsource',
 ('GHSA-4qv8-2p9j-2685', 'undici', 'github-actions'): 'undici-fetch-only',
 ('GHSA-5wm8-gmm8-39j9', 'fast-xml-builder', 'github-actions'): 'xml-default-entity-option',
 ('GHSA-6j4f-fj2g-mc7p', 'brace-expansion', 'github-actions'): 'fixed-artifact-patterns',
 ('GHSA-8988-9cw3-xx77', 'urllib3', 'verification-tool'): 'offline-pip',
 ('GHSA-8xcm-r25x-g524', 'undici', 'github-actions'): 'undici-fetch-only',
 ('GHSA-f269-vfmq-vjvj', 'undici', 'github-actions'): 'undici-fetch-only',
 ('GHSA-f886-m6hf-6m8v', 'brace-expansion', 'github-actions'): 'fixed-artifact-patterns',
 ('GHSA-g8m3-5g58-fq7m', 'undici', 'github-actions'): 'undici-fetch-only',
 ('GHSA-gh4c-6fx4-qh6g', 'urllib3', 'verification-tool'): 'offline-pip',
 ('GHSA-gh4j-gqv2-49f6', 'fast-xml-parser', 'github-actions'): 'xml-generated-block-list',
 ('GHSA-jp2q-39xq-3w4g', 'fast-xml-parser', 'github-actions'): 'xml-bounded-entity-options',
 ('GHSA-jxxr-4gwj-5jf2', 'brace-expansion', 'github-actions'): 'fixed-artifact-patterns',
 ('GHSA-m8rv-5g2x-5cg5', 'undici', 'github-actions'): 'undici-fetch-only',
 ('GHSA-mh99-v99m-4gvg', 'brace-expansion', 'github-actions'): 'fixed-artifact-patterns',
 ('GHSA-p88m-4jfj-68fv', 'undici', 'github-actions'): 'undici-fetch-only',
 ('GHSA-q2hr-2g5m-vwhr', 'brace-expansion', 'github-actions'): 'fixed-artifact-patterns',
 ('GHSA-qhr7-859c-m2p7', 'brace-expansion', 'github-actions'): 'fixed-artifact-patterns',
 ('GHSA-r4xh-jqrq-34v2', 'smol-toml', 'github-actions'): 'node-explicit-version',
 ('GHSA-r53p-7pc4-xj5r', 'undici', 'github-actions'): 'undici-fetch-only',
 ('GHSA-rfgv-xxqx-mfg5', 'undici', 'github-actions'): 'undici-fetch-only',
 ('GHSA-rgw5-rvv9-x895', 'brace-expansion', 'github-actions'): 'fixed-artifact-patterns',
 ('GHSA-rxp7-6hxx-x8q5', 'ip-address', 'development'): 'validated-ip-input',
 ('GHSA-v3r7-h72x-cjcm', 'undici', 'github-actions'): 'undici-fetch-only',
 ('GHSA-v9p9-hfj2-hcw8', 'undici', 'github-actions'): 'undici-fetch-only',
 ('GHSA-vrm6-8vpv-qv8q', 'undici', 'github-actions'): 'undici-fetch-only',
 ('GHSA-vxpw-j846-p89q', 'undici', 'github-actions'): 'undici-fetch-only',
 ('GHSA-vxq7-64xx-v4gw', 'urllib3', 'verification-tool'): 'offline-pip',
 ('GHSA-xjj6-f33q-929c', 'undici', 'development'): 'npm-no-install-scripts'}
