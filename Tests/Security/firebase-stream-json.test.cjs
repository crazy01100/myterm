const {test}=require('node:test');
const assert=require('node:assert/strict');
const {Readable}=require('node:stream');
const {createRequire}=require('node:module');
const {spawnSync}=require('node:child_process');
const path=require('node:path');
const root=path.resolve(__dirname,'../..');
const local=createRequire(path.join(root,'package.json'));
const cli=createRequire(local.resolve('firebase-tools/package.json'));
const Chain=cli('stream-chain');
const {parserStream}=cli('stream-json');
const {pick}=cli('stream-json/filters/pick.js');
const {streamArray}=cli('stream-json/streamers/stream-array.js');
const {streamObject}=cli('stream-json/streamers/stream-object.js');
function input(value,size){const bytes=Buffer.from(JSON.stringify(value));return Readable.from(Array.from({length:Math.ceil(bytes.length/size)},(_,i)=>bytes.subarray(i*size,(i+1)*size)));}
function collect(stages){return new Promise((resolve,reject)=>{const out=[];new Chain(stages).on('data',v=>out.push(v)).on('error',reject).on('end',()=>resolve(out));});}

test('installed CLI has the reviewed compatibility patch and loads its consumers',()=>{
 const checked=spawnSync('python3',[path.join(root,'scripts/patch-firebase-stream-json.py'),'--check'],{encoding:'utf8',timeout:10000});
 assert.equal(checked.status,0,checked.stderr);
 for(const module of ['commands/auth-import','database/import','frameworks/next/index'])assert.doesNotThrow(()=>cli('./lib/'+module+'.js'));
});

test('Auth JSON extraction preserves chunked Unicode, arrays, nulls and numbers',async()=>{
 for(const size of [1,7,4096])for(const users of [[],[{localId:'x',displayName:'中文🧪',disabled:false}], [{n:0,a:[true,null,{b:'c'}]},{n:-125000}]]){
  const actual=await collect([input({metadata:{ignored:1},users,other:['skip']},size),pick.withParserAsStream({filter:/^users$/}),streamArray.asStream()]);
  assert.deepEqual(actual,users.map((value,key)=>({key,value})));
 }
});

test('Next.js dependency extraction preserves the CLI parser options',async()=>{
 // Firebase deliberately omits string/number values; these expected tokens
 // were verified against its original stream-json 1.9.1 pipeline.
 const cases=[ [{},[]], [{alpha:{version:'1',dependencies:{beta:{version:'2'}}}},[{key:'alpha',value:{dependencies:{beta:{}}}}]], [{'套件':{version:'1',optional:false,extra:[1,null]}},[{key:'套件',value:{optional:false,extra:[null]}}]] ];
 for(const size of [1,7,4096])for(const [dependencies,expected] of cases){
  const actual=await collect([input({name:'test',dependencies},size),parserStream({packValues:false,packKeys:true,streamValues:false}),pick.asStream({filter:'dependencies'}),streamObject.asStream()]);
  assert.deepEqual(actual,expected);
 }
});

test('actual DatabaseImporter retains filtered request data without a network',async()=>{
 const Importer=cli('./lib/database/import.js').default;
 for(const size of [1,7,4096]){
  const importer=new Importer(new URL('https://example.invalid/test'),input({nested:{a:1,b:{c:[1,2,true]}},skip:3},size),'/nested',1024*1024,1);
  const requests=[];importer.client.request=async request=>{requests.push(request);return {status:200};};
  await importer.readAndWriteChunks();
  assert.equal(requests.length,1);
  assert.equal(requests[0].method,'PATCH');
  assert.equal(requests[0].path,'/test/nested.json');
  assert.deepEqual(requests[0].body,{a:1,b:{c:[1,2,true]}});
 }
});

test('malformed JSON remains rejected',async()=>{
 for(const source of ['{"users":[','{"users":[1,]}','not json'])await assert.rejects(collect([Readable.from([source]),pick.withParserAsStream({filter:/^users$/}),streamArray.asStream()]));
});

test('all vulnerable filter families reject excessive depth within a bounded process',()=>{
 const code=`
 const {Readable}=require('node:stream');const {pipeline}=require('node:stream/promises');const {createRequire}=require('node:module');const req=createRequire(process.argv[1]);
 (async()=>{for(const name of ['pick','ignore','filter','replace'])for(const filter of ['data',/^data$/]){
  const factory=req('stream-json/filters/'+name+'.js')[name];let rejected=false;
  try{await pipeline(Readable.from(['{"meta":'.repeat(20000)+'1'+'}'.repeat(20000)]),factory.withParserAsStream({filter}),async function*(source){for await(const token of source){}});}catch(e){if(!(e instanceof RangeError))throw e;rejected=true;}
  if(!rejected)throw Error(name+' failed to cap nesting');
 }})().catch(e=>{console.error(e);process.exit(1)});`;
 const child=spawnSync(process.execPath,['--max-old-space-size=128','-e',code,local.resolve('firebase-tools/package.json')],{encoding:'utf8',timeout:5000});
 assert.equal(child.error,undefined);assert.equal(child.status,0,child.stderr);
});
