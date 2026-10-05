# ALBASHIR Gate 24/7 Operations Checklist

This project is designed for a hospital gate screen that runs continuously with QR verification, Supabase RPCs, offline cache support, and role-based access.

## Production Reliability Rules

1. QR refresh must stay active every 30 seconds.
2. Only one QR creation request should run at a time.
3. If QR creation fails, the screen keeps the last visible QR and retries automatically.
4. Supabase RPC calls are the trusted source for QR sessions and verification.
5. Network failures must not crash the gate screen.
6. Offline cache must never cache Supabase API responses.
7. Employee identity data must be protected by roles and RLS.
8. Admin and super admin actions must stay behind role checks.

## Gate Screen Health Indicators

The gate screen shows:

- Last successful QR update.
- Current QR refresh status.
- Total QR refresh attempts.
- Consecutive QR failures.
- Last error or operational note.

These indicators are intended for fast diagnosis by the technical team without opening developer tools.

## Required Acceptance Tests Before Live Use

1. Long run test: keep `index.html` open for at least 8 hours and confirm QR continues refreshing.
2. Shift pressure test: run `qr_load_test_100.js` (repository root) only against staging or with explicit production approval.
3. Network loss test: follow `offline_sync_10_minute_check.md` and confirm `synced_count` does not count duplicate client logs.
4. Cache update test: change `CACHE_VERSION`, redeploy, and confirm updated files load after refresh.
5. Role test: confirm SUPER_ADMIN, ADMIN, GUARD, and EMPLOYEE only see their allowed pages.
6. Data privacy test: confirm employee phone and sensitive details are not exposed on the guard display.

## Deployment Notes

- Do not upload `setup_sub_admins.sql`, local screenshots, temporary reports, or private CSV snippets.
- Do not place a Supabase service-role key in any HTML or JavaScript file.
- Apply SQL patches in the order documented in `README.md`.
- For public hosting, serve over HTTPS so camera access, service worker, and PWA features work reliably.
