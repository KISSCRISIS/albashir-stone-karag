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
