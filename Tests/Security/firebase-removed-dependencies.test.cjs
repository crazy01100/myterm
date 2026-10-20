const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {createRequire} = require('node:module');
const root = path.resolve(__dirname, '../..');
const read = file => JSON.parse(fs.readFileSync(path.join(root, file), 'utf8'));
const local = createRequire(path.join(root, 'package.json'));
const cliFile = local.resolve('firebase-tools/package.json');
const cli = createRequire(cliFile);
const removed = [
  '@apphosting/common', 'universal-analytics', 'proxy-agent',
  'pac-proxy-agent', 'pac-resolver', 'get-uri', 'basic-ftp',
  'socks-proxy-agent', 'socks', '@tootallnate/quickjs-emscripten',
];

test('retired proxy/FTP dependencies are absent from every lockfile level', () => {
  const packages = read('package-lock.json').packages;
  for (const [key, entry] of Object.entries(packages)) {
    const name = key.split('node_modules/').at(-1);
    assert.ok(!removed.includes(name), `Retired package returned: ${key}`);
    for (const field of ['dependencies', 'optionalDependencies', 'devDependencies']) {
      for (const dependency of Object.keys(entry[field] || {})) {
        assert.ok(!removed.includes(dependency), `${key || 'root'} reintroduces ${dependency}`);
      }
    }
  }
});

test('clean Firebase installation cannot resolve the retired dependency chain', () => {
  for (const name of removed) {
    for (const resolver of [local, cli]) {
      assert.throws(() => resolver.resolve(name), {code: 'MODULE_NOT_FOUND'}, name);
    }
  }
});

test('the retired FTP override is absent and upstream no longer declares these packages', () => {
  const manifest = read('package.json');
  assert.equal(Object.hasOwn(manifest.overrides, 'get-uri'), false);
  const upstream = JSON.parse(fs.readFileSync(cliFile, 'utf8'));
  for (const name of removed) {
    assert.equal(Object.hasOwn(upstream.dependencies || {}, name), false, name);
    assert.equal(Object.hasOwn(upstream.optionalDependencies || {}, name), false, name);
  }
});
