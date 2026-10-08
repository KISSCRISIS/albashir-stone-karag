# ALBASHIR Emergency Hospital Gate

## Latest cache review correction — 2026-10-08

Branch `fix/review-latest-cache` corrects the Service Worker Cache-Control word-boundary check so `private` and `no-store` responses are not persisted. The runtime regression now expects pathname cache keys and verifies these directives for both page navigation and JavaScript assets. Backend/Auth permissions are unchanged. The separate mobile-photo branch was checked with simulated browser conversion/compression; actual HEIC decoding remains dependent on the phone browser.

## Private employee photos — prepared for review, NOT applied 2026-10-06

Branch `security/private-employee-photos`. The `employee-photos` bucket becomes private (2 MiB, JPEG/PNG/WEBP), the two permissive Storage policies are removed, the database stores object paths instead of permanent public URLs, and every display path is exchanged for a 60-second signed URL by the new `employee-photo-url` resolver after it verifies the actor (admin session, employee credentials, trusted device, or gate device). Employee actors can only resolve their own photo. A `private.pending_employee_uploads` ledger plus a service-role-only sweep prevent abandoned uploads from accumulating.

Production state before the change: `employee-photos` was public with `"Anyone can read employee photos"` and `"Anyone can upload employee photos"`, and `employee_registrations.employee_photo_url` held public URLs. Legacy URLs are backfilled to object paths by the migration; unparseable values are left for manual review.

Status: migration, Edge Function, frontend wiring, tests, rollback and documentation are prepared in this branch. **No migration was applied, no function was deployed and Production was not modified.** Coordinated rollout prerequisites and the staging gate are in `docs/PRIVATE_EMPLOYEE_PHOTOS_ARCHITECTURE.md` and `docs/EMPLOYEE_PHOTOS_STAGING_ACCEPTANCE.md`; the pull request description is in `docs/PULL_REQUEST_PRIVATE_EMPLOYEE_PHOTOS.md`. The signed URL is fetched with `cache: "no-store"` and displayed as a blob URL, is never persisted, and is never cached by the service worker. The migration documents the required post-apply check `employee_photo_url like 'http%' = 0`; Production currently holds 2 rows, both parseable public bucket URLs, and 0 uninterpretable values. Verification: `tests/private-employee-photos.cjs` (real migration and rollback in PGlite), `tests/employee-photo-resolver.cjs` (resolver behaviour, mocked Storage API), `tests/employee-photos-static.cjs` (no `getPublicUrl()` remains anywhere).

Storage API HTTP behaviour (expiry rejection, blocked public path), real browser rendering and Production data are explicitly not covered offline and remain part of the staging acceptance work.


## Offline synchronization hardening — 2026-10-06

Shared offline synchronization now sends at most 500 records and 256KiB serialized UTF-8 per batch, leaving headroom below the existing Production 1MB jsonb cap. A batch is deleted locally only after explicit ok=true and a valid synced_count acknowledgement. A zero count remains valid for server-side duplicate handling. Successful batches are removed separately; failures retain and increment retries only for unsent records, with visible/logged errors. Oversized or missing-ID records remain stored for review. Existing encryption, sync lock, RPC authentication, QR decisions, schema and RLS are unchanged.

`tests/offline-sync.cjs` verifies large/Unicode queues, partial failures, malformed responses, duplicate acknowledgements, oversized records and concurrent synchronization without Production calls.


## Staged guard RPC hardening — APPLIED AND VERIFIED 2026-10-06

Phase A: `supabase/migrations/20261005213927_guard_rpc_phase_a.sql` creates the device-bound result overload and revokes legacy reset execution from PUBLIC/anon/authenticated. Legacy employee-result access stays unchanged so the deployed index.html continues to work. Existing device-bound reset, tables and RLS remain unchanged.

Rollout: apply reviewed Phase A; deploy and confirm index.html sends employee id + existing gate code/token and visibly logs/reports reset failures; only then apply `supabase/migrations/20261005213928_guard_rpc_phase_b.sql` to revoke legacy result execution from PUBLIC/anon/authenticated. Owner/service_role access remains. Do not run both migrations as a batch against existing Production. Canonical/fresh-install now contain the final A+B state after live caller confirmation.

Phase A was applied and verified on 2026-10-06 from commit 058d89a. Existing result access and device reset body/ACL are preserved; legacy reset access is revoked. Frontend commit 4e1233f is deployed and verified: live index.html matches committed source exactly, passes gate code/token and handles reset rejection. Phase B was applied after live caller confirmation from commit 7493bd8. Post-apply verification confirms legacy result PUBLIC/anon/authenticated EXECUTE=false, postgres owner and service_role retained, and all other guard bodies/ACLs unchanged. The staged rollout completed without a deliberate service interruption; no real QR or employee data was used in verification. Isolated tests verify old/new callers coexist in Phase A, final ACLs in Phase B, device authentication, result contract without mobile_number, and frontend error handling with synthetic data only.

## P0-3 mandatory QR — APPLIED AND VERIFIED 2026-10-06

Applied from committed migration `supabase/migrations/20261005212905_manual_employee_check_require_qr.sql` (commit 9f35245). Live body and ACL verified after application; no real QR consumed. The complete live Production body captured by `pg_get_functiondef` is preserved except for replacing the optional QR block with unconditional validation and `qr_ok IS NOT TRUE` denial. Signature/defaults, existing ACLs, Employee Status, Trusted Device, specialty rules, daily limits and all response fields (including `access.entry_time` and `access.daily_visits`) are preserved.

Canonical definition: `supabase/canonical/manual_employee_check.sql`. The consolidated fresh-install script ends with this same definition; historical composition layers and patch files remain untouched. The migrations directory contains scoped reviewed deltas, NOT a reconciled initial database baseline. Do not run a blanket reset/push or reapply historical patches.

`tests/manual-employee-check-qr.cjs` executes the real PL/pgSQL candidate and captured validator in an isolated PGlite database with synthetic employees/QR tokens and test helper functions. It covers null/empty/whitespace/invalid/expired/consumed QR, valid tokens and claims/replay, rejected/pending employees and revoked devices before consumption, permanent specialties and daily limits. Valid-flow outputs are compared with the captured baseline; existing ACL preservation and exact source-only QR change are asserted. No Production QR is consumed. Run with the pinned test dependency available via Node's module path.

Impact: approved registrations routed into manual checking without QR now receive DENIED; pending first-entry registration remains a separate unchanged path. Trusted-device checking with valid QR continues. Offline logging/sync and Register Hardening are unchanged.

Reproducible SQL test setup: `npm ci --prefix tests`, then `npm --prefix tests test` (PGlite pinned to 0.5.8).

Status: prepared for review, not committed/pushed or applied. Before any approved Production application, re-read the live definition and compare against the captured fixture to avoid overwriting intervening changes. Production acceptance is not claimed.


## Frontend QR runtime hardening — October 2026

- Expired displayed QR is cleared, including failed-refresh and foreground-resume paths. Only an unexpired server-issued QR may remain visible.
- Absolute RPC `expires_at` is preferred when supplied; otherwise `expires_in_seconds` is anchored conservatively to the QR request start. Previously persisted QR entries using the old expiry calculation are not restored. No local token or validity extension is introduced.
- Shared heartbeat errors and returned rejection states are logged and displayed; the silent compatibility retry is removed. Existing audit handling is used only where available.
- Runtime cache reporting matches Service Worker v16; caching strategy is unchanged.
- Operational pages are disallowed in robots.txt. The existing portal rule is unchanged.
- The guard registration shortcut stays in document flow; result overlays scroll internally on short landscape screens.
- Employee scan CTA already targets verify.html and is unchanged. SQL, RPC contracts, RLS and Register Hardening are unchanged.
- Validation: `tests/frontend-qr-hardening.cjs` checks delayed/expired QR responses, failed refresh, absolute expiry, heartbeat rejection, and isolated browser layouts at 320/375/390/430px, 568x320, 844x390 and 1024x768. Page startup is disabled during layout checks; no Production calls or real-phone/camera tests are performed. Run with Playwright available on Node's module path.


## Production README — Current Repository State

Last repository review: 2026-10-05

Repository: KISSCRISIS/albashir-stone-karag  
Production branch: main  
Frontend target: Vercel  
Production URL: https://albashir-stone-karag.vercel.app  
Backend: Supabase  
Production project reference: qinsfvlspdticposbvst

---

## 1. Project purpose

ALBASHIR Gate is a hospital gate access-control system for:

- employee registration and approval;
- employee profile access;
- Trusted Device registration and fast login;
- guard QR generation and verification;
- gate-device approval and heartbeat monitoring;
- access decisions and access logging;
- administration, auditing, limits, reports, and offline synchronization.

The current frontend is a static application built with HTML, CSS, and Vanilla JavaScript. It does not use Next.js, React, Vue, or a build framework.

---

## 2. Current production architecture

~~~text
GitHub main
    |
    v
Vercel static deployment
    |
    v
ALBASHIR Gate frontend
    |
    v
Supabase Production
qinsfvlspdticposbvst
~~~

Production Supabase is the source of truth for the live database state.

Repository SQL files describe current intended definitions, historical patches, and fresh-install support, but the presence of a patch file in GitHub does not by itself prove that the full patch was applied to the existing Production database.

---

## 3. Deployment status

The repository is configured for static deployment through vercel.json.

Current Vercel configuration includes:

- no framework;
- no build command;
- output directory set to the repository root;
- Content-Security-Policy;
- X-Frame-Options;
- X-Content-Type-Options;
- Referrer-Policy;
- Permissions-Policy;
- HSTS;
- no-store headers for HTML navigation pages.

Netlify is retired from the current production path.

The old netlify.toml file has been removed.

global-leadership.js no longer depends on the old Netlify URL and uses the current origin, with the Vercel production URL only as a local fallback.

Important: the current frontend is static and reads its Supabase URL and public key directly from the frontend source files. NEXT_PUBLIC_* Vercel environment variables are not consumed by this codebase unless the frontend is changed to read generated runtime/build configuration.

---

## 4. Main application pages

### portal.html

Current unified entry page.

Implemented:

- Employee login using employee ID/national ID and phone.
- Trusted Device fast login.
- New employee onboarding entry.
- Guard entry.
- Admin login using Supabase Auth.
- Role-aware redirect logic.
- Existing session continuation.

Current note:

The portal does not currently contain the full previously documented dedication/feature/leadership-photo layout. Leadership information is appended by global-leadership.js.

Current UI (local, uncommitted batch): reference-image overlay login (assets/images/portal-reference.png) with role tabs and the same routing/session logic; runtime script unchanged.

### login.html

Legacy compatibility entry.

Current behavior:

- Redirects immediately to portal.html via an early inline script, so the legacy admin-login markup below it in the file is dead code that never renders.
- It is not the primary standalone login screen.
- Remaining references are: service-worker cache list, robots.txt disallow, and an admin_dashboard error string — login.html itself is kept, not deleted.

### index.html

Main gate QR screen.

Implemented:

- secure QR generation through Supabase;
- 30-second QR refresh cycle;
- approved gate-device heartbeat;
- gate approval state;
- last valid QR retention;
- request locking through qrRuntime.refreshing;
- QR request timeout;
- QR retry backoff: 2s, 5s, 15s, 30s;
- 90-second QR watchdog;
- Realtime guard-screen updates;
- 5-second polling fallback;
- local diagnostic counters and error ring;
- Service Worker registration and update checks;
- offline queue synchronization;
- authenticated two-argument reset_guard_screen client call.

Current UI (local, uncommitted batch): simplified operational screen — the GUARD displays the QR and the employee scans it with the employee phone. Approved on-screen instruction: "اعرض الرمز للموظف ليمسحه بهاتفه". Dominant QR card, compact countdown, compact waiting card, result overlay on real results with automatic reset, collapsible violation/diagnostics sections. QR/security/heartbeat/realtime/reset logic unchanged; no QR fallback introduced.

### register.html

Employee registration screen.

Implemented:

- full name;
- employee/national ID;
- phone;
- registration category (PERMANENT / TEMPORARY) via one shared form;
- job type + independent department (PERMANENT) or specialty + affiliated entity (TEMPORARY);
- employee photo upload;
- two required declarations;
- pending Trusted Device token/device metadata;
- register_employee_request RPC (15-argument overload with category fields, Production-confirmed via 20261005092112 registration_category_split);
- Pending approval result.

Current UI (local, uncommitted batch): stepper with a real device-review state (never marked completed by the frontend), personal/work/device cards, dynamic PERMANENT/TEMPORARY fields, photo preview. Registration RPC payload and Trusted Device logic unchanged.

Repository status:

Production repository supports PERMANENT / TEMPORARY registration split with affiliated-entity field. Production DB migration is APPLIED AND VERIFIED via 20261005092112 registration_category_split (registration_category and affiliated_entity exist and are nullable, specialty remains NOT NULL, CHECK constraint exists, register_employee_request overloads 8/13/15 present, 15-arg has 0 defaults, anon/authenticated EXECUTE confirmed, old rows were NOT backfilled). The split frontend is DEPLOYED to Production (commit 76608c3): Production register.html uses the 15-argument overload and admin_dashboard.html shows the registration category + affiliated entity columns. Production smoke tests passed for registration UI state switching and deployed JS; admin authenticated live-row rendering test COMPLETE and PASSED on Production as SUPER_ADMIN (طلبات التسجيل opened, نوع التسجيل column visible, legacy NULL registration_category rendered غير مصنف (سجل سابق), الجهة التابعة column visible, NULL affiliated_entity rendered -, no approve/reject action performed). The newer UI redesign batch for these pages (see section 22) is LOCAL only and has NOT been committed, pushed, or deployed yet.

### verify.html

Employee QR verification screen.

Implemented:

- role restriction for EMPLOYEE;
- QR camera scanning;
- QR claim/verification flow;
- Supabase access decision;
- offline attempt queuing when the network is unavailable.

Current UI (local, uncommitted batch): mobile-first scan card titled to scan the guard screen QR, same claim/check/Trusted-Device/offline logic; manual panel stays secondary and still requires a claimed QR.

### guard.html

Guard verification interface.

Implemented:

- role restriction for GUARD;
- QR camera scanning;
- access-result display;
- manual employee ID + phone fallback;
- offline attempt queuing and later synchronization.

Current implementation note:

The current guard page is not scan-only. Manual employee verification is still available.

Architecture clarification: guard.html is a SECONDARY manual/fallback verification page. The PRIMARY guard screen is index.html. Do not delete index.html before reviewing its dependencies.

### profile.html

Employee profile portal.

Implemented:

- employee profile login;
- profile data;
- Trusted Device status;
- access history;
- employee data-change request flow;
- QR verification navigation.

Current UI (local, uncommitted batch): sidebar + identity/status cards + QR-scan CTA routing only to verify.html (no personal employee QR is generated); registration_category is not returned by the current RPC and is shown as unavailable rather than inferred; runtime script unchanged.

### admin_dashboard.html

Administration and control center.

Implemented:

- registration review and approval;
- profile change requests;
- gate-device monitoring;
- gate sync status;
- access logs;
- admin audit logs;
- specialty daily limits;
- violations;
- admin profile management;
- SUPER_ADMIN-only admin management;
- permission controls;
- quick search;
- status filter;
- department filter;
- CSV exports;
- Trusted Device status/revocation UI;
- dashboard statistics and recent-result charting.

Current note:

A dedicated DRS quick-filter button is not present. The current dashboard uses a generic department filter.

Current UI (local, uncommitted batch): command-center layout (topbar + sidebar, 9 tabs), six compact KPI cards, Shift A/B/C analytics, three-chart analytics row (current-shift results, hospital PERMANENT employees, temporary/external registrations), prominent daily specialty-limit usage, compact system health, collapsible filters/specialty/device sections. All admin RPCs, permissions, realtime, CSV, Watar sound, signed URLs, and display-only gate devices unchanged.

---

## 5. Supabase capabilities confirmed by Production mapping

PRODUCTION_MIGRATION_MAPPING.md records high-confidence evidence that Production currently contains these capabilities:

| Capability | Production status |
|---|---|
| Trusted Device registration | Confirmed |
| Pending Trusted Device promotion on employee approval | Confirmed |
| Employee approval RPC | Confirmed |
| Guard-device approval | Confirmed |
| Offline device authentication | Confirmed |
| Secure two-argument create_qr_session(device_code, device_token) | Confirmed |
| Authenticated reset_guard_screen(text, text) | Confirmed via migration 20261005075552 (add_authenticated_guard_screen_reset) |
| Scheduled QR cleanup | Confirmed active every 15 minutes via migration 20261005080323 (schedule_expired_qr_cleanup) |
| Auto employee check | Confirmed |
| Admin profiles and audit logs | Confirmed |
| Employee data-change request architecture | Confirmed |
| Registration category split (PERMANENT / TEMPORARY) | Confirmed via migration 20261005092112 registration_category_split (nullable registration_category + affiliated_entity, CHECK constraint exists, 15-arg registration overload with 0 defaults, old rows NOT backfilled) |

The employee base table is public.employee_registrations.

There is no required public.employee_profiles table in the current Production architecture.

---

## 6. Trusted Device flow

Current intended and Production-confirmed flow:

~~~text
Employee registration
        |
        v
Pending registration + pending device metadata
        |
        v
Admin approves employee
        |
        v
Pending device is promoted and enabled
        |
        v
Trusted Device fast login becomes available
~~~

The employee does not select ALLOWED, LIMITED, or DENIED. Access decisions remain server-controlled.

---

## 7. Guard-device security

Current QR generation uses the canonical two-argument RPC:

~~~text
create_qr_session(device_code, device_token)
~~~

The gate device must be active and present a valid, non-revoked token.

Production mapping confirms the secure QR capability.

The repository also contains schema_patch_guard_screen_reset_auth.sql, which adds:

~~~text
reset_guard_screen(device_code, device_token)
~~~

This patch fixes the client/server signature mismatch for automatic guard-screen reset.

Important production status:

The two-argument reset_guard_screen(text, text) RPC is applied and confirmed in Supabase Production via migration 20261005075552, add_authenticated_guard_screen_reset. It is SECURITY DEFINER and callable by anon and authenticated.

---

## 8. QR reliability implementation

Implemented in index.html:

- last valid QR is kept in memory/local storage;
- a failed refresh does not replace a still-valid QR with an unsafe fallback;
- refresh requests cannot overlap;
- retry backoff is 2 / 5 / 15 / 30 seconds;
- QR expiry uses the server response;
- watchdog threshold is 90 seconds;
- Realtime has a polling fallback;
- gate heartbeat reports operational metadata;
- recent gate errors are stored locally.

The system must not grant access solely because the client is offline.

---

## 9. Offline/PWA implementation

Implemented:

- Service Worker;
- cache storage;
- IndexedDB offline queue;
- retry_count on queued items;
- pending-count reporting;
- sync_offline_access_logs;
- duplicate-safe sync logic on the database side;
- Service Worker install continues even when one optional asset fails to cache;
- Supabase API responses are excluded from offline caching.

### Cache-version alignment

Cache-version constants are now aligned.

The following files use:

~~~text
emergency-room-parking-offline-v17
~~~

- service-worker.js
- index.html
- verify-shared.js

Cache-version constants stay aligned across the three files; the private-photo
batch moved them to v17 and added ./employee-photo.js to the precache list, so
heartbeat/cache diagnostics report the same Service Worker cache version.

---

## 10. Verification result data

The backend/result model supports employee access details.

The current shared frontend renderer displays:

- photo;
- name;
- employee/national number;
- department;
- specialty;
- employee classification;
- status.

Current frontend gap:

entry_time and daily_visits are not currently rendered in renderEmployeeDetails() in verify-shared.js.

If these fields are required on the guard/verification success card, the frontend still needs to add them.

---

## 11. Employee photo privacy status

Status: private architecture prepared on branch security/private-employee-photos; NOT applied to Production and NOT deployed.

Production today (verified 2026-10-06): employee-photos is a public bucket with an unconditional read policy and an unconditional upload policy, and register.html still calls getPublicUrl().

The prepared branch converts employee photos to private signed-URL-only assets: private bucket with MIME/size limits, no client read policy, object paths stored instead of URLs, a 60-second employee-photo-url resolver that verifies the actor (and restricts employees to their own photo), a pending-upload ledger with a service-role-only orphan sweep, and a manual rollback.

Until the migration and the resolver deployment are executed by the owner, the Production statement above remains the accurate one.

Violation photos are handled separately and use a private bucket with signed URLs in the admin workflow.

---

## 12. Service Worker and update behavior

Current Service Worker strategy:

- navigation requests: network first, cache fallback;
- local same-origin assets: network first with cache fallback;
- Supabase Auth/REST/Storage traffic: network only;
- old cache versions are deleted on activation;
- clients are claimed after activation.

index.html checks for Service Worker updates every 15 minutes and can request SKIP_WAITING.

---

## 13. SQL files and fresh-install source

For a brand-new Supabase project, use:

~~~text
schema_consolidated_fresh_install.sql
~~~

Do not run the consolidated fresh-install script against the existing Production project.

The consolidated file currently includes these source layers in dependency order:

~~~text
1.  schema.sql
2.  schema_patch_pgcrypto_schema_fix.sql
3.  schema_patch_permanent_specialty.sql
4.  schema_patch_auto_verify.sql
5.  schema_patch_offline_gate_mode.sql
6.  schema_patch_verify_employee_profile.sql
7.  schema_patch_employee_profiles.sql
8.  schema_patch_trusted_device_registration_flow.sql
9.  schema_patch_trusted_device_metadata.sql
10. schema_patch_production_hardening.sql
11. schema_patch_gate_qr_device_auth.sql
12. schema_patch_guard_screen_reset_auth.sql
13. schema_patch_registration_category_split.sql
~~~

Note:

Some older documentation still lists only 11 or 12 layers. The consolidated file now contains 13 layers including the registration-category split as layer 13 (Production migration 20261005092112 registration_category_split is APPLIED AND VERIFIED) and is the current repository source for fresh-install composition.

---

## 14. Production migration safety

Do not rerun schema.sql or all repository patches blindly against Production.

Production Supabase is the authoritative database state.

PRODUCTION_MIGRATION_MAPPING.md confirms that repository patch filenames do not map one-to-one to recorded Production migration names.

No supabase/migrations directory should be introduced until the current live Production baseline and migration history are formally reconciled.

Future Production SQL work should use narrowly scoped reviewed delta migrations.

---

## 15. Canonical RPC status

Current canonical runtime targets:

| Capability | Canonical RPC |
|---|---|
| QR creation | create_qr_session(text, text) |
| Employee registration | register_employee_request(15 args, 0 defaults; 13 args and 8 args retained in Production for compatibility) |
| Trusted Device fast login | trusted_device_profile_login(text) |
| Guard-device approval | admin_approve_gate_device(text, boolean) |

Production registration overloads (confirmed via migration 20261005092112 registration_category_split): 8 args legacy, 13 args preserved compatibility, 15 args new registration overload with 0 defaults and anon/authenticated EXECUTE.

Legacy overloads remain in Production for compatibility and should not receive new callers.

A separately reviewed cleanup/freeze migration is still pending after consumer inventory is complete.

---

## 16. Cleanup scheduling

Production contains:

~~~text
public.cleanup_expired_qr_sessions()
~~~

The function removes expired QR sessions older than 10 minutes from:

~~~text
public.qr_sessions
~~~

Supabase Cron is now enabled in Production.

Confirmed Production job:

~~~text
Job name: cleanup-expired-qr-sessions
Schedule: */15 * * * *
Command: select public.cleanup_expired_qr_sessions();
Active: true
~~~

This means expired QR-session cleanup runs automatically every 15 minutes.

The schedule was applied through Production migration:

~~~text
20261005080323
schedule_expired_qr_cleanup
~~~

---

## 17. Current confirmed repository gaps / pending implementation

| Item | Current status |
|---|---|
| Vercel static configuration | Implemented in repository |
| Netlify dependency removal | Implemented in repository |
| Dynamic current-origin public URL handling | Implemented |
| Secure gate QR flow | Implemented; core capability Production-confirmed |
| Trusted Device registration/approval | Production-confirmed |
| Guard-device approval | Production-confirmed |
| Offline queue and sync code | Implemented |
| Service Worker v15 | Implemented; cache-version constants aligned across service-worker.js, index.html, and verify-shared.js |
| Two-argument reset_guard_screen | Applied and confirmed in Production via migration 20261005075552 (add_authenticated_guard_screen_reset) |
| Permanent vs Temporary/External registration split | Production DB migration APPLIED AND VERIFIED via 20261005092112 registration_category_split; split frontend DEPLOYED to Production and smoke-tested |
| External/affiliated entity registration field | Production DB migration APPLIED AND VERIFIED via 20261005092112 registration_category_split; admin column DEPLOYED to Production and live-row rendering PASSED as SUPER_ADMIN (NULL renders -) |
| entry_time in verification success card | Not rendered yet |
| daily_visits in verification success card | Not rendered yet |
| Guard scan-only policy | Not implemented; manual fallback still exists |
| Private signed employee photos | Prepared on branch security/private-employee-photos (migration + resolver + tests + rollback); NOT applied to Production |
| Dedicated leadership photographs in global leadership cards | Not implemented in current global-leadership.js |
| Full standalone dedication section in portal | Not present in current portal.html |
| Dedicated DRS quick-filter button | Not present; generic department filter exists |
| QR cleanup Cron | Confirmed active in Production every 15 minutes via migration 20261005080323 |
| Legacy RPC consumer inventory/freeze | Pending |
| supabase/migrations baseline reconciliation | Pending by design |
| SUB_ADMIN / access-control role discrepancy | Known, NOT MODIFIED |

---

## 18. Acceptance tests still requiring evidence

The repository contains test scripts/checklists, but the following should not be described as fully passed unless a dated production/staging result is recorded:

| Acceptance test | Status |
|---|---|
| 72-hour continuous gate run | Pending evidence |
| 100 concurrent QR requests | Test script exists; production acceptance result not recorded |
| p95 under 2 seconds | Pending evidence |
| 10-minute network outage and duplicate-free resync | Checklist exists; completed result not recorded |
| QR replay must return DENIED | Pending acceptance evidence |
| Unauthorized admin access test | Pending acceptance evidence |
| Role separation test | Pending acceptance evidence |
| Employee privacy/guard display test | Pending acceptance evidence |
| Service Worker upgrade/cache migration test | Pending acceptance evidence |

---

## 19. Repository documentation

Current important documentation:

- README.md — current high-level source of project status.
- ALBASHIR_GATE_24_7_FINAL_SOLUTION_REPORT.md — reliability/production report.
- PROJECT_INDEX_AND_ARCHITECTURE.md — architecture and SQL dependency notes.
- PRODUCTION_MIGRATION_MAPPING.md — live Production capability mapping and source-of-truth warning.
- PRODUCTION_RPC_CANONICAL_MAP.md — canonical/legacy RPC rules.
- OPERATIONS_24_7.md — operational acceptance checklist.
- offline_sync_10_minute_check.md — offline sync acceptance procedure.
- docs/AUTO_DEVICE_ACTIVATION_FLOW.md — Trusted Device approval flow.
- schema_consolidated_fresh_install.sql — fresh-project database setup only.

Some older statements in supporting docs may lag behind the current repository. When there is a conflict:

1. live Production Supabase is authoritative for Production database state;
2. current frontend source is authoritative for current UI behavior;
3. schema_consolidated_fresh_install.sql is authoritative for the current fresh-install composition;
4. PRODUCTION_MIGRATION_MAPPING.md is authoritative for what has actually been confirmed in Production;
5. README.md should describe the current reviewed state and explicitly mark unverified items as pending.

---

## 20. Immediate next actions

Highest-priority technical items before declaring the system fully production-accepted:

1. Permanent vs Temporary/External registration feature: DEPLOYED, smoke-tested, and admin live-row rendering exercise COMPLETE and PASSED on Production as SUPER_ADMIN with no approve/reject action performed (commit 76608c3 on main; DB migration 20261005092112 APPLIED AND VERIFIED). This feature acceptance is complete; broader system acceptance work (below) remains.
2. Add entry_time and daily_visits to the verification/guard success renderer if required.
3. Decide whether guard manual verification remains allowed or enforce scan-only behavior.
4. Employee-photo privacy: architecture prepared on branch security/private-employee-photos; review, then apply the migration and deploy the resolver following docs/PRIVATE_EMPLOYEE_PHOTOS_ARCHITECTURE.md.
5. Run and record the outstanding acceptance tests.
6. Complete legacy RPC consumer inventory before any legacy-grant freeze/removal.
7. Reconcile Production migration history before introducing a formal supabase/migrations baseline.

---

## 21. Final status

The project has a substantial implemented frontend and a Production-confirmed Supabase core for employee approval, Trusted Devices, secure QR generation, guard-device approval, and access checking.

It should not yet be described as fully production-accepted solely from repository state.

The remaining work is primarily:

- a small set of frontend/spec alignment gaps;
- privacy decisions for employee photos;
- formal acceptance testing;
- migration-history reconciliation.

The correct status is:

~~~text
Core system: Implemented
Production database core capabilities: Confirmed
Vercel migration in repository: Implemented
Registration split feature deployment: Verified for DB + registration frontend smoke tests + admin authenticated live-row rendering (PASSED as SUPER_ADMIN)
Production acceptance: Pending final verification and recorded acceptance tests
~~~

---

## 22. Frontend UI batch status (local, uncommitted)

Primary frontend pages:

portal.html             COMPLETE
register.html           COMPLETE
profile.html            COMPLETE
verify.html             COMPLETE
index.html              COMPLETE
admin_dashboard.html    COMPLETE

Status: 6 / 6 primary frontend pages completed locally.

This statement refers to the approved frontend/UI batch only, not to blanket closure of every repository/security issue. guard.html remains a secondary manual/fallback page outside the six.

## 23. Shift definitions (dashboard analytics)

Shift A: 07:00 <= time < 15:00

Shift B: 15:00 <= time < 23:00

Shift C: 23:00 <= time < 07:00 next day

Operational-day rule: from 07:00 onward the operational date is the current calendar date; from 00:00 through 06:59 it is the previous calendar date. Shift C belongs to the date on which it started at 23:00. Classification uses the same local timestamp basis as existing log rendering; no database timestamps or timezones were changed.

## 24. Admin three-chart analytics

Final Overview row (desktop): three compact cards — (1) نتائج الشفت الحالي (current-shift result distribution), (2) موظفو المستشفى (registration_category === "PERMANENT" only, by specialty), (3) التسجيلات المؤقتة والخارجية (registration_category === "TEMPORARY" only, affiliated entity/specialty bars).

Classification rules: PERMANENT and TEMPORARY are mutually exclusive per linked registration; legacy/null categories stay UNKNOWN; unlinked logs stay UNLINKED; neither is guessed into the other group. UNKNOWN methodology is secondary/collapsed. No new RPC, query, or realtime subscription was added for these charts.

## 25. KPI responsive behavior

The six KPI cards use a compact responsive grid (desktop six-across, tablet responsive, mobile stacked) with title + value always visible; there is no KPI icon-only mode (sidebar mobile icons are separate navigation behavior). Decorative pseudo-elements were disabled where they interfered with card content.

## 26. Daily specialty limits (current UI behavior)

Daily limits remain specialty-based via the unchanged admin_upsert_specialty_limit RPC and parameters. Specialty selection is SELECT-based from known real values; department-only values are not used as specialty keys; free-text specialty creation was removed from the current UI while existing saved limit names remain selectable. PER-EMPLOYEE LIMITS ARE NOT SUPPORTED BY THE CURRENT RPC.

## 27. System health (Overview)

Gate Devices + Offline Sync remain available but secondary: compact health summaries (device health, stale/offline state, pending sync) with full tables collapsed by default. No new monitoring backend was added.

## 28. Database / backend impact of the UI batch

The completed frontend redesign did NOT require: a new database schema, a new migration, a new RPC for dashboard analytics, a new realtime channel, service_role exposure, or new QR fallback logic. Existing backend contracts were preserved.

## 29. Security rules (restated, still mandatory)

- no QR generation without Supabase validation;
- gate device must be approved before QR creation;
- no service_role in frontend;
- no silent heartbeat fallback;
- no automatic migrations;
- no production schema patches without owner review;
- manual_employee_check decision order remains: 1. Employee Status, 2. Trusted Device, 3. QR Validation + Consume, 4. Specialty Rules, 5. Daily Limits.

These are mandatory rules, not optional recommendations.

## 30. Known / unresolved items

- SUB_ADMIN / access-control role discrepancy (access-control.js data-roles vs verifyAdmin accepted roles): known, NOT MODIFIED during UI work.
- Broader items from sections 17-18 (photo privacy, guard policy, acceptance tests, migration reconciliation) remain unchanged by the UI batch.

## 31. Repository / workflow status

- Current UI work lives in the local extracted working folder; no final commit/push yet for this batch.
- Final changes must be transferred/reconciled into the clean Git clone before commit; do not git init the extracted ZIP working directory.
- Clean clone for Git operations: C:\Users\USER\Downloads\albashir-stone-karag-git\
- Repository: KISSCRISIS/albashir-stone-karag, branch main. No new commit hash exists yet.

## 32. Next steps (approved sequence)

1. Repository Cleanup Audit — READ ONLY (classify KEEP / REVIEW / DELETE CANDIDATE, owner review before deletion).
2. Final Regression + Security Audit.
3. Final diff review.
4. Reconcile approved files into the clean Git clone.
5. Commit/push only after explicit owner approval.

## 33. Cleanup audit warning

- SQL/migration files must not be deleted merely because they appear old; schema_patch_*.sql files require separate review.
- No PROJECT_RULES.md, wrangler config, or supabase/ directory was found in the current working folder; do not reference them as authoritative until verified.
- Repository cleanup must follow the controlled review workflow above.

### Employee photo client review — local candidate only

The private-photo candidate now fails closed when a no-store image fetch fails.
Images and thumbnail links use blob URLs, with no direct signed-URL fallback.
Photo cache entries are credential-bound in memory; session changes and logout
clear displayed blobs and invalidate pending requests. Client regression tests
cover credential changes and logout during resolver/image requests. The frontend
QR regression expects this candidate's Service Worker v17. SQL remains unchanged;
Staging acceptance and Production rollout are not performed or approved here.

### Staging executable review — 2026-10-07

The full fresh-install SQL and photo migration execute in an isolated local
Supabase-shaped database, but deployment remains BLOCKED: profile helpers are
missing, the resolver service role cannot execute profile login, and required
admin table SELECT grants are absent. SDK entry import is pinned to 2.117.2;
Deno lock/runtime verification remains pending. Migration rollout comments now
agree with baseline -> verify -> fixtures -> photo migration -> verify ->
resolver -> Staging frontend -> acceptance. SQL executable logic is unchanged.
No hosted writes/deployments or Production operations were performed.

### Staging grant correction candidate — review only

Fresh-install now includes SELECT for authenticated on the seven admin tables
queried by the dashboard and EXECUTE for the backend service role on existing
profile-login RPC. Existing RLS remains authoritative; no anon table grants,
guard-screen grants, write grants or function-body changes are introduced.
Missing rate-limit/audit helper definitions remain a BLOCKER pending an approved
source. No new migration, hosted SQL execution or Production change.

The fresh-install candidate now restores security_attempt_logs and the exact
is_rate_limited/write_security_attempt bodies read from Production under explicit
read-only approval. Helper EXECUTE and direct ledger access are denied to client
roles and service_role; existing postgres-owned profile login invokes them as
owner. No raw mobile column is stored; the existing MD5 behavior is preserved
and is not described as strong anonymization. Production ACLs are not changed.

Validation update: tests/fresh-install-readiness.cjs is part of the isolated
test command and verifies the complete candidate, live helper bodies, failed-only
5-in-5-minute limit, audit hashes, backend login, RLS filtering and photo migration
integration. supabase/functions/deno.lock freezes the SDK dependency graph.
Deno 2.9.6 frozen-lock TypeScript check and local entry smoke PASS; only type
annotations were added to the entry. Hosted Staging/17 acceptance checks NOT RUN.
Earlier missing-helper and pending-lock notes describe the pre-correction state.

## Staging execution checkpoint — 2026-10-07

The reviewed employee-photo baseline, migration and resolver were applied only to adwvokwucotohwayorgx. Authorization and signed-link expiry checks passed. Valid image upload fails the Storage RLS policy; server-side forged-content rejection remains unproven, and response cache headers do not meet the acceptance guarantee. No hosted frontend, Production rollout, commit or CI is claimed. See docs/EMPLOYEE_PHOTOS_STAGING_RESULTS.md for evidence and stop conditions.

## Owner-approved upload correction — 2026-10-07

Apply supabase/employee_photo_upload_compatibility_reviewed.sql after the reviewed private-photo migration. It changes only the upload INSERT predicate for Storage's permission-probe metadata; the private bucket and its real-byte 2MiB/MIME limits remain mandatory. No photo reads or updates are granted. Applied to Staging only. register.html requests max-age=0, no-store for new uploads; client downloads remain no-store and display only blob URLs.

The owner chose administrative photo review instead of server-side content decoding. Status: ACCEPTED BY OWNER / ADMIN REVIEW. This is not an automated content-validation PASS. Storage accepts forged image MIME; SVG and oversize limits remain enforced. Production has not been changed.

Owner-reported Staging acceptance (2026-10-07): registration submission completed on desktop Chrome and iPhone16e Safari with a pending-review success message. This is user-performed evidence; approval, photo rendering and real-device cache checks are separate. See docs/EMPLOYEE_PHOTOS_STAGING_RESULTS.md.

### Guard status privacy — approved staged rollout (2026-10-07)
Introduce get_guard_screen_status with active gate/token authentication, then deploy index.html using bounded five-second polling. Only after live frontend confirmation apply supabase/guard_status_retire_direct_read.sql to revoke direct SELECT. Fresh installs include the final ACL. QR and Register Hardening remain unchanged. Isolated synthetic tests cover device denial, private reads, contract and frontend concurrency/error handling. No real-phone test is claimed.

### Five search_path warnings — review candidate (2026-10-07)
Reviewed SQL: supabase/search_path_five_reviewed.sql. Sets pg_catalog only for normalize_specialty_name(text), is_permanently_allowed_specialty(text), default_admin_permissions(text), sync_trusted_device_activity() and prevent_approved_employee_identity_change(). No bodies, grants, ownership, volatility, tables, RLS or JWT keys change. Synthetic regression verifies behavior, hostile caller search_path resistance, approved identity protection and trusted-device activity synchronization. Owner approved the exact five ALTER statements on 2026-10-07; apply only this reviewed SQL and verify bodies/ACLs and advisors afterward.

### Registration APPROVED phone validation (2026-10-07)
Canonical 15-argument registration body synchronized from the live Production definition: APPROVED requests must supply the matching stored mobile number, and manual_employee_check receives clean_mobile. Already applied to Staging and Production; do not reapply historical patches. QR logic unchanged. Owner approved gate-device DEFAULT false for Production and fresh installs. Existing device states remain unchanged. Cache-Control remains a separate open item.

### P2-18 Staging integration candidate (2026-10-07)
Three reviewed migrations synchronize the Staging enrollment claim, device ID binding and 30-day TTL implementation. Legacy enrollment/login overloads fail closed. Photo actors and Resolver now require device_id, and cache authorization keys include it. Production deployment is NOT approved: main auto-deploys Production frontend, so merge must wait for an approved rollout window and successful Staging phone acceptance. No Production SQL or Resolver deployment is performed during this review. See docs/P2_18_ROLLOUT.md.
# Registration-device approval — owner decision 2026-10-07

Admin approval now activates the device submitted with the registration request on Staging, with device binding and a 30-day expiry; no extra QR enrollment step is required. QR remains mandatory for gate access. Production is unchanged. See [the final policy and deployment scope](docs/ADMIN_APPROVAL_DEVICE_POLICY.md), which supersedes the earlier registration-device QR-claim requirement.
# Final trusted-device duration — 2026-10-07

On Staging, the owner-approved registration device remains trusted until administrator revocation while the employee remains approved and device authorization remains valid. The earlier 30-day duration is superseded. QR remains mandatory for gate access. Production unchanged; see [final policy](docs/ADMIN_APPROVAL_DEVICE_POLICY.md).
# Public guard Staging — 2026-10-07

Scan-to-decision correction: a logged-in employee now proceeds to server verification after QR scan without re-entering identity; trusted-device automatic results also reach the matching guard session. Both flows were verified live on Staging; real-phone retest remains pending. No authority-function or Production changes.

`guard.html` now displays database-issued QR immediately without login/PIN/gate-device approval. Approved name/photo/job/specialty fields are exposed only for its QR session using a separate short-lived read capability; private Storage and direct-table restrictions remain. Mandatory QR and the original decision function stay unchanged. Staging published; Production unchanged. See [rollout, tests and authorization scope](docs/PUBLIC_GUARD_STAGING.md).

## Owner frontend refinement — 2026-10-07

The public guard page is opened by a direct link distributed to guards only. Public frontend navigation, redirects, comments and service-worker asset lists must not disclose its path. This is presentation policy, not authorization. Backend permissions remain unchanged. Its result replaces the QR panel for 10 seconds; rotation and server expiry continue. Employee verification photos use the credentials of the successful verification path, never an unrelated stored device token. Cache version is v18. Chromium/WebKit emulation is not a real-phone acceptance test.

## Autonomous audit repairs — 2026-10-07

Registration shortcuts must target the current registration page. CSV exports must neutralize formula-like string cells. Service Worker page caches must omit credential-bearing queries and never persist third-party responses. Cache version is v19. The QR/heartbeat/layout browser suite now runs in CI with pinned Playwright. See docs/PROJECT_AUDIT_2026_10_07.md for evidence and unresolved database/Production gates.

## QR v2 compatibility review — 2026-10-07

Verification retries retain their request ID only while the mode and payload remain identical. Correcting credentials or switching from automatic to manual verification creates a new request ID; transport retries remain idempotent. Guard WAITING polling preserves QR generation failure messages. Isolated SQL coverage exercises the real v2 definitions, claim replay, credential correction and single access-event behavior.

The owner-approved Staging correction uses a distinct permanent Other department value, while temporary `أخرى` retains its configured limit of 7. No existing Other registrations required conversion. The original authority-function body and ACL remain unchanged. Vercel authorization was renewed and the combined frontend was deployed to https://albashir-staging.vercel.app (deployment dpl_757rXprTzdvfausE4f4HroiDJcyo). Chromium and WebKit Staging checks passed for QR/countdown, employee and guard results, private-photo blob decoding, QR-panel replacement and 10-second result cleanup, with zero Production requests. CI passed for code commit abc7129. Production is unchanged. Local regression and browser emulation passes do not constitute a real-phone acceptance result.

## Owner mobile feedback — 2026-10-07

An existing employee session takes precedence over an unrelated saved device token after an in-app QR scan; verification still goes through the existing mandatory-QR server RPC. The portal opens with a large visible login form and functional QR, registration and profile service cards. The owner-provided image is preserved as CSS image sections for the header, dedication and executive leadership, with the latter sections below the services and above the English leadership list. The upper entry button is removed. Service Worker/runtime cache labels are v20 to retire older frontend assets. No SQL, grants, RLS or Production changes. Phone acceptance is pending a retest of this build.

Staging frontend ee77f1d is published at https://albashir-staging.vercel.app (deployment dpl_GGH68ZJd7ubqkpyDVJ8i7NRmpXcq), with CI PASS. Chromium and WebKit live-backend testing of the simulated in-app camera callback, including a stale saved token and active employee session, confirmed automatic server verification, decoded private photos for both parties and 10-second result cleanup. This uses a simulated camera source, not a real-phone camera test.

## Owner persistent-login and landing refinement — 2026-10-08

The landing shows an unobstructed hospital panorama, then five functional service cards. Employee/admin dialogs open only when selected; dedication and the original executive portraits are at the bottom, with no duplicate English leadership section on the portal. The original reference image is reused without regenerating portraits.

Employee login offers a visible remember-me checkbox (enabled for the owner-requested flow). When selected, only the employee ID and mobile login identity are retained in this browser origin; logout and an unchecked subsequent login remove this remembered identity. A reopened tab restores an EMPLOYEE UI session only, never administrator roles or backend trust. Every gate decision still calls the existing server RPC with mandatory QR, current employee status and device policy. No auto-enrollment RPC or backend/schema/ACL changes were added. Browser storage and camera permissions are specific to each browser. QR service links start the camera from `verify.html?scan=1`, with the camera button retained for denied permissions or browser restrictions. Cache labels are v21. Real-phone acceptance remains pending for this build.

Staging release 4db3094: deployment dpl_DbH8F58wJ67UtZjSsQiNNcDwpQWX READY, CI PASS, 26 local suites PASS. Chromium and WebKit tests cleared the tab session while retaining the remembered identity, then automatically started a simulated in-app camera scan. The real Staging RPCs produced employee/guard results and decoded private photos without manual re-entry; QR replacement and 10-second cleanup passed. Zero Production requests or gate-device heartbeat requests. Real-phone acceptance for this release: NOT RUN.

## External phone camera verification — 2026-10-08

The guard QR already encodes a same-origin HTTPS verification link, so phone cameras/QR readers can open it without the in-app scanner. Chromium and WebKit tests decoded the actual displayed QR, cleared the tab session, opened that link with the remembered browser identity, and confirmed automatic server verification and both private photos with no app camera request. No database changes were needed. See [final Staging acceptance procedure](docs/FINAL_STAGING_ACCEPTANCE_2026_10_08.md) for reproducible phone steps, supported browser boundaries and the remaining real-phone gate.
# تصحيح اختبار الهاتف — 8 تشرين الأول 2026

## اعتماد الإصدار النهائي

أكد المالك نجاح المسح التلقائي والصورة على الهاتف واختصار الشاشة الرئيسية، ووافق على مراجعة/دمج GitHub والنشر الفعلي في 2026-10-08. اشترط الحفاظ على ربط الأجهزة الحالية؛ لذلك يستخدم النشر `supabase/rollout/production_preserve_existing_devices.sql` بدل تصفير tokens في migration التاريخية. الاختبار يثبت الحفاظ على هوية الموظف وحالة الجهاز وtoken، وإضافة fingerprint من معرّف الجهاز المحفوظ فقط. أُغلقت إعادة نتائج QR المكتملة بعد 30 ثانية، وأصبح hash للطلب مبنيًا على JSON لمنع التباس الفواصل. نسخة الدمج تحفظ تقوية ACL الموجودة في Production وتعطيل عمليات المخالفات، وتجمع اختبارات الفروع دون إسقاط أي مجموعة. لا يُشغَّل fresh-install على Production.

صفحة التحقق تحفظ هوية الموظف بعد نجاح تحقق QR اليدوي (`ALLOWED` أو `LIMITED`) عند اختيار «حفظ دخولي على هذا الجهاز للمسح التالي». المسح التالي يستعيد هذه الهوية حتى في تبويب جديد، ثم يعيد التحقق عبر RPC الحالية؛ الحفظ لا يمنح تفويضًا ولا يغير اعتماد الجهاز أو Mandatory QR. الطلب المرفوض لا يُحفظ، وخيار عدم الحفظ والخروج يبقيان متاحين. تعيين الجلسة يسبق تحميل الصورة كي لا يُلغى رابط blob الجديد عند تنظيف صور الجلسة القديمة.

تحميل صورة النتيجة يعرض حالة انتظار، وفشل التحميل يعرض زر إعادة محاولة عبر Resolver نفسه وfetch بلا cache. لا توجد قراءة مباشرة من Storage أو كتابة رابط موقّع في التخزين. نسخة cache أصبحت v22 لتحديث الواجهة السابقة على الأجهزة. اختبار regression يغطي حفظ التحقق الناجح فقط واحترام عدم الحفظ؛ اختبار Staging في Chromium/WebKit يغطي أول تحقق يدوي ثم QR جديد تلقائيًا، وانقطاع طلب الصورة ثم نجاح إعادة تحميلها. اختبار الهاتف الفعلي ما زال يحتاج إعادة تجربة الإصدار الجديد. لا تغيير Backend أو Production.

## Public deployment artifact
Vercel builds `public-runtime` using `scripts/build-public-runtime.cjs`. Only application pages and assets are published. SQL/canonical/migrations, documentation, tests, scripts, Git metadata and credentials remain outside the public output. The direct guard page remains in the runtime artifact. Regression `tests/public-runtime-artifact.cjs` verifies inclusion/exclusion. The 2026-10-08 post-deployment audit found and corrected the previous repository-root publishing configuration.
