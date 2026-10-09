# Admin account creation rollout

Deploy the Edge Function `admin-create-user` to the Production Supabase project. Keep JWT verification enabled. The function requires `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` in Supabase's server-side secrets. Never expose the service role key to Vercel's public runtime or the browser.

The browser submits a logged-in SUPER_ADMIN's access token to the function. The function checks `get_my_admin_profile`, creates an unconfirmed Supabase Auth user and calls `super_admin_upsert_admin_profile` under the original user's JWT. The database RPC must enforce SUPER_ADMIN permissions and log the operation. If profile creation fails, the function attempts to delete the newly created Auth user.

**Important:** Do not merge or deploy until staging verification confirms the currently deployed RPC accepts `p_phone_number` and `p_permissions` and tests cover unauthorized calls, existing emails, failed profile creation, password policy, and user email confirmation. New users must confirm their email before login; configure Supabase Auth email delivery accordingly.

Current UI creates a new Auth user only when the password field is populated. Existing accounts are edited with the established RPC when the password field is blank. Password reset and first-login password change are not implemented in this change and should be completed before treating this as full lifecycle management.
