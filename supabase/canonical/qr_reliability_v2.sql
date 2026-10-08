-- QR Reliability v2 (Staging-first): idempotent claims and atomic verification retries.
-- Additive only: existing v1 RPCs remain available during rollout.

alter table public.qr_sessions
  add column if not exists claim_request_id uuid;

create unique index if not exists qr_sessions_claim_request_id_key
  on public.qr_sessions (claim_request_id)
  where claim_request_id is not null;

create table if not exists private.qr_verification_requests (
  request_id uuid primary key,
  mode text not null check (mode in ('AUTO','MANUAL')),
  payload_hash text not null,
  guard_session_id uuid references private.public_guard_sessions(id) on delete set null,
  qr_session_id uuid references public.qr_sessions(id) on delete set null,
  employee_registration_id uuid references public.employee_registrations(id) on delete set null,
  status text not null default 'PROCESSING' check (status in ('PROCESSING','COMPLETED')),
  result text,
  response jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz
);

create index if not exists qr_verification_requests_created_at_idx
  on private.qr_verification_requests (created_at);

alter table private.qr_verification_requests enable row level security;
revoke all on table private.qr_verification_requests from public, anon, authenticated;

create or replace function public.claim_qr_session_v2(
  p_token text,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  token_uuid uuid;
  new_claim uuid := gen_random_uuid();
  q public.qr_sessions%rowtype;
begin
  if p_request_id is null then
    return jsonb_build_object('ok', false, 'error', 'REQUEST_ID_REQUIRED', 'message', 'معرف الطلب مطلوب');
  end if;

  begin
    token_uuid := nullif(trim(coalesce(p_token, '')), '')::uuid;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'INVALID_QR', 'message', 'QR غير صحيح');
  end;

  update public.qr_sessions
  set used_at = now(),
      claimed_at = now(),
      claim_token = new_claim,
      claim_expires_at = now() + interval '5 minutes',
      claim_used_at = null,
      claim_request_id = p_request_id
  where token = token_uuid
    and used_at is null
    and expires_at > now()
  returning * into q;

  if q.id is not null then
    return jsonb_build_object(
      'ok', true,
      'claim_token', q.claim_token::text,
      'expires_in_seconds', greatest(0, extract(epoch from (q.claim_expires_at-now()))::integer),
      'server_now', now(),
      'idempotent', false,
      'message', 'تم تفعيل جلسة QR، أكمل البيانات خلال 5 دقائق'
    );
  end if;

  select * into q
  from public.qr_sessions
  where token = token_uuid
    and claim_request_id = p_request_id
    and claim_token is not null
    and claim_expires_at > now()
  limit 1;

  if q.id is not null then
    return jsonb_build_object(
      'ok', true,
      'claim_token', q.claim_token::text,
      'expires_in_seconds', greatest(0, extract(epoch from (q.claim_expires_at-now()))::integer),
      'server_now', now(),
      'idempotent', true,
      'message', 'تم استعادة جلسة QR نفسها بعد إعادة المحاولة'
    );
  end if;

  return jsonb_build_object(
    'ok', false,
    'error', 'QR_UNAVAILABLE',
    'server_now', now(),
    'message', 'QR غير صالح أو منتهي، يرجى مسح QR جديد من شاشة الحارس'
  );
end;
$function$;

create or replace function public.public_guard_auto_employee_check_v2(
  p_request_id uuid,
  p_device_token text,
  p_qr_token text,
  p_device_id text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','private','extensions'
as $function$
declare
  req private.qr_verification_requests%rowtype;
  s_id uuid;
  q_id uuid;
  e_id uuid;
  r jsonb;
  h text;
begin
  if p_request_id is null then
    return jsonb_build_object('ok',false,'result','DENIED','error','REQUEST_ID_REQUIRED','message','معرف الطلب مطلوب');
  end if;

  h := encode(extensions.digest(
    jsonb_build_array('AUTO',coalesce(p_qr_token,''),coalesce(p_device_id,''),coalesce(p_device_token,''))::text,
    'sha256'
  ),'hex');

  insert into private.qr_verification_requests(request_id,mode,payload_hash)
  values(p_request_id,'AUTO',h)
  on conflict (request_id) do nothing;

  select * into req
  from private.qr_verification_requests
  where request_id=p_request_id
  for update;

  if req.mode <> 'AUTO' or req.payload_hash <> h then
    return jsonb_build_object('ok',false,'result','DENIED','error','REQUEST_ID_REUSED','message','تم استخدام معرف الطلب مع بيانات مختلفة');
  end if;

  if req.status='COMPLETED' and req.response is not null then
    if req.completed_at is null or req.completed_at < now()-interval '30 seconds' then
      return jsonb_build_object('ok',false,'result','DENIED','error','RETRY_EXPIRED','message','انتهت مهلة إعادة المحاولة. امسح QR جديدًا.');
    end if;
    return req.response || jsonb_build_object('request_id',p_request_id,'idempotent',true);
  end if;

  begin
    select s.id,q.id into s_id,q_id
    from private.public_guard_sessions s
    join public.qr_sessions q on q.id=s.qr_session_id
    where q.claim_token=nullif(trim(p_qr_token),'')::uuid
      and q.claim_request_id=p_request_id
      and q.claim_used_at is null
      and q.claim_expires_at>now()
      and s.expires_at>now()
    limit 1;
  exception when invalid_text_representation then
    s_id:=null; q_id:=null;
  end;

  update private.qr_verification_requests
  set guard_session_id=s_id,qr_session_id=q_id,updated_at=now()
  where request_id=p_request_id;

  r := public.public_guard_auto_employee_check(p_device_token,p_qr_token,p_device_id);

  if coalesce(r->>'employee','') <> '' then
    select id into e_id
    from public.employee_registrations
    where trusted_device_token_hash=public.hash_trusted_device_token(trim(p_device_token))
      and trusted_device_fingerprint_hash=public.hash_trusted_device_fingerprint(trim(p_device_id))
    limit 1;
  end if;

  update private.qr_verification_requests
  set status='COMPLETED',
      result=coalesce(r->>'result','DENIED'),
      response=r,
      employee_registration_id=e_id,
      completed_at=now(),
      updated_at=now()
  where request_id=p_request_id;

  return r || jsonb_build_object('request_id',p_request_id,'idempotent',false);
end;
$function$;

create or replace function public.public_guard_employee_check_v2(
  p_request_id uuid,
  p_employee_id text,
  p_mobile_number text,
  p_qr_token text,
  p_device_id text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','private','extensions'
as $function$
declare
  req private.qr_verification_requests%rowtype;
  s_id uuid;
  q_id uuid;
  e_id uuid;
  r jsonb;
  h text;
begin
  if p_request_id is null then
    return jsonb_build_object('ok',false,'result','DENIED','error','REQUEST_ID_REQUIRED','message','معرف الطلب مطلوب');
  end if;

  h := encode(extensions.digest(
    jsonb_build_array('MANUAL',coalesce(p_qr_token,''),coalesce(p_device_id,''),coalesce(p_employee_id,''),coalesce(p_mobile_number,''))::text,
    'sha256'
  ),'hex');

  insert into private.qr_verification_requests(request_id,mode,payload_hash)
  values(p_request_id,'MANUAL',h)
  on conflict (request_id) do nothing;

  select * into req
  from private.qr_verification_requests
  where request_id=p_request_id
  for update;

  if req.mode <> 'MANUAL' or req.payload_hash <> h then
    return jsonb_build_object('ok',false,'result','DENIED','error','REQUEST_ID_REUSED','message','تم استخدام معرف الطلب مع بيانات مختلفة');
  end if;

  if req.status='COMPLETED' and req.response is not null then
    if req.completed_at is null or req.completed_at < now()-interval '30 seconds' then
      return jsonb_build_object('ok',false,'result','DENIED','error','RETRY_EXPIRED','message','انتهت مهلة إعادة المحاولة. امسح QR جديدًا.');
    end if;
    return req.response || jsonb_build_object('request_id',p_request_id,'idempotent',true);
  end if;

  begin
    select s.id,q.id into s_id,q_id
    from private.public_guard_sessions s
    join public.qr_sessions q on q.id=s.qr_session_id
    where q.claim_token=nullif(trim(p_qr_token),'')::uuid
      and q.claim_request_id=p_request_id
      and q.claim_used_at is null
      and q.claim_expires_at>now()
      and s.expires_at>now()
    limit 1;
  exception when invalid_text_representation then
    s_id:=null; q_id:=null;
  end;

  update private.qr_verification_requests
  set guard_session_id=s_id,qr_session_id=q_id,updated_at=now()
  where request_id=p_request_id;

  r := public.public_guard_employee_check(p_employee_id,p_mobile_number,p_qr_token,p_device_id);

  select id into e_id
  from public.employee_registrations
  where employee_id=trim(coalesce(p_employee_id,''))
    and mobile_number=trim(coalesce(p_mobile_number,''))
  limit 1;

  update private.qr_verification_requests
  set status='COMPLETED',
      result=coalesce(r->>'result','DENIED'),
      response=r,
      employee_registration_id=e_id,
      completed_at=now(),
      updated_at=now()
  where request_id=p_request_id;

  return r || jsonb_build_object('request_id',p_request_id,'idempotent',false);
end;
$function$;

revoke all on function public.claim_qr_session_v2(text,uuid) from public;
revoke all on function public.public_guard_auto_employee_check_v2(uuid,text,text,text) from public;
revoke all on function public.public_guard_employee_check_v2(uuid,text,text,text,text) from public;

grant execute on function public.claim_qr_session_v2(text,uuid) to anon, authenticated, service_role;
grant execute on function public.public_guard_auto_employee_check_v2(uuid,text,text,text) to anon, authenticated, service_role;
grant execute on function public.public_guard_employee_check_v2(uuid,text,text,text,text) to anon, authenticated, service_role;
