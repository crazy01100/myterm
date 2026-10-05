const {test}=require('node:test');
const assert=require('node:assert/strict');
const net=require('node:net');
const path=require('node:path');
const {createRequire}=require('node:module');
const {spawnSync}=require('node:child_process');
const local=createRequire(path.resolve(__dirname,'../../package.json'));
const cli=createRequire(local.resolve('firebase-tools/package.json'));
const getUri=cli('get-uri').getUri;
const ftpRequire=createRequire(cli.resolve('get-uri'));
const {Client}=ftpRequire('basic-ftp');
async function server(t,{fallback=false,missing=false,stall=false,legacy=false,separateHost=false}={}){
 const connections=new Set(),servers=[];const commands=[];
 const control=net.createServer(socket=>{
  connections.add(socket);socket.on('error',()=>{});socket.on('close',()=>connections.delete(socket));socket.write('220 fixture\r\n');
  let buffer='',dataSocket,pending;
  function transfer(data){
   socket.write('150 sending\r\n');
   const send=()=>{dataSocket.end(data);socket.write('226 done\r\n');pending=undefined;};
   if(dataSocket)send();else pending=send;
  }
  socket.on('data',chunk=>{
   buffer+=chunk.toString();let end;
   while((end=buffer.indexOf('\r\n'))>=0){
    const line=buffer.slice(0,end);buffer=buffer.slice(end+2);const verb=line.split(' ')[0];commands.push(verb);
    if(verb==='USER')socket.write('331 password\r\n');
    else if(verb==='PASS')socket.write('230 logged in\r\n');
    else if(verb==='FEAT')socket.write(fallback&&!legacy?'211-features\r\n MLST type*;size*;modify*;\r\n211 end\r\n':'211 no features\r\n');
    else if(verb==='PWD')socket.write('257 "/"\r\n');
    else if(verb==='MDTM'){
     if(!stall)socket.write(missing?'550 missing\r\n':fallback?'500 unsupported\r\n':'213 20260101000000\r\n');
    }else if(verb==='PASV'&&separateHost){socket.write('227 (192,0,2,1,0,1)\r\n');
    }else if(verb==='EPSV'&&separateHost){socket.write('500 unsupported\r\n');
    }else if(verb==='EPSV'){
     dataSocket=undefined;
     const data=net.createServer(s=>{dataSocket=s;connections.add(s);s.on('error',()=>{});s.on('close',()=>connections.delete(s));if(pending)pending();});servers.push(data);
     data.listen(0,'127.0.0.1',()=>socket.write(`229 (|||${data.address().port}|)\r\n`));
    }else if(verb==='MLSD')transfer('type=file;size=7;modify=20260101000000; fixture.pac\r\n');
    else if(verb==='LIST')transfer('-rw-r--r-- 1 owner group 7 Jan 1 2026 fixture.pac\r\n');
    else if(verb==='RETR')transfer('fixture');
    else if(verb==='QUIT')socket.end('221 goodbye\r\n');
    else socket.write('200 ok\r\n');
   }
  });
 });
 await new Promise(resolve=>control.listen(0,'127.0.0.1',resolve));servers.push(control);
 t.after(async()=>{for(const s of connections)s.destroy();await Promise.all(servers.map(s=>new Promise(resolve=>s.close(resolve))));});
 return {port:control.address().port,commands};
}
for(const fallback of [false,true])test(`real get-uri FTP download (directory fallback=${fallback})`,{timeout:8000},async t=>{
 const fixture=await server(t,{fallback});const stream=await getUri(new URL(`ftp://fixture:synthetic@127.0.0.1:${fixture.port}/fixture.pac`));
 const chunks=[];for await(const c of stream)chunks.push(c);assert.equal(Buffer.concat(chunks).toString(),'fixture');
 assert.equal(fixture.commands.includes('MLSD'),fallback);
});
test('legacy LIST without a reliable timestamp retains get-uri rejection',{timeout:8000},async t=>{
 const fixture=await server(t,{fallback:true,legacy:true});
 await assert.rejects(getUri(new URL(`ftp://127.0.0.1:${fixture.port}/fixture.pac`)),e=>e.code==='ENOTFOUND');
 assert.ok(fixture.commands.includes('LIST'));
});
test('get-uri reports missing remote files' ,{timeout:8000},async t=>{
 const fixture=await server(t,{missing:true});await assert.rejects(getUri(new URL(`ftp://127.0.0.1:${fixture.port}/missing`)),e=>e.code==='ENOTFOUND');
});
test('FTP pending request can be explicitly closed',{timeout:8000},async t=>{
 const fixture=await server(t,{stall:true});const client=new Client(1000);t.after(()=>client.close());
 await client.access({host:'127.0.0.1',port:fixture.port,user:'fixture',password:'synthetic'});
 const pending=client.lastMod('/fixture.pac');const failure=assert.rejects(pending);client.close();await failure;
});
test('malformed Unix listing remains bounded and ordinary listing works',()=>{
 const file=ftpRequire.resolve('basic-ftp/dist/parseList.js');
 const code=`const assert=require('node:assert/strict');const {parseList}=require(process.argv[1]);
 const line='-rw-r--r-- 1 owner group 7 Jan 1 2026 fixture.pac';assert.equal(parseList(line)[0].name,'fixture.pac');
 const bad='-rw-r--r-- 1 '+'a '.repeat(65536)+'!';
 try {parseList(bad+'\\r\\n'+line)} catch(e) {assert.ok(e instanceof Error);}`;
 const result=spawnSync(process.execPath,['--max-old-space-size=128','-e',code,file],{encoding:'utf8',timeout:4000});
 assert.equal(result.error,undefined);assert.equal(result.status,0,result.stderr);
});
test('proxy-agent still constructs supported proxy routes without a network',()=>{
 const {ProxyAgent}=cli('proxy-agent');const agent=new ProxyAgent({getProxyForUrl:()=> 'http://127.0.0.1:1'});
 assert.equal(typeof agent.connect,'function');agent.destroy();
});

test('default FTP client rejects a different PASV transfer host',{timeout:8000},async t=>{
 const fixture=await server(t,{separateHost:true});const client=new Client(1000);t.after(()=>client.close());
 await client.access({host:'127.0.0.1',port:fixture.port,user:'fixture',password:'synthetic'});
 const {PassThrough}=require('node:stream');const sink=new PassThrough();sink.resume();t.after(()=>sink.destroy());
 await assert.rejects(client.downloadTo(sink,'fixture.pac'),/another host/);
 assert.ok(fixture.commands.includes('PASV'));assert.ok(!fixture.commands.includes('RETR'));
});
