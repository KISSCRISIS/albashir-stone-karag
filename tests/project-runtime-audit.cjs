const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.join(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');

const csvSource = read('admin_dashboard.html').match(/function csvEscape\(value\) \{[\s\S]*?\n    \}/)[0];
const csv = vm.runInNewContext('(' + csvSource + ')');
for (const value of ['=1+1', '+cmd', '-cmd', '@SUM(A1)', ' \t=1+1']) {
  assert.equal(csv(value), "'" + value);
}
assert.equal(csv(-10), '-10');
assert.equal(csv('اسم الموظف'), 'اسم الموظف');
assert.equal(csv('a\rb'), '"a\rb"');
assert.equal(csv('a,"b"'), '"a,""b"""');

const registration = read('global-leadership.js').match(/function getRegistrationUrl\(\) \{[\s\S]*?\n  \}/)[0];
const link = vm.runInNewContext('(' + registration + ')()', {
  URL, window: { location: { href: 'https://staging.example/portal.html?next=anything' } }
});
assert.equal(link, 'https://staging.example/register.html');

async function workerRequest(url, { method = 'GET', mode = 'navigate', status = 200, quota = false, cacheControl = '' } = {}) {
  const listeners = {}, writes = [], waits = [], warnings = [];
  let response;
  const request = { url, method, mode };
  vm.runInNewContext(read('service-worker.js'), {
    URL, console: { warn: (...args) => warnings.push(args) },
    self: { location: { origin: 'https://app.example', href: 'https://app.example/service-worker.js' }, addEventListener: (type, fn) => { listeners[type] = fn; } },
    fetch: async () => ({ status, headers: { get: () => cacheControl }, clone() { return this; } }),
    caches: { open: async () => ({ put: async key => { if (quota) throw Error('quota'); writes.push(typeof key === 'string' ? key : key.url); } }) }
  });
  listeners.fetch({ request, respondWith: promise => { response = promise; }, waitUntil: promise => waits.push(promise) });
  if (response) await response;
  await Promise.all(waits);
  return { writes, warnings, intercepted: !!response };
}

(async () => {
  const uploadSource = read('register.html').match(/async function uploadEmployeePhoto\(employeeId\) \{[\s\S]*?\n  \}/)[0];
  for (const outcome of ['transport', 'denied', 'exception', 'ok']) {
    const warnings = [];
    const upload = vm.runInNewContext('(' + uploadSource + ')', {
      $: () => ({ files: [{ type: 'image/png', size: 68, name: 'test.png' }] }),
      ALLOWED_PHOTO_TYPES: ['image/png'], MAX_PHOTO_BYTES: 2097152,
      console: { warn: message => warnings.push(message) },
      supabaseClient: {
        storage: { from: () => ({ upload: async () => ({ error: null }) }) },
        rpc: async () => {
          if (outcome === 'exception') throw Error('network');
          return { error: outcome === 'transport' ? {} : null, data: { ok: outcome !== 'denied' } };
        }
      }
    });
    assert((await upload('SYNTHETIC')).startsWith('registrations/SYNTHETIC/'));
    assert.equal(warnings.length, outcome === 'ok' ? 0 : 1);
  }
  const identitySource = read('portal.html').match(/async function identityLogin\(event\)\{[\s\S]*?(?=\r?\n  async function adminLogin)/)[0];
  const button = { disabled: false }, roles = [];
  const login = vm.runInNewContext('(' + identitySource + ')', {
    $: id => ({ value: id === 'employeeId' ? 'SYNTHETIC' : '000000000001' }),
    client: { rpc: async () => ({ error: null, data: { ok: true, profile: {} } }) },
    go: role => roles.push(role), show: message => { throw Error(message); }
  });
  await login({ preventDefault() {}, submitter: null, currentTarget: { querySelector: () => button } });
  assert.deepEqual(roles, ['EMPLOYEE']);
  assert.equal(button.disabled, false);
  const page = await workerRequest('https://app.example/verify.html?token=RAW_QR&claim=SECRET');
  assert.deepEqual(page.writes, []); // QR token URLs are never cached
  assert.equal((await workerRequest('https://app.example/index.html', { status: 500 })).writes.length, 0);
  assert.deepEqual((await workerRequest('https://app.example/portal.html')).writes, ['/portal.html']);
  for (const cacheControl of ['no-store', 'private', 'max-age=0, PRIVATE', 'private, no-store']) {
    for (const [pathname, mode] of [['portal.html', 'navigate'], ['verify-shared.js', 'cors']]) {
      assert.deepEqual((await workerRequest(`https://app.example/${pathname}`, { mode, cacheControl })).writes, []);
    }
  }
  assert.equal((await workerRequest('https://app.example/private-data', { mode: 'cors' })).intercepted, false);
  assert.equal((await workerRequest('https://db.supabase.co/rest/v1/rpc/test')).writes.length, 0);
  assert.equal((await workerRequest('https://cdn.example/image?token=SIGNED', { mode: 'cors' })).writes.length, 0);
  assert.equal((await workerRequest('https://app.example/data', { method: 'POST' })).intercepted, false);
  const quota = await workerRequest('https://app.example/index.html', { quota: true });
  assert.equal(quota.warnings.length, 1);
  console.log('PASS CSV formula protection, correct registration link, credential-free SW cache, failure handling and network-only third parties');
})().catch(error => { console.error(error); process.exitCode = 1; });
