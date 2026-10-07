const fs=require('fs'),path=require('path'),assert=require('assert/strict');const {PGlite}=require('@electric-sql/pglite');
const root=path.resolve(__dirname,'..'),sql=fs.readFileSync(path.join(root,'supabase/canonical/registration_approved_phone.sql'),'utf8');
(async()=>{const db=await PGlite.create();try{const block=sql.slice(sql.indexOf("  if reg.status = 'APPROVED' then"),sql.indexOf('  if reg.first_entry_used = true then'));assert(block.includes('manual_employee_check(reg.employee_id, clean_mobile, p_qr_token)'));assert(fs.readFileSync(path.join(root,'schema_consolidated_fresh_install.sql'),'utf8').includes(sql));
await db.exec(`CREATE FUNCTION public.manual_employee_check(text,text,text) RETURNS jsonb LANGUAGE sql AS $$SELECT jsonb_build_object('employee',$1,'mobile',$2,'qr',$3)$$;CREATE FUNCTION public.check_approved(p_mobile text) RETURNS jsonb LANGUAGE plpgsql AS $body$ DECLARE reg record;clean_mobile text:=trim(coalesce(p_mobile,''));p_qr_token text:='SYNTHETIC';BEGIN SELECT 'APPROVED'::text status,'SYN'::text employee_id,'012345'::text mobile_number INTO reg;${block} RETURN NULL;END;$body$;`);
for(const x of [null,'',' ','wrong']){const r=(await db.query('SELECT check_approved($1) r',[x])).rows[0].r;assert.equal(r.ok,false);assert.equal(r.result,'DENIED');}
for(const x of ['012345',' 012345 '])assert.deepEqual((await db.query('SELECT check_approved($1) r',[x])).rows[0].r,{employee:'SYN',mobile:'012345',qr:'SYNTHETIC'});
await db.exec('CREATE TABLE public.gate_devices(id integer,is_active boolean NOT NULL DEFAULT true); INSERT INTO gate_devices(id) VALUES(1);');
await db.exec(fs.readFileSync(path.join(root,'supabase/gate_device_default_false_reviewed.sql'),'utf8'));
await db.exec('INSERT INTO gate_devices(id) VALUES(2); INSERT INTO gate_devices VALUES(3,true);');
assert.deepEqual((await db.query('SELECT is_active FROM gate_devices ORDER BY id')).rows.map(x=>x.is_active),[true,false,true]);
console.log('PASS APPROVED caller phone denial/matching and unchanged QR; gate default false, existing states and explicit activation preserved');}finally{await db.close();}})().catch(e=>{console.error(e);process.exitCode=1});
