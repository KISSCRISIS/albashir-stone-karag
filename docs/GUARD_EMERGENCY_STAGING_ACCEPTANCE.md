# Guard emergency entry — owner-approved 2026-10-10

Staging backend migration: `20261009230333_guard_accounts_emergency_entry.sql`.
Staging frontend: `dpl_7QssiNg2bXbGabuhEfuHmf9gef3v`, version `750c57c24472`,
cache v25. Production is unchanged.

The public guard QR display still needs no login or gate-device approval.
Manual emergency entry requires a guard profile created by SUPER_ADMIN, and
simple login using name OR national ID plus phone number. Phone is treated as
the owner-selected credential, not as proof of phone ownership. It is stored
only as a salted bcrypt hash. Login is rate-limited; sessions expire after 24
hours and account edits/disable revoke them. The browser stores only the opaque
session token, never the phone number.

SUPER_ADMIN creates/edits/disables profiles under **ملفات الحراس والدخول اليدوي
للطوارئ** in the existing admin dashboard. Emergency mode starts disabled;
the administrator enables it when QR display/scanning is unavailable. A full
Supabase outage cannot support online manual decisions.

An authorized guard enters the employee ID only. The server invokes the existing
decision function with a server-only, single-use QR issued after authorization;
the guard does not scan it and the token is never returned. This preserves the
existing status, trusted-device, specialty and daily-limit logic without copying
it or changing `manual_employee_check`. Approved permanent entries are logged;
limited entries consume the existing specialty allowance. A stable request UUID
prevents retrying a lost response from consuming another visit. A different
employee under the same request UUID is denied. Guard identity/request/result
are audited, and private session-scoped photos reuse the existing resolver.

The result replaces QR for ten seconds, then name/photo/job/specialty and the
employee input are cleared. No public employee directory or search suggestions
are exposed. Anonymous/manual requests without a valid active guard session
receive no employee data. All five new private tables have RLS and no direct
anon/authenticated SELECT, INSERT or UPDATE grants.

Validation completed:
- 34 isolated suites PASS, including the complete fresh-install SQL.
- Actual Chromium UI with mocked backend: simple login, remembered session,
  duplicate submit, same retry UUID, result replacement and ten-second clearing.
- Existing employee QR journey and responsive/expiry/heartbeat browser checks PASS.
- Real Staging SQL smoke PASS in a rollback-only transaction: actual entries,
  duplicate request, daily-limit denial, pending denial and guard revocation.
- Published Staging QR, countdown, login form and unauthorized manual-entry
  denial PASS; zero Production requests.
- Existing decision function MD5 remains f0e750e4abb2bf97f20999264684341f.
- Original five employees remain; zero temporary guard/employee fixtures.

The combined live browser/fixture test was NOT completed: Supabase connector
rejected persistent fixture setup twice with `Invalid or expired requestState`.
Cleanup succeeded after both failures. This is a test-connector limitation;
do not describe the combined live test as PASS.

Security advisor INFO for RLS-without-policies is expected on closed private
tables. SECURITY DEFINER warnings require reviewing custom authorization rather
than opening table policies or removing necessary RPC grants. See the
[Supabase function advisor](https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable).

Owner acceptance before Production:
1. Sign into Staging admin, create a real guard profile and enable emergency mode.
2. Open the direct guard link on the guard phone/tablet; confirm QR before login.
3. Select manual entry, log in with name/national ID and phone, then enter an
   approved test employee ID. Confirm decision/photo/job/specialty and ten-second reset.
4. Confirm one gate log/one allowance consumption, a denied entry at the limit,
   restoration after reopening the browser, and denial after disabling the guard.
5. Obtain Production approval for this new authorized emergency path and enable
   it only after backend/frontend rollout verification. GO for Staging testing;
   BLOCK for Production until acceptance.
