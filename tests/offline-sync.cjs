const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');const vm=require('node:vm');
const source=fs.readFileSync(path.join(__dirname,'../verify-shared.js'),'utf8');
const normalize=source.slice(source.indexOf('function normalizeRpcData('),source.indexOf('function escapeHtml('));
const sync=source.slice(source.indexOf('async function syncOfflineAccessLogs('),source.indexOf('function registerOfflineGateMode('));
const rows=(n,size=0)=>Array.from({length:n},(_,i)=>({client_log_id:'row-'+i,employee_id:'synthetic',reason:'ع'.repeat(size),result:'DENIED'}));
async function run(input,response,hold=false){
 const queue=new Map(input.map(r=>[r.client_log_id,r]));const calls=[],deleted=[],retries=[],warnings=[];
 let release;const gate=hold?new Promise(r=>{release=r;}):null;
 const c={TextEncoder,navigator:{onLine:true},readOfflineAccessLogs:async()=>[...queue.values()],
 decryptOfflineAccessLogs:async logs=>logs,clearSyncedOfflineAccessLogs:async logs=>{for(const r of logs){deleted.push(r.client_log_id);queue.delete(r.client_log_id);}},
 incrementOfflineRetryCounts:async logs=>retries.push(...logs.map(r=>r.client_log_id)),updateOfflinePendingBadge:async()=>{},
 syncGateDeviceHeartbeat:async()=>{},getGateDevice:()=>({device_code:'GATE'}),getOfflineDeviceToken:()=> 'TOKEN',
 showSetupWarning:(...a)=>warnings.push(a),setConnection:()=>{},console:{warn:()=>{}},
 supabaseClient:{rpc:async(name,payload)=>{calls.push(payload);if(gate)await gate;return response?response(calls.length,payload):{data:{ok:true,synced_count:payload.p_logs.length},error:null};}}};
 vm.createContext(c);vm.runInContext('let syncingLock=false;'+normalize+sync,c);
 const first=c.syncOfflineAccessLogs();
 if(hold){while(!calls.length)await Promise.resolve();await c.syncOfflineAccessLogs();assert.equal(calls.length,1,'concurrent sync prevented');release();}
 await first;return {queue,calls,deleted,retries,warnings,c};
}
(async()=>{
 let t=await run(rows(1201));assert.deepEqual(t.calls.map(x=>x.p_logs.length),[500,500,201]);assert.equal(t.queue.size,0);assert.equal(new Set(t.deleted).size,1201);
 console.log('PASS >500 queue drains in separate batches');
 t=await run(rows(20,20000));assert.ok(t.calls.length>1);for(const c of t.calls)assert.ok(new TextEncoder().encode(JSON.stringify(c.p_logs)).length<=256*1024);assert.equal(t.queue.size,0);
 console.log('PASS UTF-8 byte cap splits large payload');
 t=await run(rows(600),(n,p)=>n===1?{data:{ok:true,synced_count:p.p_logs.length},error:null}:{data:{ok:false},error:null});
 assert.equal(t.deleted.length,500);assert.equal(t.queue.size,100);assert.equal(t.retries.length,100);assert.ok(!t.retries.includes('row-0'));assert.ok(t.warnings.length);
 console.log('PASS partial success preserves remaining rows without resurrecting deleted rows');
 for(const data of [null,{},[],{ok:true},{ok:false},{ok:true,synced_count:1,error:'failure'},{ok:true,synced_count:2},{ok:true,synced_count:-1}]){
 t=await run(rows(1),()=>({data,error:null}));assert.equal(t.deleted.length,0);assert.equal(t.queue.size,1);assert.ok(t.warnings.length);
 }
 t=await run(rows(1),()=>({data:null,error:new Error('transport')}));assert.equal(t.queue.size,1);
 console.log('PASS null/malformed/rejected/transport responses never delete rows');
 t=await run(rows(3),()=>({data:{ok:true,synced_count:0},error:null}));assert.equal(t.queue.size,0);
 console.log('PASS acknowledged duplicate replay is safe');
 t=await run(rows(1,200000));assert.equal(t.calls.length,0);assert.equal(t.queue.size,1);
 t=await run([{client_log_id:'',result:'DENIED'}]);assert.equal(t.calls.length,0);assert.equal(t.queue.size,1);
 console.log('PASS oversized/invalid-ID row retained');
 t=await run(rows(501),null,true);assert.equal(t.queue.size,0);
 console.log('PASS syncingLock prevents overlapping requests');
 console.log('ALL OFFLINE SYNC TESTS PASS; no Production calls.');
})().catch(e=>{console.error(e);process.exitCode=1;});
