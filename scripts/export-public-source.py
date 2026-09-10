#!/usr/bin/env python3
"""Export an explicit, reviewed source set; never copy Git history or publish it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PRIVATE_MARKERS = (b"lieniapp.work", b"myterm-updates", b"/users/lieni/",
                   b"myterm.release.ed25519")
SECRET = re.compile(rb"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----|"
                    rb"AIza[0-9A-Za-z_-]{35}|GOCSPX-[0-9A-Za-z_-]{20,}|"
                    rb"gh[pousr]_[0-9A-Za-z]{36,}|github_pat_[0-9A-Za-z_]{50,}")
FORBIDDEN_PARTS = {".git", "Config/Local", "Config/Release", "build", "docs",
                   ".build", ".build-app", "Exports", ".github/workflows"}


def safe_relative(name):
    p = Path(name)
    if not name or p.is_absolute() or ".." in p.parts or str(p) != name:
        raise ValueError("Invalid source path")
    return p


def public_path(name):
    p = safe_relative(name)
    for prefix in FORBIDDEN_PARTS:
        if name == prefix or name.startswith(prefix + "/"):
            raise ValueError("Private path in export manifest: " + name)
    if p.name in {"AGENTS.md", ".DS_Store"} or p.name.startswith('.env') or p.suffix.lower() in {
        '.zip', '.dmg', '.p12', '.p8', '.key', '.pem', '.cer', '.mobileprovision'
    }:
        raise ValueError("Non-source artifact in export manifest: " + name)
    if name == "update-site/appcast.xml":
        raise ValueError("Signed update feed must remain private")
    return p


def checked_file(root, relative):
    path = root / safe_relative(relative)
    current = root
    for part in Path(relative).parts:
        current = current / part
        if current.is_symlink():
            raise ValueError("Symlink source rejected: " + relative)
    if not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError("Missing or escaped source: " + relative)
    return path


def scan_file(name, data):
    if any(marker in data.lower() for marker in PRIVATE_MARKERS):
        raise ValueError("Private service/identity marker in: " + name)
    if SECRET.search(data):
        raise ValueError("Credential-like material in: " + name)


def export(root, manifest_path, output):
    root, output = root.resolve(), output.resolve()
    if output.exists() or output.is_symlink():
        raise ValueError("Output already exists; use a new candidate directory")
    if output == root or root.is_relative_to(output):
        raise ValueError("Output cannot contain the source checkout")
    manifest = json.loads(manifest_path.read_text())
    if manifest.get('schemaVersion') != 1:
        raise ValueError("Unsupported export manifest")
    prepared, seen = [], set()
    for entry in manifest['files']:
        name = entry['path']
        public_path(name)
        if name in seen:
            raise ValueError("Duplicate export path: " + name)
        seen.add(name)
        if 'overlay' in entry:
            # Fail closed if the private counterpart changed since review.
            if 'baseSHA256' in entry:
                original = checked_file(root, name)
                if hashlib.sha256(original.read_bytes()).hexdigest() != entry['baseSHA256']:
                    raise ValueError("Public override requires re-review: " + name)
            source = checked_file(root, entry['overlay'])
        else:
            source = checked_file(root, name)
        data = source.read_bytes()
        scan_file(name, data)
        prepared.append((name, data, 0o755 if entry.get('executable') else 0o644))
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.public-source-', dir=output.parent))
    try:
        for name, data, mode in prepared:
            target = stage / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            target.chmod(mode)
        # The directory contains source only: no private commit identifiers or report.
        stage.rename(output)
    except BaseException:
        shutil.rmtree(stage)
        raise
    return len(prepared)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    output = Path(args.output).resolve()
    allowed = ROOT / 'build/public-source'
    if not (output.is_relative_to(allowed) or output.is_relative_to(Path('/private/tmp'))):
        parser.error('Output must be under build/public-source or /private/tmp')
    try:
        count = export(ROOT, ROOT / 'PublicSource/export-manifest.json', output)
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, str(error) + '\n')
    print(f'Exported {count} reviewed source files to {output}. No Git history or upload.')


if __name__ == '__main__':
    main()
