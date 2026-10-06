const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');const vm=require('node:vm');
const read=f=>fs.readFileSync(path.join(__dirname,'..',f),'utf8');
const actual={full_name:'Synthetic',employee_id:'EMP'};
(async()=>{
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
for(const match of index.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi))if(!/src=/.test(match[1]))new vm.Script(match[2]);
console.log('PASS inline syntax; no Production calls');
})().catch(e=>{console.error(e);process.exitCode=1;});
