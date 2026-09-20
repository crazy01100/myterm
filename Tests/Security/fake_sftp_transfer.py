"""Local SFTP transfer wire peer. Files are confined to a generated test root."""
import json, os, struct, sys, time
from pathlib import Path
root = Path(sys.argv[1]).resolve()
mode = sys.argv[2]
(root / 'peer.pid').write_text(str(os.getpid()))
u = lambda n: struct.pack('>I', n)
s = lambda b: u(len(b)) + b
handles = {}; serial = 0
def path(raw):
    p = (root / raw.decode().lstrip('/')).resolve()
    assert p.is_relative_to(root)
    return p
def string(p, offset):
    n = struct.unpack('>I', p[offset:offset+4])[0]
    return p[offset+4:offset+4+n], offset+4+n
def status(i, code):
    return bytes([101]) + i + u(code) + s(b'fixture') + s(b'')
while True:
    h = sys.stdin.buffer.read(4)
    if not h: break
    p = sys.stdin.buffer.read(struct.unpack('>I', h)[0]); t = p[0]; i = p[1:5]
    with (root / 'events.jsonl').open('a') as log: log.write(json.dumps({'type':t})+'\n')
    try:
        if t == 1:
            out = bytes([2]) + u(3)
            if mode != 'unsupported': out += s(b'posix-rename@openssh.com') + s(b'2' if mode == 'version2' else b'1')
        elif t == 16:
            out = bytes([104]) + i + u(1) + s(b'/test') + s(b'') + u(0)
        elif t == 7:
            raw, _ = string(p,5); target=path(raw)
            if target.exists(): out=bytes([105])+i+u(5)+struct.pack('>Q',target.stat().st_size)+u(target.stat().st_mode)
            else: out=status(i,2)
        elif t == 14:
            raw,_=string(p,5); target=path(raw); target.mkdir(mode=0o700)
            if mode=='mkdir_conflict':
                (target/'foreign').write_text('not ours'); out=status(i,4)
            else: out=status(i,0)
        elif t == 15:
            raw,_=string(p,5); path(raw).rmdir(); out=status(i,0)
        elif t == 11:
            raw,_=string(p,5); serial+=1; key=str(serial).encode()
            handles[key]=iter(path(raw).iterdir()); out=bytes([102])+i+s(key)
        elif t == 12:
            key,_=string(p,5); children=list(handles[key])
            if not children: out=status(i,1)
            else:
                entries=b''.join(s(child.name.encode())+s(b'')+u(5)+struct.pack('>Q',child.stat().st_size)+u(child.stat().st_mode) for child in children)
                out=bytes([104])+i+u(len(children))+entries
        elif t == 3:
            raw, offset=string(p,5); target=path(raw); flags=struct.unpack('>I',p[offset:offset+4])[0]
            f = target.open('xb' if flags & 2 else 'rb')
            serial += 1; key=str(serial).encode(); handles[key]=f
            out=bytes([102])+i+s(key)
        elif t == 6:
            key, offset=string(p,5); position=struct.unpack('>Q',p[offset:offset+8])[0]; data,_=string(p,offset+8)
            handles[key].seek(position); handles[key].write(data); handles[key].flush()
            if mode == 'stall': time.sleep(5)
            else: time.sleep(.02)
            out=status(i,0)
        elif t == 5:
            key,offset=string(p,5); position=struct.unpack('>Q',p[offset:offset+8])[0]; size=struct.unpack('>I',p[offset+8:offset+12])[0]
            handles[key].seek(position); data=handles[key].read(size); time.sleep(.02)
            out=bytes([103])+i+s(data) if data else status(i,1)
        elif t == 4:
            key,_=string(p,5); handle=handles.pop(key)
            if hasattr(handle,'close'): handle.close()
            out=status(i,0)
        elif t == 13:
            raw,_=string(p,5); path(raw).unlink(); out=status(i,0)
        elif t in (18,200):
            offset=5
            if t==200: ext,offset=string(p,offset); assert ext==b'posix-rename@openssh.com'
            old,offset=string(p,offset); new,_=string(p,offset); src,dst=path(old),path(new)
            if mode=='commit_fail' or (t==18 and dst.exists()): out=status(i,4)
            else:
                os.replace(src,dst)
                if mode=='commit_drop': sys.exit(0)
                out=status(i,0)
        else: out=status(i,8)
    except FileNotFoundError: out=status(i,2)
    except (OSError, AssertionError): out=status(i,4)
    sys.stdout.buffer.write(u(len(out))+out); sys.stdout.buffer.flush()
