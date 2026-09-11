"""Bounded local protocol peer; never connects to a real SSH server."""
import os, struct, sys, time
mode=sys.argv[1]
if len(sys.argv)>2:open(sys.argv[2],'w').write(str(os.getpid()))
R=sys.stdin.buffer;W=sys.stdout.buffer
u=lambda n:struct.pack('>I',n)
s=lambda b:u(len(b))+b
pages=reads=0
while True:
 h=R.read(4)
 if not h:break
 p=R.read(struct.unpack('>I',h)[0]);t=p[0];i=p[1:5]
 if t==1:
  if mode=='early_exit':break
  if mode=='init_stall':time.sleep(5);break
  if mode=='partial':W.write(u(5)+b'\x02');W.flush();time.sleep(5);break
  if mode=='oversized':W.write(u(16*1024*1024+1));W.flush();break
  out=b'\x02'+u(3)
 elif t==16:
  if mode=='realpath_stall':time.sleep(5);break
  out=b'\x68'+i+u(1)+s(b'/test')+s(b'')+u(0)
 elif t in (3,11):out=b'\x66'+i+s(b'handle')
 elif t==12:
  pages+=1
  if mode=='list_stall':time.sleep(5);break
  if mode=='empty_name':out=b'\x68'+i+u(0)
  elif mode=='name_limit' and pages<=12:
   ent=s(b'file')+s(b'')+u(4)+u(0o100644)
   out=b'\x68'+i+u(10000)+ent*10000
  elif mode=='depth':out=b'\x68'+i+u(1)+s(b'x')+s(b'')+u(4)+u(0o40755)
  else:out=b'\x65'+i+u(1)+s(b'EOF')+s(b'')
 elif t==5:
  reads+=1
  if mode=='status_ok':out=b'\x65'+i+u(0)+s(b'OK')+s(b'')
  elif mode=='empty_data':out=b'\x67'+i+s(b'')
  elif mode=='long_data':out=b'\x67'+i+s(b'x'*65537)
  elif mode=='slow' and reads<=8:
   time.sleep(.04);out=b'\x67'+i+s(b'12345678')
  else:out=b'\x65'+i+u(1)+s(b'EOF')+s(b'')
 else:out=b'\x65'+i+u(0)+s(b'OK')+s(b'')
 W.write(u(len(out))+out);W.flush()
