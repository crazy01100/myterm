#!/usr/bin/env python3
"""Download only pinned public inventory artifacts; never install or execute."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import urllib.request

ROOT=Path(__file__).resolve().parents[1]
LIMIT=160*1024*1024


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('Pinned inventory artifact must not redirect')


def declarations(root):
    artifacts=[]
    actions=json.loads((root/'Config/Security/action-bundles.json').read_text())
    if actions.get('schemaVersion')!=1:raise ValueError('Unknown action inventory policy')
    for row in actions['bundles']:
        repo,revision=row['repository'],row['revision']
        if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',repo) or not re.fullmatch('[a-f0-9]{40}',revision):
            raise ValueError('Invalid action source')
        url=f'https://codeload.github.com/{repo}/tar.gz/{revision}'
        relative=f'.build/security-inventory-actions/{repo.replace("/","-")}-{revision}.tgz'
        if row['url']!=url or row['cacheFile']!=relative:raise ValueError('Action source identity differs')
        artifacts.append({'url':url,'path':relative,'sha256':row['archiveSHA256'],'limit':64*1024*1024})
    policy=json.loads((root/'Config/Security/toolchain-inventory.json').read_text())
    for row in policy.get('supplierBoundaries',[]):
        if row.get('kind')=='action-bundle-limited-evidence':
            # Action archives are already enumerated above; verify their exact
            # accepted bundle identity before treating this as a duplicate.
            matches=[a for a in actions['bundles'] if a['repository']==row.get('component')
                     and a['revision']==row.get('revision')
                     and a['archiveSHA256']==row.get('archiveSHA256')]
            if row.get('state')!='accepted' or len(matches)!=1:
                raise ValueError('Action supplier boundary does not match pinned archive')
            continue
        if row.get('component')!='firestore-emulator' or row.get('state')!='accepted':
            raise ValueError('Unreviewed supplier download')
        version=row['version']
        if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){2}',version):raise ValueError('Invalid emulator version')
        filename=f'cloud-firestore-emulator-v{version}.jar'
        url=f'https://storage.googleapis.com/firebase-preview-drop/emulator/{filename}'
        if row['url']!=url or row['filename']!=filename or not 0<row['size']<=LIMIT:
            raise ValueError('Supplier download identity differs')
        artifacts.append({'url':url,'path':'.build/security-inventory-artifacts/'+filename,
                          'sha256':row['sha256'],'size':row['size'],'limit':LIMIT})
    return artifacts


def verify(path, row):
    if not re.fullmatch('[a-f0-9]{64}',row['sha256']) or path.is_symlink() or path.stat().st_size>row['limit']:
        raise ValueError('Invalid inventory artifact')
    if row.get('size') is not None and path.stat().st_size!=row['size']:
        raise ValueError('Inventory artifact size mismatch')
    h=hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):h.update(chunk)
    if h.hexdigest()!=row['sha256']:raise ValueError('Inventory artifact hash mismatch')


def prepare(root, context):
    opener=urllib.request.build_opener(NoRedirect(),urllib.request.HTTPSHandler(context=context))
    result=[]
    for row in declarations(root):
        path=root/row['path']
        if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()/'.build'):
            raise ValueError('Inventory artifact escapes project storage')
        path.parent.mkdir(parents=True,exist_ok=True)
        if not path.exists():
            with tempfile.TemporaryDirectory(prefix='download-',dir=path.parent) as directory:
                stage=Path(directory)/path.name
                request=urllib.request.Request(row['url'],headers={'User-Agent':'MyTerm-security-inventory'})
                with opener.open(request,timeout=45) as response,stage.open('wb') as output:
                    total=0
                    while chunk:=response.read(1024*1024):
                        total+=len(chunk)
                        if total>row['limit']:raise ValueError('Inventory download exceeds limit')
                        output.write(chunk)
                verify(stage,row);stage.replace(path)
        verify(path,row)
        result.append({'path':row['path'],'sha256':row['sha256']})
    return result


if __name__=='__main__':
    spec=importlib.util.spec_from_file_location('python_toolchain',ROOT/'scripts/python-toolchain.py')
    trust=importlib.util.module_from_spec(spec);spec.loader.exec_module(trust)
    print(json.dumps({'verifiedArtifacts':prepare(ROOT,trust.https_context(ROOT)),'executed':False}))
