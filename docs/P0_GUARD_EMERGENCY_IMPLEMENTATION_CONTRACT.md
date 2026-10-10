# P0 — Guard emergency hardening | implementation contract
Date: 2026-10-10
Status: PREPARATION ONLY — no migration or deployment authorized.

## Approved operating workflow
- One active guard QR phone normally, two at most.
- QR remains public and does not require guard sign-in.
- When QR *generation* fails on a particular guard phone, the authenticated guard may immediately use manual entry on that phone, without checking another phone.
- Guard asks employee for **employee number only**, enters it into the protected manual form; no employee phone, national ID or employee handset is needed.
- Existing server decision rules (registration, approved status, specialty, daily limits) apply; result and authorized employee photo appear for ten seconds. Count permitted visits once; never fabricate an ALLOWED decision when server is unreachable.
- Emergency access ends automatically on QR generator recovery on that same phone.
- Temporary shared guard login remains operational. Personal guard registration stays optional for now.
- Do not change Production.

## Verified baseline
- Source branch: fix/admin-account-and-photo-readiness @ 2d001b56105237869f7c7cb426f291e78c5654e5.
- Staging Supabase: adwvokwucotohwayorgx.
- Live functions: guard_manual_employee_entry, guard_set_emergency, create_public_guard_qr, manual_employee_check.
- Live manual_employee_check definition MD5: f0e750e4abb2bf97f20999264684341f.
- guard_manual_employee_entry checks emergency_enabled, but does not prove QR generator failure.
- Database session timezone is UTC; operational shifts are Asia/Amman. Do not silently alter quota-day semantics.
- Existing guard manual request_id is idempotent, but shared account is not a reliable individual attribution.
- Existing public QR is opaque, server-generated and short-lived.

## P0-01: Server-authoritative station-specific QR outage
1. Design private guard-station identity (up to two devices) with unguessable revocable credential, server-stored hash, rotation, expiry and admin audit; public QR remains unauthenticated for human guards but result-read access must be station-scoped. Never trust a client-supplied device ID or client error flag as proof.
2. Add narrowly scoped server health/outage state. Define precisely what counts as *generator failure*, which failures are observable by server, and which require an explicit administrator override. A successful generation/recovery invalidates emergency eligibility on that station.
3. Require the guard session, bound station credential, recent proven outage and a short-lived emergency lease *inside guard_manual_employee_entry*; validate on every request and fail closed when unprovable.
4. Maintain the approved one-phone behavior: no second-phone prerequisite. Do not unlock manual for mere polling failures or WAN loss.
5. Preserve server-side employee lookup by employee number, existing decision rules, photo privacy and ten-second display.
6. Tests: healthy QR denies manual; failed QR enables only affected station; other station denied; recovery revokes; forged failure denied; expired lease denied; missing credential denied; replay and concurrent calls denied or idempotent; no server means no ALLOWED.

## P0-02: Guard authentication and accountability
- Preserve shared login temporarily, as owner explicitly approved. Do not silently mandate personal accounts.
- Clearly distinguish shared-account attribution from individual attribution; audit station, session, request ID, timestamp and authorization origin without exposing national ID, phone, photo or token.
- Prepare a phased migration to stronger individual authentication for sensitive actions; owner must approve any change to shared-account permissions.

## P0-03: Atomic daily quotas
- Inspect the live employee decision function and all paths writing gate_access_logs before changes.
- Choose a per-employee + operational-day transactional lock/counter, with request-level idempotency across both QR and manual paths.
- Obtain owner decision on calendar day (Asia/Amman midnight) versus shift-day before changing behavior.
- Test concurrent last-slot claims, retries, denial, and multi-station requests with synthetic data.

## P0-04: Authorization audit
- Enumerate live RPC signatures, EXECUTE grants, SECURITY DEFINER search paths, RLS policies, storage/photo access and frontend anonymous endpoints.
- Test anonymous, authenticated non-admin, guard and super-admin allow/deny cases. Do not revoke permissions in bulk.
- Verify deployed Staging SQL hashes, frontend deployment and migrations against source branch before any apply.

## Release gates
- First deliver a diff, isolated test results, explicit risks and rollback script.
- Do not run a Staging SQL migration or publish Staging without separate owner approval after review.
- Never change Production without explicit owner authorization.
