# Project audit and bounded repair — 2026-10-07

## Scope and evidence
Reviewed current branch runtime pages/scripts, local assets/navigation, Service Worker, CSV export, regression/CI configuration, upload/login error paths, tracked-secret patterns and npm lock dependencies. Read-only live metadata/body/policy review covered Supabase Staging and Production. No real employee rows were retrieved, no Production QR was consumed and no SQL/DDL or Production deployment was performed. This is a bounded audit, not proof that every possible vulnerability is absent.

## Repairs
- Registration-copy shortcut now opens register.html on the current deployment; old verify.html?register=1 had no registration handler.
- CSV exports neutralize string cells starting with formula characters, including leading controls/whitespace; numeric values remain numeric and CR is quoted.
- Service Worker stores navigation page shells under paths without credential-bearing queries, skips non-200 pages, logs failed cache writes, and keeps third-party responses network-only. Supabase/POST network-only and same-origin network-first are preserved. Cache v19 retires old entries.
- Login handlers support submit events without a submitter. Fast-login transport failures enter the visible error path rather than silently returning.
- Upload orphan-ledger transport/returned/exception failures are logged without object path or credentials; successful registration remains possible under the existing best-effort policy.
- Removed the remaining alternate guard destination regex from portal routing. Public navigation still does not disclose the direct guard page.
- The existing frontend QR/heartbeat/layout regression now matches current policy and is run in CI using locked Playwright 1.62.1.
- Supabase CLI metadata is ignored rather than accidentally committed.

## Validation
19 isolated regression suites PASS. Browser QR failure/absolute expiry/heartbeat checks PASS. Chromium layout emulation at 320, 375, 390, 430, 568x320, 844x390 and 1024x768 PASS. Script/JSON syntax and local asset link scan PASS. npm audit including dev dependencies: 0 reported vulnerabilities. Tracked secret scan: 115 files, no embedded secret key/private key/service-role JWT found (publishable keys are intentional). This does not audit Git history, external secrets or vendored library vulnerability databases.
Latest live Staging browser outcomes and CI are recorded in the completion report. Real-phone acceptance is owner-operated; previous photo failure remains pending latest-build confirmation.

## Live security findings and interpretation
Both environments: employee-photos and violation-photos public=false. Legacy reset_guard_screen() and get_guard_employee_result(text) deny anon/authenticated EXECUTE. Device-bound replacements remain available. Sensitive public tables have RLS. Production employee registration SELECT is constrained to authenticated administrators, and change-request SELECT requires is_admin(); grants alone do not prove data exposure. security_attempt_logs has RLS with no SELECT policy, which intentionally denies direct reads.
private.pending_employee_uploads has no RLS but also no anon/authenticated SELECT grants; service-only schema access is intentional. No-policy claims/QR/session tables are fail-closed, not missing an access policy to add blindly.
Production has no mutable-search_path advisor finding. Staging has six: default_admin_permissions, hash_trusted_device_token, normalize_specialty_name, is_permanently_allowed_specialty, hash_offline_device_token, sync_trusted_device_activity. The five previously reviewed Production fixes should be reconciled to Staging; the sixth requires complete body/dependency review. No automatic migration created.
SECURITY DEFINER caller warnings include intentional public, internally authenticated RPCs and safe-deny legacy bodies. Do not revoke them wholesale. Production write_security_attempt is callable by anon/authenticated and accepts caller-supplied outcome/action, permitting fabricated audit entries; Staging already denies these direct grants. Compare scoped ACL baseline and callers before coordinated Production repair. cleanup_expired_qr_sessions is callable without auth and deletes only rows expired over 10 minutes; it is a maintenance exposure to review, not an active QR bypass.
Legacy Production register_trusted_device(text,text,text) still links from employee ID/mobile without fresh QR proof. Current Staging candidate closes obsolete enrollment paths; Production P2-18 is therefore not CLOSED before coordinated rollout.
Supabase reports leaked-password protection disabled in both environments; enabling it requires verifying Auth plan/support and the approved account policy. No Auth configuration changed.

## Remaining gates
Coordinated Production review/deployment still required for PR #5 backend/frontend changes and token invalidation. Real iPhone photo and registration -> administrator approval -> same-device fast login acceptance remain required. Historical secret/key exposure and external legacy service_role integration inventory are not settled by a working-tree scan. Do not disable legacy JWT keys.
No claim of real-device tests, full penetration testing, staging-to-production parity or unrestricted Production readiness is made.
