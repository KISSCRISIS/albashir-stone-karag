ALBASHIR Gate — Production Migration Mapping
Status: Documentation-only mapping
Audit date: 2026-10-05
Guard-screen reset confirmation: 2026-10-05
QR cleanup Cron confirmation: 2026-10-05
Production project: ALBASHIR-Gate-Production2026
Scope and source-of-truth statement
This document maps the current Supabase Production state to the repository SQL patch files. It does not apply SQL, create migrations, change database functions, change permissions, or delete legacy overloads.
The current Supabase Production state is the source of truth. Repository SQL files describe intended or historical implementation, but they do not prove that a complete patch file was applied in Production.

Confirmed Production capabilities
Capability	Production evidence	Related repository SQL files	Recorded Supabase migrations that are identifiable	Confidence
Trusted Device registration	public.employee_registrations exists with trusted_device_enabled, trusted_device_token_hash, pending Trusted Device hash/ID/type/name/user-agent/timestamp fields. Production exposes the 13-argument register_employee_request overload and it contains the pending-device flow.	schema_patch_trusted_device_registration_flow.sql; schema_patch_trusted_device_metadata.sql; schema_patch_auto_verify.sql; schema_patch_production_hardening.sql	No single migration name maps unambiguously to the complete registration patch. add_qr_employee_identity_access_details is related to employee access details, but is not proof of the full Trusted Device patch.	High for capability; Low for file-to-migration identity
Employee approval	Production exposes admin_update_registration_status(uuid, text) as a SECURITY DEFINER function. Its definition checks is_super_admin() or has_admin_permission, updates approval state, promotes pending Trusted Device fields, enables the trusted device, and clears pending fields. admin_profiles and admin_audit_logs also exist.	schema.sql; schema_patch_trusted_device_registration_flow.sql; schema_patch_production_hardening.sql	No direct migration record can be conclusively mapped to the complete employee approval implementation.	High for capability; Low for file-to-migration identity
Guard device approval	Production has gate_devices and admin_approve_gate_device(text, boolean). The function is SECURITY DEFINER, requires the admin path, changes is_active, and records approval activity.	schema_patch_offline_gate_mode.sql; schema_patch_guard_device_admin_control.sql; schema_patch_production_hardening.sql	20260930004838_update_upsert_gate_device_heartbeat_require_admin_approval is directly related to the gate-device approval/registration hardening area, but does not prove every guard-device patch file was applied.	High for capability; Medium for migration identity
Offline device authentication	gate_devices, offline_device_tokens, and gate_sync_status exist. Production contains device-token hashes, active/revoked state, heartbeat fields, and token validation in the QR/heartbeat paths.	schema_patch_offline_gate_mode.sql; schema_patch_pgcrypto_schema_fix.sql; schema_patch_gate_qr_device_auth.sql	20260928214412_enable_pgcrypto_for_qr_device_hash; 20260928214426_refresh_create_qr_session_token_hash; and 20260930004838_update_upsert_gate_device_heartbeat_require_admin_approval are functionally related. The exact file-to-migration mapping is not recorded.	High for capability; Medium for migration identity
Secure QR creation	Production has the two-argument create_qr_session(p_device_code text, p_device_token text) overload. Its definition checks active gate state and the non-revoked device-token hash, creates a QR session with a 30-second expiry, and updates gate/token usage timestamps. qr_sessions exists.	schema_patch_gate_qr_device_auth.sql; schema_patch_offline_gate_mode.sql; schema_patch_pgcrypto_schema_fix.sql; schema_patch_production_hardening.sql	The following recorded migrations are directly related to the QR/device-auth area: 20260928214252_fix_create_qr_session_device_token_signature; 20260928214412_enable_pgcrypto_for_qr_device_hash; 20260928214426_refresh_create_qr_session_token_hash; 20260928215050_fix_qr_session_digest_schema; 20260928215241_fix_qr_session_wrapper_hash_logic. They still do not prove that a named repository patch was executed as a whole.	High for capability; High for functional relationship, not exact file identity
Authenticated guard-screen reset	reset_guard_screen(text, text) is applied and confirmed in Production as a SECURITY DEFINER function, callable by anon and authenticated.	schema_patch_guard_screen_reset_auth.sql	20261005075552_add_authenticated_guard_screen_reset	High for capability and migration identity
Scheduled QR cleanup	public.cleanup_expired_qr_sessions() exists in Production and Supabase Cron job cleanup-expired-qr-sessions is active with schedule */15 * * * *, executing select public.cleanup_expired_qr_sessions();.	schema_patch_production_hardening.sql; schema_consolidated_fresh_install.sql documents the optional 15-minute schedule	20261005080323_schedule_expired_qr_cleanup	High for capability and migration identity
Auto employee check	Production exposes auto_employee_check(p_device_token text, p_qr_token text). Its definition checks the employee approval state, Trusted Device state, receives the QR token, calls the central manual check, and returns the access decision.	schema_patch_auto_verify.sql; schema_patch_verify_employee_profile.sql; schema_patch_trusted_device_registration_flow.sql; schema_patch_production_hardening.sql	20260929073218_add_qr_employee_identity_access_details is related to employee identity/access result details. No recorded migration unambiguously represents the complete auto-check implementation.	High for capability; Low/Medium for migration identity


Current employee/profile architecture
employee_profiles does not exist
Production metadata confirms that public.employee_profiles is absent. The current application architecture does not require that table.
The employee base table is:
public.employee_registrations
The repository's schema_patch_employee_profiles.sql does not create employee_profiles. Instead, it:
- adds vehicle fields to employee_registrations;
- creates employee_data_change_requests;
- defines employee_profile_login against employee_registrations;
- defines employee data-change request/review functions.
Production contains employee_data_change_requests, and the employee/profile functions use employee_registrations. Therefore, the word “profile” describes the application/profile capability, not a separate employee_profiles table.
Legacy RPC overloads
Production still contains legacy overloads:
create_qr_session()
create_qr_session(p_device_token text)
register_employee_request(8 arguments)
Production-confirmed database RPC state:
create_qr_session(p_device_code text, p_device_token text)

register_employee_request overloads currently present in Production:
- 8 arguments: legacy compatibility overload
- 13 arguments: preserved compatibility overload and still compatible with the currently deployed pre-split frontend
- 15 arguments: new Production-confirmed registration-category overload (0 defaults), intended for the updated register.html after frontend deployment
The 8-arg and 13-arg overloads are intentionally retained. No cleanup/removal should occur until the updated frontend is deployed and all external consumers/test tooling are confirmed to use the intended signatures.
Registration category split migration (APPLIED in Production):
Production migration:
20261005092112 registration_category_split
Adds registration_category + affiliated_entity to employee_registrations and a 15-argument register_employee_request overload (PERMANENT / TEMPORARY).
Status:
APPLIED AND VERIFIED
Verified Production state:
- registration_category exists and is nullable
- affiliated_entity exists and is nullable
- specialty remains NOT NULL (preserved)
- chk_employee_registrations_registration_category CHECK constraint confirmed
- register_employee_request 8-arg overload preserved
- register_employee_request 13-arg overload preserved
- register_employee_request 15-arg overload present
- 15-arg overload has 0 defaults
- anon/authenticated EXECUTE confirmed
- old rows were NOT backfilled
Note: schema_patch_registration_category_split.sql is now a historical/reference repository migration. Do NOT re-run it blindly against Production. Any future change must be a new narrowly scoped migration.
Recorded Supabase migration history
The following migrations are actually recorded in Supabase Production:
Version	Recorded name
20260928214252	fix_create_qr_session_device_token_signature
20260928214412	enable_pgcrypto_for_qr_device_hash
20260928214426	refresh_create_qr_session_token_hash
20260928215050	fix_qr_session_digest_schema
20260928215241	fix_qr_session_wrapper_hash_logic
20260929073218	add_qr_employee_identity_access_details
20260930004838	update_upsert_gate_device_heartbeat_require_admin_approval
20261005075552	add_authenticated_guard_screen_reset
20261005080323	schedule_expired_qr_cleanup
20261005092112	registration_category_split


Confirmed scheduled maintenance
Production currently has the following active Supabase Cron job:
Job name: cleanup-expired-qr-sessions
Schedule: */15 * * * *
Command: select public.cleanup_expired_qr_sessions();
Active: true
This job automatically removes expired QR sessions on a 15-minute schedule.
No recorded migration name exactly matches the repository filenames schema_patch_*.sql. The relationship table above is therefore a capability/function mapping, not a claim that the corresponding repository file was executed as a complete unit.
Migration and repository safeguards
Do not create supabase/migrations yet
No new supabase/migrations folder should be created at this stage.
Creating one before reconciling the recorded migration history with the live Production definitions could:
- reapply already-effective DDL;
- replace newer Production function bodies with older repository copies;
- create duplicate or conflicting overloads;
- change grants or RLS behavior unintentionally;
- make rollback and ownership of the source of truth unclear.
A future migration folder should only be introduced after a separate, approved reconciliation process identifies the exact live baseline and converts only verified deltas into new migrations.
What this document does not prove
This mapping does not prove:
- the exact historical order in which repository patch files were run;
- that every statement in any patch file was applied;
- that the migration names correspond one-to-one to repository files;
- that no external client calls a legacy RPC overload;
- that PostgREST schema cache history matches every repository revision.
Final statement
Production Supabase is the authoritative source of truth for the current database state. This document records the confirmed relationship between that state and the repository patches without changing either the database or the migration system.
