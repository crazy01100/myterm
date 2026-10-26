#!/usr/bin/env node
// Read-only installation consistency check. npm ci verifies archive integrity;
// advisory scanning and consumer tests remain separate required CI checks.
const fs = require('node:fs');
const path = require('node:path');
const {createRequire} = require('node:module');

function verify(root = path.resolve(__dirname, '..')) {
  root = fs.realpathSync(root);
  const read = file => JSON.parse(fs.readFileSync(file, 'utf8'));
  const manifest = read(path.join(root, 'package.json'));
  const lock = read(path.join(root, 'package-lock.json'));
  const pinned = manifest.devDependencies['firebase-tools'];
  if (!/^\d+\.\d+\.\d+$/.test(pinned) || lock.packages[''].devDependencies['firebase-tools'] !== pinned) {
    throw Error('Firebase CLI must have an exact matching manifest/lockfile version');
  }
  function checkedPackage(resolver, name) {
    let dir = path.dirname(resolver.resolve(name));
    while (dir !== path.dirname(dir)) {
      const file = path.join(dir, 'package.json');
      if (fs.existsSync(file) && read(file).name === name) {
        const installed = read(file);
        const relative = path.relative(root, dir).split(path.sep).join('/');
        const expected = lock.packages[relative];
        if (!relative.startsWith('node_modules/') || !expected || installed.version !== expected.version) {
          throw Error(name + ': installation differs from lockfile; run npm ci');
        }
        const peers = value => Object.entries(value || {}).sort(([a], [b]) => a.localeCompare(b));
        if (JSON.stringify(peers(installed.peerDependencies)) !== JSON.stringify(peers(expected.peerDependencies))) {
          throw Error(name + ': peer requirements differ from the installed official package');
        }
        return {file, version: installed.version};
      }
      dir = path.dirname(dir);
    }
    throw Error(name + ': package metadata not found');
  }
  const cli = checkedPackage(createRequire(path.join(root, 'package.json')), 'firebase-tools');
  if (cli.version !== pinned) throw Error('Firebase CLI installation differs from manifest');
  const rules = checkedPackage(createRequire(path.join(root, 'package.json')), '@firebase/rules-unit-testing');
  if (rules.version !== manifest.devDependencies['@firebase/rules-unit-testing'] ||
      rules.version !== lock.packages[''].devDependencies['@firebase/rules-unit-testing']) {
    throw Error('Firebase Rules test version differs from manifest/lockfile');
  }
  const resolver = createRequire(cli.file);
  for (const name of ['stream-json', 'stream-chain', 'csv-parse']) checkedPackage(resolver, name);
}

module.exports = {verify};
if (require.main === module) {
  try { verify(); console.log('Firebase tool installation matches the lockfile.'); }
  catch (error) { console.error('Firebase installation verification failed: ' + error.message); process.exitCode = 1; }
}
