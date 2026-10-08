# P2-18 acceptance — 2026-10-07

Scope: Supabase adwvokwucotohwayorgx and https://albashir-staging.vercel.app only. No Production changes.

| Check | Result | Evidence / limits |
|---|---|---|
| Complete isolated regression suite | PASS | Includes complete fresh install, pgcrypto, QR-to-claim, expiry/replay/device mismatch, legacy denial, claim ACL and photo authorization |
| Staging transactional smoke | PASS | Seven assertions true; all synthetic rows rolled back |
| Registration backend | PASS | Synthetic request returns PENDING with pending device intent, no active token; rolled back |
| Registration browser UI | PASS (mocked writes) | Published page, full input payload, pending review and device note; upload/RPC mocked, not an end-to-end submission |
| Ordinary portal login | PASS | Existing synthetic fixture logs into profile; zero direct enrollment requests |
| Own photo display | PASS | Real Staging resolver and Storage, decoded blob image |
| Device-bound photo invalid credentials | PASS | Live HTTP 403 with opaque DENIED |
| Device-bound valid photo and IDOR | PASS live and locally | Verified synthetic fixture was temporarily provisioned, own blob photo decoded, wrong device and other employee path returned opaque HTTP 403; original fixture state restored |
| Responsive browser | PASS | Seven viewports, including landscape; no Production requests |
| Data preservation | PASS | 5 employees: 3 APPROVED, 2 PENDING, 0 active token rows |
| Real phone / camera / enrollment return flow | NOT RUN | Owner cannot test phone now; previous phone results are not reused |

Staging Resolver employee-photo-url v3, SHA 8e256b93359aa1e86ca8153aab875d4c4cfd8774bf1f21c2839c58533beaceae.
Staging Vercel deployment dpl_GZ5JyxSLVs8baBZHAJ3CB8aNYXzB is READY.
Existing approved guard-status RPC was also synchronized to Staging so the current index.html can read authenticated status; no Production changes.

Production gate remains BLOCKED by phone/full enrollment acceptance and owner rollout approval. Do not merge to main early: automatic Vercel deployment would expose incompatible callers before Production backend readiness.
# Final owner policy update — 2026-10-07

Admin approval now activates only the registration-time device directly, with 30-day expiry. This supersedes earlier acceptance criteria requiring an extra QR claim for a newly approved registration. Full isolated tests PASS; hosted rollback smoke confirms pending token preservation, admin approval activation without QR, matching-device fast login and wrong-device denial. Earlier phone evidence confirms QR/manual access but is not acceptance of the new approval flow. New registration → admin approval → same-phone fast login remains owner acceptance NOT RUN. Production unchanged.
# Final duration acceptance

Owner decision: no time expiry for trusted devices; administrator revocation and employee approval still enforced. Latest local and hosted rollback checks PASS for permanent binding, fast login/photo verifier, wrong-device denial and revocation; local employee-status denial PASS. New registration → admin approval → same-phone automatic login still needs owner acceptance. This supersedes 30-day assertions below.
