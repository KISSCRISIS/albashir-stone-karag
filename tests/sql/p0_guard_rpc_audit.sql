-- Read-only P0 guard RPC inventory for Staging review.
select p.proname, pg_get_function_identity_arguments(p.oid) as arguments,
       md5(pg_get_functiondef(p.oid)) as definition_md5,
       p.prosecdef as security_definer,
       p.proconfig as settings,
       has_function_privilege('anon',p.oid,'EXECUTE') as anon_execute,
       has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_execute
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in
 ('guard_manual_employee_entry','guard_set_emergency','manual_employee_check',
  'guard_login','guard_session_status','create_public_guard_qr')
order by p.proname;
