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
