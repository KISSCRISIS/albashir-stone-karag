# Guard optional profile — 2026-10-10

Owner request: national ID as the only username, phone as password, optional name
and optional profile details including official-uniform picture.

Administrators create/activate the guard using national ID and phone; name may
be empty. The authenticated guard sees a personal-page link even when emergency
entry is disabled. All optional details can remain blank. National ID, phone and
activation cannot be changed by the profile RPC. Photo choice asks for a uniform
portrait; no claim is made that software verifies the uniform.

Existing accounts and their sessions are preserved. Login by name is intentionally
disabled. Database name uniqueness is removed because name is no longer a login
identifier. A separate private RLS table holds bounded optional details and JPEG
photo bytes. Direct SELECT/INSERT/UPDATE is revoked from anon/authenticated.
Both profile RPCs authorize through an active unexpired guard token; write locks
and rechecks prevent concurrent account revocation from being ignored. Session
tokens remain 24 hours, stored without phone or personal fields in localStorage.

Validation: 35 isolated suites passed; browser tests passed for profile image
conversion, blank fields, invalid image and duplicate submissions. Those browser
tests intercept backend traffic. Real Staging rollback SQL verified two unnamed
accounts, national-ID-only login, own-file isolation, photo removal, and revoked
access, leaving no test guards. Mandatory QR and employee decision logic remained
unchanged. Production was not changed.

The published Staging browser was also tested with actual Staging RPCs, without
mocked backend responses: public QR, unnamed-guard national ID login, personal
page navigation, saving/reopening optional details and a converted photo, photo
removal and access denial after admin deactivation all passed. Zero Production
requests occurred. The synthetic guard was disabled, then removed; its cascaded
profile/session were removed, and verification found zero fixture guards/profiles
and five original employees. Audit records retain the synthetic test history.

Security advisors report the expected RLS-without-policies notice on the closed
private table and SECURITY DEFINER notices on token-authorized RPCs. Direct table
grants remain revoked; the scoped token checks are covered by regression.
See [the RPC advisory explanation](https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable).

Owner acceptance: create a guard with national ID/phone and no name; log into the
guard screen; open the personal page; optionally enter name/residence/age/about,
select a uniform photo and save; return and reopen the profile; verify retained
details; test removing the photo; disable guard from admin and check access denial.
Staging is ready for acceptance; Production remains blocked pending acceptance.
