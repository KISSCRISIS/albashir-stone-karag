# P0 release verification — guard emergency

Status: BLOCKED. Do not deploy the emergency entry feature until all gates pass.

## Observed in Staging (2026-10-10)
- The public QR generator returns RATE_LIMITED when 1200 unexpired public guard sessions exist. This is a capacity guard, not proof that a particular phone's QR rendering failed.
- The existing guard emergency setting is global.
- Guard sessions identify the guard account, not the physical station. Concurrent sessions on the shared guard account cannot be distinguished by guard_id.
- The employee decision RPC counts specialty daily entries without a transaction-scoped quota lock.
- The existing generator function is not instrumented with a durable server-side failure event and station ID.

## Required implementation and acceptance gates
1. Provision independently revocable station credentials, distinct from shared guard account credentials. Store only hashes server-side; protect registration against anonymous callers.
2. Introduce station-scoped, expiring emergency authorizations, issued only from trusted server-observed QR generation failure evidence for that station. Do not accept browser-reported failure as evidence. RATE_LIMITED alone is insufficient unless the product owner explicitly authorizes it as a qualifying outage.
3. Ensure QR generation remains possible on a healthy station; a successful generation immediately revokes that station's emergency authorization.
4. Require guard session, station credential, station-scoped active authorization, employee ID, and idempotency request ID in the manual RPC. A stale lease, unknown station, missing authentication, or backend outage fails closed.
5. Preserve shared guard concurrent sessions, employee decision rules, photo expiry and rate limiting. Remove national ID from guard manual UI.
6. Serialize specialty quota decisions (count and insert in one transaction under the same per-specialty lock); verify timezone policy before changing the daily cutoff.
7. Run tests: healthy QR rejects manual, server-observed outage allows affected station only, recovery revokes, unrelated station denied, unauthenticated denied, revoked guard denied, request replay idempotent, mismatch rejected, 30/min throttle, concurrent last-slot requests allow no overage, network failure denied.
8. Verify staging deploy target and rollback procedure; apply database migration and test on Staging only; deploy Staging frontend only after all tests pass.

## Known limitation
A server cannot independently observe a phone's local canvas/rendering failure. That case must remain disabled without a separate trusted attestation path. A complete backend outage cannot safely authorize online manual entry.

## Current files
- `supabase/drafts/p0_server_observed_qr_outage_guard.sql`: unsafe experimental generator probe; DO NOT APPLY.
- `supabase/drafts/p0_rate_limited_readonly_probe.sql`: non-mutating prototype, but not station-scoped and recognizes only RATE_LIMITED; DO NOT APPLY.
