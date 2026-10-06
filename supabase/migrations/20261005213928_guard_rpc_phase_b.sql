-- Phase B: NOT APPLIED. Apply ONLY after Phase A and live frontend confirmation.
-- Confirm index.html sends employee id, gate code and gate token; retain owner/service_role.
REVOKE EXECUTE ON FUNCTION public.get_guard_employee_result(text) FROM PUBLIC, anon, authenticated;
