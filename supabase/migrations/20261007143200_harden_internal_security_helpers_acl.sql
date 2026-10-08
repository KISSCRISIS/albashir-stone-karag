-- Production parity: prevent direct anonymous execution of authorization
-- helpers and make maintenance/logging helpers internal-only.
-- Applied to Production as migration: harden_internal_security_helpers_acl.

-- Admin authorization helpers remain callable by authenticated admin flows.
REVOKE EXECUTE ON FUNCTION public.current_admin_role()
  FROM PUBLIC, anon;

REVOKE EXECUTE ON FUNCTION public.is_admin()
  FROM PUBLIC, anon;

REVOKE EXECUTE ON FUNCTION public.is_super_admin()
  FROM PUBLIC, anon;

REVOKE EXECUTE ON FUNCTION public.has_admin_permission(text)
  FROM PUBLIC, anon;

-- Internal-only helpers are restricted to postgres/service_role.
REVOKE EXECUTE ON FUNCTION public.cleanup_expired_qr_sessions()
  FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.rls_auto_enable()
  FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.write_security_attempt(text, text, text, boolean)
  FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';
