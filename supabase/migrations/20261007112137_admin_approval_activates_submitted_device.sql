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
