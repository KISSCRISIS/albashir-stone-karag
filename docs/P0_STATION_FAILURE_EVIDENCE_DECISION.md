# P0 security design decision — QR generation failure evidence

## Verified on Staging (read-only)
- `guard_set_emergency(p_token,p_enabled)` currently toggles one global setting for all guards and stations.
- `guard_manual_employee_entry(p_token,p_employee_id,p_request_id)` checks that global setting but not the requesting station or independently verified outage.
- `create_public_guard_qr()` has no station argument or server-issued station identity. It can succeed on the server even when canvas rendering fails locally.

## Unresolved security requirement
The approved emergency trigger is **failure to generate/display a QR on the affected guard phone**, not failure to poll or lack of connectivity. Browser-controlled flags, request counts, or client error reports cannot independently prove local rendering failure. A backend health check can prove a backend failure but not that the phone's QR renderer failed.

## Proposed secure approach requiring owner decision
Use authenticated, server-registered station credentials and a station-scoped, short-lived emergency lease. A trusted supervisor or independently attested station agent must authorize local-renderer-failure leases; backend-observed generation failures may grant leases automatically if attributable to the station. Never accept browser-only failure reports as proof. Do not require trying a second phone.

On every manual request, require active guard session + valid station credential + unexpired outage lease + employee number + request id. Immediately revoke lease on verified QR recovery. Apply existing employee decision and atomic quota enforcement.

## Release gate
Do not deploy the UI-only patch as a security fix or activate global emergency mode. The evidence source for local rendering failure must be resolved and implemented before release.
