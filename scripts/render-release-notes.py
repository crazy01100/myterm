#!/usr/bin/env python3
"""Render concise, escaped release notes shared by Sparkle and the release page."""
import argparse
import html
from pathlib import Path
import re

VERSION = r'[0-9]+\.[0-9]+\.[0-9]+(?:[.-][0-9A-Za-z]+)*'


def render(source, version):
    if not re.fullmatch(VERSION, version):
        raise ValueError('Invalid release version')
    lines = source.lstrip('\ufeff').splitlines()
    while lines and not lines[0].strip():
        lines.pop(0)
    if not lines:
        raise ValueError('Release notes must contain user-facing content')
    # Only normalize a redundant leading product/version heading. Do not hide
    # sections from the author's source: content policy belongs to authoring.
    heading = re.fullmatch(r'#{1,3}\s+MyTerm\s+v?('+VERSION+r')\s*', lines[0].strip(), re.I)
    if heading:
        if heading[1] != version:
            raise ValueError('Release notes title does not match the release version')
        lines.pop(0)
    parts = []
    paragraph = []
    list_kind = None

    def flush_paragraph():
        if paragraph:
            parts.append('<p>'+html.escape(' '.join(item.strip() for item in paragraph))+'</p>')
            paragraph.clear()

    def close_list():
        nonlocal list_kind
        if list_kind:
            parts.append(f'</{list_kind}>')
            list_kind = None

    for raw in lines:
        line = raw.rstrip()
        if not line:
            flush_paragraph()
            close_list()
            continue
        heading = re.match(r'^(#{1,3})\s+(.+)$', line)
        bullet = re.match(r'^\s*[-*]\s+(.+)$', line)
        numbered = re.match(r'^\s*\d+[.)]\s+(.+)$', line)
        if heading:
            flush_paragraph()
            close_list()
            level = max(2, len(heading[1]))
            parts.append(f'<h{level}>{html.escape(heading[2])}</h{level}>')
        elif bullet or numbered:
            flush_paragraph()
            desired = 'ul' if bullet else 'ol'
            if list_kind != desired:
                close_list()
                list_kind = desired
                parts.append(f'<{desired}>')
            parts.append('<li>'+html.escape((bullet or numbered)[1])+'</li>')
        else:
            close_list()
            paragraph.append(line)
    flush_paragraph()
    close_list()
    if not parts:
        raise ValueError('Release notes must contain content beyond the version title')
    body = '\n    '.join(parts)
    return f'''<!doctype html>
<html lang="zh-Hant">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light dark">
  <title>MyTerm {version} 更新說明</title>
  <link rel="stylesheet" href="/assets/release-notes.css">
</head>
<body>
  <main>
    <h1>MyTerm {version}</h1>
    {body}
  </main>
</body>
</html>
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    output = render(args.source.read_text(encoding='utf-8'), args.version)
    args.output.write_text(output, encoding='utf-8')


if __name__ == '__main__':
    main()
