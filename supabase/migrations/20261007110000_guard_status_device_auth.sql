-- Approved guard status introduction. Apply before frontend switch.
CREATE OR REPLACE FUNCTION public.get_guard_screen_status(p_device_code text, p_device_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  clean_device_code text := trim(coalesce(p_device_code, ''));
  clean_token text := trim(coalesce(p_device_token, ''));
  gate public.gate_devices%rowtype;
  token_ok boolean := false;
  result jsonb;
begin
  if clean_device_code = '' or clean_token = '' then
    return jsonb_build_object('ok', false, 'error', 'DENIED');
  end if;
  select * into gate from public.gate_devices where device_code = clean_device_code limit 1;
  if gate.id is null or coalesce(gate.is_active, false) = false then
    perform public.log_gate_auth_failure(clean_device_code, 'get_guard_screen_status: device not approved');
    return jsonb_build_object('ok', false, 'error', 'DENIED');
  end if;
  select exists (
    select 1 from public.offline_device_tokens
    where gate_device_id = gate.id and device_code = clean_device_code
      and token_hash = public.hash_offline_device_token(clean_token)
      and is_active = true and revoked_at is null
  ) into token_ok;
  if token_ok is not true then
    perform public.log_gate_auth_failure(clean_device_code, 'get_guard_screen_status: invalid token');
    return jsonb_build_object('ok', false, 'error', 'DENIED');
  end if;
  select jsonb_build_object('current_status',current_status,'employee_name',employee_name,
    'employee_id',employee_id,'message',message,'updated_at',updated_at)
  into result from public.guard_screen_status where id = 1;
  return jsonb_build_object('ok',true,'status',result);
end;
$function$;
REVOKE EXECUTE ON FUNCTION public.get_guard_screen_status(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_guard_screen_status(text,text) TO anon, authenticated, service_role;
