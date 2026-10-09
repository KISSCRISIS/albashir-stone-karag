const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..');
(async()=>{
  let calls=0,aborted=false,mode='stall';const timers=new Set();
  const c={navigator:{onLine:true},AbortController,Error,document:{readyState:'complete',getElementById:()=>null},setTimeout:(fn,ms)=>{const t=setTimeout(fn,Math.min(ms,10));timers.add(t);return t;},clearTimeout:t=>{clearTimeout(t);timers.delete(t);},fetch:(input,options)=>{calls++;if(mode==='ok')return Promise.resolve({ok:true});return new Promise((resolve,reject)=>options.signal.addEventListener('abort',()=>{aborted=true;reject(new Error('aborted'));},{once:true}));}};
  c.window={addEventListener:()=>{}};vm.createContext(c);vm.runInContext(fs.readFileSync(path.join(root,'app-runtime.js'),'utf8'),c);
  const runtime=c.window.ALBASHIRRuntime;
  await assert.rejects(runtime.fetchWithTimeout('TEST'),/NETWORK_TIMEOUT/);assert(aborted);assert.equal(calls,1,'login never retries automatically');assert.equal(timers.size,0);
  mode='ok';await runtime.fetchWithTimeout('TEST');assert.equal(calls,2);assert.equal(timers.size,0);
  c.fetch=(input,options)=>Promise.resolve({ok:true,clone:()=>({arrayBuffer:()=>new Promise((resolve,reject)=>options.signal.addEventListener('abort',()=>reject(Error('body aborted'))))})});
  await assert.rejects(runtime.fetchWithTimeout('TEST'),/NETWORK_TIMEOUT/);assert.equal(timers.size,0);
  assert.equal(runtime.errorMessage(new Error('NETWORK_TIMEOUT'),''),'انتهت مهلة الاتصال. أعد المحاولة.');
  const html=fs.readFileSync(path.join(root,'verify.html'),'utf8');
  const source=html.slice(html.indexOf('  async function rpcWithRetry('),html.indexOf('  function setConnection('));
  let attempts=0;const payload={p_request_id:'SAME-ID',p_employee_id:'SYN'};
  const retry={...c,sleep:async()=>{},supabaseClient:{rpc:(name,args)=>{assert.equal(args,payload);attempts++;return {abortSignal:signal=>attempts===1?new Promise((resolve,reject)=>signal.addEventListener('abort',()=>reject(Error('network aborted')))):Promise.resolve({data:{ok:true}})};}}};
  vm.createContext(retry);vm.runInContext(source,retry);assert((await retry.rpcWithRetry('TEST',payload,{timeoutMs:10,maxAttempts:2})).data.ok);assert.equal(attempts,2);assert.equal(timers.size,0);
  console.log('PASS bounded login transport, request cancellation, timer cleanup, explicit retry recovery and stable verification request identity');
})().catch(e=>{console.error(e);process.exitCode=1});
