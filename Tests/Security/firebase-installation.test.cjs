const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {verify} = require('../../scripts/verify-firebase-tools.cjs');

function fixture(t, {prepared = true} = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'myterm-firebase-install-'));
  t.after(() => fs.rmSync(root, {recursive:true, force:true}));
  const write = (file, value) => { const p=path.join(root,file);fs.mkdirSync(path.dirname(p),{recursive:true});fs.writeFileSync(p,JSON.stringify(value)); };
  const manifest = {devDependencies:{'firebase-tools':'15.35.0','@firebase/rules-unit-testing':'6.0.0'}};
  const lock = {packages:{'':manifest}};
  write('package.json',manifest);
  for(const [name,version] of Object.entries({'firebase-tools':'15.35.0','@firebase/rules-unit-testing':'6.0.0','stream-json':'3.6.0','stream-chain':'4.2.5','csv-parse':'7.0.2','superstatic':'10.0.0','minimatch':'11.0.4'})) {
    const peerDependencies = name === '@firebase/rules-unit-testing' ? {firebase:'^13.0.0'} : undefined;
    write('node_modules/'+name+'/package.json',{name,version,main:'index.js',peerDependencies});
    fs.writeFileSync(path.join(root,'node_modules',name,'index.js'),'throw Error("must not execute package code");');
    lock.packages['node_modules/'+name]={version,peerDependencies};
  }
  write('package-lock.json',lock);
  const sources = ['firebase-tools/lib/fsAsync.js', 'superstatic/lib/utils/patterns.js'].map(name => {
    const relative = path.join('node_modules', name);
    const file = path.join(root, relative);
    const installed = fs.readFileSync(path.resolve(__dirname, '../..', relative), 'utf8');
    const upstream = 'const minimatch = require("minimatch");';
    const patched = 'const { minimatch } = require("minimatch");';
    fs.mkdirSync(path.dirname(file), {recursive: true});
    fs.writeFileSync(file, prepared ? installed.replace(upstream, patched) : installed.replace(patched, upstream));
    return file;
  });
  return {root,write,manifest,lock,sources};
}
test('only explicit preparation applies the reviewed imports and retries are idempotent', t => {
  const {root, sources} = fixture(t, {prepared: false});
  const before = sources.map(file => fs.readFileSync(file, 'utf8'));
  assert.throws(() => verify(root), /--apply-minimatch/);
  assert.deepEqual(sources.map(file => fs.readFileSync(file, 'utf8')), before);
  verify(root, {applyMinimatch: true});
  verify(root);
  const prepared = sources.map(file => fs.readFileSync(file, 'utf8'));
  fs.writeFileSync(sources[1], before[1]); // interrupted after the first file
  verify(root, {applyMinimatch: true});
  verify(root, {applyMinimatch: true});
  assert.deepEqual(sources.map(file => fs.readFileSync(file, 'utf8')), prepared);
});
test('drift in either consumer stops preparation before writing the first file', t => {
  const {root, sources} = fixture(t, {prepared: false});
  const before = fs.readFileSync(sources[0]);
  fs.appendFileSync(sources[1], '// unexpected change');
  assert.throws(() => verify(root, {applyMinimatch: true}), /Unreviewed minimatch import/);
  assert.deepEqual(fs.readFileSync(sources[0]), before);
});
test('preparation refuses redirected source files even if the target bytes match', t => {
  const {root, sources} = fixture(t, {prepared: false});
  const target = path.join(root, 'redirected.js');
  fs.renameSync(sources[1], target);
  fs.symlinkSync(target, sources[1]);
  const before = fs.readFileSync(target);
  assert.throws(() => verify(root, {applyMinimatch: true}), /Unexpected Firebase import path/);
  assert.deepEqual(fs.readFileSync(target), before);
});
test('a different locked matcher version requires review before preparation', t => {
  const {root, write, lock} = fixture(t, {prepared: false});
  const dir = 'node_modules/minimatch';
  write(dir + '/package.json', {name: 'minimatch', version: '11.0.1', main: 'index.js'});
  lock.packages[dir].version = '11.0.1';
  write('package-lock.json', lock);
  assert.throws(() => verify(root, {applyMinimatch: true}), /Unreviewed minimatch or consumer version/);
});
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

test('stale locked Rules peer metadata is rejected without loading package code',t=>{
  const {root,write,lock}=fixture(t);
  lock.packages['node_modules/@firebase/rules-unit-testing'].peerDependencies.firebase='13.0.0';
  write('package-lock.json',lock);
  assert.throws(()=>verify(root),/peer requirements differ/);
});
test('missing locked Rules peer metadata is rejected',t=>{
  const {root,write,lock}=fixture(t);
  delete lock.packages['node_modules/@firebase/rules-unit-testing'].peerDependencies;
  write('package-lock.json',lock);
  assert.throws(()=>verify(root),/peer requirements differ/);
});
