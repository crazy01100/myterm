#!/usr/bin/env python3
"""Install a pinned standalone Python base inside the project; never touch shared runtimes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tarfile
import tempfile

ROOT=Path(__file__).resolve().parents[1]
CONFIG='Config/Security/python-runtime.json'


def configuration(root):
    row=json.loads((root/CONFIG).read_text())
    if (row.get('schemaVersion')!=1 or row.get('vendor')!='Astral python-build-standalone'
            or not re.fullmatch(r'3\.12\.[0-9]+',row['pythonVersion'])
            or not re.fullmatch('[0-9]{8}',row['release']) or row.get('platform')!='aarch64-apple-darwin'
            or not re.fullmatch('[a-f0-9]{64}',row['sha256']) or not 0<row['size']<64*1024*1024):
        raise ValueError('Unreviewed Python base policy')
    filename=f"cpython-{row['pythonVersion']}%2B{row['release']}-{row['platform']}-install_only_stripped.tar.gz"
    if row['url']!=f"https://github.com/astral-sh/python-build-standalone/releases/download/{row['release']}/{filename}":
        raise ValueError('Python archive source differs from approved release')
    return row


def probe(python, row):
    # Only ordinary version reads after archive integrity verification.
    result=subprocess.run([str(python),'-I','-S','-c',
        'import json,sys,ssl; print(json.dumps({"python":sys.version.split()[0],"openssl":ssl.OPENSSL_VERSION,"base":sys.base_prefix}))'],
        capture_output=True,text=True,check=True,timeout=20)
    info=json.loads(result.stdout)
    match=re.fullmatch(r'OpenSSL ([0-9]+\.[0-9]+)\.([0-9]+)(?: .*)?',info['openssl'])
    if (info['python']!=row['pythonVersion'] or not match or
            match[1] not in row['opensslMinimums'] or int(match[2])<row['opensslMinimums'][match[1]]):
        raise ValueError('Standalone Python/OpenSSL does not meet the approved patch floor')
    return info


def setup(root=ROOT):
    if platform.system()!='Darwin' or platform.machine()!='arm64':
        raise ValueError('This reviewed base artifact is for Apple Silicon macOS only')
    row=configuration(root)
    cache=root/'.build/python-base-download';target=root/'.build/python-base'
    for path in (cache,target):
        if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()/'.build'):
            raise ValueError('Python base must remain inside project storage')
    cache.mkdir(parents=True,exist_ok=True)
    archive=cache/'python-base.tar.gz'
    if archive.is_symlink():raise ValueError('Unexpected Python archive link')
    if not archive.exists():
        with tempfile.TemporaryDirectory(dir=cache,prefix='download-') as directory:
            stage=Path(directory)/archive.name
            subprocess.run(['/usr/bin/curl','--disable','--fail','--silent','--show-error','--location',
                            '--proto','=https','--proto-redir','=https','--max-time','120',
                            '--max-filesize',str(row['size']),'--output',str(stage),row['url']],check=True,timeout=125)
            verify_archive(stage,row);stage.replace(archive)
    verify_archive(archive,row)
    if target.exists():
        raise ValueError('Existing standalone base preserved; explicit replacement requires a new reviewed operation')
    with tempfile.TemporaryDirectory(dir=cache,prefix='unpack-') as directory:
        stage=Path(directory)
        with tarfile.open(archive,'r:gz') as source:
            total=0
            for index,entry in enumerate(source):
                parts=Path(entry.name).parts
                total+=entry.size
                if index>20000 or total>512*1024*1024 or not parts or parts[0]!='python' or '..' in parts or Path(entry.name).is_absolute():
                    raise ValueError('Python archive layout exceeds reviewed bounds')
                source.extract(entry,stage,filter='data')
        info=probe(stage/'python/bin/python3.12',row)
        (stage/'python').rename(target)
    info=probe(target/'bin/python3.12',row)
    return {'python':info['python'],'openssl':info['openssl'],'archiveSHA256':row['sha256'],
            'vendor':row['vendor'],'path':'.build/python-base','sharedRuntimeChanged':False}


def verify_archive(path,row):
    if path.stat().st_size!=row['size'] or hashlib.sha256(path.read_bytes()).hexdigest()!=row['sha256']:
        raise ValueError('Standalone Python archive size/hash mismatch')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path)
    args=parser.parse_args();result=setup()
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))
