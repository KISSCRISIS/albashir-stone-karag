-- Apply ONLY after live index.html uses device-authenticated status RPC.
REVOKE SELECT ON TABLE public.guard_screen_status FROM PUBLIC, anon, authenticated;
DROP POLICY IF EXISTS "Anyone can read guard screen status" ON public.guard_screen_status;
