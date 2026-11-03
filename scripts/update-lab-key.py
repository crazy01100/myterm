#!/usr/bin/env python3
"""Ephemeral Sparkle keys and isolated UpdateLab identity verification."""
import argparse
import base64
import os
from pathlib import Path
import plistlib


def prepare(directory):
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives.serialization import Encoding, NoEncryption, PrivateFormat, PublicFormat

    key = Ed25519PrivateKey.generate()
    private = directory / 'test-private-key.txt'
    public = directory / 'test-public-key.txt'
    # Exclusive creation keeps an existing lab's signed feed paired with its key.
    with os.fdopen(os.open(private, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as output:
        output.write(base64.b64encode(key.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())))
    with public.open('xb') as output:
        output.write(base64.b64encode(key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)))


def verify(app, public_file):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    required = {
        'CFBundleIdentifier': 'tw.local.MySSHClient.UpdateLab',
        'MyTermApplicationSupportDirectory': 'MyTerm Update Lab',
        'MyTermLocalSecretVaultKeychainService': 'tw.local.MySSHClient.UpdateLab.local-secret-vault-root',
        'MyTermUpdateLabMode': True,
    }
    for name, value in required.items():
        if type(info.get(name)) is not type(value) or info[name] != value:
            raise ValueError('Test key requires isolated UpdateLab identity: ' + name)
    for name in ('MyTermCloudConfig.plist', 'GoogleService-Info.plist'):
        if (app / 'Contents/Resources' / name).exists():
            raise ValueError('UpdateLab must not include cloud configuration')
    expected = public_file.read_text().strip()
    if len(base64.b64decode(expected, validate=True)) != 32 or info.get('SUPublicEDKey') != expected:
        raise ValueError('UpdateLab public key differs from the prepared test key')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'verify'))
    parser.add_argument('--app', type=Path)
    args = parser.parse_args()
    directory = Path(__file__).resolve().parents[1] / 'build/update-lab'
    if directory.resolve() != directory or not directory.is_dir():
        parser.error('Expected a real project build/update-lab directory')
    if args.action == 'prepare':
        if args.app:
            parser.error('prepare does not take an App')
        prepare(directory)
    else:
        if not args.app:
            parser.error('verify requires --app')
        verify(args.app, directory / 'test-public-key.txt')


if __name__ == '__main__':
    main()
