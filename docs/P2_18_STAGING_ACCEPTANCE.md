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
