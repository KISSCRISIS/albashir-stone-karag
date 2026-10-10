const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {chromium}=require('playwright'),root=path.resolve(__dirname,'..');
const server=http.createServer((req,res)=>{const name=new URL(req.url,'http://localhost').pathname.slice(1),file=path.resolve(root,name);
 if(!file.startsWith(root+path.sep))return res.writeHead(403).end();
 try{res.setHeader('Content-Type',name.endsWith('.html')?'text/html; charset=utf-8':name.endsWith('.js')?'text/javascript':name.endsWith('.css')?'text/css':'application/octet-stream');res.end(fs.readFileSync(file));}catch{res.writeHead(404).end();}});
(async()=>{let browser;try{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin='http://127.0.0.1:'+server.address().port;
 browser=await chromium.launch();const context=await browser.newContext({serviceWorkers:'block',viewport:{width:390,height:844}});
 const errors=[],requests=[],session='a'.repeat(64);let logins=0,successful=0;
 await context.route('**/*',async route=>{const req=route.request(),url=new URL(req.url());if(url.origin===origin)return route.continue();
  if(!url.hostname.endsWith('.supabase.co'))return route.abort();
  const send=data=>route.fulfill({status:200,contentType:'application/json',headers:{'access-control-allow-origin':'*'},body:JSON.stringify(data)});
  if(req.method()==='OPTIONS')return route.fulfill({status:204,headers:{'access-control-allow-origin':'*','access-control-allow-headers':'*','access-control-allow-methods':'POST,GET,OPTIONS'}});
  const name=url.pathname.split('/').pop(),body=req.postDataJSON()||{};
  if(name==='create_public_guard_qr')return send({ok:true,token:crypto.randomUUID(),read_key:'b'.repeat(64),expires_at:new Date(Date.now()+30000).toISOString()});
  if(name==='get_public_guard_result')return send({ok:true,result:'WAITING'});
  if(name==='guard_login'){logins++;assert.equal(body.p_identity,'999999991');assert.equal(body.p_phone,'0799999901');return send({ok:true,token:session,full_name:'',emergency_enabled:true});}
  if(name==='guard_session_profile')return send({ok:true,is_shared:false,full_name:'Synthetic guard',logged_in_at:new Date().toISOString()});
  if(name==='guard_session_status'){assert.equal(body.p_token,session);return send({ok:true,full_name:'Synthetic guard',emergency_enabled:true});}
  if(name==='guard_manual_employee_entry'){
   requests.push(body);assert.equal(body.p_token,session);assert.equal(body.p_employee_id,'SYN-ENTRY');assert(body.p_request_id);
   if(requests.length===1)return route.abort();successful++;
   return send({ok:true,result:'LIMITED',counted:true,employee:{full_name:'Synthetic employee',job_type:'Synthetic job',specialty:'Synthetic specialty',has_photo:false}});
  }
  if(name==='guard_logout')return send({ok:true});
  throw Error('Unexpected backend request '+name);
 });
 let page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));await page.goto(origin+'/guard.html');
 await page.waitForFunction(()=>document.querySelector('#qr').hidden===false);
 assert.equal(logins,0,'public QR does not require guard login');
 await page.locator('#manualOpen').click();await page.locator('#guardIdentity').fill('999999991');await page.locator('#guardPhone').fill('0799999901');
 await page.locator('#guardLoginForm').evaluate(f=>{f.requestSubmit();f.requestSubmit();});await page.waitForFunction(()=>document.querySelector('#guardEntryForm').hidden===false);
 assert.equal(logins,1);assert.equal(await page.locator('#guardPhone').inputValue(),'');
 assert.equal(await page.locator('#guardProfileLink').getAttribute('href'),'./guard-profile.html');
 assert.equal(await page.locator('#guardWelcome').textContent(),'مرحبًا بك في شاشة الحارس');
 const stored=await page.evaluate(()=>Object.fromEntries(Object.entries(localStorage)));
 assert.equal(stored.alb_guard_session_v1,session);assert(!JSON.stringify(stored).includes('0799999901'));
 await page.locator('#manualEmployeeId').fill('SYN-ENTRY');await page.locator('#guardEntryButton').click();
 await page.waitForFunction(()=>document.querySelector('#guardManualMessage').textContent.includes('لم تُؤكد'));
 await page.locator('#guardEntryForm').evaluate(f=>{f.requestSubmit();f.requestSubmit();});
 await page.waitForFunction(()=>document.querySelector('#result').hidden===false);
 assert.equal(requests.length,2);assert.equal(requests[0].p_request_id,requests[1].p_request_id);assert.equal(successful,1);
 assert.equal(await page.locator('#qrPanel').isVisible(),false);assert.equal(await page.locator('#name').textContent(),'Synthetic employee');
 await page.waitForFunction(()=>document.querySelector('#result').hidden===true,null,{timeout:12000});
 assert.equal(await page.locator('#name').textContent(),'');assert.equal(await page.locator('#manualEmployeeId').inputValue(),'');
 await page.close();page=await context.newPage();await page.goto(origin+'/guard.html');await page.locator('#manualOpen').click();
 await page.waitForFunction(()=>document.querySelector('#guardEntryForm').hidden===false);assert.equal(logins,1,'guard session restored without phone reentry');
 for(const width of [320,390,768,1366]){await page.setViewportSize({width,height:844});const box=await page.locator('#guardManualPanel').boundingBox();assert(box.x>=0&&box.x+box.width<=width+1&&box.y>=0&&box.y+box.height<=845);assert.equal(await page.evaluate(()=>document.body.classList.contains('guard-panel-open')),true);assert.equal(await page.locator('#qrPanel').evaluate(e=>e.inert),true);}
 await page.keyboard.press('Escape');assert.equal(await page.locator('#guardManualPanel').isVisible(),false);assert.equal(await page.locator('#qrPanel').evaluate(e=>e.inert),false);await page.locator('#manualOpen').click();
 await page.locator('#guardAccountOptions summary').click();await page.locator('#guardLogoutButton').click();await page.waitForFunction(()=>!localStorage.getItem('alb_guard_session_v1'));
 assert.deepEqual(errors,[]);console.log('PASS public QR, simple remembered guard login, no saved phone, manual-entry retry ID, duplicate-submit lock, result replacement and ten-second cleanup; mocked backend');
}finally{if(browser)await browser.close();await new Promise(r=>server.close(r));}})().catch(e=>{console.error(e);process.exitCode=1});
