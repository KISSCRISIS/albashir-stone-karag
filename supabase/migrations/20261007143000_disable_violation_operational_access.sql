-- Production parity: disable the operational violation-reporting path while
-- preserving historical read access for authenticated administrators.
-- Applied to Production as migration: disable_violation_operational_access.

REVOKE EXECUTE ON FUNCTION public.submit_violation_report(text, text, text)
  FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.admin_update_violation_status(uuid, text)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL PRIVILEGES ON TABLE public.violation_reports FROM anon;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.violation_reports
  FROM authenticated;

DROP POLICY IF EXISTS "Gate can upload violation photos" ON storage.objects;

NOTIFY pgrst, 'reload schema';
