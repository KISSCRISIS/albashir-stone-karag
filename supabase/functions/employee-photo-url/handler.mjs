// ============================================================================
// employee-photo-url — resolver logic (pure, dependency-injected)
//
// This module contains every decision the resolver makes and has no runtime
// dependency on Deno, Node or supabase-js, so it is unit-testable offline
// (tests/employee-photo-resolver.cjs) with mocked dependencies.
//
// The Deno entry point (index.ts) wires the real Supabase clients into `deps`.
//
// Contract (see docs/PRIVATE_EMPLOYEE_PHOTOS_ARCHITECTURE.md):
//   POST { action: "resolve", path | url, actor }
//        -> 200 { ok: true, url, expires_in: 60, expires_at }
//        -> 403 { ok: false, error: "DENIED" } (opaque authorization failure)
//   POST { action: "sweep", dry_run?, retention_hours?, limit? } + super-admin
// ============================================================================

export const SIGNED_URL_TTL_SECONDS = 60;
export const BUCKET_ID = "employee-photos";
export const MAX_INPUT_LENGTH = 512;
export const DEFAULT_RETENTION_HOURS = 24;
export const DEFAULT_SWEEP_LIMIT = 200;
export const MAX_SWEEP_LIMIT = 500;

const PATH_PATTERN = /^registrations\/[A-Za-z0-9_-]{1,64}\/[A-Za-z0-9._-]{1,120}$/;
const ALLOWED_EXTENSIONS = ["jpg", "jpeg", "png", "webp"];

/**
 * Accepts a stored object path or a legacy Storage URL and returns the object
 * path. Mirrors private.employee_photo_object_path() in SQL. Returns "" when
 * the value cannot be interpreted.
 */
export function normalizeObjectPath(value) {
  const raw = String(value ?? "").trim();
  if (!raw || raw.length > MAX_INPUT_LENGTH) return "";
  if (raw.startsWith("registrations/")) return isWellFormedPath(raw) ? raw : "";
  const publicMarker = "/storage/v1/object/public/employee-photos/";
  const signedMarker = "/storage/v1/object/sign/employee-photos/";
  let candidate = "";
  if (raw.includes(publicMarker)) candidate = raw.split(publicMarker)[1] || "";
  else if (raw.includes(signedMarker)) candidate = (raw.split(signedMarker)[1] || "").split("?")[0];
  if (!candidate) return "";
  try {
    candidate = decodeURIComponent(candidate);
  } catch {
    return "";
  }
  candidate = candidate.trim();
  return isWellFormedPath(candidate) ? candidate : "";
}

export function isWellFormedPath(path) {
  if (!PATH_PATTERN.test(path)) return false;
  const extension = path.split(".").pop()?.toLowerCase() || "";
  return ALLOWED_EXTENSIONS.includes(extension);
}

/**
 * Folder rule shared with register.html: the employee identifier is reduced to
 * [A-Za-z0-9_-] before it becomes a folder name.
 */
export function employeeFolder(employeeId) {
  return String(employeeId ?? "").trim().replace(/[^\w-]+/g, "-");
}

/** True when the path lives under registrations/<employeeFolder>/ of that employee. */
export function pathBelongsToEmployee(path, employeeId) {
  const folder = employeeFolder(employeeId);
  if (!folder) return false;
  const parts = path.split("/");
  return parts.length === 3 && parts[0] === "registrations" && parts[1] === folder;
}

function response(status, payload, headers = {}) {
  // Keep every authorization rejection indistinguishable at the payload level.
  // Never expose ownership, credential validity, or verifier reasons to callers.
  const body = status === 403 ? { ok: false, error: "DENIED" } : payload;
  return { status, body, headers: { ...headers, "cache-control": "no-store, private", "pragma": "no-cache", "expires": "0" } };
}

function corsHeaders(origin, allowedOrigins) {
  const allowList = String(allowedOrigins || "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
  const allowedOrigin = allowList.length === 0 ? "*" : allowList.includes(origin) ? origin : "";
  if (!allowedOrigin) return { "access-control-allow-origin": "" };
  return {
    "access-control-allow-origin": allowedOrigin,
    "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
    "access-control-allow-methods": "POST, OPTIONS",
    vary: "Origin"
  };
}

export const CORS_PREFLIGHT = { status: 204, body: null, headers: {} };

/**
 * Main entry point.
 *
 * @param {{ method: string, headers: Record<string,string>, body: any }} input
 * @param {{
 *   verifyAdmin: (accessToken: string) => Promise<{ok:boolean, role?:string, reason?:string}>,
 *   verifyEmployeeCredentials: (employeeId:string, mobileNumber:string) => Promise<{ok:boolean, employeeId?:string, reason?:string}>,
 *   verifyTrustedDevice: (deviceToken:string, deviceId:string) => Promise<{ok:boolean, employeeId?:string, reason?:string}>,
 *   verifyGateDevice: (deviceCode:string, deviceToken:string) => Promise<{ok:boolean, reason?:string}>,
 *   objectExists: (path:string) => Promise<boolean>,
 *   createSignedUrl: (path:string, ttl:number) => Promise<{ok:boolean, url?:string, error?:string}>,
 *   sweep: (options:{retentionHours:number, limit:number, dryRun:boolean}) => Promise<{ok:boolean, paths?:string[], candidateCount?:number, error?:string}>,
 *   removeObjects: (paths:string[]) => Promise<{ok:boolean, removed?:string[], failed?:string[], error?:string}>,
 *   confirmRemoval: (paths:string[]) => Promise<{ok:boolean, deleted?:number, error?:string}>,
 *   allowedOrigins: string,
 *   now: () => number
 * }} deps
 */
export async function handleRequest(input, deps) {
  const origin = String(input?.headers?.origin || "");
  const cors = corsHeaders(origin, deps?.allowedOrigins);

  if (input?.method === "OPTIONS") return { ...CORS_PREFLIGHT, headers: cors };

  if (input?.method !== "POST") {
    return response(405, { ok: false, error: "DENIED", reason: "METHOD_NOT_ALLOWED" }, cors);
  }

  const body = input?.body && typeof input.body === "object" ? input.body : null;
  if (!body) {
    return response(400, { ok: false, error: "DENIED", reason: "INVALID_BODY" }, cors);
  }

  const action = String(body.action || "resolve");

  if (action === "resolve") return resolveAction(body, input, deps, cors);
  if (action === "sweep") return sweepAction(body, input, deps, cors);

  return response(400, { ok: false, error: "DENIED", reason: "UNKNOWN_ACTION" }, cors);
}

async function resolveAction(body, input, deps, cors) {
  let publicSession = null;
  if (body.actor?.type === "public_guard_session") {
    try { publicSession = await deps.verifyPublicGuardSession(String(body.actor.read_key || "")); }
    catch { return response(403, { ok: false, error: "DENIED" }, cors); }
    if (publicSession?.ok !== true) return response(403, { ok: false, error: "DENIED" }, cors);
  }
  const path = normalizeObjectPath(publicSession ? publicSession.path : body.path || body.url || "");
  if (!path) {
    return response(403, { ok: false, error: "DENIED", reason: "INVALID_PHOTO_REFERENCE" }, cors);
  }

  const actor = body.actor && typeof body.actor === "object" ? body.actor : {};
  const actorType = String(actor.type || "").trim();
  const bearer = extractBearer(input?.headers?.authorization);

  let authorized = false;
  let reason = "NOT_AUTHORIZED";

  try {
    if (actorType === "public_guard_session") {
      authorized = publicSession?.ok === true;
    } else if (actorType === "admin") {
      const token = String(actor.access_token || bearer || "");
      if (!token) return response(403, { ok: false, error: "DENIED", reason: "MISSING_CREDENTIALS" }, cors);
      const verified = await deps.verifyAdmin(token);
      authorized = verified?.ok === true;
      reason = verified?.reason || reason;
    } else if (actorType === "employee") {
      const verified = await deps.verifyEmployeeCredentials(
        String(actor.employee_id || ""),
        String(actor.mobile_number || "")
      );
      if (verified?.ok === true) {
        authorized = pathBelongsToEmployee(path, verified.employeeId || actor.employee_id);
        reason = authorized ? reason : "NOT_OWNER";
      } else {
        reason = verified?.reason || "INVALID_EMPLOYEE_CREDENTIALS";
      }
    } else if (actorType === "employee_device") {
      const deviceId = String(actor.device_id || "").trim();
      if (!deviceId) return response(403, { ok: false, error: "DENIED" }, cors);
      const verified = await deps.verifyTrustedDevice(String(actor.device_token || ""), deviceId);
      if (verified?.ok === true) {
        authorized = pathBelongsToEmployee(path, verified.employeeId);
        reason = authorized ? reason : "NOT_OWNER";
      } else {
        reason = verified?.reason || "INVALID_DEVICE_TOKEN";
      }
    } else if (actorType === "guard_device") {
      const verified = await deps.verifyGateDevice(
        String(actor.device_code || ""),
        String(actor.device_token || "")
      );
      authorized = verified?.ok === true;
      reason = verified?.reason || reason;
    } else {
      reason = actorType ? "UNKNOWN_ACTOR" : "MISSING_CREDENTIALS";
    }
  } catch {
    return response(500, { ok: false, error: "DENIED", reason: "VERIFICATION_FAILED" }, cors);
  }

  if (!authorized) {
    return response(403, { ok: false, error: "DENIED", reason }, cors);
  }

  try {
    const exists = await deps.objectExists(path);
    if (exists !== true) {
      return response(404, { ok: false, error: "DENIED", reason: "PHOTO_NOT_FOUND" }, cors);
    }
  } catch {
    return response(500, { ok: false, error: "DENIED", reason: "STORAGE_UNAVAILABLE" }, cors);
  }

  try {
    const signed = await deps.createSignedUrl(path, SIGNED_URL_TTL_SECONDS);
    if (signed?.ok !== true || !signed.url) {
      return response(500, { ok: false, error: "DENIED", reason: "SIGNING_FAILED" }, cors);
    }
    return response(
      200,
      {
        ok: true,
        url: signed.url,
        expires_in: SIGNED_URL_TTL_SECONDS,
        expires_at: new Date(deps.now() + SIGNED_URL_TTL_SECONDS * 1000).toISOString()
      },
      cors
    );
  } catch {
    return response(500, { ok: false, error: "DENIED", reason: "SIGNING_FAILED" }, cors);
  }
}

async function sweepAction(body, input, deps, cors) {
  const bearer = extractBearer(input?.headers?.authorization);
  const token = String((body.actor && body.actor.access_token) || bearer || "");
  if (!token) {
    return response(403, { ok: false, error: "DENIED", reason: "MISSING_CREDENTIALS" }, cors);
  }

  let verified;
  try {
    verified = await deps.verifyAdmin(token);
  } catch {
    return response(500, { ok: false, error: "DENIED", reason: "VERIFICATION_FAILED" }, cors);
  }

  if (verified?.ok !== true) {
    return response(403, { ok: false, error: "DENIED", reason: verified?.reason || "NOT_AUTHORIZED" }, cors);
  }
  if (String(verified.role || "") !== "SUPER_ADMIN") {
    return response(403, { ok: false, error: "DENIED", reason: "SUPER_ADMIN_REQUIRED" }, cors);
  }

  const dryRun = body.dry_run !== false;
  const retentionHours = clampInteger(body.retention_hours, 1, 24 * 365, DEFAULT_RETENTION_HOURS);
  const limit = clampInteger(body.limit, 1, MAX_SWEEP_LIMIT, DEFAULT_SWEEP_LIMIT);

  let sweep;
  try {
    sweep = await deps.sweep({ retentionHours, limit, dryRun });
  } catch {
    return response(500, { ok: false, error: "DENIED", reason: "SWEEP_FAILED" }, cors);
  }

  if (sweep?.ok !== true) {
    return response(500, { ok: false, error: "DENIED", reason: sweep?.error || "SWEEP_FAILED" }, cors);
  }

  const paths = Array.isArray(sweep.paths) ? sweep.paths : [];

  if (dryRun) {
    return response(
      200,
      {
        ok: true,
        mode: "DRY_RUN",
        retention_hours: retentionHours,
        candidate_count: sweep.candidateCount ?? paths.length,
        paths
      },
      cors
    );
  }

  if (paths.length === 0) {
    return response(200, { ok: true, mode: "APPLY", removed_count: 0, failed_count: 0, removed: [], failed: [] }, cors);
  }

  let removal;
  try {
    removal = await deps.removeObjects(paths);
  } catch {
    return response(500, { ok: false, error: "DENIED", reason: "STORAGE_DELETE_FAILED" }, cors);
  }

  const removed = Array.isArray(removal?.removed) ? removal.removed : [];
  const failed = Array.isArray(removal?.failed) ? removal.failed : [];

  if (removed.length > 0) {
    try {
      await deps.confirmRemoval(removed);
    } catch {
      // The bytes are already gone; a stale ledger row is harmless and the next
      // sweep run will retry the bookkeeping.
    }
  }

  return response(
    200,
    {
      ok: true,
      mode: "APPLY",
      retention_hours: retentionHours,
      removed_count: removed.length,
      failed_count: failed.length,
      removed,
      failed
    },
    cors
  );
}

function extractBearer(headerValue) {
  const raw = String(headerValue || "").trim();
  if (!raw.toLowerCase().startsWith("bearer ")) return "";
  return raw.slice(7).trim();
}

function clampInteger(value, min, max, fallback) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(Math.max(parsed, min), max);
}
