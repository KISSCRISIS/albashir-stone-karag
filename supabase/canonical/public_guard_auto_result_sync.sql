-- Capture trusted-device decisions for the public guard session, without changing authority.
create function public.public_guard_auto_employee_check(p_device_token text,p_qr_token text,p_device_id text)
returns jsonb language plpgsql security definer set search_path=public,private as $$
declare s_id uuid; r jsonb; e_id uuid;
begin
  begin
    select s.id into s_id from private.public_guard_sessions s join public.qr_sessions q on q.id=s.qr_session_id
    where (q.token=nullif(trim(p_qr_token),'')::uuid or q.claim_token=nullif(trim(p_qr_token),'')::uuid) and s.expires_at>now()
    for update of s;
  exception when invalid_text_representation then s_id:=null;
  end;
  r:=public.auto_employee_check(p_device_token,p_qr_token,p_device_id);
  if s_id is not null then
    select id into e_id from public.employee_registrations
    where trusted_device_token_hash=public.hash_trusted_device_token(trim(p_device_token))
      and trusted_device_fingerprint_hash=public.hash_trusted_device_fingerprint(trim(p_device_id))
      and status='APPROVED' and trusted_device_enabled=true and trusted_device_revoked_at is null
      and trusted_device_expires_at>now();
    update private.public_guard_sessions set
      result=case when r->>'result' in ('ALLOWED','LIMITED') then r->>'result' else 'DENIED' end,
      employee_registration_id=e_id,decided_at=now()
    where id=s_id and (result is null or (result='DENIED' and r->>'result' in ('ALLOWED','LIMITED')));
  end if;
  return r;
end; $$;
revoke all on function public.public_guard_auto_employee_check(text,text,text) from public;
grant execute on function public.public_guard_auto_employee_check(text,text,text) to anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.public_guard_employee_check(p_employee_id text, p_mobile_number text, p_qr_token text, p_device_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare s_id uuid; r jsonb; e_id uuid;
begin
  begin
    select s.id into s_id from private.public_guard_sessions s join public.qr_sessions q on q.id=s.qr_session_id
    where (q.token=nullif(trim(p_qr_token),'')::uuid or q.claim_token=nullif(trim(p_qr_token),'')::uuid) and s.expires_at>now()
    for update of s;
  exception when invalid_text_representation then s_id:=null;
  end;
  r:=public.manual_employee_check_with_device(p_employee_id,p_mobile_number,p_qr_token,p_device_id);
  if s_id is not null then
    select id into e_id from public.employee_registrations where employee_id=trim(p_employee_id) and mobile_number=trim(p_mobile_number);
    update private.public_guard_sessions set
      result=case when r->>'result' in ('ALLOWED','LIMITED') then r->>'result' else 'DENIED' end,
      employee_registration_id=e_id,decided_at=now()
    where id=s_id and (result is null or (result='DENIED' and r->>'result' in ('ALLOWED','LIMITED')));
  end if;
  return r;
end; $function$;
