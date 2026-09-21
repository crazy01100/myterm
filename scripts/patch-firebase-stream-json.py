#!/usr/bin/env python3
"""Adapt pinned Firebase CLI stream APIs to the official patched stream-json.

Run by npm postinstall. --check verifies the installed patch without changing it.
Remove this adapter when upstream Firebase supports a patched stream-json itself.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
PATCHES = {
    "lib/commands/auth-import.js": {
        "before": "a74d755e32e911d39810dc8e8290f6e9b0f83f057d5d8b06b11078c7e1b24b9e",
        "after": "a61674e6f11dc84b2ab0ef52da79eefb10bc37f7bbe84eadb5d750ce6992c976",
        "replacements": {
            "require(\"stream-json/filters/Pick\")": "require(\"stream-json/filters/pick.js\").pick",
            "require(\"stream-json/streamers/StreamArray\")": "{ streamArray: require(\"stream-json/streamers/stream-array.js\").streamArray.asStream }",
            "Pick.withParser(": "Pick.withParserAsStream("
        }
    },
    "lib/database/import.js": {
        "before": "cbf075c20415428f285095e2eec7c35182b1d4f3568b965bcf7727d8bdcf9cee",
        "after": "dc0fff674fb70ead885ad6975b0c11e91184a0a4d9f240353a86e2ac5cfe93ee",
        "replacements": {
            "require(\"stream-json/filters/Filter\")": "require(\"stream-json/filters/filter.js\").filter",
            "require(\"stream-json/streamers/StreamObject\")": "{ streamObject: require(\"stream-json/streamers/stream-object.js\").streamObject.asStream }",
            "Filter.withParser(": "Filter.withParserAsStream("
        }
    },
    "lib/frameworks/next/index.js": {
        "before": "e02e16d5009cbf16cf177b23b3c509353b2666075245845867e049c8a14a37b3",
        "after": "fd9c15e8a6048d0e0547b5e9833fa86aa17bd4adf083c28a485ffcc0bf092240",
        "replacements": {
            "require(\"stream-json\")": "{ parser: require(\"stream-json\").parserStream }",
            "require(\"stream-json/filters/Pick\")": "{ pick: require(\"stream-json/filters/pick.js\").pick.asStream }",
            "require(\"stream-json/streamers/StreamObject\")": "{ streamObject: require(\"stream-json/streamers/stream-object.js\").streamObject.asStream }"
        }
    }
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def apply(root=ROOT, check=False, patches=PATCHES):
    for package, version in [('firebase-tools', '15.30.2'), ('stream-json', '3.6.0')]:
        path = root / 'node_modules' / package / 'package.json'
        if json.loads(path.read_text())['version'] != version:
            raise ValueError(f'{package}: version drift; review upstream before updating the adapter')
    pending = []
    # Validate all inputs before writing any file. An interrupted installation can
    # be rerun: already-patched files must match the exact reviewed output hash.
    for name, patch in patches.items():
        path = root / 'node_modules/firebase-tools' / name
        original = path.read_bytes()
        actual = digest(original)
        if actual == patch['after']:
            continue
        if check or actual != patch['before']:
            raise ValueError(f'{name}: missing patch or unexpected upstream content; reinstall/review required')
        result = original.decode('utf-8')
        for old, new in patch['replacements'].items():
            if result.count(old) != 1:
                raise ValueError(f'{name}: ambiguous API mapping')
            result = result.replace(old, new)
        encoded = result.encode('utf-8')
        if digest(encoded) != patch['after']:
            raise ValueError(f'{name}: unexpected patch output')
        pending.append((path, encoded))
    for path, encoded in pending:
        path.write_bytes(encoded)
    return len(pending)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        count = apply(check=args.check)
    except (OSError, ValueError, KeyError) as error:
        print(f'Firebase compatibility verification failed: {error}', file=sys.stderr)
        return 1
    print(f'Firebase stream-json compatibility verified ({count} files updated).')
    return 0


if __name__ == '__main__':
    sys.exit(main())
