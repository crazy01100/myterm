import { execFileSync, spawnSync } from 'node:child_process';
import { lstatSync, mkdirSync, readFileSync, writeFileSync, realpathSync } from 'node:fs';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// No third-party runtime dependencies, credential-file parsing, or Firebase CLI bypass.
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const ORIGIN = 'https://identitytoolkit.googleapis.com';
const MAX_BYTES = 256 * 1024;
const messages = {
  USAGE: '用法：invite-sync-user.sh [--dry-run] GOOGLE_EMAIL；首次設定請見 --help。',
  EMAIL: '請輸入單一 Google 帳號的主要 email；不接受顯示名稱、空白或別名推算。',
  CONFIG: '本機管理設定不存在、不安全或格式不符。請先完成 --configure。',
  AUTH: '無法取得管理員授權。請以綁定的管理帳號執行 --login，並確認權限。',
  POLICY: '專案不符合邀請模式：須關閉自行加入並使用單一 email 身分。未建立使用者。',
  PROJECT: '後端回傳的專案與本機綁定不符。已停止。',
  HTTP: 'Google 管理 API 拒絕要求。請確認管理權限、API 啟用狀態與配額。',
  NETWORK: '連線失敗或逾時；若發生於建立期間，結果可能已生效。請先以 --dry-run 查核。',
  RESPONSE: 'Google 回應不符合預期；若已送出建立要求，請以 --dry-run 查核，勿假設未生效。',
  CONFLICT: '帳號已停用或身分有衝突。未覆蓋或重新啟用，請人工核對。',
  CREATE_UNCERTAIN: '建立要求已送出，但尚未完成回讀核對。請以 --dry-run 查核；不自動重送。',
};
export class InviteError extends Error {
  constructor(code) { super(messages[code] ?? messages.RESPONSE); this.code = code; }
}
const fail = code => { throw new InviteError(code); };
const object = x => x !== null && typeof x === 'object' && !Array.isArray(x);
export function emailAddress(value) {
  // Preserve the supplied primary address; do not strip dots/+suffixes or rewrite domains.
  if (typeof value !== 'string' || value.length > 254 || !/^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$/.test(value)) fail('EMAIL');
  return value;
}
export function validateConfig(c) {
  if (!object(c) || c.schemaVersion !== 1 || Object.keys(c).sort().join() !== 'adminEmail,gcloudPath,projectId,schemaVersion' ||
      !/^[a-z][a-z0-9-]{4,28}[a-z0-9]$/.test(c.projectId ?? '') ||
      typeof c.gcloudPath !== 'string' || !isAbsolute(c.gcloudPath)) fail('CONFIG');
  emailAddress(c.adminEmail);
  return c;
}
function privatePath(path, directory = false) {
  const st = lstatSync(path);
  if (st.isSymbolicLink() || (directory ? !st.isDirectory() : !st.isFile()) ||
      (st.mode & 0o077) || st.uid !== process.getuid()) fail('CONFIG');
  return st;
}
function localDirectory(root, create = false) {
  const local = join(root, 'Config/Local');
  if (create) mkdirSync(local, { recursive: true, mode: 0o700 });
  // Existing Config/Local may contain other app settings, but may not redirect elsewhere.
  if (lstatSync(local).isSymbolicLink() || realpathSync(local) !== join(realpathSync(root), 'Config/Local')) fail('CONFIG');
  const dir = join(local, 'SyncAdmin');
  if (create) mkdirSync(dir, { mode: 0o700, recursive: true });
  privatePath(dir, true);
  return dir;
}
export function loadConfig(root = ROOT) {
  try {
    const path = join(localDirectory(root), 'config.json');
    if (privatePath(path).size > 4096) fail('CONFIG');
    return validateConfig(JSON.parse(readFileSync(path, 'utf8')));
  } catch { fail('CONFIG'); }
}
export function configure(projectId, adminEmail, gcloudPath, root = ROOT) {
  const c = validateConfig({ schemaVersion: 1, projectId, adminEmail, gcloudPath });
  try {
    if (!lstatSync(gcloudPath).isFile()) fail('CONFIG');
    const dir = localDirectory(root, true);
    // Exclusive creation: changing a bound project requires deliberate local review.
    writeFileSync(join(dir, 'config.json'), JSON.stringify(c, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
  } catch { fail('CONFIG'); }
}
export function gcloudEnvironment(root = ROOT, source = process.env) {
  // Do not inherit endpoint overrides, impersonation, token files, or HTTP debug settings.
  const env = {};
  for (const k of ['HOME', 'PATH', 'TMPDIR', 'LANG', 'LC_ALL']) if (source[k]) env[k] = source[k];
  return { ...env, CLOUDSDK_CONFIG: join(root, 'Config/Local/SyncAdmin/gcloud'),
    CLOUDSDK_PYTHON: join(root, 'scripts/project-python.sh'),
    CLOUDSDK_CORE_DISABLE_USAGE_REPORTING: 'true', CLOUDSDK_CORE_DISABLE_FILE_LOGGING: 'true' };
}
function authDirectory(root) {
  const dir = join(localDirectory(root), 'gcloud');
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  privatePath(dir, true);
}
export function accessToken(c, root = ROOT, execute = execFileSync) {
  try {
    authDirectory(root);
    const token = execute(c.gcloudPath, ['auth', 'print-access-token', c.adminEmail,
      '--project', c.projectId, '--quiet', '--verbosity=none'], {
      env: gcloudEnvironment(root), encoding: 'utf8', timeout: 60000,
      maxBuffer: 32768, stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
    if (!/^[A-Za-z0-9._~+\/-]{20,16384}={0,2}$/.test(token)) fail('AUTH');
    return token;
  } catch { fail('AUTH'); }
}
export function adminAPI(c, token, fetcher = fetch) {
  validateConfig(c);
  return async (path, body) => {
    // All endpoints are constructed internally; no environment-selected host/emulator.
    const allowed = new Set([`/admin/v2/projects/${c.projectId}/config`,
      `/v1/projects/${c.projectId}/accounts:lookup`, '/v1/accounts:signUp', `/v3/projects/${c.projectId}`]);
    if (!allowed.has(path)) fail('PROJECT');
    const projectMetadata = path === `/v3/projects/${c.projectId}`;
    if (projectMetadata && body !== undefined) fail('PROJECT');
    let response, data;
    try {
      response = await fetcher((projectMetadata ? 'https://cloudresourcemanager.googleapis.com' : ORIGIN) + path, { method: body === undefined ? 'GET' : 'POST',
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'X-Goog-User-Project': c.projectId },
        body: body === undefined ? undefined : JSON.stringify(body),
        redirect: 'error', signal: AbortSignal.timeout(30000) });
      const reader = response.body.getReader();
      const chunks = []; let size = 0;
      try {
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          size += value.byteLength;
          if (size > MAX_BYTES) fail('RESPONSE');
          chunks.push(Buffer.from(value));
        }
      } finally { await reader.cancel(); }
      data = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    } catch (e) {
      if (e instanceof InviteError) throw e;
      fail(e instanceof SyntaxError ? 'RESPONSE' : 'NETWORK');
    }
    if (!object(data)) fail('RESPONSE');
    if (!response.ok) {
      // The only recoverable API error is an exact concurrent-create collision.
      if (path === '/v1/accounts:signUp' && response.status === 400 && data.error?.message === 'EMAIL_EXISTS') {
        const e = new InviteError('CONFLICT'); e.emailExists = true; throw e;
      }
      fail('HTTP');
    }
    if (data.error !== undefined) fail('RESPONSE');
    return data;
  };
}
export async function checkPolicy(api, projectId) {
  const c = await api(`/admin/v2/projects/${projectId}/config`);
  if (c.name !== `projects/${projectId}/config`) {
    // Firebase canonicalizes resource names to project numbers. Resolve only the
    // locally bound ID; never trust an arbitrary number merely because it is numeric.
    if (typeof c.name !== 'string' || !/^projects\/[1-9][0-9]*\/config$/.test(c.name)) fail('PROJECT');
    const project = await api(`/v3/projects/${projectId}`);
    if (project.projectId !== projectId || project.state !== 'ACTIVE' ||
        `${project.name}/config` !== c.name) fail('PROJECT');
  }
  // Proto JSON may omit false booleans; missing signup restriction never passes.
  if (c.client?.permissions?.disabledUserSignup !== true || !object(c.signIn) ||
      ![undefined, false].includes(c.signIn.allowDuplicateEmails)) fail('POLICY');
}
function checkedUser(u, email) {
  if (!object(u) || typeof u.localId !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(u.localId) ||
      typeof u.email !== 'string' || u.email.toLowerCase() !== email.toLowerCase()) fail('RESPONSE');
  if (![undefined, false].includes(u.disabled) || u.passwordHash || u.phoneNumber || u.customAttributes || u.tenantId) fail('CONFLICT');
  const providers = u.providerUserInfo ?? [];
  if (!Array.isArray(providers) || providers.some(p => !object(p) || p.providerId !== 'google.com' ||
      typeof p.rawId !== 'string' || !p.rawId || (p.email && p.email.toLowerCase() !== email.toLowerCase()))) fail('CONFLICT');
  return { uid: u.localId, googleLinked: providers.length > 0 };
}
async function lookup(api, projectId, email) {
  const data = await api(`/v1/projects/${projectId}/accounts:lookup`, { email: [email] });
  // Official lookup returns an omitted users field (or empty array) for no match.
  if (data.users === undefined && Object.keys(data).some(k => k !== 'kind')) fail('RESPONSE');
  const users = data.users ?? [];
  if (!Array.isArray(users) || users.length > 1) fail('CONFLICT');
  return users.length ? checkedUser(users[0], email) : null;
}
export async function invite({ config, email, dryRun = false, api }) {
  validateConfig(config); emailAddress(email);
  const { projectId } = config;
  await checkPolicy(api, projectId);
  const existing = await lookup(api, projectId, email);
  if (existing) return { status: 'existing', projectId, ...existing };
  if (dryRun) return { status: 'would-create', projectId };
  let created;
  try {
    created = await api('/v1/accounts:signUp', { targetProjectId: projectId, email, emailVerified: false, disabled: false });
  } catch (e) {
    if (!e.emailExists) throw e;
    const concurrent = await lookup(api, projectId, email);
    if (!concurrent) fail('CONFLICT');
    return { status: 'existing', projectId, ...concurrent };
  }
  try {
    const user = await lookup(api, projectId, email);
    if (!user || user.uid !== created.localId) fail('CREATE_UNCERTAIN');
    return { status: 'created', projectId, ...user };
  } catch { fail('CREATE_UNCERTAIN'); }
}
export async function main(args, root = ROOT) {
  if (args.length === 1 && args[0] === '--help') {
    console.log('首次：--configure PROJECT_ID ADMIN_EMAIL /absolute/path/to/gcloud\n登入：--login（由本人完成 Google 驗證）\n檢查管理設定：--check（不查詢使用者）\n邀請：[--dry-run] GOOGLE_EMAIL\n詳細私人操作指南：docs/CLOUD_SYNC_INVITATION_GUIDE.md'); return;
  }
  if (args.length === 4 && args[0] === '--configure') {
    configure(...args.slice(1), root); console.log('本機綁定已建立。下一步：--login。'); return;
  }
  const login = args.length === 1 && args[0] === '--login';
  const check = args.length === 1 && args[0] === '--check';
  const dryRun = args.length === 2 && args[0] === '--dry-run';
  const email = dryRun ? args[1] : args[0];
  if (!login && !check && !dryRun && (args.length !== 1 || email?.startsWith('-'))) fail('USAGE');
  if (!login && !check) emailAddress(email);
  const c = loadConfig(root);
  if (login) {
    authDirectory(root);
    console.log('Google Cloud CLI 的標準 OAuth 授權涵蓋廣泛雲端管理權限（含 Cloud Platform、App Engine、SQL、Compute 與重新驗證），並非僅限此工具的 Firebase 操作；請本人審閱同意頁。實際存取仍受既有 IAM 限制，工具不新增角色。');
    const result = spawnSync(c.gcloudPath, ['auth', 'login', c.adminEmail, '--force', '--brief', '--project', c.projectId],
      { env: gcloudEnvironment(root), stdio: 'inherit' });
    if (result.status !== 0) fail('AUTH');
    console.log('管理員登入完成。請執行 --check 驗證專案設定。'); return;
  }
  const api = adminAPI(c, accessToken(c, root));
  if (check) { await checkPolicy(api, c.projectId); console.log('管理員讀取與邀請模式檢查通過；尚未驗證建立權限或朋友登入。'); return; }
  const result = await invite({ config: c, email, dryRun, api });
  console.log(JSON.stringify(result));
  console.log('以上只代表後端身分狀態；朋友仍需自行完成 Google 登入與同步測試。未傳送通知。');
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch(e => {
    console.error(e instanceof InviteError ? `[${e.code}] ${e.message}` : '[INTERNAL] 管理工具未完成；請勿將原始錯誤或憑證貼入公開紀錄。');
    process.exitCode = 1;
  });
}
