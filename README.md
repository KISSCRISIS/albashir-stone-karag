# ALBASHIR Emergency Hospital Gate

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

### login.html

Legacy compatibility entry.

Current behavior:

- Redirects immediately to portal.html.
- It is not the primary standalone login screen.

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

### register.html

Employee registration screen.

Implemented:

- full name;
- employee/national ID;
- phone;
- job type;
- specialty;
- employee photo upload;
- two required declarations;
- pending Trusted Device token/device metadata;
- register_employee_request RPC;
- Pending approval result.

Current implementation gap:

Registration is still one shared form. There is no separate Permanent vs Temporary/External category flow in the current frontend.

There is also no separate affiliated-entity field for external/temporary staff in the current register.html.

### verify.html

Employee QR verification screen.

Implemented:

- role restriction for EMPLOYEE;
- QR camera scanning;
- QR claim/verification flow;
- Supabase access decision;
- offline attempt queuing when the network is unavailable.

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

### profile.html

Employee profile portal.

Implemented:

- employee profile login;
- profile data;
- Trusted Device status;
- access history;
- employee data-change request flow;
- QR verification navigation.

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
| Auto employee check | Confirmed |
| Admin profiles and audit logs | Confirmed |
| Employee data-change request architecture | Confirmed |

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
emergency-room-parking-offline-v15
~~~

- service-worker.js
- index.html
- verify-shared.js

This alignment was completed in commit 2cc03bf, so heartbeat/cache diagnostics now report the same Service Worker cache version.

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

Current register.html uploads employee images to the employee-photos bucket and calls getPublicUrl().

The current repository SQL configures employee-photos as a public bucket.

Therefore employee photos are not currently implemented as private signed-URL-only assets.

If private employee photos are a production privacy requirement, this remains a security-hardening task and requires coordinated Storage policy + frontend changes.

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
~~~

Note:

Some older documentation still lists only 11 layers. The consolidated file itself already contains the guard-screen reset patch as layer 12 and is the current repository source for fresh-install composition.

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
| Employee registration | register_employee_request(13 args) |
| Trusted Device fast login | trusted_device_profile_login(text) |
| Guard-device approval | admin_approve_gate_device(text, boolean) |

Legacy overloads still exist in Production for compatibility, including older create_qr_session and register_employee_request signatures.

They are frozen legacy paths and should not receive new callers.

A separately reviewed cleanup/freeze migration is still pending after consumer inventory is complete.

---

## 16. Cleanup scheduling

The repository contains:

~~~text
public.cleanup_expired_qr_sessions()
~~~

Recommended schedule:

every 10 to 30 minutes.

Current status:

The repository documents the schedule, but there is no repository evidence proving that the Supabase Cron/Scheduled Function is currently active in Production.

Verify the actual Production schedule before marking this complete.

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
| Permanent vs Temporary/External registration split | Not implemented in current register.html |
| External/affiliated entity registration field | Not implemented |
| entry_time in verification success card | Not rendered yet |
| daily_visits in verification success card | Not rendered yet |
| Guard scan-only policy | Not implemented; manual fallback still exists |
| Private signed employee photos | Not implemented; employee-photos is public |
| Dedicated leadership photographs in global leadership cards | Not implemented in current global-leadership.js |
| Full standalone dedication section in portal | Not present in current portal.html |
| Dedicated DRS quick-filter button | Not present; generic department filter exists |
| QR cleanup Cron confirmation | Pending Production verification |
| Legacy RPC consumer inventory/freeze | Pending |
| supabase/migrations baseline reconciliation | Pending by design |

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

1. Unify CACHE_VERSION between service-worker.js, index.html, and verify-shared.js.
2. Confirm cleanup_expired_qr_sessions is actually scheduled in Production.
3. Decide and implement the final registration model for Permanent vs Temporary/External employees.
4. Add entry_time and daily_visits to the verification/guard success renderer if required.
5. Decide whether guard manual verification remains allowed or enforce scan-only behavior.
6. Decide employee-photo privacy policy; convert to private/signed URLs if required.
7. Run and record the outstanding acceptance tests.
8. Complete legacy RPC consumer inventory before any legacy-grant freeze/removal.
9. Reconcile Production migration history before introducing a formal supabase/migrations baseline.

---

## 21. Final status

The project has a substantial implemented frontend and a Production-confirmed Supabase core for employee approval, Trusted Devices, secure QR generation, guard-device approval, and access checking.

It should not yet be described as fully production-accepted solely from repository state.

The remaining work is primarily:

- a small set of frontend/spec alignment gaps;
- cache-version alignment;
- privacy decisions for employee photos;
- Cron verification;
- formal acceptance testing;
- migration-history reconciliation.

The correct status is:

~~~text
Core system: Implemented
Production database core capabilities: Confirmed
Vercel migration in repository: Implemented
Production acceptance: Pending final verification and recorded tests
~~~
