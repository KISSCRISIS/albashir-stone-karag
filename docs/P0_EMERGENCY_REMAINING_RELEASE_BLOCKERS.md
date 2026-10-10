# P0 emergency — release blockers

Status: NOT READY TO DEPLOY. The UI patch is not a security boundary.

## Current branch changes
- guard.html tracks three consecutive failed QR generation attempts and resets on successful QR activation.
- guard-manual.js disables manual-entry UI unless the local flag indicates QR generation failures.
- Neither change can prove outage server-side. A browser user can manipulate client state.

## Blocking server work
1. Introduce server-validated station registration and a short-lived, station-bound outage lease. Do not trust browser error reports alone.
2. Bind guard manual RPC to authenticated guard session, station credential, server-side lease and current recovery state. Remove reliance on the global emergency toggle alone.
3. Ensure only employee ID is accepted in manual path and preserve authorized employee photo/result display for ten seconds.
4. Prevent quota races and guarantee idempotency across QR and manual requests. Validate Asia/Amman operational day policy before altering quota semantics.
5. Isolated tests: healthy QR, one failed station, healthy second station, recovery, forged error, expired lease, shared session, retry, concurrent last daily slot, photo privacy, denied employee.
6. Verify deployed Staging frontend and database migration parity before deployment.

## Rollback
- Revert UI commits e2962a5 and 811311d from this branch if needed.
- No SQL migration has been executed, so there is no database rollback for this patch.
- Staging and Production are unchanged.

## Approval gate
Present final SQL/JS diff, isolated test evidence and rollback plan before requesting separate authorization to apply to Staging. Production requires separate explicit authorization.
