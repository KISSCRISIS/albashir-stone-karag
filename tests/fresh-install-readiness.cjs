const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { PGlite } = require('@electric-sql/pglite');
const { pgcrypto } = require('@electric-sql/pglite/contrib/pgcrypto');
const root = path.resolve(__dirname, '..');
const baseline = fs.readFileSync(path.join(root,'schema_consolidated_fresh_install.sql'),'utf8');
const snapshot = JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/security-helpers.production.json'),'utf8'));
async function asRole(db,role,sql,params=[]) {
  await db.exec(`set role ${role}`);
  try { return await db.query(sql,params); } finally { await db.exec('reset role'); }
}
(async()=>{
  const marker='\n-- =============================================================================\n-- STAGING READINESS CORRECTION CANDIDATE';
  const end=baseline.indexOf(marker);
  assert.ok(end>0);
  assert.equal(crypto.createHash('sha256').update(baseline.slice(0,end)).digest('hex'),'fe1c50564f317547032976ae7973cefdef9b79ba262ac1dc80335bee6bae80a3','historical layers must remain byte-identical');
  const db=new PGlite({extensions:{pgcrypto}});
  try {
    await db.exec(`
      create role anon; create role authenticated; create role service_role bypassrls;
      create schema extensions; create extension pgcrypto with schema extensions;
      create schema auth; create table auth.users(id uuid primary key,email text);
      create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
      create schema storage;
      create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
      create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text,metadata jsonb,created_at timestamptz default now());
      alter table storage.objects enable row level security;
      create function storage.foldername(name text) returns text[] language sql immutable as $$select (string_to_array(name,'/'))[1:array_length(string_to_array(name,'/'),1)-1]$$;
      create function storage.extension(name text) returns text language sql immutable as $$select lower(substring(name from '\\.([^.]+)$'))$$;
      grant usage on schema public,auth,storage,extensions to anon,authenticated,service_role;
      grant all on all tables in schema storage to anon,authenticated,service_role;
      create publication supabase_realtime;
    `);
    await db.exec(baseline);
    console.log('PASS complete fresh-install execution with real local pgcrypto');
    for (const f of snapshot.functions) {
      const row=(await db.query('select pg_get_functiondef($1::regprocedure) as definition',[`public.${f.signature}`])).rows[0];
      assert.equal(row.definition.replace(/\r\n/g,'\n'),f.definition.replace(/\r\n/g,'\n'),'live helper body/signature/search_path preserved (line endings normalized)');
      const acl=(await db.query("select has_function_privilege('anon',$1::regprocedure,'execute') as anon,has_function_privilege('authenticated',$1::regprocedure,'execute') as authenticated,has_function_privilege('service_role',$1::regprocedure,'execute') as service",[`public.${f.signature}`])).rows[0];
      assert.deepEqual(acl,{anon:false,authenticated:false,service:false});
    }
    await assert.rejects(asRole(db,'anon',"select public.write_security_attempt('employee_profile_login','SYN-A','000',false)"),/permission denied/);
    await assert.rejects(asRole(db,'authenticated','select * from public.security_attempt_logs'),/permission denied/);
    const tables=['employee_registrations','specialty_daily_limits','gate_access_logs','violation_reports','admin_profiles','admin_audit_logs','employee_data_change_requests'];
    for (const table of tables) {
      const row=(await db.query("select has_table_privilege('authenticated',$1::regclass,'select') as authenticated,has_table_privilege('anon',$1::regclass,'select') as anon,(select relrowsecurity from pg_class where oid=$1::regclass) as rls",[`public.${table}`])).rows[0];
      assert.deepEqual(row,{authenticated:true,anon:false,rls:true});
    }
    for(const role of ['anon','authenticated']) {
      assert.equal((await db.query('select has_table_privilege($1,\'public.guard_screen_status\',\'select\') as allowed',[role])).rows[0].allowed,false);
    }
    assert.equal((await asRole(db,'authenticated','select * from public.employee_registrations')).rows.length,0);
    await db.exec("insert into public.employee_registrations(full_name,employee_id,mobile_number,specialty,status,job_type,department,employee_photo_url) values('Synthetic A','SYN-A','0000000000','Audit','PENDING','Audit','Audit','registrations/SYN-A/a.jpg')");
    const login=async(role,id,mobile)=>(await asRole(db,role,'select public.employee_profile_login($1,$2) as result',[id,mobile])).rows[0].result;
    assert.equal((await login('service_role','SYN-A','0000000000')).ok,true);
    assert.equal((await login('anon','SYN-A','0000000000')).ok,true);
    assert.equal((await db.query("select public.is_rate_limited('employee_profile_login','SYN-A',5,5) as limited")).rows[0].limited,false,'successful logins do not count toward limit');
    for(let i=0;i<5;i++) assert.equal((await login('anon','SYN-A','invalid')).ok,false);
    const attempts=(await db.query("select count(*)::int as count from public.security_attempt_logs where employee_id='SYN-A'")).rows[0].count;
    assert.equal(attempts,7);
    assert.equal((await db.query("select public.is_rate_limited('employee_profile_login','SYN-A',5,5) as limited")).rows[0].limited,true);
    assert.equal((await login('service_role','SYN-A','0000000000')).ok,false,'valid credentials still denied during active limit');
    assert.equal((await db.query("select count(*)::int as count from public.security_attempt_logs where employee_id='SYN-A'")).rows[0].count,attempts,'limited call preserves live no-additional-log behavior');
    assert.equal((await db.query("select public.is_rate_limited('other-action','SYN-A',5,5) as limited")).rows[0].limited,false);
    assert.equal((await db.query("select public.is_rate_limited('employee_profile_login','OTHER-ID',5,5) as limited")).rows[0].limited,false);
    await db.exec("update public.security_attempt_logs set created_at=now()-interval '6 minutes' where success=false");
    assert.equal((await login('service_role','SYN-A','0000000000')).ok,true,'expired failures no longer deny');
    assert.equal((await db.query("select count(*)::int as count from public.security_attempt_logs where success=false and mobile_hash<>md5('invalid')")).rows[0].count,0,'existing mobile hash behavior preserved');
    await db.exec("insert into public.admin_profiles(auth_user_id,email,role,is_active) values('00000000-0000-0000-0000-000000000001','synthetic@example.invalid','SUPER_ADMIN',true)");
    await db.query("select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false)");
    assert.equal((await asRole(db,'authenticated','select * from public.employee_registrations')).rows.length,1);
    await db.query("select set_config('request.jwt.claim.sub','',false)");
    assert.equal((await asRole(db,'authenticated','select * from public.employee_registrations')).rows.length,0);
    console.log('PASS helper ACLs, preserved live rate limit/audit, minimal grants and RLS admin filtering');
    await db.exec(fs.readFileSync(path.join(root,'supabase/migrations/20261006190000_private_employee_photos.sql'),'utf8'));
    assert.equal((await login('service_role','SYN-A','0000000000')).ok,true,'backend employee verification still works after photo migration');
    assert.equal((await db.query("select public from storage.buckets where id='employee-photos'")).rows[0].public,false);
    assert.equal((await db.query("select public from storage.buckets where id='violation-photos'")).rows[0].public,false);
    console.log('PASS photo migration on complete corrected baseline and backend profile verification');
    console.log('LOCAL READINESS CHECKS PASS; hosted Staging/Storage HTTP tests NOT RUN.');
  } finally { await db.close(); }
})().catch(e=>{console.error(e);process.exitCode=1;});
