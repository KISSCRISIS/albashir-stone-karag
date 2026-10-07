const fs=require('fs'),path=require('path'),assert=require('assert/strict');
const {PGlite}=require('@electric-sql/pglite');
const root=path.resolve(__dirname,'..'),fixtures=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/search-path-five.production.json'),'utf8'));
const sql=fs.readFileSync(path.join(root,'supabase/search_path_five_reviewed.sql'),'utf8');
(async()=>{const db=await PGlite.create();try{
await db.exec(`CREATE ROLE anon;CREATE ROLE authenticated;CREATE ROLE service_role;
CREATE TABLE employee_registrations(status text,full_name text,employee_id text,mobile_number text,specialty text,department text,job_type text,employee_photo_url text,trusted_device_last_used_at timestamptz,trusted_device_last_activity_at timestamptz);
CREATE SCHEMA hostile;
CREATE FUNCTION hostile.upper(text) RETURNS text LANGUAGE sql AS $$SELECT 'HIJACKED'$$;
CREATE FUNCTION hostile.replace(text,text,text) RETURNS text LANGUAGE sql AS $$SELECT 'HIJACKED'$$;`);
for(const f of fixtures){await db.exec(f.definition);await db.exec('GRANT EXECUTE ON FUNCTION public.'+f.signature+' TO PUBLIC,anon,authenticated,service_role');}
await db.exec('CREATE TRIGGER identity_guard BEFORE UPDATE ON employee_registrations FOR EACH ROW EXECUTE FUNCTION prevent_approved_employee_identity_change(); CREATE TRIGGER activity_sync BEFORE UPDATE ON employee_registrations FOR EACH ROW EXECUTE FUNCTION sync_trusted_device_activity();');
const before=(await db.query("SELECT oid::regprocedure::text signature,prosrc,proacl::text acl,proowner,provolatile,prosecdef FROM pg_proc WHERE pronamespace='public'::regnamespace")).rows;
const input=[null,'','DRS/NRS/EMT/MLT','الإسعاف والطوارئ','Other'];
async function behavior(){const result=[];for(const x of input)result.push((await db.query('SELECT public.normalize_specialty_name($1) normalized, public.is_permanently_allowed_specialty($1) permanent',[x])).rows[0]);for(const role of ['SUPER_ADMIN','ADMIN','SUB_ADMIN',null])result.push((await db.query('SELECT public.default_admin_permissions($1) permissions',[role])).rows[0]);return result;}
const expected=await behavior();await db.exec(sql);assert.deepEqual(await behavior(),expected);
await db.exec('SET search_path TO hostile,pg_catalog,public');assert.deepEqual(await behavior(),expected);
for(const f of before){const after=(await db.query('SELECT prosrc,proacl::text acl,proowner,provolatile,prosecdef,proconfig FROM pg_proc WHERE oid=$1::regprocedure',[`public.${f.signature}`])).rows[0];for(const key of ['prosrc','acl','proowner','provolatile','prosecdef'])assert.equal(after[key],f[key]);assert.deepEqual(after.proconfig,['search_path=pg_catalog']);}
await db.exec("INSERT INTO public.employee_registrations(status,full_name) VALUES('APPROVED','Synthetic');");
for(const col of ['full_name','employee_id','mobile_number','specialty','department','job_type','employee_photo_url'])await assert.rejects(db.exec(`UPDATE public.employee_registrations SET ${col}='changed'`),/Approved employee identity/);
await db.exec("UPDATE public.employee_registrations SET trusted_device_last_used_at='2026-10-07T00:00:00Z'");assert.equal((await db.query('SELECT trusted_device_last_used_at=trusted_device_last_activity_at synced FROM public.employee_registrations')).rows[0].synced,true);
await db.exec("INSERT INTO public.employee_registrations(status,full_name) VALUES('PENDING','Pending'); UPDATE public.employee_registrations SET full_name='Updated' WHERE status='PENDING'");
await db.exec(sql);assert.deepEqual(await behavior(),expected);
console.log('PASS five fixed paths, unchanged bodies/ACL/owner/volatility, hostile-path resistance, identity guard and activity sync; synthetic local DB only');
}finally{await db.close();}})().catch(e=>{console.error(e);process.exitCode=1});
