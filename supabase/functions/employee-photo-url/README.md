# employee-photo-url

Resolver for the private `employee-photos` bucket. It verifies the caller, then
mints a **60-second** signed URL for exactly one object.

- `handler.mjs` — all logic, no runtime dependencies (unit-tested offline).
- `index.ts` — Deno entry point that wires Supabase clients into the handler.

## Contract

```http
POST /functions/v1/employee-photo-url
apikey: <publishable key>
content-type: application/json

{ "action": "resolve", "path": "registrations/80632/1790627850001-7df3b32a22b418.jpeg",
  "actor": { "type": "employee", "employee_id": "80632", "mobile_number": "0790000000" } }
```

```json
{ "ok": true, "url": "https://<ref>.supabase.co/storage/v1/object/sign/...", "expires_in": 60, "expires_at": "..." }
```

Authorization failures return HTTP `403` with exactly
`{ "ok": false, "error": "DENIED" }`: no ownership or credential-validity reason
is exposed. Other failures may include a fixed error code at `400`, `404`,
`405` or `500`; exception messages are never echoed.

Real Storage acceptance remains NOT RUN; see
`docs/EMPLOYEE_PHOTOS_STAGING_ACCEPTANCE.md`.

### Actor types

| `actor.type` | Credentials | May resolve |
|---|---|---|
| `admin` | `access_token` (Supabase Auth session) or `Authorization: Bearer` | any employee photo |
| `employee` | `employee_id` + `mobile_number` | own photo only |
| `employee_device` | `device_token` + `device_id` | own photo only; P2-18 binding and expiry checked |
| `guard_device` | `device_code` + `device_token` | any employee photo |

`path` may be an object path or a legacy Storage URL (public or signed); both are
normalised to the object path before anything else happens.

### Maintenance action

```http
{ "action": "sweep", "dry_run": true, "retention_hours": 24, "limit": 200,
  "actor": { "access_token": "<SUPER_ADMIN session>" } }
```

`dry_run` defaults to `true`. With `dry_run: false` the function removes the
candidate objects through the Storage API and then confirms the removals. Only a
`SUPER_ADMIN` session may call it.

## Deployment

Owner action — not part of any pull request:

```bash
supabase functions deploy employee-photo-url \
  --project-ref <REVIEWED_TARGET_PROJECT_REF> \
  --no-verify-jwt
```

- `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected by the platform.
- `ALLOWED_ORIGINS` (optional) is a comma-separated allow-list, for example
  `https://albashir-stone-karag.vercel.app`. When it is unset the function
  answers with `Access-Control-Allow-Origin: *` and still authorises every
  request itself.
- `--no-verify-jwt` is intentional: guard screens and the registration page are
  anonymous, so the gateway cannot be the authorization boundary. This function
  verifies the actor against the database before signing anything, and the
  service role key never leaves the function.

## Why the service role is required

Signing is performed by the Storage API, not by Postgres, so it cannot be done
from an RPC. Because the bucket has **no** `select` policy for `anon` or
`authenticated`, an ordinary client can never mint a signed URL; the resolver is
the single, audited access path.

## Related objects

- Migration: `supabase/migrations/20261006190000_private_employee_photos.sql`
- Rollback: `supabase/rollback/20261006190000_private_employee_photos_rollback.sql`
- Frontend client: `employee-photo.js`
- Tests: `tests/employee-photo-resolver.cjs`, `tests/private-employee-photos.cjs`,
  `tests/employee-photos-static.cjs`

## Dependency review and Staging prerequisites

The SDK entry import is pinned to npm:@supabase/supabase-js@2.117.2.
The dependency graph is resolved in supabase/functions/deno.lock. Frozen-lock
Deno check and local entry-point smoke tests PASS with Deno 2.9.6. Hosted
Supabase runtime/deployment behavior remains untested.
Deploy only after the approved baseline and photo migration pass verification.
The fresh-install correction candidate restores the approved helper definitions
and grants service_role execute on employee_profile_login(text,text). Complete
local readiness tests pass; hosted application/deployment still requires approval.
No Staging/Production deployment was performed.

Local check: `deno check --config=supabase/functions/deno.json --frozen-lockfile supabase/functions/employee-photo-url/index.ts`.
The entry smoke test requires synthetic env values and network permission for
127.0.0.1:8000 only; it cannot contact a real Supabase project.
# Public guard session actor — owner-approved Staging update

`{actor:{type:"public_guard_session",read_key:"<256-bit capability>"}}` resolves only the photo associated with the session's completed verification result. The service-only `resolve_public_guard_photo` RPC checks the read-key hash and six-minute session window. An arbitrary requested `path` is ignored for this actor. No device code/token is required; missing, wrong, expired or undecided sessions return opaque DENIED before Storage access. Private bucket, 60-second signed URL and no-store headers remain unchanged. Production unchanged.
