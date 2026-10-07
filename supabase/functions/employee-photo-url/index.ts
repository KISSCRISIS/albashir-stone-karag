// ============================================================================
// employee-photo-url — Supabase Edge Function (Deno) entry point
//
// Deploy (owner action, not part of the PR):
//   supabase functions deploy employee-photo-url \
//     --project-ref <REVIEWED_STAGING_PROJECT_REF> --no-verify-jwt
//
// Secrets: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected by the
// platform. ALLOWED_ORIGINS is optional (comma separated list); when unset the
// function answers with `Access-Control-Allow-Origin: *` and still authorises
// every request itself.
//
// --no-verify-jwt is intentional: anonymous callers (guard screens and the
// registration page) cannot present a JWT, so the gateway must not be the
// authorization boundary. This function performs its own verification against
// the database before it signs anything, and the service role key never leaves
// this process.
// ============================================================================

import { createClient } from "npm:@supabase/supabase-js@2.117.2";
import { handleRequest, BUCKET_ID } from "./handler.mjs";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ALLOWED_ORIGINS = Deno.env.get("ALLOWED_ORIGINS") ?? "";

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false }
});

// PostgREST takes the effective role from the Authorization header, so passing
// the admin's own access token keeps RLS and auth.uid() in force (the service
// role key is only sent as `apikey`).
function userScopedClient(accessToken: string) {
  return createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } }
  });
}

const deps = {
  async verifyAdmin(accessToken: string) {
    const client = userScopedClient(accessToken);
    const { data: userData, error: userError } = await client.auth.getUser(accessToken);
    if (userError || !userData?.user) return { ok: false, reason: "INVALID_ADMIN_SESSION" };

    const { data, error } = await client.rpc("get_my_admin_profile");
    const profile = Array.isArray(data) ? data[0] : data;
    if (error || !profile?.ok) return { ok: false, reason: "NOT_AN_ADMIN" };

    return { ok: true, role: String(profile.role ?? "") };
  },

  async verifyEmployeeCredentials(employeeId: string, mobileNumber: string) {
    const { data, error } = await admin.rpc("employee_profile_login", {
      p_employee_id: employeeId,
      p_mobile_number: mobileNumber
    });
    const result = Array.isArray(data) ? data[0] : data;
    if (error || !result?.ok) return { ok: false, reason: "INVALID_EMPLOYEE_CREDENTIALS" };
    return { ok: true, employeeId: String(result.profile?.employee_id ?? "") };
  },

  async verifyTrustedDevice(deviceToken: string, deviceId: string) {
    const { data, error } = await admin.rpc("verify_trusted_device_credentials", {
      p_device_token: deviceToken,
      p_device_id: deviceId
    });
    const result = Array.isArray(data) ? data[0] : data;
    if (error || !result?.ok) return { ok: false, reason: result?.reason || "DEVICE_NOT_TRUSTED" };
    return { ok: true, employeeId: String(result.employee_id ?? "") };
  },

  async verifyGateDevice(deviceCode: string, deviceToken: string) {
    const { data, error } = await admin.rpc("verify_gate_device_credentials", {
      p_device_code: deviceCode,
      p_device_token: deviceToken
    });
    const result = Array.isArray(data) ? data[0] : data;
    if (error || !result?.ok) return { ok: false, reason: result?.reason || "DEVICE_NOT_APPROVED" };
    return { ok: true };
  },

  async objectExists(path: string) {
    const separator = path.lastIndexOf("/");
    const folder = path.slice(0, separator);
    const name = path.slice(separator + 1);
    const { data, error } = await admin.storage.from(BUCKET_ID).list(folder, { search: name, limit: 100 });
    if (error) return false;
    return (data ?? []).some((entry) => entry.name === name);
  },

  async createSignedUrl(path: string, ttl: number) {
    const { data, error } = await admin.storage.from(BUCKET_ID).createSignedUrl(path, ttl);
    if (error || !data?.signedUrl) return { ok: false, error: error?.message };
    return { ok: true, url: data.signedUrl };
  },

  async sweep({ retentionHours, limit, dryRun }: { retentionHours: number; limit: number; dryRun: boolean }) {
    const { data, error } = await admin.rpc("employee_photo_sweep_candidates", {
      p_retention_hours: retentionHours,
      p_limit: limit,
      p_dry_run: dryRun
    });
    const result = Array.isArray(data) ? data[0] : data;
    if (error || !result?.ok) return { ok: false, error: error?.message || "SWEEP_FAILED" };
    return {
      ok: true,
      paths: Array.isArray(result.paths) ? result.paths : [],
      candidateCount: result.candidate_count ?? 0
    };
  },

  async removeObjects(paths: string[]) {
    const { data, error } = await admin.storage.from(BUCKET_ID).remove(paths);
    if (error) return { ok: false, error: error.message };
    const removed = (data ?? []).map((entry) => entry.name).filter(Boolean);
    const failed = paths.filter((path) => !removed.includes(path));
    return { ok: true, removed, failed };
  },

  async confirmRemoval(paths: string[]) {
    const { data, error } = await admin.rpc("employee_photo_confirm_removal", { p_paths: paths });
    if (error) return { ok: false, error: error.message };
    return { ok: true, deleted: Number(data ?? 0) };
  },

  allowedOrigins: ALLOWED_ORIGINS,
  now: () => Date.now()
};

Deno.serve(async (request: Request) => {
  let body: unknown = null;
  if (request.method === "POST") {
    try {
      body = await request.json();
    } catch {
      body = null;
    }
  }

  const result = await handleRequest(
    {
      method: request.method,
      headers: {
        origin: request.headers.get("origin") ?? "",
        authorization: request.headers.get("authorization") ?? ""
      },
      body
    },
    deps
  );

  const headers = new Headers({ "content-type": "application/json; charset=utf-8" });
  for (const [key, value] of Object.entries(result.headers ?? {})) {
    if (value) headers.set(key, String(value));
  }

  return new Response(result.body === null ? null : JSON.stringify(result.body), {
    status: result.status,
    headers
  });
});
