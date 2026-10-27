#!/usr/bin/env python3
"""Prepare/verify the reviewed project JDK without changing global Java or CAs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT=Path(__file__).resolve().parents[1]
CONFIG='Config/Security/java-runtime.json'
TARGET='.build/java-runtime'
MANIFEST='.build/java-runtime-files.json'
TRUST='Config/Security/java-trust.json'
EXCLUDED_ROOTS={'emSign Root CA - G1','emSign Root CA - G2',
                'emSign ECC Root CA - G3','AAA Certificate Services'}


def config_path():
    identity=(platform.system(),platform.machine())
    if identity==('Darwin','arm64'):return CONFIG
    if identity==('Linux','x86_64'):return 'Config/Security/java-runtime-linux.json'
    raise ValueError('No reviewed Java artifact for this platform')


def java_home(target,row):
    return target/'Contents/Home' if row['platform']=='aarch64-apple-darwin' else target


def configuration(root):
    config=config_path()
    row=json.loads((root/config).read_text())
    expected_platform='aarch64-apple-darwin' if config==CONFIG else 'x86_64-linux-gnu'
    version=row.get('version','')
    if (row.get('schemaVersion')!=1 or row.get('vendor')!='Eclipse Temurin' or
            row.get('platform')!=expected_platform or not re.fullmatch(r'21\.0\.[0-9]+\+[0-9]+',version) or
            row.get('archiveRoot')!='jdk-'+version or type(row.get('size')) is not int or not 0<row['size']<256*1024*1024):
        raise ValueError('Unreviewed Java runtime policy')
    for key in ('sha256','fileManifestSHA256','truststoreSHA256','blockedCertsSHA256'):
        if not re.fullmatch('[a-f0-9]{64}',row.get(key,'')):raise ValueError('Invalid Java source fingerprint')
    release,build=version.split('+')
    artifact='aarch64_mac' if expected_platform=='aarch64-apple-darwin' else 'x64_linux'
    expected=f'https://github.com/adoptium/temurin21-binaries/releases/download/jdk-{release}%2B{build}/OpenJDK21U-jdk_{artifact}_hotspot_{release}_{build}.tar.gz'
    if row.get('url')!=expected:raise ValueError('Java archive source changed')
    return row


def digest_file(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def storage(root,relative):
    path=root/relative
    if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()/'.build'):
        raise ValueError('Java runtime storage escaped project')
    return path


def archive_manifest(archive,row):
    if archive.stat().st_size!=row['size'] or digest_file(archive)!=row['sha256']:
        raise ValueError('Java archive size/hash mismatch')
    files={};seen=set();total=0
    with tarfile.open(archive,'r:gz') as source:
        for index,item in enumerate(source):
            path=Path(item.name);parts=path.parts
            total+=item.size
            if (index>=20000 or total>1024*1024*1024 or path.is_absolute() or '..' in parts or
                    not parts or parts[0]!=row['archiveRoot'] or item.name in seen):
                raise ValueError('Java archive exceeds reviewed layout')
            seen.add(item.name)
            if item.issym():
                name='/'.join(parts[1:])
                if (row.get('platform')!='x86_64-linux-gnu' or len(parts)!=4 or parts[1]!='legal'
                        or parts[-1] not in ('LICENSE','ASSEMBLY_EXCEPTION','ADDITIONAL_LICENSE_INFO','cldr.md')
                        or item.linkname!='../java.base/'+parts[-1]):
                    raise ValueError('Unreviewed Java archive link')
                files[name]={'symlink':item.linkname}
            elif not (item.isfile() or item.isdir()):raise ValueError('Unreviewed Java archive member')
            if item.isfile():
                name='/'.join(parts[1:])
                if not name:raise ValueError('Invalid Java archive file')
                with source.extractfile(item) as stream:
                    files[name]={'sha256':hashlib.file_digest(stream,'sha256').hexdigest(),'executable':bool(item.mode&0o111)}
    for name,entry in files.items():
        if 'symlink' in entry and 'sha256' not in files.get('legal/java.base/'+Path(name).name,{}):
            raise ValueError('Java license link target missing or indirect')
    raw=json.dumps(files,sort_keys=True,separators=(',',':')).encode()
    if hashlib.sha256(raw).hexdigest()!=row['fileManifestSHA256']:
        raise ValueError('Java archive file manifest changed')
    return files,raw


def verify_tree(target,files):
    seen=set()
    for path in target.rglob('*'):
        if path.is_symlink():
            name=str(path.relative_to(target));seen.add(name)
            if (files.get(name)!={'symlink':os.readlink(path)} or
                    not path.resolve().is_relative_to(target.resolve()) or not path.is_file()):
                raise ValueError('Java runtime contains an unexpected link')
            continue
        if path.is_dir():continue
        name=str(path.relative_to(target));seen.add(name)
        expected=files.get(name)
        if (expected is None or 'sha256' not in expected or not path.is_file() or digest_file(path)!=expected['sha256'] or
                bool(path.stat().st_mode&0o111)!=expected['executable']):
            raise ValueError('Java runtime file content or mode changed')
    if seen!=set(files):raise ValueError('Java runtime file inventory changed')


def trust_configuration(root, row):
    policy=json.loads((root/TRUST).read_text())
    if (policy.get('schemaVersion')!=1 or policy.get('id')!='CVE-2026-114820' or
            policy.get('decision')!='vendor-recommended-root-removal' or
            policy.get('grantsRiskException') is not False or
            policy.get('source')!='https://ops.java/emudhra' or
            len(policy.get('excludedRootCNs',[]))!=4 or set(policy['excludedRootCNs'])!=EXCLUDED_ROOTS or
            policy.get('upstreamTruststoreSHA256')!=row['truststoreSHA256'] or
            not re.fullmatch('[a-f0-9]{64}',policy.get('derivedTruststoreSHA256','')) or
            policy['derivedTruststoreSHA256']==policy['upstreamTruststoreSHA256'] or
            policy.get('removedCertificateSHA256')!=[
                '40f6af0346a99aa1cd1d555a4e9cce62c7f9634603ee406615833dc8c8d00367']):
        raise ValueError('Unreviewed Java trust derivation')
    return policy


def installed_manifest(root, row, files):
    policy=trust_configuration(root,row)
    name=str(java_home(Path('.'),row)/'lib/security/cacerts')
    if files.get(name)!={'sha256':policy['upstreamTruststoreSHA256'],'executable':False}:
        raise ValueError('Upstream truststore manifest differs')
    return {**files,name:{'sha256':policy['derivedTruststoreSHA256'],'executable':False}}


def certificate_inventory(text):
    """Read English keytool metadata from a hash-verified official keystore."""
    entries=[]
    for block in text.split('Alias name: ')[1:]:
        alias=block.splitlines()[0].strip()
        owner=re.search(r'^Owner: (.+)$',block,re.M)
        fingerprint=re.search(r'^\s*SHA256: ([0-9A-F:]+)$',block,re.M)
        if not owner or not fingerprint or 'Entry type: trustedCertEntry' not in block:
            raise ValueError('Incomplete Java certificate inventory')
        cn=re.search(r'(?:^|, )CN=([^,]+)(?:,|$)',owner[1])
        sha=fingerprint[1].replace(':','').lower()
        if not re.fullmatch('[a-f0-9]{64}',sha):
            raise ValueError('Invalid Java root certificate identity')
        entries.append({'alias':alias,'cn':cn[1] if cn else None,'sha256':sha})
    if not entries or len({r['alias'] for r in entries})!=len(entries):
        raise ValueError('Empty or duplicate Java certificate inventory')
    return entries


def derive_trust(home, root, row):
    policy=trust_configuration(root,row);target=home/'lib/security/cacerts'
    if target.is_symlink() or digest_file(target)!=policy['upstreamTruststoreSHA256']:
        raise ValueError('Only the exact official truststore can be derived')
    keytool=[str(home/'bin/keytool'),'-J-Duser.language=en','-J-Duser.country=US']
    def run(*args):
        return subprocess.run(keytool+list(args),env=clean_environment(),capture_output=True,
                              text=True,timeout=30,check=True).stdout
    with tempfile.TemporaryDirectory(dir=target.parent,prefix='.myterm-trust-') as directory:
        staged=Path(directory)/'cacerts';shutil.copyfile(target,staged)
        arguments=['-keystore',str(staged),'-storepass','changeit']  # Public JDK store-integrity password.
        before=certificate_inventory(run('-list','-v',*arguments))
        removed=[r for r in before if r['cn'] in EXCLUDED_ROOTS]
        if sorted(r['sha256'] for r in removed)!=policy['removedCertificateSHA256']:
            raise ValueError('Official roots differ from reviewed removal')
        for entry in removed:run('-delete',*arguments,'-alias',entry['alias'])
        after=certificate_inventory(run('-list','-v',*arguments))
        if (any(r['cn'] in EXCLUDED_ROOTS for r in after) or
                sorted(after,key=lambda r:r['alias'])!=sorted(
                    [r for r in before if r not in removed],key=lambda r:r['alias']) or
                digest_file(staged)!=policy['derivedTruststoreSHA256']):
            raise ValueError('Derived Java truststore differs from reviewed result')
        staged.chmod(0o644)
        staged.replace(target)


def upstream_manifest(root, row):
    manifest=storage(root,MANIFEST)
    raw=manifest.read_bytes()
    if hashlib.sha256(raw).hexdigest()!=row['fileManifestSHA256']:
        raise ValueError('Java installed manifest differs from reviewed artifact')
    return json.loads(raw)


def verify(root=ROOT):
    row=configuration(root);target=storage(root,TARGET)
    files=upstream_manifest(root,row);verify_tree(target,installed_manifest(root,row,files))
    home=java_home(target,row)
    if digest_file(home/'lib/security/blocked.certs')!=row['blockedCertsSHA256']:
        raise ValueError('Java blocked certificates changed')
    if (home/'lib/security/jssecacerts').exists():
        raise ValueError('Unexpected Java default truststore override')
    return home


def trust_evidence(root=ROOT):
    home=verify(root);row=configuration(root);policy=trust_configuration(root,row)
    return {'id':policy['id'],'decision':policy['decision'],'source':policy['source'],
            'version':row['version'],'platform':row['platform'],'archiveSHA256':row['sha256'],
            'policySHA256':digest_file(root/TRUST),
            'upstreamTruststoreSHA256':policy['upstreamTruststoreSHA256'],
            'derivedTruststoreSHA256':digest_file(home/'lib/security/cacerts'),
            'excludedRootCNs':policy['excludedRootCNs'],'grantsRiskException':False}


def clean_environment():
    return {k:v for k,v in os.environ.items() if k not in ('JAVA_TOOL_OPTIONS','JDK_JAVA_OPTIONS','_JAVA_OPTIONS')}


def setup(root=ROOT):
    row=configuration(root);archive=storage(root,'.build/java-base-download/'+row['url'].rsplit('/',1)[-1]);target=storage(root,TARGET)
    if target.exists():
        try:return verify(root)
        except ValueError:
            # The one explicit migration accepts a completely unchanged official
            # tree. Unknown drift is never repaired or overwritten by setup.
            verify_tree(target,upstream_manifest(root,row))
            derive_trust(java_home(target,row),root,row)
            return verify(root)
    archive.parent.mkdir(parents=True,exist_ok=True)
    if not archive.exists():
        with tempfile.TemporaryDirectory(dir=archive.parent,prefix='download-') as directory:
            temporary=Path(directory)/'java.tar.gz'
            subprocess.run(['/usr/bin/curl','--disable','--fail','--silent','--show-error','--location',
                            '--proto','=https','--proto-redir','=https','--max-time','180','--max-filesize',str(row['size']),
                            '--output',str(temporary),row['url']],check=True,timeout=185)
            archive_manifest(temporary,row);temporary.replace(archive)
    files,raw=archive_manifest(archive,row)
    with tempfile.TemporaryDirectory(dir=archive.parent,prefix='unpack-') as directory:
        stage=Path(directory)
        with tarfile.open(archive,'r:gz') as source:source.extractall(stage,filter='data')
        candidate=stage/row['archiveRoot'];verify_tree(candidate,files)
        result=subprocess.run([str(java_home(candidate,row)/'bin/java'),'-version'],
                              env=clean_environment(),capture_output=True,text=True,timeout=20,check=True)
        if 'Temurin-'+row['version'] not in result.stderr:
            raise ValueError('Java vendor/build differs from reviewed runtime')
        derive_trust(java_home(candidate,row),root,row)
        candidate.rename(target)
    storage(root,MANIFEST).write_bytes(raw)
    return verify(root)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation',choices=('setup','verify'))
    args=parser.parse_args()
    print(setup() if args.operation=='setup' else verify())
