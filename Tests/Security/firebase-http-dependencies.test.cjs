const {test}=require('node:test');
const assert=require('node:assert/strict');
const http=require('node:http');
const zlib=require('node:zlib');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {createRequire}=require('node:module');
const cli=createRequire(path.resolve(__dirname,'../../node_modules/firebase-tools/package.json'));
const staticRequire=createRequire(cli.resolve('superstatic'));
const compression=staticRequire('compression');
const expressPaths=[cli.resolve('express'),createRequire(cli.resolve('@modelcontextprotocol/sdk/server/express.js')).resolve('express')];

test('MCP rate-limit consumer preserves ordinary IPv4 and IPv6 keys',()=>{
 const sdkRequire=createRequire(cli.resolve('@modelcontextprotocol/sdk/server/express.js'));
 const {ipKeyGenerator}=sdkRequire('express-rate-limit');
 assert.equal(ipKeyGenerator('192.0.2.1'),'192.0.2.1');
 assert.equal(ipKeyGenerator('::ffff:192.0.2.1'),'192.0.2.1');
 assert.equal(ipKeyGenerator('2001:db8:1234:5678::1'),'2001:db8:1234:5600::/56');
 assert.equal(ipKeyGenerator('2001:db8:1234:5678::1',64),'2001:db8:1234:5678::/64');
 assert.equal(ipKeyGenerator('2001:db8::1',false),'2001:db8::1');
});

async function listen(t,handler){
 const server=http.createServer(handler);
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
 t.after(()=>new Promise(resolve=>{server.closeAllConnections();server.close(resolve);}));
 return server.address().port;
}
async function request(port,headers={}){
 return new Promise((resolve,reject)=>{
  const req=http.get({host:'127.0.0.1',port,path:'/',headers},res=>{
   const chunks=[];res.on('data',c=>chunks.push(c));res.on('error',reject);
   res.on('end',()=>resolve({headers:res.headers,body:Buffer.concat(chunks)}));
  });req.on('error',reject);
 });
}

for(const [encoding,factory] of [['gzip','createGzip'],['deflate','createDeflate'],['br','createBrotliCompress']]){
 test(`aborted ${encoding} response releases the real compression stream`,{timeout:5000},async t=>{
  const descriptor=Object.getOwnPropertyDescriptor(zlib,factory);
  let captured;
  let released;
  const closed=new Promise(resolve=>{released=resolve;});
  Object.defineProperty(zlib,factory,{...descriptor,value:(...args)=>{
   captured=descriptor.value(...args);captured.once('close',released);return captured;
  }});
  t.after(()=>{Object.defineProperty(zlib,factory,descriptor);captured?.destroy();});
  const middleware=compression({threshold:0});
  const port=await listen(t,(req,res)=>middleware(req,res,()=>{
   res.setHeader('Content-Type','text/plain');res.write('synthetic response '.repeat(200));res.flush();
   // Deliberately leave the response unfinished; the client closes it.
  }));
  await new Promise((resolve,reject)=>{
   const req=http.get({host:'127.0.0.1',port,headers:{'Accept-Encoding':encoding}},res=>{
    assert.equal(res.headers['content-encoding'],encoding);
    res.once('data',()=>{res.destroy();resolve();});res.on('error',reject);
   });req.on('error',reject);t.after(()=>req.destroy());
  });
  await closed;
  assert.ok(captured.destroyed,'native compression resource must be destroyed after client abort');
 });
}

test('Firebase superstatic serves both gzip and identity content',{timeout:5000},async t=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'myterm-http-'));
 t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
 const body='synthetic static content\n'.repeat(200);
 fs.writeFileSync(path.join(dir,'index.html'),body);
 const app=cli('superstatic').default({cwd:dir,config:{public:'.'},compression:true,fallthrough:false});
 const port=await listen(t,(req,res)=>app(req,res,error=>{
  res.statusCode=error?500:404;res.end(error?'fixture middleware error':'missing fixture');
 }));
 const zipped=await request(port,{'Accept-Encoding':'gzip'});
 assert.equal(zipped.headers['content-encoding'],'gzip');
 assert.equal(zlib.gunzipSync(zipped.body).toString(),body);
 const plain=await request(port,{'Accept-Encoding':'identity'});
 assert.equal(plain.headers['content-encoding'],undefined);
 assert.equal(plain.body.toString(),body);
});

for(const entry of [...new Set(expressPaths)]){
 const express=require(entry);
 const version=createRequire(entry)('./package.json').version;
 const proxyaddr=createRequire(entry)('proxy-addr');
 test(`Express ${version} proxy trust rejects unrelated IPv4 addresses`,()=>{
  for(const subnet of ['::ffff:10.0.0.0/8','::/1']){
   const trust=proxyaddr.compile(subnet);
   assert.equal(trust('192.0.2.10'),false);
   assert.equal(proxyaddr({socket:{remoteAddress:'192.0.2.10'},headers:{'x-forwarded-for':'198.51.100.7'}},trust),'192.0.2.10');
  }
  for(const subnet of ['10.0.0.0/8','::ffff:10.0.0.0/104']){
   const trust=proxyaddr.compile(subnet);
   assert.equal(trust('10.2.3.4'),true);assert.equal(trust('192.0.2.10'),false);
  }
  assert.equal(proxyaddr.compile('2001:db8::/32')('2001:db8::1'),true);
  assert.equal(proxyaddr.compile('2001:db8::/32')('2001:db9::1'),false);
 });
 test(`Express ${version} real HTTP forwarded-IP policy remains compatible`,{timeout:5000},async t=>{
  const app=express();app.get('/',(req,res)=>res.json({ip:req.ip,ips:req.ips}));
  const port=await listen(t,app);const headers={'X-Forwarded-For':'198.51.100.7'};
  const direct=JSON.parse((await request(port,headers)).body);
  assert.equal(direct.ip,'127.0.0.1');assert.deepEqual(direct.ips,[]);
  app.set('trust proxy','::/1');
  assert.equal(JSON.parse((await request(port,headers)).body).ip,'127.0.0.1');
  app.set('trust proxy','loopback');
  const forwarded=JSON.parse((await request(port,headers)).body);
  assert.equal(forwarded.ip,'198.51.100.7');assert.deepEqual(forwarded.ips,['198.51.100.7']);
 });
}

for(const entry of [...new Set(expressPaths)]){
 const express=require(entry);
 const parser=createRequire(entry)('body-parser');
 const version=createRequire(entry)('./package.json').version;
 test(`Express ${version} body-parser keeps compressed JSON and form parsing compatible`,{timeout:5000},async t=>{
  const app=express();
  app.post('/json',parser.json({limit:'16kb'}),(req,res)=>res.json(req.body));
  app.post('/form',parser.urlencoded({extended:true,limit:'16kb'}),(req,res)=>res.json(req.body));
  const port=await listen(t,app);
  async function post(url,body,headers){
   return new Promise((resolve,reject)=>{
    const req=http.request({host:'127.0.0.1',port,path:url,method:'POST',headers:{...headers,'Content-Length':body.length}},res=>{
     const chunks=[];res.on('data',c=>chunks.push(c));res.on('error',reject);
     res.on('end',()=>resolve({status:res.statusCode,data:JSON.parse(Buffer.concat(chunks).toString())}));
    });req.on('error',reject);req.end(body);
   });
  }
  for(const [encoding,compress] of [['gzip',zlib.gzipSync],['deflate',zlib.deflateSync]]){
   const data={name:'fixture',values:[1,2,3]};
   const response=await post('/json',compress(Buffer.from(JSON.stringify(data))),{'Content-Type':'application/json','Content-Encoding':encoding});
   assert.equal(response.status,200);assert.deepEqual(response.data,data);
  }
  const form=await post('/form',Buffer.from('name=fixture&roles%5B%5D=reader&roles%5B%5D=writer'),{'Content-Type':'application/x-www-form-urlencoded'});
  assert.equal(form.status,200);assert.deepEqual(form.data,{name:'fixture',roles:['reader','writer']});
 });
}

const gyp=createRequire(cli.resolve('node-gyp/package.json'));
for(const entry of [...new Set([cli.resolve('undici'),gyp.resolve('undici')])]){
 const undici=require(entry);
 test(`Undici ${createRequire(entry)('./package.json').version} preserves ordinary HTTP response decoding`,{timeout:5000},async t=>{
  const body=JSON.stringify({message:'fixture'});
  const port=await listen(t,(_req,res)=>{res.writeHead(200,{'Content-Type':'application/json','Content-Encoding':'gzip'});res.end(zlib.gzipSync(body));});
  const agent=new undici.Agent();t.after(()=>agent.close());
  const response=await undici.fetch(`http://127.0.0.1:${port}/`,{dispatcher:agent});
  assert.equal(response.status,200);assert.deepEqual(await response.json(),{message:'fixture'});
 });
}

test('Firebase Zod validates ordinary constrained tool input',()=>{
 const z=cli('zod');
 const schema=z.object({project:z.string().min(1),files:z.array(z.string()).max(5)});
 const input={project:'demo-myterm',files:['firestore.rules']};
 assert.deepEqual(schema.parse(input),input);
 assert.equal(schema.safeParse({project:'demo-myterm',files:[42]}).success,false);
});
