-- Production parity: remove anonymous/public EXECUTE from admin-only RPCs.
-- Authenticated execution remains because each RPC performs its own admin/
-- super-admin authorization check.
-- Applied to Production as migration: harden_admin_rpc_execute_acl.

REVOKE EXECUTE ON FUNCTION public.admin_review_employee_data_change(uuid, text, text)
  FROM PUBLIC, anon;

REVOKE EXECUTE ON FUNCTION public.admin_set_trusted_device(uuid, boolean, boolean)
  FROM PUBLIC, anon;

REVOKE EXECUTE ON FUNCTION public.admin_upsert_specialty_limit(text, integer, boolean)
  FROM PUBLIC, anon;

REVOKE EXECUTE ON FUNCTION public.super_admin_delete_admin_profile(uuid)
  FROM PUBLIC, anon;

REVOKE EXECUTE ON FUNCTION public.super_admin_disable_admin_profile(uuid)
  FROM PUBLIC, anon;

REVOKE EXECUTE ON FUNCTION public.super_admin_upsert_admin_profile(text, text, text, boolean)
  FROM PUBLIC, anon;

REVOKE EXECUTE ON FUNCTION public.super_admin_upsert_admin_profile(text, text, text, text, boolean, jsonb)
  FROM PUBLIC, anon;

NOTIFY pgrst, 'reload schema';
