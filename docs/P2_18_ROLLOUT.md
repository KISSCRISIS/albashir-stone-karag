# Final Staging candidate and Production rollout

Owner approved the Production rollout on 2026-10-08 after confirming phone photo and home-screen shortcut acceptance. Existing device bindings must be preserved (explicit owner decision); do not run the historical reset statements.

The reviewed executable transition is `supabase/rollout/production_preserve_existing_devices.sql`. It takes a table lock, snapshots every employee row, introduces the reviewed definitions, derives fingerprint hashes from the already-stored device IDs, and asserts that every previous field (including token hash, device ID, enabled state, revocation, identity and status) is unchanged. Missing device IDs cause an atomic abort. It applies final indefinite approval, claim, public guard, taxonomy and bounded QR retry definitions without intermediate commits. Production currently has two eligible bound devices. Old reset/re-enrollment migrations remain historical Staging records and are not the Production transition.

QR completed-response retries are limited to 30 seconds. Payload hashes use JSON arrays to avoid separator ambiguity. The isolated preserving-transition test proves original credentials still work and a changed device ID is denied. The combined candidate includes the existing Production ACL restrictions, disabled violation UI and explicit Add Admin button; these must not be lost when merging the stacked QR PRs. Full isolated test count is 29, plus hosted Chromium/WebKit first-manual-to-next-automatic/photo-retry acceptance.

## Current owner policy
Administrator approval activates the device submitted with registration. It stays trusted until administrative revocation, subject to employee approval, device enablement and fingerprint checks. Additional QR enrollment is not required for that registration device. Mandatory QR remains required for gate access.
The separate public guard display opens via a direct distributed link only. Removing application navigation is presentation policy, not security. Backend capability checks and private photos remain unchanged.

## Verification
- All 18 isolated regression suites PASS.
- Staging live Chromium/WebKit tests: own employee photo, guard photo, automatic QR verification, result replacing QR panel, 10-second clearing, countdown and responsive widths PASS.
- Owner confirmed phone QR access and both-party result; owner confirmed 10-second clearing.
- Latest-build real iPhone photo confirmation remains REQUIRED: the earlier phone screenshot showed a missing photo. WebKit did not reproduce it. Photo authorization now uses the successful verification actor rather than an unrelated stored token; cache v18 retires older assets.
- New registration -> administrator approval -> same-phone fast login acceptance remains required for final device policy.
- No production requests in the browser test; no Backend/Auth changes in the latest frontend commit.

## Approved-candidate order (requires final Production approval)
Use a coordinated maintenance window; incompatible legacy callers require operations to pause during backend/frontend transition. Owner handles operator notification.
1. Compare live Production definitions/ACLs with reviewed baselines. Stop on divergence. Preserve existing trusted-device tokens using the reviewed transition above; the owner declined invalidation.
2. The following historical definitions are included by the preserving transition, except reset/re-enrollment data statements. Execute the preserving transition, not these historical files individually:
   - 20261007094821_p2_18_trusted_device_binding_ttl.sql
   - 20261007095927_p2_18_reenroll_keep_eligibility.sql
   - 20261007101501_p2_18_enrollment_claim_acl_hardening.sql
   - 20261007112137_admin_approval_activates_submitted_device.sql
   - 20261007113049_trusted_device_admin_revocation_only.sql
   - 20261007114535_public_guard_session_rpc.sql
   - 20261007121511_public_guard_auto_result_sync.sql
   Do not expose intermediate policy versions. Do not reapply historical patches or perform a broad db push.
3. Deploy the reviewed photo Resolver supporting device_id and public-guard session capabilities.
4. Merge reviewed PR, wait for Vercel READY for that exact commit, and compare actual live runtime callers/cache v18.
5. Run synthetic authorization/QR/photo checks and owner phone/guard acceptance before resuming operations.

On failure keep operations paused; no automatic rollback or legacy enrollment fallback is authorized. Device binding is a stored identifier, not hardware attestation; copying both credentials remains a limitation.
