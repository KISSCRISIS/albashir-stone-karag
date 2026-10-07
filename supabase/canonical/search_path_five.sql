-- Scoped search_path hardening. Owner review required before Production apply.
-- All referenced custom functions are already schema-qualified with public.
-- Builtins resolve in pg_catalog; no unqualified tables or extension calls.
-- ALTER preserves bodies, ownership, volatility, signatures and grants.
ALTER FUNCTION public.normalize_specialty_name(text) SET search_path TO pg_catalog;
ALTER FUNCTION public.is_permanently_allowed_specialty(text) SET search_path TO pg_catalog;
ALTER FUNCTION public.default_admin_permissions(text) SET search_path TO pg_catalog;
ALTER FUNCTION public.sync_trusted_device_activity() SET search_path TO pg_catalog;
-- This Production-only trigger is absent from the existing fresh-install baseline.
-- Do not introduce new identity logic as part of a search_path-only change.
DO $reviewed$ BEGIN
  IF to_regprocedure('public.prevent_approved_employee_identity_change()') IS NOT NULL THEN
    ALTER FUNCTION public.prevent_approved_employee_identity_change() SET search_path TO pg_catalog;
  END IF;
END $reviewed$;
