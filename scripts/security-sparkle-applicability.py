#!/usr/bin/env python3
"""One reviewed Sparkle package-update advisory; no installer or exploit execution.

Source policy and authenticated released bytes are independent evidence. Raw
matches survive; failures invalidate the decision, never confer an exception.
"""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CONFIG = 'Config/Security/applicability/sparkle-package-update.json'
ID = 'GHSA-gcjm-h3jh-p2vc'
COMPONENT = 'sparkle-project/Sparkle'
DECISION = 'sparkle-app-bundle-updates'
SCOPES = {'current-source': 217, 'released-app': 218}
VERSION = '2.10.1'
REVISION = 'ab7d71291238df6e0492143b120c9b696a35f603'
REPO = 'crazy01100/myterm'
BASE_URL = 'https://mtus.lieniapp.work'
BUNDLE = 'tw.local.MySSHClient'
HEX = re.compile('[a-f0-9]{64}')
SOURCE_FILES = {
    'Package.swift', 'Package.resolved', 'Resources/Info.plist',
    'Sources/MySSHClient/Services/AppUpdaterStore.swift',
    'scripts/build-app.sh', 'scripts/package-app.sh',
    'scripts/prepare-release-assets.sh', 'scripts/bind-release-metadata.py',
    'scripts/verify-app.sh', 'scripts/verify-signed-release.py',
    'scripts/security-python.sh', 'scripts/python-openssl-env.sh',
    'scripts/release.sh', 'scripts/prepare-release-build.sh', 'scripts/verify-release-assets.sh',
    'scripts/sparkle-key-common.sh', 'Config/Release/SparklePublicKey.txt',
}
REASON = ('此精確 MyTerm 官方更新採用 App bundle，符合公告列明的不受影響安裝路徑；'
          '另核對既有強制 feed 簽章及正式產品／公鑰。這不是 Sparkle 套件已修補。')


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT/'scripts'/f'{name}.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                    separators=(',', ':')).encode()).hexdigest()


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def owned(root, name):
    p = root/name
    if p.is_symlink() or not p.resolve().is_relative_to(root.resolve()) or not p.is_file():
        raise ValueError('Missing or redirected reviewed source')
    return p.read_bytes()


def configuration(root):
    raw = owned(root, CONFIG); data = json.loads(raw)
    if (data.get('schemaVersion') != 1 or data.get('decision') != DECISION
            or data.get('state') != 'approved' or data.get('grantsRiskException') is not False
            or data.get('id') != ID or data.get('component') != COMPONENT
            or data.get('scopes') != SCOPES or data.get('version') != VERSION
            or data.get('revision') != REVISION or data.get('repository') != REPO
            or data.get('bundleIdentifier') != BUNDLE or data.get('baseURL') != BASE_URL
            or set(data.get('sourceSHA256', {})) != SOURCE_FILES
            or not HEX.fullmatch(data.get('advisorySHA256', ''))
            or not HEX.fullmatch(data.get('publicKeySHA256', ''))
            or any(not HEX.fullmatch(v) for v in data['sourceSHA256'].values())):
        raise ValueError('Unreviewed Sparkle applicability policy')
    return data, sha(raw)


def advisory_digest(row):
    return digest({k: row.get(k) for k in ('ghsa_id', 'html_url', 'withdrawn_at',
                                         'summary', 'description', 'vulnerabilities', 'severity')})


def reader(root, endpoint):
    return load('security-source-review').gh_read(root, endpoint)


def download(root, asset):
    if (type(asset.get('id')) is not int or asset['id'] < 1
            or not 0 < asset.get('size', 0) <= 25*1024*1024):
        raise ValueError('Invalid official release asset')
    raw = subprocess.run([str(root/'scripts/project-gh.sh'), 'api', '--method', 'GET',
        '-H', 'Accept: application/octet-stream', f'repos/{REPO}/releases/assets/{asset["id"]}'],
        check=True, capture_output=True, timeout=60).stdout
    if len(raw) != asset['size'] or len(raw) > 25*1024*1024:
        raise ValueError('Release asset size mismatch')
    return raw


def checked_advisory(root, policy, read):
    a = read(f'repos/{COMPONENT}/security-advisories/{ID}')
    if (a.get('ghsa_id') != ID or a.get('withdrawn_at')
            or advisory_digest(a) != policy['advisorySHA256']):
        raise ValueError('Official advisory conditions changed')
    return policy['advisorySHA256']


def source_evidence(root, policy):
    hashes = {name: sha(owned(root, name)) for name in sorted(SOURCE_FILES)}
    if hashes != policy['sourceSHA256']:
        changed = [name for name in hashes if hashes[name] != policy['sourceSHA256'][name]]
        raise ValueError('Reviewed source/update conditions changed: '+', '.join(changed))
    pins = json.loads(owned(root, 'Package.resolved'))['pins']
    sparkle = [p for p in pins if p.get('identity') == 'sparkle']
    if (len(sparkle) != 1 or sparkle[0].get('location') != 'https://github.com/'+COMPONENT+'.git'
            or sparkle[0].get('state') != {'version': VERSION, 'revision': REVISION}):
        raise ValueError('Reviewed Sparkle source version changed')
    commit = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=root, capture_output=True,
                            text=True, check=True, timeout=20).stdout.strip()
    if not re.fullmatch('[a-f0-9]{40}', commit): raise ValueError('Invalid source checkout identity')
    return {'kind': 'reviewed-source', 'checkoutCommit': commit, 'sourceSHA256': hashes,
            'scopeLimit': 'standard official build path; not proof of an arbitrary built App'}


def asset_evidence(root, directory, policy, *, version, build=None, commit=None):
    for name in ('scripts/verify-signed-release.py', 'scripts/security-python.sh', 'scripts/python-openssl-env.sh'):
        if sha(owned(root, name)) != policy['sourceSHA256'][name]:
            raise ValueError('Reviewed artifact verification entry changed')
    key = owned(root, 'Config/Release/SparklePublicKey.txt')
    if sha(key) != policy['publicKeySHA256']:
        raise ValueError('Official product key changed')
    command = [str(root/'scripts/security-python.sh'), str(root/'scripts/verify-signed-release.py'),
        '--assets', str(directory), '--public-key-file', str(root/'Config/Release/SparklePublicKey.txt'),
        '--base-url', BASE_URL, '--version', version]
    if build is not None: command += ['--build', build]
    if commit is not None: command += ['--commit', commit]
    verified = json.loads(subprocess.run(command, check=True, capture_output=True, timeout=60).stdout)
    dependencies = [p for p in verified['dependencies'] if p.get('name') == 'https://github.com/'+COMPONENT]
    if (len(dependencies) != 1 or dependencies[0].get('version') != VERSION
            or dependencies[0].get('revision') != REVISION):
        raise ValueError('Signed Sparkle dependency changed')
    archive = directory/verified['archive']
    with zipfile.ZipFile(archive) as z:
        entries = z.infolist(); names = [i.filename for i in entries]
        if (len(entries) > 20000 or len(names) != len(set(names))
                or sum(i.file_size for i in entries) > 256*1024*1024
                or any('\\' in n or n.startswith('/') or '..' in PurePosixPath(n).parts
                       or n.split('/')[0] not in ('MyTerm.app', '__MACOSX')
                       or any(p.lower().endswith(('.pkg', '.mpkg')) for p in PurePosixPath(n).parts)
                       for n in names)):
            raise ValueError('Not the reviewed App-only archive')
        def plist(name):
            i = z.getinfo(name)
            if i.file_size > 1024*1024 or stat.S_ISLNK(i.external_attr >> 16):
                raise ValueError('Invalid bundle metadata')
            return plistlib.loads(z.read(i))
        info = plist('MyTerm.app/Contents/Info.plist')
        expected = {'CFBundleIdentifier': BUNDLE, 'CFBundleShortVersionString': version,
                    'CFBundleVersion': verified['build'], 'SUFeedURL': BASE_URL+'/appcast.xml',
                    'SUPublicEDKey': key.decode().strip()}
        if (any(info.get(k) != v for k, v in expected.items())
                or info.get('SURequireSignedFeed') is not True
                or info.get('SUVerifyUpdateBeforeExtraction') is not True
                or info.get('MyTermUpdateLabMode') or info.get('MyTermDevelopmentMode')):
            raise ValueError('Released App update protection or product changed')
        frameworks = [n for n in names if re.fullmatch(
            r'MyTerm\.app/Contents/Frameworks/Sparkle\.framework/Versions/[A-Z]/Resources/Info\.plist', n)]
        if len(frameworks) != 1:
            raise ValueError('Missing unique Sparkle framework identity')
        framework = plist(frameworks[0])
        if framework.get('CFBundleIdentifier') != 'org.sparkle-project.Sparkle' or framework.get('CFBundleShortVersionString') != VERSION:
            raise ValueError('Actual Sparkle framework differs')
    # The already authenticated feed also must select the bundle installer,
    # never a package installation attribute hidden behind a .zip filename.
    import xml.etree.ElementTree as ET
    feed = ET.fromstring((directory/'appcast.xml').read_bytes())
    install_key = '{http://www.andymatuschak.org/xml-namespaces/sparkle}installationType'
    if any(e.get(install_key) not in (None, 'application') for e in feed.iter()):
        raise ValueError('Package installation requested by signed feed')
    if {p.name: sha(p.read_bytes()) for p in directory.iterdir()} != verified['hashes']:
        raise ValueError('Verified asset bytes changed during inspection')
    return {'kind': 'authenticated-app-bundle', **verified, 'bundleIdentifier': BUNDLE,
            'requireSignedFeed': True, 'publicKeySHA256': policy['publicKeySHA256']}


def released_evidence(root, policy, tag, read, fetch):
    if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag or ''):
        raise ValueError('Missing exact stable release identity')
    release = read(f'repos/{REPO}/releases/latest')
    if release.get('tag_name') != tag or release.get('draft') is not False or release.get('prerelease') is not False:
        raise ValueError('Released App changed during observation')
    commit = read(f'repos/{REPO}/commits/{tag}')['sha']
    if not re.fullmatch('[a-f0-9]{40}', commit): raise ValueError('Invalid release commit')
    assets = release['assets']; names = [a['name'] for a in assets]
    pattern = r'MyTerm-'+re.escape(tag[1:])+r'-build-([1-9][0-9]*)-arm64\.zip'
    archives = [re.fullmatch(pattern, name) for name in names if re.fullmatch(pattern, name)]
    if (len(archives) != 1 or len(names) != 5 or len(names) != len(set(names))
            or set(names)-{archives[0][0]} != {'appcast.xml', 'release-notes.html', 'CHECKSUMS.txt', 'release-manifest.json'}):
        raise ValueError('Release assets do not match reviewed App format')
    with tempfile.TemporaryDirectory(prefix='myterm-sparkle-review-') as directory:
        directory = Path(directory)
        for asset in assets:
            raw = fetch(asset)
            if not 0 < len(raw) == asset.get('size', 0) <= 25*1024*1024:
                raise ValueError('Unbounded or incomplete release asset')
            (directory/asset['name']).write_bytes(raw)
        proof = asset_evidence(root, directory, policy, version=tag[1:], build=archives[0][1], commit=commit)
    current = read(f'repos/{REPO}/releases/latest')
    project = lambda r: {'id': r['id'], 'tag': r['tag_name'], 'draft': r['draft'], 'prerelease': r['prerelease'],
        'assets': sorted([a['id'], a['name'], a['size'], a.get('digest'), a.get('updated_at')] for a in r['assets'])}
    if project(current) != project(release) or read(f'repos/{REPO}/commits/{tag}')['sha'] != commit:
        raise ValueError('Release evidence changed while reading')
    return {**proof, 'releaseTag': tag, 'releaseIdentity': project(release)}


def target(f):
    return f.get('id') == ID and f.get('component') == COMPONENT and f.get('scope') in SCOPES


def evaluate(report, root=ROOT, read=None, fetch=None):
    read = read or (lambda endpoint: reader(root, endpoint))
    fetch = fetch or (lambda asset: download(root, asset))
    scopes = ['current-source'] + (['released-app'] if report.get('sparkleReleaseRequested') else [])
    outcomes = []
    for scope in scopes:
        row = {'id': ID, 'component': COMPONENT, 'scope': scope, 'decision': DECISION,
               'status': 'needs-review', 'grantsRiskException': False}
        try:
            policy, policy_hash = configuration(root)
            advisory = checked_advisory(root, policy, read)
            proof = (source_evidence(root, policy) if scope == 'current-source' else
                     released_evidence(root, policy, report.get('releaseTag'), read, fetch))
            row.update(status='not-affected', version=VERSION, reason=REASON,
                       evidenceStatus='verified', policySHA256=policy_hash, advisorySHA256=advisory, evidence=proof)
        except Exception as error:
            detail = str(error) if type(error) is ValueError else type(error).__name__
            row['reason'] = '目前用途不適用的證據失效或無法完成核對；保留待審：'+detail
            row['evidenceStatus'] = 'changed' if type(error) is ValueError else 'unavailable'
        outcomes.append(row)
    return {'schemaVersion': 1, 'checkedAt': report['checkedAt'], 'outcomes': outcomes}


def covers(row, finding):
    return (target(finding) and all(row.get(k) == finding.get(k) for k in ('id', 'component', 'scope', 'version'))
            and row.get('status') == 'not-affected'
            and (finding['scope'] != 'released-app' or
                 finding.get('releaseTag') == row.get('evidence', {}).get('releaseTag')))


def classify(report, root=ROOT, read=None, fetch=None):
    if 'sparkleApplicability' in report: raise ValueError('Fresh Sparkle review required')
    result = evaluate(report, root, read, fetch); report['sparkleApplicability'] = result
    for row in result['outcomes']:
        if row['evidenceStatus'] == 'unavailable':
            report.setdefault('errors', []).append('Sparkle applicability unavailable: '+row['scope'])
    report.setdefault('rawFindings', copy.deepcopy(report['findings']))
    report['sparkleApplicabilityReviews'] = [
        {'finding': copy.deepcopy(f), 'proof': r} for f in report['findings']
        for r in result['outcomes'] if f.get('queryComplete') is True and covers(r, f)]
    report['findings'] = [f for f in report['findings'] if not (f.get('queryComplete') is True
        and any(covers(r, f) for r in result['outcomes']))]


def validate_envelope(report):
    value = report.get('sparkleApplicability')
    if value is None:
        if report.get('sparkleApplicabilityReviews'):
            raise ValueError('Missing Sparkle applicability envelope')
        return
    rows = value.get('outcomes', [])
    expected = {'current-source'} | ({'released-app'} if report.get('sparkleReleaseRequested') else set())
    if (value.get('schemaVersion') != 1 or value.get('checkedAt') != report.get('checkedAt')
            or len(rows) != len(expected) or {r.get('scope') for r in rows} != expected):
        raise ValueError('Invalid Sparkle scope evidence')
    for row in rows:
        if (not target(row) or row.get('decision') != DECISION or row.get('grantsRiskException') is not False
                or row.get('status') not in ('not-affected', 'needs-review')
                or row.get('evidenceStatus') not in ('verified','changed','unavailable')
                or (row['status']=='not-affected') != (row['evidenceStatus']=='verified')):
            raise ValueError('Invalid Sparkle decision')
        if row['status'] == 'not-affected' and (row.get('version') != VERSION
                or any(not HEX.fullmatch(row.get(k, '')) for k in ('policySHA256', 'advisorySHA256'))
                or not isinstance(row.get('evidence'), dict)):
            raise ValueError('Incomplete Sparkle evidence')
        if (row['status'] == 'not-affected' and row['scope'] == 'current-source'
                and row['evidence'].get('checkoutCommit') != report.get('sourceReview', {}).get('checkoutCommit')):
            raise ValueError('Source applicability belongs to another checkout')
    reviews = report.get('sparkleApplicabilityReviews', [])
    if not isinstance(reviews, list) or len(reviews) > len(SCOPES):
        raise ValueError('Invalid Sparkle exclusion partition')
    for review in reviews:
        if (review.get('proof') not in rows or review.get('finding', {}).get('queryComplete') is not True
                or not covers(review['proof'], review['finding'])):
            raise ValueError('Sparkle evidence does not cover raw finding')


def revalidate(report, root=ROOT, read=None, fetch=None):
    validate_envelope(report)
    if 'sparkleApplicability' not in report: return
    if digest(evaluate(report, root, read, fetch)) != digest(report['sparkleApplicability']):
        raise ValueError('Sparkle applicability changed; recheck and reopen original Issues')


def filtered(report, findings):
    validate_envelope(report)
    return [f for f in findings if not any(covers(r, f) for r in report.get('sparkleApplicability', {}).get('outcomes', []))]


def previous_decision(report, finding):
    validate_envelope(report)
    return next((r for r in report.get('sparkleApplicability', {}).get('outcomes', []) if covers(r, finding)), None)


def owned_resolution(snapshot, number):
    f = snapshot.get('finding', {}); r = snapshot.get('applicabilityResolution', {})
    return (target(f) and SCOPES[f['scope']] == number and r.get('decision') == DECISION
            and HEX.fullmatch(r.get('proofSHA256', '')) is not None)


def delivery_decision(report, ctx, root, read):
    """Internal publication scope: never reuse source or an older release proof."""
    rows = [(i, f) for i, f in enumerate(report['findings']) if f.get('id') == ID
            and f.get('component') == COMPONENT and f.get('scope') == 'delivery-app']
    if not rows: return []
    policy, _ = configuration(root); checked_advisory(root, policy, read)
    proof = ctx.get('sparkleDeliveryEvidence', {})
    if (ctx.get('stage') not in ('publish', 'deploy')
            or proof.get('kind') != 'authenticated-app-bundle'
            or proof.get('bundleIdentifier') != BUNDLE or proof.get('requireSignedFeed') is not True
            or proof.get('publicKeySHA256') != policy['publicKeySHA256']
            or proof.get('hashes') != ctx.get('assetHashes') or not proof.get('hashes')
            or proof.get('dependencies') != ctx.get('deliveryInventory')
            or proof.get('commit') != ctx.get('releaseCommit')
            or proof.get('version') != ctx.get('version') or proof.get('build') != ctx.get('build')
            or any(f.get('version') != VERSION or f.get('queryComplete') is not True for _, f in rows)):
        raise ValueError('Current delivery lacks independent App applicability evidence')
    return [{'findingIndex': i, 'id': ID, 'scope': 'delivery-app',
             'classification': 'verified-app-bundle-use', 'issueDisposition': 'delivery-only',
             'reason': REASON} for i, _ in rows]
