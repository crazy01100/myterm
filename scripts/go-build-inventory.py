#!/usr/bin/env python3
"""Read inline Go build metadata from a previously verified official executable."""
import re

MAGIC = b'\xff Go buildinf:'


def parse(blob):
    if len(blob) > 128 * 1024 * 1024:
        raise ValueError('Oversized Go executable')
    positions = [m.start() for m in re.finditer(re.escape(MAGIC), blob) if m.start() % 16 == 0]
    if len(positions) != 1:
        raise ValueError('Missing or ambiguous Go build info')
    start = positions[0]
    if start + 32 > len(blob) or blob[start + 14] not in (4, 8) or blob[start + 15] & 2 == 0:
        raise ValueError('Only inline Go build info is supported')

    def string(offset):
        size = 0
        for index in range(10):
            if offset >= len(blob):
                raise ValueError('Truncated Go length')
            value = blob[offset]; offset += 1; size |= (value & 127) << (index * 7)
            if value < 128:
                if size > 1024 * 1024 or offset + size > len(blob):
                    raise ValueError('Invalid Go string bounds')
                return blob[offset:offset + size], offset + size
        raise ValueError('Invalid Go string length')

    compiler, offset = string(start + 32); raw, _ = string(offset)
    compiler = compiler.decode('ascii')
    if not re.fullmatch(r'go1\.\d+\.\d+', compiler) or len(raw) < 33 or raw[-17] != 10:
        raise ValueError('Incomplete Go compiler/module information')
    lines = raw[16:-16].decode('utf-8').splitlines()
    modules = []; seen = set(); path = None
    for line in lines:
        fields = line.split('\t')
        if fields[0] == 'path' and len(fields) == 2:
            if path is not None:
                raise ValueError('Duplicated Go path')
            path = fields[1]
        elif fields[0] in ('mod', 'dep') and len(fields) in (3, 4):
            name, version = fields[1:3]
            if (not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._/+-]{0,239}', name)
                    or not re.fullmatch(r'v\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.+-]+)?', version)
                    or name in seen or len(modules) >= 2000):
                raise ValueError('Unversioned or ambiguous Go module')
            seen.add(name); modules.append({'name': name, 'version': version, 'kind': fields[0]})
        elif fields[0] == 'build':
            continue
        else:
            # Local/remote replacements require their own exact identity; never
            # query the replaced version as though it were the installed one.
            raise ValueError('Unsupported Go module record or replacement')
    parents = [x for x in modules if x['kind'] == 'mod']
    if len(parents) != 1 or not path or not path.startswith(parents[0]['name'] + '/'):
        raise ValueError('Go parent module identity missing')
    return {'compiler': compiler, 'path': path, 'modules': modules,
            'reachability': 'build metadata does not prove vulnerable symbols are used'}
