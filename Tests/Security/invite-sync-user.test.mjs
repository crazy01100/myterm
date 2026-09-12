import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, chmodSync, symlinkSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { invite, adminAPI, checkPolicy, emailAddress, validateConfig, configure, loadConfig, accessToken, gcloudEnvironment } from '../../scripts/invite-sync-user.mjs';

const config = { schemaVersion: 1, projectId: 'demo-myterm', adminEmail: 'owner@example.test', gcloudPath: '/unused/gcloud' };
const email = 'friend@example.test';
const policy = { name: 'projects/demo-myterm/config', client: { permissions: { disabledUserSignup: true } }, signIn: {} };
const user = { localId: 'synthetic-uid', email };
const response = (data, status = 200) => new Response(JSON.stringify(data), { status });
function scenario(sequence) {
  const calls = [];
  const api = adminAPI(config, 'synthetic-token-never-real', async (url, opts) => {
    calls.push({ url, ...opts, body: opts.body ? JSON.parse(opts.body) : undefined });
    assert.ok(sequence.length, 'unexpected API request');
    const next = sequence.shift();
    if (next instanceof Error) throw next;
    return next;
  });
  return { calls, run: (opts = {}) => invite({ config, email, api, ...opts }) };
}
const code = expected => e => e.code === expected;

test('create is email-only, bound to project, then verified by targeted lookup', async () => {
  const s = scenario([response(policy), response({}), response({ localId: user.localId }), response({ users: [user] })]);
  assert.deepEqual(await s.run(), { status: 'created', projectId: config.projectId, uid: user.localId, googleLinked: false });
  assert.deepEqual(s.calls.map(c => c.method), ['GET', 'POST', 'POST', 'POST']);
  assert.deepEqual(s.calls[2].body, { targetProjectId: 'demo-myterm', email, emailVerified: false, disabled: false });
  for (const c of [s.calls[1], s.calls[3]]) assert.deepEqual(c.body, { email: [email] });
  for (const c of s.calls) {
    assert.ok(c.url.startsWith('https://identitytoolkit.googleapis.com/'));
    assert.equal(c.redirect, 'error'); assert.ok(c.signal);
    assert.equal(c.headers['X-Goog-User-Project'], 'demo-myterm');
    assert.equal(c.url.includes(email), false);
  }
});
test('existing Google identity is a no-op with no sensitive profile in output', async () => {
  const linked = { ...user, providerUserInfo: [{ providerId: 'google.com', rawId: 'synthetic-sub', email }], displayName: 'private-name', validSince: '0' };
  const s = scenario([response(policy), response({ users: [linked] })]);
  const result = await s.run();
  assert.equal(result.status, 'existing'); assert.equal(result.googleLinked, true); assert.equal(s.calls.length, 2);
  assert.ok(!JSON.stringify(result).includes(email)); assert.ok(!JSON.stringify(result).includes('private-name'));
});
test('dry-run never sends create, including an empty users array', async () => {
  const s = scenario([response(policy), response({ users: [] })]);
  assert.equal((await s.run({ dryRun: true })).status, 'would-create'); assert.equal(s.calls.length, 2);
});
test('canonical project number is verified against the bound project ID', async () => {
  const s = scenario([response({ ...policy, name: 'projects/123456789/config' }),
    response({ projectId: config.projectId, name: 'projects/123456789', state: 'ACTIVE' }), response({})]);
  assert.equal((await s.run({ dryRun: true })).status, 'would-create');
  assert.equal(s.calls[1].url, 'https://cloudresourcemanager.googleapis.com/v3/projects/demo-myterm');
  assert.equal(s.calls[1].method, 'GET'); assert.equal(s.calls[1].body, undefined);
});
for (const [name, metadata] of [
  ['unrelated number', { projectId: config.projectId, name: 'projects/987654321', state: 'ACTIVE' }],
  ['unrelated ID', { projectId: 'another-project', name: 'projects/123456789', state: 'ACTIVE' }],
  ['inactive project', { projectId: config.projectId, name: 'projects/123456789', state: 'DELETE_REQUESTED' }],
  ['missing metadata', {}],
]) test(`reject canonical identity with ${name}`, async () => {
  const s = scenario([response({ ...policy, name: 'projects/123456789/config' }), response(metadata)]);
  await assert.rejects(s.run(), code('PROJECT')); assert.equal(s.calls.length, 2);
});
test('canonical project lookup permission failure never reaches account lookup', async () => {
  const s = scenario([response({ ...policy, name: 'projects/123456789/config' }), response({}, 403)]);
  await assert.rejects(s.run(), code('HTTP')); assert.equal(s.calls.length, 2);
});
for (const [name, change, expected] of [
  ['wrong project', { name: 'projects/another-project/config' }, 'PROJECT'],
  ['signup enabled', { client: { permissions: { disabledUserSignup: false } } }, 'POLICY'],
  ['missing restriction', { client: {} }, 'POLICY'],
  ['duplicate emails', { signIn: { allowDuplicateEmails: true } }, 'POLICY'],
  ['malformed boolean', { signIn: { allowDuplicateEmails: 'false' } }, 'POLICY'],
  ['missing sign-in config', { signIn: null }, 'POLICY'],
]) test(`reject ${name} before looking up anyone`, async () => {
  const s = scenario([response({ ...policy, ...change })]);
  await assert.rejects(s.run(), code(expected)); assert.equal(s.calls.length, 1);
});
for (const [name, fields] of [
  ['disabled', { disabled: true }], ['password', { passwordHash: 'secret-hash' }],
  ['phone identity', { phoneNumber: '+15555555555' }], ['custom claims', { customAttributes: '{}' }],
  ['other provider', { providerUserInfo: [{ providerId: 'github.com', rawId: '123' }] }],
  ['provider email mismatch', { providerUserInfo: [{ providerId: 'google.com', rawId: '123', email: 'other@example.test' }] }],
  ['missing Google subject', { providerUserInfo: [{ providerId: 'google.com' }] }],
  ['tenant', { tenantId: 'other' }],
]) test(`stop for ${name} without modifying identity`, async () => {
  const s = scenario([response(policy), response({ users: [{ ...user, ...fields }] })]);
  await assert.rejects(s.run(), code('CONFLICT')); assert.equal(s.calls.length, 2);
});
for (const status of [400, 401, 403, 404, 429, 500, 503]) test(`lookup HTTP ${status} is never absence`, async () => {
  const s = scenario([response(policy), response({ error: { message: 'SECRET server body friend@example.test' } }, status)]);
  await assert.rejects(s.run(), e => e.code === 'HTTP' && !e.message.includes('SECRET') && !e.message.includes(email));
  assert.equal(s.calls.length, 2);
});
test('network failure is not absence', async () => {
  const s = scenario([response(policy), new Error('SECRET transport')]);
  await assert.rejects(s.run(), e => e.code === 'NETWORK' && !e.message.includes('SECRET')); assert.equal(s.calls.length, 2);
});
for (const body of [null, [], { error: 'oops' }, { unexpected: true }, { users: [user, user] }, { users: [{ ...user, email: 'wrong@example.test' }] }]) {
  test(`malformed/ambiguous lookup ${JSON.stringify(body)}`, async () => {
    const s = scenario([response(policy), response(body)]);
    await assert.rejects(s.run()); assert.equal(s.calls.length, 2);
  });
}
test('exact EMAIL_EXISTS collision safely rechecks without retrying create', async () => {
  const s = scenario([response(policy), response({}), response({ error: { message: 'EMAIL_EXISTS' } }, 400), response({ users: [user] })]);
  assert.equal((await s.run()).status, 'existing'); assert.equal(s.calls.length, 4);
});
test('collision followed by disabled user stops', async () => {
  const s = scenario([response(policy), response({}), response({ error: { message: 'EMAIL_EXISTS' } }, 400), response({ users: [{ ...user, disabled: true }] })]);
  await assert.rejects(s.run(), code('CONFLICT'));
});
test('create network failure is not retried', async () => {
  const s = scenario([response(policy), response({}), new Error('unknown outcome')]);
  await assert.rejects(s.run(), code('NETWORK')); assert.equal(s.calls.length, 3);
});
test('create with a mismatched read-back UID reports uncertain outcome', async () => {
  const s = scenario([response(policy), response({}), response({ localId: 'other-uid' }), response({ users: [user] })]);
  await assert.rejects(s.run(), code('CREATE_UNCERTAIN')); assert.equal(s.calls.length, 4);
});
test('read-back failure does not hide the possible completed creation', async () => {
  const s = scenario([response(policy), response({}), response({ localId: user.localId }), response({}, 503)]);
  await assert.rejects(s.run(), code('CREATE_UNCERTAIN'));
});
test('API enforces host/path and bounds response parsing', async () => {
  let called = false;
  const api = adminAPI(config, 'unused', async () => { called = true; return response(policy); });
  await assert.rejects(api('/v1/projects/other/accounts:lookup', {}), code('PROJECT')); assert.equal(called, false);
  await assert.rejects(api('/v3/projects/other'), code('PROJECT')); assert.equal(called, false);
  await assert.rejects(api('/v3/projects/demo-myterm', {}), code('PROJECT')); assert.equal(called, false);
  const huge = adminAPI(config, 'unused', async () => new Response('x'.repeat(256 * 1024 + 1)));
  await assert.rejects(checkPolicy(huge, config.projectId), code('RESPONSE'));
  const malformed = adminAPI(config, 'unused', async () => new Response('not json'));
  await assert.rejects(checkPolicy(malformed, config.projectId), code('RESPONSE'));
});
test('email input is single, unchanged, and rejects terminal/argument injection', () => {
  assert.equal(emailAddress('First.Last+tag@gmail.com'), 'First.Last+tag@gmail.com');
  for (const bad of ['Name <friend@gmail.com>', ' x@gmail.com', 'a@gmail.com\nb@gmail.com', '--help', 'a..b@gmail.com', 'x@x', 'x@-gmail.com', 'a@gmail.com\u001b[31m']) assert.throws(() => emailAddress(bad), code('EMAIL'));
  assert.throws(() => validateConfig({ ...config, projectId: '../escape' }), code('CONFIG'));
  assert.throws(() => validateConfig({ ...config, apiKey: 'not-admin-auth' }), code('CONFIG'));
});
function tempConfig(t) {
  const root = mkdtempSync(join(tmpdir(), 'myterm-invite-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const bin = join(root, 'gcloud'); writeFileSync(bin, '#!/bin/sh\nexit 0\n', { mode: 0o700 });
  configure(config.projectId, config.adminEmail, bin, root);
  return { root, c: loadConfig(root) };
}
test('configuration is exclusive, private and rejects permission drift', t => {
  const { root, c } = tempConfig(t);
  assert.equal(c.projectId, config.projectId);
  assert.throws(() => configure(c.projectId, c.adminEmail, c.gcloudPath, root), code('CONFIG'));
  chmodSync(join(root, 'Config/Local/SyncAdmin/config.json'), 0o644);
  assert.throws(() => loadConfig(root), code('CONFIG'));
});
test('configuration rejects symbolic link redirection', t => {
  const { root } = tempConfig(t);
  const path = join(root, 'Config/Local/SyncAdmin/config.json');
  rmSync(path); symlinkSync('/etc/hosts', path);
  assert.throws(() => loadConfig(root), code('CONFIG'));
});
test('gcloud uses bound account/project and isolates environment and credentials', t => {
  const { root, c } = tempConfig(t);
  const token = accessToken(c, root, (bin, args, opts) => {
    assert.equal(bin, c.gcloudPath); assert.ok(args.includes(c.adminEmail)); assert.ok(args.includes(c.projectId));
    assert.equal(opts.env.CLOUDSDK_CONFIG, join(root, 'Config/Local/SyncAdmin/gcloud'));
    assert.deepEqual(opts.stdio, ['ignore', 'pipe', 'pipe']);
    assert.equal(args.includes('synthetic-test-access-token'), false);
    return 'synthetic-test-access-token\n';
  });
  assert.equal(token, 'synthetic-test-access-token');
  assert.throws(() => accessToken(c, root, () => { throw new Error('SECRET stdout/stderr'); }), e => e.code === 'AUTH' && !e.message.includes('SECRET'));
  assert.throws(() => accessToken(c, root, () => 'bad\ntoken'), code('AUTH'));
  const env = gcloudEnvironment(root, { HOME: '/home/example', CLOUDSDK_AUTH_ACCESS_TOKEN: 'secret', CLOUDSDK_API_ENDPOINT_OVERRIDES_IDENTITYTOOLKIT: 'https://evil.test', GOOGLE_APPLICATION_CREDENTIALS: '/secret', PYTHONPATH: '/evil' });
  assert.equal(env.HOME, '/home/example');
  for (const k of ['CLOUDSDK_AUTH_ACCESS_TOKEN', 'CLOUDSDK_API_ENDPOINT_OVERRIDES_IDENTITYTOOLKIT', 'GOOGLE_APPLICATION_CREDENTIALS', 'PYTHONPATH']) assert.equal(env[k], undefined);
});
test('help and rejected arguments require no cloud configuration or API calls', () => {
  const script = new URL('../../scripts/invite-sync-user.mjs', import.meta.url);
  const help = spawnSync(process.execPath, [script.pathname, '--help'], { encoding: 'utf8' });
  assert.equal(help.status, 0); assert.match(help.stdout, /--dry-run/);
  const bad = spawnSync(process.execPath, [script.pathname, '--delete', email], { encoding: 'utf8' });
  assert.equal(bad.status, 1); assert.match(bad.stderr, /USAGE/);
});
test('independent source export does not include this administrator entry or local settings', () => {
  const manifest = JSON.parse(readFileSync(new URL('../../PublicSource/export-manifest.json', import.meta.url)));
  assert.equal(manifest.files.some(f => /invite-sync-user|SyncAdmin|Config\/Local/.test(f.path)), false);
});
