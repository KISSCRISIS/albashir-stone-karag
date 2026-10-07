# PROJECT RULES — ALBASHIR Gate

## Owner exception — public guard screen, 2026-10-07

For `guard.html` only, the owner explicitly approved database-issued QR and session-scoped result RPCs without login/PIN/gate-device approval or gate-device credentials. This exception supersedes P0-2 for this new public issuance RPC only; the existing authenticated `index.html` flow remains unchanged. Results may expose only the owner's approved fields: name, photo, job and specialty, plus access decision. A separate high-entropy expiring read capability binds those fields to this screen's QR session; never expose the shared latest employee to everyone. Photos stay private and use the resolver with signed URLs of at most 60 seconds. No direct table grants are allowed. `manual_employee_check`, Mandatory QR and P0-3 order stay unchanged. Staging first; Production needs coordinated approval after acceptance.

This file is the authoritative, mandatory, root-level project ruleset.
Current as of October 2026.

## Absolute Prohibitions

1. Never generate QR without Supabase validation.
2. Never use service_role in frontend.
3. Never generate QR without verifying gate_devices.approved = true.
4. Never apply schema_patch_*.sql to production without owner review.
5. Never use silent fallback when heartbeat fails.
6. Never rewrite a working file without documented reason.
7. Never change Supabase structure without explaining production impact.
8. Never create migrations automatically.
9. Never use fixed LIVE_SITE_URL; use window.location.origin.
10. Never commit/upload secrets or keys to a public repository.

## P0 — Critical

### P0-1 — No public QR fallback
File: index.html

If Supabase fails:
- keep the last valid QR
- show:
  "النظام غير متاح حالياً"

Never generate a QR without a database-issued token.

### P0-2 — Approved gate device required

Before QR generation verify:

gate_devices.approved = true

Never generate QR for:
- pending
- revoked

### P0-3 — manual_employee_check exact decision order

Mandatory:

1. Employee Status
2. Trusted Device
3. QR Validation + Consume
4. Specialty Rules
5. Daily Limits

### P0-4 — wrangler.jsonc

If present:
remove it through normal Git cleanup workflow.

Reason:
project is not deployed on Cloudflare Workers.

Current audit found:
wrangler.jsonc NOT PRESENT.

Document the rule but do not create/delete anything.

### P0-5 — Repository security

- repository must be Private
- rotate SUPABASE_ANON_KEY when exposure risk requires it

### P0-6 — Violation images

Violation image storage must be private.
Use signed URLs in admin_dashboard.html.

### P0-7 — Employee photos must stay private

The `employee-photos` bucket must remain private (`public = false`) with a
MIME/size limit and no `select` policy for `anon` or `authenticated`.

Mandatory:

- never reintroduce `getPublicUrl()` or any permanent public photo link;
- store the object path (`registrations/<employee folder>/<file>`), never a URL;
- every display path goes through the `employee-photo-url` resolver, which
  verifies the actor first and issues a URL of at most 60 seconds;
- an employee actor may only resolve their own photo;
- a resolver failure must never fall back to a public URL;
- the `private` schema and the sweep RPCs stay service-role only.

Enforced by `tests/employee-photos-static.cjs`,
`tests/private-employee-photos.cjs` and `tests/employee-photo-resolver.cjs`.

## P1 — High Priority

### P1-7
verify.html must use activeQrToken exclusively
for verification logic.

### P1-8
verify.html must use syncingLock
to prevent duplicate offline synchronization.

### P1-9
Heartbeat failures must not silently fallback.

Required behavior:
- log
- visible state
- audit

### P1-10
manifest.json:
- start_url = ./index.html
- valid PNG icons 192x192 and 512x512

### P1-11
Security headers must exist in the CURRENT active deployment configuration.

IMPORTANT:
Current project deployment is Vercel.
Do NOT create netlify.toml.

Required headers:

Content-Security-Policy:
default-src 'self';
script-src 'self' 'unsafe-inline';
connect-src 'self' https://*.supabase.co wss://*.supabase.co;
img-src 'self' data: blob:;
style-src 'self' 'unsafe-inline';

Permissions-Policy:
camera=(self), microphone=()

Strict-Transport-Security:
max-age=31536000; includeSubDomains

Document the requirement platform-neutrally,
with current implementation expected in vercel.json if applicable.

### P1-12
Never create migrations automatically.

Anything under:
supabase/migrations/

requires explicit owner review.

## P2 — Medium

### P2-13
Use server QR expiry exactly as returned.
Do not Math.max it.

### P2-14
Minimize IndexedDB data.
Delete synchronized data.
Encrypt sensitive data.

### P2-15
Use immutable cache policy for versioned JS/assets where applicable.

### P2-16
robots.txt must block sensitive pages from indexing.

### P2-17
Use window.location.origin instead of LIVE_SITE_URL.

### P2-18
Trusted Device hardening:
- fingerprint
- expiry
- revoke
- maximum device count

### P2-19
Splitting admin_dashboard.html into separate files is deferred.
Do not perform without separate approval.

## OPEN / UNREVIEWED SECURITY ITEMS

### NEW-1
Migration ordering/reconciliation remains owner-controlled.
Do not assume migration order from old reports.

### NEW-2
Security review required for relevant legacy schema_patch SQL files
before production application.

Do not execute them automatically.

### NEW-3
access-control.js requires explicit runtime/permission review.
Do not assume it is equivalent to manual_employee_check.

## PRE-COMMIT CHECKLIST

- [ ] Change is explicitly approved
- [ ] RLS impact checked where relevant
- [ ] README updated at approved documentation stage
- [ ] Audit logging considered where required
- [ ] No secrets included
- [ ] P0 → P1 → P2 priority respected
- [ ] Extracted ZIP folder was NOT turned into a Git repo

## DEFINITION OF PREVENTING REPEATED ERRORS

A problem is only considered prevented when:

1. documented in PROJECT_RULES.md
2. tested automatically where feasible
3. reviewed in CI before merge
4. periodically security-audited

## AI / DEVELOPER RULES

- implement only approved tasks
- do not add unrequested solutions
- do not redesign untouched areas
- do not assume undocumented behavior
- if uncertain: STOP and ask
- follow priority P0 → P1 → P2
- never git init the extracted ZIP working folder
- reconcile final approved changes into the clean Git clone before commit/push

## UI / Dashboard Prevention Rules

### 1. Guard flow direction

- Guard screen displays QR.
- Employee scans QR using employee phone.
- Never document or design the flow as guard scanning employee QR.
- Approved guard instruction:
  "اعرض الرمز للموظف ليمسحه بهاتفه"

### 2. Guard result visibility

- WAITING state may remain compact.
- A real access result must become immediately visible without requiring page scrolling.
- Do not add a manual close/reset if existing reset_guard_screen already restores READY automatically.
- UI changes must not introduce QR fallback.

### 3. KPI responsive rule

- Admin KPI cards must always show title + numeric value.
- Never collapse KPI cards into icon-only mode.
- Decorative pseudo-elements must never obscure KPI content.

### 4. Operational UI vs developer diagnostics

- Developer terminology/methodology must not dominate operational screens.
- Technical explanations should be secondary/collapsed when needed.
- Do not expose implementation terminology such as internal state/data-source names as primary dashboard content.

### 5. Dashboard classification integrity

- Hospital employees:
  registration_category === "PERMANENT" only.
- Temporary/external:
  registration_category === "TEMPORARY" only.
- UNKNOWN / legacy / unlinked records must not be guessed into either category.
- One record must never count as both PERMANENT and TEMPORARY.

### 6. Daily limit selector integrity

- Daily-limit UI must use valid specialty keys matching current specialty-based backend logic.
- Do not populate specialty limits using department-only values.
- Do not add per-employee limits unless backend/RPC support is explicitly approved.
- Do not silently expand admin_upsert_specialty_limit semantics.

### 7. Admin analytics data rule

- New charts must derive from existing real loaded data unless a backend change is explicitly approved.
- Do not fabricate sample production categories/counts.
- Do not add RPC/query/realtime subscriptions for visual redesign without explicit approval.

### 8. Dashboard hierarchy rule

Primary operational analytics must remain visually more prominent than:
- filters
- device detail tables
- offline detail tables
- methodology/debug information

### 9. Responsive validation rule

Before marking a UI page complete:
- test desktop
- tablet
- mobile
- 100% zoom
- confirm no page-level horizontal overflow
- confirm required labels/values remain readable

### 10. Documentation status integrity

- "UI COMPLETE" must not be interpreted as:
  - security audit complete
  - database audit complete
  - production acceptance complete
- Keep completed frontend work separate from unresolved security/backend items.

### 11. Extracted ZIP workflow

- Never git init the extracted working ZIP folder.
- Final approved changes must be reconciled into the clean Git clone before commit/push.
