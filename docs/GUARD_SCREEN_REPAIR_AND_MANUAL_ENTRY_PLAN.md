# Guard screen repair and emergency manual-entry implementation plan

Status: diagnosis only; no Production changes.

## Findings
- `guard.html` issues public QR via `create_public_guard_qr`; screenshot shows valid QR.
- `index.html` requires approved gate device via `upsert_gate_device_heartbeat` before `create_qr_session`; screenshot shows unavailable state.
- An unavailable message alone does **not** prove the device is unapproved. Network, missing device credentials, RPC errors, or a timeout may produce the same UI.
- Do not delete or redirect `index.html` until references, operational users, and deployment routes are audited.
- Public `guard.html` does not authenticate a guard. Adding a searchable employee directory there without a new server-enforced authorization flow would expose private personal data.

## Diagnostic checklist (read-only)
1. Reproduce on the affected phone and capture timestamp, URL, online state, and visible error.
2. Review browser console/network for `upsert_gate_device_heartbeat` status and response; redact tokens and employee data.
3. Check the matching gate-device approval/revocation state in Supabase, using minimal read-only fields.
4. Compare `create_public_guard_qr` health independently; never bypass heartbeat in `index.html`.
5. Inventory links to `index.html` and confirm with owner whether to retain legacy approved-device mode.
6. Test on staging and real phone before any Production change.

## Manual emergency-entry design (requires separate approval)
- Place a button below QR in `guard.html`; QR remains the default.
- Button opens a guard authorization step (server-verified credentials or approved guard-device capability), **before** accepting employee identifier or returning any employee data.
- Only while a server-authorized emergency mode is active, a guarded lookup returns minimum data: name, short-lived private photo, job/specialty, and effective ALLOWED/LIMITED/DENIED outcome.
- Compute decisions on server using employee status, trusted-device policy as applicable, specialty rules and daily limits. No direct public table SELECT or unauthenticated employee enumeration.
- Require explicit identity-match confirmation before a separate one-time entry commit. Both lookups and commits are audited, rate-limited, and protected against replay.
- Never call `manual_employee_check` without QR: current mandatory-QR policy remains unchanged.
- A full Supabase outage needs an independently approved offline policy; online lookups cannot work then.

## Acceptance
- Public QR refresh and result display remain unaffected.
- Unauthorized requests return no employee identity or photo.
- Denied, pending, unknown, revoked, expired emergency session and repeated commits fail closed.
- ALLOWED and LIMITED match existing business policy; daily limits remain enforced atomically.
- Mobile viewport tests, staging integration, and real-device tests pass.
- No production merge, schema change, or deployment before explicit approval.
