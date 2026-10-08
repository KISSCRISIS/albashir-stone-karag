# Production rollout — 2026-10-08

Owner confirmed phone photo, automatic QR and home-screen shortcut acceptance and approved actual deployment. Owner explicitly declined invalidation of the two existing device bindings.

PR #10 combines PRs #5–#9, with the Production ACL restrictions, disabled violation UI and Add Admin button retained. It merged to main as `40e97d0f08989d5e4f76ebd310dbd79c29c4056c` after successful CI and 29 isolated regression suites. Chromium/WebKit hosted Staging checks passed manual-first-to-next-automatic verification, session restoration in a new tab, image failure/retry, both-party pictures and 10-second guard clearing.

Supabase Production `qinsfvlspdticposbvst` received the reviewed preserving transaction, not the historical device-reset statements or fresh-install baseline. The transaction compared every original employee field with its snapshot and aborted on unexpected changes. Post-check: two bindings, two active fingerprint-bound indefinitely approved devices. Existing token hashes, device identifiers, enabled/revoked state, identity and employee status were preserved. `manual_employee_check(text,text,text)` remained MD5 `f0e750e4abb2bf97f20999264684341f`.

The photo Resolver is ACTIVE version 2, authenticates the actor itself, supports device_id and session-bound public guard capabilities, and keeps Storage private. Admin RPCs remain unavailable to anon; internal logging/QR-consumption helpers remain unavailable to anon/authenticated. Claims, verification requests and public guard sessions have RLS and no direct anon/authenticated SELECT.

Live Production synthetic SQL smoke passed anonymous database-issued QR, claim, employee verification, idempotent retry, guard result synchronization, changed-payload denial and fail-closed legacy enrollment. All synthetic fixture writes were rolled back; leftover test employees = 0. Browser smoke verified Production portal/dialog, direct guard QR/countdown, absence of guard navigation, Production backend/cache v22 and denied unauthorized photo requests. It did not authenticate any real employee or claim an independent real-phone Production test.

The automatic repository-root deployment exposed SQL files as static artifacts during the post-deployment audit. The public runtime build now allowlists application pages/assets and excludes SQL, canonical/migrations, documentation, tests, scripts and credentials. A follow-up regression verifies those artifact boundaries while retaining guard.html for direct-link use. The subsequent clean deployment must return 404 for repository sources. This report supersedes the remaining Staging phone-acceptance/Production-approval gates in earlier dated reports.

Public employee portal: https://albashir-stone-karag.vercel.app/portal.html

Direct guard link: https://albashir-stone-karag.vercel.app/guard.html
