import { withSupabase } from 'npm:@supabase/server@1.9.1';
import { createAdminAccount } from './handler.mjs';

export default {
  fetch: withSupabase({ auth: 'user' }, createAdminAccount),
};
