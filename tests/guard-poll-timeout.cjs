const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../guard.html'),'utf8');
const helper=html.slice(html.indexOf('async function guardRpc('),html.indexOf('async function createCandidate('));
const poll=html.slice(html.indexOf('async function poll(){'),html.indexOf("el('refresh').onclick"));
(async()=>{
  let stalled=true,aborted=false,calls=0,warnings=0;
  const timers=new Set();
  const c={AbortController,Date,Promise,Error,polling:false,lastHealthyAt:0,sessions:[{key:'OLD',until:Date.now()+60000},{key:'NEW',until:Date.now()+60000}],
    setTimeout:(fn,ms)=>{const t=setTimeout(fn,Math.min(ms,10));timers.add(t);return t;},clearTimeout:t=>{clearTimeout(t);timers.delete(t);},
    unavailable:()=>warnings++,client:{rpc:(name,payload)=>{calls++;assert.equal(name,'get_public_guard_result');assert.equal(payload.p_read_key,'NEW');return {abortSignal:signal=>{signal.addEventListener('abort',()=>aborted=true);return stalled?new Promise(()=>{}):Promise.resolve({data:{ok:true,result:'WAITING'}});}}}}
  };
  vm.createContext(c);vm.runInContext(helper+poll,c);
  await c.poll();assert(aborted);assert.equal(c.polling,false);assert.equal(warnings,1);assert.equal(timers.size,0);
  stalled=false;c.sessions=c.sessions.slice(1);await c.poll();assert.equal(c.polling,false);assert.equal(calls,2);assert.equal(timers.size,0);assert(c.lastHealthyAt>0);
  assert(html.includes("guardRpc('create_public_guard_qr')"));
  console.log('PASS hanging guard RPC aborts, polling lock releases, next poll recovers, newest session first and timers cleaned');
})().catch(e=>{console.error(e);process.exitCode=1});
