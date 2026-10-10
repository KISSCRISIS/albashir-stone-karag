const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
(async () => {
  const { createAdminAccount } = await import('../supabase/functions/admin-create-user/handler.mjs');
  const valid = { p_email: 'test@example.invalid', password: 'Synthetic-Test-123!', p_full_name: 'Synthetic admin',
    p_phone_number: '', p_role: 'SUB_ADMIN', p_is_active: true, p_permissions: { can_view_logs: true } };
  async function run(options = {}, body = valid) {
    const calls = [];
    const result = (data, error = null) => ({ data, error });
    const context = {
      supabase: { rpc: async (name, payload) => {
        calls.push({ name, payload });
        if (name === 'get_my_admin_profile') return result({ ok: options.authorized !== false, role: options.role || 'SUPER_ADMIN' });
        if (options.saveThrows) throw Error('transport lost after possible commit');
        return result({ ok: !options.saveError }, options.saveError ? Error('save failed') : null);
      }, auth: { resend: async payload => { calls.push({ name: 'mail', payload }); if(options.mailThrows)throw Error('mail transport failed'); return result({}, options.mailError ? Error('mail failed') : null); } } },
      supabaseAdmin: { auth: { admin: {
        createUser: async payload => { calls.push({ name: 'create', payload }); return result({ user: { id: 'new-only' } }, options.duplicate ? Error('exists') : null); },
        deleteUser: async id => { calls.push({ name: 'delete', id }); return result({}, options.cleanupError ? Error('cleanup failed') : null); }
      } } }
    };
    const response = await createAdminAccount(new Request('https://test.invalid', { method: 'POST', body: JSON.stringify(body) }), context);
    return { status: response.status, body: await response.json(), calls };
  }
  for (const options of [{ authorized: false }, { role: 'SUB_ADMIN' }]) {
    const r = await run(options); assert.equal(r.status, 403); assert.equal(r.calls.length, 1);
  }
  for (const body of [null, { ...valid, password: 'short' }, { ...valid, p_role: 'EMPLOYEE' },
    { ...valid, p_permissions: { can_view_logs: 'true' } }]) {
    const r = await run({}, body); assert.equal(r.status, 400); assert.equal(r.calls.length, 1);
  }
  const duplicate = await run({ duplicate: true }); assert.equal(duplicate.status, 400); assert(!duplicate.calls.some(c => c.name === 'delete' || c.name === 'mail'));
  const failed = await run({ saveError: true }); assert.equal(failed.status, 500);
  assert.deepEqual(failed.calls.map(c => c.name), ['get_my_admin_profile', 'create', 'super_admin_upsert_admin_profile', 'delete']);
  assert.equal(failed.calls.at(-1).id, 'new-only');
  const cleanup = await run({ saveError: true, cleanupError: true }); assert.match(cleanup.body.message, /تنظيف/);
  const mail = await run({ mailError: true }); assert.equal(mail.status, 201); assert.equal(mail.body.confirmation_sent, false); assert(!mail.calls.some(c => c.name === 'delete'));
  const uncertain = await run({ saveThrows: true }); assert.equal(uncertain.status, 503); assert.equal(uncertain.body.account_created, true); assert(!uncertain.calls.some(c => c.name === 'mail' || c.name === 'delete'));
  const mailLost = await run({ mailThrows: true }); assert.equal(mailLost.body.confirmation_sent, false);
  const success = await run(); assert.equal(success.status, 201); assert.equal(success.body.confirmation_sent, true);
  assert.deepEqual(success.calls.map(c => c.name), ['get_my_admin_profile', 'create', 'super_admin_upsert_admin_profile', 'mail']);
  assert.equal(success.calls[1].payload.email_confirm, false); assert.equal(success.calls.at(-1).payload.type, 'signup');
  assert(!('password' in success.calls[2].payload));
  const entry = fs.readFileSync(path.join(__dirname, '../supabase/functions/admin-create-user/index.ts'), 'utf8');
  assert.match(entry, /auth: 'user'/); assert.match(entry, /@supabase\/server@1\.9\.1/);
  console.log('PASS admin authorization, input validation, duplicate email, caller-JWT permissions, rollback and explicit confirmation delivery');
})().catch(e => { console.error(e); process.exitCode = 1; });
