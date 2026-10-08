-- Owner requested preserving existing device bindings, 2026-10-08.
-- Atomic rollout; identities/token hashes/enabled/revoked state must not change.
lock table public.employee_registrations in share row exclusive mode;
create temporary table rollout_device_baseline on commit drop as
select id, to_jsonb(e)-'trusted_device_fingerprint_hash'-'trusted_device_expires_at' as row_data
from public.employee_registrations e;
-- P2-18 Trusted Device hardening
-- Staging migration applied as:
-- 20261007094821_p2_18_trusted_device_binding_ttl
--
-- Scope:
-- - device_id fingerprint binding
-- - 30-day TTL
-- - revoke/disable cleanup
-- - legacy token-only RPC safe-deny
-- - new device-bound RPC overloads
-- - audit events
-- - existing active trusted devices forced to re-enroll
--
-- IMPORTANT:
-- This file reflects the exact SQL applied to Staging for this migration.

alter table public.employee_registrations
  add column if not exists trusted_device_fingerprint_hash text,
  add column if not exists trusted_device_expires_at timestamptz;

create or replace function public.hash_trusted_device_fingerprint(p_device_id text)
returns text
language sql
immutable
set search_path = public, extensions
as $$
  select case
    when trim(coalesce(p_device_id, '')) = '' then null
    else encode(extensions.digest('v1|' || trim(p_device_id), 'sha256'), 'hex')
  end;
$$;

revoke all on function public.hash_trusted_device_fingerprint(text) from public;
grant execute on function public.hash_trusted_device_fingerprint(text) to service_role;

create or replace function public.admin_update_registration_status(
  p_registration_id uuid,
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reg record;
begin
  if not (public.is_super_admin() or public.has_admin_permission('can_approve_requests')) then
    return jsonb_build_object('ok', false, 'message', 'غير مصرح لك بالموافقة أو الرفض');
  end if;

  if p_status not in ('APPROVED', 'REJECTED') then
    return jsonb_build_object('ok', false, 'message', 'حالة غير صحيحة');
  end if;

  update public.employee_registrations
  set status = p_status,
      approved_at = case when p_status = 'APPROVED' then now() else approved_at end,
      approved_by = case when p_status = 'APPROVED' then auth.uid() else approved_by end,
      rejected_at = case when p_status = 'REJECTED' then now() else rejected_at end,
      rejected_by = case when p_status = 'REJECTED' then auth.uid() else rejected_by end,

      trusted_device_enabled = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then true
        else trusted_device_enabled
      end,

      trusted_device_token_hash = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then pending_trusted_device_token_hash
        else trusted_device_token_hash
      end,

      trusted_device_fingerprint_hash = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then public.hash_trusted_device_fingerprint(pending_trusted_device_id)
        else trusted_device_fingerprint_hash
      end,

      trusted_device_id = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then pending_trusted_device_id
        else trusted_device_id
      end,

      trusted_device_type = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then pending_trusted_device_type
        else trusted_device_type
      end,

      trusted_device_name = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then pending_trusted_device_name
        else trusted_device_name
      end,

      trusted_device_user_agent = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then pending_trusted_device_user_agent
        else trusted_device_user_agent
      end,

      trusted_device_registered_at = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then now()
        else trusted_device_registered_at
      end,

      trusted_device_expires_at = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then now() + interval '30 days'
        else trusted_device_expires_at
      end,

      trusted_device_revoked_at = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then null
        else trusted_device_revoked_at
      end,

      pending_trusted_device_token_hash = case when p_status = 'APPROVED' then null else pending_trusted_device_token_hash end,
      pending_trusted_device_id = case when p_status = 'APPROVED' then null else pending_trusted_device_id end,
      pending_trusted_device_type = case when p_status = 'APPROVED' then null else pending_trusted_device_type end,
      pending_trusted_device_name = case when p_status = 'APPROVED' then null else pending_trusted_device_name end,
      pending_trusted_device_user_agent = case when p_status = 'APPROVED' then null else pending_trusted_device_user_agent end,
      pending_trusted_device_created_at = case when p_status = 'APPROVED' then null else pending_trusted_device_created_at end
  where id = p_registration_id
  returning * into reg;

  if reg.id is null then
    return jsonb_build_object('ok', false, 'message', 'الموظف غير موجود');
  end if;

  insert into public.admin_audit_logs (
    admin_auth_user_id, action, target_table, target_id, details
  )
  values (
    auth.uid(), 'UPDATE_REGISTRATION_STATUS', 'employee_registrations',
    p_registration_id::text,
    jsonb_build_object(
      'status', p_status,
      'trusted_device_linked',
        reg.trusted_device_token_hash is not null
        and reg.trusted_device_fingerprint_hash is not null
        and reg.trusted_device_expires_at is not null
    )
  );

  return jsonb_build_object('ok', true, 'message', 'تم تحديث الطلب');
end;
$$;

create or replace function public.admin_set_trusted_device_impl(
  p_registration_id uuid,
  p_enabled boolean,
  p_revoke boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reg record;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'message', 'غير مصرح');
  end if;

  select *
  into reg
  from public.employee_registrations
  where id = p_registration_id
  limit 1;

  if reg.id is null then
    return jsonb_build_object('ok', false, 'message', 'الموظف غير موجود');
  end if;

  if p_enabled = true then
    if reg.status <> 'APPROVED' then
      return jsonb_build_object('ok', false, 'message', 'يجب اعتماد الموظف أولًا');
    end if;

    if not public.is_permanently_allowed_specialty(reg.specialty) then
      return jsonb_build_object('ok', false, 'message', 'التحقق السريع مخصص لاختصاص الدخول الدائم فقط');
    end if;
  end if;

  update public.employee_registrations
  set trusted_device_enabled = p_enabled,
      trusted_device_token_hash =
        case when p_revoke or p_enabled = false then null else trusted_device_token_hash end,
      trusted_device_fingerprint_hash =
        case when p_revoke or p_enabled = false then null else trusted_device_fingerprint_hash end,
      trusted_device_expires_at =
        case when p_revoke or p_enabled = false then null else trusted_device_expires_at end,
      trusted_device_registered_at =
        case when p_revoke or p_enabled = false then null else trusted_device_registered_at end,
      trusted_device_last_used_at =
        case when p_revoke or p_enabled = false then null else trusted_device_last_used_at end,
      trusted_device_last_activity_at =
        case when p_revoke or p_enabled = false then null else trusted_device_last_activity_at end,
      trusted_device_id =
        case when p_revoke or p_enabled = false then null else trusted_device_id end,
      trusted_device_type =
        case when p_revoke or p_enabled = false then null else trusted_device_type end,
      trusted_device_name =
        case when p_revoke or p_enabled = false then null else trusted_device_name end,
      trusted_device_user_agent =
        case when p_revoke or p_enabled = false then null else trusted_device_user_agent end,
      trusted_device_revoked_at =
        case when p_revoke or p_enabled = false then now() else trusted_device_revoked_at end
  where id = p_registration_id;

  insert into public.admin_audit_logs (
    admin_auth_user_id, action, target_table, target_id, details
  )
  values (
    auth.uid(), 'ADMIN_SET_TRUSTED_DEVICE', 'employee_registrations',
    p_registration_id::text,
    jsonb_build_object(
      'enabled', p_enabled,
      'revoked', p_revoke,
      'employee_id', reg.employee_id
    )
  );

  return jsonb_build_object(
    'ok', true,
    'message', case
      when p_enabled = false then 'تم تعطيل التحقق السريع وإلغاء ربط الجهاز'
      when p_revoke = true then 'تم إلغاء ربط الجهاز. يستطيع الموظف ربط جهاز جديد بعد إعادة التفعيل.'
      else 'تم تفعيل التحقق السريع. على الموظف إجراء تحقق يدوي مرة واحدة لربط جهازه.'
    end
  );
end;
$$;

create or replace function public.register_trusted_device(
  p_employee_id text,
  p_mobile_number text,
  p_device_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return jsonb_build_object(
    'ok', false,
    'result', 'DENIED',
    'client_update_required', true,
    'message', 'يتطلب ربط الجهاز الموثوق معرف الجهاز. استخدم مسار الربط المحدّث.'
  );
end;
$$;

create or replace function public.register_trusted_device_with_metadata(
  p_employee_id text,
  p_mobile_number text,
  p_device_token text,
  p_device_id text,
  p_device_type text,
  p_device_name text,
  p_user_agent text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reg public.employee_registrations%rowtype;
  clean_emp text := trim(coalesce(p_employee_id, ''));
  clean_mobile text := trim(coalesce(p_mobile_number, ''));
  clean_token text := trim(coalesce(p_device_token, ''));
  clean_device_id text := trim(coalesce(p_device_id, ''));
  clean_device_type text := nullif(trim(coalesce(p_device_type, '')), '');
  clean_device_name text := nullif(trim(coalesce(p_device_name, '')), '');
  clean_user_agent text := nullif(trim(coalesce(p_user_agent, '')), '');
  token_hash text;
  fingerprint_hash text;
  expiry timestamptz;
begin
  if clean_emp = ''
     or clean_mobile = ''
     or length(clean_token) < 40
     or clean_device_id = '' then
    return jsonb_build_object(
      'ok', false,
      'result', 'DENIED',
      'message', 'بيانات تفعيل الجهاز غير مكتملة'
    );
  end if;

  select *
  into reg
  from public.employee_registrations
  where employee_id = clean_emp
    and mobile_number = clean_mobile
  limit 1
  for update;

  if reg.id is null
     or reg.status <> 'APPROVED'
     or not coalesce(reg.trusted_device_enabled, false)
     or not public.is_permanently_allowed_specialty(reg.specialty) then
    return jsonb_build_object('ok', false, 'result', 'DENIED', 'message', 'الجهاز غير مؤهل للربط');
  end if;

  token_hash := public.hash_trusted_device_token(clean_token);
  fingerprint_hash := public.hash_trusted_device_fingerprint(clean_device_id);

  if fingerprint_hash is null then
    return jsonb_build_object('ok', false, 'result', 'DENIED', 'message', 'معرف الجهاز غير صالح');
  end if;

  if reg.trusted_device_token_hash is not null
     and reg.trusted_device_fingerprint_hash is null then
    return jsonb_build_object(
      'ok', false,
      'result', 'DENIED',
      'admin_reset_required', true,
      'message', 'ربط الجهاز القديم يحتاج إعادة تفعيل من الإدارة'
    );
  end if;

  if reg.trusted_device_fingerprint_hash is not null
     and reg.trusted_device_fingerprint_hash <> fingerprint_hash then
    return jsonb_build_object(
      'ok', false,
      'result', 'DENIED',
      'new_device', true,
      'message', 'تم اكتشاف جهاز مختلف. يجب إلغاء ربط الجهاز السابق من الإدارة أولًا.'
    );
  end if;

  if reg.trusted_device_token_hash is not null
     and reg.trusted_device_token_hash <> token_hash
     and (reg.trusted_device_expires_at is null or reg.trusted_device_expires_at > now()) then
    return jsonb_build_object(
      'ok', false,
      'result', 'DENIED',
      'new_device', true,
      'message', 'رمز جهاز مختلف قبل انتهاء الربط الحالي. يجب إلغاء الربط السابق أولًا.'
    );
  end if;

  expiry := now() + interval '30 days';

  update public.employee_registrations
  set trusted_device_token_hash = token_hash,
      trusted_device_fingerprint_hash = fingerprint_hash,
      trusted_device_registered_at = now(),
      trusted_device_expires_at = expiry,
      trusted_device_revoked_at = null,
      trusted_device_id = clean_device_id,
      trusted_device_type = clean_device_type,
      trusted_device_name = clean_device_name,
      trusted_device_user_agent = clean_user_agent,
      trusted_device_last_activity_at = now()
  where id = reg.id;

  insert into public.admin_audit_logs (
    admin_auth_user_id, action, target_table, target_id, details
  )
  values (
    null,
    'TRUSTED_DEVICE_BOUND',
    'employee_registrations',
    reg.id::text,
    jsonb_build_object(
      'employee_id', reg.employee_id,
      'device_id', clean_device_id,
      'expires_at', expiry
    )
  );

  return jsonb_build_object(
    'ok', true,
    'message', 'تم ربط الجهاز الموثوق لمدة 30 يومًا',
    'device_id', clean_device_id,
    'expires_at', expiry
  );
exception when others then
  return jsonb_build_object('ok', false, 'result', 'DENIED', 'message', 'تعذر حفظ بيانات الجهاز الموثوق');
end;
$$;

create or replace function public.trusted_device_profile_login(p_device_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return jsonb_build_object(
    'ok', false,
    'clear_device', true,
    'client_update_required', true,
    'message', 'تسجيل الدخول السريع يتطلب التحقق من معرف الجهاز'
  );
end;
$$;

create or replace function public.trusted_device_profile_login(
  p_device_token text,
  p_device_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reg public.employee_registrations%rowtype;
  clean_token text := trim(coalesce(p_device_token, ''));
  clean_device_id text := trim(coalesce(p_device_id, ''));
  fingerprint_hash text;
begin
  if length(clean_token) < 40 or clean_device_id = '' then
    return jsonb_build_object('ok', false, 'clear_device', true, 'message', 'بيانات الجهاز غير صالحة');
  end if;

  fingerprint_hash := public.hash_trusted_device_fingerprint(clean_device_id);

  select *
  into reg
  from public.employee_registrations
  where trusted_device_token_hash = public.hash_trusted_device_token(clean_token)
  limit 1;

  if reg.id is null then
    return jsonb_build_object('ok', false, 'clear_device', true, 'message', 'الجهاز غير مربوط أو تم إلغاء اعتماده');
  end if;

  if reg.status <> 'APPROVED'
     or not coalesce(reg.trusted_device_enabled, false)
     or reg.trusted_device_revoked_at is not null then
    return jsonb_build_object('ok', false, 'clear_device', true, 'message', 'الجهاز غير مفعّل أو تم إلغاء اعتماده');
  end if;

  if reg.trusted_device_expires_at is null
     or reg.trusted_device_expires_at <= now() then
    insert into public.admin_audit_logs (
      admin_auth_user_id, action, target_table, target_id, details
    )
    values (
      null, 'TRUSTED_DEVICE_AUTH_FAILED', 'employee_registrations', reg.id::text,
      jsonb_build_object('reason', 'EXPIRED', 'employee_id', reg.employee_id)
    );
    return jsonb_build_object(
      'ok', false,
      'clear_device', true,
      'expired', true,
      'message', 'انتهت صلاحية الجهاز الموثوق. أعد التفعيل.'
    );
  end if;

  if reg.trusted_device_fingerprint_hash is null
     or reg.trusted_device_fingerprint_hash <> fingerprint_hash then
    insert into public.admin_audit_logs (
      admin_auth_user_id, action, target_table, target_id, details
    )
    values (
      null, 'TRUSTED_DEVICE_AUTH_FAILED', 'employee_registrations', reg.id::text,
      jsonb_build_object('reason', 'FINGERPRINT_MISMATCH', 'employee_id', reg.employee_id)
    );
    return jsonb_build_object(
      'ok', false,
      'clear_device', true,
      'fingerprint_mismatch', true,
      'message', 'بصمة الجهاز لا تطابق الجهاز الموثوق'
    );
  end if;

  update public.employee_registrations
  set trusted_device_last_used_at = now(),
      trusted_device_last_activity_at = now()
  where id = reg.id;

  insert into public.admin_audit_logs (
    admin_auth_user_id, action, target_table, target_id, details
  )
  values (
    null, 'TRUSTED_DEVICE_FAST_LOGIN', 'employee_registrations', reg.id::text,
    jsonb_build_object(
      'device_id', reg.trusted_device_id,
      'employee_id', reg.employee_id,
      'expires_at', reg.trusted_device_expires_at
    )
  );

  return jsonb_build_object(
    'ok', true,
    'expires_at', reg.trusted_device_expires_at,
    'profile', jsonb_build_object(
      'employee_id', reg.employee_id,
      'mobile_number', reg.mobile_number,
      'full_name', reg.full_name,
      'job_type', coalesce(reg.job_type, ''),
      'department', coalesce(reg.department, ''),
      'specialty', reg.specialty,
      'status', reg.status
    )
  );
end;
$$;

create or replace function public.auto_employee_check(
  p_device_token text,
  p_qr_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return jsonb_build_object(
    'ok', false,
    'result', 'DENIED',
    'clear_device', true,
    'client_update_required', true,
    'message', 'التحقق التلقائي يتطلب معرف الجهاز'
  );
end;
$$;

create or replace function public.auto_employee_check(
  p_device_token text,
  p_qr_token text,
  p_device_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reg public.employee_registrations%rowtype;
  check_result jsonb;
  clean_token text := trim(coalesce(p_device_token, ''));
  clean_device_id text := trim(coalesce(p_device_id, ''));
  fingerprint_hash text;
begin
  if length(clean_token) < 40 or clean_device_id = '' then
    return jsonb_build_object('ok', false, 'result', 'DENIED', 'clear_device', true, 'message', 'بيانات الجهاز غير صالحة');
  end if;

  fingerprint_hash := public.hash_trusted_device_fingerprint(clean_device_id);

  select *
  into reg
  from public.employee_registrations
  where trusted_device_token_hash = public.hash_trusted_device_token(clean_token)
     or pending_trusted_device_token_hash = public.hash_trusted_device_token(clean_token)
  limit 1;

  if reg.id is null then
    return jsonb_build_object('ok', true, 'result', 'DENIED', 'clear_device', true, 'message', 'هذا الجهاز غير مربوط أو تم إلغاء ربطه');
  end if;

  if reg.status <> 'APPROVED' then
    return jsonb_build_object('ok', true, 'result', 'DENIED', 'clear_device', false, 'message', 'طلب الموظف لم يعتمد بعد');
  end if;

  if not coalesce(reg.trusted_device_enabled, false)
     or reg.trusted_device_revoked_at is not null then
    return jsonb_build_object('ok', true, 'result', 'DENIED', 'clear_device', true, 'message', 'الجهاز محفوظ لكنه غير مفعّل');
  end if;

  if reg.trusted_device_expires_at is null
     or reg.trusted_device_expires_at <= now() then
    insert into public.admin_audit_logs (
      admin_auth_user_id, action, target_table, target_id, details
    )
    values (
      null, 'TRUSTED_DEVICE_AUTH_FAILED', 'employee_registrations', reg.id::text,
      jsonb_build_object('reason', 'EXPIRED', 'employee_id', reg.employee_id, 'source', 'auto_employee_check')
    );
    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'clear_device', true,
      'expired', true,
      'message', 'انتهت صلاحية الجهاز الموثوق. أعد التفعيل.'
    );
  end if;

  if reg.trusted_device_fingerprint_hash is null
     or reg.trusted_device_fingerprint_hash <> fingerprint_hash then
    insert into public.admin_audit_logs (
      admin_auth_user_id, action, target_table, target_id, details
    )
    values (
      null, 'TRUSTED_DEVICE_AUTH_FAILED', 'employee_registrations', reg.id::text,
      jsonb_build_object('reason', 'FINGERPRINT_MISMATCH', 'employee_id', reg.employee_id, 'source', 'auto_employee_check')
    );
    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'clear_device', true,
      'fingerprint_mismatch', true,
      'message', 'بصمة الجهاز لا تطابق الجهاز الموثوق'
    );
  end if;

  check_result := public.manual_employee_check(reg.employee_id, reg.mobile_number, p_qr_token);

  if (check_result->>'ok')::boolean = true
     and coalesce(check_result->>'result', '') in ('ALLOWED', 'LIMITED') then
    update public.employee_registrations
    set trusted_device_last_used_at = now(),
        trusted_device_last_activity_at = now()
    where id = reg.id;
  end if;

  return check_result || jsonb_build_object(
    'trusted_device_expires_at', reg.trusted_device_expires_at,
    'employee',
    jsonb_build_object(
      'full_name', reg.full_name,
      'employee_id', reg.employee_id,
      'mobile_number', reg.mobile_number,
      'department', coalesce(reg.department, ''),
      'specialty', reg.specialty,
      'job_type', coalesce(reg.job_type, ''),
      'employee_photo_url', coalesce(reg.employee_photo_url, '')
    )
  );
end;
$$;

create or replace function public.verify_trusted_device_credentials(p_device_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return jsonb_build_object('ok', false, 'reason', 'DEVICE_ID_REQUIRED');
end;
$$;

create or replace function public.verify_trusted_device_credentials(
  p_device_token text,
  p_device_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_token text := trim(coalesce(p_device_token, ''));
  clean_device_id text := trim(coalesce(p_device_id, ''));
  fingerprint_hash text;
  reg public.employee_registrations%rowtype;
begin
  if length(clean_token) < 40 or clean_device_id = '' then
    return jsonb_build_object('ok', false, 'reason', 'INVALID_DEVICE_CREDENTIALS');
  end if;

  fingerprint_hash := public.hash_trusted_device_fingerprint(clean_device_id);

  select *
  into reg
  from public.employee_registrations
  where trusted_device_token_hash = public.hash_trusted_device_token(clean_token)
  limit 1;

  if reg.id is null
     or reg.status <> 'APPROVED'
     or not coalesce(reg.trusted_device_enabled, false)
     or reg.trusted_device_revoked_at is not null
     or reg.trusted_device_expires_at is null
     or reg.trusted_device_expires_at <= now()
     or reg.trusted_device_fingerprint_hash is null
     or reg.trusted_device_fingerprint_hash <> fingerprint_hash then
    return jsonb_build_object('ok', false, 'reason', 'DEVICE_NOT_TRUSTED');
  end if;

  return jsonb_build_object(
    'ok', true,
    'employee_id', reg.employee_id,
    'expires_at', reg.trusted_device_expires_at
  );
end;
$$;

revoke all on function public.verify_trusted_device_credentials(text, text) from public, anon, authenticated;
grant execute on function public.verify_trusted_device_credentials(text, text) to service_role;

grant execute on function public.trusted_device_profile_login(text, text) to anon, authenticated;
grant execute on function public.auto_employee_check(text, text, text) to anon, authenticated;


DO $$ BEGIN
 IF EXISTS(select 1 from public.employee_registrations where trusted_device_token_hash is not null and nullif(trim(trusted_device_id),'') is null) THEN
 RAISE EXCEPTION 'Cannot preserve binding without a stored device ID'; END IF;
END $$;
update public.employee_registrations set
trusted_device_fingerprint_hash=public.hash_trusted_device_fingerprint(trusted_device_id),
trusted_device_expires_at=case when status='APPROVED' and trusted_device_enabled and trusted_device_revoked_at is null then 'infinity'::timestamptz else null end
where trusted_device_token_hash is not null;

-- P2-18 Trusted Device enrollment-claim + ACL hardening
-- Applied to Supabase Staging as migration:
-- 20261007101501_p2_18_enrollment_claim_acl_hardening
--
-- Security model:
-- successful QR access -> 2-minute single-use claim bound to device_id fingerprint
-- -> claim required to bind/renew a Trusted Device.
-- public.manual_employee_check remains unchanged; the wrapper preserves P0-3 order.

create table if not exists public.trusted_device_enrollment_claims (
  id uuid primary key default gen_random_uuid(),
  employee_registration_id uuid not null
    references public.employee_registrations(id) on delete cascade,
  claim_hash text not null unique,
  device_fingerprint_hash text not null,
  access_result text not null check (access_result in ('ALLOWED','LIMITED')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz
);

create index if not exists idx_trusted_device_enrollment_claims_employee
  on public.trusted_device_enrollment_claims(employee_registration_id);
create index if not exists idx_trusted_device_enrollment_claims_expiry
  on public.trusted_device_enrollment_claims(expires_at);

alter table public.trusted_device_enrollment_claims enable row level security;
revoke all on table public.trusted_device_enrollment_claims from public, anon, authenticated;

create or replace function public.manual_employee_check_with_device(
  p_employee_id text,
  p_mobile_number text,
  p_qr_token text,
  p_device_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  check_result jsonb;
  reg public.employee_registrations%rowtype;
  clean_emp text := trim(coalesce(p_employee_id, ''));
  clean_mobile text := trim(coalesce(p_mobile_number, ''));
  clean_device_id text := trim(coalesce(p_device_id, ''));
  fingerprint_hash text;
  raw_claim text;
  claim_hash text;
  claim_expiry timestamptz;
begin
  if clean_device_id = '' then
    return jsonb_build_object('ok', false, 'result', 'DENIED', 'message', 'معرف الجهاز مطلوب للتحقق');
  end if;

  check_result := public.manual_employee_check(clean_emp, clean_mobile, p_qr_token);

  if coalesce((check_result->>'ok')::boolean, false) is not true
     or coalesce(check_result->>'result', '') not in ('ALLOWED','LIMITED') then
    return check_result;
  end if;

  select * into reg
  from public.employee_registrations
  where employee_id = clean_emp and mobile_number = clean_mobile
  limit 1;

  if reg.id is null
     or reg.status <> 'APPROVED'
     or not coalesce(reg.trusted_device_enabled, false)
     or not public.is_permanently_allowed_specialty(reg.specialty) then
    return check_result || jsonb_build_object('trusted_device_enrollment_eligible', false);
  end if;

  fingerprint_hash := public.hash_trusted_device_fingerprint(clean_device_id);
  if fingerprint_hash is null then
    return check_result || jsonb_build_object('trusted_device_enrollment_eligible', false);
  end if;

  if reg.trusted_device_fingerprint_hash is not null
     and reg.trusted_device_fingerprint_hash <> fingerprint_hash then
    return check_result || jsonb_build_object(
      'trusted_device_enrollment_eligible', false,
      'trusted_device_new_device', true,
      'trusted_device_message', 'الجهاز الحالي مختلف عن الجهاز المعتمد. يلزم إلغاء الربط من الإدارة أولًا.'
    );
  end if;

  if reg.trusted_device_token_hash is not null
     and reg.trusted_device_expires_at is not null
     and reg.trusted_device_expires_at > now()
     and reg.trusted_device_revoked_at is null then
    return check_result || jsonb_build_object(
      'trusted_device_enrollment_eligible', false,
      'trusted_device_already_linked', true,
      'trusted_device_expires_at', reg.trusted_device_expires_at
    );
  end if;

  update public.trusted_device_enrollment_claims
  set consumed_at = now()
  where employee_registration_id = reg.id and consumed_at is null;

  delete from public.trusted_device_enrollment_claims
  where expires_at < now() - interval '1 day'
     or consumed_at < now() - interval '1 day';

  raw_claim := encode(extensions.gen_random_bytes(32), 'hex');
  claim_hash := encode(extensions.digest(raw_claim, 'sha256'), 'hex');
  claim_expiry := now() + interval '2 minutes';

  insert into public.trusted_device_enrollment_claims (
    employee_registration_id, claim_hash, device_fingerprint_hash, access_result, expires_at
  ) values (
    reg.id, claim_hash, fingerprint_hash, check_result->>'result', claim_expiry
  );

  insert into public.admin_audit_logs (
    admin_auth_user_id, action, target_table, target_id, details
  ) values (
    null,
    'TRUSTED_DEVICE_ENROLLMENT_CLAIM_ISSUED',
    'employee_registrations',
    reg.id::text,
    jsonb_build_object(
      'employee_id', reg.employee_id,
      'expires_at', claim_expiry,
      'access_result', check_result->>'result'
    )
  );

  return check_result || jsonb_build_object(
    'trusted_device_enrollment_eligible', true,
    'trusted_device_enrollment_claim', raw_claim,
    'trusted_device_enrollment_claim_expires_at', claim_expiry
  );
end;
$$;

create or replace function public.register_trusted_device_with_metadata(
  p_employee_id text,
  p_mobile_number text,
  p_device_token text,
  p_device_id text,
  p_device_type text,
  p_device_name text,
  p_user_agent text,
  p_enrollment_claim text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reg public.employee_registrations%rowtype;
  claim_row public.trusted_device_enrollment_claims%rowtype;
  clean_emp text := trim(coalesce(p_employee_id, ''));
  clean_mobile text := trim(coalesce(p_mobile_number, ''));
  clean_token text := trim(coalesce(p_device_token, ''));
  clean_device_id text := trim(coalesce(p_device_id, ''));
  clean_device_type text := nullif(trim(coalesce(p_device_type, '')), '');
  clean_device_name text := nullif(trim(coalesce(p_device_name, '')), '');
  clean_user_agent text := nullif(trim(coalesce(p_user_agent, '')), '');
  clean_claim text := trim(coalesce(p_enrollment_claim, ''));
  token_hash text;
  fingerprint_hash text;
  enrollment_claim_hash text;
  expiry timestamptz;
begin
  if clean_emp = '' or clean_mobile = '' or length(clean_token) < 40
     or clean_device_id = '' or length(clean_claim) < 40 then
    return jsonb_build_object('ok', false, 'result', 'DENIED', 'message', 'بيانات تفعيل الجهاز غير مكتملة');
  end if;

  select * into reg
  from public.employee_registrations
  where employee_id = clean_emp and mobile_number = clean_mobile
  limit 1 for update;

  if reg.id is null
     or reg.status <> 'APPROVED'
     or not coalesce(reg.trusted_device_enabled, false)
     or not public.is_permanently_allowed_specialty(reg.specialty) then
    return jsonb_build_object('ok', false, 'result', 'DENIED', 'message', 'الجهاز غير مؤهل للربط');
  end if;

  token_hash := public.hash_trusted_device_token(clean_token);
  fingerprint_hash := public.hash_trusted_device_fingerprint(clean_device_id);
  enrollment_claim_hash := encode(extensions.digest(clean_claim, 'sha256'), 'hex');

  if fingerprint_hash is null then
    return jsonb_build_object('ok', false, 'result', 'DENIED', 'message', 'معرف الجهاز غير صالح');
  end if;

  select * into claim_row
  from public.trusted_device_enrollment_claims
  where claim_hash = enrollment_claim_hash
    and employee_registration_id = reg.id
  limit 1 for update;

  if claim_row.id is null or claim_row.consumed_at is not null or claim_row.expires_at <= now() then
    return jsonb_build_object(
      'ok', false, 'result', 'DENIED', 'enrollment_claim_invalid', true,
      'message', 'انتهت أو استُخدمت صلاحية تفعيل الجهاز. أعد التحقق عبر QR.'
    );
  end if;

  if claim_row.device_fingerprint_hash <> fingerprint_hash then
    return jsonb_build_object(
      'ok', false, 'result', 'DENIED', 'fingerprint_mismatch', true,
      'message', 'طلب التفعيل لا يخص هذا الجهاز'
    );
  end if;

  if reg.trusted_device_fingerprint_hash is not null
     and reg.trusted_device_fingerprint_hash <> fingerprint_hash then
    return jsonb_build_object(
      'ok', false, 'result', 'DENIED', 'new_device', true, 'admin_reset_required', true,
      'message', 'تم اكتشاف جهاز مختلف. يجب إلغاء ربط الجهاز السابق من الإدارة أولًا.'
    );
  end if;

  if reg.trusted_device_token_hash is not null
     and reg.trusted_device_expires_at is not null
     and reg.trusted_device_expires_at > now()
     and reg.trusted_device_revoked_at is null then
    return jsonb_build_object(
      'ok', false, 'result', 'DENIED', 'already_linked', true,
      'message', 'يوجد جهاز موثوق فعال بالفعل'
    );
  end if;

  expiry := now() + interval '30 days';

  update public.employee_registrations
  set trusted_device_token_hash = token_hash,
      trusted_device_fingerprint_hash = fingerprint_hash,
      trusted_device_registered_at = now(),
      trusted_device_expires_at = expiry,
      trusted_device_revoked_at = null,
      trusted_device_id = clean_device_id,
      trusted_device_type = clean_device_type,
      trusted_device_name = clean_device_name,
      trusted_device_user_agent = clean_user_agent,
      trusted_device_last_activity_at = now()
  where id = reg.id;

  update public.trusted_device_enrollment_claims
  set consumed_at = now()
  where id = claim_row.id and consumed_at is null;

  if not found then
    raise exception 'enrollment claim race detected';
  end if;

  insert into public.admin_audit_logs (
    admin_auth_user_id, action, target_table, target_id, details
  ) values (
    null,
    'TRUSTED_DEVICE_BOUND',
    'employee_registrations',
    reg.id::text,
    jsonb_build_object(
      'employee_id', reg.employee_id,
      'device_id', clean_device_id,
      'expires_at', expiry,
      'claim_id', claim_row.id
    )
  );

  return jsonb_build_object(
    'ok', true,
    'message', 'تم ربط الجهاز الموثوق لمدة 30 يومًا',
    'device_id', clean_device_id,
    'expires_at', expiry
  );
exception when others then
  return jsonb_build_object('ok', false, 'result', 'DENIED', 'message', 'تعذر حفظ بيانات الجهاز الموثوق');
end;
$$;

create or replace function public.register_trusted_device_with_metadata(
  p_employee_id text,
  p_mobile_number text,
  p_device_token text,
  p_device_id text,
  p_device_type text,
  p_device_name text,
  p_user_agent text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return jsonb_build_object(
    'ok', false, 'result', 'DENIED',
    'enrollment_claim_required', true,
    'client_update_required', true,
    'message', 'يتطلب تفعيل الجهاز تحقق QR ناجحًا وصلاحية تفعيل قصيرة المدة'
  );
end;
$$;

create or replace function public.register_trusted_device(
  p_employee_id text,
  p_mobile_number text,
  p_device_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return jsonb_build_object(
    'ok', false, 'result', 'DENIED',
    'enrollment_claim_required', true,
    'client_update_required', true,
    'message', 'يتطلب تفعيل الجهاز تحقق QR ناجحًا ومعرف الجهاز'
  );
end;
$$;

create or replace function public.admin_update_registration_status(
  p_registration_id uuid,
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reg record;
begin
  if not (public.is_super_admin() or public.has_admin_permission('can_approve_requests')) then
    return jsonb_build_object('ok', false, 'message', 'غير مصرح لك بالموافقة أو الرفض');
  end if;

  if p_status not in ('APPROVED', 'REJECTED') then
    return jsonb_build_object('ok', false, 'message', 'حالة غير صحيحة');
  end if;

  update public.employee_registrations
  set status = p_status,
      approved_at = case when p_status = 'APPROVED' then now() else approved_at end,
      approved_by = case when p_status = 'APPROVED' then auth.uid() else approved_by end,
      rejected_at = case when p_status = 'REJECTED' then now() else rejected_at end,
      rejected_by = case when p_status = 'REJECTED' then auth.uid() else rejected_by end,
      trusted_device_enabled = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then true else trusted_device_enabled end,
      trusted_device_token_hash = case
        when p_status = 'APPROVED' and pending_trusted_device_token_hash is not null
        then null else trusted_device_token_hash end,
      trusted_device_fingerprint_hash = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then public.hash_trusted_device_fingerprint(pending_trusted_device_id)
        else trusted_device_fingerprint_hash end,
      trusted_device_id = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then pending_trusted_device_id else trusted_device_id end,
      trusted_device_type = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then pending_trusted_device_type else trusted_device_type end,
      trusted_device_name = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then pending_trusted_device_name else trusted_device_name end,
      trusted_device_user_agent = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then pending_trusted_device_user_agent else trusted_device_user_agent end,
      trusted_device_registered_at = case
        when p_status = 'APPROVED' and pending_trusted_device_token_hash is not null
        then null else trusted_device_registered_at end,
      trusted_device_expires_at = case
        when p_status = 'APPROVED' and pending_trusted_device_token_hash is not null
        then null else trusted_device_expires_at end,
      trusted_device_revoked_at = case
        when p_status = 'APPROVED' and pending_trusted_device_token_hash is not null
        then null else trusted_device_revoked_at end,
      pending_trusted_device_token_hash = case when p_status = 'APPROVED' then null else pending_trusted_device_token_hash end,
      pending_trusted_device_id = case when p_status = 'APPROVED' then null else pending_trusted_device_id end,
      pending_trusted_device_type = case when p_status = 'APPROVED' then null else pending_trusted_device_type end,
      pending_trusted_device_name = case when p_status = 'APPROVED' then null else pending_trusted_device_name end,
      pending_trusted_device_user_agent = case when p_status = 'APPROVED' then null else pending_trusted_device_user_agent end,
      pending_trusted_device_created_at = case when p_status = 'APPROVED' then null else pending_trusted_device_created_at end
  where id = p_registration_id
  returning * into reg;

  if reg.id is null then
    return jsonb_build_object('ok', false, 'message', 'الموظف غير موجود');
  end if;

  insert into public.admin_audit_logs (
    admin_auth_user_id, action, target_table, target_id, details
  ) values (
    auth.uid(), 'UPDATE_REGISTRATION_STATUS', 'employee_registrations', p_registration_id::text,
    jsonb_build_object(
      'status', p_status,
      'trusted_device_enrollment_required',
        p_status = 'APPROVED' and reg.trusted_device_enabled = true and reg.trusted_device_token_hash is null
    )
  );

  return jsonb_build_object('ok', true, 'message', 'تم تحديث الطلب');
end;
$$;

revoke all on function public.manual_employee_check_with_device(text,text,text,text) from public, anon, authenticated;
grant execute on function public.manual_employee_check_with_device(text,text,text,text) to anon, authenticated;

revoke all on function public.register_trusted_device_with_metadata(text,text,text,text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.register_trusted_device_with_metadata(text,text,text,text,text,text,text,text) to anon, authenticated;

revoke all on function public.register_trusted_device_with_metadata(text,text,text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.register_trusted_device_with_metadata(text,text,text,text,text,text,text) to anon, authenticated;

revoke all on function public.register_trusted_device(text,text,text) from public, anon, authenticated;
grant execute on function public.register_trusted_device(text,text,text) to anon, authenticated;

revoke all on function public.trusted_device_profile_login(text) from public, anon, authenticated;
grant execute on function public.trusted_device_profile_login(text) to anon, authenticated;

revoke all on function public.trusted_device_profile_login(text,text) from public, anon, authenticated;
grant execute on function public.trusted_device_profile_login(text,text) to anon, authenticated;

revoke all on function public.auto_employee_check(text,text) from public, anon, authenticated;
grant execute on function public.auto_employee_check(text,text) to anon, authenticated;

revoke all on function public.auto_employee_check(text,text,text) from public, anon, authenticated;
grant execute on function public.auto_employee_check(text,text,text) to anon, authenticated;

revoke all on function public.can_register_trusted_device(text,text) from public, anon, authenticated;
grant execute on function public.can_register_trusted_device(text,text) to anon, authenticated;

revoke all on function public.admin_update_registration_status(uuid,text) from public, anon, authenticated;
grant execute on function public.admin_update_registration_status(uuid,text) to authenticated;

revoke all on function public.admin_set_trusted_device(uuid,boolean,boolean) from public, anon, authenticated;
grant execute on function public.admin_set_trusted_device(uuid,boolean,boolean) to authenticated;

notify pgrst, 'reload schema';

-- Owner-approved policy: admin approval activates only the registration-time device.
-- No table/RLS/grant changes; QR remains mandatory for gate access.
CREATE OR REPLACE FUNCTION public.admin_update_registration_status(p_registration_id uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  reg record;
begin
  if not (public.is_super_admin() or public.has_admin_permission('can_approve_requests')) then
    return jsonb_build_object('ok', false, 'message', 'غير مصرح لك بالموافقة أو الرفض');
  end if;

  if p_status not in ('APPROVED', 'REJECTED') then
    return jsonb_build_object('ok', false, 'message', 'حالة غير صحيحة');
  end if;

  update public.employee_registrations
  set status = p_status,
      approved_at = case when p_status = 'APPROVED' then now() else approved_at end,
      approved_by = case when p_status = 'APPROVED' then auth.uid() else approved_by end,
      rejected_at = case when p_status = 'REJECTED' then now() else rejected_at end,
      rejected_by = case when p_status = 'REJECTED' then auth.uid() else rejected_by end,

      trusted_device_enabled = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then true
        else trusted_device_enabled
      end,

      -- Owner decision: activate only the device submitted with the registration.
      trusted_device_token_hash = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then pending_trusted_device_token_hash
        else trusted_device_token_hash
      end,

      trusted_device_fingerprint_hash = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then public.hash_trusted_device_fingerprint(pending_trusted_device_id)
        else trusted_device_fingerprint_hash
      end,

      trusted_device_id = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then pending_trusted_device_id
        else trusted_device_id
      end,

      trusted_device_type = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then pending_trusted_device_type
        else trusted_device_type
      end,

      trusted_device_name = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then pending_trusted_device_name
        else trusted_device_name
      end,

      trusted_device_user_agent = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then pending_trusted_device_user_agent
        else trusted_device_user_agent
      end,

      trusted_device_registered_at = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then now()
        else trusted_device_registered_at
      end,

      trusted_device_expires_at = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then now() + interval '30 days'
        else trusted_device_expires_at
      end,

      trusted_device_revoked_at = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
        then null
        else trusted_device_revoked_at
      end,

      pending_trusted_device_token_hash = case when p_status = 'APPROVED' then null else pending_trusted_device_token_hash end,
      pending_trusted_device_id = case when p_status = 'APPROVED' then null else pending_trusted_device_id end,
      pending_trusted_device_type = case when p_status = 'APPROVED' then null else pending_trusted_device_type end,
      pending_trusted_device_name = case when p_status = 'APPROVED' then null else pending_trusted_device_name end,
      pending_trusted_device_user_agent = case when p_status = 'APPROVED' then null else pending_trusted_device_user_agent end,
      pending_trusted_device_created_at = case when p_status = 'APPROVED' then null else pending_trusted_device_created_at end
  where id = p_registration_id
  returning * into reg;

  if reg.id is null then
    return jsonb_build_object('ok', false, 'message', 'الموظف غير موجود');
  end if;

  insert into public.admin_audit_logs (
    admin_auth_user_id, action, target_table, target_id, details
  )
  values (
    auth.uid(),
    'UPDATE_REGISTRATION_STATUS',
    'employee_registrations',
    p_registration_id::text,
    jsonb_build_object(
      'status', p_status,
      'trusted_device_enrollment_required',
        p_status = 'APPROVED'
        and reg.trusted_device_enabled = true
        and reg.trusted_device_token_hash is null
    )
  );

  return jsonb_build_object('ok', true, 'message', 'تم تحديث الطلب');
end;
$function$;

CREATE OR REPLACE FUNCTION public.trusted_device_profile_login(p_device_token text, p_device_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  reg public.employee_registrations%rowtype;
  clean_token text := trim(coalesce(p_device_token, ''));
  clean_device_id text := trim(coalesce(p_device_id, ''));
  fingerprint_hash text;
begin
  if length(clean_token) < 40 or clean_device_id = '' then
    return jsonb_build_object('ok', false, 'clear_device', true, 'message', 'بيانات الجهاز غير صالحة');
  end if;

  fingerprint_hash := public.hash_trusted_device_fingerprint(clean_device_id);

  select *
  into reg
  from public.employee_registrations
  where trusted_device_token_hash = public.hash_trusted_device_token(clean_token)
  limit 1;

  -- Preserve the submitted browser token while the administrator reviews it.
  -- This grants no session or employee data.
  if reg.id is null and exists (
    select 1 from public.employee_registrations pending
    where pending.status = 'PENDING'
      and pending.pending_trusted_device_token_hash = public.hash_trusted_device_token(clean_token)
      and public.hash_trusted_device_fingerprint(pending.pending_trusted_device_id) = fingerprint_hash
  ) then
    return jsonb_build_object('ok', false, 'clear_device', false, 'pending', true,
      'message', 'طلب التسجيل والجهاز بانتظار موافقة الإدارة');
  end if;

  if reg.id is null then
    return jsonb_build_object('ok', false, 'clear_device', true, 'message', 'الجهاز غير مربوط أو تم إلغاء اعتماده');
  end if;

  if reg.status <> 'APPROVED'
     or not coalesce(reg.trusted_device_enabled, false)
     or reg.trusted_device_revoked_at is not null then
    return jsonb_build_object('ok', false, 'clear_device', true, 'message', 'الجهاز غير مفعّل أو تم إلغاء اعتماده');
  end if;

  if reg.trusted_device_expires_at is null
     or reg.trusted_device_expires_at <= now() then
    insert into public.admin_audit_logs (
      admin_auth_user_id, action, target_table, target_id, details
    )
    values (
      null, 'TRUSTED_DEVICE_AUTH_FAILED', 'employee_registrations', reg.id::text,
      jsonb_build_object('reason', 'EXPIRED', 'employee_id', reg.employee_id)
    );
    return jsonb_build_object(
      'ok', false,
      'clear_device', true,
      'expired', true,
      'message', 'انتهت صلاحية الجهاز الموثوق. أعد التفعيل.'
    );
  end if;

  if reg.trusted_device_fingerprint_hash is null
     or reg.trusted_device_fingerprint_hash <> fingerprint_hash then
    insert into public.admin_audit_logs (
      admin_auth_user_id, action, target_table, target_id, details
    )
    values (
      null, 'TRUSTED_DEVICE_AUTH_FAILED', 'employee_registrations', reg.id::text,
      jsonb_build_object('reason', 'FINGERPRINT_MISMATCH', 'employee_id', reg.employee_id)
    );
    return jsonb_build_object(
      'ok', false,
      'clear_device', true,
      'fingerprint_mismatch', true,
      'message', 'بصمة الجهاز لا تطابق الجهاز الموثوق'
    );
  end if;

  update public.employee_registrations
  set trusted_device_last_used_at = now(),
      trusted_device_last_activity_at = now()
  where id = reg.id;

  insert into public.admin_audit_logs (
    admin_auth_user_id, action, target_table, target_id, details
  )
  values (
    null, 'TRUSTED_DEVICE_FAST_LOGIN', 'employee_registrations', reg.id::text,
    jsonb_build_object(
      'device_id', reg.trusted_device_id,
      'employee_id', reg.employee_id,
      'expires_at', reg.trusted_device_expires_at
    )
  );

  return jsonb_build_object(
    'ok', true,
    'expires_at', reg.trusted_device_expires_at,
    'profile', jsonb_build_object(
      'employee_id', reg.employee_id,
      'mobile_number', reg.mobile_number,
      'full_name', reg.full_name,
      'job_type', coalesce(reg.job_type, ''),
      'department', coalesce(reg.department, ''),
      'specialty', reg.specialty,
      'status', reg.status
    )
  );
end;
$function$;

-- Owner decision 2026-10-07: no time expiry for an approved bound device.
-- PostgreSQL infinity preserves fail-closed NULL handling and existing readers.
-- QR, employee status, device fingerprint and admin revocation checks unchanged.

CREATE OR REPLACE FUNCTION public.admin_update_registration_status(p_registration_id uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  reg record;
begin
  if not (public.is_super_admin() or public.has_admin_permission('can_approve_requests')) then
    return jsonb_build_object('ok', false, 'message', 'غير مصرح لك بالموافقة أو الرفض');
  end if;

  if p_status not in ('APPROVED', 'REJECTED') then
    return jsonb_build_object('ok', false, 'message', 'حالة غير صحيحة');
  end if;

  update public.employee_registrations
  set status = p_status,
      approved_at = case when p_status = 'APPROVED' then now() else approved_at end,
      approved_by = case when p_status = 'APPROVED' then auth.uid() else approved_by end,
      rejected_at = case when p_status = 'REJECTED' then now() else rejected_at end,
      rejected_by = case when p_status = 'REJECTED' then auth.uid() else rejected_by end,

      trusted_device_enabled = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then true
        else trusted_device_enabled
      end,

      -- Owner decision: activate only the device submitted with the registration.
      trusted_device_token_hash = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then pending_trusted_device_token_hash
        else trusted_device_token_hash
      end,

      trusted_device_fingerprint_hash = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then public.hash_trusted_device_fingerprint(pending_trusted_device_id)
        else trusted_device_fingerprint_hash
      end,

      trusted_device_id = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then pending_trusted_device_id
        else trusted_device_id
      end,

      trusted_device_type = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then pending_trusted_device_type
        else trusted_device_type
      end,

      trusted_device_name = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then pending_trusted_device_name
        else trusted_device_name
      end,

      trusted_device_user_agent = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then pending_trusted_device_user_agent
        else trusted_device_user_agent
      end,

      trusted_device_registered_at = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then now()
        else trusted_device_registered_at
      end,

      trusted_device_expires_at = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
          and public.hash_trusted_device_fingerprint(pending_trusted_device_id) is not null
        then 'infinity'::timestamptz
        else trusted_device_expires_at
      end,

      trusted_device_revoked_at = case
        when p_status = 'APPROVED'
          and pending_trusted_device_token_hash is not null
        then null
        else trusted_device_revoked_at
      end,

      pending_trusted_device_token_hash = case when p_status = 'APPROVED' then null else pending_trusted_device_token_hash end,
      pending_trusted_device_id = case when p_status = 'APPROVED' then null else pending_trusted_device_id end,
      pending_trusted_device_type = case when p_status = 'APPROVED' then null else pending_trusted_device_type end,
      pending_trusted_device_name = case when p_status = 'APPROVED' then null else pending_trusted_device_name end,
      pending_trusted_device_user_agent = case when p_status = 'APPROVED' then null else pending_trusted_device_user_agent end,
      pending_trusted_device_created_at = case when p_status = 'APPROVED' then null else pending_trusted_device_created_at end
  where id = p_registration_id
  returning * into reg;

  if reg.id is null then
    return jsonb_build_object('ok', false, 'message', 'الموظف غير موجود');
  end if;

  insert into public.admin_audit_logs (
    admin_auth_user_id, action, target_table, target_id, details
  )
  values (
    auth.uid(),
    'UPDATE_REGISTRATION_STATUS',
    'employee_registrations',
    p_registration_id::text,
    jsonb_build_object(
      'status', p_status,
      'trusted_device_enrollment_required',
        p_status = 'APPROVED'
        and reg.trusted_device_enabled = true
        and reg.trusted_device_token_hash is null
    )
  );

  return jsonb_build_object('ok', true, 'message', 'تم تحديث الطلب');
end;
$function$;

CREATE OR REPLACE FUNCTION public.register_trusted_device_with_metadata(p_employee_id text, p_mobile_number text, p_device_token text, p_device_id text, p_device_type text, p_device_name text, p_user_agent text, p_enrollment_claim text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  reg public.employee_registrations%rowtype;
  claim_row public.trusted_device_enrollment_claims%rowtype;
  clean_emp text := trim(coalesce(p_employee_id, ''));
  clean_mobile text := trim(coalesce(p_mobile_number, ''));
  clean_token text := trim(coalesce(p_device_token, ''));
  clean_device_id text := trim(coalesce(p_device_id, ''));
  clean_device_type text := nullif(trim(coalesce(p_device_type, '')), '');
  clean_device_name text := nullif(trim(coalesce(p_device_name, '')), '');
  clean_user_agent text := nullif(trim(coalesce(p_user_agent, '')), '');
  clean_claim text := trim(coalesce(p_enrollment_claim, ''));
  token_hash text;
  fingerprint_hash text;
  enrollment_claim_hash text;
  expiry timestamptz;
begin
  if clean_emp = ''
     or clean_mobile = ''
     or length(clean_token) < 40
     or clean_device_id = ''
     or length(clean_claim) < 40 then
    return jsonb_build_object(
      'ok', false,
      'result', 'DENIED',
      'message', 'بيانات تفعيل الجهاز غير مكتملة'
    );
  end if;

  select *
  into reg
  from public.employee_registrations
  where employee_id = clean_emp
    and mobile_number = clean_mobile
  limit 1
  for update;

  if reg.id is null
     or reg.status <> 'APPROVED'
     or not coalesce(reg.trusted_device_enabled, false)
     or not public.is_permanently_allowed_specialty(reg.specialty) then
    return jsonb_build_object(
      'ok', false,
      'result', 'DENIED',
      'message', 'الجهاز غير مؤهل للربط'
    );
  end if;

  token_hash := public.hash_trusted_device_token(clean_token);
  fingerprint_hash := public.hash_trusted_device_fingerprint(clean_device_id);
  enrollment_claim_hash := encode(extensions.digest(clean_claim, 'sha256'), 'hex');

  if fingerprint_hash is null then
    return jsonb_build_object('ok', false, 'result', 'DENIED', 'message', 'معرف الجهاز غير صالح');
  end if;

  select *
  into claim_row
  from public.trusted_device_enrollment_claims
  where claim_hash = enrollment_claim_hash
    and employee_registration_id = reg.id
  limit 1
  for update;

  if claim_row.id is null
     or claim_row.consumed_at is not null
     or claim_row.expires_at <= now() then
    return jsonb_build_object(
      'ok', false,
      'result', 'DENIED',
      'enrollment_claim_invalid', true,
      'message', 'انتهت أو استُخدمت صلاحية تفعيل الجهاز. أعد التحقق عبر QR.'
    );
  end if;

  if claim_row.device_fingerprint_hash <> fingerprint_hash then
    return jsonb_build_object(
      'ok', false,
      'result', 'DENIED',
      'fingerprint_mismatch', true,
      'message', 'طلب التفعيل لا يخص هذا الجهاز'
    );
  end if;

  if reg.trusted_device_fingerprint_hash is not null
     and reg.trusted_device_fingerprint_hash <> fingerprint_hash then
    return jsonb_build_object(
      'ok', false,
      'result', 'DENIED',
      'new_device', true,
      'admin_reset_required', true,
      'message', 'تم اكتشاف جهاز مختلف. يجب إلغاء ربط الجهاز السابق من الإدارة أولًا.'
    );
  end if;

  if reg.trusted_device_token_hash is not null
     and reg.trusted_device_expires_at is not null
     and reg.trusted_device_expires_at > now()
     and reg.trusted_device_revoked_at is null then
    return jsonb_build_object(
      'ok', false,
      'result', 'DENIED',
      'already_linked', true,
      'message', 'يوجد جهاز موثوق فعال بالفعل'
    );
  end if;

  expiry := 'infinity'::timestamptz;

  update public.employee_registrations
  set trusted_device_token_hash = token_hash,
      trusted_device_fingerprint_hash = fingerprint_hash,
      trusted_device_registered_at = now(),
      trusted_device_expires_at = expiry,
      trusted_device_revoked_at = null,
      trusted_device_id = clean_device_id,
      trusted_device_type = clean_device_type,
      trusted_device_name = clean_device_name,
      trusted_device_user_agent = clean_user_agent,
      trusted_device_last_activity_at = now()
  where id = reg.id;

  update public.trusted_device_enrollment_claims
  set consumed_at = now()
  where id = claim_row.id
    and consumed_at is null;

  if not found then
    raise exception 'enrollment claim race detected';
  end if;

  insert into public.admin_audit_logs (
    admin_auth_user_id,
    action,
    target_table,
    target_id,
    details
  )
  values (
    null,
    'TRUSTED_DEVICE_BOUND',
    'employee_registrations',
    reg.id::text,
    jsonb_build_object(
      'employee_id', reg.employee_id,
      'device_id', clean_device_id,
      'expires_at', expiry,
      'claim_id', claim_row.id
    )
  );

  return jsonb_build_object(
    'ok', true,
    'message', 'تم ربط الجهاز الموثوق لمدة 30 يومًا',
    'device_id', clean_device_id,
    'expires_at', expiry
  );
exception when others then
  return jsonb_build_object(
    'ok', false,
    'result', 'DENIED',
    'message', 'تعذر حفظ بيانات الجهاز الموثوق'
  );
end;
$function$;

-- Convert only existing administrator-enabled, bound, non-revoked approved devices.
-- Do not enable pending/disabled/revoked devices or rows with incomplete binding.
with changed as (
  update public.employee_registrations
  set trusted_device_expires_at = 'infinity'::timestamptz
  where status = 'APPROVED'
    and trusted_device_enabled = true
    and trusted_device_token_hash is not null
    and trusted_device_fingerprint_hash is not null
    and trusted_device_revoked_at is null
    and trusted_device_expires_at is not null
    and trusted_device_expires_at <> 'infinity'::timestamptz
  returning id
)
insert into public.admin_audit_logs(action,target_table,target_id,details)
select 'TRUSTED_DEVICE_ADMIN_REVOCATION_ONLY','employee_registrations',id::text,
  jsonb_build_object('policy','NO_TIME_EXPIRY','owner_decision_date','2026-10-07')
from changed;

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

-- Owner approved: Staging only; no authority function, grants, RLS or schema changes.
-- Stop rather than silently reclassify an existing permanent Other registration.
DO $$ BEGIN
 IF EXISTS (SELECT 1 FROM public.employee_registrations WHERE registration_category='PERMANENT' AND specialty='أخرى') THEN
  RAISE EXCEPTION 'Existing permanent Other registrations require explicit reviewed conversion';
 END IF;
END $$;
-- Owner-approved registration taxonomy for permanent hospital employees.
-- Permanent department values are treated as permanent gate access categories.
CREATE OR REPLACE FUNCTION public.is_permanently_allowed_specialty(p_specialty text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'pg_catalog'
AS $function$
declare
  v text;
begin
  v := public.normalize_specialty_name(p_specialty);
  return v in (
    public.normalize_specialty_name('الإسعاف والطوارئ (DRS/NRS/EMT/MLT)'),
    public.normalize_specialty_name('أطباء امتياز'),
    public.normalize_specialty_name('ممرضو رعاية حثيثة (ICU)'),
    public.normalize_specialty_name('فنيو أشعة وتصوير طبي'),
    public.normalize_specialty_name('فنيو مختبرات طبية'),
    public.normalize_specialty_name('صيادلة ومساعدو صيادلة'),
    public.normalize_specialty_name('مسعفون'),
    public.normalize_specialty_name('موظفو سجلات طبية واستعلامات'),
    public.normalize_specialty_name('موظفو محاسبة ودخول'),
    public.normalize_specialty_name('مدخلو بيانات'),
    public.normalize_specialty_name('كوادر أمن وحماية'),
    public.normalize_specialty_name('عمال خدمات ونظافة'),
    public.normalize_specialty_name('أخرى (موظف دائم)')
  );
end;
$function$;

DO $$ BEGIN
 IF EXISTS(select 1 from rollout_device_baseline b full join public.employee_registrations e using(id)
 where b.row_data is distinct from (to_jsonb(e)-'trusted_device_fingerprint_hash'-'trusted_device_expires_at')) THEN
 RAISE EXCEPTION 'Unexpected employee or binding change'; END IF;
END $$;
insert into public.admin_audit_logs(action,target_table,target_id,details)
select 'TRUSTED_DEVICE_BINDING_PRESERVED_ROLLOUT','employee_registrations',id::text,jsonb_build_object('policy','ADMIN_REVOCATION_ONLY','token_preserved',true)
from public.employee_registrations where trusted_device_token_hash is not null;
notify pgrst,'reload schema';
