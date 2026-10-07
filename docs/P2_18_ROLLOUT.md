# P2-18 Staging integration and Production decision

Production is not approved by this task. Do not apply these migrations there or merge the frontend into main before the rollout decision: main automatically deploys the Production frontend.

## Acceptance
- Isolated regression suite and PR CI pass.
- Staging backend already contains the supplied migration sequence; compare final definitions before deployment, do not reapply it.
- Deploy the updated employee-photo-url to Staging only, then deploy the separate Staging frontend.
- Verify registration, ordinary login, QR-to-claim, enrollment, device login and own photo/IDOR against synthetic fixtures.
- Human phone acceptance: Safari/iPhone registration, QR scan, claim enrollment, return fast login and photo display. NOT RUN until user reports this new build was tested. Previous phone results do not validate P2-18.

## Production rollout requiring approval
Use a planned maintenance window; callers are incompatible during the transition. Notify gate operators through the owner's existing process. Pause online gate operations, retain the existing offline policy without redesign.
1. Capture current function bodies/ACLs and counts without employee data exports. Confirm no divergence and explicit approval for invalidating existing trusted-device tokens, as migration 1 does.
2. Apply the three reviewed migrations in order in ONE database transaction. Intermediate migration 1 approval/token-promotion logic must not be exposed alone; migration 3 supplies the final behavior.
3. Deploy the device-bound photo Resolver to Production.
4. Merge the reviewed PR and wait for Vercel READY for that exact commit. Verify live caller signatures and no legacy enrollment fallback.
5. Synthetic checks and owner-operated phone/guard acceptance, then resume operations.

Do not restore old enrollment functions as a fallback. On failure, keep operations paused and review recovery. No destructive automatic rollback is authorized.

Device ID is a client-stored identifier hashed by the backend, not hardware attestation. Copying both token and device ID remains outside the protection provided by this binding.
# Final owner policy update — 2026-10-07

The owner replaced the registration-device QR-claim requirement with direct activation by administrator approval. The final rollout must also apply `20261007112137_admin_approval_activates_submitted_device.sql` after the original three P2-18 migrations within the coordinated backend window. See `ADMIN_APPROVAL_DEVICE_POLICY.md`. Production remains NOT APPROVED/APPLIED for this updated candidate. New-registration acceptance now requires pending device denied, admin approval activates that exact device, matching-device fast login succeeds, and a different device is denied; no additional QR enrollment step. QR remains mandatory for gate access.
