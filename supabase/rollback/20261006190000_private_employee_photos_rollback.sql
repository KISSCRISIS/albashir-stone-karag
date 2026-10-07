-- ============================================================================
-- ALBASHIR Gate — ROLLBACK for 20261006190000_private_employee_photos.sql
--
-- This file is MANUAL. It lives outside supabase/migrations/ on purpose so it
-- is never picked up by a forward `supabase db push`. Run it only with explicit
-- owner approval, and only after the frontend has been rolled back to a build
-- that reads public photo URLs.
--
-- WHAT IT RESTORES
--   1. employee-photos bucket -> public
--   2. legacy read/upload policies -> restored, constrained policy -> removed
--   3. photo references        -> optional path -> public URL rewrite
--   4. private schema objects  -> ledger, trigger and sweep helpers removed
--   5. verify_gate_device_credentials -> removed
--
-- WHAT IT DOES NOT RESTORE
--   - Objects already removed by the orphan sweep. Removal is irreversible.
--   - employee_registrations rows that were deleted after this migration.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1 + 2 — Storage boundary
-- ---------------------------------------------------------------------------
update storage.buckets
set public = true,
    file_size_limit = null,
    allowed_mime_types = null
where id = 'employee-photos';

drop policy if exists "Registration can upload employee photos" on storage.objects;

drop policy if exists "Anyone can read employee photos" on storage.objects;
create policy "Anyone can read employee photos"
on storage.objects
for select
to anon, authenticated
using (bucket_id = 'employee-photos');

drop policy if exists "Anyone can upload employee photos" on storage.objects;
create policy "Anyone can upload employee photos"
on storage.objects
for insert
to anon, authenticated
with check (bucket_id = 'employee-photos');

-- ---------------------------------------------------------------------------
-- 3 — OPTIONAL data rollback: object path -> public URL
-- Uncomment only if the frontend is being rolled back to public URLs.
-- Replace the project reference if Production changes.
-- ---------------------------------------------------------------------------
-- update public.employee_registrations
-- set employee_photo_url =
--   'https://qinsfvlspdticposbvst.supabase.co/storage/v1/object/public/employee-photos/'
--   || employee_photo_url
-- where employee_photo_url like 'registrations/%';

-- ---------------------------------------------------------------------------
-- 4 — private schema objects
-- ---------------------------------------------------------------------------
drop trigger if exists trg_link_pending_employee_upload on public.employee_registrations;
drop function if exists private.link_pending_employee_upload();
drop function if exists public.register_pending_employee_upload(text);
drop function if exists public.employee_photo_confirm_removal(text[]);
drop function if exists public.employee_photo_sweep_candidates(integer, integer, boolean);
drop table if exists private.pending_employee_uploads;
drop function if exists private.is_valid_employee_photo_path(text);
drop function if exists private.employee_photo_object_path(text);

-- ---------------------------------------------------------------------------
-- 5 — Resolver device verification
-- ---------------------------------------------------------------------------
drop function if exists public.verify_gate_device_credentials(text, text);
drop function if exists public.verify_trusted_device_credentials(text);

-- The `private` schema itself is left in place on purpose: dropping a schema
-- that may already hold operator data is more dangerous than leaving it empty.
-- Drop it manually only after confirming it is unused:
--   drop schema if exists private;
