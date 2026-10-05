CREATE OR REPLACE FUNCTION public.manual_employee_check(p_employee_id text, p_mobile_number text, p_qr_token text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  reg public.employee_registrations%rowtype;
  lim public.specialty_daily_limits%rowtype;
  used_count integer := 0;
  qr_ok boolean := true;
  clean_emp text := trim(coalesce(p_employee_id, ''));
  clean_mobile text := trim(coalesce(p_mobile_number, ''));
  access_result text;
  access_reason text;
  access_message text;
BEGIN
  IF clean_emp = '' OR clean_mobile = '' THEN
    RETURN jsonb_build_object('ok', false, 'result', 'DENIED', 'message', 'أدخل الرقم الوظيفي/الوطني ورقم الهاتف');
  END IF;

  SELECT * INTO reg
  FROM public.employee_registrations
  WHERE employee_id = clean_emp AND mobile_number = clean_mobile
  LIMIT 1;

  IF reg.id IS NULL THEN
    PERFORM public.set_guard_status('DENIED', NULL, clean_emp, 'الموظف غير موجود');
    RETURN jsonb_build_object('ok', true, 'result', 'NOT_FOUND', 'message', 'الموظف غير موجود، الرجاء التسجيل أولًا');
  END IF;

  IF reg.status <> 'APPROVED' THEN
    access_message := CASE WHEN reg.status = 'PENDING' THEN 'طلبك قيد المراجعة' ELSE 'تم رفض الطلب، يرجى مراجعة الإدارة' END;
    INSERT INTO public.gate_access_logs (employee_registration_id, employee_id, mobile_number, full_name, specialty, result, reason)
    VALUES (reg.id, reg.employee_id, reg.mobile_number, reg.full_name, reg.specialty, 'DENIED', reg.status || '_EMPLOYEE');
    PERFORM public.set_guard_status('DENIED', reg.full_name, reg.employee_id, access_message);
    RETURN jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'message', access_message,
      'employee', public.employee_result_details(reg.id),
      'access', jsonb_build_object(
        'entry_time', now(),
        'daily_visits', (
          SELECT count(*) FROM public.gate_access_logs gal
          WHERE gal.employee_registration_id = reg.id
            AND gal.result = 'ALLOWED'
            AND gal.created_at >= date_trunc('day', now())
            AND gal.created_at < date_trunc('day', now()) + interval '1 day'
        )
      )
    );
  END IF;

  IF nullif(reg.trusted_device_token_hash, '') IS NOT NULL
     AND (coalesce(reg.trusted_device_enabled, false) = false OR reg.trusted_device_revoked_at IS NOT NULL)
  THEN
    INSERT INTO public.gate_access_logs (employee_registration_id, employee_id, mobile_number, full_name, specialty, result, reason)
    VALUES (reg.id, reg.employee_id, reg.mobile_number, reg.full_name, reg.specialty, 'DENIED', 'TRUSTED_DEVICE_NOT_ACTIVE');
    PERFORM public.set_guard_status('DENIED', reg.full_name, reg.employee_id, 'الجهاز الموثوق غير مفعّل');
    RETURN jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'message', 'الجهاز الموثوق غير مفعّل، يرجى مراجعة الإدارة',
      'employee', public.employee_result_details(reg.id)
    );
  END IF;

  IF nullif(trim(coalesce(p_qr_token, '')), '') IS NOT NULL THEN
    qr_ok := public.validate_and_use_qr_token(p_qr_token);
    IF NOT qr_ok THEN
      PERFORM public.set_guard_status('DENIED', NULL, clean_emp, 'QR غير صالح أو منتهي');
      RETURN jsonb_build_object('ok', true, 'result', 'DENIED', 'message', 'QR غير صالح أو منتهي، يرجى مسح QR جديد');
    END IF;
  END IF;

  IF public.is_permanently_allowed_specialty(reg.specialty) THEN
    access_result := 'ALLOWED';
    access_reason := 'PERMANENTLY_ALLOWED_SPECIALTY';
    access_message := 'مسموح بالدخول';
  ELSE
    SELECT * INTO lim
    FROM public.specialty_daily_limits
    WHERE specialty_name = reg.specialty AND is_active = true
    LIMIT 1;

    IF lim.id IS NOT NULL THEN
      SELECT count(*) INTO used_count
      FROM public.gate_access_logs
      WHERE specialty = reg.specialty
        AND result = 'LIMITED'
        AND created_at >= date_trunc('day', now())
        AND created_at < date_trunc('day', now()) + interval '1 day';

      IF used_count >= lim.daily_limit THEN
        access_result := 'DENIED';
        access_reason := 'SPECIALTY_DAILY_LIMIT_REACHED';
        access_message := 'غير مسموح — تم الوصول للحد اليومي لهذا الاختصاص';
      ELSE
        access_result := 'LIMITED';
        access_reason := 'SPECIALTY_LIMITED_ACCESS';
        access_message := 'مسموح بشكل مؤقت';
      END IF;
    ELSIF public.normalize_specialty_name(coalesce(reg.job_type, '')) = public.normalize_specialty_name('طبيب') THEN
      access_result := 'LIMITED';
      access_reason := 'TEMPORARY_DOCTOR_NON_EMERGENCY';
      access_message := 'مسموح جزئيًا — طبيب من اختصاص آخر';
    ELSE
      access_result := 'LIMITED';
      access_reason := 'TEMPORARY_APPROVED_ACCESS';
      access_message := 'مسموح بشكل مؤقت';
    END IF;
  END IF;

  INSERT INTO public.gate_access_logs (employee_registration_id, employee_id, mobile_number, full_name, specialty, result, reason, qr_token)
  VALUES (
    reg.id, reg.employee_id, reg.mobile_number, reg.full_name, reg.specialty, access_result, access_reason,
    CASE WHEN nullif(trim(coalesce(p_qr_token, '')), '') IS NULL THEN NULL ELSE p_qr_token::uuid END
  );
  PERFORM public.set_guard_status(access_result, reg.full_name, reg.employee_id, access_message);

  RETURN jsonb_build_object(
    'ok', true,
    'result', access_result,
    'message', access_message,
    'employee', public.employee_result_details(reg.id),
    'access', jsonb_build_object(
      'entry_time', now(),
      'daily_visits', (
        SELECT count(*) FROM public.gate_access_logs gal
        WHERE gal.employee_registration_id = reg.id
          AND gal.result = 'ALLOWED'
          AND gal.created_at >= date_trunc('day', now())
          AND gal.created_at < date_trunc('day', now()) + interval '1 day'
      )
    )
  );
END;
$function$
;
