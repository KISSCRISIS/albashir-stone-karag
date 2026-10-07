-- Scoped search_path hardening. Owner approved these five statements on 2026-10-07.
-- All referenced custom functions are already schema-qualified with public.
-- Builtins resolve in pg_catalog; no unqualified tables or extension calls.
-- ALTER preserves bodies, ownership, volatility, signatures and grants.
ALTER FUNCTION public.normalize_specialty_name(text) SET search_path TO pg_catalog;
ALTER FUNCTION public.is_permanently_allowed_specialty(text) SET search_path TO pg_catalog;
ALTER FUNCTION public.default_admin_permissions(text) SET search_path TO pg_catalog;
ALTER FUNCTION public.sync_trusted_device_activity() SET search_path TO pg_catalog;
ALTER FUNCTION public.prevent_approved_employee_identity_change() SET search_path TO pg_catalog;
