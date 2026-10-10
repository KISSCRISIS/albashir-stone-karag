-- Owner approved: Staging only. Current frontend sends all 15 arguments.
-- Disable only obsolete signatures; preserve bodies/data and current registration grants.
REVOKE EXECUTE ON FUNCTION public.register_employee_request(text,text,text,text,text,text,text,text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.register_employee_request(text,text,text,text,text,text,text,text,text,text,text,text,text) FROM PUBLIC, anon, authenticated;
