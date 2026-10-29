#!/usr/bin/env python3
"""Read inline Go build metadata from a previously verified official executable."""
import re
import struct

MAGIC = b'\xff Go buildinf:'


def function_names(blob):
    """Read the reviewed 64-bit little-endian Go 1.20+ pclntab, including inlines.

    Layout follows debug/gosym/pclntab.go. Called only after official asset
    identity verification; unknown/ambiguous layouts fail closed.
    """
    if len(blob) > 128 * 1024 * 1024:
        raise ValueError('Oversized Go executable')
    starts = [m.start() for m in re.finditer(b'\xf1\xff\xff\xff\x00\x00[\x01\x02\x04]\x08', blob)]
    if len(starts) != 1:
        raise ValueError('Missing or ambiguous Go function table')
    start = starts[0]
    if start + 72 > len(blob):
        raise ValueError('Truncated Go function header')
    count, files, _, names, cu, filetab, pctab, funcs = struct.unpack_from('<8Q', blob, start + 8)
    size = len(blob) - start
    if (not 0 < count <= 1000000 or not 0 < files <= 100000
            or not 72 <= names < cu <= filetab <= pctab <= funcs < size
            or funcs + (count * 2 + 1) * 4 > size):
        raise ValueError('Invalid Go function table bounds')
    table = blob[start + names:start + cu]
    values = table.split(b'\x00')
    if values[-1] or not values[0]:
        raise ValueError('Incomplete Go function names')
    try:
        decoded = [v.decode('utf-8') for v in values if v]
    except UnicodeDecodeError as error:
        raise ValueError('Invalid Go function name encoding') from error
    if not decoded or any(len(n) > 8192 or any(ord(c) < 32 for c in n) for n in decoded):
        raise ValueError('Invalid Go function names')
    # Validate every concrete function's name offset, not a raw binary search.
    for index in range(count):
        relative = struct.unpack_from('<I', blob, start + funcs + index * 8 + 4)[0]
        if relative < (count * 2 + 1) * 4 or funcs + relative + 8 > size:
            raise ValueError('Invalid Go function record')
        offset = struct.unpack_from('<i', blob, start + funcs + relative + 4)[0]
        if (offset < 0 or offset >= len(table) or not table[offset]
                or (offset and table[offset - 1] != 0)):
            raise ValueError('Invalid Go function name offset')
    return sorted(set(decoded))


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
