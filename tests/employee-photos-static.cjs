// ============================================================================
// employee-photos-static.cjs
//
// Source-level guarantees for the private employee photo architecture. These
// assertions fail the build if a public URL path is reintroduced anywhere.
//
//   1. getPublicUrl() must not exist anywhere in the application
//   2. no page may build /storage/v1/object/public/employee-photos/ links
//   3. every photo-displaying page must load the resolver client
//   4. the registration flow must store an object path, never a URL
//   5. the storage policies in the migration must stay closed to reads
//   6. the rollback must reopen the previous boundary
//   7. the resolver must never expose the service role key or a TTL other than 60s
// ============================================================================
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..");
const APP_FILES = [
  "index.html",
  "register.html",
  "verify.html",
  "guard.html",
  "profile.html",
  "portal.html",
  "login.html",
  "admin_dashboard.html",
  "verify-shared.js",
  "employee-photo.js",
  "access-control.js",
  "global-leadership.js",
  "service-worker.js",
  "assets/js/app-state.js",
  "assets/js/ui-components.js",
  "manifest.json",
  "vercel.json"
];

const read = (relative) => fs.readFileSync(path.join(ROOT, relative), "utf8");
const exists = (relative) => fs.existsSync(path.join(ROOT, relative));

const MIGRATION = "supabase/migrations/20261006190000_private_employee_photos.sql";
const ROLLBACK = "supabase/rollback/20261006190000_private_employee_photos_rollback.sql";
const HANDLER = "supabase/functions/employee-photo-url/handler.mjs";
const ENTRY = "supabase/functions/employee-photo-url/index.ts";

// ---------------------------------------------------------------- 1. getPublicUrl
{
  const offenders = APP_FILES.filter((file) => exists(file) && /getPublicUrl/.test(read(file)));
  assert.deepEqual(offenders, [], "getPublicUrl() must not appear in any application file");
  const wholeRepo = [
    ...APP_FILES,
    "README.md",
    "PROJECT_RULES.md",
    MIGRATION,
    ROLLBACK,
    HANDLER,
    ENTRY,
    "supabase/functions/employee-photo-url/README.md"
  ];
  const remaining = wholeRepo.filter((file) => exists(file) && /\.getPublicUrl\(/.test(read(file)));
  assert.deepEqual(remaining, [], "no source file may still call getPublicUrl()");
  console.log("PASS no getPublicUrl() call remains in the application");
}

// ---------------------------------------------------------------- 2. public bucket URLs
{
  const allowed = new Set(["employee-photo.js", HANDLER, "tests/employee-photos-static.cjs", "tests/employee-photo-resolver.cjs"]);
  const offenders = [];
  for (const file of APP_FILES) {
    if (!exists(file) || allowed.has(file)) continue;
    if (read(file).includes("/storage/v1/object/public/employee-photos/")) offenders.push(file);
  }
  assert.deepEqual(offenders, [], "no page may construct a public employee-photos URL");
  console.log("PASS no page builds a public employee-photos URL");
}

// ---------------------------------------------------------------- 3. resolver client wiring
{
  const client = read("employee-photo.js");
  assert.match(client, /window\.EmployeePhoto\s*=/, "employee-photo.js must export EmployeePhoto");
  assert.match(client, /\/functions\/v1\/employee-photo-url/, "resolver endpoint must be used");
  assert.match(client, /data-photo-ref/, "hydrator must consume data-photo-ref");
  assert.match(client, /data-photo-href/, "hydrator must consume data-photo-href");

  for (const page of ["index.html", "register.html", "verify.html", "guard.html", "profile.html", "admin_dashboard.html"]) {
    assert.match(read(page), /<script src="\.\/employee-photo\.js"><\/script>/, `${page} must load employee-photo.js`);
  }
  console.log("PASS every photo-displaying page loads the shared resolver client");
}
{
  const shared = read("verify-shared.js");
  assert.match(shared, /data-photo-ref="\$\{escapeHtml\(photo\)\}"/, "shared renderer must emit a data-photo-ref");
  assert.doesNotMatch(shared, /<img class="employee-photo" src=/, "shared renderer must not emit a direct src");
  assert.match(shared, /function hydrateEmployeePhotos\(/);
  console.log("PASS the shared employee renderer defers photos to the resolver");
}
{
  const admin = read("admin_dashboard.html");
  assert.match(admin, /data-photo-ref="\$\{escapeHtml\(ref\)\}"/);
  assert.match(admin, /data-photo-href="\$\{escapeHtml\(ref\)\}"/);
  assert.match(admin, /hydrateAdminPhotos\(body\)/);
  assert.doesNotMatch(admin, /safeImageUrl\(row\.employee_photo_url\)/, "registration photos must not use the URL helper");
  assert.match(admin, /safeImageUrl\(row\.photo_url\)/, "violation photo handling is unchanged");
  console.log("PASS the admin dashboard resolves registration photos and keeps violation handling");
}
{
  const profile = read("profile.html");
  assert.match(profile, /showProfilePhoto\(profile\.employee_photo_url\)/);
  assert.doesNotMatch(profile, /profilePhoto"\)\.src=profile\.employee_photo_url/);
  const index = read("index.html");
  assert.match(index, /showGuardPhoto\(displayPhoto\)/);
  assert.match(index, /type: "guard_device"/);
  const verify = read("verify.html");
  assert.match(verify, /hydrateEmployeePhotos\(details, employeePhotoActor\(employee\)\)/);
  assert.match(verify, /type:"employee_device"/);
  const guard = read("guard.html");
  assert.match(guard, /hydrateEmployeePhotos\(details, guardPhotoActor\(\)\)/);
  console.log("PASS profile, guard screen, verify and guard pages resolve photos with their own actor");
}
{
  const register = read("register.html");
  assert.match(register, /return path;/, "upload must return the object path");
  assert.doesNotMatch(register, /data\.publicUrl/, "the registration flow must not use a public URL");
  assert.match(register, /p_photo_url: photoPath/);
  assert.match(register, /register_pending_employee_upload/);
  assert.match(register, /MAX_PHOTO_BYTES = 2097152/);
  assert.match(register, /ALLOWED_PHOTO_TYPES = \["image\/jpeg", "image\/png", "image\/webp"\]/);
  assert.match(register, /contentType: mimeType/, "the declared MIME type must match the validated one");
  console.log("PASS registration stores an object path with client-side size and MIME guards");
}

// ---------------------------------------------------------------- 4. PWA wiring
{
  const sw = read("service-worker.js");
  assert.match(sw, /"\.\/employee-photo\.js"/, "the resolver client must be precached");
  const versions = ["service-worker.js", "index.html", "verify-shared.js"].map((file) => {
    const match = read(file).match(/emergency-room-parking-offline-v(\d+)/);
    return match ? match[1] : null;
  });
  assert.equal(new Set(versions).size, 1, `cache versions must stay aligned: ${versions.join(", ")}`);
  console.log(`PASS cache version is aligned at v${versions[0]} and precaches the resolver client`);
}

// ---------------------------------------------------------------- 5. migration guarantees
{
  const migration = read(MIGRATION);
  assert.match(migration, /values \(\s*'employee-photos',\s*'employee-photos',\s*false,/, "employee-photos must be created private");
  assert.match(migration, /set public = false/, "an existing bucket must be flipped to private");
  assert.match(migration, /file_size_limit = excluded\.file_size_limit/);
  assert.match(migration, /drop policy if exists "Anyone can read employee photos"/);
  assert.match(migration, /drop policy if exists "Anyone can upload employee photos"/);
  assert.match(migration, /create policy "Registration can upload employee photos"/);
  assert.doesNotMatch(migration, /for select\s+to anon, authenticated\s+using \(bucket_id = 'employee-photos'\)/, "no anon read policy may be created");
  assert.match(migration, /2097152/);
  assert.match(migration, /coalesce\(\(metadata ->> 'size'\)::bigint, 0\) between 1 and 2097152/);
  assert.match(migration, /revoke all on function public\.verify_gate_device_credentials\(text, text\) from public, anon, authenticated/);
  assert.match(migration, /grant execute on function public\.verify_gate_device_credentials\(text, text\) to service_role/);
  assert.match(migration, /private\.pending_employee_uploads/);
  assert.match(migration, /revoke all on schema private from public, anon, authenticated/);
  console.log("PASS the migration closes reads, constrains writes and hides the ledger");
}
{
  const rollback = read(ROLLBACK);
  assert.match(rollback, /set public = true/);
  assert.match(rollback, /create policy "Anyone can read employee photos"/);
  assert.match(rollback, /drop table if exists private\.pending_employee_uploads/);
  assert.match(rollback, /drop function if exists public\.verify_gate_device_credentials\(text, text\)/);
  assert.match(rollback, /drop function if exists public\.employee_photo_sweep_candidates\(integer, integer, boolean\)/);
  assert.match(rollback, /Objects already removed by the orphan sweep/);
  console.log("PASS the rollback restores the previous boundary and states its limits");
}

// ---------------------------------------------------------------- 6. resolver hardening
{
  const handler = read(HANDLER);
  assert.match(handler, /export const SIGNED_URL_TTL_SECONDS = 60;/, "the signed URL lifetime is fixed at 60 seconds");
  assert.doesNotMatch(handler, /service_role/i, "the handler must not know about the service key");
  assert.match(handler, /pathBelongsToEmployee\(path, verified\.employeeId/, "ownership enforcement must exist");
  assert.match(handler, /status === 403 \? \{ ok: false, error: "DENIED" \}/, "authorization denials must not expose reasons");
  console.log("PASS the handler fixes the TTL at 60s and enforces ownership");

  const entry = read(ENTRY);
  assert.match(entry, /SUPABASE_SERVICE_ROLE_KEY/, "the service key is only used server-side");
  assert.doesNotMatch(entry, /JSON\.stringify\([^)]*SERVICE_ROLE/, "the service key must never be serialized");
  assert.match(entry, /--no-verify-jwt/, "deployment instructions must document the auth model");
  console.log("PASS the service key stays inside the Edge Function");
}

{
  // The frontend must never carry a service-role credential. Mentions of the
  // rule itself (comments and on-screen text) are allowed; key material is not.
  const forbidden = [/SERVICE_ROLE_KEY/, /service_role_key/i, /sb_secret_/, /eyJhbGciOi/];
  const offenders = APP_FILES.filter((file) => exists(file) && forbidden.some((pattern) => pattern.test(read(file))));
  assert.deepEqual(offenders, [], "no frontend file may carry a service role credential");
  console.log("PASS no frontend file references a service role credential");
}

// ---------------------------------------------------------------- 7. cache policy
{
  const sw = read("service-worker.js");
  assert.match(sw, /url\.hostname\.endsWith\("\.supabase\.co"\)/, "supabase requests must be identified in the fetch handler");
  const handler = sw.slice(sw.indexOf('self.addEventListener("fetch"'));
  const bypass = handler.indexOf('endsWith(".supabase.co")');
  const firstPut = handler.indexOf("cache.put");
  assert.ok(bypass > -1, "the supabase bypass must exist");
  assert.ok(firstPut > bypass, "no cache.put may be reachable before the supabase bypass");
  assert.match(handler.slice(bypass, bypass + 400), /event\.respondWith\(fetch\(request\)\)/, "supabase responses must stay network-only");
  console.log("PASS the service worker never caches signed storage responses");
}
{
  const client = read("employee-photo.js");
  assert.match(client, /cache: "no-store"/, "the signed URL must be fetched with cache:no-store");
  assert.match(client, /URL\.createObjectURL/, "the signed URL must be displayed through a blob URL");
  const clientCode = client
    .split("\n")
    .filter((line) => !/^\s*(\/\/|\*|\/\*)/.test(line))
    .join("\n");
  assert.doesNotMatch(clientCode, /(?:localStorage|sessionStorage)\s*[.\[]|document\.cookie/, "the credential must never be persisted");
  console.log("PASS the client never persists or caches the signed URL");
}
{
  const vercel = JSON.parse(read("vercel.json"));
  const headers = vercel.headers.flatMap((entry) => entry.headers);
  const csp = headers.find((entry) => entry.key === "Content-Security-Policy");
  assert.ok(csp, "the deployment must keep a Content-Security-Policy");
  assert.match(csp.value, /img-src[^;]*blob:/, "img-src must allow blob: for the no-store display path");
  assert.match(csp.value, /connect-src[^;]*https:\/\/\*\.supabase\.co/, "connect-src must allow the resolver and the signed fetch");
  console.log("PASS the deployment CSP supports the no-store display path");
}

console.log("\nAll private employee photo static guarantees hold.");

assert.match(fs.readFileSync(path.join(ROOT, "supabase/functions/employee-photo-url/index.ts"), "utf8"), /npm:@supabase\/supabase-js@2\.117\.2/);
