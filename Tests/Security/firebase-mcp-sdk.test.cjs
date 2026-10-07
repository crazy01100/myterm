const {test}=require('node:test');
const assert=require('node:assert/strict');
const {PassThrough}=require('node:stream');
const {createRequire}=require('node:module');
const path=require('node:path');
const cli=createRequire(path.resolve(__dirname,'../../node_modules/firebase-tools/package.json'));
const sdk=name=>cli('@modelcontextprotocol/sdk/'+name+'.js');
const {Server}=sdk('server/index');
const {Client}=sdk('client/index');
const {InMemoryTransport}=sdk('inMemory');
const {StdioServerTransport}=sdk('server/stdio');
const {ReadBuffer}=sdk('shared/stdio');
const {ListToolsRequestSchema,LATEST_PROTOCOL_VERSION}=sdk('types');
const {fetchToken}=sdk('client/auth');

function fixtureServer(){
 const server=new Server({name:'synthetic-fixture',version:'1.0.0'});
 server.registerCapabilities({tools:{listChanged:true}});
 server.setRequestHandler(ListToolsRequestSchema,async()=>({tools:[{
  name:'fixture',description:'Does not access Firebase',inputSchema:{type:'object'}
 }]}));
 return server;
}

test('Firebase-style Server APIs retain in-memory handshake and tool listing',{timeout:5000},async t=>{
 const server=fixtureServer();const client=new Client({name:'synthetic-client',version:'1.0.0'});
 const [clientTransport,serverTransport]=InMemoryTransport.createLinkedPair();
 t.after(async()=>{await client.close();await server.close();});
 await server.connect(serverTransport);await client.connect(clientTransport);
 assert.equal(client.getServerVersion().name,'synthetic-fixture');
 assert.equal(server.getClientVersion().name,'synthetic-client');
 assert.equal((await client.listTools()).tools[0].name,'fixture');
});

test('stdio server accepts fragmented initialization and tool-list messages',{timeout:5000},async t=>{
 const input=new PassThrough(),output=new PassThrough();const buffer=new ReadBuffer();
 const pending=new Map();const server=fixtureServer();
 output.on('data',chunk=>{
  buffer.append(chunk);let message;
  while((message=buffer.readMessage())!==null){pending.get(message.id)?.(message);pending.delete(message.id);}
 });
 t.after(async()=>{await server.close();input.destroy();output.destroy();});
 await server.connect(new StdioServerTransport(input,output));
 const initialized=new Promise(resolve=>pending.set(1,resolve));
 const line=JSON.stringify({jsonrpc:'2.0',id:1,method:'initialize',params:{
  protocolVersion:LATEST_PROTOCOL_VERSION,capabilities:{},clientInfo:{name:'stdio-fixture',version:'1.0.0'}
 }})+'\n';
 input.write(line.slice(0,13));input.write(line.slice(13));
 assert.equal((await initialized).result.serverInfo.name,'synthetic-fixture');
 const listed=new Promise(resolve=>pending.set(2,resolve));
 input.write(JSON.stringify({jsonrpc:'2.0',method:'notifications/initialized'})+'\n'+
  JSON.stringify({jsonrpc:'2.0',id:2,method:'tools/list',params:{}})+'\n');
 assert.equal((await listed).result.tools[0].name,'fixture');
});

function provider(){
 return {clientMetadata:{},clientInformation:()=>({
  client_id:'fixture',client_secret:'synthetic-secret',issuer:'https://auth.example'
 }),prepareTokenRequest:()=>new URLSearchParams({grant_type:'client_credentials'})};
}
test('OAuth client refuses credentials bound to another issuer before any request',async()=>{
 for(const issuer of ['https://other.example','https://auth.example.attacker.invalid']){
  let calls=0;
  await assert.rejects(fetchToken(provider(),issuer,{fetchFn:async()=>{calls++;throw Error('unexpected request');}}),/bound to authorization server/);
  assert.equal(calls,0);
 }
});
test('OAuth client still accepts its matching issuer with intercepted synthetic transport',async()=>{
 let calls=0;
 const result=await fetchToken(provider(),'https://auth.example',{
  metadata:{issuer:'https://auth.example',token_endpoint:'https://auth.example/token',token_endpoint_auth_methods_supported:['client_secret_post']},
  fetchFn:async(url,options)=>{
   calls++;assert.equal(String(url),'https://auth.example/token');
   const body=new URLSearchParams(options.body);
   assert.equal(body.get('client_id'),'fixture');assert.equal(body.get('client_secret'),'synthetic-secret');
   return new Response(JSON.stringify({access_token:'synthetic-access',token_type:'Bearer',expires_in:60}),{status:200,headers:{'Content-Type':'application/json'}});
  }
 });
 assert.equal(calls,1);assert.equal(result.access_token,'synthetic-access');
});
