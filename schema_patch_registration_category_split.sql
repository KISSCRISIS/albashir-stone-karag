-- =============================================================================
-- ALBASHIR Gate: registration category split (PERMANENT / TEMPORARY)
-- Production migration: 20261005092112 registration_category_split
-- Status: APPLIED AND VERIFIED in Production.
-- WARNING: this file is now HISTORICAL / REFERENCE inside the repository.
-- Do NOT re-apply it blindly against Production (columns, constraint and the
-- 15-argument overload already exist there). Any future change requires a new
-- narrowly scoped migration, not a re-run of this file.
-- Depends on: schema_patch_trusted_device_registration_flow.sql (13-arg
-- register_employee_request is the reference implementation preserved below).
-- =============================================================================
-- Purpose:
-- 1) Add registration_category + affiliated_entity to employee_registrations
--    (both nullable, no backfill, no NOT NULL).
-- 2) Add a 15-argument overload of register_employee_request that keeps the
--    first 13 args identical (names/order) and appends:
--      p_registration_category text
--      p_affiliated_entity   text
--    NOTE: the 15-arg overload uses NO DEFAULTS on any parameter to avoid
--    PostgreSQL/PostgREST overload ambiguity with the legacy 13-arg overload.
-- 3) Keep the existing 13-arg implementation untouched in its own file.
--    This file only ADDS the new overload; it never drops any overload.
-- 4) Preserve Trusted Device pending flow, ownership validation, APPROVED /
--    REJECTED / PENDING behavior, first_entry_used, validate_and_use_qr_token,
--    gate_access_logs, and set_guard_status logic with minimal changes.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) New columns (idempotent, nullable, no backfill)
-- ---------------------------------------------------------------------------
alter table public.employee_registrations
  add column if not exists registration_category text;

alter table public.employee_registrations
  add column if not exists affiliated_entity text;

-- ---------------------------------------------------------------------------
-- 2) CHECK constraint (idempotent via DO block probing pg_constraint).
--    Allows only PERMANENT / TEMPORARY / NULL. Old rows stay NULL.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'chk_employee_registrations_registration_category'
      and conrelid = 'public.employee_registrations'::regclass
  ) then
    alter table public.employee_registrations
      add constraint chk_employee_registrations_registration_category
      check (
        registration_category is null
        or registration_category in ('PERMANENT', 'TEMPORARY')
      );
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3) 15-argument overload (first 13 args identical to the canonical 13-arg).
--    Reference body: schema_patch_trusted_device_registration_flow.sql.
-- ---------------------------------------------------------------------------
create or replace function public.register_employee_request(
  p_full_name text,
  p_employee_id text,
  p_mobile_number text,
  p_specialty text,
  p_qr_token text,
  p_job_type text,
  p_department text,
  p_photo_url text,
  p_device_token text,
  p_device_id text,
  p_device_type text,
  p_device_name text,
  p_user_agent text,
  p_registration_category text,
  p_affiliated_entity text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
  -- Backend category validation (never rely on frontend only).
  if clean_category not in ('PERMANENT', 'TEMPORARY') then
    return jsonb_build_object(
      'ok', false,
      'result', 'DENIED',
      'message', 'نوع التسجيل غير صالح. اختر موظف دائم أو موظف مؤقت / خارجي'
    );
  end if;

  -- Base required fields for both categories.
  if clean_name = '' or clean_emp = '' or clean_mobile = '' then
    return jsonb_build_object(
      'ok', false,
      'result', 'DENIED',
      'message', 'الرجاء تعبئة الاسم ورقم الموظف/الوطني ورقم الهاتف'
    );
  end if;

  if clean_photo = '' then
    return jsonb_build_object(
      'ok', false,
      'result', 'DENIED',
      'message', 'الصورة الشخصية مطلوبة'
    );
  end if;

  -- Category-specific validation and effective values.
  if clean_category = 'PERMANENT' then
    if clean_job_in is null or clean_dept_in is null then
      return jsonb_build_object(
        'ok', false,
        'result', 'DENIED',
        'message', 'الوظيفة والقسم مطلوبان للموظف الدائم'
      );
    end if;
    -- Keep legacy access rules working: specialty column carries department.
    effective_specialty := clean_dept_in;
    store_job_type := clean_job_in;
    store_department := clean_dept_in;
    store_affiliated := null;
  else
    -- TEMPORARY
    if clean_specialty_in = '' or clean_affiliated is null then
      return jsonb_build_object(
        'ok', false,
        'result', 'DENIED',
        'message', 'الاختصاص والجهة التابعة مطلوبان للموظف المؤقت / الخارجي'
      );
    end if;
    effective_specialty := clean_specialty_in;
    store_job_type := null;
    store_department := null;
    store_affiliated := clean_affiliated;
  end if;

  select *
  into reg
  from public.employee_registrations
  where employee_id = clean_emp
  limit 1
  for update;

  if reg.id is null then
    insert into public.employee_registrations (
      full_name,
      employee_id,
      mobile_number,
      specialty,
      job_type,
      department,
      employee_photo_url,
      registration_category,
      affiliated_entity,
      status,
      first_entry_used,
      first_entry_at,
      pending_trusted_device_token_hash,
      pending_trusted_device_id,
      pending_trusted_device_type,
      pending_trusted_device_name,
      pending_trusted_device_user_agent,
      pending_trusted_device_created_at
    )
    values (
      clean_name,
      clean_emp,
      clean_mobile,
      effective_specialty,
      store_job_type,
      store_department,
      clean_photo,
      clean_category,
      store_affiliated,
      'PENDING',
      false,
      null,
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
      -- Ownership validation unchanged from the 13-arg implementation.
      if length(clean_device_token) < 40
         or reg.pending_trusted_device_token_hash is null
         or reg.pending_trusted_device_token_hash <> public.hash_trusted_device_token(clean_device_token) then
        return jsonb_build_object(
          'ok', false,
          'result', 'DENIED',
          'message', 'تعذر التحقق من ملكية الطلب المعلق. استخدم الجهاز الذي أرسل الطلب أو راجع الإدارة'
        );
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
    return public.manual_employee_check(reg.employee_id, reg.mobile_number, p_qr_token);
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
$$;

-- Same grants as the 13-arg overload; legacy overload grants untouched.
grant execute on function public.register_employee_request(text, text, text, text, text, text, text, text, text, text, text, text, text, text, text)
  to anon, authenticated;

notify pgrst, 'reload schema';
