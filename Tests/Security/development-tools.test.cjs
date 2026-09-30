const {test} = require('node:test');
const assert = require('node:assert/strict');
const {createRequire} = require('node:module');
const path = require('node:path');
const local = createRequire(path.join(process.cwd(),'package.json'));
test('Firebase CSV stream API remains compatible',async()=>{
 const parse=local('csv-parse').parse;
 const rows=await new Promise((resolve,reject)=>parse('name,value\n"quoted,name",42\n',{},(err,rows)=>err?reject(err):resolve(rows)));
 assert.deepEqual(rows,[['name','value'],['quoted,name','42']]);
});
test('PubSub propagator round trips trace context without a network',()=>{
 const pubsub=createRequire(local.resolve('@google-cloud/pubsub'));
 const core=pubsub('@opentelemetry/core');
 const api=pubsub('@opentelemetry/api');
 const propagator=new core.W3CTraceContextPropagator();
 const context=api.trace.setSpanContext(api.ROOT_CONTEXT,{traceId:'1'.repeat(32),spanId:'2'.repeat(16),traceFlags:1});
 const carrier={};propagator.inject(context,carrier,{set:(c,k,v)=>c[k]=v});
 const extracted=propagator.extract(api.ROOT_CONTEXT,carrier,{get:(c,k)=>c[k],keys:c=>Object.keys(c)});
 assert.equal(api.trace.getSpanContext(extracted).traceId,'1'.repeat(32));
});
test('Gaxios UUID dependency retains CommonJS v4 API',()=>{
 const transport=createRequire(local.resolve('gaxios'));
 assert.match(transport('uuid').v4(),/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
 assert.equal(typeof local('gaxios').Gaxios,'function');
});
test('qs preserves ordinary input and blocks prototype keys',()=>{
 const qs=local('qs');assert.deepEqual(qs.parse('x=1&x=2'),{x:['1','2']});
 assert.equal(Object.hasOwn(qs.parse('__proto__[polluted]=yes'),'__proto__'),false);
});
test('IP classification recognizes the full link-local and local-use NAT64 ranges',()=>{
 const {Address6}=local('ip-address');
 for(const ip of ['fe80::1','fea0::1','febf:ffff::1'])assert.equal(new Address6(ip).isLinkLocal(),true);
 assert.equal(new Address6('2001:db8::1').isLinkLocal(),false);
 assert.equal(new Address6('64:ff9b:1::1').isPrivate(),true);
 assert.equal(new Address6('2001:4860:4860::8888').isPrivate(),false);
});
test('Morgan quoted fields escape quotes, backslashes and newlines',()=>{
 const morgan=local('morgan');const value='agent"\\\r\ninjected';
 const result=morgan.compile('\":req[user-agent]\"')(morgan,{headers:{'user-agent':value}},{});
 assert.equal(result,JSON.stringify(value));
});
test('Firebase Undici preserves request handling without external traffic',async()=>{
 const cli=createRequire(local.resolve('firebase-tools/package.json'));
 const {MockAgent,request}=cli('undici');const agent=new MockAgent();agent.disableNetConnect();
 try {
  agent.get('https://example.invalid').intercept({path:'/test',method:'GET'}).reply(200,{ok:true},{headers:{'content-type':'application/json'}});
  const response=await request('https://example.invalid/test',{dispatcher:agent});
  assert.equal(response.statusCode,200);assert.deepEqual(await response.body.json(),{ok:true});agent.assertNoPendingInterceptors();
 } finally {await agent.close();}
});
test('Google gax creates a working gRPC client with explicit local credentials',async t=>{
 const gax=local('google-gax');const resolver=createRequire(local.resolve('google-gax'));
 const grpc=resolver('@grpc/grpc-js');const serialize=x=>Buffer.from(JSON.stringify(x));const deserialize=x=>JSON.parse(x.toString());
 const service={echo:{path:'/myterm.Test/Echo',requestStream:false,responseStream:false,requestSerialize:serialize,requestDeserialize:deserialize,responseSerialize:serialize,responseDeserialize:deserialize}};
 const server=new grpc.Server();server.addService(service,{echo:(call,done)=>done(null,{value:call.request.value})});
 t.after(()=>server.forceShutdown());
 const port=await new Promise((resolve,reject)=>server.bindAsync('127.0.0.1:0',grpc.ServerCredentials.createInsecure(),(error,port)=>error?reject(error):resolve(port)));
 const factory=new gax.GrpcClient({auth:{getUniverseDomain:async()=> 'googleapis.com'}});
 // Keep this fixture independent of local ADC and client-certificate settings.
 factory._detectClientCertificate=async()=>[undefined,undefined];
 const Client=grpc.makeGenericClientConstructor(service,'Test');
 const client=await factory.createStub(Client,{servicePath:'127.0.0.1',port,sslCreds:grpc.credentials.createInsecure()});t.after(()=>client.close());
 const response=await new Promise((resolve,reject)=>client.echo({value:'fixture'},{deadline:Date.now()+5000},(error,value)=>error?reject(error):resolve(value)));
 assert.deepEqual(response,{value:'fixture'});
});
