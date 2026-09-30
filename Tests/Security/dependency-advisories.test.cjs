const {test}=require('node:test');
const assert=require('node:assert/strict');
const {createRequire}=require('node:module');
const {spawnSync}=require('node:child_process');
const path=require('node:path');
const local=createRequire(path.resolve(__dirname,'../../package.json'));
const cli=createRequire(local.resolve('firebase-tools/package.json'));
const glob=createRequire(cli.resolve('glob'));
const readdir=createRequire(cli.resolve('readdir-glob'));
const bracePaths=[...new Set([cli.resolve('minimatch'),glob.resolve('minimatch'),readdir.resolve('minimatch')].map(p=>createRequire(p).resolve('brace-expansion')))];
test('all installed brace branches preserve normal patterns',()=>{
 assert.equal(bracePaths.length,3);
 for(const file of bracePaths){const mod=require(file);const expand=mod.expand||mod;assert.deepEqual(expand('file-{a,b}-{1..2}'),['file-a-1','file-a-2','file-b-1','file-b-2']);}
});
test('brace advisories stay bounded on comma lists, nesting and rewrite input',()=>{
 for(const file of bracePaths){
  const code=`const assert=require('node:assert/strict');const mod=require(process.argv[1]);const expand=mod.expand||mod;
  for(const value of ['{'+ '{a},'.repeat(7000)+'b}', '{{x},'+'a,'.repeat(125000)+'b}', '{'.repeat(8000)+'a,b'+'}'.repeat(8000), '{a},'.repeat(5000)+'b}']) {
   const out=expand(value,{max:2,maxLength:1000000});assert.ok(Array.isArray(out));assert.ok(out.length<=2);
  }`;
  const result=spawnSync(process.execPath,['--max-old-space-size=128','-e',code,file],{encoding:'utf8',timeout:10000});
  assert.equal(result.error,undefined);assert.equal(result.status,0,result.stderr);
 }
});
test('fast-uri normalizes encoded host case consistently',()=>{
 const uri=createRequire(cli.resolve('ajv'))('fast-uri');
 for(const host of ['EXAMPLE.com','%45XAMPLE.com','%65xample.com']){
  assert.equal(uri.parse('https://'+host+'/a').host,'example.com');
  assert.equal(uri.normalize('https://'+host+'/a'),'https://example.com/a');
 }
});
test('actual Firebase configuration validator accepts the repository configuration',()=>{
 const {getValidator}=cli('./lib/firebaseConfigValidate.js');
 const config=local('./firebase.json');const validate=getValidator();
 assert.equal(validate(config),true,JSON.stringify(validate.errors));
});
