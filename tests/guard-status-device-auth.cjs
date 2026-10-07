const assert=require('node:assert/strict'),fs=require('fs'),path=require('path'),vm=require('vm');
const {PGlite}=require('@electric-sql/pglite');
const read=f=>fs.readFileSync(path.join(__dirname,'..',f),'utf8');
const intro=read('supabase/migrations/20261007110000_guard_status_device_auth.sql'),retire=read('supabase/guard_status_retire_direct_read.sql');
(async()=>{const db=await PGlite.create();try{
await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
CREATE TABLE gate_devices(id uuid,device_code text,is_active boolean);
CREATE TABLE offline_device_tokens(gate_device_id uuid,device_code text,token_hash text,is_active boolean,revoked_at timestamptz);
CREATE TABLE guard_screen_status(id integer,current_status text,employee_name text,employee_id text,message text,updated_at timestamptz);
CREATE TABLE failures(code text,reason text);
CREATE FUNCTION hash_offline_device_token(text) RETURNS text LANGUAGE sql AS $$SELECT 'hash:'||$1$$;
CREATE FUNCTION log_gate_auth_failure(text,text) RETURNS void LANGUAGE sql AS $$INSERT INTO failures VALUES($1,$2)$$;
ALTER TABLE guard_screen_status ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can read guard screen status" ON guard_screen_status FOR SELECT TO anon,authenticated USING(true);
GRANT SELECT ON guard_screen_status TO anon,authenticated;
INSERT INTO gate_devices VALUES('11111111-1111-4111-8111-111111111111','GATE',true);
INSERT INTO offline_device_tokens VALUES('11111111-1111-4111-8111-111111111111','GATE','hash:VALID',true,null);
INSERT INTO guard_screen_status VALUES(1,'ALLOWED','Synthetic','SYN','Allowed',now());`);
await db.exec(intro);
assert.equal((await db.query("SELECT has_table_privilege('anon','guard_screen_status','SELECT') allowed")).rows[0].allowed,true,'introduction does not break old caller');
async function call(code,token){await db.exec('SET ROLE anon');try{return (await db.query('SELECT get_guard_screen_status($1,$2) result',[code,token])).rows[0].result;}finally{await db.exec('RESET ROLE');}}
for(const pair of [[null,null],['',''],[' ',' '],['UNKNOWN','VALID'],['GATE','INVALID']])assert.deepEqual(await call(...pair),{ok:false,error:'DENIED'});
for(const sql of ["UPDATE gate_devices SET is_active=false","UPDATE offline_device_tokens SET is_active=false","UPDATE offline_device_tokens SET revoked_at=now()"]){await db.exec(sql);assert.deepEqual(await call('GATE','VALID'),{ok:false,error:'DENIED'});await db.exec('UPDATE gate_devices SET is_active=true; UPDATE offline_device_tokens SET is_active=true,revoked_at=null');}
await db.exec(retire);
for(const role of ['anon','authenticated']){await db.exec('SET ROLE '+role);try{await assert.rejects(db.query('SELECT * FROM guard_screen_status'),/permission denied/);}finally{await db.exec('RESET ROLE');}}
const result=await call('GATE','VALID');assert.equal(result.ok,true);assert.equal(result.status.employee_id,'SYN');assert.equal(result.status.current_status,'ALLOWED');assert(!('mobile_number' in result.status));
await db.exec('DELETE FROM guard_screen_status');assert.deepEqual(await call('GATE','VALID'),{ok:true,status:null});
assert.equal((await db.query("SELECT EXISTS(SELECT 1 FROM pg_class c,LATERAL aclexplode(c.relacl) a WHERE c.oid='guard_screen_status'::regclass AND a.grantee=0 AND a.privilege_type='SELECT') allowed")).rows[0].allowed,false);
assert.equal((await db.query("SELECT has_function_privilege('service_role','get_guard_screen_status(text,text)','EXECUTE') allowed")).rows[0].allowed,true);
console.log('PASS staged ACL, missing/invalid/inactive/revoked device denial, valid synthetic contract and empty status');
}finally{await db.close();}
const index=read('index.html');assert(!index.includes('.from("guard_screen_status")'));assert(!index.includes('postgres_changes'));assert(!index.includes('subscribeToGuardStatus'));
for(const m of index.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi))if(!/src=/.test(m[1]))new vm.Script(m[2]);
const source=index.slice(index.indexOf('    async function pollGuardStatusFallback()'),index.indexOf('    async function copyQrLink()'));
let resolve,calls=0,errors=0,warnings=0,rows=0;
const context={AbortController,setTimeout,clearTimeout,guardStatusPollInFlight:false,supabaseClient:{rpc:(name,args)=>{assert.equal(name,'get_guard_screen_status');assert.equal(args.p_device_code,'GATE');assert.equal(args.p_device_token,'VALID');calls++;return {abortSignal:()=>new Promise(r=>resolve=r)};}},navigator:{onLine:true},getGateDevice:()=>({device_code:'GATE'}),getOfflineDeviceToken:()=>'VALID',normalizeRpcData:x=>x,qrRuntime:{},setQrDiagnostics:()=>{},processGuardStatusRow:async()=>{rows++;},recordGateError:()=>{errors++;},showSetupWarning:()=>{warnings++;}};
vm.createContext(context);vm.runInContext(source,context);
const first=context.pollGuardStatusFallback();await context.pollGuardStatusFallback();assert.equal(calls,1);resolve({data:{ok:true,status:{}},error:null});await first;assert.equal(rows,1);assert.equal(context.guardStatusPollInFlight,false);
for(const response of [{data:{ok:false},error:null},{data:null,error:new Error('transport')}]){const pending=context.pollGuardStatusFallback();resolve(response);await pending;assert.equal(context.guardStatusPollInFlight,false);}assert.equal(errors,2);assert.equal(warnings,2);
assert.equal(read('supabase/canonical/guard_status_device_auth.sql'),intro+'\n'+retire);assert(read('schema_consolidated_fresh_install.sql').includes(intro));
console.log('PASS frontend syntax, no direct/Realtime data exposure, nonoverlap and visible transport/auth failure');
})().catch(e=>{console.error(e);process.exitCode=1});
