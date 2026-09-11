#!/usr/bin/env python3
"""Read the source dependency inventory without reading local cloud/signing data."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def inventory(root=ROOT, require_binary=True):
    lock = json.loads((root/'Package.resolved').read_text())
    result = [{'ecosystem': 'swift', 'name': p['location'].removesuffix('.git'),
               'version': p['state']['version'], 'revision': p['state']['revision']}
              for p in lock['pins']]
    vendor = (root/'Vendor/SwiftTerm/UPSTREAM.md').read_text()
    revision = re.search(r'Revision: `([a-f0-9]{40})`', vendor).group(1)
    result.append({'ecosystem': 'swift', 'name': 'https://github.com/migueldeicaza/SwiftTerm',
                   'revision': revision, 'vendored': True})
    header = root/'.build/checkouts/swift-sodium/Clibsodium.xcframework/macos-arm64_arm64e_x86_64/Headers/Clibsodium/sodium/version.h'
    recorded = json.loads((root/"Config/Security/native-components.json").read_text())["libsodium"]
    wrapper = next(p for p in lock["pins"] if p["identity"] == "swift-sodium")
    if recorded["swiftSodiumRevision"] != wrapper["state"]["revision"]:
        raise ValueError("Review the bundled native inventory after upgrading swift-sodium")
    if header.exists():
        version = re.search(r'SODIUM_VERSION_STRING "([^"]+)"', header.read_text()).group(1)
        if version != recorded["version"]:
            raise ValueError("Bundled libsodium differs from the reviewed native inventory")
    elif require_binary:
        raise ValueError("Resolve Swift dependencies before recording the bundled libsodium version")
    else:
        version = recorded["version"]
    result.append({'ecosystem': 'native', 'name': 'https://github.com/jedisct1/libsodium', 'version': version})
    return sorted(result, key=lambda x: x['name'])

if __name__ == '__main__':
    print(json.dumps(inventory(), sort_keys=True))
