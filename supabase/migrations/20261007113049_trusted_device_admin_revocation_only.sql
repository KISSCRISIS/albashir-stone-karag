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
