#!/usr/bin/env python3
"""Verify release bytes with a trusted public key before parsing or extracting them.

Sparkle feed and release-notes byte boundaries follow SPUExtractSignedFeed.m.
Ed25519 is provided by cryptography; this tool never reads a private key.
"""
import argparse
import base64
import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import urlsplit
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.exceptions import InvalidSignature

SP = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
MT = '{urn:myterm:release:v1}'
PREFIX = b'<!-- sparkle-signatures:\n'
MAX_FILE = 25 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def decode64(value, size):
    data = base64.b64decode(value, validate=True)
    require(len(data) == size, 'Invalid public key or signature length')
    return data


def one(parent, name):
    found = parent.findall(name)
    require(len(found) == 1, 'Expected exactly one ' + name)
    return found[0]


def signed_feed(data, key):
    require(data.count(PREFIX) == 1, 'Missing or ambiguous feed signature block')
    content, block = data.split(PREFIX)
    match = re.fullmatch(rb'edSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\s*', block)
    require(match is not None, 'Invalid signature block or trailing content')
    require(int(match[2]) == len(content), 'Signed feed length mismatch')
    key.verify(decode64(match[1], 64), content)
    require(b'<!DOCTYPE' not in content.upper() and b'<!ENTITY' not in content.upper(), 'DTD/entity forbidden')
    return ET.fromstring(content)


def notes_content(data):
    prefix = b'<!-- sparkle-sign-warning:'
    if not data.startswith(prefix):
        return data
    end = data.find(b'-->', len(prefix))
    require(end >= 0, 'Invalid release notes signing warning')
    offset = end + 3
    if data[offset:offset+1] == b'\n':
        offset += 1
    return data[offset:]


def read_assets(directory):
    result = {}
    require(directory.is_dir() and not directory.is_symlink(), 'Invalid asset directory')
    for path in directory.iterdir():
        require(path.is_file() and not path.is_symlink(), 'Unexpected asset entry')
        with path.open('rb') as stream:
            content = stream.read(MAX_FILE + 1)
        require(len(content) <= MAX_FILE, 'Asset exceeds 25 MiB limit')
        result[path.name] = content
    return result


def verify(directory, public_key, version, base_url, build=None, expected_commit=None):
    require(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:[.-][0-9A-Za-z]+)*', version), 'Invalid version')
    parsed = urlsplit(base_url)
    require(parsed.scheme == 'https' and parsed.netloc and not parsed.username and not parsed.password
            and not parsed.query and not parsed.fragment, 'A trusted HTTPS base URL is required')
    base_url = base_url.rstrip('/')
    key = Ed25519PublicKey.from_public_bytes(decode64(public_key.strip(), 32))
    files = read_assets(directory)
    require('appcast.xml' in files, 'Missing appcast')
    root = signed_feed(files['appcast.xml'], key)
    require(root.tag == 'rss', 'Expected RSS feed')
    item = one(one(root, 'channel'), 'item')
    require(len(root.findall('.//item')) == 1, 'Ambiguous feed items')
    feed_version = one(item, SP+'shortVersionString').text
    feed_build = one(item, SP+'version').text
    require(feed_version == version, 'Version mismatch')
    require(feed_build and re.fullmatch(r'[1-9][0-9]*', feed_build), 'Invalid Build')
    require(build is None or build == feed_build, 'Build mismatch')
    require(one(item, SP+'minimumSystemVersion').text == '26.0', 'Unexpected minimum OS')
    require(one(item, SP+'hardwareRequirements').text == 'arm64', 'Unexpected architecture')
    archive = f'MyTerm-{version}-build-{feed_build}-arm64.zip'
    names = {archive, 'appcast.xml', 'release-notes.html', 'release-manifest.json', 'CHECKSUMS.txt'}
    require(set(files) == names, 'Release must contain exactly the five expected assets')
    enclosure = one(item, 'enclosure')
    require(len(root.findall('.//enclosure')) == 1, 'Ambiguous enclosure')
    require(enclosure.get('url') == base_url+'/downloads/'+archive, 'Download URL mismatch')
    require(enclosure.get('length') == str(len(files[archive])), 'Archive length mismatch')
    key.verify(decode64(enclosure.get(SP+'edSignature', ''), 64), files[archive])
    notes = one(item, SP+'releaseNotesLink')
    require(notes.text == base_url+f'/releases/{version}.html', 'Notes URL mismatch')
    content = notes_content(files['release-notes.html'])
    require(notes.get('length') == str(len(content)), 'Notes length mismatch')
    key.verify(decode64(notes.get(SP+'edSignature', ''), 64), content)
    commit = one(item, MT+'sourceCommit').text
    require(commit and re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', commit), 'Invalid signed source commit')
    require(expected_commit is None or commit == expected_commit, 'Source commit mismatch')
    dependencies = json.loads(one(item, MT+'dependencies').text)
    require(isinstance(dependencies, list) and dependencies, 'Missing signed dependency inventory')
    manifest = json.loads(files['release-manifest.json'])
    checks = {'schemaVersion': 1, 'product': 'MyTerm', 'version': version, 'build': feed_build,
              'tag': 'v'+version, 'archive': archive, 'downloadURL': enclosure.get('url'),
              'commit': commit, 'dependencies': dependencies}
    for name, value in checks.items():
        require(manifest.get(name) == value, 'Manifest mismatch: '+name)
    for name, field in [(archive, 'archiveSHA256'), ('appcast.xml', 'appcastSHA256'),
                        ('release-notes.html', 'releaseNotesSHA256')]:
        require(manifest.get(field) == hashlib.sha256(files[name]).hexdigest(), 'Manifest hash mismatch')
    expected = {hashlib.sha256(data).hexdigest()+'  '+name for name,data in files.items() if name!='CHECKSUMS.txt'}
    actual = files['CHECKSUMS.txt'].decode('ascii').splitlines()
    require(len(actual)==len(expected) and set(actual)==expected, 'Invalid checksums or unsafe checksum paths')
    return {'version': version, 'build': feed_build, 'commit': commit, 'archive': archive,
            'dependencies': dependencies, 'hashes': {n:hashlib.sha256(b).hexdigest() for n,b in files.items()}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--assets', required=True, type=Path)
    parser.add_argument('--public-key-file', required=True, type=Path)
    parser.add_argument('--base-url', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build')
    parser.add_argument('--commit')
    args = parser.parse_args()
    try:
        result = verify(args.assets, args.public_key_file.read_text(), args.version,
                        args.base_url, args.build, args.commit)
        print(json.dumps(result, sort_keys=True))
    except (ValueError, KeyError, OSError, ET.ParseError, InvalidSignature, TypeError) as error:
        print('Release verification rejected: '+(str(error) or type(error).__name__), file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    sys.exit(main())
