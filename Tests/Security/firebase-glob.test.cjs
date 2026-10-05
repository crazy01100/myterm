const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {createRequire}=require('node:module');
const {once}=require('node:events');
const local=createRequire(path.resolve(__dirname,'../../package.json'));
const cli=createRequire(local.resolve('firebase-tools/package.json'));
function fixture(t){
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'myterm-glob-'));
 t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
 for(const file of ['main.js','sub/nested.js','sub/schema.gql','sub/schema.graphql','.hidden','firebase-debug.log','sub/firebase-debug.1.log','.firebase/cache','ignored/secret.txt']){
  fs.mkdirSync(path.dirname(path.join(dir,file)),{recursive:true});fs.writeFileSync(path.join(dir,file),'fixture');
 }
 fs.symlinkSync('sub',path.join(dir,'linked'),'dir');return dir;
}
test('Firebase listFiles preserves exclusions, dotfiles and symlink traversal',t=>{
 const dir=fixture(t);const files=cli('./lib/listFiles.js').listFiles(dir,['ignored/**']).sort();
 assert.deepEqual(files,['.hidden','linked/nested.js','linked/schema.gql','linked/schema.graphql','main.js','sub/nested.js','sub/schema.gql','sub/schema.graphql'].sort());
});
test('glob sync, async and stream preserve Data Connect style brace patterns',async t=>{
 const dir=fixture(t);const glob=cli('glob');const options={cwd:dir,absolute:true,nodir:true,follow:false};
 const expected=['sub/schema.gql','sub/schema.graphql'].map(f=>path.join(dir,f)).sort();
 const pattern='**/*.{gql,graphql}';
 assert.deepEqual(glob.sync(pattern,options).sort(),expected);
 assert.deepEqual((await glob.glob(pattern,options)).sort(),expected);
 const streamed=[];for await(const file of glob.globStream(pattern,options))streamed.push(file);
 assert.deepEqual(streamed.sort(),expected);
});
test('archiver file expansion and real zip contents retain filtering',async t=>{
 const dir=fixture(t);const archiver=cli('archiver');
 const ar=createRequire(cli.resolve('archiver'));const utils=ar('archiver-utils');
 assert.deepEqual(utils.file.expand({cwd:dir},['**/*.js','!sub/**']).sort(),['main.js']);
 const zip=archiver('zip',{zlib:{level:0}});const chunks=[];zip.on('data',c=>chunks.push(c));const ended=once(zip,'end');
 zip.glob('**/*.js',{cwd:dir,ignore:['sub/**','linked/**']});await zip.finalize();await ended;
 const bytes=Buffer.concat(chunks);assert.equal(bytes.readUInt32LE(0),0x04034b50);assert.ok(bytes.includes(Buffer.from('main.js')));assert.ok(!bytes.includes(Buffer.from('nested.js')));
});
test('rimraf glob only removes matching files in an isolated fixture',async t=>{
 const dir=fixture(t);const gax=createRequire(cli.resolve('google-gax'));const {rimraf}=gax('rimraf');
 await rimraf(path.join(dir,'sub','*.js'),{glob:true});
 assert.equal(fs.existsSync(path.join(dir,'sub/nested.js')),false);assert.equal(fs.existsSync(path.join(dir,'sub/schema.gql')),true);assert.equal(fs.existsSync(path.join(dir,'main.js')),true);
});
test('exegesis controller loader retains nested aliases',t=>{
 const dir=fixture(t);const ex=createRequire(cli.resolve('exegesis'));
 const {loadControllersSync}=ex('./controllers/loadControllers.js');
 const controllers=loadControllersSync(dir,'sub/*.js',file=>({file}));
 assert.equal(controllers['sub/nested'].file,path.join(dir,'sub/nested.js'));assert.equal(controllers['sub/nested.js'],controllers['sub/nested']);
});
test('Firestore-style literal Rules watcher still reloads after file edits',{timeout:8000},async t=>{
 const dir=fixture(t);const file=path.join(dir,'規則 (local).rules');fs.writeFileSync(file,'first');
 const watcher=cli('chokidar').watch(file,{persistent:true,ignoreInitial:true});t.after(()=>watcher.close());
 await once(watcher,'ready');const changed=once(watcher,'change');fs.writeFileSync(file,'second');
 const [updated]=await changed;assert.equal(updated,file);assert.equal(fs.readFileSync(updated,'utf8'),'second');
});
