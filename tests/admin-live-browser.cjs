const fs=require('fs'),path=require('path'),http=require('http'),assert=require('assert/strict'),{chromium}=require('playwright');
const root=path.resolve(__dirname,'..');
const server=http.createServer((req,res)=>{const name=new URL(req.url,'http://localhost').pathname.slice(1),file=path.resolve(root,name);if(!file.startsWith(root+path.sep))return res.writeHead(403).end();try{let data=fs.readFileSync(file);if(name==='admin_dashboard.html')data=data.toString().replace(/<script src="\.\/access-control.js"[^>]*><\/script>/,'').replace('    init().catch((err) => {','    Promise.resolve().catch((err) => {');res.setHeader('Content-Type',name.endsWith('.html')?'text/html; charset=utf-8':name.endsWith('.js')?'text/javascript':name.endsWith('.css')?'text/css':'application/octet-stream');res.end(data);}catch{res.writeHead(404).end();}});
(async()=>{let browser;try{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin='http://127.0.0.1:'+server.address().port;browser=await chromium.launch();const context=await browser.newContext({serviceWorkers:'block',viewport:{width:390,height:844}}),page=await context.newPage(),errors=[];
 page.on('pageerror',e=>errors.push(e.message));await context.route('**/*',r=>new URL(r.request().url()).origin===origin?r.continue():r.abort());
 await page.goto(origin+'/admin_dashboard.html');await page.evaluate(async()=>{
  adminProfile={role:'SUPER_ADMIN'};window.liveCalls=[];window.liveEvents=[{id:'11111111-1111-4111-8111-111111111111',title:'طلب جديد',body:'نص عام',topic:'REGISTRATION',target:'registrations',created_at:new Date().toISOString(),read:false}];
  supabaseClient={auth:{getSession:async()=>({data:{session:{user:{id:'synthetic-owner'}}}})},rpc:(name,payload)=>({abortSignal:async()=>{liveCalls.push({name,payload});if(name==='admin_notice_read')liveEvents.find(e=>e.id===payload.p_id).read=true;return {data:name==='admin_notice_feed'?{ok:true,events:liveEvents,vapid_public:null}:{ok:true}};}})};
  await AdminLive.start();showTab('notifications');
 });
 assert.equal(await page.locator('#adminNoticeCount').textContent(),'1');assert.equal(await page.locator('#adminNoticeList button').count(),1);
 await page.locator('#adminNoticeEnable').click();await page.waitForFunction(()=>localStorage.getItem('alb_admin_notices_synthetic-owner')==='true');
 await page.evaluate(async()=>{liveEvents.unshift({id:'22222222-2222-4222-8222-222222222222',title:'اكتمل الحد',body:'اختصاص تجريبي',topic:'LIMIT',target:'limits',created_at:new Date().toISOString(),read:false});await AdminLive.refresh();});
 assert.equal(await page.locator('#adminNoticeCount').textContent(),'2');assert(await page.locator('.tab-btn.has-new-notice').count()>=2);
 await page.locator('#adminNoticeList button').first().click();assert(await page.locator('#limits').evaluate(e=>e.classList.contains('active')));
 await page.waitForFunction(()=>document.querySelector('#adminNoticeCount').textContent==='1');
 await page.evaluate(()=>showTab('notifications'));await page.locator('#adminNoticeDisable').click();await page.waitForFunction(()=>localStorage.getItem('alb_admin_notices_synthetic-owner')==='false');
 const calls=await page.evaluate(()=>liveCalls);assert(calls.some(c=>c.name==='admin_notice_device'&&c.payload.p_enabled===true));assert(calls.some(c=>c.name==='admin_notice_device'&&c.payload.p_enabled===false));assert.deepEqual(errors,[]);
 console.log('PASS admin scoped device preference, unread badges, text feed, notice navigation/read receipt, mobile notifications and disable flow; mocked RPC');
}finally{if(browser)await browser.close();await new Promise(r=>server.close(r));}})().catch(e=>{console.error(e);process.exitCode=1});
