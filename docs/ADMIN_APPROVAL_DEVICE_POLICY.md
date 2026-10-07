# Owner decision — 2026-10-07

Administrator approval activates the token and device fingerprint submitted with the registration request, for 30 days. No additional QR enrollment step is required for that submitted device. This supersedes the earlier P2-18 policy requiring a fresh QR claim to activate a registration-time device.

QR validation and consumption remain mandatory for gate access. Device binding, expiry, revocation and legacy enrollment denial remain enforced. Existing accounts without a submitted pending device are not automatically enrolled. A different browser cannot obtain a device binding from employee ID and phone alone.

The scoped migration replaces only `admin_update_registration_status(uuid,text)` and `trusted_device_profile_login(text,text)`. It changes no tables, RLS, grants, validator or `manual_employee_check`. Pending device login returns no profile/session and preserves the browser token while the administrator reviews the request.

Full isolated regression suite PASS. Staging applied; Production NOT applied. Production rollout must include this final override after the three original P2-18 migrations; do not deploy their intermediate policy as the final state. PR remains draft until coordinated Production approval and acceptance. Earlier claim-based enrollment remains available for eligible existing accounts, but is not required for a newly approved submitted device.
