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
