-- Owner-approved public guard page; access decisions remain in existing P0-3 function.
create schema if not exists private;
create table private.public_guard_sessions (
  id uuid primary key default gen_random_uuid(),
  qr_session_id uuid not null unique references public.qr_sessions(id) on delete cascade,
  read_key_hash text not null unique,
  expires_at timestamptz not null default now()+interval '6 minutes',
  result text check(result in ('ALLOWED','LIMITED','DENIED')),
  employee_registration_id uuid references public.employee_registrations(id) on delete set null,
  decided_at timestamptz
);
alter table private.public_guard_sessions enable row level security;
revoke all on private.public_guard_sessions from public,anon,authenticated;

create function public.create_public_guard_qr()
returns jsonb language plpgsql security definer set search_path=public,private,extensions as $$
declare q public.qr_sessions%rowtype; read_key text;
begin
  perform pg_advisory_xact_lock(73007114535);
  if (select count(*) from private.public_guard_sessions where expires_at>now()) >= 1200 then
    return jsonb_build_object('ok',false,'error','RATE_LIMITED');
  end if;
  delete from private.public_guard_sessions where expires_at < now()-interval '1 day';
  read_key := encode(extensions.gen_random_bytes(32),'hex');
  insert into public.qr_sessions(expires_at) values(now()+interval '30 seconds') returning * into q;
  insert into private.public_guard_sessions(qr_session_id,read_key_hash)
  values(q.id,encode(extensions.digest(read_key,'sha256'),'hex'));
  return jsonb_build_object('ok',true,'token',q.token::text,'expires_at',q.expires_at,'expires_in_seconds',30,'read_key',read_key);
end; $$;
revoke all on function public.create_public_guard_qr() from public;
grant execute on function public.create_public_guard_qr() to anon,authenticated,service_role;

create function public.get_public_guard_result(p_read_key text)
returns jsonb language plpgsql security definer set search_path=public,private,extensions as $$
declare s private.public_guard_sessions%rowtype; e public.employee_registrations%rowtype;
begin
  if p_read_key is null or p_read_key !~ '^[0-9a-f]{64}$' then return jsonb_build_object('ok',false,'error','DENIED'); end if;
  select * into s from private.public_guard_sessions where read_key_hash=encode(extensions.digest(p_read_key,'sha256'),'hex') and expires_at>now();
  if s.id is null then return jsonb_build_object('ok',false,'error','DENIED'); end if;
  if s.result is null then return jsonb_build_object('ok',true,'result','WAITING'); end if;
  select * into e from public.employee_registrations where id=s.employee_registration_id;
  return jsonb_build_object('ok',true,'result',s.result,'decided_at',s.decided_at,
    'employee',jsonb_build_object('full_name',e.full_name,'job_type',e.job_type,'specialty',e.specialty,
      'has_photo',nullif(e.employee_photo_url,'') is not null));
end; $$;
revoke all on function public.get_public_guard_result(text) from public;
grant execute on function public.get_public_guard_result(text) to anon,authenticated,service_role;

create function public.public_guard_employee_check(p_employee_id text,p_mobile_number text,p_qr_token text,p_device_id text)
returns jsonb language plpgsql security definer set search_path=public,private as $$
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
    where id=s_id and result is null;
  end if;
  return r;
end; $$;
revoke all on function public.public_guard_employee_check(text,text,text,text) from public;
grant execute on function public.public_guard_employee_check(text,text,text,text) to anon,authenticated,service_role;

-- Only the Edge resolver may obtain an object path; public result never exposes paths/IDs.
create function public.resolve_public_guard_photo(p_read_key text)
returns jsonb language plpgsql security definer set search_path=public,private,extensions as $$
declare photo text;
begin
  if p_read_key is null or p_read_key !~ '^[0-9a-f]{64}$' then return jsonb_build_object('ok',false); end if;
  select e.employee_photo_url into photo from private.public_guard_sessions s
  join public.employee_registrations e on e.id=s.employee_registration_id
  where s.read_key_hash=encode(extensions.digest(p_read_key,'sha256'),'hex') and s.expires_at>now() and s.result is not null;
  if nullif(photo,'') is null then return jsonb_build_object('ok',false); end if;
  return jsonb_build_object('ok',true,'path',photo);
end; $$;
revoke all on function public.resolve_public_guard_photo(text) from public,anon,authenticated;
grant execute on function public.resolve_public_guard_photo(text) to service_role;
