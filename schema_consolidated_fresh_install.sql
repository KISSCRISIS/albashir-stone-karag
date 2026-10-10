-- =============================================================================
-- ALBASHIR Gate — Consolidated Fresh-Install Schema
-- =============================================================================
-- Updated: 2026-10-05
--
-- PURPOSE
-- This file concatenates schema.sql and every active schema_patch_*.sql file, including the authenticated guard-screen reset patch
-- into ONE script, in the dependency-verified order below, for setting up a
-- BRAND NEW Supabase project from scratch (local testing, staging, a second
-- hospital gate, etc.).
--
-- DO NOT RUN THIS AGAINST THE EXISTING PRODUCTION PROJECT.
-- Per PRODUCTION_MIGRATION_MAPPING.md: "The existing Production database must
-- not be rebuilt by rerunning all repository patches." Production's live
-- Supabase state is the source of truth; reconciling it with these files is a
-- separate, explicitly-approved process, not a blind re-run of this script.
--
-- WHY THIS ORDER (not alphabetical, not any single prior doc's list)
-- The repository had FOUR different "recommended order" lists across
-- README.md, ALBASHIR_GATE_24_7_FINAL_SOLUTION_REPORT.md,
-- PROJECT_INDEX_AND_ARCHITECTURE.md and PRODUCTION_RPC_CANONICAL_MAP.md, and
-- they did not all agree with each other. This file's order was derived by
-- checking actual dependencies in the SQL itself, not by picking one of the
-- existing lists on trust:
--   1) schema_patch_pgcrypto_schema_fix.sql must run early (right after
--      schema.sql) because it is a FIX for pgcrypto landing in the wrong
--      Postgres schema. `create extension if not exists` cannot relocate an
--      already-installed extension, and schema.sql / schema_patch_auto_verify.sql
--      both call `create extension if not exists "pgcrypto"` with no schema
--      qualifier. If those ran before the fix, the fix would silently do
--      nothing on a fresh database.
--   2) schema_patch_verify_employee_profile.sql's own header states it must
--      run after schema.sql, schema_patch_permanent_specialty.sql,
--      schema_patch_auto_verify.sql AND schema_patch_offline_gate_mode.sql.
--   3) schema_patch_employee_profiles.sql's own header states it must run
--      after schema_patch_verify_employee_profile.sql.
--   4) schema_patch_production_hardening.sql must run after the trusted-device
--      patches (its own header says "Run LAST, after schema.sql and every
--      schema_patch_*.sql file", confirmed by grep: it references
--      trusted_device_token_hash / trusted_device_enabled
--      / register_trusted_device, all introduced by the trusted-device
--      patches, so it cannot run before them) — but it is NOT the final layer
--      of this file anymore. Layers 11-13 intentionally run after it as newer,
--      narrowly scoped additions:
--      [11/14] gate_qr_device_auth stays the last layer that defines
--      create_qr_session; [12/14] guard_screen_reset_auth depends on it;
--      [13/14] registration_category_split is the current final layer.
--   5) schema_patch_gate_qr_device_auth.sql only needs
--      schema_patch_offline_gate_mode.sql and schema_patch_pgcrypto_schema_fix.sql,
--      and per PRODUCTION_RPC_CANONICAL_MAP.md it must be the final layer
--      that defines create_qr_session — confirmed nothing after it in this
--      file redefines create_qr_session.
-- This produced the same order already independently listed (and agreeing
-- with each other) in ALBASHIR_GATE_24_7_FINAL_SOLUTION_REPORT.md and
-- PROJECT_INDEX_AND_ARCHITECTURE.md. README.md's own SQL-order section was
-- the stale outlier (it put pgcrypto_schema_fix.sql last, omitted
-- schema_patch_trusted_device_registration_flow.sql and
-- schema_patch_gate_qr_device_auth.sql entirely) and should be treated as
-- superseded by this file.
--
-- EXCLUDED ON PURPOSE
-- schema_patch_guard_device_admin_control.sql is NOT included. Its own file
-- header already says "DEPRECATED: not the production canonical API. Do not
-- apply this patch to Production." per PRODUCTION_RPC_CANONICAL_MAP.md.
-- Nothing is lost by skipping it: the canonical guard-approval function
-- admin_approve_gate_device(text, boolean) is already defined in
-- schema_patch_offline_gate_mode.sql (confirmed by grep), which IS included
-- below.
--
-- HOW TO USE
-- Paste this whole file into Supabase SQL Editor → New Query → Run, on a
-- fresh project. Each original file's content is kept verbatim inside its
-- own clearly marked section below, for auditability against the source
-- files in this repo. After running, execute the verification block at the
-- very end of this file to confirm the canonical RPC signatures exist.
-- =============================================================================


-- =============================================================================
-- [1/14] SOURCE FILE: schema.sql
-- =============================================================================

-- =========================================================
-- Employee Private Parking Access System
-- Supabase schema.sql
-- Version: 1.0
--
-- هدف الملف:
-- يجهّز قاعدة البيانات كاملة لتطبيق كراج الموظفين:
-- - تسجيل الموظفين
-- - دخول أول مرة بعد التسجيل بشرط QR صالح
-- - شاشة الحارس realtime
-- - مسموح / مرفوض / مسموح جزئيًا
-- - حدود يومية حسب الاختصاص
-- - بلاغات الحارس بالصور
-- - أدمن / سوبر أدمن / مشرفين
-- - سجلات تدقيق Audit
--
-- مهم:
-- 1) شغّلي هذا الملف في Supabase SQL Editor.
-- 2) بعدها أنشئي مستخدمك من Authentication → Users.
-- 3) ثم شغّلي كود SUPER ADMIN الموجود في آخر الملف بعد تبديل القيم.
-- =========================================================

create extension if not exists "pgcrypto";

-- =========================================================
-- ADMIN PROFILES
-- =========================================================

create table if not exists public.admin_profiles (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique not null,
  email text unique not null,
  full_name text,
  role text not null check (role in ('SUPER_ADMIN', 'SUB_ADMIN')),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.admin_profiles enable row level security;

-- =========================================================
-- EMPLOYEE REGISTRATIONS
-- =========================================================

create table if not exists public.employee_registrations (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  employee_id text not null unique,
  mobile_number text not null,
  specialty text not null,
  status text not null default 'PENDING' check (status in ('PENDING', 'APPROVED', 'REJECTED')),
  first_entry_used boolean not null default false,
  first_entry_at timestamptz,
  approved_at timestamptz,
  approved_by uuid,
  rejected_at timestamptz,
  rejected_by uuid,
  created_at timestamptz not null default now()
);

alter table public.employee_registrations enable row level security;

create index if not exists idx_employee_registrations_status
on public.employee_registrations(status);

create index if not exists idx_employee_registrations_employee_id
on public.employee_registrations(employee_id);

create index if not exists idx_employee_registrations_employee_mobile
on public.employee_registrations(employee_id, mobile_number);

create index if not exists idx_employee_registrations_specialty
on public.employee_registrations(specialty);

-- =========================================================
-- SPECIALTY DAILY LIMITS
-- =========================================================

create table if not exists public.specialty_daily_limits (
  id uuid primary key default gen_random_uuid(),
  specialty_name text not null unique,
  daily_limit integer not null default 0 check (daily_limit >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.specialty_daily_limits enable row level security;

-- =========================================================
-- GATE ACCESS LOGS
-- =========================================================

create table if not exists public.gate_access_logs (
  id uuid primary key default gen_random_uuid(),
  employee_registration_id uuid references public.employee_registrations(id) on delete set null,
  employee_id text,
  mobile_number text,
  full_name text,
  specialty text,
  result text not null check (result in ('ALLOWED', 'DENIED', 'LIMITED', 'PENDING_FIRST_ENTRY')),
  reason text,
  qr_token uuid,
  created_at timestamptz not null default now()
);

alter table public.gate_access_logs enable row level security;

create index if not exists idx_gate_access_logs_created_at
on public.gate_access_logs(created_at);

create index if not exists idx_gate_access_logs_result
on public.gate_access_logs(result);

create index if not exists idx_gate_access_logs_specialty
on public.gate_access_logs(specialty);

create index if not exists idx_gate_access_logs_specialty_created_at
on public.gate_access_logs(specialty, created_at desc);

-- =========================================================
-- GUARD SCREEN STATUS
-- one row only: id = 1
-- =========================================================

create table if not exists public.guard_screen_status (
  id integer primary key default 1 check (id = 1),
  current_status text not null default 'READY' check (current_status in ('READY', 'ALLOWED', 'DENIED', 'LIMITED')),
  employee_name text,
  employee_id text,
  message text,
  updated_at timestamptz not null default now()
);

alter table public.guard_screen_status enable row level security;

insert into public.guard_screen_status (id, current_status, message)
values (1, 'READY', 'QR جاهز للمسح')
on conflict (id) do nothing;

-- =========================================================
-- QR SESSIONS
-- كل QR له token ينتهي خلال 30 ثانية أو بعد أول استخدام.
-- =========================================================

create table if not exists public.qr_sessions (
  id uuid primary key default gen_random_uuid(),
  token uuid not null unique default gen_random_uuid(),
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.qr_sessions enable row level security;

create index if not exists idx_qr_sessions_token
on public.qr_sessions(token);

create index if not exists idx_qr_sessions_expires_at
on public.qr_sessions(expires_at);

-- =========================================================
-- VIOLATION REPORTS
-- صور مخالفات الحارس تحفظ في Supabase Storage.
-- الجدول يحفظ رابط الصورة.
-- =========================================================

create table if not exists public.violation_reports (
  id uuid primary key default gen_random_uuid(),
  employee_id text,
  note text,
  photo_url text not null,
  status text not null default 'NEW' check (status in ('NEW', 'REVIEWED', 'RESOLVED')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid
);

alter table public.violation_reports enable row level security;

create index if not exists idx_violation_reports_status
on public.violation_reports(status);

create index if not exists idx_violation_reports_created_at
on public.violation_reports(created_at);

-- =========================================================
-- ADMIN AUDIT LOGS
-- =========================================================

create table if not exists public.admin_audit_logs (
  id uuid primary key default gen_random_uuid(),
  admin_auth_user_id uuid,
  action text not null,
  target_table text,
  target_id text,
  details jsonb,
  created_at timestamptz not null default now()
);

alter table public.admin_audit_logs enable row level security;

create index if not exists idx_admin_audit_logs_created_at
on public.admin_audit_logs(created_at);

-- =========================================================
-- STORAGE BUCKET
-- =========================================================

insert into storage.buckets (id, name, public)
values ('violation-photos', 'violation-photos', false)
on conflict (id) do update set public = excluded.public;

-- =========================================================
-- HELPER FUNCTIONS
-- =========================================================

create or replace function public.current_admin_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role
  from public.admin_profiles
  where auth_user_id = auth.uid()
    and is_active = true
  limit 1;
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.current_admin_role() in ('SUPER_ADMIN', 'SUB_ADMIN'), false);
$$;

create or replace function public.is_super_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.current_admin_role() = 'SUPER_ADMIN', false);
$$;

-- =========================================================
-- RLS POLICIES
-- =========================================================

-- admin_profiles
drop policy if exists "Admins can read admin profiles" on public.admin_profiles;
create policy "Admins can read admin profiles"
on public.admin_profiles
for select
to authenticated
using (public.is_admin());

drop policy if exists "Super admin can manage admin profiles" on public.admin_profiles;
create policy "Super admin can manage admin profiles"
on public.admin_profiles
for all
to authenticated
using (public.is_super_admin())
with check (public.is_super_admin());

-- employee_registrations
drop policy if exists "Admins can read registrations" on public.employee_registrations;
create policy "Admins can read registrations"
on public.employee_registrations
for select
to authenticated
using (public.is_admin());

drop policy if exists "Admins can update registrations" on public.employee_registrations;
create policy "Admins can update registrations"
on public.employee_registrations
for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

-- specialty_daily_limits
drop policy if exists "Admins can read specialty limits" on public.specialty_daily_limits;
create policy "Admins can read specialty limits"
on public.specialty_daily_limits
for select
to authenticated
using (public.is_admin());

drop policy if exists "Super admin can manage specialty limits" on public.specialty_daily_limits;
create policy "Super admin can manage specialty limits"
on public.specialty_daily_limits
for all
to authenticated
using (public.is_super_admin())
with check (public.is_super_admin());

-- gate_access_logs
drop policy if exists "Admins can read access logs" on public.gate_access_logs;
create policy "Admins can read access logs"
on public.gate_access_logs
for select
to authenticated
using (public.is_admin());

-- guard_screen_status
drop policy if exists "Anyone can read guard screen status" on public.guard_screen_status;
create policy "Anyone can read guard screen status"
on public.guard_screen_status
for select
to anon, authenticated
using (true);

-- violation_reports
drop policy if exists "Admins can read violation reports" on public.violation_reports;
create policy "Admins can read violation reports"
on public.violation_reports
for select
to authenticated
using (public.is_admin());

drop policy if exists "Admins can update violation reports" on public.violation_reports;
create policy "Admins can update violation reports"
on public.violation_reports
for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

-- admin_audit_logs
drop policy if exists "Admins can read audit logs" on public.admin_audit_logs;
create policy "Admins can read audit logs"
on public.admin_audit_logs
for select
to authenticated
using (public.is_admin());

-- Storage policies
drop policy if exists "Anyone can upload violation photos" on storage.objects;
drop policy if exists "Gate can upload violation photos" on storage.objects;
create policy "Gate can upload violation photos"
on storage.objects
for insert
to anon, authenticated
with check (
  bucket_id = 'violation-photos'
  and (storage.foldername(name))[1] = 'violations'
  and lower(coalesce(metadata->>'mimetype', '')) in ('image/jpeg', 'image/png', 'image/webp')
  and coalesce((metadata->>'size')::bigint, 0) <= 5242880
);

drop policy if exists "Anyone can read violation photos" on storage.objects;
drop policy if exists "Admins can read violation photos" on storage.objects;

-- =========================================================
-- RPC: get_my_admin_profile
-- =========================================================

create or replace function public.get_my_admin_profile()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  prof record;
begin
  select *
  into prof
  from public.admin_profiles
  where auth_user_id = auth.uid()
    and is_active = true
  limit 1;

  if prof.id is null then
    return jsonb_build_object('ok', false, 'message', 'غير مصرح لك بالدخول');
  end if;

  return jsonb_build_object(
    'ok', true,
    'id', prof.id,
    'email', prof.email,
    'full_name', prof.full_name,
    'role', prof.role
  );
end;
$$;

-- =========================================================
-- RPC: create_qr_session
-- =========================================================

create or replace function public.cleanup_expired_qr_sessions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted_count integer := 0;
begin
  delete from public.qr_sessions
  where expires_at < now() - interval '10 minutes';

  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;

create or replace function public.create_qr_session()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  new_token uuid;
begin
  insert into public.qr_sessions (expires_at)
  values (now() + interval '30 seconds')
  returning token into new_token;

  return jsonb_build_object(
    'ok', true,
    'token', new_token::text,
    'expires_in_seconds', 30
  );
end;
$$;

grant execute on function public.cleanup_expired_qr_sessions() to authenticated;

-- =========================================================
-- RPC HELPER: validate_and_use_qr_token
-- =========================================================

create or replace function public.validate_and_use_qr_token(p_token text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  token_uuid uuid;
  found_id uuid;
begin
  if p_token is null or length(trim(p_token)) = 0 then
    return false;
  end if;

  begin
    token_uuid := p_token::uuid;
  exception when others then
    return false;
  end;

  select id
  into found_id
  from public.qr_sessions
  where token = token_uuid
    and used_at is null
    and expires_at > now()
  limit 1;

  if found_id is null then
    return false;
  end if;

  update public.qr_sessions
  set used_at = now()
  where id = found_id;

  return true;
end;
$$;

-- =========================================================
-- RPC HELPER: set_guard_status
-- =========================================================

create or replace function public.set_guard_status(
  p_status text,
  p_employee_name text,
  p_employee_id text,
  p_message text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.guard_screen_status
  set current_status = p_status,
      employee_name = p_employee_name,
      employee_id = p_employee_id,
      message = p_message,
      updated_at = now()
  where id = 1;
end;
$$;

-- =========================================================
-- RPC: reset_guard_screen
-- =========================================================

create or replace function public.reset_guard_screen()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.guard_screen_status
  set current_status = 'READY',
      employee_name = null,
      employee_id = null,
      message = 'QR جاهز للمسح',
      updated_at = now()
  where id = 1;

  return jsonb_build_object('ok', true);
end;
$$;

-- =========================================================
-- RPC: register_employee_request
-- الموظف الجديد يحصل على دخول أول مرة فقط إذا:
-- - أدخل الاسم + رقم الموظف + الهاتف + الاختصاص
-- - فتح من QR صالح وغير مستخدم
-- =========================================================

create or replace function public.register_employee_request(
  p_full_name text,
  p_employee_id text,
  p_mobile_number text,
  p_specialty text,
  p_qr_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reg record;
  qr_ok boolean := false;
  clean_name text := trim(p_full_name);
  clean_emp text := trim(p_employee_id);
  clean_mobile text := trim(p_mobile_number);
  clean_specialty text := trim(p_specialty);
begin
  if clean_name = '' or clean_emp = '' or clean_mobile = '' or clean_specialty = '' then
    return jsonb_build_object(
      'ok', false,
      'result', 'DENIED',
      'message', 'الرجاء تعبئة الاسم ورقم الموظف ورقم الهاتف والقسم'
    );
  end if;

  select *
  into reg
  from public.employee_registrations
  where employee_id = clean_emp
  limit 1;

  if reg.id is null then
    insert into public.employee_registrations (
      full_name,
      employee_id,
      mobile_number,
      specialty,
      status,
      first_entry_used,
      first_entry_at
    )
    values (
      clean_name,
      clean_emp,
      clean_mobile,
      clean_specialty,
      'PENDING',
      false,
      null
    )
    returning * into reg;
  end if;

  if reg.status = 'REJECTED' then
    insert into public.gate_access_logs (
      employee_registration_id,
      employee_id,
      mobile_number,
      full_name,
      specialty,
      result,
      reason
    )
    values (
      reg.id,
      reg.employee_id,
      reg.mobile_number,
      reg.full_name,
      reg.specialty,
      'DENIED',
      'REJECTED_EMPLOYEE'
    );

    perform public.set_guard_status('DENIED', reg.full_name, reg.employee_id, 'تم رفض الطلب مسبقًا');

    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'message', 'تم رفض الطلب، يرجى مراجعة الإدارة'
    );
  end if;

  if reg.status = 'APPROVED' then
    return public.manual_employee_check(reg.employee_id, reg.mobile_number, p_qr_token);
  end if;

  if reg.first_entry_used = true then
    insert into public.gate_access_logs (
      employee_registration_id,
      employee_id,
      mobile_number,
      full_name,
      specialty,
      result,
      reason
    )
    values (
      reg.id,
      reg.employee_id,
      reg.mobile_number,
      reg.full_name,
      reg.specialty,
      'DENIED',
      'PENDING_FIRST_ENTRY_ALREADY_USED'
    );

    perform public.set_guard_status('DENIED', reg.full_name, reg.employee_id, 'طلب قيد المراجعة — تم استخدام الدخول الأول سابقًا');

    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'message', 'طلبك قيد المراجعة، وتم استخدام الدخول الأول سابقًا'
    );
  end if;

  -- التحقق من QR هنا فقط بعد التأكد أن الطلب PENDING ولم يستخدم الدخول الأول.
  qr_ok := public.validate_and_use_qr_token(p_qr_token);

  if qr_ok then
    update public.employee_registrations
    set first_entry_used = true,
        first_entry_at = now()
    where id = reg.id
    returning * into reg;

    insert into public.gate_access_logs (
      employee_registration_id,
      employee_id,
      mobile_number,
      full_name,
      specialty,
      result,
      reason,
      qr_token
    )
    values (
      reg.id,
      reg.employee_id,
      reg.mobile_number,
      reg.full_name,
      reg.specialty,
      'PENDING_FIRST_ENTRY',
      'FIRST_ENTRY_AFTER_REGISTRATION',
      p_qr_token::uuid
    );

    perform public.set_guard_status('LIMITED', reg.full_name, reg.employee_id, 'دخول أول مرة — بانتظار موافقة الإدارة');

    return jsonb_build_object(
      'ok', true,
      'result', 'LIMITED',
      'message', 'تم إرسال طلبك. تم السماح بدخول أول مرة فقط، والطلب بانتظار موافقة الإدارة'
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'result', 'PENDING',
    'message', 'تم إرسال طلبك، الرجاء انتظار موافقة الإدارة'
  );
end;
$$;

-- =========================================================
-- HELPER: permanently allowed specialties
-- خيار الإسعاف والطوارئ DRS/NRS/EMT/MLT مسموح دائمًا ولا يُحسب ضمن الحدود اليومية
-- =========================================================

create or replace function public.normalize_specialty_name(p_specialty text)
returns text
language plpgsql
immutable
as $$
declare
  v text;
begin
  v := upper(trim(coalesce(p_specialty, '')));

  v := replace(v, 'أ', 'ا');
  v := replace(v, 'إ', 'ا');
  v := replace(v, 'آ', 'ا');
  v := replace(v, 'ٱ', 'ا');
  v := replace(v, 'ة', 'ه');

  v := regexp_replace(v, '\s+', '', 'g');
  v := replace(v, '،', ',');
  v := replace(v, '／', '/');
  v := replace(v, '(', '');
  v := replace(v, ')', '');
  v := replace(v, '-', '');

  return v;
end;
$$;

create or replace function public.is_permanently_allowed_specialty(p_specialty text)
returns boolean
language plpgsql
immutable
as $$
declare
  v text;
begin
  v := public.normalize_specialty_name(p_specialty);

  return v in (
    public.normalize_specialty_name('الإسعاف والطوارئ (DRS/NRS/EMT/MLT)'),
    public.normalize_specialty_name('الإسعاف والطوارئ - DRS/NRS/EMT/MLT'),
    public.normalize_specialty_name('الإسعاف والطوارئ DRS,NRS,EMT/MLT'),
    public.normalize_specialty_name('DRS,NRS,EMT/MLT'),
    public.normalize_specialty_name('DRS/NRS/EMT/MLT'),
    public.normalize_specialty_name('الإسعاف والطوارئ')
  );
end;
$$;

-- =========================================================
-- RPC: manual_employee_check
-- الفحص اليدوي عند تعطل QR.
-- يتحقق من employee_id + mobile_number معًا.
-- =========================================================

create or replace function public.manual_employee_check(
  p_employee_id text,
  p_mobile_number text,
  p_qr_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reg record;
  lim record;
  used_count integer := 0;
  qr_required boolean := false;
  qr_ok boolean := true;
  clean_emp text := trim(p_employee_id);
  clean_mobile text := trim(p_mobile_number);
begin
  if clean_emp = '' or clean_mobile = '' then
    return jsonb_build_object('ok', false, 'result', 'DENIED', 'message', 'أدخل رقم الموظف ورقم الهاتف');
  end if;

  select *
  into reg
  from public.employee_registrations
  where employee_id = clean_emp
    and mobile_number = clean_mobile
  limit 1;

  if reg.id is null then
    perform public.set_guard_status('DENIED', null, clean_emp, 'الموظف غير موجود');
    return jsonb_build_object(
      'ok', true,
      'result', 'NOT_FOUND',
      'message', 'الموظف غير موجود، الرجاء التسجيل أولًا'
    );
  end if;

  if reg.status = 'PENDING' then
    insert into public.gate_access_logs (
      employee_registration_id,
      employee_id,
      mobile_number,
      full_name,
      specialty,
      result,
      reason
    )
    values (
      reg.id,
      reg.employee_id,
      reg.mobile_number,
      reg.full_name,
      reg.specialty,
      'DENIED',
      'PENDING_EMPLOYEE'
    );

    perform public.set_guard_status('DENIED', reg.full_name, reg.employee_id, 'طلب قيد المراجعة');

    return jsonb_build_object('ok', true, 'result', 'DENIED', 'message', 'طلبك قيد المراجعة');
  end if;

  if reg.status = 'REJECTED' then
    insert into public.gate_access_logs (
      employee_registration_id,
      employee_id,
      mobile_number,
      full_name,
      specialty,
      result,
      reason
    )
    values (
      reg.id,
      reg.employee_id,
      reg.mobile_number,
      reg.full_name,
      reg.specialty,
      'DENIED',
      'REJECTED_EMPLOYEE'
    );

    perform public.set_guard_status('DENIED', reg.full_name, reg.employee_id, 'تم رفض الطلب');

    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'message', 'تم رفض الطلب، يرجى مراجعة الإدارة'
    );
  end if;

  -- Reject a linked device that was disabled or revoked before consuming the
  -- QR. A row without a linked token remains eligible for the existing manual
  -- bootstrap flow. Exact token ownership is validated by auto_employee_check.
  -- Metadata access keeps this baseline compatible before the trusted-device
  -- patch creates its columns.
  if to_regprocedure('public.hash_trusted_device_token(text)') is not null
     and nullif(to_jsonb(reg)->>'trusted_device_token_hash', '') is not null
     and (
       coalesce((to_jsonb(reg)->>'trusted_device_enabled')::boolean, false) = false
       or nullif(to_jsonb(reg)->>'trusted_device_revoked_at', '') is not null
     ) then
    insert into public.gate_access_logs (
      employee_registration_id,
      employee_id,
      mobile_number,
      full_name,
      specialty,
      result,
      reason
    )
    values (
      reg.id,
      reg.employee_id,
      reg.mobile_number,
      reg.full_name,
      reg.specialty,
      'DENIED',
      'TRUSTED_DEVICE_NOT_ACTIVE'
    );

    perform public.set_guard_status('DENIED', reg.full_name, reg.employee_id, 'الجهاز الموثوق غير مفعّل');

    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'message', 'الجهاز الموثوق غير مفعّل، يرجى مراجعة الإدارة'
    );
  end if;

  if p_qr_token is not null and length(trim(p_qr_token)) > 0 then
    qr_required := true;
    qr_ok := public.validate_and_use_qr_token(p_qr_token);
  end if;

  if qr_required and qr_ok = false then
    perform public.set_guard_status('DENIED', null, clean_emp, 'QR غير صالح أو منتهي');
    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'message', 'QR غير صالح أو منتهي، يرجى مسح QR جديد'
    );
  end if;

  -- Permanently allowed specialty group:
  -- الإسعاف والطوارئ (DRS/NRS/EMT/MLT)
  -- هذا الاختصاص لا يدخل في specialty_daily_limits ولا يتحول إلى LIMITED.
  if public.is_permanently_allowed_specialty(reg.specialty) then
    insert into public.gate_access_logs (
      employee_registration_id,
      employee_id,
      mobile_number,
      full_name,
      specialty,
      result,
      reason,
      qr_token
    )
    values (
      reg.id,
      reg.employee_id,
      reg.mobile_number,
      reg.full_name,
      reg.specialty,
      'ALLOWED',
      'PERMANENTLY_ALLOWED_SPECIALTY',
      case when p_qr_token is null or p_qr_token = '' then null else p_qr_token::uuid end
    );

    perform public.set_guard_status(
      'ALLOWED',
      reg.full_name,
      reg.employee_id,
      'مسموح بالدخول — اختصاص مسموح دائمًا'
    );

    return jsonb_build_object(
      'ok', true,
      'result', 'ALLOWED',
      'message', 'مسموح بالدخول — اختصاص مسموح دائمًا'
    );
  end if;

  -- APPROVED employee: check specialty limit.
  select *
  into lim
  from public.specialty_daily_limits
  where specialty_name = reg.specialty
    and is_active = true
  limit 1;

  if lim.id is not null then
    select count(*)
    into used_count
    from public.gate_access_logs
    where specialty = reg.specialty
      and result = 'LIMITED'
      and created_at >= date_trunc('day', now())
      and created_at < date_trunc('day', now()) + interval '1 day';

    if used_count >= lim.daily_limit then
      insert into public.gate_access_logs (
        employee_registration_id,
        employee_id,
        mobile_number,
        full_name,
        specialty,
        result,
        reason
      )
      values (
        reg.id,
        reg.employee_id,
        reg.mobile_number,
        reg.full_name,
        reg.specialty,
        'DENIED',
        'SPECIALTY_DAILY_LIMIT_REACHED'
      );

      perform public.set_guard_status('DENIED', reg.full_name, reg.employee_id, 'تم الوصول للحد اليومي لهذا الاختصاص');

      return jsonb_build_object(
        'ok', true,
        'result', 'DENIED',
        'message', 'غير مسموح — تم الوصول للحد اليومي لهذا الاختصاص'
      );
    end if;

    insert into public.gate_access_logs (
      employee_registration_id,
      employee_id,
      mobile_number,
      full_name,
      specialty,
      result,
      reason,
      qr_token
    )
    values (
      reg.id,
      reg.employee_id,
      reg.mobile_number,
      reg.full_name,
      reg.specialty,
      'LIMITED',
      'SPECIALTY_LIMITED_ACCESS',
      case when p_qr_token is null or p_qr_token = '' then null else p_qr_token::uuid end
    );

    perform public.set_guard_status('LIMITED', reg.full_name, reg.employee_id, 'مسموح جزئيًا حسب الاختصاص');

    return jsonb_build_object('ok', true, 'result', 'LIMITED', 'message', 'مسموح جزئيًا حسب الاختصاص');
  end if;

  insert into public.gate_access_logs (
    employee_registration_id,
    employee_id,
    mobile_number,
    full_name,
    specialty,
    result,
    reason,
    qr_token
  )
  values (
    reg.id,
    reg.employee_id,
    reg.mobile_number,
    reg.full_name,
    reg.specialty,
    'ALLOWED',
    'APPROVED_EMPLOYEE',
    case when p_qr_token is null or p_qr_token = '' then null else p_qr_token::uuid end
  );

  perform public.set_guard_status('ALLOWED', reg.full_name, reg.employee_id, 'مسموح بالدخول');

  return jsonb_build_object('ok', true, 'result', 'ALLOWED', 'message', 'مسموح بالدخول');
end;
$$;

-- =========================================================
-- RPC: submit_violation_report
-- =========================================================

create or replace function public.submit_violation_report(
  p_employee_id text,
  p_note text,
  p_photo_url text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  new_id uuid;
begin
  if p_photo_url is null or trim(p_photo_url) = '' then
    return jsonb_build_object('ok', false, 'message', 'الصورة مطلوبة');
  end if;

  insert into public.violation_reports (employee_id, note, photo_url)
  values (nullif(trim(p_employee_id), ''), nullif(trim(p_note), ''), trim(p_photo_url))
  returning id into new_id;

  return jsonb_build_object('ok', true, 'id', new_id, 'message', 'تم إرسال المخالفة إلى الإدارة');
end;
$$;

-- =========================================================
-- ADMIN RPC: update registration status
-- =========================================================

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
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'message', 'غير مصرح');
  end if;

  if p_status not in ('APPROVED', 'REJECTED') then
    return jsonb_build_object('ok', false, 'message', 'حالة غير صحيحة');
  end if;

  update public.employee_registrations
  set status = p_status,
      approved_at = case when p_status = 'APPROVED' then now() else approved_at end,
      approved_by = case when p_status = 'APPROVED' then auth.uid() else approved_by end,
      rejected_at = case when p_status = 'REJECTED' then now() else rejected_at end,
      rejected_by = case when p_status = 'REJECTED' then auth.uid() else rejected_by end
  where id = p_registration_id
  returning * into reg;

  insert into public.admin_audit_logs (
    admin_auth_user_id,
    action,
    target_table,
    target_id,
    details
  )
  values (
    auth.uid(),
    'UPDATE_REGISTRATION_STATUS',
    'employee_registrations',
    p_registration_id::text,
    jsonb_build_object('status', p_status)
  );

  return jsonb_build_object('ok', true, 'message', 'تم تحديث الطلب');
end;
$$;

-- =========================================================
-- ADMIN RPC: save specialty limit
-- =========================================================

create or replace function public.admin_upsert_specialty_limit(
  p_specialty_name text,
  p_daily_limit integer,
  p_is_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_super_admin() then
    return jsonb_build_object('ok', false, 'message', 'هذه العملية للسوبر أدمن فقط');
  end if;

  if trim(p_specialty_name) = '' then
    return jsonb_build_object('ok', false, 'message', 'اسم الاختصاص مطلوب');
  end if;

  insert into public.specialty_daily_limits (
    specialty_name,
    daily_limit,
    is_active,
    updated_at
  )
  values (
    trim(p_specialty_name),
    greatest(p_daily_limit, 0),
    p_is_active,
    now()
  )
  on conflict (specialty_name)
  do update set daily_limit = excluded.daily_limit,
                is_active = excluded.is_active,
                updated_at = now();

  insert into public.admin_audit_logs (
    admin_auth_user_id,
    action,
    target_table,
    details
  )
  values (
    auth.uid(),
    'UPSERT_SPECIALTY_LIMIT',
    'specialty_daily_limits',
    jsonb_build_object(
      'specialty',
      p_specialty_name,
      'daily_limit',
      p_daily_limit,
      'is_active',
      p_is_active
    )
  );

  return jsonb_build_object('ok', true, 'message', 'تم حفظ حد الاختصاص');
end;
$$;

-- =========================================================
-- ADMIN RPC: update violation status
-- =========================================================

create or replace function public.admin_update_violation_status(
  p_violation_id uuid,
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'message', 'غير مصرح');
  end if;

  if p_status not in ('NEW', 'REVIEWED', 'RESOLVED') then
    return jsonb_build_object('ok', false, 'message', 'حالة غير صحيحة');
  end if;

  update public.violation_reports
  set status = p_status,
      reviewed_at = now(),
      reviewed_by = auth.uid()
  where id = p_violation_id;

  insert into public.admin_audit_logs (
    admin_auth_user_id,
    action,
    target_table,
    target_id,
    details
  )
  values (
    auth.uid(),
    'UPDATE_VIOLATION_STATUS',
    'violation_reports',
    p_violation_id::text,
    jsonb_build_object('status', p_status)
  );

  return jsonb_build_object('ok', true, 'message', 'تم تحديث البلاغ');
end;
$$;

-- =========================================================
-- SUPER ADMIN RPC: add / update admin profile
-- =========================================================

create or replace function public.super_admin_upsert_admin_profile(
  p_email text,
  p_full_name text,
  p_role text,
  p_is_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  target_user record;
begin
  if not public.is_super_admin() then
    return jsonb_build_object('ok', false, 'message', 'هذه العملية للسوبر أدمن فقط');
  end if;

  if p_role not in ('SUPER_ADMIN', 'SUB_ADMIN') then
    return jsonb_build_object('ok', false, 'message', 'دور غير صحيح');
  end if;

  select id, email
  into target_user
  from auth.users
  where lower(email) = lower(trim(p_email))
  limit 1;

  if target_user.id is null then
    return jsonb_build_object('ok', false, 'message', 'يجب إنشاء المستخدم أولًا من Supabase Auth');
  end if;

  insert into public.admin_profiles (
    auth_user_id,
    email,
    full_name,
    role,
    is_active
  )
  values (
    target_user.id,
    target_user.email,
    p_full_name,
    p_role,
    p_is_active
  )
  on conflict (auth_user_id)
  do update set full_name = excluded.full_name,
                role = excluded.role,
                is_active = excluded.is_active;

  insert into public.admin_audit_logs (
    admin_auth_user_id,
    action,
    target_table,
    details
  )
  values (
    auth.uid(),
    'UPSERT_ADMIN_PROFILE',
    'admin_profiles',
    jsonb_build_object(
      'email',
      p_email,
      'role',
      p_role,
      'is_active',
      p_is_active
    )
  );

  return jsonb_build_object('ok', true, 'message', 'تم حفظ المشرف');
end;
$$;

-- =========================================================
-- DEFAULT SPECIALTY LIMITS
-- تستطيعين تعديلها لاحقًا من لوحة الأدمن.
-- =========================================================

insert into public.specialty_daily_limits (specialty_name, daily_limit, is_active)
values
('أطباء الاختصاصات الأخرى', 10, true),
('الأشعة', 5, true),
('المختبر', 5, true),
('التمريض', 20, false),
('التخدير', 5, false),
('الإدارة', 0, false),
('غير ذلك', 0, false)
on conflict (specialty_name) do nothing;

-- =========================================================
-- REALTIME
-- يجعل Realtime أكثر موثوقية.
-- إذا ظهر خطأ أن الجدول already member of publication، تجاهليه.
-- =========================================================

alter table public.guard_screen_status replica identity full;
alter table public.employee_registrations replica identity full;
alter table public.violation_reports replica identity full;
alter table public.gate_access_logs replica identity full;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'guard_screen_status'
  ) then
    alter publication supabase_realtime add table public.guard_screen_status;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'employee_registrations'
  ) then
    alter publication supabase_realtime add table public.employee_registrations;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'violation_reports'
  ) then
    alter publication supabase_realtime add table public.violation_reports;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'gate_access_logs'
  ) then
    alter publication supabase_realtime add table public.gate_access_logs;
  end if;
end $$;

-- =========================================================
-- SUPER ADMIN SETUP
-- بعد إنشاء مستخدمك في Supabase Authentication → Users:
--
-- 1) انسخي User UID.
-- 2) بدلي القيم في الكود التالي.
-- 3) شغليه لوحده.
-- =========================================================

-- insert into public.admin_profiles (
--   auth_user_id,
--   email,
--   full_name,
--   role,
--   is_active
-- )
-- values (
--   'PASTE_YOUR_AUTH_USER_UID_HERE',
--   'PASTE_YOUR_AUTH_EMAIL_HERE',
--   'PASTE_YOUR_NAME_HERE',
--   'SUPER_ADMIN',
--   true
-- )
-- on conflict (auth_user_id)
-- do update set
--   email = excluded.email,
--   full_name = excluded.full_name,
--   role = 'SUPER_ADMIN',
--   is_active = true;


-- =========================================================
-- V1.1 PATCH — Hospital identity, final specialties, admin phone + permissions
-- يمكن تشغيل هذا الجزء بأمان حتى لو كان schema.sql شُغّل سابقًا.
-- =========================================================

alter table public.admin_profiles
add column if not exists phone_number text;

alter table public.admin_profiles
add column if not exists permissions jsonb not null default '{"can_approve_requests": true, "can_review_violations": true, "can_view_logs": true, "can_export_csv": false, "can_manage_limits": false, "can_view_audit": false}'::jsonb;

create or replace function public.default_admin_permissions(p_role text)
returns jsonb
language sql
stable
as $$
  select case
    when p_role = 'SUPER_ADMIN' then '{"can_approve_requests": true, "can_review_violations": true, "can_view_logs": true, "can_export_csv": true, "can_manage_limits": true, "can_view_audit": true}'::jsonb
    else '{"can_approve_requests": true, "can_review_violations": true, "can_view_logs": true, "can_export_csv": false, "can_manage_limits": false, "can_view_audit": false}'::jsonb
  end;
$$;

create or replace function public.has_admin_permission(p_permission text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  prof record;
begin
  select role, permissions, is_active
  into prof
  from public.admin_profiles
  where auth_user_id = auth.uid()
    and is_active = true
  limit 1;

  if prof.role = 'SUPER_ADMIN' then
    return true;
  end if;

  if prof.role is null then
    return false;
  end if;

  return coalesce((prof.permissions ->> p_permission)::boolean, false);
exception when others then
  return false;
end;
$$;

drop policy if exists "Admins can read violation photos" on storage.objects;
create policy "Admins can read violation photos"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'violation-photos'
  and (public.is_super_admin() or public.has_admin_permission('can_review_violations'))
);

-- تحديث الاختصاصات النهائية والحد = 7
update public.specialty_daily_limits
set is_active = false
where specialty_name not in (
  'جراحة عامة',
  'باطني',
  'ENT',
  'نسائية',
  'مسالك بولية',
  'عيون',
  'جراحة دماغ وأعصاب',
  'تخدير',
  'طب عام',
  'جراحة أوعية دموية',
  'أخرى'
);

insert into public.specialty_daily_limits (specialty_name, daily_limit, is_active)
values
('جراحة عامة', 7, true),
('باطني', 7, true),
('ENT', 7, true),
('نسائية', 7, true),
('مسالك بولية', 7, true),
('عيون', 7, true),
('جراحة دماغ وأعصاب', 7, true),
('تخدير', 7, true),
('طب عام', 7, true),
('جراحة أوعية دموية', 7, true),
('أخرى', 7, true)
on conflict (specialty_name)
do update set
  daily_limit = 7,
  is_active = true,
  updated_at = now();

-- RLS policies updated for permissions
drop policy if exists "Admins can read admin profiles" on public.admin_profiles;
create policy "Admins can read admin profiles"
on public.admin_profiles
for select
to authenticated
using (
  auth_user_id = auth.uid()
  or public.is_super_admin()
);

drop policy if exists "Super admin can manage admin profiles" on public.admin_profiles;
create policy "Super admin can manage admin profiles"
on public.admin_profiles
for all
to authenticated
using (public.is_super_admin())
with check (public.is_super_admin());

drop policy if exists "Admins can read registrations" on public.employee_registrations;
create policy "Admins can read registrations"
on public.employee_registrations
for select
to authenticated
using (public.is_super_admin() or public.has_admin_permission('can_approve_requests'));

drop policy if exists "Admins can update registrations" on public.employee_registrations;
create policy "Admins can update registrations"
on public.employee_registrations
for update
to authenticated
using (public.is_super_admin() or public.has_admin_permission('can_approve_requests'))
with check (public.is_super_admin() or public.has_admin_permission('can_approve_requests'));

drop policy if exists "Admins can read access logs" on public.gate_access_logs;
create policy "Admins can read access logs"
on public.gate_access_logs
for select
to authenticated
using (public.is_super_admin() or public.has_admin_permission('can_view_logs'));

drop policy if exists "Admins can read violation reports" on public.violation_reports;
create policy "Admins can read violation reports"
on public.violation_reports
for select
to authenticated
using (public.is_super_admin() or public.has_admin_permission('can_review_violations'));

drop policy if exists "Admins can update violation reports" on public.violation_reports;
create policy "Admins can update violation reports"
on public.violation_reports
for update
to authenticated
using (public.is_super_admin() or public.has_admin_permission('can_review_violations'))
with check (public.is_super_admin() or public.has_admin_permission('can_review_violations'));

drop policy if exists "Super admin can manage specialty limits" on public.specialty_daily_limits;
create policy "Super admin can manage specialty limits"
on public.specialty_daily_limits
for all
to authenticated
using (public.is_super_admin() or public.has_admin_permission('can_manage_limits'))
with check (public.is_super_admin() or public.has_admin_permission('can_manage_limits'));

drop policy if exists "Admins can read audit logs" on public.admin_audit_logs;
create policy "Admins can read audit logs"
on public.admin_audit_logs
for select
to authenticated
using (public.is_super_admin() or public.has_admin_permission('can_view_audit'));

-- Updated profile function
create or replace function public.get_my_admin_profile()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  prof record;
begin
  select *
  into prof
  from public.admin_profiles
  where auth_user_id = auth.uid()
    and is_active = true
  limit 1;

  if prof.id is null then
    return jsonb_build_object('ok', false, 'message', 'غير مصرح لك بالدخول');
  end if;

  return jsonb_build_object(
    'ok', true,
    'id', prof.id,
    'email', prof.email,
    'full_name', prof.full_name,
    'phone_number', prof.phone_number,
    'role', prof.role,
    'permissions', coalesce(prof.permissions, public.default_admin_permissions(prof.role))
  );
end;
$$;

-- Updated admin registration action with permission check
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
      rejected_by = case when p_status = 'REJECTED' then auth.uid() else rejected_by end
  where id = p_registration_id
  returning * into reg;

  insert into public.admin_audit_logs (
    admin_auth_user_id,
    action,
    target_table,
    target_id,
    details
  )
  values (
    auth.uid(),
    'UPDATE_REGISTRATION_STATUS',
    'employee_registrations',
    p_registration_id::text,
    jsonb_build_object('status', p_status)
  );

  return jsonb_build_object('ok', true, 'message', 'تم تحديث الطلب');
end;
$$;

-- Updated specialty limits function with permissions
create or replace function public.admin_upsert_specialty_limit(
  p_specialty_name text,
  p_daily_limit integer,
  p_is_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (public.is_super_admin() or public.has_admin_permission('can_manage_limits')) then
    return jsonb_build_object('ok', false, 'message', 'غير مصرح لك بتعديل حدود الاختصاصات');
  end if;

  if trim(p_specialty_name) = '' then
    return jsonb_build_object('ok', false, 'message', 'اسم الاختصاص مطلوب');
  end if;

  insert into public.specialty_daily_limits (
    specialty_name,
    daily_limit,
    is_active,
    updated_at
  )
  values (
    trim(p_specialty_name),
    greatest(p_daily_limit, 0),
    p_is_active,
    now()
  )
  on conflict (specialty_name)
  do update set daily_limit = excluded.daily_limit,
                is_active = excluded.is_active,
                updated_at = now();

  insert into public.admin_audit_logs (
    admin_auth_user_id,
    action,
    target_table,
    details
  )
  values (
    auth.uid(),
    'UPSERT_SPECIALTY_LIMIT',
    'specialty_daily_limits',
    jsonb_build_object(
      'specialty',
      p_specialty_name,
      'daily_limit',
      p_daily_limit,
      'is_active',
      p_is_active
    )
  );

  return jsonb_build_object('ok', true, 'message', 'تم حفظ حد الاختصاص');
end;
$$;

-- Updated violation status function with permissions
create or replace function public.admin_update_violation_status(
  p_violation_id uuid,
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (public.is_super_admin() or public.has_admin_permission('can_review_violations')) then
    return jsonb_build_object('ok', false, 'message', 'غير مصرح لك بمراجعة البلاغات');
  end if;

  if p_status not in ('NEW', 'REVIEWED', 'RESOLVED') then
    return jsonb_build_object('ok', false, 'message', 'حالة غير صحيحة');
  end if;

  update public.violation_reports
  set status = p_status,
      reviewed_at = now(),
      reviewed_by = auth.uid()
  where id = p_violation_id;

  insert into public.admin_audit_logs (
    admin_auth_user_id,
    action,
    target_table,
    target_id,
    details
  )
  values (
    auth.uid(),
    'UPDATE_VIOLATION_STATUS',
    'violation_reports',
    p_violation_id::text,
    jsonb_build_object('status', p_status)
  );

  return jsonb_build_object('ok', true, 'message', 'تم تحديث البلاغ');
end;
$$;

-- Updated super admin function: add/update admins with phone and permissions
create or replace function public.super_admin_upsert_admin_profile(
  p_email text,
  p_full_name text,
  p_phone_number text,
  p_role text,
  p_is_active boolean,
  p_permissions jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  target_user record;
  final_permissions jsonb;
begin
  if not public.is_super_admin() then
    return jsonb_build_object('ok', false, 'message', 'هذه العملية للسوبر أدمن فقط');
  end if;

  if p_role not in ('SUPER_ADMIN', 'SUB_ADMIN') then
    return jsonb_build_object('ok', false, 'message', 'دور غير صحيح');
  end if;

  select id, email
  into target_user
  from auth.users
  where lower(email) = lower(trim(p_email))
  limit 1;

  if target_user.id is null then
    return jsonb_build_object('ok', false, 'message', 'يجب إنشاء المستخدم أولًا من Supabase Auth بنفس الإيميل');
  end if;

  final_permissions := coalesce(p_permissions, public.default_admin_permissions(p_role));

  insert into public.admin_profiles (
    auth_user_id,
    email,
    full_name,
    phone_number,
    role,
    is_active,
    permissions
  )
  values (
    target_user.id,
    target_user.email,
    p_full_name,
    p_phone_number,
    p_role,
    p_is_active,
    final_permissions
  )
  on conflict (auth_user_id)
  do update set full_name = excluded.full_name,
                phone_number = excluded.phone_number,
                role = excluded.role,
                is_active = excluded.is_active,
                permissions = excluded.permissions;

  insert into public.admin_audit_logs (
    admin_auth_user_id,
    action,
    target_table,
    details
  )
  values (
    auth.uid(),
    'UPSERT_ADMIN_PROFILE',
    'admin_profiles',
    jsonb_build_object(
      'email',
      p_email,
      'full_name',
      p_full_name,
      'phone_number',
      p_phone_number,
      'role',
      p_role,
      'is_active',
      p_is_active,
      'permissions',
      final_permissions
    )
  );

  return jsonb_build_object('ok', true, 'message', 'تم حفظ المشرف');
end;
$$;

create or replace function public.super_admin_disable_admin_profile(
  p_admin_profile_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_super_admin() then
    return jsonb_build_object('ok', false, 'message', 'هذه العملية للسوبر أدمن فقط');
  end if;

  if exists (
    select 1 from public.admin_profiles
    where id = p_admin_profile_id
      and auth_user_id = auth.uid()
  ) then
    return jsonb_build_object('ok', false, 'message', 'لا يمكنك تعطيل حسابك الحالي');
  end if;

  update public.admin_profiles
  set is_active = false
  where id = p_admin_profile_id;

  insert into public.admin_audit_logs (
    admin_auth_user_id,
    action,
    target_table,
    target_id
  )
  values (
    auth.uid(),
    'DISABLE_ADMIN_PROFILE',
    'admin_profiles',
    p_admin_profile_id::text
  );

  return jsonb_build_object('ok', true, 'message', 'تم تعطيل المشرف');
end;
$$;

create or replace function public.super_admin_delete_admin_profile(
  p_admin_profile_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_super_admin() then
    return jsonb_build_object('ok', false, 'message', 'هذه العملية للسوبر أدمن فقط');
  end if;

  if exists (
    select 1 from public.admin_profiles
    where id = p_admin_profile_id
      and auth_user_id = auth.uid()
  ) then
    return jsonb_build_object('ok', false, 'message', 'لا يمكنك حذف حسابك الحالي');
  end if;

  delete from public.admin_profiles
  where id = p_admin_profile_id;

  insert into public.admin_audit_logs (
    admin_auth_user_id,
    action,
    target_table,
    target_id
  )
  values (
    auth.uid(),
    'DELETE_ADMIN_PROFILE',
    'admin_profiles',
    p_admin_profile_id::text
  );

  return jsonb_build_object('ok', true, 'message', 'تم حذف المشرف من لوحة الإدارة');
end;
$$;

-- Optional: update an existing super admin record after replacing the email below.
-- update public.admin_profiles
-- set full_name = 'Super Admin',
--     permissions = public.default_admin_permissions('SUPER_ADMIN')
-- where lower(email) = lower('admin@example.com')
--   and role = 'SUPER_ADMIN';


-- =========================================================
-- schema_patch_qr_claim.sql
-- Emergency Room Parking V1.6
--
-- السبب:
-- QR token صالح 30 ثانية فقط. إذا الموظف مسح QR ثم أخذ وقتًا بإدخال بياناته،
-- كان النظام يرفضه لأن token انتهى قبل الضغط على إرسال.
--
-- الحل:
-- عند فتح verify.html من QR، يتم Claim للـ QR فورًا خلال أول 30 ثانية.
-- بعدها يحصل المستخدم على claim_token صالح لمدة 5 دقائق لإكمال النموذج.
--
-- الأمان:
-- - QR الأصلي يبقى صالح 30 ثانية فقط.
-- - بمجرد أن يفتحه أول شخص، يتم استعماله ولا يعود صالحًا لشخص آخر.
-- - claim_token يستخدم مرة واحدة فقط.
-- =========================================================

alter table public.qr_sessions
add column if not exists claim_token uuid unique;

alter table public.qr_sessions
add column if not exists claimed_at timestamptz;

alter table public.qr_sessions
add column if not exists claim_expires_at timestamptz;

alter table public.qr_sessions
add column if not exists claim_used_at timestamptz;

create index if not exists idx_qr_sessions_claim_token
on public.qr_sessions(claim_token);

create index if not exists idx_qr_sessions_claim_expires_at
on public.qr_sessions(claim_expires_at);

create or replace function public.claim_qr_session(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  token_uuid uuid;
  found_id uuid;
  new_claim uuid := gen_random_uuid();
begin
  if p_token is null or length(trim(p_token)) = 0 then
    return jsonb_build_object(
      'ok', false,
      'message', 'QR غير موجود'
    );
  end if;

  begin
    token_uuid := p_token::uuid;
  exception when others then
    return jsonb_build_object(
      'ok', false,
      'message', 'QR غير صحيح'
    );
  end;

  select id
  into found_id
  from public.qr_sessions
  where token = token_uuid
    and used_at is null
    and expires_at > now()
  limit 1;

  if found_id is null then
    return jsonb_build_object(
      'ok', false,
      'message', 'QR غير صالح أو منتهي، يرجى مسح QR جديد من شاشة الحارس'
    );
  end if;

  update public.qr_sessions
  set used_at = now(),
      claimed_at = now(),
      claim_token = new_claim,
      claim_expires_at = now() + interval '5 minutes',
      claim_used_at = null
  where id = found_id;

  return jsonb_build_object(
    'ok', true,
    'claim_token', new_claim::text,
    'expires_in_seconds', 300,
    'message', 'تم تفعيل جلسة QR، أكمل البيانات خلال 5 دقائق'
  );
end;
$$;

create or replace function public.validate_and_use_qr_token(p_token text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  input_uuid uuid;
  found_id uuid;
begin
  if p_token is null or length(trim(p_token)) = 0 then
    return false;
  end if;

  begin
    input_uuid := p_token::uuid;
  exception when others then
    return false;
  end;

  -- Backward compatibility: direct QR token use within original 30 seconds.
  select id
  into found_id
  from public.qr_sessions
  where token = input_uuid
    and used_at is null
    and expires_at > now()
  limit 1;

  if found_id is not null then
    update public.qr_sessions
    set used_at = now()
    where id = found_id;

    return true;
  end if;

  -- V1.6: claimed QR token. User opened QR on time, then has 5 minutes to submit form.
  select id
  into found_id
  from public.qr_sessions
  where claim_token = input_uuid
    and claim_used_at is null
    and claim_expires_at > now()
  limit 1;

  if found_id is not null then
    update public.qr_sessions
    set claim_used_at = now()
    where id = found_id;

    return true;
  end if;

  return false;
end;
$$;

grant execute on function public.claim_qr_session(text) to anon, authenticated;
grant execute on function public.validate_and_use_qr_token(text) to anon, authenticated;

notify pgrst, 'reload schema';

-- اختبار سريع بعد التشغيل:
-- افتحي QR جديد من شاشة الحارس، امسحيه، يجب أن يظهر في صفحة verify أن جلسة QR فعالة.

-- =============================================================================
-- [2/14] SOURCE FILE: schema_patch_pgcrypto_schema_fix.sql
-- =============================================================================

-- ALBASHIR Gate: pgcrypto schema compatibility fix for existing Supabase projects.
-- Safe to run more than once. It does not modify employee or access-log data.

begin;

create extension if not exists "pgcrypto" with schema extensions;

create or replace function public.hash_trusted_device_token(p_token text)
returns text
language sql
immutable
set search_path = public, extensions
as $$
  select encode(extensions.digest(trim(coalesce(p_token, '')), 'sha256'), 'hex');
$$;

create or replace function public.hash_offline_device_token(p_token text)
returns text
language sql
immutable
set search_path = public, extensions
as $$
  select encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
$$;

commit;

notify pgrst, 'reload schema';

-- =============================================================================
-- [3/14] SOURCE FILE: schema_patch_permanent_specialty.sql
-- =============================================================================

-- =========================================================
-- PATCH: Permanently allowed specialty option
-- الإسعاف والطوارئ (DRS/NRS/EMT/MLT)
-- شغّلي هذا الملف في Supabase SQL Editor إذا كانت قاعدة البيانات موجودة مسبقًا.
-- =========================================================

create or replace function public.normalize_specialty_name(p_specialty text)
returns text
language plpgsql
immutable
as $$
declare
  v text;
begin
  v := upper(trim(coalesce(p_specialty, '')));

  v := replace(v, 'أ', 'ا');
  v := replace(v, 'إ', 'ا');
  v := replace(v, 'آ', 'ا');
  v := replace(v, 'ٱ', 'ا');
  v := replace(v, 'ة', 'ه');

  v := regexp_replace(v, '\s+', '', 'g');
  v := replace(v, '،', ',');
  v := replace(v, '／', '/');
  v := replace(v, '(', '');
  v := replace(v, ')', '');
  v := replace(v, '-', '');

  return v;
end;
$$;

create or replace function public.is_permanently_allowed_specialty(p_specialty text)
returns boolean
language plpgsql
immutable
as $$
declare
  v text;
begin
  v := public.normalize_specialty_name(p_specialty);

  return v in (
    public.normalize_specialty_name('الإسعاف والطوارئ (DRS/NRS/EMT/MLT)'),
    public.normalize_specialty_name('الإسعاف والطوارئ - DRS/NRS/EMT/MLT'),
    public.normalize_specialty_name('الإسعاف والطوارئ DRS,NRS,EMT/MLT'),
    public.normalize_specialty_name('DRS,NRS,EMT/MLT'),
    public.normalize_specialty_name('DRS/NRS/EMT/MLT'),
    public.normalize_specialty_name('الإسعاف والطوارئ')
  );
end;
$$;

create or replace function public.manual_employee_check(
  p_employee_id text,
  p_mobile_number text,
  p_qr_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reg record;
  lim record;
  used_count integer := 0;
  qr_required boolean := false;
  qr_ok boolean := true;
  clean_emp text := trim(p_employee_id);
  clean_mobile text := trim(p_mobile_number);
begin
  if clean_emp = '' or clean_mobile = '' then
    return jsonb_build_object('ok', false, 'result', 'DENIED', 'message', 'أدخل رقم الموظف ورقم الهاتف');
  end if;

  select *
  into reg
  from public.employee_registrations
  where employee_id = clean_emp
    and mobile_number = clean_mobile
  limit 1;

  if reg.id is null then
    perform public.set_guard_status('DENIED', null, clean_emp, 'الموظف غير موجود');
    return jsonb_build_object(
      'ok', true,
      'result', 'NOT_FOUND',
      'message', 'الموظف غير موجود، الرجاء التسجيل أولًا'
    );
  end if;

  if reg.status = 'PENDING' then
    insert into public.gate_access_logs (
      employee_registration_id,
      employee_id,
      mobile_number,
      full_name,
      specialty,
      result,
      reason
    )
    values (
      reg.id,
      reg.employee_id,
      reg.mobile_number,
      reg.full_name,
      reg.specialty,
      'DENIED',
      'PENDING_EMPLOYEE'
    );

    perform public.set_guard_status('DENIED', reg.full_name, reg.employee_id, 'طلب قيد المراجعة');

    return jsonb_build_object('ok', true, 'result', 'DENIED', 'message', 'طلبك قيد المراجعة');
  end if;

  if reg.status = 'REJECTED' then
    insert into public.gate_access_logs (
      employee_registration_id,
      employee_id,
      mobile_number,
      full_name,
      specialty,
      result,
      reason
    )
    values (
      reg.id,
      reg.employee_id,
      reg.mobile_number,
      reg.full_name,
      reg.specialty,
      'DENIED',
      'REJECTED_EMPLOYEE'
    );

    perform public.set_guard_status('DENIED', reg.full_name, reg.employee_id, 'تم رفض الطلب');

    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'message', 'تم رفض الطلب، يرجى مراجعة الإدارة'
    );
  end if;

  -- Reject a linked device that was disabled or revoked before consuming the
  -- QR. A row without a linked token remains eligible for the existing manual
  -- bootstrap flow. Exact token ownership is validated by auto_employee_check.
  -- Metadata access keeps this patch compatible before the trusted-device
  -- columns are introduced.
  if to_regprocedure('public.hash_trusted_device_token(text)') is not null
     and nullif(to_jsonb(reg)->>'trusted_device_token_hash', '') is not null
     and (
       coalesce((to_jsonb(reg)->>'trusted_device_enabled')::boolean, false) = false
       or nullif(to_jsonb(reg)->>'trusted_device_revoked_at', '') is not null
     ) then
    insert into public.gate_access_logs (
      employee_registration_id,
      employee_id,
      mobile_number,
      full_name,
      specialty,
      result,
      reason
    )
    values (
      reg.id,
      reg.employee_id,
      reg.mobile_number,
      reg.full_name,
      reg.specialty,
      'DENIED',
      'TRUSTED_DEVICE_NOT_ACTIVE'
    );

    perform public.set_guard_status('DENIED', reg.full_name, reg.employee_id, 'الجهاز الموثوق غير مفعّل');

    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'message', 'الجهاز الموثوق غير مفعّل، يرجى مراجعة الإدارة'
    );
  end if;

  if p_qr_token is not null and length(trim(p_qr_token)) > 0 then
    qr_required := true;
    qr_ok := public.validate_and_use_qr_token(p_qr_token);
  end if;

  if qr_required and qr_ok = false then
    perform public.set_guard_status('DENIED', null, clean_emp, 'QR غير صالح أو منتهي');
    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'message', 'QR غير صالح أو منتهي، يرجى مسح QR جديد'
    );
  end if;

  -- Permanently allowed specialty group:
  -- الإسعاف والطوارئ (DRS/NRS/EMT/MLT)
  -- هذا الاختصاص لا يدخل في specialty_daily_limits ولا يتحول إلى LIMITED.
  if public.is_permanently_allowed_specialty(reg.specialty) then
    insert into public.gate_access_logs (
      employee_registration_id,
      employee_id,
      mobile_number,
      full_name,
      specialty,
      result,
      reason,
      qr_token
    )
    values (
      reg.id,
      reg.employee_id,
      reg.mobile_number,
      reg.full_name,
      reg.specialty,
      'ALLOWED',
      'PERMANENTLY_ALLOWED_SPECIALTY',
      case when p_qr_token is null or p_qr_token = '' then null else p_qr_token::uuid end
    );

    perform public.set_guard_status(
      'ALLOWED',
      reg.full_name,
      reg.employee_id,
      'مسموح بالدخول — اختصاص مسموح دائمًا'
    );

    return jsonb_build_object(
      'ok', true,
      'result', 'ALLOWED',
      'message', 'مسموح بالدخول — اختصاص مسموح دائمًا'
    );
  end if;

  -- APPROVED employee: check specialty limit.
  select *
  into lim
  from public.specialty_daily_limits
  where specialty_name = reg.specialty
    and is_active = true
  limit 1;

  if lim.id is not null then
    select count(*)
    into used_count
    from public.gate_access_logs
    where specialty = reg.specialty
      and result = 'LIMITED'
      and created_at >= date_trunc('day', now())
      and created_at < date_trunc('day', now()) + interval '1 day';

    if used_count >= lim.daily_limit then
      insert into public.gate_access_logs (
        employee_registration_id,
        employee_id,
        mobile_number,
        full_name,
        specialty,
        result,
        reason
      )
      values (
        reg.id,
        reg.employee_id,
        reg.mobile_number,
        reg.full_name,
        reg.specialty,
        'DENIED',
        'SPECIALTY_DAILY_LIMIT_REACHED'
      );

      perform public.set_guard_status('DENIED', reg.full_name, reg.employee_id, 'تم الوصول للحد اليومي لهذا الاختصاص');

      return jsonb_build_object(
        'ok', true,
        'result', 'DENIED',
        'message', 'غير مسموح — تم الوصول للحد اليومي لهذا الاختصاص'
      );
    end if;

    insert into public.gate_access_logs (
      employee_registration_id,
      employee_id,
      mobile_number,
      full_name,
      specialty,
      result,
      reason,
      qr_token
    )
    values (
      reg.id,
      reg.employee_id,
      reg.mobile_number,
      reg.full_name,
      reg.specialty,
      'LIMITED',
      'SPECIALTY_LIMITED_ACCESS',
      case when p_qr_token is null or p_qr_token = '' then null else p_qr_token::uuid end
    );

    perform public.set_guard_status('LIMITED', reg.full_name, reg.employee_id, 'مسموح جزئيًا حسب الاختصاص');

    return jsonb_build_object('ok', true, 'result', 'LIMITED', 'message', 'مسموح جزئيًا حسب الاختصاص');
  end if;

  insert into public.gate_access_logs (
    employee_registration_id,
    employee_id,
    mobile_number,
    full_name,
    specialty,
    result,
    reason,
    qr_token
  )
  values (
    reg.id,
    reg.employee_id,
    reg.mobile_number,
    reg.full_name,
    reg.specialty,
    'ALLOWED',
    'APPROVED_EMPLOYEE',
    case when p_qr_token is null or p_qr_token = '' then null else p_qr_token::uuid end
  );

  perform public.set_guard_status('ALLOWED', reg.full_name, reg.employee_id, 'مسموح بالدخول');

  return jsonb_build_object('ok', true, 'result', 'ALLOWED', 'message', 'مسموح بالدخول');
end;
$$;

notify pgrst, 'reload schema';

-- بعد تشغيل الباتش: الموظف APPROVED صاحب هذا الاختصاص سيظهر ALLOWED دائمًا.

-- =============================================================================
-- [4/14] SOURCE FILE: schema_patch_auto_verify.sql
-- =============================================================================

-- =========================================================
-- schema_patch_auto_verify.sql
-- Emergency Room Parking - Auto trusted-device verification
--
-- الهدف:
-- 5) الموظف يسجل مرة واحدة فقط، وبعد الموافقة يستخدم التحقق.
-- 6) موظف الدخول الدائم يمكنه مسح QR فقط، فيتعرف النظام على جهازه الموثوق
--    بدون إدخال رقم الموظف كل مرة.
--
-- مهم:
-- شغلي هذا الملف مرة واحدة فقط من Supabase SQL Editor بعد التأكد أن النسخة الحالية تعمل.
-- لا تشغلي schema.sql الكامل من جديد فوق قاعدة شغالة.
-- =========================================================

create extension if not exists "pgcrypto";

-- 1) أعمدة الجهاز الموثوق داخل جدول الموظفين
alter table public.employee_registrations
add column if not exists trusted_device_enabled boolean not null default false;

alter table public.employee_registrations
add column if not exists trusted_device_token_hash text;

alter table public.employee_registrations
add column if not exists trusted_device_registered_at timestamptz;

alter table public.employee_registrations
add column if not exists trusted_device_last_used_at timestamptz;

alter table public.employee_registrations
add column if not exists trusted_device_revoked_at timestamptz;

create index if not exists idx_employee_registrations_trusted_device_token_hash
on public.employee_registrations(trusted_device_token_hash)
where trusted_device_token_hash is not null;

create index if not exists idx_employee_registrations_trusted_device_enabled
on public.employee_registrations(trusted_device_enabled);

-- 2) Hash helper: لا نخزن رمز الجهاز الخام في قاعدة البيانات
create or replace function public.hash_trusted_device_token(p_token text)
returns text
language sql
immutable
as $$
  select encode(extensions.digest(trim(coalesce(p_token, '')), 'sha256'), 'hex');
$$;

-- 3) فحص أهلية الموظف لتفعيل التحقق السريع من جهازه
create or replace function public.can_register_trusted_device(
  p_employee_id text,
  p_mobile_number text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reg record;
  clean_emp text := trim(coalesce(p_employee_id, ''));
  clean_mobile text := trim(coalesce(p_mobile_number, ''));
begin
  if clean_emp = '' or clean_mobile = '' then
    return jsonb_build_object('ok', false, 'eligible', false, 'message', 'رقم الموظف ورقم الهاتف مطلوبان');
  end if;

  select *
  into reg
  from public.employee_registrations
  where employee_id = clean_emp
    and mobile_number = clean_mobile
  limit 1;

  if reg.id is null then
    return jsonb_build_object('ok', true, 'eligible', false, 'message', 'الموظف غير موجود');
  end if;

  if reg.status <> 'APPROVED' then
    return jsonb_build_object('ok', true, 'eligible', false, 'message', 'التفعيل متاح بعد موافقة الإدارة فقط');
  end if;

  if not public.is_permanently_allowed_specialty(reg.specialty) then
    return jsonb_build_object('ok', true, 'eligible', false, 'message', 'التحقق السريع مخصص لاختصاص الدخول الدائم فقط');
  end if;

  if coalesce(reg.trusted_device_enabled, false) = false then
    return jsonb_build_object('ok', true, 'eligible', false, 'message', 'الإدارة لم تفعل التحقق السريع لهذا الموظف بعد');
  end if;

  return jsonb_build_object(
    'ok', true,
    'eligible', true,
    'already_linked', reg.trusted_device_token_hash is not null,
    'message', 'يمكن تفعيل التحقق السريع على هذا الجهاز'
  );
end;
$$;

-- 4) ربط هذا الجهاز بموظف بعد التحقق اليدوي الصحيح
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
declare
  reg record;
  clean_emp text := trim(coalesce(p_employee_id, ''));
  clean_mobile text := trim(coalesce(p_mobile_number, ''));
  clean_token text := trim(coalesce(p_device_token, ''));
begin
  if clean_emp = '' or clean_mobile = '' or length(clean_token) < 40 then
    return jsonb_build_object('ok', false, 'message', 'بيانات تفعيل الجهاز غير مكتملة');
  end if;

  select *
  into reg
  from public.employee_registrations
  where employee_id = clean_emp
    and mobile_number = clean_mobile
  limit 1;

  if reg.id is null then
    return jsonb_build_object('ok', false, 'message', 'الموظف غير موجود');
  end if;

  if reg.status <> 'APPROVED' then
    return jsonb_build_object('ok', false, 'message', 'لا يمكن ربط الجهاز قبل موافقة الإدارة');
  end if;

  if not public.is_permanently_allowed_specialty(reg.specialty) then
    return jsonb_build_object('ok', false, 'message', 'التحقق السريع مخصص لاختصاص الدخول الدائم فقط');
  end if;

  if coalesce(reg.trusted_device_enabled, false) = false then
    return jsonb_build_object('ok', false, 'message', 'الإدارة لم تفعل التحقق السريع لهذا الموظف بعد');
  end if;

  update public.employee_registrations
  set trusted_device_token_hash = public.hash_trusted_device_token(clean_token),
      trusted_device_registered_at = now(),
      trusted_device_last_used_at = null,
      trusted_device_revoked_at = null
  where id = reg.id;

  insert into public.admin_audit_logs (
    admin_auth_user_id,
    action,
    target_table,
    target_id,
    details
  ) values (
    null,
    'TRUSTED_DEVICE_LINKED_BY_EMPLOYEE',
    'employee_registrations',
    reg.id::text,
    jsonb_build_object('employee_id', reg.employee_id)
  );

  return jsonb_build_object('ok', true, 'message', 'تم ربط هذا الجهاز بنجاح. في المرات القادمة امسح QR فقط.');
end;
$$;

-- 5) تحقق تلقائي من رمز الجهاز الموثوق + QR
-- ملاحظة أمان وتجربة استخدام:
-- لا يتم استهلاك QR إلا بعد التأكد أن رمز الجهاز مربوط بموظف مؤهل.
-- إذا كان الرمز المحلي قديمًا أو ملغيًا، يبقى QR صالحًا للتعبئة اليدوية خلال مهلة الـ 5 دقائق.
create or replace function public.auto_employee_check(
  p_device_token text,
  p_qr_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reg record;
  clean_token text := trim(coalesce(p_device_token, ''));
  qr_ok boolean := false;
begin
  if length(clean_token) < 40 then
    return jsonb_build_object(
      'ok', false,
      'result', 'DENIED',
      'clear_device', true,
      'message', 'رمز الجهاز غير صالح. أعد التفعيل من التحقق اليدوي.'
    );
  end if;

  select *
  into reg
  from public.employee_registrations
  where trusted_device_enabled = true
    and trusted_device_token_hash = public.hash_trusted_device_token(clean_token)
  limit 1;

  if reg.id is null then
    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'clear_device', true,
      'message', 'هذا الجهاز غير مربوط أو تم إلغاء ربطه. استخدم التحقق اليدوي ثم أعد التفعيل.'
    );
  end if;

  if reg.status <> 'APPROVED' then
    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'clear_device', true,
      'message', 'الموظف غير معتمد حاليًا'
    );
  end if;

  if not public.is_permanently_allowed_specialty(reg.specialty) then
    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'message', 'التحقق السريع مخصص لاختصاص الدخول الدائم فقط'
    );
  end if;

  if p_qr_token is null or length(trim(p_qr_token)) = 0 then
    return jsonb_build_object(
      'ok', false,
      'result', 'DENIED',
      'message', 'يجب مسح QR مباشر من شاشة الحارس'
    );
  end if;

  qr_ok := public.validate_and_use_qr_token(p_qr_token);

  if qr_ok = false then
    perform public.set_guard_status('DENIED', reg.full_name, reg.employee_id, 'QR غير صالح أو منتهي');
    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'message', 'QR غير صالح أو منتهي، يرجى مسح QR جديد'
    );
  end if;

  update public.employee_registrations
  set trusted_device_last_used_at = now()
  where id = reg.id;

  insert into public.gate_access_logs (
    employee_registration_id,
    employee_id,
    mobile_number,
    full_name,
    specialty,
    result,
    reason,
    qr_token
  ) values (
    reg.id,
    reg.employee_id,
    reg.mobile_number,
    reg.full_name,
    reg.specialty,
    'ALLOWED',
    'AUTO_TRUSTED_DEVICE',
    case when p_qr_token is null or p_qr_token = '' then null else p_qr_token::uuid end
  );

  perform public.set_guard_status(
    'ALLOWED',
    reg.full_name,
    reg.employee_id,
    'مسموح بالدخول — تحقق تلقائي من جهاز موثوق'
  );

  return jsonb_build_object(
    'ok', true,
    'result', 'ALLOWED',
    'message', 'مسموح بالدخول — تم التحقق تلقائيًا من الجهاز الموثوق',
    'employee_id', reg.employee_id,
    'full_name', reg.full_name
  );
end;
$$;

-- 6) تحكم الأدمن: تفعيل/تعطيل/إلغاء ربط الجهاز
create or replace function public.admin_set_trusted_device(
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
      trusted_device_token_hash = case when p_revoke or p_enabled = false then null else trusted_device_token_hash end,
      trusted_device_registered_at = case when p_revoke or p_enabled = false then null else trusted_device_registered_at end,
      trusted_device_last_used_at = case when p_revoke or p_enabled = false then null else trusted_device_last_used_at end,
      trusted_device_revoked_at = case when p_revoke or p_enabled = false then now() else trusted_device_revoked_at end
  where id = p_registration_id;

  insert into public.admin_audit_logs (
    admin_auth_user_id,
    action,
    target_table,
    target_id,
    details
  ) values (
    auth.uid(),
    'ADMIN_SET_TRUSTED_DEVICE',
    'employee_registrations',
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
      when p_revoke = true then 'تم إلغاء ربط الجهاز. يستطيع الموظف ربط جهاز جديد من التحقق اليدوي.'
      else 'تم تفعيل التحقق السريع. على الموظف إجراء تحقق يدوي مرة واحدة لربط جهازه.'
    end
  );
end;
$$;

grant execute on function public.can_register_trusted_device(text, text) to anon, authenticated;
grant execute on function public.register_trusted_device(text, text, text) to anon, authenticated;
grant execute on function public.auto_employee_check(text, text) to anon, authenticated;
grant execute on function public.admin_set_trusted_device(uuid, boolean, boolean) to authenticated;

notify pgrst, 'reload schema';

-- =============================================================================
-- [5/14] SOURCE FILE: schema_patch_offline_gate_mode.sql
-- =============================================================================

-- =========================================================
-- Emergency Room Parking - Offline Gate Mode
-- Run after schema.sql and the existing patches.
-- Production hardening rev: batch caps, heartbeat throttle,
-- device quarantine + admin approval, retention cleanup.
-- =========================================================

create table if not exists public.gate_devices (
  id uuid primary key default gen_random_uuid(),
  device_code text not null unique,
  gate_name text,
  gate_location text,
  cache_version text,
  app_version text,
  user_agent text,
  is_active boolean not null default true,
  last_qr_at timestamptz,
  last_scan_at timestamptz,
  last_seen_at timestamptz,
  last_online_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.gate_devices
add column if not exists app_version text;

alter table public.gate_devices
add column if not exists last_qr_at timestamptz;

alter table public.gate_devices
add column if not exists last_scan_at timestamptz;

alter table public.gate_devices enable row level security;

create index if not exists idx_gate_devices_device_code
on public.gate_devices(device_code);

create index if not exists idx_gate_devices_last_seen_at
on public.gate_devices(last_seen_at desc);

-- PROD-3: admin dashboard filters active gates by recency.
create index if not exists idx_gate_devices_active
on public.gate_devices(is_active, last_seen_at desc);

create table if not exists public.offline_device_tokens (
  id uuid primary key default gen_random_uuid(),
  gate_device_id uuid not null references public.gate_devices(id) on delete cascade,
  device_code text not null,
  token_hash text not null unique,
  is_active boolean not null default true,
  last_used_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.offline_device_tokens enable row level security;

create index if not exists idx_offline_device_tokens_device_code
on public.offline_device_tokens(device_code);

create table if not exists public.gate_sync_status (
  id uuid primary key default gen_random_uuid(),
  gate_device_id uuid references public.gate_devices(id) on delete cascade,
  gate_device_code text not null unique,
  pending_count integer not null default 0 check (pending_count >= 0),
  last_sync_started_at timestamptz,
  last_sync_finished_at timestamptz,
  last_sync_status text not null default 'IDLE'
    check (last_sync_status in ('IDLE', 'ONLINE', 'OFFLINE', 'SYNCING', 'SYNCED', 'FAILED')),
  last_error text,
  last_seen_at timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.gate_sync_status enable row level security;

create index if not exists idx_gate_sync_status_updated_at
on public.gate_sync_status(updated_at desc);

create table if not exists public.offline_access_logs (
  id uuid primary key default gen_random_uuid(),
  client_log_id text not null unique,
  gate_device_id uuid references public.gate_devices(id) on delete set null,
  gate_device_code text,
  gate_name text,
  employee_id text,
  mobile_number text,
  full_name text,
  specialty text,
  result text not null default 'DENIED'
    check (result in ('ALLOWED', 'DENIED', 'LIMITED', 'PENDING_FIRST_ENTRY', 'PENDING', 'NOT_FOUND')),
  reason text,
  qr_token text,
  offline_created_at timestamptz not null,
  synced_at timestamptz not null default now(),
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.offline_access_logs enable row level security;

create index if not exists idx_offline_access_logs_synced_at
on public.offline_access_logs(synced_at desc);

create index if not exists idx_offline_access_logs_offline_created_at
on public.offline_access_logs(offline_created_at desc);

create index if not exists idx_offline_access_logs_gate_device_code
on public.offline_access_logs(gate_device_code);

create index if not exists idx_offline_access_logs_device_client
on public.offline_access_logs(gate_device_code, client_log_id);

drop policy if exists "Admins can read gate devices" on public.gate_devices;
create policy "Admins can read gate devices"
on public.gate_devices
for select
to authenticated
using (public.is_super_admin() or public.has_admin_permission('can_view_logs'));

drop policy if exists "Admins can read offline device tokens" on public.offline_device_tokens;
create policy "Admins can read offline device tokens"
on public.offline_device_tokens
for select
to authenticated
using (public.is_super_admin() or public.has_admin_permission('can_view_logs'));

drop policy if exists "Admins can read gate sync status" on public.gate_sync_status;
create policy "Admins can read gate sync status"
on public.gate_sync_status
for select
to authenticated
using (public.is_super_admin() or public.has_admin_permission('can_view_logs'));

drop policy if exists "Admins can read offline access logs" on public.offline_access_logs;
create policy "Admins can read offline access logs"
on public.offline_access_logs
for select
to authenticated
using (public.is_super_admin() or public.has_admin_permission('can_view_logs'));

grant select on public.gate_devices to authenticated;
grant select on public.offline_device_tokens to authenticated;
grant select on public.gate_sync_status to authenticated;
grant select on public.offline_access_logs to authenticated;

create or replace function public.hash_offline_device_token(p_token text)
returns text
language sql
immutable
as $$
  select encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
$$;

drop function if exists public.upsert_gate_device_heartbeat(text, text, text, text);
drop function if exists public.upsert_gate_device_heartbeat(text, text, text, text, integer);
drop function if exists public.upsert_gate_device_heartbeat(text, text, text, text, integer, text);

create or replace function public.upsert_gate_device_heartbeat(
  p_device_code text,
  p_gate_name text default null,
  p_cache_version text default null,
  p_user_agent text default null,
  p_pending_count integer default 0,
  p_device_token text default null,
  p_app_version text default null,
  p_last_qr_at timestamptz default null,
  p_last_scan_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_device_code text := trim(coalesce(p_device_code, ''));
  clean_token text := trim(coalesce(p_device_token, ''));
  clean_token_hash text;
  device_row public.gate_devices%rowtype;
  existing_row public.gate_devices%rowtype;
  has_existing_token boolean := false;
  token_is_valid boolean := false;
  total_devices integer := 0;
  recent_creations integer := 0;
  bootstrap_active boolean := false;
begin
  if clean_device_code = '' then
    return jsonb_build_object('ok', false, 'message', 'device_code is required');
  end if;

  -- PROD-1/PROD-5: load the existing row first for throttle + quarantine.
  select * into existing_row
  from public.gate_devices
  where device_code = clean_device_code
  limit 1;

  if existing_row.id is not null then
    -- Heartbeat throttle: the guard screen calls every 60s, anything
    -- faster is spam. Answer from the cached row without extra writes.
    if existing_row.last_seen_at is not null
      and existing_row.last_seen_at > now() - interval '5 seconds' then
      return jsonb_build_object(
        'ok', true,
        'device_id', existing_row.id,
        'device_code', existing_row.device_code,
        'throttled', true,
        'pending_approval', coalesce(existing_row.is_active, true) = false
      );
    end if;

    -- Quarantine: admin-disabled devices stay visible but get nothing else.
    if coalesce(existing_row.is_active, true) = false then
      update public.gate_devices
      set last_seen_at = now(),
          updated_at = now()
      where id = existing_row.id;
      return jsonb_build_object(
        'ok', false,
        'pending_approval', true,
        'message', 'الجهاز بانتظار اعتماد الإدارة'
      );
    end if;
  else
    -- PROD-5: caps against rogue auto-registration with a stolen anon key.
    select count(*) into total_devices from public.gate_devices;
    if total_devices >= 10 then
      return jsonb_build_object('ok', false, 'message', 'device limit reached, contact admin');
    end if;

    select count(*) into recent_creations
    from public.gate_devices
    where created_at > now() - interval '1 hour';
    if recent_creations >= 3 then
      return jsonb_build_object('ok', false, 'message', 'too many new devices, try later');
    end if;

    -- New gate devices remain inactive until an administrator approves them.
    bootstrap_active := false;
  end if;

  insert into public.gate_devices (
    device_code,
    gate_name,
    cache_version,
    app_version,
    user_agent,
    is_active,
    last_qr_at,
    last_scan_at,
    last_seen_at,
    last_online_at,
    updated_at
  )
  values (
    clean_device_code,
    nullif(trim(coalesce(p_gate_name, '')), ''),
    nullif(trim(coalesce(p_cache_version, '')), ''),
    nullif(trim(coalesce(p_app_version, '')), ''),
    nullif(trim(coalesce(p_user_agent, '')), ''),
    case when existing_row.id is null then bootstrap_active else true end,
    p_last_qr_at,
    p_last_scan_at,
    now(),
    now(),
    now()
  )
  on conflict (device_code)
  do update set
    gate_name = coalesce(excluded.gate_name, public.gate_devices.gate_name),
    cache_version = coalesce(excluded.cache_version, public.gate_devices.cache_version),
    app_version = coalesce(excluded.app_version, public.gate_devices.app_version),
    user_agent = coalesce(excluded.user_agent, public.gate_devices.user_agent),
    last_qr_at = coalesce(excluded.last_qr_at, public.gate_devices.last_qr_at),
    last_scan_at = coalesce(excluded.last_scan_at, public.gate_devices.last_scan_at),
    last_seen_at = now(),
    last_online_at = now(),
    updated_at = now()
  returning * into device_row;

  -- PROD-5: newly auto-registered devices are reported; quarantined ones
  -- stop here so the admin sees them before they can sync anything.
  if existing_row.id is null then
    insert into public.admin_audit_logs (
      admin_auth_user_id, action, target_table, target_id, details
    ) values (
      null, 'GATE_DEVICE_AUTO_REGISTERED', 'gate_devices', clean_device_code,
      jsonb_build_object('active', device_row.is_active)
    );

    if coalesce(device_row.is_active, true) = false then
      insert into public.gate_sync_status (
        gate_device_id, gate_device_code, pending_count,
        last_sync_status, last_error, last_seen_at, updated_at
      ) values (
        device_row.id, device_row.device_code, 0,
        'OFFLINE', 'pending admin approval', now(), now()
      )
      on conflict (gate_device_code) do nothing;
      return jsonb_build_object(
        'ok', false,
        'pending_approval', true,
        'message', 'الجهاز بانتظار اعتماد الإدارة'
      );
    end if;
  end if;

  select exists (
    select 1
    from public.offline_device_tokens
    where gate_device_id = device_row.id
      and is_active = true
      and revoked_at is null
  ) into has_existing_token;

  if clean_token <> '' then
    clean_token_hash := public.hash_offline_device_token(clean_token);

    select exists (
      select 1
      from public.offline_device_tokens
      where gate_device_id = device_row.id
        and token_hash = clean_token_hash
        and is_active = true
        and revoked_at is null
    ) into token_is_valid;

    -- PROD-1: record auth failures (audit insert throttled inside the
    -- helper so an attacker cannot flood the audit log).
    if has_existing_token and token_is_valid = false then
      update public.gate_sync_status
      set last_error = 'offline device token is invalid',
          updated_at = now()
      where gate_device_code = clean_device_code;

      perform public.log_gate_auth_failure(clean_device_code, 'heartbeat: invalid token');

      return jsonb_build_object('ok', false, 'message', 'offline device token is invalid');
    end if;

    if has_existing_token = false then
      insert into public.offline_device_tokens (
        gate_device_id,
        device_code,
        token_hash,
        last_used_at
      )
      values (
        device_row.id,
        device_row.device_code,
        clean_token_hash,
        now()
      )
      on conflict (token_hash)
      do update set last_used_at = now();
    else
      update public.offline_device_tokens
      set last_used_at = now()
      where gate_device_id = device_row.id
        and token_hash = clean_token_hash;
    end if;
  elsif has_existing_token then
    update public.gate_sync_status
    set last_error = 'offline device token is required',
        updated_at = now()
    where gate_device_code = clean_device_code;

    perform public.log_gate_auth_failure(clean_device_code, 'heartbeat: missing token');

    return jsonb_build_object('ok', false, 'message', 'offline device token is required');
  end if;

  insert into public.gate_sync_status (
    gate_device_id,
    gate_device_code,
    pending_count,
    last_sync_status,
    last_seen_at,
    updated_at
  )
  values (
    device_row.id,
    device_row.device_code,
    greatest(coalesce(p_pending_count, 0), 0),
    'ONLINE',
    now(),
    now()
  )
  on conflict (gate_device_code)
  do update set
    gate_device_id = excluded.gate_device_id,
    pending_count = excluded.pending_count,
    last_sync_status = 'ONLINE',
    last_seen_at = now(),
    updated_at = now();

  return jsonb_build_object(
    'ok', true,
    'device_id', device_row.id,
    'device_code', device_row.device_code,
    'pending_approval', false,
    'pending_count', greatest(coalesce(p_pending_count, 0), 0)
  );
end;
$$;

drop function if exists public.sync_offline_access_logs(jsonb);
drop function if exists public.sync_offline_access_logs(text, jsonb);

create or replace function public.sync_offline_access_logs(
  p_device_code text,
  p_logs jsonb,
  p_device_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  item jsonb;
  synced_count integer := 0;
  device_id uuid;
  device_active boolean := true;
  token_is_valid boolean := false;
  batch_size integer := 0;
  payload_bytes integer := 0;
  clean_client_log_id text;
  clean_device_code text := trim(coalesce(p_device_code, ''));
  clean_token text := trim(coalesce(p_device_token, ''));
  clean_token_hash text;
  inserted_count integer := 0;
begin
  if clean_device_code = '' then
    return jsonb_build_object('ok', false, 'message', 'device_code is required');
  end if;

  if clean_token = '' then
    return jsonb_build_object('ok', false, 'message', 'offline device token is required');
  end if;

  if jsonb_typeof(p_logs) <> 'array' then
    return jsonb_build_object('ok', false, 'message', 'p_logs must be a JSON array');
  end if;

  -- PROD-2: batch + payload caps so one device cannot stall the database.
  -- Clients must split larger queues into chunks of <= 500.
  batch_size := jsonb_array_length(p_logs);
  if batch_size > 500 then
    return jsonb_build_object('ok', false, 'message', 'batch too large, max 500 logs per request');
  end if;

  payload_bytes := pg_column_size(p_logs);
  if payload_bytes > 1048576 then
    return jsonb_build_object('ok', false, 'message', 'payload too large, split into smaller batches');
  end if;

  clean_token_hash := public.hash_offline_device_token(clean_token);

  -- Device lookup separated from the token check for clearer diagnostics.
  select gd.id, gd.is_active
  into device_id, device_active
  from public.gate_devices gd
  where gd.device_code = clean_device_code
  limit 1;

  if device_id is null then
    perform public.log_gate_auth_failure(clean_device_code, 'sync: unknown device');
    return jsonb_build_object('ok', false, 'message', 'device is not authorized for offline sync');
  end if;

  if coalesce(device_active, true) = false then
    update public.gate_sync_status
    set last_error = 'pending admin approval',
        updated_at = now()
    where gate_device_code = clean_device_code;
    return jsonb_build_object('ok', false, 'pending_approval', true, 'message', 'device pending admin approval');
  end if;

  select exists (
    select 1
    from public.offline_device_tokens
    where gate_device_id = device_id
      and token_hash = clean_token_hash
      and is_active = true
      and revoked_at is null
  ) into token_is_valid;

  if not token_is_valid then
    perform public.log_gate_auth_failure(clean_device_code, 'sync: invalid token');
    update public.gate_sync_status
    set last_error = 'offline device token is invalid',
        last_sync_status = 'FAILED',
        updated_at = now()
    where gate_device_code = clean_device_code;
    return jsonb_build_object('ok', false, 'message', 'device is not authorized for offline sync');
  end if;

  update public.gate_sync_status
  set last_sync_started_at = now(),
      last_sync_status = 'SYNCING',
      last_error = null,
      updated_at = now()
  where gate_device_code = clean_device_code;

  for item in select value from jsonb_array_elements(p_logs)
  loop
    clean_client_log_id := trim(coalesce(item->>'client_log_id', ''));

    if clean_client_log_id = '' then
      continue;
    end if;

    insert into public.offline_access_logs (
      client_log_id,
      gate_device_id,
      gate_device_code,
      gate_name,
      employee_id,
      mobile_number,
      full_name,
      specialty,
      result,
      reason,
      qr_token,
      offline_created_at,
      synced_at,
      payload
    )
    values (
      clean_client_log_id,
      device_id,
      clean_device_code,
      nullif(item->>'gate_name', ''),
      nullif(item->>'employee_id', ''),
      nullif(item->>'mobile_number', ''),
      nullif(item->>'full_name', ''),
      nullif(item->>'specialty', ''),
      coalesce(nullif(item->>'result', ''), 'DENIED'),
      nullif(item->>'reason', ''),
      nullif(item->>'qr_token', ''),
      coalesce((item->>'offline_created_at')::timestamptz, now()),
      now(),
      coalesce(item->'payload', '{}'::jsonb)
    )
    on conflict (client_log_id)
    do nothing;

    get diagnostics inserted_count = row_count;
    synced_count := synced_count + inserted_count;
  end loop;

  update public.offline_device_tokens
  set last_used_at = now()
  where gate_device_id = device_id
    and token_hash = clean_token_hash;

  update public.gate_sync_status
  set pending_count = 0,
      last_sync_finished_at = now(),
      last_sync_status = 'SYNCED',
      last_error = null,
      updated_at = now()
  where gate_device_code = clean_device_code;

  return jsonb_build_object('ok', true, 'synced_count', synced_count);
exception
  when others then
    update public.gate_sync_status
    set last_sync_finished_at = now(),
        last_sync_status = 'FAILED',
        last_error = sqlerrm,
        updated_at = now()
    where gate_device_code = clean_device_code;
    raise;
end;
$$;

-- =========================================================
-- PROD-1: throttled auth-failure logger (internal use only).
-- Capped at 1 audit row per device per 5 minutes so an attacker
-- cannot flood admin_audit_logs. Called from SECURITY DEFINER
-- functions, so no direct grants are given.
-- =========================================================

create or replace function public.log_gate_auth_failure(
  p_device_code text,
  p_source text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  fail_logged boolean := false;
begin
  if trim(coalesce(p_device_code, '')) = '' then
    return;
  end if;

  select exists (
    select 1 from public.admin_audit_logs
    where action = 'GATE_DEVICE_AUTH_FAILED'
      and target_id = p_device_code
      and created_at > now() - interval '5 minutes'
  ) into fail_logged;

  if not fail_logged then
    insert into public.admin_audit_logs (
      admin_auth_user_id, action, target_table, target_id, details
    ) values (
      null, 'GATE_DEVICE_AUTH_FAILED', 'gate_devices', p_device_code,
      jsonb_build_object('source', p_source)
    );
  end if;
end;
$$;

-- =========================================================
-- PROD-5: admin approval for quarantined gate devices.
-- =========================================================

create or replace function public.admin_approve_gate_device(
  p_device_code text,
  p_approve boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_code text := trim(coalesce(p_device_code, ''));
  dev_id uuid;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'message', 'غير مصرح');
  end if;

  if clean_code = '' then
    return jsonb_build_object('ok', false, 'message', 'device_code is required');
  end if;

  update public.gate_devices
  set is_active = coalesce(p_approve, true),
      updated_at = now()
  where device_code = clean_code
  returning id into dev_id;

  if dev_id is null then
    return jsonb_build_object('ok', false, 'message', 'device not found');
  end if;

  insert into public.admin_audit_logs (
    admin_auth_user_id, action, target_table, target_id, details
  ) values (
    auth.uid(), 'GATE_DEVICE_APPROVAL', 'gate_devices', clean_code,
    jsonb_build_object('approved', coalesce(p_approve, true))
  );

  return jsonb_build_object('ok', true, 'message', 'تم تحديث اعتماد الجهاز');
end;
$$;

-- =========================================================
-- PROD-4: retention cleanup for synced offline logs.
-- Default keeps 12 months online. Run manually or via pg_cron:
--   select cron.schedule('erp-offline-logs-retention', '0 3 1 * *',
--     $$select public.cleanup_old_offline_access_logs(12)$$);
-- =========================================================

create or replace function public.cleanup_old_offline_access_logs(
  p_retention_months integer default 12
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted_count integer := 0;
  cutoff timestamptz;
  retention integer := greatest(coalesce(p_retention_months, 12), 1);
begin
  if not public.is_super_admin() then
    return jsonb_build_object('ok', false, 'message', 'هذه العملية للسوبر أدمن فقط');
  end if;

  cutoff := now() - (retention || ' months')::interval;

  delete from public.offline_access_logs
  where synced_at < cutoff;

  get diagnostics deleted_count = row_count;

  insert into public.admin_audit_logs (
    admin_auth_user_id, action, target_table, target_id, details
  ) values (
    auth.uid(), 'OFFLINE_LOGS_RETENTION_CLEANUP', 'offline_access_logs', null,
    jsonb_build_object('retention_months', retention, 'deleted', deleted_count)
  );

  return jsonb_build_object('ok', true, 'deleted_count', deleted_count);
end;
$$;

-- NOTE on PROD-1 (wide anon grants): heartbeat + sync MUST stay
-- executable by anon because the guard screen is open-access by design
-- (no login) and employees are unauthenticated. Real enforcement lives
-- inside the functions: offline token hash check, 5s heartbeat throttle,
-- 500-row / 1MB batch caps, device cap + creation throttle, quarantine
-- for new devices, and throttled auth-failure logging above.

grant execute on function public.hash_offline_device_token(text) to anon, authenticated;
grant execute on function public.upsert_gate_device_heartbeat(text, text, text, text, integer, text, text, timestamptz, timestamptz) to anon, authenticated;
grant execute on function public.sync_offline_access_logs(text, jsonb, text) to anon, authenticated;

revoke all on function public.log_gate_auth_failure(text, text) from public, anon, authenticated;
revoke all on function public.admin_approve_gate_device(text, boolean) from public, anon;
grant execute on function public.admin_approve_gate_device(text, boolean) to authenticated;
revoke all on function public.cleanup_old_offline_access_logs(integer) from public, anon;
grant execute on function public.cleanup_old_offline_access_logs(integer) to authenticated;

notify pgrst, 'reload schema';

-- =============================================================================
-- [6/14] SOURCE FILE: schema_patch_verify_employee_profile.sql
-- =============================================================================

-- =========================================================
-- Emergency Room Parking - Employee profile fields for verify.html
-- Run after schema.sql, schema_patch_permanent_specialty.sql,
-- schema_patch_auto_verify.sql, and schema_patch_offline_gate_mode.sql.
-- =========================================================

alter table public.employee_registrations
add column if not exists job_type text;

alter table public.employee_registrations
add column if not exists department text;

alter table public.employee_registrations
add column if not exists employee_photo_url text;

create index if not exists idx_employee_registrations_job_type
on public.employee_registrations(job_type);

insert into storage.buckets (id, name, public)
values ('employee-photos', 'employee-photos', true)
on conflict (id) do update set public = true;

drop policy if exists "Anyone can upload employee photos" on storage.objects;
create policy "Anyone can upload employee photos"
on storage.objects
for insert
to anon, authenticated
with check (bucket_id = 'employee-photos');

drop policy if exists "Anyone can read employee photos" on storage.objects;
create policy "Anyone can read employee photos"
on storage.objects
for select
to anon, authenticated
using (bucket_id = 'employee-photos');

create or replace function public.employee_result_details(p_registration_id uuid)
returns jsonb
language sql
stable
set search_path = public
as $$
  select jsonb_build_object(
    'id', er.id,
    'full_name', er.full_name,
    'employee_id', er.employee_id,
    'mobile_number', er.mobile_number,
    'department', coalesce(er.department, er.job_type, '-'),
    'specialty', er.specialty,
    'job_type', coalesce(er.job_type, '-'),
    'employee_type', coalesce(er.job_type, '-'),
    'classification',
      case
        when public.normalize_specialty_name(coalesce(er.job_type, '')) like '%مقيم%' then 'مقيم'
        when public.normalize_specialty_name(coalesce(er.job_type, '')) like '%تمريض%' then 'ممرض'
        when public.normalize_specialty_name(coalesce(er.specialty, '')) = public.normalize_specialty_name('طب عام') then 'طبيب عام'
        when public.normalize_specialty_name(coalesce(er.job_type, '')) like '%طبيب%'
          and public.is_permanently_allowed_specialty(er.specialty) then 'أخصائي / طوارئ'
        when public.normalize_specialty_name(coalesce(er.job_type, '')) like '%طبيب%' then 'مقيم'
        when public.normalize_specialty_name(coalesce(er.job_type, '')) like '%أمن%' then 'أمن'
        when public.normalize_specialty_name(coalesce(er.job_type, '')) like '%إداري%' then 'إداري'
        when public.normalize_specialty_name(coalesce(er.job_type, '')) like '%فني%' then 'فني'
        else coalesce(er.job_type, er.specialty, '-')
      end,
    'photo_url', er.employee_photo_url,
    'status', er.status
  )
  from public.employee_registrations er
  where er.id = p_registration_id;
$$;

drop function if exists public.register_employee_request(text, text, text, text, text);
drop function if exists public.register_employee_request(text, text, text, text, text, text, text, text);

create or replace function public.register_employee_request(
  p_full_name text,
  p_employee_id text,
  p_mobile_number text,
  p_specialty text,
  p_qr_token text default null,
  p_job_type text default null,
  p_department text default null,
  p_photo_url text default null
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
  clean_specialty text := trim(coalesce(p_specialty, ''));
  clean_job_type text := trim(coalesce(p_job_type, ''));
  clean_department text := trim(coalesce(p_department, p_job_type, ''));
  clean_photo_url text := trim(coalesce(p_photo_url, ''));
begin
  if clean_name = '' or clean_emp = '' or clean_mobile = '' or clean_specialty = '' or clean_job_type = '' or clean_photo_url = '' then
    return jsonb_build_object(
      'ok', false,
      'result', 'DENIED',
      'message', 'الرجاء تعبئة الاسم والرقم الوظيفي/الوطني والهاتف والوظيفة والقسم/الاختصاص ورفع الصورة الشخصية'
    );
  end if;

  select *
  into reg
  from public.employee_registrations
  where employee_id = clean_emp
  limit 1;

  if reg.id is null then
    insert into public.employee_registrations (
      full_name,
      employee_id,
      mobile_number,
      specialty,
      job_type,
      department,
      employee_photo_url,
      status,
      first_entry_used,
      first_entry_at
    )
    values (
      clean_name,
      clean_emp,
      clean_mobile,
      clean_specialty,
      clean_job_type,
      clean_department,
      clean_photo_url,
      'PENDING',
      false,
      null
    )
    returning * into reg;
  elsif reg.status = 'PENDING' then
    update public.employee_registrations
    set full_name = clean_name,
        mobile_number = clean_mobile,
        specialty = clean_specialty,
        job_type = clean_job_type,
        department = clean_department,
        employee_photo_url = clean_photo_url
    where id = reg.id
    returning * into reg;
  end if;

  if reg.status = 'REJECTED' then
    insert into public.gate_access_logs (
      employee_registration_id,
      employee_id,
      mobile_number,
      full_name,
      specialty,
      result,
      reason
    )
    values (
      reg.id,
      reg.employee_id,
      reg.mobile_number,
      reg.full_name,
      reg.specialty,
      'DENIED',
      'REJECTED_EMPLOYEE'
    );

    perform public.set_guard_status('DENIED', reg.full_name, reg.employee_id, 'تم رفض الطلب مسبقًا');

    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'message', 'تم رفض الطلب، يرجى مراجعة الإدارة',
      'employee', public.employee_result_details(reg.id)
    );
  end if;

  if reg.status = 'APPROVED' then
    return public.manual_employee_check(reg.employee_id, reg.mobile_number, p_qr_token);
  end if;

  if reg.first_entry_used = true then
    insert into public.gate_access_logs (
      employee_registration_id,
      employee_id,
      mobile_number,
      full_name,
      specialty,
      result,
      reason
    )
    values (
      reg.id,
      reg.employee_id,
      reg.mobile_number,
      reg.full_name,
      reg.specialty,
      'DENIED',
      'PENDING_FIRST_ENTRY_ALREADY_USED'
    );

    perform public.set_guard_status('DENIED', reg.full_name, reg.employee_id, 'طلب قيد المراجعة — تم استخدام الدخول الأول سابقًا');

    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'message', 'طلبك قيد المراجعة، وتم استخدام الدخول الأول سابقًا',
      'employee', public.employee_result_details(reg.id)
    );
  end if;

  qr_ok := public.validate_and_use_qr_token(p_qr_token);

  if qr_ok then
    update public.employee_registrations
    set first_entry_used = true,
        first_entry_at = now()
    where id = reg.id
    returning * into reg;

    insert into public.gate_access_logs (
      employee_registration_id,
      employee_id,
      mobile_number,
      full_name,
      specialty,
      result,
      reason,
      qr_token
    )
    values (
      reg.id,
      reg.employee_id,
      reg.mobile_number,
      reg.full_name,
      reg.specialty,
      'PENDING_FIRST_ENTRY',
      'FIRST_ENTRY_AFTER_REGISTRATION',
      p_qr_token::uuid
    );

    perform public.set_guard_status('LIMITED', reg.full_name, reg.employee_id, 'دخول أول مرة — بانتظار موافقة الإدارة');

    return jsonb_build_object(
      'ok', true,
      'result', 'LIMITED',
      'message', 'تم إرسال طلبك. تم السماح بدخول أول مرة فقط، والطلب بانتظار موافقة الإدارة',
      'employee', public.employee_result_details(reg.id)
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'result', 'PENDING',
    'message', 'تم إرسال طلبك، الرجاء انتظار موافقة الإدارة',
    'employee', public.employee_result_details(reg.id)
  );
end;
$$;

create or replace function public.manual_employee_check(
  p_employee_id text,
  p_mobile_number text,
  p_qr_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reg record;
  lim record;
  used_count integer := 0;
  qr_required boolean := false;
  qr_ok boolean := true;
  clean_emp text := trim(coalesce(p_employee_id, ''));
  clean_mobile text := trim(coalesce(p_mobile_number, ''));
  is_permanent boolean := false;
  access_result text := 'LIMITED';
  access_reason text := 'TEMPORARY_APPROVED_ACCESS';
  access_message text := 'مسموح بشكل مؤقت';
begin
  if clean_emp = '' or clean_mobile = '' then
    return jsonb_build_object('ok', false, 'result', 'DENIED', 'message', 'أدخل الرقم الوظيفي/الوطني ورقم الهاتف');
  end if;

  select *
  into reg
  from public.employee_registrations
  where employee_id = clean_emp
    and mobile_number = clean_mobile
  limit 1;

  if reg.id is null then
    perform public.set_guard_status('DENIED', null, clean_emp, 'الموظف غير موجود');
    return jsonb_build_object(
      'ok', true,
      'result', 'NOT_FOUND',
      'message', 'الموظف غير موجود، الرجاء التسجيل أولًا'
    );
  end if;

  if reg.status = 'PENDING' then
    insert into public.gate_access_logs (
      employee_registration_id,
      employee_id,
      mobile_number,
      full_name,
      specialty,
      result,
      reason
    )
    values (
      reg.id,
      reg.employee_id,
      reg.mobile_number,
      reg.full_name,
      reg.specialty,
      'DENIED',
      'PENDING_EMPLOYEE'
    );

    perform public.set_guard_status('DENIED', reg.full_name, reg.employee_id, 'طلب قيد المراجعة');

    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'message', 'طلبك قيد المراجعة',
      'employee', public.employee_result_details(reg.id)
    );
  end if;

  if reg.status = 'REJECTED' then
    insert into public.gate_access_logs (
      employee_registration_id,
      employee_id,
      mobile_number,
      full_name,
      specialty,
      result,
      reason
    )
    values (
      reg.id,
      reg.employee_id,
      reg.mobile_number,
      reg.full_name,
      reg.specialty,
      'DENIED',
      'REJECTED_EMPLOYEE'
    );

    perform public.set_guard_status('DENIED', reg.full_name, reg.employee_id, 'تم رفض الطلب');

    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'message', 'تم رفض الطلب، يرجى مراجعة الإدارة',
      'employee', public.employee_result_details(reg.id)
    );
  end if;

  -- Reject a linked device that was disabled or revoked before consuming the
  -- QR. A row without a linked token remains eligible for the existing manual
  -- bootstrap flow. Exact token ownership is validated by auto_employee_check.
  if nullif(reg.trusted_device_token_hash, '') is not null
     and (
       coalesce(reg.trusted_device_enabled, false) = false
       or reg.trusted_device_revoked_at is not null
     ) then
    insert into public.gate_access_logs (
      employee_registration_id,
      employee_id,
      mobile_number,
      full_name,
      specialty,
      result,
      reason
    )
    values (
      reg.id,
      reg.employee_id,
      reg.mobile_number,
      reg.full_name,
      reg.specialty,
      'DENIED',
      'TRUSTED_DEVICE_NOT_ACTIVE'
    );

    perform public.set_guard_status('DENIED', reg.full_name, reg.employee_id, 'الجهاز الموثوق غير مفعّل');

    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'message', 'الجهاز الموثوق غير مفعّل، يرجى مراجعة الإدارة',
      'employee', public.employee_result_details(reg.id)
    );
  end if;

  if p_qr_token is not null and length(trim(p_qr_token)) > 0 then
    qr_required := true;
    qr_ok := public.validate_and_use_qr_token(p_qr_token);
  end if;

  if qr_required and qr_ok = false then
    perform public.set_guard_status('DENIED', null, clean_emp, 'QR غير صالح أو منتهي');
    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'message', 'QR غير صالح أو منتهي، يرجى مسح QR جديد'
    );
  end if;

  is_permanent := public.is_permanently_allowed_specialty(reg.specialty);

  if is_permanent then
    access_result := 'ALLOWED';
    access_reason := 'PERMANENTLY_ALLOWED_SPECIALTY';
    access_message := 'مسموح بالدخول';
  elsif public.normalize_specialty_name(coalesce(reg.job_type, '')) = public.normalize_specialty_name('طبيب')
        and public.normalize_specialty_name(reg.specialty) not in (
          public.normalize_specialty_name('الإسعاف والطوارئ (DRS/NRS/EMT/MLT)'),
          public.normalize_specialty_name('الإسعاف والطوارئ'),
          public.normalize_specialty_name('طب عام')
        ) then
    access_result := 'LIMITED';
    access_reason := 'TEMPORARY_DOCTOR_NON_EMERGENCY';
    access_message := 'مسموح جزئيًا — طبيب من اختصاص آخر';
  end if;

  if not is_permanent then
    select *
    into lim
    from public.specialty_daily_limits
    where specialty_name = reg.specialty
      and is_active = true
    limit 1;

    if lim.id is not null then
      select count(*)
      into used_count
      from public.gate_access_logs
      where specialty = reg.specialty
        and result = 'LIMITED'
        and created_at >= date_trunc('day', now())
        and created_at < date_trunc('day', now()) + interval '1 day';

      if used_count >= lim.daily_limit then
        access_result := 'DENIED';
        access_reason := 'SPECIALTY_DAILY_LIMIT_REACHED';
        access_message := 'غير مسموح — تم الوصول للحد اليومي لهذا الاختصاص';
      else
        access_result := 'LIMITED';
        access_reason := 'SPECIALTY_LIMITED_ACCESS';
        access_message := 'مسموح بشكل مؤقت';
      end if;
    end if;
  end if;

  insert into public.gate_access_logs (
    employee_registration_id,
    employee_id,
    mobile_number,
    full_name,
    specialty,
    result,
    reason,
    qr_token
  )
  values (
    reg.id,
    reg.employee_id,
    reg.mobile_number,
    reg.full_name,
    reg.specialty,
    access_result,
    access_reason,
    case when p_qr_token is null or p_qr_token = '' then null else p_qr_token::uuid end
  );

  perform public.set_guard_status(access_result, reg.full_name, reg.employee_id, access_message);

  return jsonb_build_object(
    'ok', true,
    'result', access_result,
    'message', access_message,
    'employee', public.employee_result_details(reg.id)
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
declare
  reg record;
  clean_token text := trim(coalesce(p_device_token, ''));
  qr_ok boolean := false;
begin
  if length(clean_token) < 40 then
    return jsonb_build_object(
      'ok', false,
      'result', 'DENIED',
      'clear_device', true,
      'message', 'رمز الجهاز غير صالح. أعد التفعيل من التحقق اليدوي.'
    );
  end if;

  select *
  into reg
  from public.employee_registrations
  where trusted_device_enabled = true
    and trusted_device_token_hash = public.hash_trusted_device_token(clean_token)
  limit 1;

  if reg.id is null then
    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'clear_device', true,
      'message', 'هذا الجهاز غير مربوط أو تم إلغاء ربطه. استخدم التحقق اليدوي ثم أعد التفعيل.'
    );
  end if;

  if reg.status <> 'APPROVED' then
    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'clear_device', true,
      'message', 'الموظف غير معتمد حاليًا',
      'employee', public.employee_result_details(reg.id)
    );
  end if;

  if not public.is_permanently_allowed_specialty(reg.specialty) then
    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'message', 'التحقق السريع مخصص لاختصاص الدخول الدائم فقط',
      'employee', public.employee_result_details(reg.id)
    );
  end if;

  if p_qr_token is null or length(trim(p_qr_token)) = 0 then
    return jsonb_build_object(
      'ok', false,
      'result', 'DENIED',
      'message', 'يجب مسح QR مباشر من شاشة الحارس',
      'employee', public.employee_result_details(reg.id)
    );
  end if;

  qr_ok := public.validate_and_use_qr_token(p_qr_token);

  if qr_ok = false then
    perform public.set_guard_status('DENIED', reg.full_name, reg.employee_id, 'QR غير صالح أو منتهي');
    return jsonb_build_object(
      'ok', true,
      'result', 'DENIED',
      'message', 'QR غير صالح أو منتهي، يرجى مسح QR جديد',
      'employee', public.employee_result_details(reg.id)
    );
  end if;

  update public.employee_registrations
  set trusted_device_last_used_at = now()
  where id = reg.id;

  insert into public.gate_access_logs (
    employee_registration_id,
    employee_id,
    mobile_number,
    full_name,
    specialty,
    result,
    reason,
    qr_token
  ) values (
    reg.id,
    reg.employee_id,
    reg.mobile_number,
    reg.full_name,
    reg.specialty,
    'ALLOWED',
    'AUTO_TRUSTED_DEVICE',
    case when p_qr_token is null or p_qr_token = '' then null else p_qr_token::uuid end
  );

  perform public.set_guard_status(
    'ALLOWED',
    reg.full_name,
    reg.employee_id,
    'مسموح بالدخول — تحقق تلقائي من جهاز موثوق'
  );

  return jsonb_build_object(
    'ok', true,
    'result', 'ALLOWED',
    'message', 'مسموح بالدخول — تم التحقق تلقائيًا من الجهاز الموثوق',
    'employee', public.employee_result_details(reg.id)
  );
end;
$$;

grant execute on function public.employee_result_details(uuid) to anon, authenticated;
grant execute on function public.register_employee_request(text, text, text, text, text, text, text, text) to anon, authenticated;
grant execute on function public.manual_employee_check(text, text, text) to anon, authenticated;
grant execute on function public.auto_employee_check(text, text) to anon, authenticated;

create or replace function public.get_guard_employee_result(p_employee_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reg record;
begin
  select *
  into reg
  from public.employee_registrations
  where employee_id = trim(coalesce(p_employee_id, ''))
  limit 1;

  if reg.id is null then
    return null;
  end if;

  return public.employee_result_details(reg.id);
end;
$$;

grant execute on function public.get_guard_employee_result(text) to anon, authenticated;

-- =============================================================================
-- [7/14] SOURCE FILE: schema_patch_employee_profiles.sql
-- =============================================================================

-- ALBASHIR Gate - employee profile and controlled data-change requests
-- Run after schema_patch_verify_employee_profile.sql.

alter table public.employee_registrations
  add column if not exists vehicle_type text,
  add column if not exists vehicle_plate text,
  add column if not exists vehicle_color text;

create table if not exists public.employee_data_change_requests (
  id uuid primary key default gen_random_uuid(),
  employee_registration_id uuid not null references public.employee_registrations(id) on delete cascade,
  requested_changes jsonb not null default '{}'::jsonb,
  reason text,
  status text not null default 'PENDING' check (status in ('PENDING','APPROVED','REJECTED')),
  admin_note text,
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.employee_data_change_requests enable row level security;
drop policy if exists "Admins can read employee change requests" on public.employee_data_change_requests;
create policy "Admins can read employee change requests"
  on public.employee_data_change_requests for select
  using (public.is_admin());
create index if not exists idx_employee_data_change_requests_employee
  on public.employee_data_change_requests(employee_registration_id);
create index if not exists idx_employee_data_change_requests_status
  on public.employee_data_change_requests(status);

create or replace function public.employee_profile_login(
  p_employee_id text,
  p_mobile_number text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reg record;
  clean_id text := trim(coalesce(p_employee_id, ''));
  clean_mobile text := trim(coalesce(p_mobile_number, ''));
begin
  select * into reg
  from public.employee_registrations
  where employee_id = clean_id and mobile_number = clean_mobile
  limit 1;

  if reg.id is null then
    return jsonb_build_object('ok', false, 'message', 'الرقم الوظيفي أو الهاتف غير صحيح');
  end if;

  return jsonb_build_object(
    'ok', true,
    'profile', jsonb_build_object(
      'id', reg.id,
      'full_name', reg.full_name,
      'employee_id', reg.employee_id,
      'mobile_number', reg.mobile_number,
      'department', coalesce(reg.department, ''),
      'specialty', reg.specialty,
      'job_type', coalesce(reg.job_type, ''),
      'employee_photo_url', coalesce(reg.employee_photo_url, ''),
      'vehicle_type', coalesce(reg.vehicle_type, ''),
      'vehicle_plate', coalesce(reg.vehicle_plate, ''),
      'vehicle_color', coalesce(reg.vehicle_color, ''),
      'status', reg.status,
      'trusted_device_type', coalesce(reg.trusted_device_type, ''),
      'trusted_device_last_activity_at', reg.trusted_device_last_activity_at
    ),
    'qr_history', coalesce((
      select jsonb_agg(to_jsonb(log_row) order by log_row.created_at desc)
      from (
        select created_at, result, reason, specialty
        from public.gate_access_logs
        where employee_registration_id = reg.id
        order by created_at desc
        limit 30
      ) log_row
    ), '[]'::jsonb),
    'change_requests', coalesce((
      select jsonb_agg(to_jsonb(request_row) order by request_row.created_at desc)
      from (
        select id, requested_changes, reason, status, admin_note, created_at, reviewed_at
        from public.employee_data_change_requests
        where employee_registration_id = reg.id
        order by created_at desc
        limit 10
      ) request_row
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.employee_request_data_change(
  p_employee_id text,
  p_mobile_number text,
  p_requested_changes jsonb,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reg record;
  request_id uuid;
  allowed jsonb;
begin
  select * into reg
  from public.employee_registrations
  where employee_id = trim(coalesce(p_employee_id, ''))
    and mobile_number = trim(coalesce(p_mobile_number, ''))
  limit 1;

  if reg.id is null then
    return jsonb_build_object('ok', false, 'message', 'تعذر التحقق من بيانات الموظف');
  end if;

  allowed := jsonb_build_object(
    'full_name', coalesce(p_requested_changes->'full_name', 'null'::jsonb),
    'employee_id', coalesce(p_requested_changes->'employee_id', 'null'::jsonb),
    'mobile_number', coalesce(p_requested_changes->'mobile_number', 'null'::jsonb),
    'department', coalesce(p_requested_changes->'department', 'null'::jsonb),
    'specialty', coalesce(p_requested_changes->'specialty', 'null'::jsonb),
    'job_type', coalesce(p_requested_changes->'job_type', 'null'::jsonb),
    'vehicle_type', coalesce(p_requested_changes->'vehicle_type', 'null'::jsonb),
    'vehicle_plate', coalesce(p_requested_changes->'vehicle_plate', 'null'::jsonb),
    'vehicle_color', coalesce(p_requested_changes->'vehicle_color', 'null'::jsonb)
  );

  insert into public.employee_data_change_requests (employee_registration_id, requested_changes, reason)
  values (reg.id, allowed, nullif(trim(coalesce(p_reason, '')), ''))
  returning id into request_id;

  insert into public.admin_audit_logs (admin_auth_user_id, action, target_table, target_id, details)
  values (null, 'EMPLOYEE_DATA_CHANGE_REQUESTED', 'employee_registrations', reg.id::text,
    jsonb_build_object('request_id', request_id, 'employee_id', reg.employee_id));

  return jsonb_build_object('ok', true, 'request_id', request_id, 'message', 'تم إرسال طلب تغيير البيانات للمراجعة');
end;
$$;

create or replace function public.admin_review_employee_data_change(
  p_request_id uuid,
  p_status text,
  p_admin_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  req record;
  changes jsonb;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'message', 'غير مصرح');
  end if;
  if upper(p_status) not in ('APPROVED', 'REJECTED') then
    return jsonb_build_object('ok', false, 'message', 'حالة الطلب غير صحيحة');
  end if;

  select * into req from public.employee_data_change_requests
  where id = p_request_id and status = 'PENDING' for update;
  if req.id is null then
    return jsonb_build_object('ok', false, 'message', 'طلب التغيير غير موجود أو تمت مراجعته');
  end if;

  changes := req.requested_changes;
  if upper(p_status) = 'APPROVED' then
    update public.employee_registrations
    set full_name = coalesce(nullif(changes->>'full_name', ''), full_name),
        employee_id = coalesce(nullif(changes->>'employee_id', ''), employee_id),
        mobile_number = coalesce(nullif(changes->>'mobile_number', ''), mobile_number),
        department = coalesce(nullif(changes->>'department', ''), department),
        specialty = coalesce(nullif(changes->>'specialty', ''), specialty),
        job_type = coalesce(nullif(changes->>'job_type', ''), job_type),
        vehicle_type = coalesce(nullif(changes->>'vehicle_type', ''), vehicle_type),
        vehicle_plate = coalesce(nullif(changes->>'vehicle_plate', ''), vehicle_plate),
        vehicle_color = coalesce(nullif(changes->>'vehicle_color', ''), vehicle_color)
    where id = req.employee_registration_id;
  end if;

  update public.employee_data_change_requests
  set status = upper(p_status), admin_note = nullif(trim(coalesce(p_admin_note, '')), ''), reviewed_by = auth.uid(), reviewed_at = now()
  where id = req.id;

  insert into public.admin_audit_logs (admin_auth_user_id, action, target_table, target_id, details)
  values (auth.uid(), 'EMPLOYEE_DATA_CHANGE_REVIEWED', 'employee_data_change_requests', req.id::text,
    jsonb_build_object('status', upper(p_status), 'employee_registration_id', req.employee_registration_id));

  return jsonb_build_object('ok', true, 'message', case when upper(p_status) = 'APPROVED' then 'تم اعتماد التغيير' else 'تم رفض التغيير' end);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'message', 'الرقم الوظيفي مستخدم لموظف آخر');
end;
$$;

grant execute on function public.employee_profile_login(text, text) to anon, authenticated;
grant execute on function public.employee_request_data_change(text, text, jsonb, text) to anon, authenticated;
grant execute on function public.admin_review_employee_data_change(uuid, text, text) to authenticated;

-- =============================================================================
-- [8/14] SOURCE FILE: schema_patch_trusted_device_registration_flow.sql
-- =============================================================================

-- ALBASHIR Gate: trusted device registration flow fix
-- Apply after schema_patch_pgcrypto_schema_fix.sql.
-- Purpose:
-- 1) Capture the employee device token during first registration.
-- 2) Keep the browser token while the request is still pending.
-- 3) Enable the same device automatically when ADMIN/SUPER_ADMIN approves the employee.
-- 4) Let trusted-device QR checks return ALLOWED or LIMITED according to the existing access rules.

alter table public.employee_registrations
  add column if not exists job_type text,
  add column if not exists department text,
  add column if not exists employee_photo_url text,
  add column if not exists pending_trusted_device_token_hash text,
  add column if not exists pending_trusted_device_id text,
  add column if not exists pending_trusted_device_type text,
  add column if not exists pending_trusted_device_name text,
  add column if not exists pending_trusted_device_user_agent text,
  add column if not exists pending_trusted_device_created_at timestamptz;

create index if not exists idx_employee_registrations_pending_trusted_device_token_hash
  on public.employee_registrations(pending_trusted_device_token_hash)
  where pending_trusted_device_token_hash is not null;

create or replace function public.register_employee_request(
  p_full_name text,
  p_employee_id text,
  p_mobile_number text,
  p_specialty text,
  p_qr_token text default null,
  p_job_type text default null,
  p_department text default null,
  p_photo_url text default null,
  p_device_token text default null,
  p_device_id text default null,
  p_device_type text default null,
  p_device_name text default null,
  p_user_agent text default null
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
  clean_specialty text := trim(coalesce(p_specialty, ''));
  clean_device_token text := trim(coalesce(p_device_token, ''));
begin
  if clean_name = '' or clean_emp = '' or clean_mobile = '' or clean_specialty = '' then
    return jsonb_build_object('ok', false, 'result', 'DENIED', 'message', 'الرجاء تعبئة الاسم ورقم الموظف ورقم الهاتف والقسم');
  end if;

  if p_photo_url is null or trim(coalesce(p_photo_url, '')) = '' then
    return jsonb_build_object('ok', false, 'result', 'DENIED', 'message', 'الصورة الشخصية مطلوبة');
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
      clean_specialty,
      nullif(trim(coalesce(p_job_type, '')), ''),
      nullif(trim(coalesce(p_department, '')), ''),
      trim(p_photo_url),
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
          specialty = clean_specialty,
          job_type = nullif(trim(coalesce(p_job_type, '')), ''),
          department = nullif(trim(coalesce(p_department, '')), ''),
          employee_photo_url = trim(p_photo_url)
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

grant execute on function public.register_employee_request(text, text, text, text, text, text, text, text, text, text, text, text, text)
  to anon, authenticated;

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
        when p_status = 'APPROVED' and pending_trusted_device_token_hash is not null then true
        else trusted_device_enabled
      end,
      trusted_device_token_hash = case
        when p_status = 'APPROVED' and pending_trusted_device_token_hash is not null then pending_trusted_device_token_hash
        else trusted_device_token_hash
      end,
      trusted_device_id = case when p_status = 'APPROVED' and pending_trusted_device_token_hash is not null then pending_trusted_device_id else trusted_device_id end,
      trusted_device_type = case when p_status = 'APPROVED' and pending_trusted_device_token_hash is not null then pending_trusted_device_type else trusted_device_type end,
      trusted_device_name = case when p_status = 'APPROVED' and pending_trusted_device_token_hash is not null then pending_trusted_device_name else trusted_device_name end,
      trusted_device_user_agent = case when p_status = 'APPROVED' and pending_trusted_device_token_hash is not null then pending_trusted_device_user_agent else trusted_device_user_agent end,
      trusted_device_registered_at = case
        when p_status = 'APPROVED' and pending_trusted_device_token_hash is not null then now()
        else trusted_device_registered_at
      end,
      trusted_device_revoked_at = case
        when p_status = 'APPROVED' and pending_trusted_device_token_hash is not null then null
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

  insert into public.admin_audit_logs (admin_auth_user_id, action, target_table, target_id, details)
  values (auth.uid(), 'UPDATE_REGISTRATION_STATUS', 'employee_registrations', p_registration_id::text,
    jsonb_build_object('status', p_status, 'trusted_device_linked', reg.trusted_device_token_hash is not null));

  return jsonb_build_object('ok', true, 'message', 'تم تحديث الطلب');
end;
$$;

grant execute on function public.admin_update_registration_status(uuid, text) to authenticated;

create or replace function public.auto_employee_check(
  p_device_token text,
  p_qr_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reg record;
  check_result jsonb;
  clean_token text := trim(coalesce(p_device_token, ''));
begin
  if length(clean_token) < 40 then
    return jsonb_build_object('ok', false, 'result', 'DENIED', 'clear_device', true, 'message', 'رمز الجهاز غير صالح. أعد التفعيل من التحقق اليدوي.');
  end if;

  select *
  into reg
  from public.employee_registrations
  where trusted_device_token_hash = public.hash_trusted_device_token(clean_token)
     or pending_trusted_device_token_hash = public.hash_trusted_device_token(clean_token)
  limit 1;

  if reg.id is null then
    return jsonb_build_object('ok', true, 'result', 'DENIED', 'clear_device', true, 'message', 'هذا الجهاز غير مربوط أو تم إلغاء ربطه. استخدم التحقق اليدوي ثم أعد التفعيل.');
  end if;

  if reg.status <> 'APPROVED' then
    return jsonb_build_object('ok', true, 'result', 'DENIED', 'clear_device', false, 'message', 'طلب الموظف لم يعتمد بعد');
  end if;

  if coalesce(reg.trusted_device_enabled, false) = false then
    return jsonb_build_object('ok', true, 'result', 'DENIED', 'clear_device', false, 'message', 'الجهاز محفوظ لكنه غير مفعّل بعد');
  end if;

  check_result := public.manual_employee_check(reg.employee_id, reg.mobile_number, p_qr_token);

  if (check_result->>'ok')::boolean = true
     and coalesce(check_result->>'result', '') in ('ALLOWED', 'LIMITED') then
    update public.employee_registrations
    set trusted_device_last_used_at = now(), trusted_device_last_activity_at = now()
    where id = reg.id;
  end if;

  return check_result || jsonb_build_object(
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

grant execute on function public.auto_employee_check(text, text) to anon, authenticated;

notify pgrst, 'reload schema';

-- =============================================================================
-- [9/14] SOURCE FILE: schema_patch_trusted_device_metadata.sql
-- =============================================================================

-- ALBASHIR Gate - trusted device metadata and secure device registration
-- Run after schema_patch_auto_verify.sql.

alter table public.employee_registrations
  add column if not exists trusted_device_id text,
  add column if not exists trusted_device_type text,
  add column if not exists trusted_device_name text,
  add column if not exists trusted_device_user_agent text,
  add column if not exists trusted_device_last_activity_at timestamptz;

create index if not exists idx_employee_registrations_trusted_device_id
  on public.employee_registrations(trusted_device_id)
  where trusted_device_id is not null;

create or replace function public.sync_trusted_device_activity()
returns trigger
language plpgsql
as $$
begin
  if new.trusted_device_last_used_at is distinct from old.trusted_device_last_used_at then
    new.trusted_device_last_activity_at := new.trusted_device_last_used_at;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_trusted_device_activity on public.employee_registrations;
create trigger trg_sync_trusted_device_activity
before update on public.employee_registrations
for each row execute function public.sync_trusted_device_activity();

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
  result jsonb;
  reg_id uuid;
begin
  select public.register_trusted_device(
    p_employee_id,
    p_mobile_number,
    p_device_token
  ) into result;

  if coalesce((result->>'ok')::boolean, false) = false then
    return result;
  end if;

  select id into reg_id
  from public.employee_registrations
  where employee_id = trim(coalesce(p_employee_id, ''))
    and mobile_number = trim(coalesce(p_mobile_number, ''))
  limit 1;

  update public.employee_registrations
  set trusted_device_id = nullif(trim(coalesce(p_device_id, '')), ''),
      trusted_device_type = nullif(trim(coalesce(p_device_type, '')), ''),
      trusted_device_name = nullif(trim(coalesce(p_device_name, '')), ''),
      trusted_device_user_agent = nullif(trim(coalesce(p_user_agent, '')), ''),
      trusted_device_last_activity_at = now()
  where id = reg_id;

  insert into public.admin_audit_logs (
    admin_auth_user_id,
    action,
    target_table,
    target_id,
    details
  ) values (
    null,
    'TRUSTED_DEVICE_METADATA_REGISTERED',
    'employee_registrations',
    reg_id::text,
    jsonb_build_object(
      'device_id', nullif(trim(coalesce(p_device_id, '')), ''),
      'device_type', nullif(trim(coalesce(p_device_type, '')), ''),
      'device_name', nullif(trim(coalesce(p_device_name, '')), '')
    )
  );

  return result || jsonb_build_object(
    'device_id', nullif(trim(coalesce(p_device_id, '')), ''),
    'device_type', nullif(trim(coalesce(p_device_type, '')), ''),
    'device_name', nullif(trim(coalesce(p_device_name, '')), '')
  );
exception when others then
  return jsonb_build_object('ok', false, 'message', 'تعذر حفظ بيانات الجهاز الموثوق');
end;
$$;

grant execute on function public.register_trusted_device_with_metadata(text, text, text, text, text, text, text)
  to anon, authenticated;

create or replace function public.trusted_device_profile_login(p_device_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reg record;
  clean_token text := trim(coalesce(p_device_token, ''));
begin
  if length(clean_token) < 40 then
    return jsonb_build_object('ok', false, 'clear_device', true, 'message', 'رمز الجهاز غير صالح');
  end if;

  select * into reg
  from public.employee_registrations
  where trusted_device_enabled = true
    and trusted_device_token_hash = public.hash_trusted_device_token(clean_token)
    and status = 'APPROVED'
  limit 1;

  if reg.id is null then
    return jsonb_build_object('ok', false, 'clear_device', true, 'message', 'الجهاز جديد أو تم إلغاء اعتماده');
  end if;

  update public.employee_registrations
  set trusted_device_last_used_at = now(), trusted_device_last_activity_at = now()
  where id = reg.id;

  insert into public.admin_audit_logs (admin_auth_user_id, action, target_table, target_id, details)
  values (null, 'TRUSTED_DEVICE_FAST_LOGIN', 'employee_registrations', reg.id::text,
    jsonb_build_object('device_id', reg.trusted_device_id, 'employee_id', reg.employee_id));

  return jsonb_build_object(
    'ok', true,
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

grant execute on function public.trusted_device_profile_login(text) to anon, authenticated;

-- =============================================================================
-- [10/14] SOURCE FILE: schema_patch_production_hardening.sql
-- =============================================================================

-- ALBASHIR Gate - production hardening
-- Run LAST, after schema.sql and every schema_patch_*.sql file listed in README.md.

create table if not exists public.hospital_settings (
  setting_key text primary key,
  setting_value jsonb not null,
  updated_by uuid,
  updated_at timestamptz not null default now()
);
alter table public.hospital_settings enable row level security;
drop policy if exists "Anyone can read hospital settings" on public.hospital_settings;
create policy "Anyone can read hospital settings"
  on public.hospital_settings for select to anon, authenticated using (true);
drop policy if exists "Super admin can insert hospital settings" on public.hospital_settings;
create policy "Super admin can insert hospital settings"
  on public.hospital_settings for insert to authenticated
  with check (public.is_super_admin());
drop policy if exists "Super admin can update hospital settings" on public.hospital_settings;
create policy "Super admin can update hospital settings"
  on public.hospital_settings for update to authenticated
  using (public.is_super_admin()) with check (public.is_super_admin());
grant select on public.hospital_settings to anon, authenticated;
grant insert, update on public.hospital_settings to authenticated;

create index if not exists idx_gate_access_logs_specialty_created_at
on public.gate_access_logs(specialty, created_at desc);

create index if not exists idx_employee_registrations_employee_mobile
on public.employee_registrations(employee_id, mobile_number);

alter table if exists public.gate_devices
add column if not exists last_qr_at timestamptz;

alter table if exists public.gate_devices
add column if not exists last_scan_at timestamptz;

alter table if exists public.gate_devices
add column if not exists app_version text;

create or replace function public.cleanup_expired_qr_sessions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted_count integer := 0;
begin
  delete from public.qr_sessions
  where expires_at < now() - interval '10 minutes';

  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;

grant execute on function public.cleanup_expired_qr_sessions() to authenticated;

drop policy if exists "Anyone can upload violation photos" on storage.objects;
drop policy if exists "Gate can upload violation photos" on storage.objects;
create policy "Gate can upload violation photos"
on storage.objects
for insert
to anon, authenticated
with check (
  bucket_id = 'violation-photos'
  and (storage.foldername(name))[1] = 'violations'
  and lower(coalesce(metadata->>'mimetype', '')) in ('image/jpeg', 'image/png', 'image/webp')
  and coalesce((metadata->>'size')::bigint, 0) <= 5242880
);

-- Internal helper: callers must use a verification RPC, never write the guard state directly.
revoke all on function public.set_guard_status(text, text, text, text) from public, anon, authenticated;

-- Consume the original QR or its five-minute claim atomically.
create or replace function public.claim_qr_session(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  token_uuid uuid;
  new_claim uuid := gen_random_uuid();
  claimed_id uuid;
begin
  begin
    token_uuid := nullif(trim(coalesce(p_token, '')), '')::uuid;
  exception when others then
    return jsonb_build_object('ok', false, 'message', 'QR غير صحيح');
  end;

  update public.qr_sessions
  set used_at = now(),
      claimed_at = now(),
      claim_token = new_claim,
      claim_expires_at = now() + interval '5 minutes',
      claim_used_at = null
  where token = token_uuid
    and used_at is null
    and expires_at > now()
  returning id into claimed_id;

  if claimed_id is null then
    return jsonb_build_object('ok', false, 'message', 'QR غير صالح أو منتهي، يرجى مسح QR جديد من شاشة الحارس');
  end if;

  return jsonb_build_object(
    'ok', true,
    'claim_token', new_claim::text,
    'expires_in_seconds', 300,
    'message', 'تم تفعيل جلسة QR، أكمل البيانات خلال 5 دقائق'
  );
end;
$$;

create or replace function public.validate_and_use_qr_token(p_token text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  input_uuid uuid;
  consumed_id uuid;
begin
  begin
    input_uuid := nullif(trim(coalesce(p_token, '')), '')::uuid;
  exception when others then
    return false;
  end;

  update public.qr_sessions
  set used_at = now()
  where token = input_uuid
    and used_at is null
    and expires_at > now()
  returning id into consumed_id;

  if consumed_id is not null then
    return true;
  end if;

  update public.qr_sessions
  set claim_used_at = now()
  where claim_token = input_uuid
    and claim_used_at is null
    and claim_expires_at > now()
  returning id into consumed_id;

  return consumed_id is not null;
end;
$$;

-- Keep the approved-access decision and specialty daily limits in one function.
create or replace function public.manual_employee_check(
  p_employee_id text,
  p_mobile_number text,
  p_qr_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reg public.employee_registrations%rowtype;
  lim public.specialty_daily_limits%rowtype;
  used_count integer := 0;
  qr_ok boolean := true;
  clean_emp text := trim(coalesce(p_employee_id, ''));
  clean_mobile text := trim(coalesce(p_mobile_number, ''));
  access_result text;
  access_reason text;
  access_message text;
begin
  if clean_emp = '' or clean_mobile = '' then
    return jsonb_build_object('ok', false, 'result', 'DENIED',
      'message', 'أدخل الرقم الوظيفي/الوطني ورقم الهاتف');
  end if;

  select * into reg
  from public.employee_registrations
  where employee_id = clean_emp and mobile_number = clean_mobile
  limit 1;

  if reg.id is null then
    perform public.set_guard_status('DENIED', null, clean_emp, 'الموظف غير موجود');
    return jsonb_build_object('ok', true, 'result', 'NOT_FOUND',
      'message', 'الموظف غير موجود، الرجاء التسجيل أولًا');
  end if;

  if reg.status <> 'APPROVED' then
    access_message := case when reg.status = 'PENDING'
      then 'طلبك قيد المراجعة' else 'تم رفض الطلب، يرجى مراجعة الإدارة' end;
    insert into public.gate_access_logs (
      employee_registration_id, employee_id, mobile_number, full_name,
      specialty, result, reason
    ) values (
      reg.id, reg.employee_id, reg.mobile_number, reg.full_name,
      reg.specialty, 'DENIED', reg.status || '_EMPLOYEE'
    );
    perform public.set_guard_status('DENIED', reg.full_name, reg.employee_id, access_message);
    return jsonb_build_object('ok', true, 'result', 'DENIED',
      'message', access_message, 'employee', public.employee_result_details(reg.id));
  end if;

  -- Reject a linked device that was disabled or revoked before consuming the
  -- QR. A row without a linked token remains eligible for the existing manual
  -- bootstrap flow. Exact token ownership is validated by auto_employee_check.
  if nullif(reg.trusted_device_token_hash, '') is not null
     and (
       coalesce(reg.trusted_device_enabled, false) = false
       or reg.trusted_device_revoked_at is not null
     ) then
    insert into public.gate_access_logs (
      employee_registration_id, employee_id, mobile_number, full_name,
      specialty, result, reason
    ) values (
      reg.id, reg.employee_id, reg.mobile_number, reg.full_name,
      reg.specialty, 'DENIED', 'TRUSTED_DEVICE_NOT_ACTIVE'
    );
    perform public.set_guard_status('DENIED', reg.full_name, reg.employee_id,
      'الجهاز الموثوق غير مفعّل');
    return jsonb_build_object('ok', true, 'result', 'DENIED',
      'message', 'الجهاز الموثوق غير مفعّل، يرجى مراجعة الإدارة',
      'employee', public.employee_result_details(reg.id));
  end if;

  if nullif(trim(coalesce(p_qr_token, '')), '') is not null then
    qr_ok := public.validate_and_use_qr_token(p_qr_token);
    if not qr_ok then
      perform public.set_guard_status('DENIED', null, clean_emp, 'QR غير صالح أو منتهي');
      return jsonb_build_object('ok', true, 'result', 'DENIED',
        'message', 'QR غير صالح أو منتهي، يرجى مسح QR جديد');
    end if;
  end if;

  if public.is_permanently_allowed_specialty(reg.specialty) then
    access_result := 'ALLOWED';
    access_reason := 'PERMANENTLY_ALLOWED_SPECIALTY';
    access_message := 'مسموح بالدخول';
  else
    select * into lim
    from public.specialty_daily_limits
    where specialty_name = reg.specialty and is_active = true
    limit 1;

    if lim.id is not null then
      select count(*) into used_count
      from public.gate_access_logs
      where specialty = reg.specialty
        and result = 'LIMITED'
        and created_at >= date_trunc('day', now())
        and created_at < date_trunc('day', now()) + interval '1 day';

      if used_count >= lim.daily_limit then
        access_result := 'DENIED';
        access_reason := 'SPECIALTY_DAILY_LIMIT_REACHED';
        access_message := 'غير مسموح — تم الوصول للحد اليومي لهذا الاختصاص';
      else
        access_result := 'LIMITED';
        access_reason := 'SPECIALTY_LIMITED_ACCESS';
        access_message := 'مسموح بشكل مؤقت';
      end if;
    elsif public.normalize_specialty_name(coalesce(reg.job_type, '')) =
          public.normalize_specialty_name('طبيب') then
      access_result := 'LIMITED';
      access_reason := 'TEMPORARY_DOCTOR_NON_EMERGENCY';
      access_message := 'مسموح جزئيًا — طبيب من اختصاص آخر';
    else
      access_result := 'LIMITED';
      access_reason := 'TEMPORARY_APPROVED_ACCESS';
      access_message := 'مسموح بشكل مؤقت';
    end if;
  end if;

  insert into public.gate_access_logs (
    employee_registration_id, employee_id, mobile_number, full_name,
    specialty, result, reason, qr_token
  ) values (
    reg.id, reg.employee_id, reg.mobile_number, reg.full_name,
    reg.specialty, access_result, access_reason,
    case when nullif(trim(coalesce(p_qr_token, '')), '') is null
      then null else p_qr_token::uuid end
  );
  perform public.set_guard_status(access_result, reg.full_name, reg.employee_id, access_message);

  return jsonb_build_object('ok', true, 'result', access_result,
    'message', access_message, 'employee', public.employee_result_details(reg.id));
end;
$$;

-- Guard display result: never expose the phone credential.
create or replace function public.get_guard_employee_result(p_employee_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  reg public.employee_registrations%rowtype;
  result jsonb;
begin
  select * into reg from public.employee_registrations
  where employee_id = trim(coalesce(p_employee_id, ''))
  limit 1;
  if reg.id is null then return null; end if;
  result := public.employee_result_details(reg.id);
  return result - 'mobile_number';
end;
$$;

-- Existing trusted device cannot be silently replaced. Admin must revoke it first.
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
declare
  reg public.employee_registrations%rowtype;
  clean_emp text := trim(coalesce(p_employee_id, ''));
  clean_mobile text := trim(coalesce(p_mobile_number, ''));
  clean_token text := trim(coalesce(p_device_token, ''));
  token_hash text;
begin
  if clean_emp = '' or clean_mobile = '' or length(clean_token) < 40 then
    return jsonb_build_object('ok', false, 'message', 'بيانات تفعيل الجهاز غير مكتملة');
  end if;

  select * into reg from public.employee_registrations
  where employee_id = clean_emp and mobile_number = clean_mobile
  limit 1;

  if reg.id is null or reg.status <> 'APPROVED'
     or not coalesce(reg.trusted_device_enabled, false)
     or not public.is_permanently_allowed_specialty(reg.specialty) then
    return jsonb_build_object('ok', false, 'message', 'الجهاز غير مؤهل للربط');
  end if;

  token_hash := public.hash_trusted_device_token(clean_token);
  if reg.trusted_device_token_hash is not null
     and reg.trusted_device_token_hash <> token_hash then
    return jsonb_build_object('ok', false, 'new_device', true,
      'message', 'تم اكتشاف جهاز جديد. يجب أن تلغي الإدارة ربط الجهاز السابق أولًا.');
  end if;

  update public.employee_registrations
  set trusted_device_token_hash = token_hash,
      trusted_device_registered_at = coalesce(trusted_device_registered_at, now()),
      trusted_device_revoked_at = null
  where id = reg.id;

  insert into public.admin_audit_logs (
    admin_auth_user_id, action, target_table, target_id, details
  ) values (
    null, 'TRUSTED_DEVICE_LINKED_BY_EMPLOYEE', 'employee_registrations',
    reg.id::text, jsonb_build_object('employee_id', reg.employee_id)
  );
  return jsonb_build_object('ok', true, 'message', 'تم ربط هذا الجهاز بنجاح');
end;
$$;

-- Enforce detailed administrator permissions in the database.
create or replace function public.admin_can_approve_requests()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_super_admin()
    or public.has_admin_permission('can_approve_requests');
$$;

-- The two existing administrative functions keep their signatures; inject a
-- mandatory permission check through wrappers by renaming their implementations.
do $$
begin
  if to_regprocedure('public.admin_review_employee_data_change_impl(uuid,text,text)') is null then
    alter function public.admin_review_employee_data_change(uuid,text,text)
      rename to admin_review_employee_data_change_impl;
  end if;
  if to_regprocedure('public.admin_set_trusted_device_impl(uuid,boolean,boolean)') is null then
    alter function public.admin_set_trusted_device(uuid,boolean,boolean)
      rename to admin_set_trusted_device_impl;
  end if;
end
$$;

create or replace function public.admin_review_employee_data_change(
  p_request_id uuid, p_status text, p_admin_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.admin_can_approve_requests() then
    return jsonb_build_object('ok', false, 'message', 'لا تملك صلاحية مراجعة الطلبات');
  end if;
  return public.admin_review_employee_data_change_impl(p_request_id, p_status, p_admin_note);
end;
$$;

create or replace function public.admin_set_trusted_device(
  p_registration_id uuid, p_enabled boolean, p_revoke boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.admin_can_approve_requests() then
    return jsonb_build_object('ok', false, 'message', 'لا تملك صلاحية إدارة الأجهزة');
  end if;
  return public.admin_set_trusted_device_impl(p_registration_id, p_enabled, p_revoke);
end;
$$;

revoke all on function public.admin_review_employee_data_change_impl(uuid,text,text) from public, anon, authenticated;
revoke all on function public.admin_set_trusted_device_impl(uuid,boolean,boolean) from public, anon, authenticated;
revoke all on function public.admin_can_approve_requests() from public, anon, authenticated;
grant execute on function public.claim_qr_session(text) to anon, authenticated;
grant execute on function public.validate_and_use_qr_token(text) to anon, authenticated;
grant execute on function public.manual_employee_check(text,text,text) to anon, authenticated;
grant execute on function public.get_guard_employee_result(text) to anon, authenticated;
grant execute on function public.register_trusted_device(text,text,text) to anon, authenticated;
grant execute on function public.admin_review_employee_data_change(uuid,text,text) to authenticated;
grant execute on function public.admin_set_trusted_device(uuid,boolean,boolean) to authenticated;

notify pgrst, 'reload schema';

-- =============================================================================
-- [11/14] SOURCE FILE: schema_patch_gate_qr_device_auth.sql
-- =============================================================================

-- ALBASHIR Gate: require trusted guard device authentication before issuing QR.
-- Apply after schema_patch_offline_gate_mode.sql and schema_patch_pgcrypto_schema_fix.sql.

create or replace function public.create_qr_session(
  p_device_code text,
  p_device_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_device_code text := trim(coalesce(p_device_code, ''));
  clean_token text := trim(coalesce(p_device_token, ''));
  clean_token_hash text;
  gate public.gate_devices%rowtype;
  token_ok boolean := false;
  new_token uuid;
begin
  if clean_device_code = '' or clean_token = '' then
    return jsonb_build_object(
      'ok', false,
      'message', 'جهاز الحارس غير موثق لإصدار QR'
    );
  end if;

  select *
  into gate
  from public.gate_devices
  where device_code = clean_device_code
  limit 1;

  if gate.id is null then
    perform public.log_gate_auth_failure(clean_device_code, 'create_qr_session: unknown device');
    return jsonb_build_object(
      'ok', false,
      'message', 'جهاز الحارس غير مسجل'
    );
  end if;

  if coalesce(gate.is_active, false) = false then
    perform public.log_gate_auth_failure(clean_device_code, 'create_qr_session: inactive device');
    return jsonb_build_object(
      'ok', false,
      'pending_approval', true,
      'message', 'جهاز الحارس بانتظار اعتماد الإدارة'
    );
  end if;

  clean_token_hash := public.hash_offline_device_token(clean_token);

  select exists (
    select 1
    from public.offline_device_tokens
    where gate_device_id = gate.id
      and device_code = clean_device_code
      and token_hash = clean_token_hash
      and is_active = true
      and revoked_at is null
  )
  into token_ok;

  if token_ok = false then
    perform public.log_gate_auth_failure(clean_device_code, 'create_qr_session: invalid token');
    return jsonb_build_object(
      'ok', false,
      'message', 'رمز جهاز الحارس غير صالح'
    );
  end if;

  insert into public.qr_sessions (expires_at)
  values (now() + interval '30 seconds')
  returning token into new_token;

  update public.gate_devices
  set last_qr_at = now(),
      last_seen_at = now(),
      last_online_at = now(),
      updated_at = now()
  where id = gate.id;

  update public.offline_device_tokens
  set last_used_at = now()
  where gate_device_id = gate.id
    and token_hash = clean_token_hash;

  return jsonb_build_object(
    'ok', true,
    'token', new_token::text,
    'expires_in_seconds', 30
  );
end;
$$;

grant execute on function public.create_qr_session(text, text) to anon, authenticated;

-- Replace the old no-argument function so anon-key-only callers cannot mint QR sessions.
create or replace function public.create_qr_session()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return jsonb_build_object(
    'ok', false,
    'message', 'QR requires a trusted guard device'
  );
end;
$$;

grant execute on function public.create_qr_session() to anon, authenticated;

notify pgrst, 'reload schema';

-- =============================================================================
-- [12/14] SOURCE FILE: schema_patch_guard_screen_reset_auth.sql
-- =============================================================================

-- ALBASHIR Gate: authenticate reset_guard_screen() to the approved gate device
-- and fix a signature mismatch that silently broke the auto-reset flow.
--
-- Bug found during audit (NEW-7 / feeds into NEW-6):
-- index.html calls:
--     supabaseClient.rpc("reset_guard_screen", { p_device_code, p_device_token })
-- but the only function defined in schema.sql is reset_guard_screen() with NO
-- arguments. PostgREST cannot match a call with named parameters to a
-- zero-argument function, so every reset attempt fails. The failure is
-- swallowed client-side (console.warn only), so nothing visibly breaks — but
-- the last employee's name + employee_id keeps broadcasting on
-- guard_screen_status (readable by anyone holding the anon key, via
-- Realtime) until the NEXT QR scan overwrites it, instead of clearing after
-- ~6 seconds as the UI intends.
--
-- This migration adds the 2-argument overload the client actually calls,
-- authenticated the same way create_qr_session() is (device must be active
-- and present a valid, non-revoked offline_device_tokens entry). The
-- existing 0-argument function is left untouched for backward compatibility
-- but is no longer called by index.html.
--
-- Apply after schema_patch_gate_qr_device_auth.sql (uses
-- hash_offline_device_token() and offline_device_tokens from that layer).

create or replace function public.reset_guard_screen(
  p_device_code text,
  p_device_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_device_code text := trim(coalesce(p_device_code, ''));
  clean_token text := trim(coalesce(p_device_token, ''));
  clean_token_hash text;
  gate public.gate_devices%rowtype;
  token_ok boolean := false;
begin
  if clean_device_code = '' or clean_token = '' then
    return jsonb_build_object('ok', false, 'message', 'جهاز الحارس غير موثق');
  end if;

  select * into gate
  from public.gate_devices
  where device_code = clean_device_code
  limit 1;

  if gate.id is null or coalesce(gate.is_active, false) = false then
    perform public.log_gate_auth_failure(clean_device_code, 'reset_guard_screen: device not approved');
    return jsonb_build_object('ok', false, 'message', 'جهاز الحارس غير معتمد');
  end if;

  clean_token_hash := public.hash_offline_device_token(clean_token);

  select exists (
    select 1
    from public.offline_device_tokens
    where gate_device_id = gate.id
      and device_code = clean_device_code
      and token_hash = clean_token_hash
      and is_active = true
      and revoked_at is null
  )
  into token_ok;

  if token_ok = false then
    perform public.log_gate_auth_failure(clean_device_code, 'reset_guard_screen: invalid token');
    return jsonb_build_object('ok', false, 'message', 'رمز جهاز الحارس غير صالح');
  end if;

  update public.guard_screen_status
  set current_status = 'READY',
      employee_name = null,
      employee_id = null,
      message = 'QR جاهز للمسح',
      updated_at = now()
  where id = 1;

  update public.gate_devices
  set last_seen_at = now(),
      updated_at = now()
  where id = gate.id;

  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.reset_guard_screen(text, text) to anon, authenticated;

notify pgrst, 'reload schema';


-- =============================================================================
-- [13/14] SOURCE FILE: schema_patch_registration_category_split.sql
-- =============================================================================

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

-- =============================================================================
-- =============================================================================
-- [14/14] SOURCE FILE: schema_patch_register_hardening.sql
-- =============================================================================

-- =============================================================================
-- ALBASHIR Gate: registration hardening (length limits + specialty allowlist
-- + photo URL check + 13-arg grant freeze + profile category field)
-- Status: REPOSITORY ONLY — NOT APPLIED to Production.
-- Do NOT run this file against Production without explicit owner review and
-- approval. It redefines register_employee_request(15 args) and
-- employee_profile_login(text, text) and revokes the legacy 13-arg registration
-- grant. Applying it blindly would change live registration behavior.
-- Depends on: schema_patch_registration_category_split.sql (columns
-- registration_category / affiliated_entity and the CHECK constraint).
-- Run order for fresh installs: as layer [14/14] in
-- schema_consolidated_fresh_install.sql, after layer [13/13].
-- =============================================================================
-- Purpose:
-- 1) Freeze the legacy 13-argument register_employee_request overload by
--    revoking its anon/authenticated grants (function NOT dropped).
-- 2) Harden the 15-argument overload: input length limits, TEMPORARY specialty
--    must exist in the active specialty allowlist, photo URL must be a storage
--    path or https URL. PUBLIC execute is revoked (anon/authenticated kept).
-- 3) Return registration_category from employee_profile_login so profile.html
--    can display the real category instead of a static placeholder.
--    PUBLIC execute is revoked (anon/authenticated kept).
-- 4) Self-verification SELECT block (14 rows) runs as the final VERIFICATION BLOCK
--    of this consolidated file; all rows must read passed = true.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Freeze legacy 13-arg registration overload (revoke grants, keep function)
-- ---------------------------------------------------------------------------
revoke execute on function public.register_employee_request(text, text, text, text, text, text, text, text, text, text, text, text, text)
  from anon, authenticated, public;

-- ---------------------------------------------------------------------------
-- 2) Hardened 15-argument overload (body copied from
--    schema_patch_registration_category_split.sql, validations added)
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
  -- Input length limits (applied right after cleaning).
  if char_length(clean_name) > 120
     or char_length(clean_emp) > 32
     or char_length(clean_mobile) > 20
     or char_length(clean_specialty_in) > 80
     or char_length(coalesce(clean_affiliated, '')) > 120 then
    return jsonb_build_object(
      'ok', false,
      'result', 'DENIED',
      'message', 'تجاوزت البيانات الحد المسموح لطول الحقول'
    );
  end if;

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

  -- Photo must be an employee-photos storage path or an https URL.
  if clean_photo not like 'registrations/%'
     and clean_photo not like 'https://%' then
    return jsonb_build_object(
      'ok', false,
      'result', 'DENIED',
      'message', 'رابط الصورة الشخصية غير صالح'
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
    -- TEMPORARY specialty must exist in the active specialty allowlist.
    if not exists (
      select 1 from public.specialty_daily_limits
      where specialty_name = effective_specialty
        and is_active = true
    ) then
      return jsonb_build_object(
        'ok', false,
        'result', 'DENIED',
        'message', 'الاختصاص غير معتمد للتسجيل المؤقت / الخارجي'
      );
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

grant execute on function public.register_employee_request(text, text, text, text, text, text, text, text, text, text, text, text, text, text, text)
  to anon, authenticated;

-- CREATE OR REPLACE preserves pre-existing privileges, so explicitly revoke
-- PUBLIC execute to complete the freeze (anon/authenticated stay granted).
revoke execute on function public.register_employee_request(text, text, text, text, text, text, text, text, text, text, text, text, text, text, text)
  from public;

-- ---------------------------------------------------------------------------
-- 3) employee_profile_login: VERBATIM current Production body (rate limiting,
--    failed/success security audit, SECURITY DEFINER, search_path, qr_history,
--    change_requests, all returned fields) plus registration_category in the
--    returned profile jsonb. Nothing else changed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.employee_profile_login(p_employee_id text, p_mobile_number text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  reg record;
  clean_id text := trim(coalesce(p_employee_id, ''));
  clean_mobile text := trim(coalesce(p_mobile_number, ''));
begin

  -- Rate limit
  IF public.is_rate_limited(
      'employee_profile_login',
      clean_id,
      5,
      5
  ) THEN

    RETURN jsonb_build_object(
      'ok', false,
      'message', 'تم إيقاف المحاولة مؤقتاً بسبب كثرة المحاولات'
    );

  END IF;


  select * into reg
  from public.employee_registrations
  where employee_id = clean_id
    and mobile_number = clean_mobile
  limit 1;


  IF reg.id IS NULL THEN

    PERFORM public.write_security_attempt(
      'employee_profile_login',
      clean_id,
      clean_mobile,
      false
    );


    RETURN jsonb_build_object(
      'ok', false,
      'message', 'الرقم الوظيفي أو الهاتف غير صحيح'
    );

  END IF;


  PERFORM public.write_security_attempt(
    'employee_profile_login',
    clean_id,
    clean_mobile,
    true
  );


  RETURN jsonb_build_object(
    'ok', true,

    'profile', jsonb_build_object(
      'id', reg.id,
      'full_name', reg.full_name,
      'employee_id', reg.employee_id,
      'mobile_number', reg.mobile_number,
      'department', coalesce(reg.department, ''),
      'specialty', reg.specialty,
      'job_type', coalesce(reg.job_type, ''),
      'employee_photo_url', coalesce(reg.employee_photo_url, ''),
      'vehicle_type', coalesce(reg.vehicle_type, ''),
      'vehicle_plate', coalesce(reg.vehicle_plate, ''),
      'vehicle_color', coalesce(reg.vehicle_color, ''),
      'status', reg.status,
      'registration_category', coalesce(reg.registration_category, ''),
      'trusted_device_type', coalesce(reg.trusted_device_type, ''),
      'trusted_device_last_activity_at', reg.trusted_device_last_activity_at
    ),

    'qr_history',
    coalesce((
      select jsonb_agg(to_jsonb(log_row)
      order by log_row.created_at desc)
      from (
        select created_at, result, reason, specialty
        from public.gate_access_logs
        where employee_registration_id = reg.id
        order by created_at desc
        limit 30
      ) log_row
    ), '[]'::jsonb),

    'change_requests',
    coalesce((
      select jsonb_agg(to_jsonb(request_row)
      order by request_row.created_at desc)
      from (
        select id, requested_changes, reason, status, admin_note, created_at, reviewed_at
        from public.employee_data_change_requests
        where employee_registration_id = reg.id
        order by created_at desc
        limit 10
      ) request_row
    ), '[]'::jsonb)

  );


end;
$function$;

grant execute on function public.employee_profile_login(text, text) to anon, authenticated;

-- Same PUBLIC-freeze rationale as the 15-arg overload above.
revoke execute on function public.employee_profile_login(text, text)
  from public;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- VERIFICATION BLOCK — run after the script above completes successfully.
-- Confirms the canonical signatures exist and the frozen/deprecated ones
-- were not accidentally reintroduced, per PRODUCTION_RPC_CANONICAL_MAP.md.
-- Includes Layer 13 (registration_category_split) checks.
-- =============================================================================

select
  'create_qr_session(text,text) canonical exists' as check_name,
  to_regprocedure('public.create_qr_session(text,text)') is not null as passed
union all
select
  'register_employee_request(13 args) canonical exists',
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'register_employee_request'
      and pg_get_function_arguments(p.oid) ilike '%p_device_token%'
      and array_length(p.proargtypes, 1) = 13
  )
union all
select
  'trusted_device_profile_login(text) exists exactly once',
  (
    select count(*) from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'trusted_device_profile_login'
  ) = 1
union all
select
  'admin_approve_gate_device(text,boolean) canonical exists',
  to_regprocedure('public.admin_approve_gate_device(text,boolean)') is not null
union all
select
  'deprecated admin_set_guard_device_status is absent',
  to_regprocedure('public.admin_set_guard_device_status(text,boolean)') is null
union all
select
  'registration_category column exists',
  exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'employee_registrations'
      and column_name = 'registration_category'
  )
union all
select
  'affiliated_entity column exists',
  exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'employee_registrations'
      and column_name = 'affiliated_entity'
  )
union all
select
  'chk_employee_registrations_registration_category exists',
  exists (
    select 1 from pg_constraint
    where conname = 'chk_employee_registrations_registration_category'
      and conrelid = 'public.employee_registrations'::regclass
  )
union all
select
  'register_employee_request(15 args) exists',
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'register_employee_request'
      and array_length(p.proargtypes, 1) = 15
  )
union all
select
  'register_employee_request(15 args) has 0 defaults',
  coalesce((
    select p.pronargdefaults from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'register_employee_request'
      and array_length(p.proargtypes, 1) = 15
  ), -1) = 0
union all
select
  'register_employee_request(13 args) still exists',
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'register_employee_request'
      and array_length(p.proargtypes, 1) = 13
  )
union all
select
  'register_employee_request(13 args) has no anon execute',
  coalesce(has_function_privilege('anon', (
    select p.oid from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'register_employee_request'
      and array_length(p.proargtypes, 1) = 13
  ), 'execute'), true) = false
union all
select
  'register_employee_request(15 args) has no public execute',
  coalesce(has_function_privilege('public', (
    select p.oid from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'register_employee_request'
      and array_length(p.proargtypes, 1) = 15
  ), 'execute'), true) = false
union all
select
  'employee_profile_login has no public execute',
  coalesce(has_function_privilege('public', (
    select p.oid from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'employee_profile_login'
  ), 'execute'), true) = false
union all
select
  'employee_profile_login retains is_rate_limited',
  (select to_regprocedure('public.employee_profile_login(text, text)') is not null
   and position('is_rate_limited' in pg_get_functiondef('public.employee_profile_login(text, text)'::regprocedure)) > 0)
union all
select
  'employee_profile_login retains write_security_attempt',
  (select to_regprocedure('public.employee_profile_login(text, text)') is not null
   and position('write_security_attempt' in pg_get_functiondef('public.employee_profile_login(text, text)'::regprocedure)) > 0);

-- All sixteen rows above must read passed = true. If any reads false, stop and
-- investigate before pointing the application at this database — do not
-- proceed to register real employees or approve real gate devices.

-- Final canonical P0-3 override: mandatory QR, complete Production response fields.
-- Earlier definitions above are historical composition layers, not deployment patches.
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

  qr_ok := public.validate_and_use_qr_token(p_qr_token);
  IF qr_ok IS NOT TRUE THEN
    PERFORM public.set_guard_status('DENIED', NULL, clean_emp, 'QR غير صالح أو منتهي');
    RETURN jsonb_build_object('ok', true, 'result', 'DENIED', 'message', 'QR غير صالح أو منتهي، يرجى مسح QR جديد');
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

-- Optional: schedule periodic cleanup (NOT enabled by default — uncomment
-- and run separately if pg_cron is available on this project):
-- select cron.schedule('erp-cleanup-expired-qr-sessions', '*/15 * * * *',
--   $$select public.cleanup_expired_qr_sessions()$$);
-- select cron.schedule('erp-offline-logs-retention', '0 3 1 * *',
--   $$select public.cleanup_old_offline_access_logs(12)$$);

-- Final guard state: Phase A + Phase B. Existing Production must use staged rollout.
-- Phase A: approved candidate. NOT APPLIED to Production.
-- Preserve legacy employee-result access until frontend deployment is confirmed.
-- No tables/RLS changed; legacy functions retained for owner/service_role.
CREATE OR REPLACE FUNCTION public.get_guard_employee_result(p_employee_id text, p_device_code text, p_device_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  clean_device_code text := trim(coalesce(p_device_code, ''));
  clean_token text := trim(coalesce(p_device_token, ''));
  clean_token_hash text;
  gate public.gate_devices%rowtype;
  token_ok boolean := false;
  reg public.employee_registrations%rowtype;
  result jsonb;
begin
  if clean_device_code = '' or clean_token = '' then
    return jsonb_build_object('ok', false, 'message', 'جهاز الحارس غير موثق');
  end if;

  select * into gate
  from public.gate_devices
  where device_code = clean_device_code
  limit 1;

  if gate.id is null or coalesce(gate.is_active, false) = false then
    perform public.log_gate_auth_failure(clean_device_code, 'get_guard_employee_result: device not approved');
    return jsonb_build_object('ok', false, 'message', 'جهاز الحارس غير معتمد');
  end if;

  clean_token_hash := public.hash_offline_device_token(clean_token);

  select exists (
    select 1
    from public.offline_device_tokens
    where gate_device_id = gate.id
      and device_code = clean_device_code
      and token_hash = clean_token_hash
      and is_active = true
      and revoked_at is null
  )
  into token_ok;

  if token_ok = false then
    perform public.log_gate_auth_failure(clean_device_code, 'get_guard_employee_result: invalid token');
    return jsonb_build_object('ok', false, 'message', 'رمز جهاز الحارس غير صالح');
  end if;

  select * into reg from public.employee_registrations
  where employee_id = trim(coalesce(p_employee_id, ''))
  limit 1;
  if reg.id is null then return null; end if;
  result := public.employee_result_details(reg.id);
  return result - 'mobile_number';
end;
$function$;

REVOKE EXECUTE ON FUNCTION public.get_guard_employee_result(text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_guard_employee_result(text,text,text) TO anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.reset_guard_screen() FROM PUBLIC, anon, authenticated;

-- Phase B: NOT APPLIED. Apply ONLY after Phase A and live frontend confirmation.
-- Confirm index.html sends employee id, gate code and gate token; retain owner/service_role.
REVOKE EXECUTE ON FUNCTION public.get_guard_employee_result(text) FROM PUBLIC, anon, authenticated;

-- =============================================================================
-- STAGING READINESS CORRECTION CANDIDATE — REVIEW ONLY, NOT APPLIED
-- Target for any separately approved execution: EMPTY adwvokwucotohwayorgx.
-- No Production execution. No grants to anon, no guard-screen grants, no RLS
-- or changes to existing RPC bodies. Helpers below restore missing dependencies.
-- =============================================================================
-- Existing Production helper definitions captured read-only with owner approval.
-- Fresh-install candidate ONLY; no Production change. Preserve the exact live
-- counting policy and MD5 mobile hash; do not invent replacement auth behavior.
CREATE TABLE IF NOT EXISTS public.security_attempt_logs (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  action text NOT NULL,
  employee_id text,
  mobile_hash text,
  success boolean DEFAULT false,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT security_attempt_logs_pkey PRIMARY KEY (id)
);
ALTER TABLE public.security_attempt_logs OWNER TO postgres;
ALTER TABLE public.security_attempt_logs ENABLE ROW LEVEL SECURITY;
-- Internal ledger: no client table grant or read policy is required.
REVOKE ALL ON TABLE public.security_attempt_logs FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.is_rate_limited(p_action text, p_employee_id text, p_max_attempts integer, p_minutes integer)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  attempts integer;
BEGIN

  SELECT count(*)
  INTO attempts
  FROM public.security_attempt_logs
  WHERE action = p_action
    AND employee_id = p_employee_id
    AND success = false
    AND created_at >= now() - make_interval(mins => p_minutes);

  RETURN attempts >= p_max_attempts;

END;
$function$;
ALTER FUNCTION public.is_rate_limited(text,text,integer,integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.is_rate_limited(text,text,integer,integer) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.write_security_attempt(p_action text, p_employee_id text, p_mobile text, p_success boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN

INSERT INTO public.security_attempt_logs
(
 action,
 employee_id,
 mobile_hash,
 success
)
VALUES
(
 p_action,
 p_employee_id,
 md5(coalesce(p_mobile,'')),
 p_success
);

END;
$function$;
ALTER FUNCTION public.write_security_attempt(text,text,text,boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.write_security_attempt(text,text,text,boolean) FROM PUBLIC, anon, authenticated, service_role;

-- Only tables actually queried by admin_dashboard.html; existing RLS still
-- decides which authenticated users can see rows. Writes remain behind RPCs.
GRANT SELECT ON TABLE
  public.employee_registrations,
  public.specialty_daily_limits,
  public.gate_access_logs,
  public.violation_reports,
  public.admin_profiles,
  public.admin_audit_logs,
  public.employee_data_change_requests
TO authenticated;

-- The backend photo resolver authenticates employee credentials via this RPC.
-- service_role is server-only. PUBLIC stays revoked; browser grants unchanged.
GRANT EXECUTE ON FUNCTION public.employee_profile_login(text,text) TO service_role;

-- Approved final guard status privacy definition
-- Approved guard status introduction. Apply before frontend switch.
CREATE OR REPLACE FUNCTION public.get_guard_screen_status(p_device_code text, p_device_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  clean_device_code text := trim(coalesce(p_device_code, ''));
  clean_token text := trim(coalesce(p_device_token, ''));
  gate public.gate_devices%rowtype;
  token_ok boolean := false;
  result jsonb;
begin
  if clean_device_code = '' or clean_token = '' then
    return jsonb_build_object('ok', false, 'error', 'DENIED');
  end if;
  select * into gate from public.gate_devices where device_code = clean_device_code limit 1;
  if gate.id is null or coalesce(gate.is_active, false) = false then
    perform public.log_gate_auth_failure(clean_device_code, 'get_guard_screen_status: device not approved');
    return jsonb_build_object('ok', false, 'error', 'DENIED');
  end if;
  select exists (
    select 1 from public.offline_device_tokens
    where gate_device_id = gate.id and device_code = clean_device_code
      and token_hash = public.hash_offline_device_token(clean_token)
      and is_active = true and revoked_at is null
  ) into token_ok;
  if token_ok is not true then
    perform public.log_gate_auth_failure(clean_device_code, 'get_guard_screen_status: invalid token');
    return jsonb_build_object('ok', false, 'error', 'DENIED');
  end if;
  select jsonb_build_object('current_status',current_status,'employee_name',employee_name,
    'employee_id',employee_id,'message',message,'updated_at',updated_at)
  into result from public.guard_screen_status where id = 1;
  return jsonb_build_object('ok',true,'status',result);
end;
$function$;
REVOKE EXECUTE ON FUNCTION public.get_guard_screen_status(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_guard_screen_status(text,text) TO anon, authenticated, service_role;

-- Apply ONLY after live index.html uses device-authenticated status RPC.
REVOKE SELECT ON TABLE public.guard_screen_status FROM PUBLIC, anon, authenticated;
DROP POLICY IF EXISTS "Anyone can read guard screen status" ON public.guard_screen_status;

-- Reviewed fixed search_path for five existing helpers/triggers
-- Scoped search_path hardening. Owner review required before Production apply.
-- All referenced custom functions are already schema-qualified with public.
-- Builtins resolve in pg_catalog; no unqualified tables or extension calls.
-- ALTER preserves bodies, ownership, volatility, signatures and grants.
ALTER FUNCTION public.normalize_specialty_name(text) SET search_path TO pg_catalog;
ALTER FUNCTION public.is_permanently_allowed_specialty(text) SET search_path TO pg_catalog;
ALTER FUNCTION public.default_admin_permissions(text) SET search_path TO pg_catalog;
ALTER FUNCTION public.sync_trusted_device_activity() SET search_path TO pg_catalog;
-- This Production-only trigger is absent from the existing fresh-install baseline.
-- Do not introduce new identity logic as part of a search_path-only change.
DO $reviewed$ BEGIN
  IF to_regprocedure('public.prevent_approved_employee_identity_change()') IS NOT NULL THEN
    ALTER FUNCTION public.prevent_approved_employee_identity_change() SET search_path TO pg_catalog;
  END IF;
END $reviewed$;

-- Synchronize live 15-argument APPROVED caller phone validation
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

-- Approved new gate devices require explicit activation
-- Owner approved Production application on 2026-10-07. Existing rows unchanged.
ALTER TABLE public.gate_devices ALTER COLUMN is_active SET DEFAULT false;

-- Reviewed P2-18 final enrollment, binding, TTL and ACL sequence
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

-- Latest owner decision supersedes QR-claim requirement for registration-device approval only.
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

-- Final owner device policy: retained until administrative revocation.
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

-- Owner-approved public guard session interface.
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

-- Public guard trusted-device result synchronization.
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

-- Current owner-approved registration taxonomy: distinct permanent Other.
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

-- Reviewed QR retry protocol; bounded response replay and unambiguous payload encoding.
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

-- Owner-authorized authenticated emergency entry, 2026-10-10.
-- QR display remains public. Only the new manual-entry path needs guard login.
create table private.guard_accounts (
  id uuid primary key default gen_random_uuid(),
  full_name text not null check(length(full_name) between 2 and 100),
  national_id text not null unique check(national_id ~ '^[0-9]{6,20}$'),
  phone_hash text not null,
  phone_hint text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index guard_accounts_name_unique on private.guard_accounts(lower(trim(full_name)));
create table private.guard_login_attempts (
  id bigint generated always as identity primary key,
  identity_hash text not null,
  created_at timestamptz not null default now()
);
create index guard_login_attempts_time on private.guard_login_attempts(created_at);
create index guard_login_attempts_identity on private.guard_login_attempts(identity_hash,created_at);
create table private.guard_sessions (
  token_hash text primary key,
  guard_id uuid not null references private.guard_accounts(id) on delete cascade,
  expires_at timestamptz not null default now()+interval '24 hours'
);
create table private.guard_emergency_settings (
  singleton boolean primary key default true check(singleton),
  enabled boolean not null default false
);
insert into private.guard_emergency_settings(singleton,enabled) values(true,false);
create table private.guard_manual_entries (
  guard_id uuid not null references private.guard_accounts(id),
  request_id uuid not null,
  employee_id text not null,
  response jsonb not null,
  created_at timestamptz not null default now(),
  primary key(guard_id,request_id)
);
create index guard_manual_entries_time on private.guard_manual_entries(created_at);
alter table private.guard_accounts enable row level security;
alter table private.guard_login_attempts enable row level security;
alter table private.guard_sessions enable row level security;
alter table private.guard_emergency_settings enable row level security;
alter table private.guard_manual_entries enable row level security;
revoke all on private.guard_accounts,private.guard_login_attempts,private.guard_sessions,
  private.guard_emergency_settings,private.guard_manual_entries from public,anon,authenticated;

create function private.guard_normalize_phone(p_phone text) returns text
language sql immutable set search_path=pg_catalog as $$
  select regexp_replace(regexp_replace(
    translate(trim(coalesce(p_phone,'')),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789'),
    '[^0-9]','','g'),'^(00962|962)','0');
$$;
revoke all on function private.guard_normalize_phone(text) from public,anon,authenticated;

create function public.admin_save_guard(p_guard_id uuid,p_full_name text,p_national_id text,p_phone text,p_is_active boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private,extensions as $$
declare g_id uuid; phone text:=private.guard_normalize_phone(p_phone); name text:=trim(p_full_name); national text:=translate(trim(p_national_id),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789');
begin
  if not public.is_super_admin() then return jsonb_build_object('ok',false,'message','هذه العملية للسوبر أدمن فقط'); end if;
  if name is null or length(name) not between 2 and 100 or name ~ '^[0-9]+$' or national is null or national !~ '^[0-9]{6,20}$'
     or p_is_active is null or (phone<>'' and phone !~ '^[0-9]{8,15}$') or (p_guard_id is null and phone='') then
    return jsonb_build_object('ok',false,'message','تحقق من الاسم والرقم الوطني ورقم الهاتف');
  end if;
  if p_guard_id is null then
    insert into private.guard_accounts(full_name,national_id,phone_hash,phone_hint,is_active)
    values(name,national,extensions.crypt(phone,extensions.gen_salt('bf',10)),right(phone,4),p_is_active) returning id into g_id;
  else
    update private.guard_accounts set full_name=name,national_id=national,is_active=p_is_active,
      phone_hash=case when phone='' then phone_hash else extensions.crypt(phone,extensions.gen_salt('bf',10)) end,
      phone_hint=case when phone='' then phone_hint else right(phone,4) end
    where id=p_guard_id returning id into g_id;
    if g_id is null then return jsonb_build_object('ok',false,'message','ملف الحارس غير موجود'); end if;
    -- Editing identity, phone or status revokes all existing sessions immediately.
    delete from private.guard_sessions where guard_id=g_id;
  end if;
  insert into public.admin_audit_logs(admin_auth_user_id,action,target_table,target_id,details)
  values(auth.uid(),'SAVE_GUARD_ACCOUNT','guard_accounts',g_id::text,jsonb_build_object('is_active',p_is_active));
  return jsonb_build_object('ok',true,'message','تم حفظ ملف الحارس');
exception when unique_violation then
  return jsonb_build_object('ok',false,'message','الاسم أو الرقم الوطني مستخدم؛ اختر اسمًا مميزًا للحارس');
end; $$;
revoke all on function public.admin_save_guard(uuid,text,text,text,boolean) from public,anon;
grant execute on function public.admin_save_guard(uuid,text,text,text,boolean) to authenticated;

create function public.admin_list_guards() returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,private as $$
begin
  if not public.is_super_admin() then return jsonb_build_object('ok',false,'message','غير مصرح'); end if;
  return jsonb_build_object('ok',true,'emergency_enabled',(select enabled from private.guard_emergency_settings),
    'guards',coalesce((select jsonb_agg(jsonb_build_object('id',id,'full_name',full_name,'national_id',national_id,
      'phone_hint',phone_hint,'is_active',is_active) order by full_name) from private.guard_accounts),'[]'::jsonb));
end; $$;
revoke all on function public.admin_list_guards() from public,anon;
grant execute on function public.admin_list_guards() to authenticated;

create function public.admin_set_guard_emergency(p_enabled boolean) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,private as $$
begin
  if not public.is_super_admin() then return jsonb_build_object('ok',false,'message','غير مصرح'); end if;
  if p_enabled is null then return jsonb_build_object('ok',false,'message','حالة غير صحيحة'); end if;
  update private.guard_emergency_settings set enabled=p_enabled;
  insert into public.admin_audit_logs(admin_auth_user_id,action,target_table,details)
  values(auth.uid(),'SET_GUARD_EMERGENCY','guard_emergency_settings',jsonb_build_object('enabled',p_enabled));
  return jsonb_build_object('ok',true,'message','تم تحديث وضع الطوارئ');
end; $$;
revoke all on function public.admin_set_guard_emergency(boolean) from public,anon;
grant execute on function public.admin_set_guard_emergency(boolean) to authenticated;

create function public.guard_login(p_identity text,p_phone text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,private,extensions as $$
declare g private.guard_accounts%rowtype; identity text:=translate(lower(trim(coalesce(p_identity,''))),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789'); phone text:=private.guard_normalize_phone(p_phone);
  ih text; token text; expiry timestamptz:=now()+interval '24 hours';
begin
  if length(identity) not between 2 and 100 or phone !~ '^[0-9]{8,15}$' then return jsonb_build_object('ok',false,'message','تحقق من الاسم أو الرقم الوطني ورقم الهاتف'); end if;
  perform pg_advisory_xact_lock(610100901);
  delete from private.guard_login_attempts where created_at<now()-interval '1 day';
  delete from private.guard_sessions where expires_at<=now();
  ih:=encode(extensions.digest(identity,'sha256'),'hex');
  if (select count(*) from private.guard_login_attempts where created_at>now()-interval '1 minute')>=120
     or (select count(*) from private.guard_login_attempts where identity_hash=ih and created_at>now()-interval '15 minutes')>=5 then
    return jsonb_build_object('ok',false,'message','محاولات كثيرة؛ انتظر 15 دقيقة ثم حاول مجددًا');
  end if;
  insert into private.guard_login_attempts(identity_hash) values(ih);
  select * into g from private.guard_accounts where lower(trim(full_name))=identity or national_id=identity for update;
  if g.id is null or not g.is_active then
    perform extensions.crypt(phone,extensions.gen_salt('bf',10));
    return jsonb_build_object('ok',false,'message','تحقق من الاسم أو الرقم الوطني ورقم الهاتف');
  end if;
  if extensions.crypt(phone,g.phone_hash)<>g.phone_hash then return jsonb_build_object('ok',false,'message','تحقق من الاسم أو الرقم الوطني ورقم الهاتف'); end if;
  token:=encode(extensions.gen_random_bytes(32),'hex');
  delete from private.guard_sessions where guard_id=g.id;
  insert into private.guard_sessions(token_hash,guard_id,expires_at) values(encode(extensions.digest(token,'sha256'),'hex'),g.id,expiry);
  return jsonb_build_object('ok',true,'token',token,'expires_at',expiry,'full_name',g.full_name,
    'emergency_enabled',(select enabled from private.guard_emergency_settings));
end; $$;
revoke all on function public.guard_login(text,text) from public;
grant execute on function public.guard_login(text,text) to anon,authenticated;

create function private.guard_session_id(p_token text) returns uuid
language sql stable set search_path=pg_catalog,private,extensions as $$
  select g.id from private.guard_sessions s join private.guard_accounts g on g.id=s.guard_id
  where p_token ~ '^[0-9a-f]{64}$' and s.token_hash=encode(extensions.digest(p_token,'sha256'),'hex')
    and s.expires_at>now() and g.is_active;
$$;
revoke all on function private.guard_session_id(text) from public,anon,authenticated;

create function public.guard_session_status(p_token text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare g_id uuid:=private.guard_session_id(p_token);
begin
  if g_id is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
  return jsonb_build_object('ok',true,'full_name',(select full_name from private.guard_accounts where id=g_id),
    'emergency_enabled',(select enabled from private.guard_emergency_settings));
end; $$;
revoke all on function public.guard_session_status(text) from public;
grant execute on function public.guard_session_status(text) to anon,authenticated;

create function public.guard_logout(p_token text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,private,extensions as $$
begin
  if p_token ~ '^[0-9a-f]{64}$' then delete from private.guard_sessions where token_hash=encode(extensions.digest(p_token,'sha256'),'hex'); end if;
  return jsonb_build_object('ok',true);
end; $$;
revoke all on function public.guard_logout(text) from public;
grant execute on function public.guard_logout(text) to anon,authenticated;

create function public.guard_manual_employee_entry(p_token text,p_employee_id text,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,private,extensions as $$
declare g_id uuid; reg public.employee_registrations%rowtype; q public.qr_sessions%rowtype;
  prior private.guard_manual_entries%rowtype; r jsonb; response jsonb; read_key text; emp text:=translate(trim(coalesce(p_employee_id,'')),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789');
begin
  g_id:=private.guard_session_id(p_token);
  if g_id is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED','message','سجّل دخول الحارس أولًا'); end if;
  -- Lock the account against revocation for this decision, then recheck session.
  perform 1 from private.guard_accounts where id=g_id for share;
  if private.guard_session_id(p_token) is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
  if p_request_id is null or length(emp) not between 1 and 100 then return jsonb_build_object('ok',false,'message','أدخل الرقم الوظيفي أو الوطني'); end if;
  perform pg_advisory_xact_lock(610100902);
  select * into prior from private.guard_manual_entries where guard_id=g_id and request_id=p_request_id;
  if prior.request_id is not null then
    if prior.employee_id<>emp then return jsonb_build_object('ok',false,'error','REQUEST_MISMATCH'); end if;
    return prior.response;
  end if;
  if not (select enabled from private.guard_emergency_settings) then return jsonb_build_object('ok',false,'message','الدخول اليدوي للطوارئ غير مفعّل؛ راجع الإدارة'); end if;
  if (select count(*) from private.guard_manual_entries where guard_id=g_id and created_at>now()-interval '1 minute')>=30 then
    return jsonb_build_object('ok',false,'message','محاولات كثيرة؛ انتظر دقيقة');
  end if;
  select * into reg from public.employee_registrations where employee_id=emp order by created_at desc limit 1;
  if reg.id is null then
    response:=jsonb_build_object('ok',true,'result','DENIED','message','الموظف غير موجود أو غير مصرح','employee',null,'counted',false);
  else
    -- Reuse the existing decision function, including status/device/specialty
    -- and daily-limit rules. A server-only single-use QR is issued ONLY after
    -- guard authorization; no caller receives or supplies this token.
    insert into public.qr_sessions(expires_at) values(now()+interval '30 seconds') returning * into q;
    r:=public.manual_employee_check(reg.employee_id,reg.mobile_number,q.token::text);
    read_key:=encode(extensions.gen_random_bytes(32),'hex');
    insert into private.public_guard_sessions(qr_session_id,read_key_hash,expires_at,result,employee_registration_id,decided_at)
    values(q.id,encode(extensions.digest(read_key,'sha256'),'hex'),now()+interval '60 seconds',
      case when r->>'result' in ('ALLOWED','LIMITED') then r->>'result' else 'DENIED' end,reg.id,now());
    response:=public.get_public_guard_result(read_key)||jsonb_build_object('message',r->>'message','read_key',read_key,
      'counted',(r->>'result') in ('ALLOWED','LIMITED'));
    update public.gate_access_logs set reason='GUARD_MANUAL_EMERGENCY:'||coalesce(reason,'') where qr_token=q.token;
  end if;
  insert into private.guard_manual_entries(guard_id,request_id,employee_id,response) values(g_id,p_request_id,emp,response);
  insert into public.admin_audit_logs(admin_auth_user_id,action,target_table,target_id,details)
  values(null,'GUARD_MANUAL_ENTRY','employee_registrations',reg.id::text,
    jsonb_build_object('guard_id',g_id,'request_id',p_request_id,'result',response->>'result','counted',response->'counted'));
  return response;
end; $$;
revoke all on function public.guard_manual_employee_entry(text,text,uuid) from public;
grant execute on function public.guard_manual_employee_entry(text,text,uuid) to anon,authenticated;

-- Owner requested: national ID only login; optional private guard profile.
alter table private.guard_accounts drop constraint guard_accounts_full_name_check;
alter table private.guard_accounts add constraint guard_accounts_full_name_check check(length(full_name)=0 or length(full_name) between 2 and 100);
drop index private.guard_accounts_name_unique;
create or replace function public.admin_save_guard(p_guard_id uuid,p_full_name text,p_national_id text,p_phone text,p_is_active boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private,extensions as $$
declare g_id uuid; phone text:=private.guard_normalize_phone(p_phone); name text:=trim(coalesce(p_full_name,'')); national text:=translate(trim(p_national_id),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789');
begin
  if not public.is_super_admin() then return jsonb_build_object('ok',false,'message','هذه العملية للسوبر أدمن فقط'); end if;
  if length(name)>100 or length(name)=1 or national is null or national !~ '^[0-9]{6,20}$'
     or p_is_active is null or (phone<>'' and phone !~ '^[0-9]{8,15}$') or (p_guard_id is null and phone='') then
    return jsonb_build_object('ok',false,'message','تحقق من الرقم الوطني ورقم الهاتف؛ الاسم اختياري');
  end if;
  if p_guard_id is null then
    insert into private.guard_accounts(full_name,national_id,phone_hash,phone_hint,is_active)
    values(name,national,extensions.crypt(phone,extensions.gen_salt('bf',10)),right(phone,4),p_is_active) returning id into g_id;
  else
    update private.guard_accounts set full_name=name,national_id=national,is_active=p_is_active,
      phone_hash=case when phone='' then phone_hash else extensions.crypt(phone,extensions.gen_salt('bf',10)) end,
      phone_hint=case when phone='' then phone_hint else right(phone,4) end
    where id=p_guard_id returning id into g_id;
    if g_id is null then return jsonb_build_object('ok',false,'message','ملف الحارس غير موجود'); end if;
    -- Editing identity, phone or status revokes all existing sessions immediately.
    delete from private.guard_sessions where guard_id=g_id;
  end if;
  insert into public.admin_audit_logs(admin_auth_user_id,action,target_table,target_id,details)
  values(auth.uid(),'SAVE_GUARD_ACCOUNT','guard_accounts',g_id::text,jsonb_build_object('is_active',p_is_active));
  return jsonb_build_object('ok',true,'message','تم حفظ ملف الحارس');
exception when unique_violation then
  return jsonb_build_object('ok',false,'message','الرقم الوطني مستخدم لحارس آخر');
end; $$;
revoke all on function public.admin_save_guard(uuid,text,text,text,boolean) from public,anon;
grant execute on function public.admin_save_guard(uuid,text,text,text,boolean) to authenticated;

create or replace function public.guard_login(p_identity text,p_phone text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,private,extensions as $$
declare g private.guard_accounts%rowtype; identity text:=translate(lower(trim(coalesce(p_identity,''))),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789'); phone text:=private.guard_normalize_phone(p_phone);
  ih text; token text; expiry timestamptz:=now()+interval '24 hours';
begin
  if identity !~ '^[0-9]{6,20}$' or phone !~ '^[0-9]{8,15}$' then return jsonb_build_object('ok',false,'message','تحقق من الرقم الوطني ورقم الهاتف'); end if;
  perform pg_advisory_xact_lock(610100901);
  delete from private.guard_login_attempts where created_at<now()-interval '1 day';
  delete from private.guard_sessions where expires_at<=now();
  ih:=encode(extensions.digest(identity,'sha256'),'hex');
  if (select count(*) from private.guard_login_attempts where created_at>now()-interval '1 minute')>=120
     or (select count(*) from private.guard_login_attempts where identity_hash=ih and created_at>now()-interval '15 minutes')>=5 then
    return jsonb_build_object('ok',false,'message','محاولات كثيرة؛ انتظر 15 دقيقة ثم حاول مجددًا');
  end if;
  insert into private.guard_login_attempts(identity_hash) values(ih);
  select * into g from private.guard_accounts where national_id=identity for update;
  if g.id is null or not g.is_active then
    perform extensions.crypt(phone,extensions.gen_salt('bf',10));
    return jsonb_build_object('ok',false,'message','تحقق من الرقم الوطني ورقم الهاتف');
  end if;
  if extensions.crypt(phone,g.phone_hash)<>g.phone_hash then return jsonb_build_object('ok',false,'message','تحقق من الرقم الوطني ورقم الهاتف'); end if;
  token:=encode(extensions.gen_random_bytes(32),'hex');
  delete from private.guard_sessions where guard_id=g.id;
  insert into private.guard_sessions(token_hash,guard_id,expires_at) values(encode(extensions.digest(token,'sha256'),'hex'),g.id,expiry);
  return jsonb_build_object('ok',true,'token',token,'expires_at',expiry,'full_name',g.full_name,
    'emergency_enabled',(select enabled from private.guard_emergency_settings));
end; $$;
revoke all on function public.guard_login(text,text) from public;
grant execute on function public.guard_login(text,text) to anon,authenticated;

create table private.guard_profiles (
 guard_id uuid primary key references private.guard_accounts(id) on delete cascade,
 age integer check(age between 16 and 100), residence text not null default '' check(length(residence)<=200),
 about text not null default '' check(length(about)<=1000), photo bytea,
 updated_at timestamptz not null default now(),
 check(photo is null or (octet_length(photo) between 4 and 196608 and encode(substring(photo from 1 for 3),'hex')='ffd8ff'))
);
alter table private.guard_profiles enable row level security;
revoke all on private.guard_profiles from public,anon,authenticated;

create function public.guard_get_profile(p_token text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,private,public as $$
declare gid uuid:=private.guard_session_id(p_token); g private.guard_accounts%rowtype; p private.guard_profiles%rowtype;
begin
 if gid is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
 select * into g from private.guard_accounts where id=gid;
 select * into p from private.guard_profiles where guard_id=gid;
 return jsonb_build_object('ok',true,'profile',jsonb_build_object('full_name',g.full_name,'national_id',g.national_id,
 'age',p.age,'residence',coalesce(p.residence,''),'about',coalesce(p.about,''),
 'photo_base64',case when p.photo is null then null else encode(p.photo,'base64') end));
end; $$;
revoke all on function public.guard_get_profile(text) from public;
grant execute on function public.guard_get_profile(text) to anon,authenticated;

create function public.guard_save_profile(p_token text,p_profile jsonb) returns jsonb
language plpgsql security definer set search_path=pg_catalog,private,public as $$
declare gid uuid:=private.guard_session_id(p_token); n text; a integer; r text; b text; picture bytea;
begin
 if gid is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
 perform 1 from private.guard_accounts where id=gid for update;
 if private.guard_session_id(p_token) is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
 if p_profile is null or jsonb_typeof(p_profile)<>'object' then return jsonb_build_object('ok',false,'message','بيانات غير صحيحة'); end if;
 n:=trim(coalesce(p_profile->>'full_name','')); r:=trim(coalesce(p_profile->>'residence','')); b:=trim(coalesce(p_profile->>'about',''));
 if length(n)>100 or length(n)=1 or length(r)>200 or length(b)>1000 then return jsonb_build_object('ok',false,'message','تحقق من طول المعلومات المدخلة'); end if;
 if nullif(p_profile->>'age','') is not null then
  if (p_profile->>'age') !~ '^[0-9]{2,3}$' then return jsonb_build_object('ok',false,'message','أدخل عمرًا صحيحًا أو اتركه فارغًا'); end if;
  a:=(p_profile->>'age')::integer;
  if a not between 16 and 100 then return jsonb_build_object('ok',false,'message','العمر بين 16 و100 سنة'); end if;
 end if;
 if p_profile ? 'photo_base64' then
  if length(coalesce(p_profile->>'photo_base64',''))>262144 then return jsonb_build_object('ok',false,'message','الصورة كبيرة؛ اختر صورة أصغر'); end if;
  picture:=decode(coalesce(p_profile->>'photo_base64',''),'base64');
  if octet_length(picture) not between 4 and 196608 or encode(substring(picture from 1 for 3),'hex')<>'ffd8ff' then
   return jsonb_build_object('ok',false,'message','الصورة غير صالحة');
  end if;
 end if;
 insert into private.guard_profiles(guard_id,age,residence,about,photo)
 values(gid,a,r,b,picture)
 on conflict(guard_id) do update set age=excluded.age,residence=excluded.residence,about=excluded.about,
 photo=case when p_profile->>'remove_photo'='true' then null when p_profile ? 'photo_base64' then excluded.photo else guard_profiles.photo end,updated_at=now();
 update private.guard_accounts set full_name=n where id=gid;
 insert into public.admin_audit_logs(action,target_table,target_id,details)
 values('GUARD_UPDATE_OWN_PROFILE','guard_profiles',gid::text,jsonb_build_object('photo_changed',p_profile ? 'photo_base64' or p_profile->>'remove_photo'='true'));
 return jsonb_build_object('ok',true,'message','تم حفظ صفحتك الشخصية');
exception when invalid_parameter_value or data_exception then
 return jsonb_build_object('ok',false,'message','بيانات الصورة غير صالحة');
end; $$;
revoke all on function public.guard_save_profile(text,jsonb) from public;
grant execute on function public.guard_save_profile(text,jsonb) to anon,authenticated;

-- Owner-approved Staging transition: shared guards and private admin notices.
-- Owner approved Staging-only shared transition, optional requests and notifications.
alter table private.guard_accounts add column is_shared boolean not null default false;
create unique index guard_one_shared on private.guard_accounts(is_shared) where is_shared;
alter table private.guard_sessions add column created_at timestamptz not null default now();
create table private.guard_signins(id uuid primary key default gen_random_uuid(),guard_id uuid not null references private.guard_accounts(id) on delete cascade,is_shared boolean not null,created_at timestamptz not null default now());
create index guard_signins_recent on private.guard_signins(guard_id,created_at desc);
alter table private.guard_signins enable row level security;
revoke all on private.guard_signins from public,anon,authenticated;
create table private.guard_registration_requests(
 id uuid primary key default gen_random_uuid(),national_id text not null unique check(national_id ~ '^[0-9]{6,20}$'),
 phone_hash text not null,phone_hint text not null,full_name text not null default '',age integer check(age between 16 and 100),residence text not null default '',about text not null default '',photo bytea,
 status text not null default 'PENDING' check(status in ('PENDING','APPROVED','REJECTED')),
 submitted_by uuid not null references private.guard_accounts(id),request_id uuid not null unique,created_at timestamptz not null default now(),reviewed_at timestamptz,reviewed_by uuid,
 check(length(full_name)<=100 and length(full_name)<>1 and length(residence)<=200 and length(about)<=1000),
 check(photo is null or (octet_length(photo) between 4 and 196608 and encode(substring(photo from 1 for 3),'hex')='ffd8ff'))
);
create index guard_requests_pending on private.guard_registration_requests(status,created_at desc);
alter table private.guard_registration_requests enable row level security;
revoke all on private.guard_registration_requests from public,anon,authenticated;
create function public.admin_configure_shared_guard(p_phone text,p_enabled boolean default true) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,private,extensions as $$
declare gid uuid; phone text:=private.guard_normalize_phone(p_phone);
begin
 if not public.is_super_admin() then return jsonb_build_object('ok',false,'message','غير مصرح'); end if;
 if phone !~ '^[0-9]{8,15}$' or p_enabled is null then return jsonb_build_object('ok',false,'message','أدخل كلمة مرور رقمية من 8–15 رقمًا'); end if;
 select id into gid from private.guard_accounts where is_shared for update;
 if gid is null then
 insert into private.guard_accounts(full_name,national_id,phone_hash,phone_hint,is_active,is_shared) values('حساب الحراس الجماعي','7000000000',extensions.crypt(phone,extensions.gen_salt('bf',10)),right(phone,4),p_enabled,true) returning id into gid;
 else update private.guard_accounts set phone_hash=extensions.crypt(phone,extensions.gen_salt('bf',10)),phone_hint=right(phone,4),is_active=p_enabled where id=gid;delete from private.guard_sessions where guard_id=gid; end if;
 insert into public.admin_audit_logs(admin_auth_user_id,action,target_table,target_id,details) values(auth.uid(),'CONFIGURE_SHARED_GUARD','guard_accounts',gid::text,jsonb_build_object('enabled',p_enabled));
 return jsonb_build_object('ok',true,'national_id','7000000000','message','تم تحديث الحساب الجماعي');
 exception when unique_violation then return jsonb_build_object('ok',false,'message','معرف الحساب الجماعي مستخدم؛ راجع مسؤول النظام');
end;$$;
revoke all on function public.admin_configure_shared_guard(text,boolean) from public,anon;grant execute on function public.admin_configure_shared_guard(text,boolean) to authenticated;
create function public.guard_session_profile(p_token text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,private,extensions as $$
declare gid uuid:=private.guard_session_id(p_token);
begin
 if gid is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
 return (select jsonb_build_object('ok',true,'is_shared',g.is_shared,'full_name',g.full_name,'photo_base64',case when g.is_shared or p.photo is null then null else encode(p.photo,'base64') end,'logged_in_at',s.created_at,'emergency_enabled',(select enabled from private.guard_emergency_settings)) from private.guard_accounts g left join private.guard_profiles p on p.guard_id=g.id join private.guard_sessions s on s.guard_id=g.id and s.token_hash=encode(extensions.digest(p_token,'sha256'),'hex') where g.id=gid);
end;$$;
revoke all on function public.guard_session_profile(text) from public;grant execute on function public.guard_session_profile(text) to anon,authenticated;
alter function public.guard_save_profile(text,jsonb) rename to guard_save_profile_personal;
alter function public.guard_save_profile_personal(text,jsonb) set schema private;
revoke all on function private.guard_save_profile_personal(text,jsonb) from public,anon,authenticated;
create function public.guard_save_profile(p_token text,p_profile jsonb) returns jsonb language plpgsql security definer set search_path=pg_catalog,private,public as $$
declare gid uuid:=private.guard_session_id(p_token);
begin
 if gid is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
 if (select is_shared from private.guard_accounts where id=gid) then return jsonb_build_object('ok',false,'message','الحساب الجماعي لا يملك ملفًا شخصيًا؛ أرسل طلب حساب مستقل اختياريًا'); end if;
 return private.guard_save_profile_personal(p_token,p_profile);
end;$$;
revoke all on function public.guard_save_profile(text,jsonb) from public;grant execute on function public.guard_save_profile(text,jsonb) to anon,authenticated;
create function public.guard_submit_registration(p_token text,p_request_id uuid,p_national_id text,p_phone text,p_profile jsonb) returns jsonb
language plpgsql security definer set search_path=pg_catalog,private,public,extensions as $$
declare gid uuid:=private.guard_session_id(p_token);nid text:=translate(trim(p_national_id),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789');phone text:=private.guard_normalize_phone(p_phone);n text:=trim(coalesce(p_profile->>'full_name',''));a integer;r text:=trim(coalesce(p_profile->>'residence',''));b text:=trim(coalesce(p_profile->>'about',''));picture bytea;prior private.guard_registration_requests%rowtype;rid uuid;
begin
 if gid is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
 perform 1 from private.guard_accounts where id=gid and is_shared for share;
 if not found or private.guard_session_id(p_token) is null then return jsonb_build_object('ok',false,'message','الطلب متاح من الحساب الجماعي الفعال فقط'); end if;
 if p_request_id is null or nid is null or nid !~ '^[0-9]{6,20}$' or phone !~ '^[0-9]{8,15}$' or p_profile is null or jsonb_typeof(p_profile)<>'object' or length(n)>100 or length(n)=1 or length(r)>200 or length(b)>1000 then return jsonb_build_object('ok',false,'message','تحقق من الرقم الوطني والهاتف والمعلومات'); end if;
 perform pg_advisory_xact_lock(hashtextextended(nid,61010));
 select * into prior from private.guard_registration_requests where request_id=p_request_id;
 if prior.id is not null then
 if prior.national_id=nid and prior.submitted_by=gid then return jsonb_build_object('ok',true,'message','تم إرسال الطلب سابقًا للموافقة');end if;
 return jsonb_build_object('ok',false,'message','أعد تحميل الصفحة لإرسال طلب جديد');end if;
 if exists(select 1 from private.guard_accounts where national_id=nid) or exists(select 1 from private.guard_registration_requests where national_id=nid and status in ('PENDING','APPROVED')) then return jsonb_build_object('ok',false,'message','الرقم مسجل أو لديه طلب قائم؛ راجع الإدارة'); end if;
 if (select count(*) from private.guard_registration_requests where submitted_by=gid and created_at>now()-interval '1 hour')>=30 then return jsonb_build_object('ok',false,'message','طلبات كثيرة؛ أعد المحاولة لاحقًا'); end if;
 if nullif(p_profile->>'age','') is not null then if p_profile->>'age' !~ '^[0-9]{2,3}$' then return jsonb_build_object('ok',false,'message','العمر غير صحيح');end if;a:=(p_profile->>'age')::integer;if a not between 16 and 100 then return jsonb_build_object('ok',false,'message','العمر بين 16 و100');end if;end if;
 if p_profile ? 'photo_base64' then if length(p_profile->>'photo_base64')>262144 then return jsonb_build_object('ok',false,'message','الصورة كبيرة');end if;picture:=decode(p_profile->>'photo_base64','base64');if octet_length(picture) not between 4 and 196608 or encode(substring(picture from 1 for 3),'hex')<>'ffd8ff' then return jsonb_build_object('ok',false,'message','الصورة غير صالحة');end if;end if;
 insert into private.guard_registration_requests(national_id,phone_hash,phone_hint,full_name,age,residence,about,photo,submitted_by,request_id) values(nid,extensions.crypt(phone,extensions.gen_salt('bf',10)),right(phone,4),n,a,r,b,picture,gid,p_request_id)
 on conflict(national_id) do update set phone_hash=excluded.phone_hash,phone_hint=excluded.phone_hint,full_name=excluded.full_name,age=excluded.age,residence=excluded.residence,about=excluded.about,photo=excluded.photo,status='PENDING',request_id=excluded.request_id,created_at=now(),reviewed_at=null,reviewed_by=null returning id into rid;
 insert into public.admin_audit_logs(action,target_table,target_id,details) values('GUARD_REGISTRATION_REQUEST','guard_registration_requests',rid::text,'{}');
 return jsonb_build_object('ok',true,'message','تم إرسال طلب حسابك للموافقة. يمكنك الاستمرار بالحساب الجماعي');
 exception when data_exception then return jsonb_build_object('ok',false,'message','بيانات الصورة أو العمر غير صالحة');
end;$$;
revoke all on function public.guard_submit_registration(text,uuid,text,text,jsonb) from public;grant execute on function public.guard_submit_registration(text,uuid,text,text,jsonb) to anon,authenticated;
create function public.admin_guard_requests() returns jsonb language plpgsql security definer set search_path=pg_catalog,private,public as $$
begin
 if not public.is_super_admin() then return jsonb_build_object('ok',false,'message','غير مصرح');end if;
 return jsonb_build_object('ok',true,'requests',coalesce((select jsonb_agg(jsonb_build_object('id',id,'national_id',national_id,'phone_hint',phone_hint,'full_name',full_name,'age',age,'residence',residence,'about',about,'photo_base64',case when photo is null then null else encode(photo,'base64') end,'status',status,'created_at',created_at) order by created_at desc) from (select * from private.guard_registration_requests order by created_at desc limit 100) r),'[]'::jsonb),'signins',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'full_name',g.full_name,'is_shared',s.is_shared,'created_at',s.created_at) order by s.created_at desc) from (select * from private.guard_signins order by created_at desc limit 100) s join private.guard_accounts g on g.id=s.guard_id),'[]'::jsonb));
end;$$;
revoke all on function public.admin_guard_requests() from public,anon;grant execute on function public.admin_guard_requests() to authenticated;
create function public.admin_review_guard_request(p_id uuid,p_approve boolean) returns jsonb language plpgsql security definer set search_path=pg_catalog,private,public as $$
declare r private.guard_registration_requests%rowtype;gid uuid;
begin
 if not public.is_super_admin() or p_approve is null then return jsonb_build_object('ok',false,'message','غير مصرح');end if;
 select * into r from private.guard_registration_requests where id=p_id for update;
 if r.id is null or r.status<>'PENDING' then return jsonb_build_object('ok',false,'message','تمت مراجعة الطلب أو لم يعد موجودًا');end if;
 if p_approve then
 insert into private.guard_accounts(full_name,national_id,phone_hash,phone_hint,is_active) values(r.full_name,r.national_id,r.phone_hash,r.phone_hint,true) returning id into gid;
 insert into private.guard_profiles(guard_id,age,residence,about,photo) values(gid,r.age,r.residence,r.about,r.photo);
 end if;
 update private.guard_registration_requests set status=case when p_approve then 'APPROVED' else 'REJECTED' end,reviewed_at=now(),reviewed_by=auth.uid() where id=p_id;
 insert into public.admin_audit_logs(admin_auth_user_id,action,target_table,target_id,details) values(auth.uid(),'REVIEW_GUARD_REQUEST','guard_registration_requests',p_id::text,jsonb_build_object('approved',p_approve));
 return jsonb_build_object('ok',true,'message',case when p_approve then 'تم اعتماد حساب الحارس الشخصي' else 'تم رفض الطلب' end);
 exception when unique_violation then return jsonb_build_object('ok',false,'message','الرقم مسجل؛ لم تتغير حالة الطلب');
end;$$;
revoke all on function public.admin_review_guard_request(uuid,boolean) from public,anon;grant execute on function public.admin_review_guard_request(uuid,boolean) to authenticated;
create or replace function public.guard_login(p_identity text,p_phone text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,private,extensions as $$
declare g private.guard_accounts%rowtype; identity text:=translate(lower(trim(coalesce(p_identity,''))),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789'); phone text:=private.guard_normalize_phone(p_phone);
  ih text; token text; expiry timestamptz:=now()+interval '24 hours';
begin
  if identity !~ '^[0-9]{6,20}$' or phone !~ '^[0-9]{8,15}$' then return jsonb_build_object('ok',false,'message','تحقق من الرقم الوطني ورقم الهاتف'); end if;
  perform pg_advisory_xact_lock(610100901);
  delete from private.guard_login_attempts where created_at<now()-interval '1 day';
  delete from private.guard_sessions where expires_at<=now();
  ih:=encode(extensions.digest(identity,'sha256'),'hex');
  if (select count(*) from private.guard_login_attempts where created_at>now()-interval '1 minute')>=120
     or (select count(*) from private.guard_login_attempts where identity_hash=ih and created_at>now()-interval '15 minutes')>=5 then
    return jsonb_build_object('ok',false,'message','محاولات كثيرة؛ انتظر 15 دقيقة ثم حاول مجددًا');
  end if;
  insert into private.guard_login_attempts(identity_hash) values(ih);
  select * into g from private.guard_accounts where national_id=identity for update;
  if g.id is null or not g.is_active then
    perform extensions.crypt(phone,extensions.gen_salt('bf',10));
    return jsonb_build_object('ok',false,'message','تحقق من الرقم الوطني ورقم الهاتف');
  end if;
  if extensions.crypt(phone,g.phone_hash)<>g.phone_hash then return jsonb_build_object('ok',false,'message','تحقق من الرقم الوطني ورقم الهاتف'); end if;
  if g.is_shared then delete from private.guard_login_attempts where identity_hash=ih; end if;
  token:=encode(extensions.gen_random_bytes(32),'hex');
  if not g.is_shared then delete from private.guard_sessions where guard_id=g.id; end if;
  insert into private.guard_sessions(token_hash,guard_id,expires_at) values(encode(extensions.digest(token,'sha256'),'hex'),g.id,expiry);
  insert into private.guard_signins(guard_id,is_shared) values(g.id,g.is_shared);
  return jsonb_build_object('is_shared',g.is_shared)||jsonb_build_object('ok',true,'token',token,'expires_at',expiry,'full_name',g.full_name,
    'emergency_enabled',(select enabled from private.guard_emergency_settings));
end; $$;
revoke all on function public.guard_login(text,text) from public;
grant execute on function public.guard_login(text,text) to anon,authenticated;

create table private.admin_notice_events(id uuid primary key default gen_random_uuid(),event_key text not null unique,topic text not null,title text not null,body text not null,target text not null,created_at timestamptz not null default now());
create index admin_notice_recent on private.admin_notice_events(created_at desc);
create table private.admin_notice_reads(admin_id uuid not null,event_id uuid not null references private.admin_notice_events(id) on delete cascade,primary key(admin_id,event_id));
create table private.admin_notice_devices(admin_id uuid not null,device_id uuid not null,label text not null default '',subscription jsonb,enabled boolean not null default true,last_seen_at timestamptz not null default now(),primary key(admin_id,device_id));
create table private.admin_notice_outbox(id uuid primary key default gen_random_uuid(),event_id uuid not null references private.admin_notice_events(id) on delete cascade,admin_id uuid not null,device_id uuid not null,attempts integer not null default 0,available_at timestamptz not null default now(),sent_at timestamptz,last_error text,unique(event_id,admin_id,device_id));
create table private.admin_notice_config(singleton boolean primary key default true check(singleton),enabled_at timestamptz not null default now(),vapid_public text,vapid_private text,dispatch_key_hash text);
insert into private.admin_notice_config(singleton) values(true);
alter table private.admin_notice_events enable row level security;alter table private.admin_notice_reads enable row level security;alter table private.admin_notice_devices enable row level security;alter table private.admin_notice_outbox enable row level security;alter table private.admin_notice_config enable row level security;
revoke all on private.admin_notice_events,private.admin_notice_reads,private.admin_notice_devices,private.admin_notice_outbox,private.admin_notice_config from public,anon,authenticated;
create function private.admin_notice_allowed(p_uid uuid,p_topic text) returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select coalesce((select is_active and (role='SUPER_ADMIN' or case p_topic when 'GUARD_REQUEST' then false when 'REGISTRATION' then coalesce((permissions->>'can_approve_requests')::boolean,false) when 'PROFILE_CHANGE' then coalesce((permissions->>'can_approve_requests')::boolean,false) when 'VIOLATION' then coalesce((permissions->>'can_review_violations')::boolean,false) when 'LIMIT' then coalesce((permissions->>'can_manage_limits')::boolean,false) when 'SHIFT' then coalesce((permissions->>'can_view_logs')::boolean,false) else false end) from public.admin_profiles where auth_user_id=p_uid),false);
$$;
revoke all on function private.admin_notice_allowed(uuid,text) from public,anon,authenticated;
create function private.add_admin_notice(p_key text,p_topic text,p_title text,p_body text,p_target text) returns void language plpgsql security definer set search_path=pg_catalog,private,public as $$
declare eid uuid;
begin
 insert into private.admin_notice_events(event_key,topic,title,body,target) values(p_key,p_topic,p_title,p_body,p_target) on conflict(event_key) do nothing returning id into eid;
 if eid is null then return;end if;
 insert into private.admin_notice_outbox(event_id,admin_id,device_id) select eid,d.admin_id,d.device_id from private.admin_notice_devices d where d.enabled and d.subscription is not null and private.admin_notice_allowed(d.admin_id,p_topic);
end;$$;
revoke all on function private.add_admin_notice(text,text,text,text,text) from public,anon,authenticated;
create function private.registration_notice_trigger() returns trigger language plpgsql security definer set search_path=pg_catalog,private,public as $$
begin
 if tg_table_name='guard_registration_requests' then
 if new.status='PENDING' then perform private.add_admin_notice('guard:'||new.id||':'||new.created_at,'GUARD_REQUEST','طلب حساب حارس جديد','وصل طلب اختياري لاعتماد حساب حارس.','guardRequests');end if;
 elsif tg_table_name='employee_registrations' then
 if new.status in ('PENDING','PENDING_FIRST_ENTRY','NEW') then perform private.add_admin_notice('employee:'||new.id||':'||new.created_at,'REGISTRATION','طلب تسجيل موظف جديد','يوجد طلب تسجيل بانتظار المراجعة.','registrations');end if;
 elsif tg_table_name='violation_reports' then
 perform private.add_admin_notice('violation:'||new.id,'VIOLATION','أمن الصخره وتبليغات التجاوزات','وصل بلاغ جديد للمراجعة.','violations');
 end if;
 return new;
end;$$;
revoke all on function private.registration_notice_trigger() from public,anon,authenticated;
create trigger guard_request_notice after insert or update of status on private.guard_registration_requests for each row execute function private.registration_notice_trigger();
create trigger employee_request_notice after insert on public.employee_registrations for each row execute function private.registration_notice_trigger();
create trigger violation_request_notice after insert on public.violation_reports for each row execute function private.registration_notice_trigger();
create function private.limit_notice_trigger() returns trigger language plpgsql security definer set search_path=pg_catalog,private,public as $$
declare lim integer;used integer;
begin
 if new.result<>'LIMITED' then return new;end if;
 select daily_limit into lim from public.specialty_daily_limits where specialty_name=new.specialty and is_active;
 if lim is null or lim<1 then return new;end if;
 select count(*) into used from public.gate_access_logs where specialty=new.specialty and result='LIMITED' and created_at>=date_trunc('day',now()) and created_at<date_trunc('day',now())+interval '1 day';
 if used>=lim then perform private.add_admin_notice('limit:'||new.specialty||':'||date_trunc('day',now()),'LIMIT','اكتمل الحد اليومي','الاختصاص: '||new.specialty||' — الحد: '||lim,'limits');end if;
 return new;
end;$$;
revoke all on function private.limit_notice_trigger() from public,anon,authenticated;
create trigger daily_limit_notice after insert on public.gate_access_logs for each row execute function private.limit_notice_trigger();
create function private.admin_notice_tick() returns void language plpgsql security definer set search_path=pg_catalog,private,public as $$
declare d date;h integer;end_at timestamptz;start_at timestamptz;stats text;label text;
begin
 for d in select generate_series((now() at time zone 'Asia/Amman')::date-1,(now() at time zone 'Asia/Amman')::date,interval '1 day')::date loop
 foreach h in array array[7,15,23] loop
 end_at:=(d+make_time(h,0,0)) at time zone 'Asia/Amman';start_at:=end_at-interval '8 hours';
 if end_at<=now() and end_at>=(select enabled_at from private.admin_notice_config) then
 label:=case h when 7 then 'C' when 15 then 'A' else 'B' end;
 select 'مسموح: '||count(*) filter(where result='ALLOWED')||'، مؤقت: '||count(*) filter(where result='LIMITED')||'، مرفوض: '||count(*) filter(where result='DENIED') into stats from public.gate_access_logs where created_at>=start_at and created_at<end_at;
 perform private.add_admin_notice('shift:'||end_at,'SHIFT','خلاصة نهاية الشفت '||label,stats,'logs');
 end if;
 end loop;end loop;
 delete from private.admin_notice_events where created_at<now()-interval '30 days';
 delete from private.guard_signins where created_at<now()-interval '90 days';
end;$$;
revoke all on function private.admin_notice_tick() from public,anon,authenticated;
create function public.admin_notice_feed() returns jsonb language plpgsql security definer set search_path=pg_catalog,private,public as $$
begin
 if not exists(select 1 from public.admin_profiles where auth_user_id=auth.uid() and is_active) then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED');end if;
 return jsonb_build_object('ok',true,'events',coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'title',e.title,'body',e.body,'topic',e.topic,'target',e.target,'created_at',e.created_at,'read',r.event_id is not null) order by e.created_at desc) from (select * from private.admin_notice_events where private.admin_notice_allowed(auth.uid(),topic) order by created_at desc limit 100) e left join private.admin_notice_reads r on r.event_id=e.id and r.admin_id=auth.uid()),'[]'::jsonb),'vapid_public',(select vapid_public from private.admin_notice_config));
end;$$;
revoke all on function public.admin_notice_feed() from public,anon;grant execute on function public.admin_notice_feed() to authenticated;
create function public.admin_notice_read(p_id uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog,private,public as $$
begin
 if not exists(select 1 from private.admin_notice_events where id=p_id and private.admin_notice_allowed(auth.uid(),topic)) then return jsonb_build_object('ok',false,'message','غير مصرح');end if;
 insert into private.admin_notice_reads(admin_id,event_id) values(auth.uid(),p_id) on conflict do nothing;return jsonb_build_object('ok',true);
end;$$;
revoke all on function public.admin_notice_read(uuid) from public,anon;grant execute on function public.admin_notice_read(uuid) to authenticated;
create function public.admin_notice_device(p_id uuid,p_label text,p_subscription jsonb,p_enabled boolean) returns jsonb language plpgsql security definer set search_path=pg_catalog,private,public as $$
begin
 if not exists(select 1 from public.admin_profiles where auth_user_id=auth.uid() and is_active) then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED');end if;
 if p_id is null or length(coalesce(p_label,''))>100 or p_enabled is null or (p_subscription is not null and (jsonb_typeof(p_subscription)<>'object' or length(p_subscription::text)>5000 or coalesce(p_subscription->>'endpoint','') !~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-zA-Z0-9-]+\.notify\.windows\.com)/' or coalesce(p_subscription#>>'{keys,p256dh}','') !~ '^[A-Za-z0-9_-]{80,100}$' or coalesce(p_subscription#>>'{keys,auth}','') !~ '^[A-Za-z0-9_-]{20,30}$')) then return jsonb_build_object('ok',false,'message','اشتراك الإشعارات غير صالح');end if;
 if (select count(*) from private.admin_notice_devices where admin_id=auth.uid())>=10 and not exists(select 1 from private.admin_notice_devices where admin_id=auth.uid() and device_id=p_id) then return jsonb_build_object('ok',false,'message','الحد عشرة أجهزة لكل مشرف؛ ألغِ جهازًا سابقًا');end if;
 insert into private.admin_notice_devices(admin_id,device_id,label,subscription,enabled) values(auth.uid(),p_id,coalesce(p_label,''),p_subscription,p_enabled) on conflict(admin_id,device_id) do update set label=excluded.label,subscription=excluded.subscription,enabled=excluded.enabled,last_seen_at=now();
 insert into public.admin_audit_logs(admin_auth_user_id,action,target_table,target_id,details) values(auth.uid(),'ADMIN_NOTICE_DEVICE','admin_notice_devices',p_id::text,jsonb_build_object('enabled',p_enabled));
 return jsonb_build_object('ok',true,'message','تم حفظ تفضيل إشعارات هذا الجهاز');
end;$$;
revoke all on function public.admin_notice_device(uuid,text,jsonb,boolean) from public,anon;grant execute on function public.admin_notice_device(uuid,text,jsonb,boolean) to authenticated;
create function public.admin_notice_claim(p_key text) returns jsonb language plpgsql security definer set search_path=pg_catalog,private,public,extensions as $$
declare jobs jsonb;
begin
 if p_key is null or length(p_key)<>64 or encode(extensions.digest(p_key,'sha256'),'hex') is distinct from (select dispatch_key_hash from private.admin_notice_config) then return jsonb_build_object('ok',false);end if;
 perform private.admin_notice_tick();
 with claim as (select o.id from private.admin_notice_outbox o join private.admin_notice_devices d on d.admin_id=o.admin_id and d.device_id=o.device_id join private.admin_notice_events e on e.id=o.event_id where o.sent_at is null and o.attempts<5 and o.available_at<=now() and d.enabled and d.subscription is not null and private.admin_notice_allowed(o.admin_id,e.topic) order by o.available_at limit 50 for update of o skip locked),updated as (update private.admin_notice_outbox o set attempts=attempts+1,available_at=now()+interval '5 minutes' from claim c where o.id=c.id returning o.*)
 select jsonb_agg(jsonb_build_object('id',o.id,'subscription',d.subscription,'title',e.title,'body',e.body,'event_id',e.id,'target',e.target)) into jobs from updated o join private.admin_notice_devices d on d.admin_id=o.admin_id and d.device_id=o.device_id join private.admin_notice_events e on e.id=o.event_id;
 return jsonb_build_object('ok',true,'jobs',coalesce(jobs,'[]'::jsonb),'vapid_public',(select vapid_public from private.admin_notice_config),'vapid_private',(select vapid_private from private.admin_notice_config));
end;$$;
revoke all on function public.admin_notice_claim(text) from public;grant execute on function public.admin_notice_claim(text) to anon,authenticated;
create function public.admin_notice_complete(p_key text,p_id uuid,p_status integer) returns jsonb language plpgsql security definer set search_path=pg_catalog,private,extensions as $$
begin
 if p_key is null or length(p_key)<>64 or encode(extensions.digest(p_key,'sha256'),'hex') is distinct from (select dispatch_key_hash from private.admin_notice_config) then return jsonb_build_object('ok',false);end if;
 update private.admin_notice_outbox set sent_at=case when p_status between 200 and 299 or p_status in (404,410) then now() else null end,last_error=case when p_status between 200 and 299 then null else p_status::text end where id=p_id;
 if p_status in (404,410) then update private.admin_notice_devices d set enabled=false,subscription=null from private.admin_notice_outbox o where o.id=p_id and d.admin_id=o.admin_id and d.device_id=o.device_id;end if;
 return jsonb_build_object('ok',true);
end;$$;
revoke all on function public.admin_notice_complete(text,uuid,integer) from public;grant execute on function public.admin_notice_complete(text,uuid,integer) to anon,authenticated;

alter table private.admin_notice_config add column dispatch_url text,add column publishable_key text;
create function private.admin_notice_dispatch() returns void language plpgsql security definer set search_path=pg_catalog,private as $$
declare cfg private.admin_notice_config%rowtype; credential text;
begin
 perform private.admin_notice_tick();
 select * into cfg from private.admin_notice_config;
 if cfg.dispatch_url is null or cfg.publishable_key is null then return;end if;
 select decrypted_secret into credential from vault.decrypted_secrets where name='admin_notice_dispatch_key';
 if credential is null then raise warning 'Notice dispatcher credential unavailable';return;end if;
 perform net.http_post(url:=cfg.dispatch_url,headers:=jsonb_build_object('Content-Type','application/json','apikey',cfg.publishable_key,'x-dispatch-key',credential),body:='{}'::jsonb,timeout_milliseconds:=60000);
end;$$;
revoke all on function private.admin_notice_dispatch() from public,anon,authenticated;
DO $$ BEGIN
 IF EXISTS(select 1 from pg_available_extensions where name='pg_cron') AND EXISTS(select 1 from pg_available_extensions where name='pg_net') THEN
 EXECUTE 'create extension if not exists pg_cron';EXECUTE 'create extension if not exists pg_net';
 PERFORM cron.schedule('admin-notice-dispatch','* * * * *','select private.admin_notice_dispatch()');
 END IF;
END $$;

-- Follow-up within the owner-approved Staging transition.
-- Only database-owned scheduled jobs may use the network extension.
DO $$ BEGIN
 IF EXISTS(select 1 from pg_namespace where nspname='net') THEN
 EXECUTE 'revoke usage on schema net from public,anon,authenticated';
 EXECUTE 'revoke execute on all functions in schema net from public,anon,authenticated';
 END IF;
END $$;
create function private.profile_change_notice_trigger() returns trigger language plpgsql security definer set search_path=pg_catalog,private,public as $$
begin
 if new.status='PENDING' then perform private.add_admin_notice('profile:'||new.id||':'||new.created_at,'PROFILE_CHANGE','طلب تعديل بيانات جديد','وصل طلب تعديل بيانات موظف للمراجعة.','profileChanges');end if;
 return new;
end;$$;
revoke all on function private.profile_change_notice_trigger() from public,anon,authenticated;
create trigger profile_change_request_notice after insert on public.employee_data_change_requests for each row execute function private.profile_change_notice_trigger();
create function public.guard_set_emergency(p_token text,p_enabled boolean) returns jsonb language plpgsql security definer set search_path=pg_catalog,private,public as $$
declare gid uuid:=private.guard_session_id(p_token);
begin
 if gid is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED');end if;
 if p_enabled is null then return jsonb_build_object('ok',false,'message','اختيار غير صالح');end if;
 perform 1 from private.guard_accounts where id=gid for share;
 if private.guard_session_id(p_token) is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED');end if;
 update private.guard_emergency_settings set enabled=p_enabled;
 insert into public.admin_audit_logs(action,target_table,target_id,details) values('GUARD_SET_EMERGENCY','guard_emergency_settings','true',jsonb_build_object('guard_id',gid,'enabled',p_enabled));
 return jsonb_build_object('ok',true,'emergency_enabled',p_enabled,'message',case when p_enabled then 'تم تفعيل الدخول اليدوي للطوارئ؛ كل زيارة تسجل وتحتسب' else 'تم إيقاف الدخول اليدوي للطوارئ' end);
end;$$;
revoke all on function public.guard_set_emergency(text,boolean) from public;grant execute on function public.guard_set_emergency(text,boolean) to anon,authenticated;
