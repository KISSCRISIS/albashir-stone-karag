-- ============================================================================
-- ALBASHIR Gate — Private Employee Photos Architecture
-- Migration: 20261006190000_private_employee_photos.sql
--
-- SCOPE
--   Phase 1  Storage boundary   : employee-photos bucket becomes private,
--                                 public read/upload policies are removed and
--                                 replaced by a constrained upload policy.
--   Phase 2  Backfill           : legacy public object URLs stored in
--                                 employee_registrations.employee_photo_url are
--                                 converted to object paths.
--   Phase 3  Access support     : read-only gate-device credential verification
--                                 used by the employee-photo-url resolver.
--   Phase 4  Cleanup support    : private.pending_employee_uploads ledger +
--                                 orphan sweep used to stop unlinked photo
--                                 accumulation.
--
-- NOT APPLIED BY THIS PR. PROJECT_RULES P1-12 / NEW-2 require explicit owner
-- review before this file is executed against Production. Nothing in this file
-- is executed automatically by the repository.
--
-- STAGING ROLLOUT ONLY (after explicit approval; target adwvokwucotohwayorgx):
--   1. fresh-install baseline -> STOP and verify DB/RPC/RLS/ACL
--   2. synthetic fixtures only
--   3. this migration -> STOP and verify Storage/RLS/verification RPCs
--   4. deploy employee-photo-url (requires RPCs created by this migration)
--   5. deploy frontend configured exclusively for Staging
--   6. execute all 17 acceptance checks; cleanup remains dry-run
-- Production rollout is NOT authorized. This single migration both creates
-- resolver dependencies and closes the bucket; no zero-downtime claim is made.
-- Do not deploy the new frontend before its backend dependencies exist.
--
-- ROLLBACK: supabase/rollback/20261006190000_private_employee_photos_rollback.sql
-- ============================================================================

-- ============================================================================
-- Phase 1 — Storage boundary
-- ============================================================================

-- Public bucket -> private bucket, with hard server-side limits.
-- file_size_limit 2 MiB, MIME allow-list limited to the formats the
-- registration UI accepts.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'employee-photos',
  'employee-photos',
  false,
  2097152,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Remove every public access path that exists today.
-- "Anyone can read employee photos"  : full read of every employee photo.
-- "Anyone can upload employee photos": unrestricted insert of any object.
drop policy if exists "Anyone can read employee photos" on storage.objects;
drop policy if exists "Anyone can upload employee photos" on storage.objects;

-- Constrained upload policy (mirrors the existing violation-photos pattern):
-- path shape + extension + MIME + size are all enforced by the database, so a
-- client cannot bypass the limits by hand-crafting a Storage request.
drop policy if exists "Registration can upload employee photos" on storage.objects;
create policy "Registration can upload employee photos"
on storage.objects
for insert
to anon, authenticated
with check (
  bucket_id = 'employee-photos'
  and (storage.foldername(name))[1] = 'registrations'
  and lower(storage.extension(name)) in ('jpg', 'jpeg', 'png', 'webp')
  and lower(coalesce(metadata ->> 'mimetype', '')) in ('image/jpeg', 'image/png', 'image/webp')
  and coalesce((metadata ->> 'size')::bigint, 0) between 1 and 2097152
);

-- No SELECT / UPDATE / DELETE policy is created for anon or authenticated.
-- Reading an employee photo is therefore impossible through the public API;
-- it is only possible through a short-lived signed URL minted by the
-- employee-photo-url resolver (service role).

-- ============================================================================
-- private schema — server-side only, never exposed through the Data API
-- ============================================================================
create schema if not exists private;

revoke all on schema private from public, anon, authenticated;
grant usage on schema private to service_role;

-- ============================================================================
-- Photo reference normalisation (single source of truth for path parsing)
-- ============================================================================
-- Accepts either a stored object path ("registrations/<id>/<file>.jpg") or a
-- legacy Storage URL (public or signed) and returns the object path.
-- Returns null when the value cannot be interpreted, so callers can refuse it.
create or replace function private.employee_photo_object_path(p_value text)
returns text
language sql
immutable
set search_path = private, public
as $$
  select case
    when v = '' then null
    when v like 'registrations/%' then v
    when v like '%/storage/v1/object/public/employee-photos/%'
      then nullif(split_part(v, '/storage/v1/object/public/employee-photos/', 2), '')
    when v like '%/storage/v1/object/sign/employee-photos/%'
      then nullif(split_part(split_part(v, '/storage/v1/object/sign/employee-photos/', 2), '?', 1), '')
    else null
  end
  from (select btrim(coalesce(p_value, '')) as v) s;
$$;

-- Same contract, but rejects anything that is not a well-formed photo path.
create or replace function private.is_valid_employee_photo_path(p_value text)
returns boolean
language sql
immutable
set search_path = private, public
as $$
  select p is not null
     and p ~ '^registrations/[A-Za-z0-9_-]{1,64}/[A-Za-z0-9._-]{1,120}$'
     and lower(split_part(p, '.', -1)) in ('jpg', 'jpeg', 'png', 'webp')
  from (select private.employee_photo_object_path(p_value) as p) s;
$$;

-- ============================================================================
-- Phase 2 — Backfill: public URL -> object path
-- ============================================================================
-- Only rows whose value is a parseable legacy Storage URL are rewritten.
-- Unparseable values are intentionally left untouched so the operator can
-- review them (see the review query at the end of this file).
update public.employee_registrations
set employee_photo_url = private.employee_photo_object_path(employee_photo_url)
where employee_photo_url is not null
  and employee_photo_url not like 'registrations/%'
  and private.employee_photo_object_path(employee_photo_url) is not null;

-- Operator feedback after the backfill. This never aborts the migration: a row
-- that cannot be interpreted is a review item, not a deployment failure.
do $$
declare
  legacy_count integer;
  unparseable_count integer;
begin
  select count(*) into legacy_count
  from public.employee_registrations
  where employee_photo_url like 'http%';

  select count(*) into unparseable_count
  from public.employee_registrations
  where coalesce(employee_photo_url, '') <> ''
    and private.employee_photo_object_path(employee_photo_url) is null;

  if legacy_count > 0 then
    raise warning 'employee-photos backfill: % row(s) still hold an http%% photo reference', legacy_count;
  end if;
  if unparseable_count > 0 then
    raise warning 'employee-photos backfill: % photo reference(s) need manual review', unparseable_count;
  end if;
end $$;

-- ============================================================================
-- Phase 4 — Pending / linked upload ledger
-- ============================================================================
-- One row per uploaded object path. The sweep uses it to tell three states
-- apart:
--   LINKED  : referenced by a registration -> never swept
--   PENDING : uploaded but not linked yet  -> swept after the retention window
--   ORPHAN  : marked for removal by a sweep run
create table if not exists private.pending_employee_uploads (
  object_path text primary key,
  employee_id text,
  registration_id uuid,
  status text not null default 'PENDING'
    check (status in ('PENDING', 'LINKED', 'ORPHAN')),
  created_at timestamptz not null default now(),
  linked_at timestamptz
);

create index if not exists idx_pending_employee_uploads_status_created
on private.pending_employee_uploads(status, created_at);

comment on table private.pending_employee_uploads is
  'Ledger of employee photo uploads used by the orphan sweep. Server-side only; no anon/authenticated access.';

-- Ledger entry is written by the frontend immediately after a successful
-- Storage upload, before the registration is submitted.
create or replace function public.register_pending_employee_upload(p_object_path text)
returns jsonb
language plpgsql
security definer
set search_path = private, public
as $$
declare
  clean_path text := btrim(coalesce(p_object_path, ''));
begin
  if private.is_valid_employee_photo_path(clean_path) = false then
    return jsonb_build_object('ok', false, 'message', 'مسار صورة غير صالح');
  end if;

  insert into private.pending_employee_uploads (object_path, status)
  values (clean_path, 'PENDING')
  on conflict (object_path) do nothing;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.register_pending_employee_upload(text) from public;
grant execute on function public.register_pending_employee_upload(text) to anon, authenticated, service_role;

-- A registration that references a path links the ledger entry, so a photo
-- belonging to a real (even still pending) registration is never swept.
create or replace function private.link_pending_employee_upload()
returns trigger
language plpgsql
security definer
set search_path = private, public
as $$
declare
  photo_path text := private.employee_photo_object_path(new.employee_photo_url);
begin
  if photo_path is null then
    return new;
  end if;

  insert into private.pending_employee_uploads
    (object_path, employee_id, registration_id, status, linked_at)
  values
    (photo_path, new.employee_id, new.id, 'LINKED', now())
  on conflict (object_path) do update
    set employee_id = excluded.employee_id,
        registration_id = excluded.registration_id,
        status = 'LINKED',
        linked_at = now();

  return new;
end;
$$;

drop trigger if exists trg_link_pending_employee_upload on public.employee_registrations;
create trigger trg_link_pending_employee_upload
after insert or update of employee_photo_url
on public.employee_registrations
for each row
execute function private.link_pending_employee_upload();

-- Sweep candidate selection.
-- This function NEVER deletes a Storage object: removing bytes requires the
-- Storage API, which is only reachable with the service role. The SQL side
-- selects and marks candidates; the employee-photo-url Edge Function performs
-- the physical removal and then confirms it back.
--
-- It is declared in `public` only because PostgREST exposes `public`; it is
-- revoked from PUBLIC/anon/authenticated and granted to service_role alone, so
-- it is not part of the client-facing API surface.
create or replace function public.employee_photo_sweep_candidates(
  p_retention_hours integer default 24,
  p_limit integer default 200,
  p_dry_run boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = private, public, storage
as $$
declare
  candidate_paths text[];
  candidate_count integer := 0;
begin
  if p_retention_hours is null or p_retention_hours < 1 then
    raise exception 'p_retention_hours must be >= 1';
  end if;

  with candidates as (
    select o.name as object_path
    from storage.objects o
    where o.bucket_id = 'employee-photos'
      and o.created_at < now() - make_interval(hours => p_retention_hours)
      and not exists (
        select 1
        from private.pending_employee_uploads p
        where p.object_path = o.name
          and p.status in ('LINKED', 'ORPHAN')
      )
      and not exists (
        select 1
        from public.employee_registrations r
        where private.employee_photo_object_path(r.employee_photo_url) = o.name
      )
    order by o.created_at asc
    limit greatest(1, least(coalesce(p_limit, 200), 500))
  )
  select coalesce(array_agg(object_path), '{}'::text[])
  into candidate_paths
  from candidates;

  candidate_count := coalesce(array_length(candidate_paths, 1), 0);

  if p_dry_run then
    return jsonb_build_object(
      'ok', true,
      'mode', 'DRY_RUN',
      'retention_hours', p_retention_hours,
      'candidate_count', candidate_count,
      'paths', to_jsonb(candidate_paths)
    );
  end if;

  update private.pending_employee_uploads
  set status = 'ORPHAN'
  where object_path = any(candidate_paths)
    and status <> 'LINKED';

  return jsonb_build_object(
    'ok', true,
    'mode', 'MARKED',
    'retention_hours', p_retention_hours,
    'candidate_count', candidate_count,
    'paths', to_jsonb(candidate_paths)
  );
end;
$$;

-- Called by the resolver after Storage confirms the bytes are gone.
create or replace function public.employee_photo_confirm_removal(p_paths text[])
returns integer
language plpgsql
security definer
set search_path = private, public
as $$
declare
  deleted_count integer := 0;
begin
  delete from private.pending_employee_uploads
  where object_path = any(coalesce(p_paths, '{}'::text[]))
    and status <> 'LINKED';

  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;

revoke all on function public.employee_photo_sweep_candidates(integer, integer, boolean) from public, anon, authenticated;
revoke all on function public.employee_photo_confirm_removal(text[]) from public, anon, authenticated;
grant execute on function public.employee_photo_sweep_candidates(integer, integer, boolean) to service_role;
grant execute on function public.employee_photo_confirm_removal(text[]) to service_role;

-- ============================================================================
-- Phase 3 — Read-only gate-device verification for the resolver
-- ============================================================================
-- Same checks as get_guard_employee_result(text, text, text) but without any
-- write other than the existing auth-failure audit entry, so the resolver can
-- authenticate a guard screen before signing a photo URL.
create or replace function public.verify_gate_device_credentials(
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
  gate public.gate_devices%rowtype;
  token_ok boolean := false;
begin
  if clean_device_code = '' or clean_token = '' then
    return jsonb_build_object('ok', false, 'reason', 'MISSING_CREDENTIALS');
  end if;

  select * into gate
  from public.gate_devices
  where device_code = clean_device_code
  limit 1;

  if gate.id is null or coalesce(gate.is_active, false) = false then
    perform public.log_gate_auth_failure(clean_device_code, 'verify_gate_device_credentials: device not approved');
    return jsonb_build_object('ok', false, 'reason', 'DEVICE_NOT_APPROVED');
  end if;

  select exists (
    select 1
    from public.offline_device_tokens
    where gate_device_id = gate.id
      and device_code = clean_device_code
      and token_hash = public.hash_offline_device_token(clean_token)
      and is_active = true
      and revoked_at is null
  )
  into token_ok;

  if token_ok = false then
    perform public.log_gate_auth_failure(clean_device_code, 'verify_gate_device_credentials: invalid token');
    return jsonb_build_object('ok', false, 'reason', 'INVALID_DEVICE_TOKEN');
  end if;

  return jsonb_build_object(
    'ok', true,
    'gate_device_id', gate.id,
    'device_code', clean_device_code
  );
end;
$$;

-- Service-role only: the resolver is the only intended caller.
revoke all on function public.verify_gate_device_credentials(text, text) from public, anon, authenticated;
grant execute on function public.verify_gate_device_credentials(text, text) to service_role;

-- Read-only counterpart of trusted_device_profile_login(p_device_token):
-- same token hash + APPROVED + trusted_device_enabled checks, but it performs
-- no write and no audit insert. Resolving a photo must not look like a login,
-- and it must not flood admin_audit_logs with FAST_LOGIN entries.
create or replace function public.verify_trusted_device_credentials(p_device_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_token text := trim(coalesce(p_device_token, ''));
  reg record;
begin
  if length(clean_token) < 40 then
    return jsonb_build_object('ok', false, 'reason', 'INVALID_DEVICE_TOKEN');
  end if;

  select employee_id
  into reg
  from public.employee_registrations
  where trusted_device_enabled = true
    and trusted_device_token_hash = public.hash_trusted_device_token(clean_token)
    and status = 'APPROVED'
  limit 1;

  if reg.employee_id is null then
    return jsonb_build_object('ok', false, 'reason', 'DEVICE_NOT_TRUSTED');
  end if;

  return jsonb_build_object('ok', true, 'employee_id', reg.employee_id);
end;
$$;

revoke all on function public.verify_trusted_device_credentials(text) from public, anon, authenticated;
grant execute on function public.verify_trusted_device_credentials(text) to service_role;

-- ============================================================================
-- OPERATOR REVIEW QUERIES (run manually, read-only)
-- ============================================================================
-- 0) REQUIRED POST-APPLY CHECK — no legacy link may survive (must return 0):
--    select count(*) from public.employee_registrations
--    where employee_photo_url like 'http%';
--    Any non-zero result means the backfill could not interpret the value
--    (different host or bucket); each such row must be reviewed by hand before
--    the private boundary is trusted.

-- ============================================================================
-- 1) How many rows still hold an unparseable photo reference?
--    select count(*) from public.employee_registrations
--    where employee_photo_url is not null
--      and private.employee_photo_object_path(employee_photo_url) is null;
--
-- 2) Dry-run the orphan sweep before enabling anything destructive:
--    select public.employee_photo_sweep_candidates(24, 200, true);
--
-- 3) Objects currently in the bucket:
--    select name, created_at from storage.objects
--    where bucket_id = 'employee-photos' order by created_at desc limit 50;
-- ============================================================================
