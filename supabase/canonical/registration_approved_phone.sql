CREATE OR REPLACE FUNCTION public.register_employee_request(p_full_name text, p_employee_id text, p_mobile_number text, p_specialty text, p_qr_token text, p_job_type text, p_department text, p_photo_url text, p_device_token text, p_device_id text, p_device_type text, p_device_name text, p_user_agent text, p_registration_category text, p_affiliated_entity text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  reg record;
  qr_ok boolean := false;
  clean_name text := trim(coalesce(p_full_name, ''));
  clean_emp text := trim(coalesce(p_employee_id, ''));
  clean_mobile text := trim(coalesce(p_mobile_number, ''));
  clean_specialty_in text := trim(coalesce(p_specialty, ''));
  clean_job_in text := nullif(trim(coalesce(p_job_type, '')), '');
  clean_dept_in text := nullif(trim(coalesce(p_department, '')), '');
  clean_photo text := trim(coalesce(p_photo_url, ''));
  clean_device_token text := trim(coalesce(p_device_token, ''));
  clean_category text := upper(trim(coalesce(p_registration_category, '')));
  clean_affiliated text := nullif(trim(coalesce(p_affiliated_entity, '')), '');
  effective_specialty text;
  store_job_type text;
  store_department text;
  store_affiliated text;
begin
  if char_length(clean_name) > 120
     or char_length(clean_emp) > 32
     or char_length(clean_mobile) > 20
     or char_length(clean_specialty_in) > 80
     or char_length(coalesce(clean_affiliated, '')) > 120 then
    return jsonb_build_object('ok', false,'result', 'DENIED','message', 'تجاوزت البيانات الحد المسموح لطول الحقول');
  end if;

  if clean_category not in ('PERMANENT', 'TEMPORARY') then
    return jsonb_build_object('ok', false,'result', 'DENIED','message', 'نوع التسجيل غير صالح. اختر موظف دائم أو موظف مؤقت / خارجي');
  end if;

  if clean_name = '' or clean_emp = '' or clean_mobile = '' then
    return jsonb_build_object('ok', false,'result', 'DENIED','message', 'الرجاء تعبئة الاسم ورقم الموظف/الوطني ورقم الهاتف');
  end if;

  if clean_photo = '' then
    return jsonb_build_object('ok', false,'result', 'DENIED','message', 'الصورة الشخصية مطلوبة');
  end if;

  if clean_photo not like 'registrations/%'
     and clean_photo not like 'https://%' then
    return jsonb_build_object('ok', false,'result', 'DENIED','message', 'رابط الصورة الشخصية غير صالح');
  end if;

  if clean_category = 'PERMANENT' then
    if clean_job_in is null or clean_dept_in is null then
      return jsonb_build_object('ok', false,'result', 'DENIED','message', 'الوظيفة والقسم مطلوبان للموظف الدائم');
    end if;
    effective_specialty := clean_dept_in;
    store_job_type := clean_job_in;
    store_department := clean_dept_in;
    store_affiliated := null;
  else
    if clean_specialty_in = '' or clean_affiliated is null then
      return jsonb_build_object('ok', false,'result', 'DENIED','message', 'الاختصاص والجهة التابعة مطلوبان للموظف المؤقت / الخارجي');
    end if;
    effective_specialty := clean_specialty_in;
    store_job_type := null;
    store_department := null;
    store_affiliated := clean_affiliated;
    if not exists (
      select 1 from public.specialty_daily_limits
      where specialty_name = effective_specialty
        and is_active = true
    ) then
      return jsonb_build_object('ok', false,'result', 'DENIED','message', 'الاختصاص غير معتمد للتسجيل المؤقت / الخارجي');
    end if;
  end if;

  select *
  into reg
  from public.employee_registrations
  where employee_id = clean_emp
  limit 1
  for update;

  if reg.id is null then
    insert into public.employee_registrations (
      full_name,employee_id,mobile_number,specialty,job_type,department,employee_photo_url,
      registration_category,affiliated_entity,status,first_entry_used,first_entry_at,
      pending_trusted_device_token_hash,pending_trusted_device_id,pending_trusted_device_type,
      pending_trusted_device_name,pending_trusted_device_user_agent,pending_trusted_device_created_at
    )
    values (
      clean_name,clean_emp,clean_mobile,effective_specialty,store_job_type,store_department,clean_photo,
      clean_category,store_affiliated,'PENDING',false,null,
      case when length(clean_device_token) >= 40 then public.hash_trusted_device_token(clean_device_token) else null end,
      nullif(trim(coalesce(p_device_id, '')), ''),
      nullif(trim(coalesce(p_device_type, '')), ''),
      nullif(trim(coalesce(p_device_name, '')), ''),
      nullif(trim(coalesce(p_user_agent, '')), ''),
      case when length(clean_device_token) >= 40 then now() else null end
    )
    returning * into reg;
  else
    if reg.status = 'PENDING' then
      if length(clean_device_token) < 40
         or reg.pending_trusted_device_token_hash is null
         or reg.pending_trusted_device_token_hash <> public.hash_trusted_device_token(clean_device_token) then
        return jsonb_build_object('ok', false,'result', 'DENIED','message', 'تعذر التحقق من ملكية الطلب المعلق. استخدم الجهاز الذي أرسل الطلب أو راجع الإدارة');
      end if;

      update public.employee_registrations
      set mobile_number = clean_mobile,
          specialty = effective_specialty,
          job_type = store_job_type,
          department = store_department,
          employee_photo_url = clean_photo,
          registration_category = clean_category,
          affiliated_entity = store_affiliated
      where id = reg.id
      returning * into reg;
    end if;
  end if;

  if reg.status = 'REJECTED' then
    insert into public.gate_access_logs (employee_registration_id, employee_id, mobile_number, full_name, specialty, result, reason)
    values (reg.id, reg.employee_id, reg.mobile_number, reg.full_name, reg.specialty, 'DENIED', 'REJECTED_EMPLOYEE');
    perform public.set_guard_status('DENIED', reg.full_name, reg.employee_id, 'تم رفض الطلب مسبقًا');
    return jsonb_build_object('ok', true, 'result', 'DENIED', 'message', 'تم رفض الطلب، يرجى مراجعة الإدارة');
  end if;

  if reg.status = 'APPROVED' then
    if clean_mobile = ''
       or trim(coalesce(reg.mobile_number, '')) <> clean_mobile then
      return jsonb_build_object(
        'ok', false,
        'result', 'DENIED',
        'message', 'تعذر التحقق من بيانات الموظف'
      );
    end if;

    return public.manual_employee_check(reg.employee_id, clean_mobile, p_qr_token);
  end if;

  if reg.first_entry_used = true then
    insert into public.gate_access_logs (employee_registration_id, employee_id, mobile_number, full_name, specialty, result, reason)
    values (reg.id, reg.employee_id, reg.mobile_number, reg.full_name, reg.specialty, 'DENIED', 'PENDING_FIRST_ENTRY_ALREADY_USED');
    perform public.set_guard_status('DENIED', reg.full_name, reg.employee_id, 'طلب قيد المراجعة — تم استخدام الدخول الأول سابقًا');
    return jsonb_build_object('ok', true, 'result', 'DENIED', 'message', 'طلبك قيد المراجعة، وتم استخدام الدخول الأول سابقًا');
  end if;

  qr_ok := public.validate_and_use_qr_token(p_qr_token);

  if qr_ok then
    update public.employee_registrations
    set first_entry_used = true,
        first_entry_at = now()
    where id = reg.id
    returning * into reg;

    insert into public.gate_access_logs (employee_registration_id, employee_id, mobile_number, full_name, specialty, result, reason, qr_token)
    values (reg.id, reg.employee_id, reg.mobile_number, reg.full_name, reg.specialty, 'PENDING_FIRST_ENTRY', 'FIRST_ENTRY_AFTER_REGISTRATION',
      case when p_qr_token is null or p_qr_token = '' then null else p_qr_token::uuid end);
    perform public.set_guard_status('LIMITED', reg.full_name, reg.employee_id, 'دخول أول مرة — بانتظار موافقة الإدارة');
    return jsonb_build_object('ok', true, 'result', 'LIMITED', 'message', 'تم إرسال طلبك. تم السماح بدخول أول مرة فقط، والطلب بانتظار موافقة الإدارة');
  end if;

  return jsonb_build_object('ok', true, 'result', 'PENDING', 'message', 'تم إرسال طلبك، الرجاء انتظار موافقة الإدارة');
end;
$function$
;
