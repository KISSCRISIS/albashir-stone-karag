const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const {PGlite}=require('@electric-sql/pglite');
const root=path.resolve(__dirname,'..');
const read=f=>fs.readFileSync(path.join(root,f),'utf8').replace(/\r\n/g,'\n');
const fixtures=JSON.parse(read('tests/fixtures/guard-rpc.production.json'));
const phaseA=read('supabase/migrations/20261005213927_guard_rpc_phase_a.sql');
const phaseB=read('supabase/migrations/20261005213928_guard_rpc_phase_b.sql');
const migration=phaseA+'\n'+phaseB;
assert.doesNotMatch(phaseA,/REVOKE EXECUTE ON FUNCTION public\.get_guard_employee_result\(text\)/);
assert.equal(phaseB.split('\n').filter(l=>l.trim()&&!l.startsWith('--')).join('\n'),'REVOKE EXECUTE ON FUNCTION public.get_guard_employee_result(text) FROM PUBLIC, anon, authenticated;');
assert.equal(migration,read('supabase/canonical/guard_rpc_device_hardening.sql'));
const freshInstall=read('schema_consolidated_fresh_install.sql');
const correctionMarker='\n-- =============================================================================\n-- STAGING READINESS CORRECTION CANDIDATE';
assert.ok(freshInstall.split(correctionMarker)[0].trim().endsWith(migration.trim()));
assert.doesNotMatch(freshInstall.split(correctionMarker)[1]||'',/CREATE OR REPLACE FUNCTION public\.(?:get_guard_employee_result|reset_guard_screen)/i);
assert.doesNotMatch(migration,/\b(?:CREATE TABLE|ALTER TABLE|POLICY|DROP FUNCTION)\b/i);
assert.equal((migration.match(/CREATE OR REPLACE FUNCTION/g)||[]).length,1);
assert.ok(fs.readdirSync(path.join(root,'supabase/migrations')).every(f=>['20261007114535_public_guard_session_rpc.sql','20261007113049_trusted_device_admin_revocation_only.sql','20261007112137_admin_approval_activates_submitted_device.sql','20261005212905_manual_employee_check_require_qr.sql','20261005213927_guard_rpc_phase_a.sql','20261005213928_guard_rpc_phase_b.sql','20261006190000_private_employee_photos.sql','20261007110000_guard_status_device_auth.sql',"20261007094821_p2_18_trusted_device_binding_ttl.sql","20261007095927_p2_18_reenroll_keep_eligibility.sql","20261007101501_p2_18_enrollment_claim_acl_hardening.sql"].includes(f)));
(async()=>{
const db=await PGlite.create();
try{
await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
CREATE TABLE gate_devices(id uuid PRIMARY KEY,device_code text,is_active boolean,last_seen_at timestamptz,updated_at timestamptz);
CREATE TABLE offline_device_tokens(gate_device_id uuid,device_code text,token_hash text,is_active boolean,revoked_at timestamptz);
CREATE TABLE employee_registrations(id uuid PRIMARY KEY,employee_id text);
CREATE TABLE guard_screen_status(id integer,current_status text,employee_name text,employee_id text,message text,updated_at timestamptz);
CREATE TABLE auth_failures(code text,reason text);
CREATE FUNCTION hash_offline_device_token(text) RETURNS text LANGUAGE sql AS $$ SELECT 'hash:' || $1 $$;
CREATE FUNCTION log_gate_auth_failure(text,text) RETURNS void LANGUAGE sql AS $$ INSERT INTO auth_failures VALUES($1,$2) $$;
CREATE FUNCTION employee_result_details(uuid) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('id',$1,'full_name','Synthetic','employee_id','EMP','department','D','specialty','S','job_type','J','employee_type','J','classification','C','photo_url','/synthetic.png','status','APPROVED','mobile_number','SECRET') $$;
INSERT INTO gate_devices VALUES('11111111-1111-4111-8111-111111111111','GATE',true,null,null);
INSERT INTO offline_device_tokens VALUES('11111111-1111-4111-8111-111111111111','GATE','hash:VALID',true,null);
INSERT INTO employee_registrations VALUES('22222222-2222-4222-8222-222222222222','EMP');
INSERT INTO guard_screen_status(id,current_status) VALUES(1,'DENIED');`);
for(const f of fixtures){await db.exec(f.definition+';');await db.exec('GRANT EXECUTE ON FUNCTION public.'+f.signature+' TO anon,authenticated,service_role');}
const resetBefore=(await db.query("SELECT pg_get_functiondef('reset_guard_screen(text,text)'::regprocedure) body")).rows[0].body;
await db.exec(phaseA);
for(const role of ['anon','authenticated']){
 await db.exec('SET ROLE '+role);
 try{assert.equal((await db.query("SELECT get_guard_employee_result('EMP') result")).rows[0].result.full_name,'Synthetic');
 assert.equal((await db.query("SELECT get_guard_employee_result('EMP','GATE','VALID') result")).rows[0].result.full_name,'Synthetic');
 await assert.rejects(db.query('SELECT reset_guard_screen()'),/permission denied/);
 assert.equal((await db.query("SELECT reset_guard_screen('GATE','VALID') result")).rows[0].result.ok,true);
 }finally{await db.exec('RESET ROLE');}
}
assert.equal((await db.query("SELECT EXISTS(SELECT 1 FROM pg_proc p,LATERAL aclexplode(p.proacl) a WHERE p.oid='get_guard_employee_result(text)'::regprocedure AND a.grantee=0 AND a.privilege_type='EXECUTE') allowed")).rows[0].allowed,true);
console.log('PASS Phase A: old and new frontend contracts coexist; legacy reset denied');
await db.exec(phaseB);
console.log('PASS Phase B: legacy result revoked after frontend transition');
assert.equal((await db.query("SELECT pg_get_functiondef('reset_guard_screen(text,text)'::regprocedure) body")).rows[0].body,resetBefore);
for(const sig of ['reset_guard_screen()','get_guard_employee_result(text)']){
 for(const role of ['anon','authenticated']){
 assert.equal((await db.query('SELECT has_function_privilege($1,$2,\'EXECUTE\') allowed',[role,sig])).rows[0].allowed,false);
 await db.exec('SET ROLE '+role);
 try{await assert.rejects(db.query(sig.startsWith('reset')?'SELECT reset_guard_screen()':"SELECT get_guard_employee_result('EMP')"),/permission denied/);}finally{await db.exec('RESET ROLE');}
 }
 assert.equal((await db.query('SELECT has_function_privilege(\'service_role\',$1,\'EXECUTE\') allowed',[sig])).rows[0].allowed,true);
 assert.equal((await db.query("SELECT EXISTS(SELECT 1 FROM pg_proc p, LATERAL aclexplode(p.proacl) a WHERE p.oid=$1::regprocedure AND a.grantee=0 AND a.privilege_type='EXECUTE') allowed",[sig])).rows[0].allowed,false);
 console.log('PASS legacy ACL '+sig);
}
const fetch=async(code,token)=>{await db.exec('SET ROLE anon');try{return (await db.query("SELECT get_guard_employee_result('EMP',$1,$2) result",[code,token])).rows[0].result;}finally{await db.exec('RESET ROLE');}};
for(const [code,token] of [[null,null],['',''],['UNKNOWN','VALID'],['GATE','INVALID']])assert.equal((await fetch(code,token)).ok,false);
await db.exec('UPDATE gate_devices SET is_active=false');assert.equal((await fetch('GATE','VALID')).ok,false);
await db.exec('UPDATE gate_devices SET is_active=true; UPDATE offline_device_tokens SET revoked_at=now()');assert.equal((await fetch('GATE','VALID')).ok,false);
await db.exec('UPDATE offline_device_tokens SET revoked_at=null,is_active=false');assert.equal((await fetch('GATE','VALID')).ok,false);
await db.exec('UPDATE offline_device_tokens SET is_active=true');
const actual=await fetch('GATE','VALID');
assert.equal(actual.full_name,'Synthetic');assert.ok(!Object.hasOwn(actual,'mobile_number'));
assert.deepEqual(actual,(await db.query("SELECT get_guard_employee_result('EMP') result")).rows[0].result);
await db.exec('SET ROLE anon');assert.equal((await db.query("SELECT reset_guard_screen('GATE','VALID') result")).rows[0].result.ok,true);await db.exec('RESET ROLE');
assert.equal((await db.query('SELECT current_status FROM guard_screen_status')).rows[0].current_status,'READY');
console.log('PASS device authentication, exact result contract, no mobile, reset works');
const index=read('index.html');
const fetchSource=index.slice(index.indexOf('    async function fetchGuardEmployee('),index.indexOf('    function setDecision('));
const resetSource=index.slice(index.indexOf('    async function resetGuardDisplaySoon('),index.indexOf('    async function processGuardStatusRow('));
assert.equal((index.match(/rpc\("get_guard_employee_result"/g)||[]).length,1);
const calls=[],warnings=[],logs=[];
let response={data:actual,error:null},callback;
const context={supabaseClient:{rpc:async(name,args)=>{calls.push({name,args});return response;}},getGateDevice:()=>({device_code:'GATE'}),getOfflineDeviceToken:()=> 'VALID',normalizeRpcData:x=>x,showSetupWarning:(...a)=>warnings.push(a),console:{error:(...a)=>logs.push(a)},setManagedTimeout:(name,fn)=>{callback=fn;},setDecision:()=>{},refreshQrNow:async()=>{}};
vm.createContext(context);vm.runInContext(fetchSource+resetSource,context);
assert.equal((await context.fetchGuardEmployee('EMP')).full_name,'Synthetic');
assert.equal(calls[0].args.p_device_code,'GATE');assert.equal(calls[0].args.p_device_token,'VALID');
for(const failed of [{data:{ok:false,message:'denied'},error:null},{data:null,error:new Error('transport')}]){response=failed;await context.resetGuardDisplaySoon();await callback();assert.ok(warnings.length);assert.ok(logs.length);warnings.length=0;logs.length=0;}
console.log('PASS secure frontend caller and visible/logged reset errors');
console.log('ALL GUARD RPC TESTS PASS. Production untouched.');
}finally{await db.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
