#!/usr/bin/env python3
"""Bounded, read-only tool identities. Inventory is never a vulnerability verdict.

No installation, package entry points, lifecycle scripts or cloud credentials.
The probe subcommand runs only in the project's existing trusted Python venvs.
"""
import argparse
import ast
import hashlib
import importlib.metadata
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import ssl
import subprocess
import sys
import sysconfig
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
POLICY = 'Config/Security/toolchain-inventory.json'
MAX_FILE = 8 * 1024 * 1024
MAX_COMPONENTS = 10000
ID = re.compile(r'[A-Za-z0-9@][A-Za-z0-9@._/+:-]{0,239}\Z')


def read(path, base=None, limit=MAX_FILE):
    path = Path(path)
    if base is not None and not path.resolve().is_relative_to(Path(base).resolve()):
        raise ValueError('Metadata escapes its reviewed root')
    if not path.is_file() or path.stat().st_size > limit:
        raise ValueError('Missing or oversized metadata')
    raw = path.read_bytes()
    if len(raw) > limit:
        raise ValueError('Metadata grew past limit')
    return raw


def document(path, base=None):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('Duplicate metadata field')
            result[key] = value
        return result
    return json.loads(read(path, base), object_pairs_hook=pairs)


def canonical_name(value):
    if not isinstance(value, str) or not ID.fullmatch(value):
        raise ValueError('Invalid component name')
    return re.sub(r'[-_.]+', '-', value).lower()


def component(ecosystem, name, version, origin, **extra):
    if (not isinstance(name, str) or not ID.fullmatch(name) or not isinstance(version, str)
            or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.+_:-]{0,127}', version)):
        raise ValueError('Incomplete component identity')
    if ecosystem == 'PyPI':
        name = canonical_name(name)
    return {'ecosystem': ecosystem, 'name': name, 'version': version, 'origin': origin,
            'advisoryStatus': 'not-queried', **extra}


def vendor_rows(text, origin):
    rows = []
    seen = set()
    for line in text.splitlines():
        line = line.split('#', 1)[0].strip()
        if not line:
            continue
        match = re.fullmatch(r'([A-Za-z0-9_.-]+)==([A-Za-z0-9.+_-]+)', line)
        if not match:
            raise ValueError('Unknown pip vendor declaration')
        name, version = match.groups()
        name = canonical_name(name)
        if name in seen:
            raise ValueError('Duplicate pip vendor identity')
        seen.add(name)
        rows.append(component('PyPI', name, version, origin + '/pip-vendored',
                              evidence='pip/_vendor/vendor.txt', relationship='vendored',
                              runtimeReachability='not-established'))
    if not rows or len(rows) > 256:
        raise ValueError('Incomplete or oversized vendor inventory')
    return rows


def rust_rows(sbom, origin):
    rows = []
    for item in sbom.get('components', []):
        purl = item.get('purl', '')
        # Local path crates belong to the wheel, not crates.io releases.
        if purl.startswith('pkg:cargo/') and '?' not in purl:
            match = re.fullmatch(r'pkg:cargo/([A-Za-z0-9_-]+)@([A-Za-z0-9.+_-]+)', purl)
            if not match or match[1] != item.get('name') or match[2] != item.get('version'):
                raise ValueError('Invalid Rust package identity')
            rows.append(component('crates.io', match[1], match[2], origin + '/cryptography-sbom',
                                  relationship='upstream-sbom-candidate',
                                  runtimeReachability='not-established'))
    if not rows:
        raise ValueError('Missing external Rust SBOM identities')
    return rows


def python_probe():
    """Metadata only, plus version APIs from already pinned cryptography."""
    prefix = Path(sys.prefix).resolve()
    if sys.prefix == sys.base_prefix or not Path(sysconfig.get_path('purelib')).resolve().is_relative_to(prefix):
        raise ValueError('Probe requires an isolated venv')
    rows = []
    seen = set()
    for dist in importlib.metadata.distributions():
        name = canonical_name(dist.metadata['Name'])
        if name in seen or not Path(dist.locate_file('')).resolve().is_relative_to(prefix):
            raise ValueError('Duplicate or external installed Python distribution')
        seen.add(name)
        rows.append(component('PyPI', name, dist.version, 'python-environment', relationship='installed'))
        if name == 'pip':
            vendor = Path(dist.locate_file('pip/_vendor/vendor.txt'))
            rows += vendor_rows(read(vendor, prefix).decode(), 'python-environment')
        if name == 'cryptography':
            sboms = [x for x in (dist.files or []) if str(x).endswith('cryptography-rust.cyclonedx.json')]
            if len(sboms) != 1:
                raise ValueError('Missing cryptography wheel SBOM')
            rows += rust_rows(document(dist.locate_file(sboms[0]), prefix), 'python-environment')
    native = {'python': sys.version.split()[0], 'python-implementation': sys.implementation.name,
              'openssl': ssl.OPENSSL_VERSION}
    import zlib
    native.update(zlib=zlib.ZLIB_RUNTIME_VERSION)
    # This is a version read of the existing pinned verification dependency,
    # not an untrusted arbitrary distribution import or certificate test.
    if 'cryptography' in seen:
        from cryptography.hazmat.backends.openssl.backend import backend
        native['cryptography-openssl'] = backend.openssl_version_text()
    linkage = []
    if 'cffi' in seen:
        dist = importlib.metadata.distribution('cffi')
        binaries = [Path(dist.locate_file(x)) for x in (dist.files or [])
                    if Path(x).name.startswith('_cffi_backend') and str(x).endswith(('.so','.pyd'))]
        if len(binaries) != 1 or not binaries[0].resolve().is_relative_to(prefix):
            raise ValueError('Missing or external cffi native binary')
        binary = binaries[0]
        if sys.platform == 'darwin':
            result = subprocess.run(['/usr/bin/otool','-L',str(binary)],capture_output=True,text=True,timeout=10,check=True)
            for line in result.stdout.splitlines()[1:]:
                name = line.strip().split(' ',1)[0]
                linkage.append({'component':'cffi-native-link','library':Path(name).name,
                                'provider':'Apple system library' if name.startswith('/usr/lib/') else 'additional identity review required',
                                'versionMeaning':'Mach-O compatibility/current values are not upstream package versions'})
        elif sys.platform.startswith('linux'):
            result = subprocess.run(['readelf','-d',str(binary)],capture_output=True,text=True,timeout=10,check=True)
            linkage.extend({'component':'cffi-native-link','library':name,'provider':'distribution or wheel; version mapping required'}
                           for name in re.findall(r'\(NEEDED\).*?\[([^]\n]+)\]',result.stdout))
        else:
            raise ValueError('cffi platform native collector is not implemented')
        linkage.append({'component':'cffi-native-binary','sha256':hashlib.sha256(read(binary,prefix,64*1024*1024)).hexdigest(),
                        'advisoryStatus':'vendor-mapping-required'})
    spec = importlib.util.spec_from_file_location('openssl_supplier', ROOT/'scripts/security-openssl-supplier.py')
    supplier = importlib.util.module_from_spec(spec); spec.loader.exec_module(supplier)
    try:
        loaded = supplier.probe()
    except Exception as error:
        loaded = {'status': 'unavailable', 'error': type(error).__name__,
                  'reason': str(error) if type(error) is ValueError else 'Process identity query failed'}
    return {'prefix': str(prefix), 'basePrefix': sys.base_prefix, 'components': rows, 'native': native,
            'nativeLinkage':linkage, 'opensslLoaded': loaded}


def run_json(args, cwd=ROOT):
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=30,
                            env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
    if result.returncode or len(result.stdout) > MAX_FILE:
        raise ValueError('Tool identity probe failed')
    return json.loads(result.stdout)


def collect_python(root):
    rows = []
    evidence = []
    requirements = dict(re.findall(r'^([\w-]+)==([\w.]+)',
                                  read(root/'Tests/Security/requirements.txt', root).decode(), re.M))
    required = {canonical_name(k): v for k, v in requirements.items()}
    for role in ('python-runtime', 'security-tools'):
        prefix = root/'.build'/role
        info = run_json([str(prefix/'bin/python3'), '-I', '-B', str(root/'scripts/security-toolchain-inventory.py'),
                         '--probe-python'], root)
        if Path(info['prefix']).resolve() != prefix.resolve() or prefix.is_symlink():
            raise ValueError('Unexpected Python environment')
        installed = {c['name']: c['version'] for c in info['components'] if c['relationship'] == 'installed'}
        if role == 'security-tools' and any(installed.get(k) != v for k, v in required.items()):
            raise ValueError('Installed verification tools differ from requirements')
        if not {'pip', 'certifi'} <= installed.keys():
            raise ValueError('Missing managed Python tools')
        for row in info['components']:
            row['origin'] = role + row['origin'].removeprefix('python-environment')
            rows.append(row)
        for name, version in info['native'].items():
            # Native vendor strings remain separate from ecosystem versions.
            evidence.append({'role': role, 'component': name, 'vendorVersion': version,
                             'advisoryStatus': 'vendor-mapping-required',
                             **({'loadedEvidence': info.get('opensslLoaded')} if name == 'openssl' else {})})
        evidence.extend({'role':role,**row} for row in info.get('nativeLinkage',[]))
    return rows, evidence


def package_files(root):
    """Only package installation boundaries; never test/fixture package.jsons."""
    stack = [root/'node_modules']
    count = 0
    while stack:
        directory = stack.pop()
        if not directory.exists():
            continue
        if not directory.resolve().is_relative_to(root.resolve()):
            raise ValueError('Package tree escapes its reviewed root')
        for entry in sorted(directory.iterdir()):
            if entry.name.startswith('.'):
                continue
            packages = sorted(entry.iterdir()) if entry.name.startswith('@') and entry.is_dir() else [entry]
            for package in packages:
                path = package/'package.json'
                if not path.is_file():
                    continue
                count += 1
                if count > MAX_COMPONENTS:
                    raise ValueError('Package tree exceeds limit')
                yield path
                stack.append(package/'node_modules')


def npm_rows(root, origin):
    rows = []
    manifests = [root/'package.json', *package_files(root)]
    for path in manifests:
        doc = document(path, root)
        row = component('npm', doc['name'], doc['version'], origin,
                        evidence=str(path.relative_to(root)), relationship='installed')
        dependencies = {}
        for field in ('dependencies', 'optionalDependencies'):
            deps = doc.get(field, {})
            if not isinstance(deps, dict):
                raise ValueError('Invalid npm dependency declarations')
            for name, constraint in deps.items():
                if not ID.fullmatch(name) or not isinstance(constraint, str) or len(constraint) > 512:
                    raise ValueError('Invalid npm dependency identity')
                dependencies[name] = {'range': constraint, 'optional': field == 'optionalDependencies'}
        row['dependencies'] = dependencies
        row['resolvedDependencies'] = {}
        for name, declaration in dependencies.items():
            if not re.fullmatch(r'(?:@[A-Za-z0-9_.-]+/)?[A-Za-z0-9_.-]+', name):
                raise ValueError('Invalid npm package path')
            directory = path.parent
            resolved = None
            while directory.resolve().is_relative_to(root.resolve()):
                candidate = directory/'node_modules'/name/'package.json'
                if candidate.is_file():
                    target = document(candidate, root)
                    alias = re.fullmatch(r'npm:((?:@[A-Za-z0-9_.-]+/)?[A-Za-z0-9_.-]+)@(.+)', declaration['range'])
                    expected_name = alias[1] if alias else name
                    if target.get('name') != expected_name or not isinstance(target.get('version'), str):
                        raise ValueError('Resolved npm dependency identity differs')
                    resolved = {'path': str(candidate.relative_to(root)), 'name': target['name'], 'version': target['version']}
                    break
                if directory == root:
                    break
                directory = directory.parent
            if resolved is None and not declaration['optional']:
                raise ValueError('Missing required installed npm dependency: '+name)
            row['resolvedDependencies'][name] = resolved
        rows.append(row)
    return rows


def lock_rows(path, origin):
    doc = document(path)
    if doc.get('lockfileVersion') not in (2, 3) or not isinstance(doc.get('packages'), dict):
        raise ValueError('Unsupported npm lock format')
    rows = []
    for key, item in doc['packages'].items():
        if not key:
            continue
        if not key.startswith('node_modules/') or '..' in Path(key).parts or item.get('link'):
            raise ValueError('Unreviewed npm lock path/link')
        name = item.get('name') or key.rsplit('node_modules/', 1)[-1]
        rows.append(component('npm', name, item['version'], origin, evidence=key,
                              relationship='locked', optional=bool(item.get('optional'))))
    if not rows or len(rows) > MAX_COMPONENTS:
        raise ValueError('Incomplete or oversized lock inventory')
    return rows


def collect_project_npm(root):
    locked = lock_rows(root/'package-lock.json', 'project-npm')
    actual = {row['evidence'].removesuffix('/package.json'): row for row in npm_rows(root, 'project-npm')
              if row['evidence'] != 'package.json'}
    expected = {r['evidence']: r for r in locked}
    for path, row in expected.items():
        installed = actual.get(path)
        if installed is None and row['optional']:
            continue  # Platform-optional absence is explicit lock evidence.
        if installed is None or any(installed[k] != row[k] for k in ('name', 'version')):
            raise ValueError('Installed npm package differs from lock: ' + path)
    if set(actual) - set(expected):
        raise ValueError('Installed npm tree contains untracked package identities')
    return locked, [{'lockedNodes': len(locked), 'installedNodes': len(actual),
                     'lockSHA256':hashlib.sha256(read(root/'package-lock.json',root)).hexdigest(),
                     'optionalAbsent': sorted(set(expected)-set(actual))}]


def collect_node(root):
    info = run_json([str(root/'scripts/project-node.sh'), '-p',
                     'JSON.stringify({executable:process.execPath,versions:process.versions})'], root)
    exe = Path(info['executable']).resolve()
    npm = root/'.build/npm-runtime'
    run = subprocess.run([str(root/'scripts/project-python.sh'), '-B', str(root/'scripts/node-toolchain.py'), 'verify'],
                         cwd=root, capture_output=True, text=True, timeout=30)
    if run.returncode or Path(run.stdout.strip()) != npm/'bin/npm-cli.js':
        raise ValueError('Selected npm does not match the official reviewed archive')
    rows = npm_rows(npm, 'project-npm-tool')
    bundled = document(exe.parent.parent/'lib/node_modules/npm/package.json')
    inactive = {'component': 'distribution-bundled-npm', 'version': bundled['version'],
                'usage': 'not selected by project npm entry; retained in unmodified Node distribution',
                'advisoryStatus': 'not-applicable-to-selected-tool', 'notProofOfRemediation': True}
    # These are separately shipped JS packages inside Node, not npm's graph.
    for key in ('undici', 'acorn', 'amaro'):
        if info['versions'].get(key):
            rows.append(component('npm', key, info['versions'][key], 'node-runtime/'+key, relationship='embedded'))
    return rows, [inactive, *[{'component': k, 'vendorVersion': v, 'role': 'node-runtime',
                   'advisoryStatus': 'vendor-mapping-required'} for k, v in info['versions'].items()
                  if k not in ('modules', 'napi') and v]]


def jar_metadata(path, expected_sha256):
    """Hash and inspect the same open file; never extract or execute the JAR."""
    if not re.fullmatch('[a-f0-9]{64}', expected_sha256):
        raise ValueError('Missing expected JAR hash')
    rows = []
    total = 0
    with Path(path).open('rb') as stream:
        before = os.fstat(stream.fileno())
        if not 0 < before.st_size <= 256 * 1024 * 1024:
            raise ValueError('JAR size exceeds reviewed limit')
        h = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024*1024), b''):
            h.update(chunk)
        if h.hexdigest() != expected_sha256:
            raise ValueError('JAR differs from reviewed declaration')
        stream.seek(0)
        with zipfile.ZipFile(stream) as archive:
            entries = archive.infolist()
            if len(entries) > 100000:
                raise ValueError('JAR metadata entry limit exceeded')
            metadata_candidates = [i.filename for i in entries if
                'sbom' in i.filename.lower() or 'cyclonedx' in i.filename.lower()
                or 'spdx' in i.filename.lower() or i.filename.lower().endswith('.jar')]
            for item in entries:
                if not item.filename.startswith('META-INF/maven/') or not item.filename.endswith('/pom.properties'):
                    continue
                if '..' in Path(item.filename).parts or item.file_size > 65536:
                    raise ValueError('Invalid JAR metadata member')
                total += item.file_size
                if total > MAX_FILE:
                    raise ValueError('JAR metadata total limit exceeded')
                text = archive.read(item).decode('utf-8')
                pairs = re.findall(r'^(groupId|artifactId|version)\s*=\s*([^\r\n]+)$', text, re.M)
                props = dict(pairs)
                if len(pairs) != 3 or set(props) != {'groupId', 'artifactId', 'version'}:
                    raise ValueError('Incomplete or duplicate Maven identity')
                rows.append(component('Maven', props['groupId']+':'+props['artifactId'], props['version'],
                                      'firestore-emulator', relationship='jar-metadata'))
        after = os.fstat(stream.fileno())
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise ValueError('JAR changed during inspection')
    return {'components': rows, 'coverage': 'partial', 'entryCount': len(entries),
            'metadataCandidates': metadata_candidates, 'sha256': h.hexdigest(), 'size': before.st_size,
            'limitation': 'Maven metadata does not establish all shaded code identities'}


def collect_emulator(root):
    """The approved supplier boundary is exact, not a general opaque-file waiver."""
    policy = document(root/POLICY, root)
    decisions = [d for d in policy.get('supplierBoundaries', [])
                 if d.get('component') == 'firestore-emulator']
    if len(decisions) != 1:
        raise ValueError('Missing or ambiguous Firestore supplier boundary')
    decision = decisions[0]
    if (decision.get('state') != 'accepted' or
            decision.get('kind') != 'supplier-managed-limited-subdependency-evidence' or
            decision.get('knownVulnerabilityWaiver') is not False or
            decision.get('subdependencyCoverage') != 'unavailable-from-supplier'):
        raise ValueError('Unaccepted or expanded supplier boundary')
    manifest = document(root/'node_modules/firebase-tools/package.json', root)
    lock = document(root/'package-lock.json', root)
    if (manifest.get('name') != 'firebase-tools' or
            manifest.get('version') != decision['firebaseToolsVersion'] or
            lock['packages']['node_modules/firebase-tools']['version'] != decision['firebaseToolsVersion']):
        raise ValueError('Firestore parent tool differs from accepted boundary')
    declaration = document(root/'node_modules/firebase-tools/lib/emulator/downloadableEmulatorInfo.json', root)['firestore']
    fields = {'version': 'version', 'expectedSize': 'size', 'expectedChecksumSHA256': 'sha256',
              'remoteUrl': 'url', 'downloadPathRelativeToCacheDir': 'filename'}
    if any(declaration.get(k) != decision[v] for k, v in fields.items()):
        raise ValueError('Firestore declaration differs from accepted boundary')
    filename = decision['filename']
    if not re.fullmatch(r'cloud-firestore-emulator-v[0-9.]+\.jar', filename):
        raise ValueError('Unexpected Firestore artifact path')
    # Inventory download and operational cache are distinct. If the operational
    # copy exists it must agree too; an older reviewed download cannot hide drift.
    candidates = [root/'.build/security-inventory-artifacts'/filename, root/'.firebase/emulators'/filename]
    present = [p for p in candidates if p.exists() or p.is_symlink()]
    if not present:
        raise ValueError('Missing actual Firestore artifact evidence')
    checked = []
    for path in present:
        if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
            raise ValueError('Firestore artifact escapes managed storage')
        if path.stat().st_size != decision['size']:
            raise ValueError('Firestore artifact size differs')
        info = jar_metadata(path, decision['sha256'])
        if (info['entryCount'] != decision['entryCount'] or info['components'] or info['metadataCandidates']):
            raise ValueError('New supplier metadata requires coverage reassessment')
        checked.append(str(path.relative_to(root)))
    return [], [{'component': 'firestore-emulator', 'version': decision['version'],
                 'firebaseToolsVersion': decision['firebaseToolsVersion'], 'sha256': decision['sha256'],
                 'size': decision['size'], 'source': decision['url'], 'verifiedArtifacts': checked,
                 'boundaryId': decision['id'], 'coverageStatus': 'supplier-managed-limited',
                 'subdependencyCoverage': 'unavailable-from-supplier', 'allDependenciesScanned': False,
                 'knownVulnerabilityWaiver': False, 'advisoryStatus': 'not-queried',
                 'noticeSources': decision['noticeSources'], 'use': decision['use'],
                 'limitation': 'Supplier JAR has no complete versioned subdependency evidence'}]


def collect_deployment(root):
    manifest = document(root/'Tools/Deployment/package.json', root)
    rows, installed_evidence = collect_project_npm(root/'Tools/Deployment')
    for row in rows:
        row['origin'] = 'deployment-wrangler'
    version = manifest.get('dependencies', {}).get('wrangler')
    top = [r for r in rows if r['evidence'] == 'node_modules/wrangler']
    workflow = read(root/'.github/workflows/deploy-update-site.yml', root).decode()
    if (len(top) != 1 or top[0]['version'] != version or
            './scripts/project-node.sh --npm ci --prefix Tools/Deployment --ignore-scripts' not in workflow or
            './scripts/project-node.sh Tools/Deployment/node_modules/wrangler/bin/wrangler.js pages deploy ' not in workflow or
            'uses: cloudflare/wrangler-action@' in workflow):
        raise ValueError('Deployment must use the reviewed isolated lock and CLI')
    return rows, [*installed_evidence, {'graph': 'lock and installed package metadata agree', 'actualDeployment': 'not-run',
                   'nativeBinaries': 'identity-review-required'}]


def collect_app(root):
    lock=document(root/'Package.resolved',root)
    pins=lock.get('pins',[])
    if not pins or any(p.get('kind')!='remoteSourceControl' for p in pins):
        raise ValueError('Unsupported Swift dependency identity')
    declarations=read(root/'Package.swift',root).decode()
    urls=set(re.findall(r'url:\s*"([^"\n]+)"',declarations))
    if urls!={p['location'] for p in pins}:
        raise ValueError('Swift package declarations differ from locked inventory')
    native=document(root/'Config/Security/native-components.json',root)
    vendor=read(root/'Vendor/SwiftTerm/UPSTREAM.md',root).decode()
    revision=re.search(r'Revision: `([a-f0-9]{40})`',vendor)
    if revision is None:raise ValueError('Missing vendored SwiftTerm source')
    evidence=[{'component':p['identity'],'version':p['state']['version'],'revision':p['state']['revision'],
               'provider':'existing runtime advisory collector'} for p in pins]
    evidence.extend([{'component':'SwiftTerm','revision':revision[1],'provider':'existing vendored runtime collector'},
                     {'component':'libsodium','version':native['libsodium']['version'],'provider':'existing native runtime collector'},
                     {'component':'Sparkle publishing tools','relationship':'same locked artifact','nativeCoverage':'additional binary identities require review'}])
    evidence.append({'sourceSHA256':{name:hashlib.sha256(read(root/name,root)).hexdigest() for name in (
        'Package.swift','Package.resolved','Vendor/SwiftTerm/UPSTREAM.md','Config/Security/native-components.json')}})
    return [],evidence


def action_bundle(root, repo, revision):
    policy = document(root/'Config/Security/action-bundles.json', root)
    matches = [b for b in policy.get('bundles',[]) if b.get('repository')==repo and b.get('revision')==revision]
    if len(matches)!=1:
        raise ValueError('Action revision has no reviewed bundle inventory')
    bundle=matches[0]
    expected_url=f'https://codeload.github.com/{repo}/tar.gz/{revision}'
    expected_cache=f'.build/security-inventory-actions/{repo.replace("/","-")}-{revision}.tgz'
    if bundle.get('url')!=expected_url or bundle.get('cacheFile')!=expected_cache:
        raise ValueError('Action inventory source differs')
    blob=read(root/expected_cache,root,64*1024*1024)
    if hashlib.sha256(blob).hexdigest()!=bundle['archiveSHA256']:
        raise ValueError('Action archive differs from pinned source')
    files={};total=0
    with tarfile.open(fileobj=io.BytesIO(blob),mode='r:gz') as archive:
        for index,item in enumerate(archive):
            if index>20000:raise ValueError('Action archive entry limit exceeded')
            parts=Path(item.name).parts
            if len(parts)<2:continue
            name='/'.join(parts[1:])
            wanted=(name in ('package.json','package-lock.json','action.yml') or
                    name.startswith('.licenses/npm/') and name.endswith('.dep.yml') or
                    name.startswith('dist/') and name.endswith('.js'))
            if not wanted:continue
            if not item.isfile() or '..' in parts or name in files or item.size>MAX_FILE:
                raise ValueError('Invalid action metadata member')
            total+=item.size
            if total>16*1024*1024:raise ValueError('Action metadata exceeds limit')
            files[name]=archive.extractfile(item).read().decode()
    lock=json.loads(files['package-lock.json'])
    if lock.get('lockfileVersion') not in (2,3):raise ValueError('Unsupported action lock')
    using=re.findall(r'^  using:\s*[\'\"]?(node[0-9]+)',files['action.yml'],re.M)
    if using!=['node24']:raise ValueError('Unreviewed action runtime')
    entrypoints={}
    for field in ('main','pre','post'):
        matches=re.findall(r'^  '+field+r':\s*[\'\"]?([^\s\'\"]+)',files['action.yml'],re.M)
        if len(matches)>1 or field=='main' and len(matches)!=1:
            raise ValueError('Missing or ambiguous action entrypoint')
        for name in matches:
            if not re.fullmatch(r'dist/[A-Za-z0-9_./-]+\.js',name) or '..' in Path(name).parts or name not in files:
                raise ValueError('Uninventoried action entrypoint')
            entrypoints[field]={'path':name,'sha256':hashlib.sha256(files[name].encode()).hexdigest()}
    licensed=set()
    for name,text in files.items():
        if not name.startswith('.licenses/npm/'):continue
        pair=[]
        for field in ('name','version'):
            found=re.findall('^'+field+r':\s*([^\n]+)',text,re.M)
            if len(found)!=1:raise ValueError('Incomplete action license identity')
            pair.append(found[0].strip().strip("'\""))
        licensed.add(tuple(pair))
    if not licensed:raise ValueError('Missing action supplier dependency evidence')
    rows=[]
    for path,item in lock['packages'].items():
        if not path or item.get('dev') or item.get('devOptional'):continue
        if not path.startswith('node_modules/') or '..' in Path(path).parts or item.get('link'):
            raise ValueError('Unreviewed action lock path')
        name=item.get('name') or path.rsplit('node_modules/',1)[-1]
        rows.append(component('npm',name,item['version'],f'action/{repo}@{revision}',
                              relationship='action-production-lock',runtimeReachability='not-established',
                              evidence=path,licenseConfirmed=(name,item['version']) in licensed))
    if not licensed<={(r['name'],r['version']) for r in rows}:
        raise ValueError('Action license and production lock identities differ')
    return rows,{'action':repo,'revision':revision,'runtime':'runner-provided node24; independent of setup-node',
                 'archiveSHA256':bundle['archiveSHA256'],'entrypoints':entrypoints,
                 'productionLockNodes':len(rows),'licensedIdentities':len(licensed),
                 'coverageMeaning':'Production dependency candidates; not proof all code is in the bundled execution path',
                 'parentAdvisory':'existing action collector','advisoryStatus':'not-queried'}


def collect_actions(root):
    refs={}
    for path in sorted((root/'.github/workflows').glob('*.yml')):
        text=read(path,root).decode()
        for line in text.splitlines():
            match=re.search(r'(?:^|\s)uses:\s*["\']?([^#\s"\']+)',line)
            if not match:continue
            exact=re.fullmatch(r'([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@([a-f0-9]{40})',match[1])
            if not exact:raise ValueError('New/unpinned/local action requires explicit coverage')
            refs.setdefault((exact[1],exact[2]),[]).append(str(path.relative_to(root)))
    if not refs:raise ValueError('Missing workflow actions')
    rows=[];evidence=[]
    policy=configuration(root)
    for (repo,revision),workflows in sorted(refs.items()):
        items,proof=action_bundle(root,repo,revision)
        uses={name:hashlib.sha256(read(root/name,root)).hexdigest() for name in workflows}
        decisions=[d for d in policy.get('supplierBoundaries',[]) if d.get('kind')=='action-bundle-limited-evidence'
                   and d.get('component')==repo and d.get('revision')==revision]
        if len(decisions)!=1:raise ValueError('Action bundle supplier boundary is not accepted')
        decision=decisions[0]
        if (decision.get('state')!='accepted' or decision.get('knownVulnerabilityWaiver') is not False or
                decision.get('archiveSHA256')!=proof['archiveSHA256'] or
                decision.get('entrypoints')!=proof['entrypoints'] or
                decision.get('url')!=f'https://codeload.github.com/{repo}/tar.gz/{revision}' or
                decision.get('runnerRuntimeCovered') is not False):
            raise ValueError('Action bundle identity, use or accepted boundary changed')
        rows.extend(items)
        evidence.append({**proof,'component':repo,'workflows':workflows,'workflowSHA256':uses,
                         'source':decision['url'],'boundaryId':decision['id'],
                         'coverageStatus':'supplier-managed-limited','allDependenciesScanned':False,
                         'knownVulnerabilityWaiver':False,'runnerRuntimeCovered':False})
    return rows,evidence


def collect_project_gh(root):
    import importlib.util
    def load_helper(name):
        spec=importlib.util.spec_from_file_location(name,root/'scripts'/f'{name}.py')
        helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper);return helper
    gh_runtime=load_helper('project-gh-runtime')
    gh_binary=gh_runtime.verify(root)
    gh_version=gh_runtime.policy(root)['version']
    go=load_helper('go-build-inventory').parse(gh_binary.read_bytes())
    parent=next(m for m in go['modules'] if m['kind']=='mod')
    if parent['name']!='github.com/cli/cli/v2' or parent['version']!='v'+gh_version:
        raise ValueError('Verified GitHub CLI module does not match package version')
    origin='platform/project-gh'
    components=[component('Go',m['name'],m['version'],origin,
                          relationship='official executable build metadata',runtimeReachability='not-established')
                for m in go['modules']]
    components.append(component('Go','stdlib',go['compiler'].removeprefix('go'),origin,
                                relationship='official executable Go runtime',runtimeReachability='not-established'))
    evidence=[{'component':'github-cli-build','version':gh_version,'compiler':go['compiler'],
                     'binarySHA256':gh_runtime.sha(gh_binary),'modules':len(go['modules']),
                     'provider':'official project-owned GitHub CLI','advisoryStatus':'not-queried'}]
    return components,evidence,gh_binary


def collect_platform(root):
    """Legacy collector id: only the project-selected GitHub CLI, never the OS."""
    rows, evidence, _ = collect_project_gh(root)
    return rows, evidence


def collect_java(root):
    """Read the JDK selected by the Rules wrapper, not the machine's OS state."""
    spec=importlib.util.spec_from_file_location('project_java_runtime',root/'scripts/project-java-runtime.py')
    runtime=importlib.util.module_from_spec(spec);spec.loader.exec_module(runtime)
    result=subprocess.run([str(root/'scripts/project-java.sh'),'--print-home'],
                          capture_output=True,text=True,check=True,timeout=30)
    home=Path(result.stdout.strip())
    if not home.is_absolute():raise ValueError('Java home is not absolute')
    release=(home/'release').read_text()
    values=dict(re.findall(r'^([A-Z_]+)="([^"\n]*)"$',release,re.M))
    if not values.get('JAVA_VERSION') or not values.get('IMPLEMENTOR'):
        raise ValueError('Selected JDK identity is incomplete')
    return {'component':'java','version':values['JAVA_VERSION'],
            'vendor':values['IMPLEMENTOR'],'runtimeVersion':values.get('JAVA_RUNTIME_VERSION',''),
            'origin':'emulator/java','use':'Firestore Rules verification',
            'trustRemediation':runtime.trust_evidence(root)}


def configuration(root):
    policy = document(root/POLICY, root)
    collectors = policy.get('collectors', [])
    if policy.get('schemaVersion') != 1 or not collectors:
        raise ValueError('Unknown coverage policy')
    ids = [x['id'] for x in collectors]
    scopes = [x for c in collectors for x in c['scopeIds']]
    if len(ids) != len(set(ids)) or sorted(scopes) != [f'C{i:02}' for i in range(1, 21)]:
        raise ValueError('Missing or duplicate coverage domains')
    return policy


def inventory(root=ROOT, purpose='audit'):
    root = root.resolve()
    policy = configuration(root)
    report = {'schemaVersion': 1, 'purpose': purpose, 'environment': 'ci' if os.environ.get('GITHUB_ACTIONS') == 'true' else 'local',
              'policyStatus': policy['status'], 'components': [], 'coverage': [], 'errors': [],
              'advisoryStatus': 'not-run', 'complete': False}
    collectors = {'python': collect_python, 'node': collect_node, 'npm-project': collect_project_npm,
                  'deployment': collect_deployment, 'app': collect_app,
                  'actions': collect_actions, 'platform': collect_platform, 'emulator': collect_emulator}
    for entry in policy['collectors']:
        row = {'id': entry['id'], 'scopeIds': entry['scopeIds'], 'owner': entry['owner']}
        if purpose not in entry['uses']:
            row.update(status='not-applicable', reason='Not used by the selected operation', uses=entry['uses'])
        elif entry['id'] not in collectors:
            row.update(status='unavailable', reason='Collector / supplier evidence is not yet implemented')
            report['errors'].append(entry['id']+': missing coverage')
        else:
            try:
                items, evidence = collectors[entry['id']](root)
                if len(items) > MAX_COMPONENTS:
                    raise ValueError('Too many components')
                report['components'].extend({**component,'collector':entry['id']} for component in items)
                row.update(status='inventoried', evidence=evidence, advisoryStatus='not-queried')
                if entry['id']=='emulator':row['tools']=[collect_java(root)]
                if any(e.get('coverageStatus') == 'supplier-managed-limited' for e in evidence):
                    row['status'] = 'supplier-managed-limited'
                    row['allDependenciesScanned'] = False
            except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile, tarfile.TarError, subprocess.SubprocessError) as error:
                # Never leak subprocess stdout or absolute machine paths.
                row.update(status='unavailable', reason=type(error).__name__)
                report['errors'].append(entry['id']+': inventory unavailable ('+type(error).__name__+')')
        report['coverage'].append(row)
    # Draft or unqueried inventories are not valid release/Issue closure evidence.
    report['inventoryComplete'] = not report['errors']
    report['allDependenciesScanned'] = False
    report['inventoryDigest'] = hashlib.sha256(json.dumps(
        {'components': report['components'], 'coverage': report['coverage']}, sort_keys=True).encode()).hexdigest()
    return report


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--purpose', choices=('audit','development','release','deployment','firebase','ci','sync-admin','icon-generation','termius-import'), default='audit')
    p.add_argument('--output', type=Path)
    p.add_argument('--probe-python', action='store_true', help=argparse.SUPPRESS)
    args = p.parse_args()
    if args.probe_python:
        print(json.dumps(python_probe()))
        return 0
    result = inventory(purpose=args.purpose)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps({'inventoryComplete': result['inventoryComplete'], 'components': len(result['components']),
                      'errors': result['errors'], 'advisoryStatus': result['advisoryStatus']}))
    return int(not result['inventoryComplete'])


if __name__ == '__main__':
    sys.exit(main())
