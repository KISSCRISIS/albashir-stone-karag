# Private Employee Photos Architecture

Branch: `security/private-employee-photos`
Status: **prepared for review — nothing applied to Production, nothing deployed.**

This document describes the storage security boundary change for employee
photos, the code that implements it, the tests that verify it, and the exact
rollout order.

---

## 1. The problem

| Before | Risk |
|---|---|
| `employee-photos` bucket was `public = true` | every object was readable by anyone who knew or guessed the URL |
| `Anyone can read employee photos` policy (`select` to `anon`, `authenticated`) | the entire bucket was listable/readable through the public Storage API |
| `Anyone can upload employee photos` policy (`insert` to `anon`, `authenticated`, no conditions) | unlimited, unvalidated uploads of any type and size |
| `register.html` called `getPublicUrl()` and stored the URL in `employee_registrations.employee_photo_url` | a permanent, unauthenticated link to an employee's photo was persisted in the database and rendered on the guard screen, the employee profile and the admin dashboard |

Confirmed against live Production before the change:

```
storage.buckets: employee-photos -> public = true, file_size_limit = null, allowed_mime_types = null
storage.objects policies: "Anyone can read employee photos" (SELECT, anon+authenticated)
                          "Anyone can upload employee photos" (INSERT, anon+authenticated)
employee_registrations.employee_photo_url: https://<ref>.supabase.co/storage/v1/object/public/employee-photos/registrations/80632/....jpeg
```

---

## 2. The target boundary

```
Browser (guard screen / employee phone / admin)
        |  credentials: employee id + phone, trusted-device token,
        |               gate-device code + token, or admin session
        v
employee-photo-url resolver  (Supabase Edge Function, service role, server-side only)
        |  1. normalise + validate the photo reference
        |  2. verify the actor against the database
        |  3. enforce ownership (employees may only read their own photo)
        |  4. confirm the object exists
        |  5. createSignedUrl(path, 60)
        v
60-second signed URL  ->  <img src="...">   (no permanent link exists anywhere)
```

Storage state after the change:

- `employee-photos.public = false`
- `file_size_limit = 2097152` (2 MiB), `allowed_mime_types = jpeg, png, webp`
- exactly one policy: `Registration can upload employee photos` (`insert` to
  `anon`, `authenticated`, constrained by folder + extension + MIME + size)
- **no** `select`, `update` or `delete` policy for `anon` / `authenticated`
- the database stores an **object path** (`registrations/<id>/<file>.jpg`),
  never a URL

---

## 3. Phases

### Phase 1 — Storage boundary
`supabase/migrations/20261006190000_private_employee_photos.sql`

- bucket flipped to private with server-side size and MIME limits
- the two permissive policies are dropped
- one constrained upload policy replaces them (same pattern already used by
  `violation-photos`)

### Phase 2 — Upload
`register.html`

- `upload` → **save object path** (no `getPublicUrl()`, no `data.publicUrl`)
- client-side guards mirror the server limits (type, extension, 2 MiB)
- the path is registered in the pending-upload ledger (best effort)

### Phase 3 — Access
`supabase/functions/employee-photo-url/` + `employee-photo.js`

- the resolver described above, plus a shared browser client that hydrates
  `<img data-photo-ref="...">` elements and caches signed URLs in memory only,
  for at most `60s − 10s` of clock skew
- wired into `index.html` (guard screen), `guard.html`, `verify.html`,
  `register.html`, `profile.html` and `admin_dashboard.html`
- `verify-shared.js` renders photo references instead of `src` URLs

### Phase 4 — Cleanup
`private.pending_employee_uploads` + `public.employee_photo_sweep_candidates()` +
`public.employee_photo_confirm_removal()`

- the ledger records every upload (`PENDING` → `LINKED` when a registration
  references it)
- the sweep proposes only objects that are older than the retention window and
  are neither linked nor referenced by any registration
- the SQL side never deletes bytes (only the Storage API can); the resolver's
  `sweep` action performs the removal and then confirms it back
- a `SUPER_ADMIN` session is required, and `dry_run` is the default

### Phase 5 — Tests
`tests/private-employee-photos.cjs`, `tests/employee-photo-resolver.cjs`,
`tests/employee-photos-static.cjs`, `tests/employee-photo-client.cjs` — see §7.

---

## 4. Ownership model

| Actor | Credential | Scope |
|---|---|---|
| `admin` | Supabase Auth session token | any employee photo (review workflow) |
| `employee` | employee id + phone | **own photo only** |
| `employee_device` | trusted-device token | **own photo only** |
| `guard_device` | gate-device code + token | any employee photo (gate display) |

Ownership is a folder check: the object must live under
`registrations/<employee folder>/`, where the folder is the same sanitised
employee identifier the registration page already uses. A guard or admin
credential never grants a write, and an employee credential never grants access
to another employee.

New service-role-only RPCs (not part of the client API surface):

- `public.verify_gate_device_credentials(device_code, device_token)` — read-only
  counterpart of `get_guard_employee_result(text, text, text)`; keeps the
  existing auth-failure audit.
- `public.verify_trusted_device_credentials(device_token)` — read-only
  counterpart of `trusted_device_profile_login(token)`; deliberately performs no
  write and no `FAST_LOGIN` audit insert, so resolving a photo never looks like a
  login and never floods `admin_audit_logs`.

Both are `revoke`d from `PUBLIC`, `anon` and `authenticated` and granted to
`service_role` only. `verify_gate_device_credentials` reuses
`hash_offline_device_token()` and the `offline_device_tokens` checks exactly as
the existing guard RPC does.

---

## 5. Backfill

Legacy rows stored a public URL. The migration converts parseable values to
object paths:

```
https://<ref>.supabase.co/storage/v1/object/public/employee-photos/registrations/80632/a.jpeg
  -> registrations/80632/a.jpeg
```

Values that cannot be interpreted are **left untouched** so they can be reviewed
by hand. The migration prints a non-fatal warning with both counts and documents
the required post-apply check:

```sql
select count(*) from public.employee_registrations
where employee_photo_url like 'http%';   -- must return 0
```

Measured on Production on 2026-10-06, before applying anything:

| Measurement | Value |
|---|---|
| rows in `employee_registrations` | 2 |
| values matching `http%` | 2 |
| `/object/public/employee-photos/` URLs | 2 |
| `/object/sign/employee-photos/` URLs | 0 |
| object paths (`registrations/%`) | 0 |
| values that cannot be interpreted | **0** |

Both legacy rows are ordinary public bucket URLs (created 2026-09-28), so the
backfill converts both and the post-apply check reaches **0** without manual
intervention. The only other photo column in the schema is
`violation_reports.photo_url`, which belongs to a different bucket and is out of
scope.

---

## 6. Cache and retention of the signed URL

A signed URL is a bearer credential for 60 seconds, so it must not survive in any
cache. What the code guarantees today:

| Layer | Behaviour | Evidence |
|---|---|---|
| Client memory | URL cached in a `Map` only, for `60s - 10s`, never persisted | `tests/employee-photo-client.cjs` |
| Browser HTTP cache | fetched with `cache: "no-store"`, `credentials: "omit"`, `referrerPolicy: "no-referrer"` and displayed as a same-origin `blob:` URL, so the credential never becomes an element `src` | `tests/employee-photo-client.cjs` |
| Service worker | `*.supabase.co`, `/auth/`, `/rest/` and `/storage/` requests are network-only and reach no `cache.put` | `tests/employee-photos-static.cjs` |
| Persistent storage | no `localStorage`, `sessionStorage` or `document.cookie` use | `tests/employee-photos-static.cjs` |
| Blob lifetime | blob URLs are revoked on replacement and on `clearCache()` | `tests/employee-photo-client.cjs` |
| CSP | `img-src` allows `blob:`, `connect-src` allows `*.supabase.co` | `tests/employee-photos-static.cjs` |

If the no-store fetch fails, the image shows its configured placeholder or is
hidden. Thumbnail links also use a no-store blob URL; no signed URL is assigned
to src or href. Credential changes use separate in-memory authorization cache
entries. Session replacement/logout clears displayed blobs and invalidates pending
resolver and image requests. Storage/CDN headers and HTTP expiry remain Staging
acceptance checks; these local changes do not prove either live property.

---

## 7. What is verified offline

`npm ci --prefix tests && npm --prefix tests test` (PGlite 0.5.8, Node 22, no
Production calls, no real photo, employee or device).

**`tests/private-employee-photos.cjs`** — executes the real migration and the
real rollback against a Production-shaped schema:

| Check | Result |
|---|---|
| anonymous read blocked | PASS (RLS returns 0 rows) |
| authenticated object SELECT blocked by RLS (not an HTTP URL test) | PASS |
| unrelated `violation-photos` isolation preserved | PASS |
| invalid MIME rejected | PASS |
| disallowed extension rejected | PASS |
| upload outside `registrations/` rejected | PASS |
| oversized upload rejected | PASS |
| anonymous update/delete has no effect | PASS |
| legacy public URLs backfilled to paths | PASS |
| ledger unreachable from `anon` / `authenticated` | PASS |
| registration trigger links the ledger entry | PASS |
| sweep protects linked and recent objects | PASS |
| sweep requires service role; retention floor enforced | PASS |
| device/employee verification RPCs are service-role only | PASS |
| rollback restores the previous boundary and removes every new object | PASS |
| migration is idempotent and re-applies after a rollback | PASS |
| post-apply check `employee_photo_url like http%` reaches 0 | PASS |

**`tests/employee-photo-resolver.cjs`** — mocked Storage API:

| Check | Result |
|---|---|
| signed URL lifetime is exactly 60 s | PASS |
| signing called for the authorized actor with TTL=60 (mock only) | PASS |
| actual signed URL HTTP fetch and expiry rejection | NOT RUN — Staging required |
| employee cannot resolve another employee's photo; 403 has no reason | PASS |
| wrong credentials, unknown actor, missing credentials denied | PASS |
| malformed reference rejected before signing | PASS |
| missing object not signed | PASS |
| signing failure / verification exception fail closed and leak nothing | PASS |
| sweep requires `SUPER_ADMIN`, dry run by default, inputs clamped | PASS |
| responses never contain credentials or service keys | PASS |

**`tests/employee-photo-client.cjs`** — browser client with a fake DOM, fake fetch and fake clock:

| Check | Result |
|---|---|
| signed URL is fetched with `cache: "no-store"` and displayed as a blob URL | PASS |
| a blocked no-store fetch shows a placeholder; thumbnail links use blobs | PASS |
| denied photos trigger no storage request and fall back or hide | PASS |
| the in-memory cache expires 10s before the URL does | PASS |
| blob URLs are revoked on replacement and on `clearCache()` | PASS |
| `localStorage` / `sessionStorage` / `document` access raises | PASS |

**`tests/employee-photos-static.cjs`** — source guarantees:

| Check | Result |
|---|---|
| no `getPublicUrl()` remains | PASS |
| no page builds a public employee-photos URL | PASS |
| every photo page loads the resolver client | PASS |
| registration stores an object path only | PASS |
| migration keeps reads closed and writes constrained | PASS |
| rollback reopens the previous boundary | PASS |
| handler fixes the TTL at 60 s; service key stays server-side | PASS |
| service worker never caches signed storage responses | PASS |
| client never persists the signed URL; CSP supports the blob path | PASS |

### What is **not** verified offline

The local tests do not execute actual Storage HTTP reads, signed-token expiry,
real browser uploads/rendering, camera/QR flows, or Production data. In particular,
MIME/extension checks do not prove rejection of an executable renamed to JPG with
spoofed `Content-Type: image/jpeg`; there is no server-side byte validation in the
current upload path. This is an unresolved acceptance condition, not a PASS.

The four real-Storage checks are recorded in
`docs/EMPLOYEE_PHOTOS_STAGING_ACCEPTANCE.md`. All remain **NOT RUN**. Fixed TTL=60
is a local code guarantee, not evidence that an old signed URL is rejected over
HTTP after expiry.

---

## 8. Review and rollout gates

Keep this branch/PR separate from `security/trusted-device-enrollment-hardening`:
the two changes govern different security boundaries.

1. Obtain repository write authorization, push the feature branch, open its
   independent PR, and require CI evidence. Local tests do not count as CI.
2. On an explicitly identified **Staging** project only, review and install the
   migration and deploy the resolver plus a frontend configured for that project.
   The resolver depends on verification RPCs introduced by the migration: it is
   not fully ready merely because the Edge Function deploys successfully.
3. Complete the four real Storage acceptance checks in
   `docs/EMPLOYEE_PHOTOS_STAGING_ACCEPTANCE.md`. Keep results NOT RUN until actual
   evidence exists. If pre-merge acceptance is required, use the PR version in
   Staging; merging code does not authorize Production deployment.
4. Production application requires owner review/confirmation and successful
   Staging acceptance of the same revision. Do not promise a zero-interruption
   rollout for the current single migration: it adds resolver dependencies and
   flips the bucket boundary together. A coordinated deployment window or a
   separately reviewed staged migration strategy is required.
5. Keep orphan deletion disabled until a reviewed dry run is clean. No recurring
   sweep schedule is created here.

Rollback: `supabase/rollback/20261006190000_private_employee_photos_rollback.sql`
(manual; kept outside `supabase/migrations/` so a forward push can never run it).
It restores the public bucket and the previous policies. Objects already removed
by a sweep cannot be restored — that is why `dry_run` is the default.

---

## 9. Residual risks (documented, not hidden)

1. **Upload spam** — the upload policy is anonymous by necessity (registration is
   public). It is bounded by folder shape, extension, MIME and 2 MiB, and the
   ledger plus sweep remove abandoned objects. A determined actor can still fill
   the bucket within those limits; a per-IP rate limit would need infrastructure
   outside this repository.
2. **Signed URL sharing** — a signed URL is a bearer token for 60 seconds. It is
   never stored in `localStorage`/`sessionStorage`, only in memory, and it is
   scoped to a single object.
3. **Resolver availability** — if the Edge Function is unavailable, photos fall
   back to `logo.jpeg` (guard/profile/verify) or are hidden (admin table). No
   permanent URL is reintroduced as a fallback.
4. **Legacy public URLs in other systems** — any external copy of an old public
   URL stops working once the bucket is private; that is the intended effect.
5. **MIME spoofing** — upload validation currently checks declared type, extension
   and size, not server-side decoding of bytes. Renamed executable rejection is
   an unresolved Staging gate; do not label this requirement complete.
6. **`admin_dashboard.html` was not split** — per `PROJECT_RULES.md` P2-19, this
   change does not restructure the file.

---

## 10. Files

| File | Change |
|---|---|
| `supabase/migrations/20261006190000_private_employee_photos.sql` | new — bucket, policies, backfill, ledger, sweep, verification RPCs |
| `supabase/rollback/20261006190000_private_employee_photos_rollback.sql` | new — manual rollback |
| `supabase/functions/employee-photo-url/{handler.mjs,index.ts,README.md}` | new — resolver |
| `employee-photo.js` | new — shared browser client |
| `register.html` | upload stores a path; client guards; photo hydration |
| `verify-shared.js` | renders photo references; hydration helper |
| `index.html` | guard screen resolves photos with device credentials |
| `guard.html`, `verify.html` | hydrate with device / employee credentials |
| `profile.html` | resolves the employee's own photo |
| `admin_dashboard.html` | registration thumbnails resolved as an admin |
| `service-worker.js` | precache the client; cache version v17 |
| `tests/{private-employee-photos,employee-photo-resolver,employee-photos-static,employee-photo-client}.cjs` | new — Phase 5 |
| `tests/guard-rpc-hardening.cjs` | migration inventory updated |
| `tests/package.json` | new tests wired into `npm test` |
| `docs/PULL_REQUEST_PRIVATE_EMPLOYEE_PHOTOS.md` | new — PR description |
| `PROJECT_RULES.md` | P0-7 employee photo privacy |
