# Shared guards and administrator notices — Staging acceptance

Owner authorized this transition and its database additions on 2026-10-10, for Staging only. Existing dashboard shifts are retained: A 07:00–15:00, B 15:00–23:00, C 23:00–07:00, Asia/Amman.

- A temporary shared guard account supports concurrent sessions. Its numeric password is configured by the owner and stored only as a bcrypt hash. Individual optional applications require national ID and phone; name, age, residence, about and re-encoded JPEG portrait are optional. Approval creates a separate active personal account; rejection creates none. Shared profile editing is denied.
- Guard sign-ins are recorded. The QR header restores the signed-in guard's small photo, name and time. QR remains public through limited RPCs; ordinary employee QR rules and `manual_employee_check` are unchanged. An authenticated guard or administrator can activate emergency entry, with an audit record; counted entry and retry idempotency use the existing emergency RPC.
- Dashboard retains request cards, six interactive KPIs, sidebar CSV selection, renamed reports and removed obsolete guard/copy-registration shortcuts.
- Administrator events are private and filtered by active account/topic permissions. Read receipts, per-account sound preference and device subscription are saved. Foreground feed polls every ten seconds. Database cron ticks every minute, produces deduplicated shift/limit notices and dispatches queued Web Push. Notifications contain generic messages, never employee identities or photos.
- Browser notification activation requires a user gesture and permission. Unsupported or denied Push keeps foreground notices working. On supported iPhones background Push requires adding the app to the Home Screen. System notification sounds are controlled by the operating system; the dashboard uses its existing chime.

## Deployment and validation

Staging project: `adwvokwucotohwayorgx`. Frontend cache v30. Applied additions: `guard_shared_registration_admin_alerts`, followed by `guard_notice_dispatch_permissions`. Canonical SQL and fresh-install baseline include both. The second addition revokes network-extension access from frontend roles and adds profile-change notices and audited guard emergency activation.

Dispatcher: `admin-notice-dispatch`, `@supabase/server@1.9.1`, publishable-key authentication plus a separate server-only scoped dispatch credential. Missing credential receives 403. VAPID private key stays in private server configuration; dispatch credential is held in Vault. No credentials are included in frontend, repository, CSV or notification payloads. Production was not modified.

Validation: isolated SQL suites and browser regressions pass. Actual Staging browser testing confirmed two simultaneous shared logins, restoration, optional request with decoded JPEG, administrator approval, personal sign-in/photo/time, notice feed, public QR/countdown and zero Production requests. The synthetic personal account/application/notice is removed after testing; audit history remains. Live dispatcher returned 200 and rejected calls without its credential; scheduled jobs succeeded. Actual background delivery to an administrator's phone remains a user-device acceptance step after permission is granted.

Private tables have RLS and no direct anon/authenticated grants; internal helpers are not executable by frontend roles. Security advisors report intentional token-gated RPCs and deny-all private tables, alongside existing unrelated project warnings. No broad permission relaxation was made. Employee decision definition hash stayed `f0e750e4abb2bf97f20999264684341f`.

## Owner test

1. Open the direct Staging guard URL, choose shared login, enter the separately provided credentials. QR needs no account.
2. Open the personal profile and optionally send a personal application. Approve it in guard management, then sign in using that national ID and phone.
3. In the administrator sidebar open Notifications and press “تفعيل تنبيهات هذا الجهاز”. Grant permission. Confirm foreground sound/text and a new-request notification with the installed app closed.
4. Confirm next shift summary and daily-limit notice. Explicit dashboard logout disables that device's server subscription.

Keep this rollout on Staging pending owner device acceptance; do not deploy these migrations or dispatcher secrets to Production automatically.
