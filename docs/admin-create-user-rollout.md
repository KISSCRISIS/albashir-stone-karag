# Admin account creation readiness

Prepared locally; not deployed. Only an authenticated, active SUPER_ADMIN may
create accounts. Authorization and audit use the existing caller-JWT RPCs.
No schema migration or new direct table access is required. Existing accounts
are edited with the existing RPC, with the password field empty.

The server creates an unconfirmed Auth user, saves permissions, then explicitly
requests a signup confirmation email. Failed profile creation deletes only the
newly created user. Failed email delivery preserves the unconfirmed account and
reports partial completion; do not retry account creation. An administrator
must resolve SMTP delivery and resend confirmation before declaring it usable.

Deploy `admin-create-user` to Staging first with JWT verification enabled and
server-only SUPABASE_PUBLISHABLE_KEY and SUPABASE_SECRET_KEY configured for
the server wrapper. Never include a secret key in Vercel public runtime.
Verify unauthorized/disabled/SUB_ADMIN rejection, existing email, password
policy, profile failure cleanup, email delivery, confirmation and actual login.
The six-argument profile RPC exists on Staging (read-only verified).

Local handler tests mock Auth and RPC services; they do not verify deployed JWT
middleware, SMTP or real login. Password recovery and first-login password
changes remain outside this change. Do not merge/deploy Production before the
Staging acceptance checks pass.
