// ============================================================================
// employee-photo-resolver.cjs
//
// Offline unit tests for the employee-photo-url resolver logic
// (supabase/functions/employee-photo-url/handler.mjs).
//
// Every dependency is mocked: no Supabase project, no Storage API and no
// Production data are touched by this file.
// ============================================================================
const assert = require("node:assert/strict");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

const HANDLER = pathToFileURL(
  path.join(__dirname, "../supabase/functions/employee-photo-url/handler.mjs")
).href;

const OWN_PATH = "registrations/80632/1790627850001-7df3b32a22b418.jpeg";
const OTHER_PATH = "registrations/97919/1790620467682-4e48996fb63c28.png";
const LEGACY_PUBLIC_URL =
  "https://example.supabase.co/storage/v1/object/public/employee-photos/" + OWN_PATH;
const LEGACY_SIGNED_URL =
  "https://example.supabase.co/storage/v1/object/sign/employee-photos/" + OWN_PATH + "?token=abc.def";

function makeDeps(overrides = {}) {
  const calls = { signed: [], removed: [], confirmed: [], swept: [] };
  const deps = {
    verifyAdmin: async (token) =>
      token === "admin-token" ? { ok: true, role: "ADMIN" } :
      token === "super-token" ? { ok: true, role: "SUPER_ADMIN" } :
      { ok: false, reason: "NOT_AN_ADMIN" },
    verifyEmployeeCredentials: async (employeeId, mobileNumber) =>
      employeeId === "80632" && mobileNumber === "0790000000"
        ? { ok: true, employeeId: "80632" }
        : { ok: false, reason: "INVALID_EMPLOYEE_CREDENTIALS" },
    verifyTrustedDevice: async (deviceToken, deviceId) =>
      deviceToken === "trusted-device-token" && deviceId === "device-A" ? { ok: true, employeeId: "80632" } : { ok: false, reason: "DEVICE_NOT_TRUSTED" },
    verifyGateDevice: async (deviceCode, deviceToken) =>
      deviceCode === "gate-1" && deviceToken === "gate-token" ? { ok: true } : { ok: false, reason: "INVALID_DEVICE_TOKEN" },
    objectExists: async () => true,
    createSignedUrl: async (photoPath, ttl) => {
      calls.signed.push({ path: photoPath, ttl });
      return { ok: true, url: `https://example.supabase.co/storage/v1/object/sign/employee-photos/${photoPath}?token=sig` };
    },
    sweep: async (options) => {
      calls.swept.push(options);
      return { ok: true, paths: ["registrations/old/1.jpeg", "registrations/old/2.png"], candidateCount: 2 };
    },
    removeObjects: async (paths) => {
      calls.removed.push(paths);
      return { ok: true, removed: paths.slice(0, 1), failed: paths.slice(1) };
    },
    confirmRemoval: async (paths) => {
      calls.confirmed.push(paths);
      return { ok: true, deleted: paths.length };
    },
    allowedOrigins: "",
    now: () => Date.parse("2026-10-06T12:00:00.000Z"),
    ...overrides
  };
  return { deps, calls };
}

const post = (body, headers = {}) => ({ method: "POST", headers, body });

(async () => {
  const { handleRequest, SIGNED_URL_TTL_SECONDS, normalizeObjectPath } = await import(HANDLER);

  // ---------------------------------------------------------------- TTL contract
  assert.equal(SIGNED_URL_TTL_SECONDS, 60, "signed URLs must live 60 seconds");
  console.log("PASS signed URL lifetime is exactly 60 seconds");

  // ---------------------------------------------------------------- path parsing
  assert.equal(normalizeObjectPath(OWN_PATH), OWN_PATH);
  assert.equal(normalizeObjectPath(LEGACY_PUBLIC_URL), OWN_PATH);
  assert.equal(normalizeObjectPath(LEGACY_SIGNED_URL), OWN_PATH);
  for (const bad of [
    "",
    "   ",
    "registrations/80632/../../secret.jpeg",
    "violation-photos/1/a.jpg",
    "registrations/80632/file.gif",
    "registrations/80632/file",
    "not-a-path",
    "x".repeat(600)
  ]) {
    assert.equal(normalizeObjectPath(bad), "", `must reject ${JSON.stringify(bad.slice(0, 40))}`);
  }
  console.log("PASS path parsing accepts object paths and legacy URLs, rejects anything else");

  // ---------------------------------------------------------------- authorization matrix
  {
    const { deps, calls } = makeDeps();
    const response = await handleRequest(post({ action: "resolve", path: OWN_PATH, actor: { type: "employee", employee_id: "80632", mobile_number: "0790000000" } }), deps);
    assert.equal(response.status, 200);
    assert.equal(response.body.ok, true);
    assert.equal(response.body.expires_in, 60);
    assert.equal(response.body.expires_at, "2026-10-06T12:01:00.000Z");
    assert.equal(calls.signed.length, 1);
    assert.equal(calls.signed[0].ttl, 60);
    assert.equal(calls.signed[0].path, OWN_PATH);
    console.log("PASS employee credentials resolve their own photo with a 60s expiry");
  }
  {
    const { deps } = makeDeps();
    const response = await handleRequest(
      post({ action: "resolve", url: LEGACY_PUBLIC_URL, actor: { type: "employee_device", device_token: "trusted-device-token", device_id: "device-A" } }),
      deps
    );
    assert.equal(response.status, 200);
    assert.equal(response.body.ok, true);
    console.log("PASS trusted device resolves a legacy public URL reference");
  }
  {
    const { deps, calls } = makeDeps();
    const response = await handleRequest(post({ action: "resolve", path: OTHER_PATH, actor: { type: "employee", employee_id: "80632", mobile_number: "0790000000" } }), deps);
    assert.equal(response.status, 403);
    assert.deepEqual(response.body, { ok: false, error: "DENIED" });
    assert.equal(calls.signed.length, 0);
    console.log("PASS employee cannot resolve another employee's photo");
  }
  {
    const { deps } = makeDeps();
    const response = await handleRequest(post({ action: "resolve", path: OWN_PATH, actor: { type: "employee", employee_id: "80632", mobile_number: "wrong" } }), deps);
    assert.equal(response.status, 403);
    assert.deepEqual(response.body, { ok: false, error: "DENIED" });
    console.log("PASS wrong employee credentials are denied");
  }
  {
    const { deps } = makeDeps();
    const response = await handleRequest(post({ action: "resolve", path: OTHER_PATH, actor: { type: "guard_device", device_code: "gate-1", device_token: "gate-token" } }), deps);
    assert.equal(response.status, 200);
    console.log("PASS guard device resolves any employee photo");
  }
  {
    const { deps } = makeDeps();
    const response = await handleRequest(post({ action: "resolve", path: OTHER_PATH, actor: { type: "admin", access_token: "admin-token" } }), deps);
    assert.equal(response.status, 200);
    console.log("PASS admin session resolves any employee photo");
  }
  {
    const { deps } = makeDeps();
    const bearerOnly = await handleRequest(post({ action: "resolve", path: OTHER_PATH, actor: { type: "admin" } }, { authorization: "Bearer admin-token" }), deps);
    assert.equal(bearerOnly.status, 200);
    const noToken = await handleRequest(post({ action: "resolve", path: OTHER_PATH, actor: { type: "admin" } }), deps);
    assert.equal(noToken.status, 403);
    assert.deepEqual(noToken.body, { ok: false, error: "DENIED" });
    console.log("PASS admin needs a session (header or body) and is denied without one");
  }
  {
    const { deps } = makeDeps();
    for (const actor of [undefined, {}, { type: "employee" }, { type: "guard_device" }, { type: "employee_device" }]) {
      const response = await handleRequest(post({ action: "resolve", path: OWN_PATH, actor }), deps);
      assert.equal(response.status, 403);
      assert.equal(response.body.ok, false);
    }
    const unknown = await handleRequest(post({ action: "resolve", path: OWN_PATH, actor: { type: "root" } }), deps);
    assert.deepEqual(unknown.body, { ok: false, error: "DENIED" });
    console.log("PASS missing/unknown actors never receive a signed URL");
  }
  {
    const { deps, calls } = makeDeps();
    const response = await handleRequest(post({ action: "resolve", path: "registrations/80632/a.gif", actor: { type: "guard_device", device_code: "gate-1", device_token: "gate-token" } }), deps);
    assert.equal(response.status, 403);
    assert.deepEqual(response.body, { ok: false, error: "DENIED" });
    assert.equal(calls.signed.length, 0);
    console.log("PASS malformed references are rejected before any signing call");
  }

  // Cross-employee failures must not reveal whether the target object exists.
  {
    let storageCalls = 0;
    const { deps, calls } = makeDeps({ objectExists: async () => { storageCalls++; return true; } });
    const employee = { type: "employee", employee_id: "80632", mobile_number: "0790000000" };
    const attempts = [
      { path: OTHER_PATH, actor: employee },
      { path: "registrations/97919/nonexistent.jpg", actor: employee },
      { path: OTHER_PATH, actor: { type: "employee_device", device_token: "trusted-device-token", device_id: "device-A" } },
      { path: OWN_PATH, actor: { ...employee, mobile_number: "wrong" } },
      { path: "malformed", actor: employee }
    ];
    for (const attempt of attempts) {
      const result = await handleRequest(post({ action: "resolve", ...attempt }), deps);
      assert.equal(result.status, 403);
      assert.deepEqual(result.body, { ok: false, error: "DENIED" });
      assert.deepEqual(Object.keys(result.body).sort(), ["error", "ok"]);
    }
    assert.equal(storageCalls, 0, "unauthorized callers must not reach object lookup");
    assert.equal(calls.signed.length, 0, "unauthorized callers must not reach signing");
    console.log("PASS IDOR denials expose no reason and never query or sign target objects");
  }

  // ---------------------------------------------------------------- storage outcomes
  {
    const { deps } = makeDeps({ objectExists: async () => false });
    const response = await handleRequest(post({ action: "resolve", path: OWN_PATH, actor: { type: "guard_device", device_code: "gate-1", device_token: "gate-token" } }), deps);
    assert.equal(response.status, 404);
    assert.equal(response.body.reason, "PHOTO_NOT_FOUND");
    console.log("PASS missing objects are not signed");
  }
  {
    const { deps, calls } = makeDeps({ createSignedUrl: async () => ({ ok: false, error: "boom" }) });
    const response = await handleRequest(post({ action: "resolve", path: OWN_PATH, actor: { type: "guard_device", device_code: "gate-1", device_token: "gate-token" } }), deps);
    assert.equal(response.status, 500);
    assert.equal(response.body.reason, "SIGNING_FAILED");
    assert.equal(calls.removed.length, 0);
    console.log("PASS signing failure returns a generic error without leaking internals");
  }
  {
    const { deps } = makeDeps({ verifyGateDevice: async () => { throw new Error("db down"); } });
    const response = await handleRequest(post({ action: "resolve", path: OWN_PATH, actor: { type: "guard_device", device_code: "gate-1", device_token: "gate-token" } }), deps);
    assert.equal(response.status, 500);
    assert.equal(response.body.reason, "VERIFICATION_FAILED");
    const walk = JSON.stringify(response.body);
    assert.ok(!walk.includes("db down"), "internal errors must not be echoed");
    console.log("PASS verification exceptions fail closed and leak nothing");
  }

  // ---------------------------------------------------------------- transport
  {
    const { deps } = makeDeps();
    const options = await handleRequest({ method: "OPTIONS", headers: {}, body: null }, deps);
    assert.equal(options.status, 204);
    const get = await handleRequest({ method: "GET", headers: {}, body: null }, deps);
    assert.equal(get.status, 405);
    const badBody = await handleRequest({ method: "POST", headers: {}, body: null }, deps);
    assert.equal(badBody.status, 400);
    const unknownAction = await handleRequest(post({ action: "nope" }), deps);
    assert.equal(unknownAction.status, 400);
    assert.equal(unknownAction.body.reason, "UNKNOWN_ACTION");
    console.log("PASS CORS preflight, non-POST, empty body and unknown actions are handled");
  }
  {
    const { deps } = makeDeps({ allowedOrigins: "https://albashir-stone-karag.vercel.app" });
    const allowed = await handleRequest(post({ action: "resolve", path: OWN_PATH, actor: { type: "guard_device", device_code: "gate-1", device_token: "gate-token" } }, { origin: "https://albashir-stone-karag.vercel.app" }), deps);
    assert.equal(allowed.headers["access-control-allow-origin"], "https://albashir-stone-karag.vercel.app");
    const denied = await handleRequest(post({ action: "resolve", path: OWN_PATH, actor: { type: "guard_device", device_code: "gate-1", device_token: "gate-token" } }, { origin: "https://evil.example" }), deps);
    assert.equal(denied.headers["access-control-allow-origin"], "");
    console.log("PASS origin allow-list is enforced when configured");
  }

  // ---------------------------------------------------------------- sweep
  {
    const { deps, calls } = makeDeps();
    const noToken = await handleRequest(post({ action: "sweep" }), deps);
    assert.equal(noToken.status, 403);
    const notSuper = await handleRequest(post({ action: "sweep", actor: { access_token: "admin-token" } }), deps);
    assert.equal(notSuper.status, 403);
    assert.deepEqual(notSuper.body, { ok: false, error: "DENIED" });
    assert.equal(calls.swept.length, 0);
    console.log("PASS sweep requires a SUPER_ADMIN session");
  }
  {
    const { deps, calls } = makeDeps();
    const dry = await handleRequest(post({ action: "sweep", actor: { access_token: "super-token" } }), deps);
    assert.equal(dry.status, 200);
    assert.equal(dry.body.mode, "DRY_RUN");
    assert.equal(dry.body.candidate_count, 2);
    assert.deepEqual(dry.body.paths, ["registrations/old/1.jpeg", "registrations/old/2.png"]);
    assert.equal(calls.swept[0].dryRun, true);
    assert.equal(calls.swept[0].retentionHours, 24);
    assert.equal(calls.removed.length, 0);
    console.log("PASS sweep defaults to a dry run and removes nothing");
  }
  {
    const { deps, calls } = makeDeps();
    const applied = await handleRequest(post({ action: "sweep", dry_run: false, retention_hours: 0, limit: 9999, actor: { access_token: "super-token" } }), deps);
    assert.equal(applied.status, 200);
    assert.equal(applied.body.mode, "APPLY");
    assert.equal(applied.body.removed_count, 1);
    assert.equal(applied.body.failed_count, 1);
    assert.equal(calls.swept[0].dryRun, false);
    assert.equal(calls.swept[0].retentionHours, 1, "retention floor is 1 hour");
    assert.equal(calls.swept[0].limit, 500, "sweep limit is capped at 500");
    assert.deepEqual(calls.confirmed[0], ["registrations/old/1.jpeg"], "only removed objects are confirmed");
    console.log("PASS applied sweep clamps inputs and confirms exactly the removed paths");
  }
  {
    const { deps } = makeDeps({ sweep: async () => ({ ok: false, error: "SWEEP_FAILED" }) });
    const response = await handleRequest(post({ action: "sweep", dry_run: false, actor: { access_token: "super-token" } }), deps);
    assert.equal(response.status, 500);
    console.log("PASS sweep failures surface as generic errors");
  }

  // ---------------------------------------------------------------- no secret leakage
  {
    const { deps } = makeDeps();
    const response = await handleRequest(post({ action: "resolve", path: OWN_PATH, actor: { type: "employee", employee_id: "80632", mobile_number: "0790000000" } }), deps);
    const payload = JSON.stringify(response.body);
    for (const forbidden of ["service_role", "SERVICE_ROLE", "eyJhbGciOi"]) {
      assert.ok(!payload.includes(forbidden), `response must not contain ${forbidden}`);
    }
    console.log("PASS resolver responses never contain credentials or service keys");
  }

  console.log("\nAll employee-photo-url resolver tests passed.");
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
