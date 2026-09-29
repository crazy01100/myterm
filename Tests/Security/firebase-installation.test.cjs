const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {verify} = require('../../scripts/verify-firebase-tools.cjs');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'myterm-firebase-install-'));
  t.after(() => fs.rmSync(root, {recursive:true, force:true}));
  const write = (file, value) => { const p=path.join(root,file);fs.mkdirSync(path.dirname(p),{recursive:true});fs.writeFileSync(p,JSON.stringify(value)); };
  const manifest = {devDependencies:{'firebase-tools':'15.31.0'}};
  const lock = {packages:{'':manifest}};
  write('package.json',manifest);
  for(const [name,version] of Object.entries({'firebase-tools':'15.31.0','stream-json':'3.6.0','stream-chain':'4.2.5','csv-parse':'7.0.2'})) {
    write('node_modules/'+name+'/package.json',{name,version,main:'index.js'});
    fs.writeFileSync(path.join(root,'node_modules',name,'index.js'),'throw Error("must not execute package code");');
    lock.packages['node_modules/'+name]={version};
  }
  write('package-lock.json',lock);
  return {root,write,manifest,lock};
}
test('read-only check accepts a complete locked installation without executing packages',t=>{
  const {root}=fixture(t);assert.doesNotThrow(()=>verify(root));
});
test('stale CLI is rejected',t=>{
  const {root,write}=fixture(t);write('node_modules/firebase-tools/package.json',{name:'firebase-tools',version:'15.30.2',main:'index.js'});
  assert.throws(()=>verify(root),/differs from lockfile/);
});
test('missing consumer dependency is rejected',t=>{
  const {root}=fixture(t);fs.rmSync(path.join(root,'node_modules/stream-json'),{recursive:true});assert.throws(()=>verify(root));
});
test('manifest and lockfile mismatch is rejected',t=>{
  const {root,write,manifest}=fixture(t);manifest.devDependencies['firebase-tools']='15.32.0';write('package.json',manifest);assert.throws(()=>verify(root),/matching manifest/);
});
test('unlocked nested dependency cannot shadow the reviewed dependency',t=>{
  const {root,write}=fixture(t);const p='node_modules/firebase-tools/node_modules/stream-json';
  write(p+'/package.json',{name:'stream-json',version:'1.9.1',main:'index.js'});fs.writeFileSync(path.join(root,p,'index.js'),'');
  assert.throws(()=>verify(root),/differs from lockfile/);
});
