const fs=require('fs'),path=require('path'),http=require('http'),assert=require('assert/strict'),{chromium}=require('playwright');
const root=path.resolve(__dirname,'..');
const server=http.createServer((req,res)=>{const name=new URL(req.url,'http://localhost').pathname.slice(1),file=path.resolve(root,name);if(!file.startsWith(root+path.sep))return res.writeHead(403).end();try{let data=fs.readFileSync(file);if(name==='admin_dashboard.html')data=data.toString().replace(/<script src="\.\/access-control.js"[^>]*><\/script>/,'').replace('    init().catch((err) => {','    Promise.resolve().catch((err) => {');res.setHeader('Content-Type',name.endsWith('.html')?'text/html; charset=utf-8':name.endsWith('.js')?'text/javascript':name.endsWith('.css')?'text/css':'application/octet-stream');res.end(data);}catch{res.writeHead(404).end();}});
(async()=>{let browser;try{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin='http://127.0.0.1:'+server.address().port;browser=await chromium.launch();const ctx=await browser.newContext({serviceWorkers:'block'}),page=await ctx.newPage(),errors=[];
 page.on('pageerror',e=>errors.push(e.message));await ctx.route('**/*',r=>new URL(r.request().url()).origin===origin?r.continue():r.abort());
 await page.goto(origin+'/admin_dashboard.html');await page.evaluate(()=>{
  adminProfile={role:'SUPER_ADMIN'};supabaseClient={auth:{getSession:async()=>({data:{session:{access_token:'synthetic'}}})}};
  window.photoHydrates=0;window.EmployeePhoto={hydrate:()=>{window.photoHydrates++;}};window.actionCalls=[];
  window.updateRegistration=(...args)=>window.actionCalls.push(['registration',...args]);window.setTrustedDevice=(...args)=>window.actionCalls.push(['device',...args]);
  const now=new Date().toISOString();registrationsData=[{id:'11111111-1111-4111-8111-111111111111',full_name:'اسم موظف طويل للتجربة',employee_id:'EMP-001',mobile_number:'0790000001',job_type:'طبيب',specialty:'الإسعاف والطوارئ',registration_category:'TEMPORARY',affiliated_entity:'جهة اختبار',status:'PENDING',first_entry_used:true,first_entry_at:now,created_at:now,employee_photo_url:'registrations/EMP-001/photo.png',trusted_device_enabled:true,trusted_device_token_hash:'private-hash',trusted_device_type:'هاتف',trusted_device_name:'Safari',trusted_device_id:'DEVICE-IDENTIFIER-1234567890',trusted_device_last_activity_at:now},
   {id:'22222222-2222-4222-8222-222222222222',full_name:'موظف معتمد',employee_id:'EMP-002',mobile_number:'0790000002',job_type:'ممرض',specialty:'قسم ثاني',registration_category:'PERMANENT',status:'APPROVED',first_entry_used:false,created_at:now,trusted_device_enabled:false},
   {id:'33333333-3333-4333-8333-333333333333',full_name:'<img src=x onerror=alert(1)>',employee_id:'EMP-003',mobile_number:'0790000003',status:'REJECTED',created_at:now}];
  filteredRegistrationsData=registrationsData.slice();populateDepartmentFilter();renderRegistrations();
  logsData=[{result:'ALLOWED',employee_id:'EMP-001',created_at:now},{result:'DENIED',employee_id:'EMP-002',created_at:now},{result:'LIMITED',employee_id:'EMP-003',created_at:new Date(Date.now()-5*86400000).toISOString()},{result:'DENIED',employee_id:'EMP-004',created_at:new Date(Date.now()-40*86400000).toISOString()}];
  violationsData=[{status:'NEW',employee_id:'EMP-001',created_at:now},{status:'CLOSED',employee_id:'EMP-002',created_at:now}];renderOverview();
 });
 await page.evaluate(()=>showTab('registrations'));assert.equal(await page.locator('.registration-card').count(),3);
 const first=page.locator('.registration-card').first();const text=await first.textContent();for(const value of ['EMP-001','0790000001','طبيب','الإسعاف والطوارئ','مؤقت / خارجي','جهة اختبار','الدخول الأول','تاريخ الطلب','Safari','المعرف','آخر نشاط','إلغاء الربط','تعطيل','موافقة','رفض'])assert(text.includes(value),'missing '+value);
 assert.equal(await first.locator('[data-photo-ref]').getAttribute('data-photo-ref'),'registrations/EMP-001/photo.png');assert.equal(await page.locator('.registration-card').last().locator('img').count(),0,'HTML in employee name is escaped');
 for(const label of ['موافقة','رفض','إلغاء الربط','تعطيل'])await first.getByRole('button',{name:label,exact:true}).click();const calls=await page.evaluate(()=>actionCalls);assert.equal(calls.length,4);assert.deepEqual(calls[0],['registration','11111111-1111-4111-8111-111111111111','APPROVED']);assert.deepEqual(calls[2],['device','11111111-1111-4111-8111-111111111111',true,true]);
 assert(await page.locator('.registration-card').nth(1).getByRole('button',{name:'موافقة',exact:true}).isDisabled());
 await page.evaluate(()=>{adminProfile={role:'ADMIN',permissions:{}};renderRegistrations();});assert(await first.getByRole('button',{name:'رفض',exact:true}).isDisabled());assert(await first.getByRole('button',{name:'إلغاء الربط',exact:true}).isDisabled());await page.evaluate(()=>{adminProfile={role:'SUPER_ADMIN'};renderRegistrations();});
 for(const [metric,target,period,result,count] of [['last30','logs','DAYS30','',3],['approvedToday','logs','TODAY','ALLOWED',1],['denied','logs','ALL','DENIED',2],['qr','logs','LAST24','',2]]){
  await page.evaluate(()=>showTab('overview'));await page.locator('[data-kpi="'+metric+'"]').click();assert(await page.locator('#'+target).evaluate(e=>e.classList.contains('active')));assert.equal(await page.locator('#logViewPeriod').inputValue(),period);assert.equal(await page.locator('#logViewResult').inputValue(),result);assert.equal(await page.locator('#logsBody tr').count(),count);
 }
 await page.evaluate(()=>showTab('overview'));await page.locator('[data-kpi="violations"]').click();assert.equal(await page.locator('#violationViewStatus').inputValue(),'NEW');assert.equal(await page.locator('#violationsBody tr').count(),1);
 await page.evaluate(()=>showTab('overview'));await page.locator('[data-kpi="pending"]').click();assert.equal(await page.locator('#dashboardStatus').inputValue(),'PENDING');assert.equal(await page.locator('.registration-card').count(),1);assert(await page.locator('#dashboardStatus').isVisible());
 await page.locator('#dashboardSearch').fill('does not exist');assert.equal(await page.locator('.registration-card').count(),0);assert(await page.locator('.registration-empty').isVisible());await page.locator('#registrations').getByRole('button',{name:'مسح الفلاتر',exact:true}).click();assert.equal(await page.locator('.registration-card').count(),3);
 for(const width of [320,390,768,1366]){
  await page.setViewportSize({width,height:900});await page.evaluate(()=>showTab('overview'));
  const columns=await page.locator('.kpi-strip').evaluate(e=>getComputedStyle(e).gridTemplateColumns.split(' ').length);assert.equal(columns,width>700?3:width<=380?1:2);
  await page.evaluate(()=>showTab('registrations'));const bounds=await page.locator('.registration-card-grid').boundingBox();assert(bounds.x>=0&&bounds.x+bounds.width<=width+2,'cards overflow '+width);
  assert.equal(await first.getByRole('button',{name:'رفض',exact:true}).evaluate(e=>e.getBoundingClientRect().height>=44),true);
  await page.evaluate(()=>{$('guardAdminPanel').hidden=false;});const check=await page.locator('#guardAdminActive').boundingBox();assert(check.width<=24&&check.height<=24,'checkbox oversized');assert((await page.locator('label:has(#guardAdminActive)').textContent()).includes('يسمح للحارس'));await page.evaluate(()=>{$('guardAdminPanel').hidden=true;});
 }
 if(process.env.ADMIN_UI_QA_DIR){
  const dir=process.env.ADMIN_UI_QA_DIR;fs.mkdirSync(dir,{recursive:true});
  await page.setViewportSize({width:1366,height:900});await page.evaluate(()=>{showTab('overview');window.scrollTo(0,0);});await page.screenshot({path:path.join(dir,'admin-kpis-desktop.png')});
  await page.evaluate(()=>{showTab('registrations');window.scrollTo(0,0);});await page.screenshot({path:path.join(dir,'admin-requests-desktop.png')});
  await page.setViewportSize({width:390,height:844});await page.evaluate(()=>window.scrollTo(0,0));await page.screenshot({path:path.join(dir,'admin-requests-mobile.png')});
 }
 assert.equal(await page.locator('.top-actions a[href="./index.html"]').count(),0);
 assert.equal(await page.locator('#registrationCopyShortcut').count(),0);
 assert.equal(await page.locator('section:not(#exports) [onclick^="exportCsv"]').count(),0);
 await page.setViewportSize({width:1366,height:900});await page.evaluate(()=>{window.csvDownload=null;window.downloadCsv=(name,rows)=>window.csvDownload={name,rows};showTab('exports');});
 assert(await page.locator('.nav-tabs').getByRole('button',{name:'تصدير CSV',exact:true}).isVisible());
 await page.getByRole('button',{name:'تحميل البيانات المحددة',exact:true}).click();assert((await page.evaluate(()=>csvDownload.rows)).some(row=>row.dataset==='logs'));
 await page.evaluate(()=>{adminProfile={role:'ADMIN',permissions:{}};csvDownload=null;exportSelectedCsv();});assert.equal(await page.evaluate(()=>csvDownload),null);
 assert.deepEqual(errors,[]);console.log('PASS all 13 request fields/actions retained, permission-disabled controls, private photo hydration, escaped data, six KPI filters, empty/search reset, responsive cards/grid and labeled checkbox sizing; synthetic browser data');
}finally{if(browser)await browser.close();await new Promise(r=>server.close(r));}})().catch(e=>{console.error(e);process.exitCode=1});
