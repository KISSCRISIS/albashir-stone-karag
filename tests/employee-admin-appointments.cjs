const fs=require('fs'),path=require('path'),assert=require('assert/strict');
const {PGlite}=require('@electric-sql/pglite'),{pgcrypto}=require('@electric-sql/pglite/contrib/pgcrypto');
const root=path.resolve(__dirname,'..'),read=p=>fs.readFileSync(path.join(root,p),'utf8');
(async()=>{const db=new PGlite({extensions:{pgcrypto}});try{
const fixture=read('tests/fresh-install-readiness.cjs'),start=fixture.lastIndexOf('await db.exec(`',fixture.indexOf('create role anon'))+15,end=fixture.indexOf('`);',start);await db.exec(Function('return `'+fixture.slice(start,end)+'`;')());
await db.exec(read('schema_consolidated_fresh_install.sql'));await db.exec('alter table auth.users add column email_confirmed_at timestamptz');
const hash=(await db.query("select md5(pg_get_functiondef('manual_employee_check(text,text,text)'::regprocedure)) h")).rows[0].h;
// The fresh-install baseline already contains the approved appointment migration.

const owner='00000000-0000-4000-8000-000000000001',user='00000000-0000-4000-8000-000000000002',other='00000000-0000-4000-8000-000000000003',rid='11111111-1111-4111-8111-111111111111';
await db.query("insert into auth.users(id,email,email_confirmed_at) values($1,'owner@test.invalid',now()),($2,'staff@test.invalid',now()),($3,'wrong@test.invalid',now())",[owner,user,other]);
await db.query("insert into admin_profiles(auth_user_id,email,full_name,role) values($1,'owner@test.invalid','Owner','SUPER_ADMIN')",[owner]);
await db.query("insert into employee_registrations(id,employee_id,mobile_number,full_name,specialty,status) values($1,'EMP-ADMIN','0000000000','Employee','ENT','APPROVED')",[rid]);
const q=async(sql,args=[])=> (await db.query(sql,args)).rows[0].r;
await db.exec("set request.jwt.claim.sub='"+owner+"';set role authenticated");
assert.equal((await q('select super_admin_assign_employee($1,$2,$3) r',[rid,'SUB_ADMIN','{"invalid":true}'])).ok,false);
const assigned=await q('select super_admin_assign_employee($1,$2,$3) r',[rid,'SUB_ADMIN','{"can_view_logs":true,"can_manage_limits":false}']);assert(assigned.ok);
await db.exec('reset role;set role anon');for(const table of ['employee_admin_assignments','employee_admin_proofs'])await assert.rejects(db.query('select * from private.'+table),/permission denied/);
assert.equal((await q("select employee_admin_assignment('EMP-ADMIN','wrong') r")).ok,false);
assert.equal((await q("select employee_admin_assignment('EMP-ADMIN','0000000000') r")).assignment.status,'PENDING');
assert.equal((await q("select employee_admin_claim($1,'other','0000000000','staff@test.invalid') r",[assigned.id])).ok,false);
const claim=await q("select employee_admin_claim($1,'EMP-ADMIN','0000000000','staff@test.invalid') r",[assigned.id]);assert(claim.ok);
await db.exec("reset role;set request.jwt.claim.sub='"+other+"';set role authenticated");assert.equal((await q('select employee_admin_complete($1) r',[claim.proof])).ok,false);assert.equal((await q('select super_admin_assign_employee($1,$2,$3) r',[rid,'SUPER_ADMIN','{}'])).ok,false);
await db.exec("reset role;update auth.users set email_confirmed_at=null where id='"+user+"';set request.jwt.claim.sub='"+user+"';set role authenticated");assert.equal((await q('select employee_admin_complete($1) r',[claim.proof])).ok,false);
await db.exec("reset role;update auth.users set email_confirmed_at=now() where id='"+user+"';set role authenticated");assert((await q('select employee_admin_complete($1) r',[claim.proof])).ok);assert((await q('select employee_admin_complete($1) r',[claim.proof])).ok,'idempotent completion');
await db.exec('reset role');const saved=(await db.query('select role,permissions from admin_profiles where auth_user_id=$1',[user])).rows[0];assert.equal(saved.role,'SUB_ADMIN');assert.deepEqual(saved.permissions,{can_view_logs:true,can_manage_limits:false});
await db.exec("set request.jwt.claim.sub='"+owner+"';set role authenticated");assert((await q('select super_admin_revoke_employee_assignment($1) r',[assigned.id])).ok);assert.equal((await q('select employee_admin_complete($1) r',[claim.proof])).ok,false);
await db.exec('reset role');assert.equal((await db.query('select is_active from admin_profiles where auth_user_id=$1',[user])).rows[0].is_active,false);
await db.exec("set role authenticated");assert((await q('select super_admin_assign_employee($1,$2,$3) r',[rid,'SUPER_ADMIN','{}'])).ok);await db.exec('reset role;set role anon');
const again=await q("select employee_admin_claim($1,'EMP-ADMIN','0000000000','staff@test.invalid') r",[assigned.id]);assert(again.ok);await db.exec("reset role;update employee_registrations set status='REJECTED' where id='"+rid+"';set request.jwt.claim.sub='"+user+"';set role authenticated");assert.equal((await q('select employee_admin_complete($1) r',[again.proof])).ok,false);
await db.exec("reset role;update employee_registrations set status='APPROVED' where id='"+rid+"';set role authenticated");assert((await q('select employee_admin_complete($1) r',[again.proof])).ok,'reactivation of linked account');await db.exec('reset role');assert.equal((await db.query('select role from admin_profiles where auth_user_id=$1',[user])).rows[0].role,'SUPER_ADMIN');
assert.equal((await db.query("select md5(pg_get_functiondef('manual_employee_check(text,text,text)'::regprocedure)) h")).rows[0].h,hash);
assert((await db.query("select count(*) n from admin_audit_logs where action like '%EMPLOYEE_ADMIN'")).rows[0].n>=5);
console.log('PASS private tables, owner-only appointment, approved identity, verified email, cross-user denial, fixed grants, idempotency, revocation, reactivation, audit and unchanged QR function');
}finally{await db.close();}})().catch(e=>{console.error(e);process.exitCode=1});
