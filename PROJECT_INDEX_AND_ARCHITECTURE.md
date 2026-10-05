# ALBASHIR Gate - Project Index & Architecture

## 1. Overview
Unified access control system for administration, guard devices, and employees.

Main flows:
- Employee registration and approval.
- Guard QR generation and validation.
- Trusted device automatic verification.
- Admin approval and auditing.
- Offline gate support.

## 2. Main Components

```
Employee Portal
    |
    v
employee_registrations
    |
    +--> trusted_device
    |
    +--> gate_access_logs

Guard Device
    |
    v
gate_devices
    |
    +--> qr_sessions
    |
    +--> offline_device_tokens

Admin Dashboard
    |
    +--> approvals
    +--> permissions
    +--> audit logs
```

## 3. SQL Patch Execution Order

For a brand-new Supabase project, run `schema_consolidated_fresh_install.sql`
instead of applying the files below one by one — it concatenates all of them
in this exact order, with its own header explaining why this order and not
one of the other orders previously listed in this repo's docs. It is NOT for
the existing Production project (see `PRODUCTION_MIGRATION_MAPPING.md`).

1. schema.sql
2. schema_patch_pgcrypto_schema_fix.sql
3. schema_patch_permanent_specialty.sql
4. schema_patch_auto_verify.sql
5. schema_patch_offline_gate_mode.sql
6. schema_patch_verify_employee_profile.sql
7. schema_patch_employee_profiles.sql
8. schema_patch_trusted_device_registration_flow.sql
9. schema_patch_trusted_device_metadata.sql
10. schema_patch_production_hardening.sql
11. schema_patch_gate_qr_device_auth.sql
12. schema_patch_guard_screen_reset_auth.sql
13. schema_patch_registration_category_split.sql (layer 13: adds registration_category + affiliated_entity and the 15-argument registration overload; Production migration 20261005092112 registration_category_split — APPLIED AND VERIFIED)

`schema_patch_guard_device_admin_control.sql` is intentionally excluded —
its own header marks it deprecated/non-canonical
(see `PRODUCTION_RPC_CANONICAL_MAP.md`); `admin_approve_gate_device` from
`schema_patch_offline_gate_mode.sql` is the canonical guard-approval API.

Migration dependencies:

- Run `schema_patch_pgcrypto_schema_fix.sql` second, right after `schema.sql`.
  It is a fix for pgcrypto landing in the wrong Postgres schema; `create
  extension if not exists` cannot relocate an already-installed extension, so
  it must run before `schema.sql`'s and `schema_patch_auto_verify.sql`'s own
  unqualified `create extension if not exists "pgcrypto"` calls would
  otherwise make the fix a no-op on a fresh database.
- `schema_patch_verify_employee_profile.sql` must run after `schema.sql`,
  `schema_patch_permanent_specialty.sql`, `schema_patch_auto_verify.sql` and
  `schema_patch_offline_gate_mode.sql` (stated in its own header).
- `schema_patch_employee_profiles.sql` must run after
  `schema_patch_verify_employee_profile.sql` (stated in its own header).
- Include `schema_patch_trusted_device_registration_flow.sql` because it provides the employee trusted-device registration, approval, and pending-to-trusted promotion flow.
- `schema_patch_production_hardening.sql` must run after the trusted-device
  patches (not before, despite one earlier doc suggesting otherwise) — it
  references `trusted_device_token_hash`, `trusted_device_enabled` and
  `register_trusted_device`, all introduced by
  `schema_patch_trusted_device_registration_flow.sql` /
  `schema_patch_trusted_device_metadata.sql`. Its own header also says to run
  it last, after every other patch.
- Run `schema_patch_gate_qr_device_auth.sql` before the guard-screen reset layer because it overrides the QR runtime with `create_qr_session(device_code, device_token)` and replaces the unsecured QR-generation flow with trusted guard-device authentication.
- Run `schema_patch_guard_screen_reset_auth.sql` after the QR device-auth layer (it uses `hash_offline_device_token()` and `offline_device_tokens` from that layer).
- Run `schema_patch_registration_category_split.sql` last as layer 13 because it adds `registration_category` + `affiliated_entity` and the 15-argument registration overload on top of the 13-argument Trusted Device flow. Production migration 20261005092112 registration_category_split — APPLIED AND VERIFIED. Database Production state: 15-arg overload exists and is confirmed (0 defaults); 8-arg legacy compatibility and 13-arg preserved compatibility overloads retained (13-arg is no longer the deployed frontend path). Frontend deployment state: the split register.html / admin_dashboard.html are DEPLOYED to Production (commit 76608c3), registration UI smoke tests passed, and admin authenticated live-row rendering test is COMPLETE and PASSED on Production as SUPER_ADMIN (نوع التسجيل visible, legacy NULL renders غير مصنف (سجل سابق), الجهة التابعة visible, NULL renders -, no approve/reject performed). In `schema_consolidated_fresh_install.sql`, Layer 13 is present and the final Verification Block runs after Layer 13 (it also checks the two new columns, the CHECK constraint, the 15-arg overload with 0 defaults, and that the 13-arg overload still exists).

## 4. Critical Tables

### employee_registrations
Stores employee identity, approval status, profile, and trusted device data.

### gate_devices
Stores guard terminals and activation state.

Important fields:
- device_code
- is_active
- last_seen_at
- last_qr_at

### qr_sessions
Controls QR lifetime and usage.

### gate_access_logs
Complete access history.

### admin_audit_logs
Administrative tracking.

## 5. Trusted Device Flow

```
Employee registers
        |
Device token saved as pending
        |
Admin approves employee
        |
Trusted device activated automatically
        |
Future QR scans use device verification
```

## 6. Guard Device Flow

```
Guard opens screen
        |
Heartbeat sent
        |
gate_devices checked
        |
Device approved?
        |
QR session created
```

If inactive:

```
جهاز الحارس بانتظار اعتماد الإدارة
```

## 7. Access Decision Logic

Priority:

1. Employee status
2. Trusted device validity
3. QR validity
4. Permanent specialties
5. Daily specialty limits

## 8. Troubleshooting

### QR cannot generate
Check:
- gate_devices.is_active
- offline_device_tokens
- device token validity

### Employee cannot auto login
Check:
- trusted_device_enabled
- trusted_device_token_hash
- employee status APPROVED

### Device pending approval
Activate the device from admin workflow.

## 9. Production Notes

- Do not rerun schema.sql on a live database.
- Apply patches in order.
- Keep audit logs enabled.
- Reload Supabase schema after RPC changes.

## 10. Current Architecture Status

Database layer: Ready
Trusted device layer: Ready
Offline gate layer: Ready
Employee profile layer: Ready
Production hardening: Applied
