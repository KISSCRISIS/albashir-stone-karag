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
