// Diagnose the current policy using Storage's pre-upload metadata contract.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { PGlite } = require('@electric-sql/pglite');
(async () => {
  const db = new PGlite();
  try {
    const sql = fs.readFileSync(path.join(__dirname, '../supabase/migrations/20261006190000_private_employee_photos.sql'), 'utf8');
    const policy = sql.match(/create policy "Registration can upload employee photos"[\s\S]*?\n\);/)[0];
    await db.exec(`create role anon; create role authenticated; create schema storage;
      create table storage.objects(bucket_id text,name text,metadata jsonb);
      alter table storage.objects enable row level security;
      grant usage on schema storage to anon,authenticated;
      grant insert on storage.objects to anon,authenticated;
      create function storage.foldername(name text) returns text[] language sql immutable as $$select (string_to_array(name,'/'))[1:2]$$;
      create function storage.extension(name text) returns text language sql immutable as $$select split_part(name,'.',2)$$;`);
    await db.exec(policy);
    await db.exec(fs.readFileSync(path.join(__dirname,'../supabase/employee_photo_upload_compatibility_reviewed.sql'),'utf8').replace(/DO \$\$[\s\S]*?END \$\$;/,''));
    for (const role of ['anon', 'authenticated']) {
      await db.exec('set role ' + role);
      await db.query('insert into storage.objects values($1,$2,$3)', ['employee-photos','registrations/STG-A/valid.png',{mimetype:'image/png',contentLength:68}]);
      await db.query('insert into storage.objects values($1,$2,$3)', ['employee-photos','registrations/STG-A/final.png',{mimetype:'image/png',size:68}]);
      await db.query('insert into storage.objects values($1,$2,$3)', ['employee-photos','registrations/STG-A/multipart.png',{mimetype:'image/png',contentLength:2098000}]);
      await assert.rejects(db.query('insert into storage.objects values($1,$2,$3)', ['employee-photos','registrations/STG-A/large.png',{mimetype:'image/png',size:3145728}]), /row-level security/);
      await db.exec('reset role');
    }
    console.log('PASS: corrected pre-upload and final metadata accepted for both roles.');
  } finally { await db.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
