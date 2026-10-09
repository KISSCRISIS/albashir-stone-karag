-- Owner-authorized authenticated emergency entry, 2026-10-10.
-- QR display remains public. Only the new manual-entry path needs guard login.
create table private.guard_accounts (
  id uuid primary key default gen_random_uuid(),
  full_name text not null check(length(full_name) between 2 and 100),
  national_id text not null unique check(national_id ~ '^[0-9]{6,20}$'),
  phone_hash text not null,
  phone_hint text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index guard_accounts_name_unique on private.guard_accounts(lower(trim(full_name)));
create table private.guard_login_attempts (
  id bigint generated always as identity primary key,
  identity_hash text not null,
  created_at timestamptz not null default now()
);
create index guard_login_attempts_time on private.guard_login_attempts(created_at);
create index guard_login_attempts_identity on private.guard_login_attempts(identity_hash,created_at);
create table private.guard_sessions (
  token_hash text primary key,
  guard_id uuid not null references private.guard_accounts(id) on delete cascade,
  expires_at timestamptz not null default now()+interval '24 hours'
);
create table private.guard_emergency_settings (
  singleton boolean primary key default true check(singleton),
  enabled boolean not null default false
);
insert into private.guard_emergency_settings(singleton,enabled) values(true,false);
create table private.guard_manual_entries (
  guard_id uuid not null references private.guard_accounts(id),
  request_id uuid not null,
  employee_id text not null,
  response jsonb not null,
  created_at timestamptz not null default now(),
  primary key(guard_id,request_id)
);
create index guard_manual_entries_time on private.guard_manual_entries(created_at);
alter table private.guard_accounts enable row level security;
alter table private.guard_login_attempts enable row level security;
alter table private.guard_sessions enable row level security;
alter table private.guard_emergency_settings enable row level security;
alter table private.guard_manual_entries enable row level security;
revoke all on private.guard_accounts,private.guard_login_attempts,private.guard_sessions,
  private.guard_emergency_settings,private.guard_manual_entries from public,anon,authenticated;

create function private.guard_normalize_phone(p_phone text) returns text
language sql immutable set search_path=pg_catalog as $$
  select regexp_replace(regexp_replace(
    translate(trim(coalesce(p_phone,'')),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789'),
    '[^0-9]','','g'),'^(00962|962)','0');
$$;
revoke all on function private.guard_normalize_phone(text) from public,anon,authenticated;

create function public.admin_save_guard(p_guard_id uuid,p_full_name text,p_national_id text,p_phone text,p_is_active boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private,extensions as $$
declare g_id uuid; phone text:=private.guard_normalize_phone(p_phone); name text:=trim(p_full_name); national text:=translate(trim(p_national_id),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789');
begin
  if not public.is_super_admin() then return jsonb_build_object('ok',false,'message','هذه العملية للسوبر أدمن فقط'); end if;
  if name is null or length(name) not between 2 and 100 or name ~ '^[0-9]+$' or national is null or national !~ '^[0-9]{6,20}$'
     or p_is_active is null or (phone<>'' and phone !~ '^[0-9]{8,15}$') or (p_guard_id is null and phone='') then
    return jsonb_build_object('ok',false,'message','تحقق من الاسم والرقم الوطني ورقم الهاتف');
  end if;
  if p_guard_id is null then
    insert into private.guard_accounts(full_name,national_id,phone_hash,phone_hint,is_active)
    values(name,national,extensions.crypt(phone,extensions.gen_salt('bf',10)),right(phone,4),p_is_active) returning id into g_id;
  else
    update private.guard_accounts set full_name=name,national_id=national,is_active=p_is_active,
      phone_hash=case when phone='' then phone_hash else extensions.crypt(phone,extensions.gen_salt('bf',10)) end,
      phone_hint=case when phone='' then phone_hint else right(phone,4) end
    where id=p_guard_id returning id into g_id;
    if g_id is null then return jsonb_build_object('ok',false,'message','ملف الحارس غير موجود'); end if;
    -- Editing identity, phone or status revokes all existing sessions immediately.
    delete from private.guard_sessions where guard_id=g_id;
  end if;
  insert into public.admin_audit_logs(admin_auth_user_id,action,target_table,target_id,details)
  values(auth.uid(),'SAVE_GUARD_ACCOUNT','guard_accounts',g_id::text,jsonb_build_object('is_active',p_is_active));
  return jsonb_build_object('ok',true,'message','تم حفظ ملف الحارس');
exception when unique_violation then
  return jsonb_build_object('ok',false,'message','الاسم أو الرقم الوطني مستخدم؛ اختر اسمًا مميزًا للحارس');
end; $$;
revoke all on function public.admin_save_guard(uuid,text,text,text,boolean) from public,anon;
grant execute on function public.admin_save_guard(uuid,text,text,text,boolean) to authenticated;

create function public.admin_list_guards() returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,private as $$
begin
  if not public.is_super_admin() then return jsonb_build_object('ok',false,'message','غير مصرح'); end if;
  return jsonb_build_object('ok',true,'emergency_enabled',(select enabled from private.guard_emergency_settings),
    'guards',coalesce((select jsonb_agg(jsonb_build_object('id',id,'full_name',full_name,'national_id',national_id,
      'phone_hint',phone_hint,'is_active',is_active) order by full_name) from private.guard_accounts),'[]'::jsonb));
end; $$;
revoke all on function public.admin_list_guards() from public,anon;
grant execute on function public.admin_list_guards() to authenticated;

create function public.admin_set_guard_emergency(p_enabled boolean) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,private as $$
begin
  if not public.is_super_admin() then return jsonb_build_object('ok',false,'message','غير مصرح'); end if;
  if p_enabled is null then return jsonb_build_object('ok',false,'message','حالة غير صحيحة'); end if;
  update private.guard_emergency_settings set enabled=p_enabled;
  insert into public.admin_audit_logs(admin_auth_user_id,action,target_table,details)
  values(auth.uid(),'SET_GUARD_EMERGENCY','guard_emergency_settings',jsonb_build_object('enabled',p_enabled));
  return jsonb_build_object('ok',true,'message','تم تحديث وضع الطوارئ');
end; $$;
revoke all on function public.admin_set_guard_emergency(boolean) from public,anon;
grant execute on function public.admin_set_guard_emergency(boolean) to authenticated;

create function public.guard_login(p_identity text,p_phone text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,private,extensions as $$
declare g private.guard_accounts%rowtype; identity text:=translate(lower(trim(coalesce(p_identity,''))),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789'); phone text:=private.guard_normalize_phone(p_phone);
  ih text; token text; expiry timestamptz:=now()+interval '24 hours';
begin
  if length(identity) not between 2 and 100 or phone !~ '^[0-9]{8,15}$' then return jsonb_build_object('ok',false,'message','تحقق من الاسم أو الرقم الوطني ورقم الهاتف'); end if;
  perform pg_advisory_xact_lock(610100901);
  delete from private.guard_login_attempts where created_at<now()-interval '1 day';
  delete from private.guard_sessions where expires_at<=now();
  ih:=encode(extensions.digest(identity,'sha256'),'hex');
  if (select count(*) from private.guard_login_attempts where created_at>now()-interval '1 minute')>=120
     or (select count(*) from private.guard_login_attempts where identity_hash=ih and created_at>now()-interval '15 minutes')>=5 then
    return jsonb_build_object('ok',false,'message','محاولات كثيرة؛ انتظر 15 دقيقة ثم حاول مجددًا');
  end if;
  insert into private.guard_login_attempts(identity_hash) values(ih);
  select * into g from private.guard_accounts where lower(trim(full_name))=identity or national_id=identity for update;
  if g.id is null or not g.is_active then
    perform extensions.crypt(phone,extensions.gen_salt('bf',10));
    return jsonb_build_object('ok',false,'message','تحقق من الاسم أو الرقم الوطني ورقم الهاتف');
  end if;
  if extensions.crypt(phone,g.phone_hash)<>g.phone_hash then return jsonb_build_object('ok',false,'message','تحقق من الاسم أو الرقم الوطني ورقم الهاتف'); end if;
  token:=encode(extensions.gen_random_bytes(32),'hex');
  delete from private.guard_sessions where guard_id=g.id;
  insert into private.guard_sessions(token_hash,guard_id,expires_at) values(encode(extensions.digest(token,'sha256'),'hex'),g.id,expiry);
  return jsonb_build_object('ok',true,'token',token,'expires_at',expiry,'full_name',g.full_name,
    'emergency_enabled',(select enabled from private.guard_emergency_settings));
end; $$;
revoke all on function public.guard_login(text,text) from public;
grant execute on function public.guard_login(text,text) to anon,authenticated;

create function private.guard_session_id(p_token text) returns uuid
language sql stable set search_path=pg_catalog,private,extensions as $$
  select g.id from private.guard_sessions s join private.guard_accounts g on g.id=s.guard_id
  where p_token ~ '^[0-9a-f]{64}$' and s.token_hash=encode(extensions.digest(p_token,'sha256'),'hex')
    and s.expires_at>now() and g.is_active;
$$;
revoke all on function private.guard_session_id(text) from public,anon,authenticated;

create function public.guard_session_status(p_token text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare g_id uuid:=private.guard_session_id(p_token);
begin
  if g_id is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
  return jsonb_build_object('ok',true,'full_name',(select full_name from private.guard_accounts where id=g_id),
    'emergency_enabled',(select enabled from private.guard_emergency_settings));
end; $$;
revoke all on function public.guard_session_status(text) from public;
grant execute on function public.guard_session_status(text) to anon,authenticated;

create function public.guard_logout(p_token text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,private,extensions as $$
begin
  if p_token ~ '^[0-9a-f]{64}$' then delete from private.guard_sessions where token_hash=encode(extensions.digest(p_token,'sha256'),'hex'); end if;
  return jsonb_build_object('ok',true);
end; $$;
revoke all on function public.guard_logout(text) from public;
grant execute on function public.guard_logout(text) to anon,authenticated;

create function public.guard_manual_employee_entry(p_token text,p_employee_id text,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,private,extensions as $$
declare g_id uuid; reg public.employee_registrations%rowtype; q public.qr_sessions%rowtype;
  prior private.guard_manual_entries%rowtype; r jsonb; response jsonb; read_key text; emp text:=translate(trim(coalesce(p_employee_id,'')),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789');
begin
  g_id:=private.guard_session_id(p_token);
  if g_id is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED','message','سجّل دخول الحارس أولًا'); end if;
  -- Lock the account against revocation for this decision, then recheck session.
  perform 1 from private.guard_accounts where id=g_id for share;
  if private.guard_session_id(p_token) is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
  if p_request_id is null or length(emp) not between 1 and 100 then return jsonb_build_object('ok',false,'message','أدخل الرقم الوظيفي أو الوطني'); end if;
  perform pg_advisory_xact_lock(610100902);
  select * into prior from private.guard_manual_entries where guard_id=g_id and request_id=p_request_id;
  if prior.request_id is not null then
    if prior.employee_id<>emp then return jsonb_build_object('ok',false,'error','REQUEST_MISMATCH'); end if;
    return prior.response;
  end if;
  if not (select enabled from private.guard_emergency_settings) then return jsonb_build_object('ok',false,'message','الدخول اليدوي للطوارئ غير مفعّل؛ راجع الإدارة'); end if;
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
end; $$;
revoke all on function public.guard_manual_employee_entry(text,text,uuid) from public;
grant execute on function public.guard_manual_employee_entry(text,text,uuid) to anon,authenticated;
