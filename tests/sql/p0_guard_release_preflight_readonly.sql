-- Read-only Staging preflight: inspect constraints and current function signatures.
-- This does not prove concurrency correctness; a transactional two-client test is required.
select n.nspname as schema_name,p.proname as function_name,
       pg_get_function_identity_arguments(p.oid) as args,
       p.prosecdef as security_definer
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in
('manual_employee_check','create_public_guard_qr','guard_manual_employee_entry',
 'guard_session_status','guard_set_emergency')
order by p.proname;

select conrelid::regclass::text as table_name, conname, pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid in ('private.guard_manual_entries'::regclass,
                    'private.guard_sessions'::regclass,
                    'public.gate_access_logs'::regclass)
order by conrelid::regclass::text,conname;

select count(*) as unexpired_qr_sessions
from private.public_guard_sessions where expires_at>now();

-- Regression acceptance plan (execute only in an isolated Staging fixture):
-- 1. Two separate transactions contend for final specialty quota slot.
-- 2. Only one obtains LIMITED; the other obtains DENIED.
-- 3. Replayed guard request_id yields stored result without a second log.
-- 4. Healthy QR generation denies emergency entry regardless of UI flags.
-- 5. An outage at station A never authorizes station B.
-- 6. Successful QR generation revokes station A's outage authorization.
-- 7. A revoked guard, expired station, and backend outage each fail closed.
