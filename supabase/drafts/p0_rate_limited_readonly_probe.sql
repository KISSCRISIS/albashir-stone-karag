-- NOT FOR DEPLOYMENT: prototype recognizes only the current generator's RATE_LIMITED failure.
-- Not station-scoped. Does not cover other server-side QR generation failures.
-- Does not yet make guard-manual.js compatible with server-only activation.
-- Review function privileges, tests, quota race and rollback before migration.
begin;
-- This read-only predicate matches the current QR generator's RATE_LIMITED branch.
-- No new QR token/session is created by checking health.
create or replace function private.guard_qr_generator_rate_limited()
returns boolean language plpgsql security definer
set search_path=pg_catalog,public,private as $health$
begin
  -- Same advisory lock used by create_public_guard_qr() prevents a race with creation.
  perform pg_advisory_xact_lock(73007114535);
  return (select count(*) from private.public_guard_sessions where expires_at>now())>=1200;
end;$health$;
revoke all on function private.guard_qr_generator_rate_limited() from public,anon,authenticated;

CREATE OR REPLACE FUNCTION public.guard_manual_employee_entry(p_token text, p_employee_id text, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private', 'extensions'
AS $function$
declare g_id uuid; reg public.employee_registrations%rowtype; q public.qr_sessions%rowtype;
  prior private.guard_manual_entries%rowtype; r jsonb; response jsonb; read_key text; emp text:=translate(trim(coalesce(p_employee_id,'')),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789');
begin
  g_id:=private.guard_session_id(p_token);
  if g_id is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED','message','سجّل دخول الحارس أولًا'); end if;
  -- Lock the account against revocation for this decision, then recheck session.
  perform 1 from private.guard_accounts where id=g_id for share;
  if private.guard_session_id(p_token) is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
  if p_request_id is null or length(emp) not between 1 and 100 then return jsonb_build_object('ok',false,'message','أدخل الرقم الوظيفي فقط'); end if;
  perform pg_advisory_xact_lock(610100902);
  select * into prior from private.guard_manual_entries where guard_id=g_id and request_id=p_request_id;
  if prior.request_id is not null then
    if prior.employee_id<>emp then return jsonb_build_object('ok',false,'error','REQUEST_MISMATCH'); end if;
    return prior.response;
  end if;
  if not private.guard_qr_generator_rate_limited() then return jsonb_build_object('ok',false,'error','QR_GENERATOR_HEALTHY','message','توليد QR يعمل؛ الدخول اليدوي غير متاح'); end if;
  if (select count(*) from private.guard_manual_entries where guard_id=g_id and created_at>now()-interval '1 minute')>=30 then
    return jsonb_build_object('ok',false,'message','محاولات كثيرة؛ انتظر دقيقة');
  end if;
  select * into reg from public.employee_registrations where employee_id=emp order by created_at desc limit 1;
  if reg.id is null then
    response:=jsonb_build_object('ok',true,'result','DENIED','message','الموظف غير موجود أو غير مصرح','employee',null,'counted',false);
  else
    -- Reuse the existing decision function, including status/device/specialty
    -- and daily-limit rules. A server-only single-use QR is issued ONLY after
    -- guard authorization; no caller receives or supplies this token.
    insert into public.qr_sessions(expires_at) values(now()+interval '30 seconds') returning * into q;
    r:=public.manual_employee_check(reg.employee_id,reg.mobile_number,q.token::text);
    read_key:=encode(extensions.gen_random_bytes(32),'hex');
    insert into private.public_guard_sessions(qr_session_id,read_key_hash,expires_at,result,employee_registration_id,decided_at)
    values(q.id,encode(extensions.digest(read_key,'sha256'),'hex'),now()+interval '60 seconds',
      case when r->>'result' in ('ALLOWED','LIMITED') then r->>'result' else 'DENIED' end,reg.id,now());
    response:=public.get_public_guard_result(read_key)||jsonb_build_object('message',r->>'message','read_key',read_key,
      'counted',(r->>'result') in ('ALLOWED','LIMITED'));
    update public.gate_access_logs set reason='GUARD_MANUAL_EMERGENCY:'||coalesce(reason,'') where qr_token=q.token;
  end if;
  insert into private.guard_manual_entries(guard_id,request_id,employee_id,response) values(g_id,p_request_id,emp,response);
  insert into public.admin_audit_logs(admin_auth_user_id,action,target_table,target_id,details)
  values(null,'GUARD_MANUAL_ENTRY','employee_registrations',reg.id::text,
    jsonb_build_object('guard_id',g_id,'request_id',p_request_id,'result',response->>'result','counted',response->'counted'));
  return response;
end; $function$
;
CREATE OR REPLACE FUNCTION public.guard_set_emergency(p_token text, p_enabled boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'private', 'public'
AS $function$
declare gid uuid:=private.guard_session_id(p_token);
begin
 if gid is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED');end if;
 if p_enabled is null then return jsonb_build_object('ok',false,'message','اختيار غير صالح');end if;
 perform 1 from private.guard_accounts where id=gid for share;
 if private.guard_session_id(p_token) is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED');end if;
 if p_enabled and not private.guard_qr_generator_rate_limited() then return jsonb_build_object('ok',false,'error','QR_GENERATOR_HEALTHY','message','توليد QR يعمل؛ لا يمكن تفعيل الطوارئ'); end if;
 update private.guard_emergency_settings set enabled=p_enabled;
 insert into public.admin_audit_logs(action,target_table,target_id,details) values('GUARD_SET_EMERGENCY','guard_emergency_settings','true',jsonb_build_object('guard_id',gid,'enabled',p_enabled));
 return jsonb_build_object('ok',true,'emergency_enabled',p_enabled,'message',case when p_enabled then 'تم تفعيل الدخول اليدوي للطوارئ؛ كل زيارة تسجل وتحتسب' else 'تم إيقاف الدخول اليدوي للطوارئ' end);
end;$function$
;
CREATE OR REPLACE FUNCTION public.guard_session_status(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare g_id uuid:=private.guard_session_id(p_token);
begin
  if g_id is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
  return jsonb_build_object('ok',true,'full_name',(select full_name from private.guard_accounts where id=g_id),
    'emergency_enabled',private.guard_qr_generator_rate_limited());
end; $function$
;
commit;
