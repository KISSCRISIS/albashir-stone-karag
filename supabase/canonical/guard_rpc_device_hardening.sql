-- Phase A: approved candidate. NOT APPLIED to Production.
-- Preserve legacy employee-result access until frontend deployment is confirmed.
-- No tables/RLS changed; legacy functions retained for owner/service_role.
CREATE OR REPLACE FUNCTION public.get_guard_employee_result(p_employee_id text, p_device_code text, p_device_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  clean_device_code text := trim(coalesce(p_device_code, ''));
  clean_token text := trim(coalesce(p_device_token, ''));
  clean_token_hash text;
  gate public.gate_devices%rowtype;
  token_ok boolean := false;
  reg public.employee_registrations%rowtype;
  result jsonb;
begin
  if clean_device_code = '' or clean_token = '' then
    return jsonb_build_object('ok', false, 'message', 'جهاز الحارس غير موثق');
  end if;

  select * into gate
  from public.gate_devices
  where device_code = clean_device_code
  limit 1;

  if gate.id is null or coalesce(gate.is_active, false) = false then
    perform public.log_gate_auth_failure(clean_device_code, 'get_guard_employee_result: device not approved');
    return jsonb_build_object('ok', false, 'message', 'جهاز الحارس غير معتمد');
  end if;

  clean_token_hash := public.hash_offline_device_token(clean_token);

  select exists (
    select 1
    from public.offline_device_tokens
    where gate_device_id = gate.id
      and device_code = clean_device_code
      and token_hash = clean_token_hash
      and is_active = true
      and revoked_at is null
  )
  into token_ok;

  if token_ok = false then
    perform public.log_gate_auth_failure(clean_device_code, 'get_guard_employee_result: invalid token');
    return jsonb_build_object('ok', false, 'message', 'رمز جهاز الحارس غير صالح');
  end if;

  select * into reg from public.employee_registrations
  where employee_id = trim(coalesce(p_employee_id, ''))
  limit 1;
  if reg.id is null then return null; end if;
  result := public.employee_result_details(reg.id);
  return result - 'mobile_number';
end;
$function$;

REVOKE EXECUTE ON FUNCTION public.get_guard_employee_result(text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_guard_employee_result(text,text,text) TO anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.reset_guard_screen() FROM PUBLIC, anon, authenticated;
