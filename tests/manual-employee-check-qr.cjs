// Isolated PostgreSQL (PGlite); never connects to Supabase or uses real QR tokens.
// Run with @electric-sql/pglite available on NODE_PATH.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { PGlite } = require('@electric-sql/pglite');
const root = path.resolve(__dirname, '..');
const read = name => fs.readFileSync(path.join(root, name), 'utf8').replace(/\r\n/g, '\n');
const live = read('tests/fixtures/manual_employee_check.production.sql');
const canonical = read('supabase/canonical/manual_employee_check.sql').slice(read('supabase/canonical/manual_employee_check.sql').indexOf('CREATE OR REPLACE'));
const optional = `  IF nullif(trim(coalesce(p_qr_token, '')), '') IS NOT NULL THEN
    qr_ok := public.validate_and_use_qr_token(p_qr_token);
    IF NOT qr_ok THEN
      PERFORM public.set_guard_status('DENIED', NULL, clean_emp, 'QR غير صالح أو منتهي');
      RETURN jsonb_build_object('ok', true, 'result', 'DENIED', 'message', 'QR غير صالح أو منتهي، يرجى مسح QR جديد');
    END IF;
  END IF;`;
const mandatory = `  qr_ok := public.validate_and_use_qr_token(p_qr_token);
  IF qr_ok IS NOT TRUE THEN
    PERFORM public.set_guard_status('DENIED', NULL, clean_emp, 'QR غير صالح أو منتهي');
    RETURN jsonb_build_object('ok', true, 'result', 'DENIED', 'message', 'QR غير صالح أو منتهي، يرجى مسح QR جديد');
  END IF;`;
assert.equal(live.split(optional).length, 2);
assert.equal(canonical.trim(), live.replace(optional, mandatory).trim(), 'Only approved QR block may differ from captured live body');
const migrationFiles = fs.readdirSync(path.join(root, 'supabase/migrations')).filter(f=>f.endsWith('.sql'));
assert.equal(migrationFiles.filter(f=>f.includes('manual_employee_check_require_qr')).length,1);
const migration = read('supabase/migrations/20261005212905_manual_employee_check_require_qr.sql');
assert.equal(migration.slice(migration.indexOf('CREATE OR REPLACE')).trim(),canonical.trim());
assert.doesNotMatch(canonical,/\b(?:GRANT|REVOKE|DROP|ALTER TABLE|CREATE TABLE)\b/i);
const fresh = read('schema_consolidated_fresh_install.sql');
const last = fresh.slice(fresh.lastIndexOf('CREATE OR REPLACE FUNCTION public.manual_employee_check'));
assert.ok(last.startsWith(canonical.trim()),'Last fresh-install definition must be canonical');
const order = ['reg.status <>', 'reg.trusted_device_token_hash', 'qr_ok := public.validate_and_use_qr_token', 'is_permanently_allowed_specialty', 'FROM public.specialty_daily_limits'].map(s=>canonical.indexOf(s));
assert.ok(order.every((n,i)=>n>=0&&(i===0||n>order[i-1])));
const token = '12345678-1234-4234-8234-123456789abc';
const claim = '22345678-1234-4234-8234-123456789abc';
(async()=>{
 const db = await PGlite.create();
 try {
  await db.exec(`
   CREATE TABLE employee_registrations(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), employee_id text,mobile_number text,full_name text,specialty text,status text,job_type text,trusted_device_token_hash text,trusted_device_enabled boolean,trusted_device_revoked_at timestamptz);
   CREATE TABLE specialty_daily_limits(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),specialty_name text,is_active boolean,daily_limit integer);
   CREATE TABLE gate_access_logs(employee_registration_id uuid,employee_id text,mobile_number text,full_name text,specialty text,result text,reason text,qr_token uuid,created_at timestamptz DEFAULT now());
   CREATE TABLE qr_sessions(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),token uuid,expires_at timestamptz,used_at timestamptz,claim_token uuid,claim_expires_at timestamptz,claim_used_at timestamptz);
   CREATE TABLE test_events(kind text,value text);
   CREATE FUNCTION set_guard_status(text,text,text,text) RETURNS void LANGUAGE sql AS $$ INSERT INTO test_events VALUES ('guard',$1); $$;
   CREATE FUNCTION employee_result_details(uuid) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('employee_id',employee_id,'full_name',full_name,'status',status) FROM employee_registrations WHERE id=$1; $$;
   CREATE FUNCTION normalize_specialty_name(text) RETURNS text LANGUAGE sql AS $$ SELECT lower(trim($1)); $$;
   CREATE FUNCTION is_permanently_allowed_specialty(text) RETURNS boolean LANGUAGE plpgsql AS $$ BEGIN INSERT INTO test_events VALUES ('specialty',$1); RETURN $1='PERMANENT'; END; $$;
  `);
  await db.exec(read('tests/fixtures/validate_and_use_qr_token.production.sql').replace('public.validate_and_use_qr_token(', 'public.test_validator_impl('));
  await db.exec(`CREATE FUNCTION validate_and_use_qr_token(text) RETURNS boolean LANGUAGE plpgsql AS $$ BEGIN INSERT INTO test_events VALUES ('consume',$1); RETURN public.test_validator_impl($1); END; $$;`);
  await db.exec(live);
  await db.exec(live.replace('public.manual_employee_check(', 'public.baseline_manual_employee_check('));
  await db.exec('CREATE ROLE anon; CREATE ROLE authenticated; REVOKE EXECUTE ON FUNCTION manual_employee_check(text,text,text) FROM PUBLIC; GRANT EXECUTE ON FUNCTION manual_employee_check(text,text,text) TO anon,authenticated;');
  const aclBefore = (await db.query("SELECT proacl::text FROM pg_proc WHERE oid='manual_employee_check(text,text,text)'::regprocedure")).rows[0];
  await db.exec(migration);
  assert.deepEqual((await db.query("SELECT proacl::text FROM pg_proc WHERE oid='manual_employee_check(text,text,text)'::regprocedure")).rows[0],aclBefore,'Existing ACL must be preserved');
  async function runCase(fn,config){
   await db.exec('BEGIN');
   try {
    await db.query(`INSERT INTO employee_registrations(employee_id,mobile_number,full_name,specialty,status,job_type,trusted_device_token_hash,trusted_device_enabled,trusted_device_revoked_at) VALUES('EMP','PHONE','Synthetic employee',$1,$2,$3,'linked-hash',true,$4)`,[config.specialty||'PERMANENT',config.status||'APPROVED',config.job||'staff',config.revoked?'2020-01-01T00:00:00Z':null]);
    await db.query(`INSERT INTO qr_sessions(token,expires_at,used_at,claim_token,claim_expires_at,claim_used_at) VALUES($1,now()+$2::interval,$3,$4,now()+$5::interval,$6)`,[token,config.expired?'-1 minute':'1 minute',config.consumed||config.claim?'2020-01-01T00:00:00Z':null,config.claim?claim:null,config.claimExpired?'-1 minute':'5 minutes',config.claimConsumed?'2020-01-01T00:00:00Z':null]);
    if(config.limit!==undefined)await db.query("INSERT INTO specialty_daily_limits(specialty_name,is_active,daily_limit) VALUES($1,true,$2)",[config.specialty,config.limit]);
    if(config.used)await db.query("INSERT INTO gate_access_logs(employee_id,specialty,result) VALUES('OTHER',$1,'LIMITED')",[config.specialty]);
    const supplied=Object.hasOwn(config,'qr')?config.qr:config.claim?claim:token;
    const result=(await db.query(`SELECT public.${fn}('EMP','PHONE',$1) AS result`,[supplied])).rows[0].result;
    const events=(await db.query('SELECT * FROM test_events')).rows;
    const qrState=(await db.query('SELECT used_at IS NOT NULL AS used,claim_used_at IS NOT NULL AS claim_used FROM qr_sessions')).rows[0];
    if(config.replay){const again=(await db.query(`SELECT public.${fn}('EMP','PHONE',$1) AS result`,[supplied])).rows[0].result;assert.equal(again.result,'DENIED');}
    if(result.access){assert.ok(result.access.entry_time);assert.equal(typeof result.access.daily_visits,'number');result.access.entry_time='<time>';}
    return {result,events,qrState};
   } finally {await db.exec('ROLLBACK');}
  }
  const cases=[
   ['NULL',{qr:null},'DENIED'],['empty',{qr:''},'DENIED'],['whitespace',{qr:'   '},'DENIED'],['invalid',{qr:'invalid'},'DENIED'],
   ['expired',{expired:true},'DENIED'],['consumed',{consumed:true},'DENIED'],
   ['valid permanent',{replay:true},'ALLOWED'],['valid temporary',{specialty:'TEMP'},'LIMITED'],
   ['rejected before consume',{status:'REJECTED'},'DENIED'],['pending before consume',{status:'PENDING'},'DENIED'],
   ['revoked before consume',{revoked:true},'DENIED'],
   ['daily limit available',{specialty:'TEMP',limit:1},'LIMITED'],['daily limit exhausted',{specialty:'TEMP',limit:1,used:true},'DENIED'],
   ['permanent ignores exhausted limit',{specialty:'PERMANENT',limit:1,used:true},'ALLOWED'],
   ['valid claim and replay',{claim:true,replay:true},'ALLOWED'],['expired claim',{claim:true,claimExpired:true},'DENIED'],['consumed claim',{claim:true,claimConsumed:true},'DENIED']
  ];
  for(const [name,config,expected] of cases){
   const actual=await runCase('manual_employee_check',config);assert.equal(actual.result.result,expected,name);
   const early=config.status||config.revoked;
   assert.equal(actual.events.filter(e=>e.kind==='consume').length,early?0:1,name+' consume ordering');
   if(early||Object.hasOwn(config,'qr')||config.expired||config.consumed||config.claimExpired||config.claimConsumed)assert.equal(actual.events.filter(e=>e.kind==='specialty').length,0,name+' no specialty bypass');
   if(!Object.hasOwn(config,'qr'))assert.deepEqual(actual,await runCase('baseline_manual_employee_check',config),name+' preserves baseline behavior and fields');
   console.log('PASS '+name);
  }
  for(const qr of [null,'','   '])assert.equal((await runCase('baseline_manual_employee_check',{qr})).result.result,'ALLOWED','Baseline bypass confirmed');
  console.log('PASS complete live-body preservation, P0-3 order, ACL preservation and final fresh-install override');
  console.log('All isolated PostgreSQL regression checks PASS. Production NOT modified.');
 } finally {await db.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
