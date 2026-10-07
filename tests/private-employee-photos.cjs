// ============================================================================
// private-employee-photos.cjs
//
// Isolated PGlite execution of supabase/migrations/20261006190000_private_employee_photos.sql
// and of its rollback, against synthetic prerequisites only.
//
// Coverage
//   * the migration and the rollback both execute without error
//   * anonymous / authenticated reads of employee-photos are blocked
//   * direct object URLs are blocked (bucket is private, no read policy)
//   * uploads are constrained by folder, extension, MIME type and size
//   * legacy public URLs are backfilled to object paths
//   * the pending-upload ledger is unreachable from anon/authenticated
//   * the orphan sweep selects, marks and confirms the right paths
//   * the resolver's device/employee verification RPCs are service-role only
//
// No Production project is contacted and no real photo, employee or device is
// used. Signing/expiry behaviour of the Storage API itself belongs to
// tests/employee-photo-resolver.cjs (mocked) and to the staging checklist.
// ============================================================================
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { PGlite } = require("@electric-sql/pglite");

const MIGRATION_PATH = path.join(__dirname, "../supabase/migrations/20261006190000_private_employee_photos.sql");
const ROLLBACK_PATH = path.join(__dirname, "../supabase/rollback/20261006190000_private_employee_photos_rollback.sql");
const MIGRATION = fs.readFileSync(MIGRATION_PATH, "utf8");
const ROLLBACK = fs.readFileSync(ROLLBACK_PATH, "utf8");

const LEGACY_PUBLIC = (employeeId, file) =>
  `https://qinsfvlspdticposbvst.supabase.co/storage/v1/object/public/employee-photos/registrations/${employeeId}/${file}`;

async function asRole(db, role, fn) {
  await db.exec(`set role ${role}`);
  try {
    return await fn();
  } finally {
    await db.exec("reset role");
  }
}

async function rejects(promise, pattern, label) {
  try {
    await promise;
  } catch (error) {
    assert.match(String(error.message), pattern, label);
    return;
  }
  throw new Error("expected rejection: " + label);
}

async function scalar(db, sql, params) {
  const result = await db.query(sql, params);
  return result.rows[0] ? Object.values(result.rows[0])[0] : undefined;
}

async function newDatabase() {
  const db = new PGlite();
  await db.exec(`
    create role anon;
    create role authenticated;
    create role service_role;

    create schema if not exists storage;

    create or replace function storage.foldername(name text)
    returns text[] language sql immutable as $$
      select (string_to_array(name, '/'))[1:greatest(array_length(string_to_array(name, '/'), 1) - 1, 0)];
    $$;

    create or replace function storage.extension(name text)
    returns text language sql immutable as $$
      select nullif(lower(substring(name from '\\.([^.]+)$')), '');
    $$;

    create table storage.buckets (
      id text primary key,
      name text not null,
      public boolean default false,
      file_size_limit bigint default null,
      allowed_mime_types text[] default null,
      created_at timestamptz default now()
    );

    create table storage.objects (
      id uuid primary key default gen_random_uuid(),
      bucket_id text not null,
      name text not null,
      metadata jsonb,
      created_at timestamptz default now(),
      unique (bucket_id, name)
    );
    alter table storage.objects enable row level security;

    grant usage on schema storage to anon, authenticated, service_role;
    grant select on storage.buckets to anon, authenticated, service_role;
    grant select, insert, update, delete on storage.objects to anon, authenticated, service_role;

    create table public.employee_registrations (
      id uuid primary key default gen_random_uuid(),
      employee_id text,
      mobile_number text,
      full_name text,
      specialty text,
      status text not null default 'PENDING',
      employee_photo_url text,
      trusted_device_enabled boolean not null default false,
      trusted_device_token_hash text,
      created_at timestamptz not null default now()
    );

    create table public.gate_devices (
      id uuid primary key default gen_random_uuid(),
      device_code text unique not null,
      is_active boolean not null default false
    );

    create table public.offline_device_tokens (
      id uuid primary key default gen_random_uuid(),
      gate_device_id uuid not null,
      device_code text not null,
      token_hash text not null,
      is_active boolean not null default true,
      revoked_at timestamptz
    );

    create table public.gate_auth_failures (
      id uuid primary key default gen_random_uuid(),
      device_code text,
      source text,
      created_at timestamptz default now()
    );

    create or replace function public.log_gate_auth_failure(p_device_code text, p_source text)
    returns void language sql security definer as $$
      insert into public.gate_auth_failures (device_code, source) values (p_device_code, p_source);
    $$;

    create or replace function public.hash_offline_device_token(p_token text)
    returns text language sql immutable as $$
      -- Production uses sha256 from pgcrypto; the harness only needs a
      -- deterministic built-in hash to exercise the verification logic.
      select md5(coalesce(p_token, ''));
    $$;

    create or replace function public.hash_trusted_device_token(p_token text)
    returns text language sql immutable as $$
      select md5(coalesce(p_token, ''));
    $$;

    grant usage on schema public to anon, authenticated, service_role;
    grant select, insert, update, delete on public.employee_registrations to anon, authenticated, service_role;
  `);

  // Production-shaped pre-migration state: a public bucket with the two
  // permissive policies, and legacy rows holding public object URLs.
  await db.exec(`
    insert into storage.buckets (id, name, public) values ('employee-photos', 'employee-photos', true);
    insert into storage.buckets (id, name, public) values ('violation-photos', 'violation-photos', false);

    create policy "Anyone can read employee photos" on storage.objects
      for select to anon, authenticated using (bucket_id = 'employee-photos');
    create policy "Anyone can upload employee photos" on storage.objects
      for insert to anon, authenticated with check (bucket_id = 'employee-photos');
    create policy "Admins can read violation photos" on storage.objects
      for select to authenticated using (bucket_id = 'violation-photos');

    insert into storage.objects (bucket_id, name, metadata, created_at) values
      ('employee-photos', 'registrations/80632/legacy.jpeg', '{"mimetype":"image/jpeg","size":1000}'::jsonb, now() - interval '5 days'),
      ('employee-photos', 'registrations/97919/legacy.png',  '{"mimetype":"image/png","size":2000}'::jsonb,  now() - interval '5 days');

    insert into public.employee_registrations (employee_id, mobile_number, full_name, employee_photo_url, status) values
      ('80632', '0790000000', 'Synthetic A', '${LEGACY_PUBLIC("80632", "legacy.jpeg")}', 'APPROVED'),
      ('97919', '0790000001', 'Synthetic B', '${LEGACY_PUBLIC("97919", "legacy.png")}', 'PENDING'),
      ('55555', '0790000002', 'Synthetic C', 'https://cdn.example.com/not-parseable.jpg', 'PENDING');
  `);

  return db;
}

(async () => {
  const db = await newDatabase();

  // -------------------------------------------------------------- migration runs
  await db.exec(MIGRATION);
  console.log("PASS migration applies cleanly on a Production-shaped schema");

  // -------------------------------------------------------------- bucket boundary
  {
    const row = (await db.query("select public, file_size_limit, allowed_mime_types from storage.buckets where id = 'employee-photos'")).rows[0];
    assert.equal(row.public, false, "employee-photos must not be public");
    assert.equal(Number(row.file_size_limit), 2097152, "2 MiB file size limit");
    assert.deepEqual(row.allowed_mime_types, ["image/jpeg", "image/png", "image/webp"]);
    const violation = (await db.query("select public, file_size_limit from storage.buckets where id = 'violation-photos'")).rows[0];
    assert.equal(violation.public, false);
    assert.equal(violation.file_size_limit, null, "unrelated buckets are untouched");
    console.log("PASS employee-photos is private with enforced MIME and size limits");
  }

  // -------------------------------------------------------------- policy surface
  {
    const policies = (await db.query(
      "select policyname, cmd, roles::text as roles, qual, with_check from pg_policies where schemaname='storage' and tablename='objects' order by policyname"
    )).rows;
    const names = policies.map((p) => p.policyname);
    assert.ok(!names.includes("Anyone can read employee photos"), "public read policy removed");
    assert.ok(!names.includes("Anyone can upload employee photos"), "unrestricted upload policy removed");
    assert.ok(names.includes("Registration can upload employee photos"), "constrained upload policy present");
    assert.ok(names.includes("Admins can read violation photos"), "unrelated policies preserved");

    const granted = policies.find((p) => p.policyname === "Registration can upload employee photos");
    assert.equal(granted.cmd, "INSERT");
    assert.deepEqual(granted.roles, "{anon,authenticated}");
    assert.equal(granted.qual, null, "insert policies carry no using clause");

    const employeePolicies = policies.filter((p) => String(p.qual || "").includes("employee-photos") || String(p.with_check || "").includes("employee-photos"));
    assert.equal(employeePolicies.length, 1, "only the upload policy may reference employee-photos");
    assert.equal(employeePolicies[0].cmd, "INSERT", "no select/update/delete policy may exist for employee-photos");
    console.log("PASS no read policy remains for employee-photos and the upload policy is constrained");
  }

  // -------------------------------------------------------------- anonymous access
  {
    const anonReads = await asRole(db, "anon", () =>
      scalar(db, "select count(*)::int from storage.objects where bucket_id = 'employee-photos'")
    );
    assert.equal(anonReads, 0, "anonymous read of employee photos returns no rows");
    console.log("PASS anonymous read of employee-photos is blocked by RLS");
  }
  {
    const authenticatedReads = await asRole(db, "authenticated", () =>
      scalar(db, "select count(*)::int from storage.objects where bucket_id = 'employee-photos'")
    );
    assert.equal(authenticatedReads, 0, "an authenticated non-admin still cannot read employee photos");
    console.log("PASS authenticated read of employee-photos is blocked (direct URL equivalent)");
  }
  {
    const visible = await asRole(db, "anon", () =>
      scalar(db, "select count(*)::int from storage.objects where bucket_id = 'violation-photos'")
    );
    assert.equal(visible, 0, "violation photos stay private to admins");
    console.log("PASS violation-photos isolation is preserved");
  }

  // -------------------------------------------------------------- upload constraints
  {
    await asRole(db, "anon", async () => {
      await db.query(
        "insert into storage.objects (bucket_id, name, metadata) values ('employee-photos', 'registrations/80632/new-valid.jpeg', $1)",
        [JSON.stringify({ mimetype: "image/jpeg", size: 1024 })]
      );
    });
    assert.equal(
      await scalar(db, "select count(*)::int from storage.objects where name = 'registrations/80632/new-valid.jpeg'"),
      1
    );
    console.log("PASS a valid registration upload is accepted");
  }
  {
    await asRole(db, "anon", async () => {
      await rejects(
        db.query("insert into storage.objects (bucket_id, name, metadata) values ('employee-photos', 'registrations/80632/a.txt', $1)", [
          JSON.stringify({ mimetype: "text/plain", size: 100 })
        ]),
        /row-level security/,
        "non-image MIME rejected"
      );
      await rejects(
        db.query("insert into storage.objects (bucket_id, name, metadata) values ('employee-photos', 'registrations/80632/a.gif', $1)", [
          JSON.stringify({ mimetype: "image/jpeg", size: 100 })
        ]),
        /row-level security/,
        "disallowed extension rejected"
      );
      await rejects(
        db.query("insert into storage.objects (bucket_id, name, metadata) values ('employee-photos', 'uploads/80632/a.jpeg', $1)", [
          JSON.stringify({ mimetype: "image/jpeg", size: 100 })
        ]),
        /row-level security/,
        "upload outside registrations/ rejected"
      );
      await rejects(
        db.query("insert into storage.objects (bucket_id, name, metadata) values ('employee-photos', 'registrations/80632/huge.jpeg', $1)", [
          JSON.stringify({ mimetype: "image/jpeg", size: 5 * 1024 * 1024 })
        ]),
        /row-level security/,
        "oversized upload rejected"
      );
      await rejects(
        db.query("insert into storage.objects (bucket_id, name, metadata) values ('employee-photos', 'registrations/80632/unknown.jpeg', $1)", [
          JSON.stringify({ size: 100 })
        ]),
        /row-level security/,
        "missing MIME metadata rejected"
      );
      await rejects(
        db.query("insert into storage.objects (bucket_id, name, metadata) values ('violation-photos', 'violations/1/a.jpeg', $1)", [
          JSON.stringify({ mimetype: "image/jpeg", size: 100 })
        ]),
        /row-level security/,
        "employee policy must not open other buckets"
      );
    });
    console.log("PASS invalid MIME, extension, folder, size and bucket are all rejected");
  }
  {
    await asRole(db, "anon", async () => {
      const updated = await db.query("update storage.objects set metadata = '{\"mimetype\":\"image/jpeg\",\"size\":1}'::jsonb where name = 'registrations/80632/new-valid.jpeg'");
      assert.equal(updated.affectedRows ?? 0, 0, "no anonymous update path");
      const deleted = await db.query("delete from storage.objects where name = 'registrations/80632/new-valid.jpeg'");
      assert.equal(deleted.affectedRows ?? 0, 0, "no anonymous delete path");
    });
    console.log("PASS anonymous update/delete of objects has no effect");
  }

  // -------------------------------------------------------------- backfill
  {
    const rows = (await db.query("select employee_id, employee_photo_url from public.employee_registrations order by employee_id")).rows;
    const byId = Object.fromEntries(rows.map((r) => [r.employee_id, r.employee_photo_url]));
    assert.equal(byId["80632"], "registrations/80632/legacy.jpeg", "legacy public URL converted to an object path");
    assert.equal(byId["97919"], "registrations/97919/legacy.png");
    assert.equal(byId["55555"], "https://cdn.example.com/not-parseable.jpg", "unparseable values are left for review");
    console.log("PASS legacy public URLs are backfilled to object paths");
  }
  {
    const path1 = await scalar(db, "select private.employee_photo_object_path($1)", [LEGACY_PUBLIC("80632", "legacy.jpeg")]);
    assert.equal(path1, "registrations/80632/legacy.jpeg");
    const signedUrl = await scalar(db, "select private.employee_photo_object_path($1)", [
      "https://x.supabase.co/storage/v1/object/sign/employee-photos/registrations/80632/legacy.jpeg?token=abc"
    ]);
    assert.equal(signedUrl, "registrations/80632/legacy.jpeg");
    assert.equal(await scalar(db, "select private.employee_photo_object_path($1)", [""]), null);
    assert.equal(await scalar(db, "select private.employee_photo_object_path($1)", ["https://evil.example/x.jpg"]), null);
    assert.equal(await scalar(db, "select private.is_valid_employee_photo_path($1)", ["registrations/80632/a.exe"]), false);
    assert.equal(await scalar(db, "select private.is_valid_employee_photo_path($1)", ["registrations/80632/a.webp"]), true);
    console.log("PASS path normalisation handles public URLs, signed URLs and invalid values");
  }

  // -------------------------------------------------------------- legacy reference count
  {
    const legacyAny = await scalar(
      db,
      "select count(*)::int from public.employee_registrations where employee_photo_url like 'http%'"
    );
    assert.equal(legacyAny, 1, "only a reference that cannot be interpreted may survive the backfill");

    const publicBucket = await scalar(
      db,
      "select count(*)::int from public.employee_registrations where employee_photo_url like '%/storage/v1/object/public/employee-photos/%'"
    );
    assert.equal(publicBucket, 0, "every employee-photos public URL was converted to an object path");

    const unparseable = await scalar(
      db,
      `select count(*)::int from public.employee_registrations
       where coalesce(employee_photo_url, '') <> ''
         and private.employee_photo_object_path(employee_photo_url) is null`
    );
    assert.equal(unparseable, 1, "the survivor is exactly the value that needs manual review");

    // Production currently holds no such row, so the required post-apply check
    // reaches 0 once the operator resolves the review item.
    await db.exec("update public.employee_registrations set employee_photo_url = null where employee_id = '55555'");
    assert.equal(
      await scalar(db, "select count(*)::int from public.employee_registrations where employee_photo_url like 'http%'"),
      0,
      "the documented post-apply check returns 0"
    );
    console.log("PASS the post-apply check 'employee_photo_url like http%' returns 0");
  }

  // -------------------------------------------------------------- ledger isolation
  {
    await asRole(db, "anon", async () => {
      await rejects(db.query("select count(*) from private.pending_employee_uploads"), /permission denied/, "anon cannot read the ledger");
      await rejects(db.query("insert into private.pending_employee_uploads (object_path) values ('registrations/1/a.jpeg')"), /permission denied/, "anon cannot write the ledger");
    });
    await asRole(db, "authenticated", async () => {
      await rejects(db.query("select count(*) from private.pending_employee_uploads"), /permission denied/, "authenticated cannot read the ledger");
    });
    console.log("PASS the pending-upload ledger is unreachable from anon and authenticated");
  }

  // -------------------------------------------------------------- ledger RPC + trigger
  {
    const invalid = await asRole(db, "anon", async () =>
      (await db.query("select public.register_pending_employee_upload($1) as r", ["../../etc/passwd"])).rows[0].r
    );
    assert.equal(invalid.ok, false, "invalid path refused");

    const valid = await asRole(db, "anon", async () =>
      (await db.query("select public.register_pending_employee_upload($1) as r", ["registrations/99999/abandoned.jpeg"])).rows[0].r
    );
    assert.equal(valid.ok, true);
    assert.equal(
      await scalar(db, "select status from private.pending_employee_uploads where object_path = 'registrations/99999/abandoned.jpeg'"),
      "PENDING"
    );
    assert.equal(
      await scalar(db, "select count(*)::int from private.pending_employee_uploads where object_path = 'registrations/99999/abandoned.jpeg'"),
      1,
      "re-registering the same path is idempotent"
    );
    console.log("PASS register_pending_employee_upload validates the path and is idempotent");
  }
  {
    await db.exec(`
      insert into public.employee_registrations (employee_id, mobile_number, full_name, employee_photo_url, status)
      values ('77777', '0790000003', 'Synthetic D', 'registrations/77777/pending.jpeg', 'PENDING');
    `);
    const linked = (await db.query("select status, linked_at, registration_id from private.pending_employee_uploads where object_path = 'registrations/77777/pending.jpeg'")).rows[0];
    assert.equal(linked.status, "LINKED", "trigger links the ledger entry");
    assert.ok(linked.linked_at, "linked_at is stamped");
    assert.ok(linked.registration_id, "registration_id is stamped");

    await db.exec(`
      insert into public.employee_registrations (employee_id, mobile_number, full_name, employee_photo_url, status)
      values ('88888', '0790000004', 'Synthetic E', 'registrations/88888/never-ledgered.jpeg', 'PENDING');
    `);
    assert.equal(
      await scalar(db, "select status from private.pending_employee_uploads where object_path = 'registrations/88888/never-ledgered.jpeg'"),
      "LINKED",
      "a registration always creates a linked ledger row"
    );
    console.log("PASS the registration trigger links (or creates) the ledger entry");
  }

  // -------------------------------------------------------------- orphan sweep
  {
    await db.exec(`
      insert into storage.objects (bucket_id, name, metadata, created_at) values
        ('employee-photos', 'registrations/80632/linked-old.jpeg',    '{"mimetype":"image/jpeg","size":1000}'::jsonb, now() - interval '9 days'),
        ('employee-photos', 'registrations/80632/orphan-old.jpeg',    '{"mimetype":"image/jpeg","size":1000}'::jsonb, now() - interval '9 days'),
        ('employee-photos', 'registrations/99999/abandoned.jpeg',     '{"mimetype":"image/jpeg","size":1000}'::jsonb, now() - interval '2 days'),
        ('employee-photos', 'registrations/80632/fresh.jpeg',         '{"mimetype":"image/jpeg","size":1000}'::jsonb, now() - interval '1 hour');
    `);
    await db.exec(`
      insert into public.employee_registrations (employee_id, mobile_number, full_name, employee_photo_url, status)
      values ('80632', '0790000000', 'Synthetic A updated', 'registrations/80632/linked-old.jpeg', 'APPROVED');
    `);

    await asRole(db, "anon", async () => {
      await rejects(
        db.query("select public.employee_photo_sweep_candidates(24, 200, true)"),
        /permission denied/,
        "anon cannot run the sweep"
      );
    });

    const dry = (await db.query("select public.employee_photo_sweep_candidates(24, 200, true) as r")).rows[0].r;
    assert.equal(dry.ok, true);
    assert.equal(dry.mode, "DRY_RUN");
    const paths = dry.paths.slice().sort();
    assert.deepEqual(
      paths,
      ["registrations/99999/abandoned.jpeg", "registrations/80632/orphan-old.jpeg"].sort(),
      "only unlinked objects older than the retention window are candidates"
    );
    assert.ok(!paths.includes("registrations/80632/linked-old.jpeg"), "linked photos are protected");
    assert.ok(!paths.includes("registrations/80632/fresh.jpeg"), "recent uploads are protected");
    assert.ok(!paths.includes("registrations/80632/legacy.jpeg"), "referenced legacy objects are protected");
    console.log("PASS dry-run sweep selects only unlinked, expired, unreferenced objects");
  }
  {
    const marked = (await db.query("select public.employee_photo_sweep_candidates(24, 200, false) as r")).rows[0].r;
    assert.equal(marked.mode, "MARKED");
    assert.equal(
      await scalar(db, "select status from private.pending_employee_uploads where object_path = 'registrations/99999/abandoned.jpeg'"),
      "ORPHAN"
    );
    const again = (await db.query("select public.employee_photo_sweep_candidates(24, 200, true) as r")).rows[0].r;
    assert.ok(!again.paths.includes("registrations/99999/abandoned.jpeg"), "a marked path is not offered twice");
    console.log("PASS a marking sweep flags candidates and does not repeat them");
  }
  {
    await asRole(db, "anon", async () => {
      await rejects(db.query("select public.employee_photo_confirm_removal(array['registrations/99999/abandoned.jpeg'])"), /permission denied/, "anon cannot confirm removals");
    });
    const deleted = await scalar(db, "select public.employee_photo_confirm_removal($1) as c", [
      ["registrations/99999/abandoned.jpeg", "registrations/80632/linked-old.jpeg"]
    ]);
    assert.equal(deleted, 1, "only non-linked ledger rows are deleted");
    assert.equal(
      await scalar(db, "select count(*)::int from private.pending_employee_uploads where object_path = 'registrations/80632/linked-old.jpeg'"),
      1,
      "linked rows survive confirmation"
    );
    console.log("PASS confirm_removal deletes only unlinked ledger rows");
  }
  {
    await rejects(
      db.query("select public.employee_photo_sweep_candidates(0, 200, true)"),
      /p_retention_hours must be/,
      "retention floor enforced"
    );
    console.log("PASS the sweep refuses a zero retention window");
  }

  // -------------------------------------------------------------- resolver verification RPCs
  {
    await db.exec(`
      insert into public.gate_devices (device_code, is_active) values ('gate-1', true), ('gate-off', false);
    `);
    const gateId = await scalar(db, "select id from public.gate_devices where device_code = 'gate-1'");
    await db.exec(`
      insert into public.offline_device_tokens (gate_device_id, device_code, token_hash, is_active)
      values ('${gateId}', 'gate-1', public.hash_offline_device_token('gate-token'), true);
    `);

    await asRole(db, "anon", async () => {
      await rejects(db.query("select public.verify_gate_device_credentials('gate-1','gate-token')"), /permission denied/, "anon cannot verify a gate device");
      await rejects(db.query("select public.verify_trusted_device_credentials(repeat('a',48))"), /permission denied/, "anon cannot verify a trusted device");
    });

    const missing = (await db.query("select public.verify_gate_device_credentials('', '') as r")).rows[0].r;
    assert.equal(missing.reason, "MISSING_CREDENTIALS");
    const notApproved = (await db.query("select public.verify_gate_device_credentials('gate-off','gate-token') as r")).rows[0].r;
    assert.equal(notApproved.reason, "DEVICE_NOT_APPROVED");
    const unknownDevice = (await db.query("select public.verify_gate_device_credentials('nope','gate-token') as r")).rows[0].r;
    assert.equal(unknownDevice.reason, "DEVICE_NOT_APPROVED");
    const badToken = (await db.query("select public.verify_gate_device_credentials('gate-1','wrong') as r")).rows[0].r;
    assert.equal(badToken.reason, "INVALID_DEVICE_TOKEN");
    const good = (await db.query("select public.verify_gate_device_credentials('gate-1','gate-token') as r")).rows[0].r;
    assert.equal(good.ok, true);
    assert.equal(good.device_code, "gate-1");
    assert.ok((await scalar(db, "select count(*)::int from public.gate_auth_failures")) >= 3, "auth failures are audited");
    console.log("PASS gate-device verification is service-role only and audits failures");
  }
  {
    const shortToken = (await db.query("select public.verify_trusted_device_credentials('abc') as r")).rows[0].r;
    assert.equal(shortToken.reason, "INVALID_DEVICE_TOKEN");
    const notTrusted = (await db.query("select public.verify_trusted_device_credentials($1) as r", ["b".repeat(48)])).rows[0].r;
    assert.equal(notTrusted.reason, "DEVICE_NOT_TRUSTED");

    await db.exec(`
      insert into public.employee_registrations (employee_id, mobile_number, full_name, status, trusted_device_enabled, trusted_device_token_hash)
      values ('90909', '0790000009', 'Synthetic F', 'APPROVED', true, public.hash_offline_device_token('${"c".repeat(48)}'));
    `);
    const trusted = (await db.query("select public.verify_trusted_device_credentials($1) as r", ["c".repeat(48)])).rows[0].r;
    assert.equal(trusted.ok, true);
    assert.equal(trusted.employee_id, "90909");
    const auditBefore = await scalar(db, "select count(*)::int from public.gate_auth_failures");
    await db.query("select public.verify_trusted_device_credentials($1)", ["c".repeat(48)]);
    assert.equal(
      await scalar(db, "select count(*)::int from public.gate_auth_failures"),
      auditBefore,
      "resolving a photo must not write audit rows"
    );
    console.log("PASS trusted-device verification is read-only and service-role only");
  }

  // -------------------------------------------------------------- rollback
  {
    await db.exec(ROLLBACK);
    const bucket = (await db.query("select public, file_size_limit, allowed_mime_types from storage.buckets where id = 'employee-photos'")).rows[0];
    assert.equal(bucket.public, true, "bucket restored to public");
    assert.equal(bucket.file_size_limit, null);
    assert.equal(bucket.allowed_mime_types, null);

    const names = (await db.query("select policyname from pg_policies where schemaname='storage' and tablename='objects'")).rows.map((r) => r.policyname);
    assert.ok(names.includes("Anyone can read employee photos"), "legacy read policy restored");
    assert.ok(names.includes("Anyone can upload employee photos"), "legacy upload policy restored");
    assert.ok(!names.includes("Registration can upload employee photos"), "constrained policy removed");

    assert.equal(await scalar(db, "select to_regclass('private.pending_employee_uploads')::text"), null, "ledger dropped");
    assert.equal(await scalar(db, "select to_regprocedure('public.register_pending_employee_upload(text)')::text"), null, "ledger RPC dropped");
    assert.equal(await scalar(db, "select to_regprocedure('public.verify_gate_device_credentials(text,text)')::text"), null, "gate verification dropped");
    assert.equal(await scalar(db, "select to_regprocedure('public.verify_trusted_device_credentials(text)')::text"), null, "trusted-device verification dropped");
    assert.equal(await scalar(db, "select count(*)::int from pg_trigger where tgname = 'trg_link_pending_employee_upload'"), 0, "trigger dropped");
    console.log("PASS rollback restores the previous storage boundary and removes every new object");
  }
  {
    // The forward migration must be re-appliable after a rollback.
    await db.exec(MIGRATION);
    assert.equal((await db.query("select public from storage.buckets where id = 'employee-photos'")).rows[0].public, false);
    console.log("PASS the migration is idempotent and re-applies after a rollback");
  }

  await db.close();
  console.log("\nAll private employee photo policy tests passed.");
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
