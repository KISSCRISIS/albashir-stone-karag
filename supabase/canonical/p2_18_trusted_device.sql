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

insert into public.admin_audit_logs (
  admin_auth_user_id, action, target_table, target_id, details
)
select
  null,
  'TRUSTED_DEVICE_REENROLL_REQUIRED_P2_18',
  'employee_registrations',
  id::text,
  jsonb_build_object(
    'reason', 'P2_18_FINGERPRINT_AND_TTL_REQUIRED',
    'previous_device_id', trusted_device_id
  )
from public.employee_registrations
where coalesce(trusted_device_enabled, false) = true
  and trusted_device_token_hash is not null;

update public.employee_registrations
set trusted_device_enabled = false,
    trusted_device_token_hash = null,
    trusted_device_fingerprint_hash = null,
    trusted_device_expires_at = null,
    trusted_device_registered_at = null,
    trusted_device_last_used_at = null,
    trusted_device_revoked_at = now()
where coalesce(trusted_device_enabled, false) = true
  and trusted_device_token_hash is not null;

-- P2-18 trusted-device re-enrollment compatibility
-- Staging migration applied as:
-- 20261007095927_p2_18_reenroll_keep_eligibility
--
-- Purpose:
-- Keep employees whose old trusted-device token was intentionally invalidated
-- by P2-18 eligible to bind a new device without requiring a fresh admin approval.

update public.employee_registrations e
set trusted_device_enabled = true
where trusted_device_token_hash is null
  and exists (
    select 1
    from public.admin_audit_logs a
    where a.action='TRUSTED_DEVICE_REENROLL_REQUIRED_P2_18'
      and a.target_table='employee_registrations'
      and a.target_id=e.id::text
  );

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

