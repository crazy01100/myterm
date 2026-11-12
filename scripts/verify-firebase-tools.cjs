#!/usr/bin/env node
// Read-only unless installation explicitly requests the two reviewed imports.
const fs = require('node:fs');
const path = require('node:path');
const {hash, randomUUID} = require('node:crypto');
const {createRequire} = require('node:module');

const minimatchImports = [
  {name: 'firebase-tools', version: '15.36.0', source: 'lib/fsAsync.js',
   upstream: '0b883e0ebe5d65cbfd550c7fb3f489f18f46e19ea7e51d37fd9dfc1c712bf183',
   prepared: '664d53bdc43ac812265dd6c443ff285667b332a469e40853a6da911b0046c11a'},
  {name: 'superstatic', version: '10.0.0', source: 'lib/utils/patterns.js',
   upstream: '072c6a97a1979527cfb5bbbbe4e86c94d3a822105de529ee924fb9b6540c65c3',
   prepared: 'cde84d89fc51e6c50540a8c9c43e4071fc5150afb38907d063bbfd997d13835c'},
];

function verify(root = path.resolve(__dirname, '..'), {applyMinimatch = false} = {}) {
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

  // Validate both consumers before writing either. A retry also accepts an
  // already prepared file after an interrupted installation.
  const pending = [];
  for (const spec of minimatchImports) {
    const consumer = spec.name === 'firebase-tools' ? cli : checkedPackage(resolver, spec.name);
    const file = path.join(path.dirname(consumer.file), spec.source);
    if (fs.realpathSync(file) !== file || !fs.statSync(file).isFile()) {
      throw Error('Unexpected Firebase import path: ' + file);
    }
    const matcher = checkedPackage(createRequire(file), 'minimatch');
    if (consumer.version !== spec.version || matcher.version !== '11.0.4') {
      throw Error('Unreviewed minimatch or consumer version for ' + spec.name);
    }
    const bytes = fs.readFileSync(file);
    const digest = hash('sha256', bytes);
    if (digest === spec.prepared) continue;
    if (digest !== spec.upstream) throw Error('Unreviewed minimatch import in ' + spec.name);
    if (!applyMinimatch) throw Error('Run scripts/verify-firebase-tools.cjs --apply-minimatch with project Node after npm ci');
    const updated = bytes.toString('utf8').replace('const minimatch = require("minimatch");',
                                                'const { minimatch } = require("minimatch");');
    if (hash('sha256', updated) !== spec.prepared) throw Error('Unexpected result for ' + spec.name);
    pending.push({file, updated});
  }
  for (const {file, updated} of pending) {
    const temp = file + '.' + randomUUID() + '.tmp';
    try {
      fs.writeFileSync(temp, updated, {flag: 'wx', mode: fs.statSync(file).mode & 0o777});
      fs.renameSync(temp, file);
    } finally {
      fs.rmSync(temp, {force: true});
    }
  }
}

module.exports = {verify};
if (require.main === module) {
  try {
    const args = process.argv.slice(2);
    if (args.length && (args.length !== 1 || args[0] !== '--apply-minimatch')) {
      throw Error('Expected no arguments or --apply-minimatch');
    }
    verify(undefined, {applyMinimatch: args.length === 1});
    console.log('Firebase tool installation and minimatch imports verified.');
  }
  catch (error) { console.error('Firebase installation verification failed: ' + error.message); process.exitCode = 1; }
}
