import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" }
});

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, message: "Method not allowed" }, 405);
  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return json({ ok: false, message: "Server configuration missing" }, 503);
  const bearer = req.headers.get("Authorization") || "";
  if (!/^Bearer\s+\S+$/i.test(bearer)) return json({ ok: false, message: "Authentication required" }, 401);
  const caller = createClient(url, anonKey, { global: { headers: { Authorization: bearer } }, auth: { persistSession: false } });
  const { data: profile, error: profileError } = await caller.rpc("get_my_admin_profile");
  if (profileError || profile?.ok !== true || profile.role !== "SUPER_ADMIN") return json({ ok: false, message: "SUPER_ADMIN required" }, 403);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ ok: false, message: "Invalid JSON" }, 400); }
  const email = String(body.p_email || "").trim().toLowerCase();
  const password = String(body.password || "");
  const name = String(body.p_full_name || "").trim();
  const phone = String(body.p_phone_number || "").trim();
  const role = String(body.p_role || "");
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || !name || password.length < 12 || !["SUB_ADMIN", "SUPER_ADMIN"].includes(role)) {
    return json({ ok: false, message: "Valid email, name, role and password of at least 12 characters required" }, 400);
  }
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email, password, email_confirm: false, user_metadata: { full_name: name }
  });
  if (createError || !created.user) return json({ ok: false, message: createError?.message || "Could not create user" }, 400);

  // Use the caller's JWT for authorization of profile management and audit logging.
  const { data: saved, error: saveError } = await caller.rpc("super_admin_upsert_admin_profile", {
    p_email: email, p_full_name: name, p_phone_number: phone, p_role: role,
    p_is_active: body.p_is_active === true, p_permissions: body.p_permissions || {}
  });
  if (saveError || saved?.ok !== true) {
    const { error: rollbackError } = await admin.auth.admin.deleteUser(created.user.id);
    return json({ ok: false, message: rollbackError
      ? "Profile setup failed; account cleanup needs administrator review"
      : (saveError?.message || saved?.message || "Profile setup failed") }, 500);
  }
  return json({ ok: true, message: "تم إنشاء حساب المشرف. يجب تأكيد البريد الإلكتروني قبل تسجيل الدخول." }, 201);
});
