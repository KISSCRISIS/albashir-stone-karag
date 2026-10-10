const json = (body, status = 200) => Response.json(body, { status, headers: { 'Cache-Control': 'no-store' } });

// Authentication is performed by the entry point; authorization stays in the
// existing caller-JWT RPCs. Never use the elevated client to assign permissions.
export async function createAdminAccount(req, { supabase, supabaseAdmin }) {
  if (req.method !== 'POST') return json({ ok: false, message: 'Method not allowed' }, 405);
  const { data: profile, error: denied } = await supabase.rpc('get_my_admin_profile');
  if (denied || profile?.ok !== true || profile.role !== 'SUPER_ADMIN') {
    return json({ ok: false, message: 'هذه العملية للسوبر أدمن فقط.' }, 403);
  }
  let body;
  try { body = await req.json(); } catch { return json({ ok: false, message: 'Invalid JSON' }, 400); }
  if (!body || typeof body !== 'object' || Array.isArray(body)) return json({ ok: false, message: 'Invalid request' }, 400);
  const email = String(body.p_email || '').trim().toLowerCase();
  const password = String(body.password || '');
  const name = String(body.p_full_name || '').trim();
  const permissions = body.p_permissions;
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254 || !name || name.length > 200 ||
      password.length < 12 || password.length > 128 || !['SUB_ADMIN', 'SUPER_ADMIN'].includes(body.p_role) ||
      typeof body.p_is_active !== 'boolean' || !permissions || typeof permissions !== 'object' ||
      Array.isArray(permissions) || Object.values(permissions).some(v => typeof v !== 'boolean')) {
    return json({ ok: false, message: 'تحقق من البريد والاسم والدور والصلاحيات وكلمة المرور (12–128 حرفًا).' }, 400);
  }
  const { data: created, error: createError } = await supabaseAdmin.auth.admin.createUser({
    email, password, email_confirm: false, user_metadata: { full_name: name }
  });
  if (createError || !created?.user?.id) return json({ ok: false, message: 'تعذر إنشاء الحساب. تحقق من البريد وسياسة كلمة المرور؛ قد يكون الحساب موجودًا.' }, 400);
  let saved, saveError;
  try {
    ({ data: saved, error: saveError } = await supabase.rpc('super_admin_upsert_admin_profile', {
    p_email: email, p_full_name: name, p_phone_number: String(body.p_phone_number || '').trim(),
    p_role: body.p_role, p_is_active: body.p_is_active, p_permissions: permissions
    }));
  } catch {
    // The RPC may have committed before transport failure. Do not delete or
    // resend confirmation until an administrator reconciles this account.
    return json({ ok: false, account_created: true, message: 'أُنشئ حساب غير مؤكد، وتعذر تأكيد حفظ الصلاحيات. راجع قائمة المشرفين قبل إعادة المحاولة.' }, 503);
  }
  if (saveError || saved?.ok !== true) {
    const { error: cleanupError } = await supabaseAdmin.auth.admin.deleteUser(created.user.id);
    return json({ ok: false, message: cleanupError
      ? 'فشل حفظ الصلاحيات وتعذر تنظيف الحساب؛ راجع مسؤول النظام قبل إعادة المحاولة.'
      : 'فشل حفظ صلاحيات المشرف؛ أُلغي الحساب الجديد.' }, 500);
  }
  // createUser does not send mail. Request delivery explicitly; a delivery
  // failure must not report a usable account or retry account creation.
  let mailError;
  try { ({ error: mailError } = await supabase.auth.resend({ type: 'signup', email })); }
  catch { mailError = true; }
  return json({ ok: true, confirmation_sent: !mailError, message: mailError
    ? 'تم إنشاء الحساب وصلاحياته، لكن تعذر إرسال التأكيد. الحساب غير جاهز للدخول؛ راجع إعدادات البريد ولا تعِد إنشاءه.'
    : 'تم إنشاء حساب المشرف وإرسال رسالة التأكيد. يجب تأكيد البريد قبل الدخول.' }, 201);
}
