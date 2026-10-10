const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {chromium}=require('playwright');
const root=path.resolve(__dirname,'..');
const photo=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jK1cAAAAASUVORK5CYII=','base64');
const server=http.createServer((req,res)=>{
  const name=decodeURIComponent(new URL(req.url,'http://localhost').pathname).replace(/^\//,'');
  if(name==='fixtures/photo.png'){res.setHeader('Content-Type','image/png');res.end(photo);return;}
  const file=path.resolve(root,name);if(!file.startsWith(root+path.sep)){res.writeHead(403).end();return;}
  try{res.setHeader('Content-Type',name.endsWith('.html')?'text/html; charset=utf-8':name.endsWith('.js')?'text/javascript':name.endsWith('.css')?'text/css':name.endsWith('.json')?'application/json':'application/octet-stream');res.end(fs.readFileSync(file));}catch{res.writeHead(404).end();}
});
(async()=>{
  let browser;
  try{
    await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
    const origin='http://127.0.0.1:'+server.address().port;
    browser=await chromium.launch({args:['--autoplay-policy=no-user-gesture-required']});
    const context=await browser.newContext({serviceWorkers:'block',viewport:{width:390,height:844}});
    const issued=new Map(),claims=new Map(),checks=[],errors=[],logins=[];
    const employee={employee_id:'CI-EMPLOYEE',mobile_number:'000000000001',full_name:'CI SYNTHETIC EMPLOYEE',status:'APPROVED',department:'CI',specialty:'CI SPECIALTY',job_type:'CI JOB',registration_category:'PERMANENT',employee_photo_url:'registrations/CI-EMPLOYEE/photo.png'};
    await context.route('**/*',async route=>{
      const request=route.request(),url=new URL(request.url());
      if(url.origin===origin)return route.continue();
      if(!url.hostname.endsWith('.supabase.co'))return route.abort();
      const send=(body,status=200)=>route.fulfill({status,contentType:'application/json',headers:{'access-control-allow-origin':'*'},body:JSON.stringify(body)});
      if(request.method()==='OPTIONS')return route.fulfill({status:204,headers:{'access-control-allow-origin':'*','access-control-allow-headers':'*','access-control-allow-methods':'POST,GET,OPTIONS'}});
      const body=request.postDataJSON()||{};
      if(url.pathname==='/rest/v1/hospital_settings')return send([]);
      if(url.pathname.endsWith('/employee-photo-url')){
        const actor=body.actor||{};
        const valid=actor.type==='employee'?actor.employee_id===employee.employee_id&&actor.mobile_number===employee.mobile_number:actor.type==='public_guard_session'&&[...issued.values()].some(x=>x.key===actor.read_key&&x.decision);
        return send(valid?{ok:true,url:origin+'/fixtures/photo.png',expires_in:60}:{ok:false},valid?200:403);
      }
      const name=url.pathname.split('/').pop();
      if(name==='employee_admin_assignment')return send({ok:true,assignment:null});
      if(name==='employee_profile_login'){
        logins.push(body);await new Promise(resolve=>setTimeout(resolve,60));
        return send({ok:body.p_employee_id===employee.employee_id&&body.p_mobile_number===employee.mobile_number,profile:employee,qr_history:[]});
      }
      if(name==='create_public_guard_qr'){
        const token=crypto.randomUUID(),key=crypto.randomBytes(32).toString('hex');issued.set(token,{key});
        return send({ok:true,token,read_key:key,expires_at:new Date(Date.now()+30000).toISOString()});
      }
      if(name==='claim_qr_session_v2'){
        const screen=issued.get(body.p_token);if(!screen||screen.claimed)return send({ok:false,error:'DENIED'});
        const claim=crypto.randomUUID();screen.claimed=true;claims.set(claim,screen);return send({ok:true,claim_token:claim});
      }
      if(name==='public_guard_employee_check_v2'){
        const screen=claims.get(body.p_qr_token);assert(screen,'mandatory QR claim must precede verification');
        assert.equal(body.p_employee_id,employee.employee_id);assert.equal(body.p_mobile_number,employee.mobile_number);assert(body.p_device_id);assert(body.p_request_id);
        checks.push(body);screen.decision={ok:true,result:'ALLOWED',message:'CI verified',employee,decided_at:new Date().toISOString()};
        return send(screen.decision);
      }
      if(name==='get_public_guard_result'){
        const screen=[...issued.values()].find(x=>x.key===body.p_read_key);assert(screen);
        return send(screen.decision?{...screen.decision,employee:{full_name:employee.full_name,job_type:employee.job_type,specialty:employee.specialty,has_photo:true}}:{ok:true,result:'WAITING'});
      }
      throw Error('Unexpected backend request: '+url.pathname);
    });
    const observe=p=>p.on('pageerror',e=>errors.push(e.message));
    const guard=await context.newPage();observe(guard);await guard.goto(origin+'/guard.html');
    await guard.waitForFunction(()=>document.querySelector('#qr')?.hidden===false);
    const qrImage=await guard.locator('#qr').evaluate(canvas=>canvas.toDataURL());
    let employeePage=await context.newPage();observe(employeePage);await employeePage.goto(origin+'/portal.html');
    await employeePage.locator('.portal-service').filter({hasText:'دخول الموظف'}).click();
    await employeePage.locator('#employeeId').fill('CI-WRONG');await employeePage.locator('#employeePhone').fill(employee.mobile_number);
    await employeePage.locator('#employeeForm button[type=submit]').click();
    await employeePage.waitForFunction(()=>document.querySelector('#notice').classList.contains('show'));
    assert.equal(await employeePage.locator('#employeeForm button[type=submit]').isEnabled(),true);
    assert.equal(await employeePage.locator('#employeeForm button[type=submit]').textContent(),'إعادة المحاولة');
    await employeePage.locator('#employeeId').fill(employee.employee_id);await employeePage.locator('#employeePhone').fill(employee.mobile_number);
    await employeePage.locator('#employeeForm').evaluate(form=>{form.requestSubmit();form.requestSubmit();});
    await employeePage.waitForURL('**/profile.html');await employeePage.waitForFunction(()=>document.querySelector('#profilePhoto').src.startsWith('blob:'));
    assert.equal(logins.length,3,'duplicate submit is blocked: one rejected login, one accepted login plus one profile validation');
    await employeePage.close();
    employeePage=await context.newPage();observe(employeePage);await employeePage.goto(origin+'/portal.html');
    await employeePage.locator('#openPortalLogin').click();await employeePage.waitForURL('**/profile.html');
    assert.equal(await employeePage.locator('#loginEmployeeId').inputValue(),employee.employee_id);
    // Feed real QR pixels into a synthetic camera stream, leaving the app's scanner/decoder unchanged.
    await employeePage.addInitScript(image=>{
      delete window.BarcodeDetector;
      navigator.mediaDevices.getUserMedia=async()=>{
        const canvas=document.createElement('canvas');canvas.width=320;canvas.height=320;
        const img=new Image();img.src=image;await img.decode();const ctx=canvas.getContext('2d');
        const stream=canvas.captureStream(10),timer=setInterval(()=>ctx.drawImage(img,0,0,320,320),80);
        stream.getTracks().forEach(track=>track.addEventListener('ended',()=>clearInterval(timer)));
        return stream;
      };
    },qrImage);
    await employeePage.goto(origin+'/verify.html?scan=1');
    await employeePage.waitForFunction(()=>document.querySelector('#resultCard').classList.contains('allowed'),null,{timeout:15000});
    await employeePage.waitForFunction(()=>document.querySelector('#resultDetails img')?.src.startsWith('blob:'));
    assert.equal(await employeePage.locator('#manualSections').isVisible(),false);
    await guard.waitForFunction(()=>document.querySelector('#result').hidden===false);
    const shownAt=Date.now();assert.equal(await guard.locator('#qrPanel').isVisible(),false);
    assert.equal(await guard.locator('#name').textContent(),employee.full_name);
    assert((await guard.locator('#job').textContent()).includes(employee.job_type));
    assert((await guard.locator('#specialty').textContent()).includes(employee.specialty));
    await guard.waitForFunction(()=>document.querySelector('#photo').src.startsWith('blob:')&&!document.querySelector('#photo').hidden);
    await guard.waitForFunction(()=>document.querySelector('#result').hidden===true,null,{timeout:12000});
    assert(Date.now()-shownAt>=8500,'guard personal details must remain for approximately ten seconds');
    assert.equal(await guard.locator('#name').textContent(),'');assert.equal(await guard.locator('#photo').getAttribute('src'),null);assert.equal(await guard.locator('#qrPanel').isVisible(),true);
    assert.equal(checks.length,1,'one scan must issue one employee verification');
    await employeePage.goto(origin+'/profile.html');await employeePage.locator('#portalRoleNavigation button').click();await employeePage.waitForURL('**/portal.html');
    assert.equal(await employeePage.evaluate(()=>localStorage.getItem('alb_remembered_employee_v1')),null);
    assert.deepEqual(errors,[]);
    console.log('PASS full employee browser journey: login, close/reopen, real QR decoding, automatic verification, both photos/results, single decision and guard data clearing after ten seconds; all backend traffic mocked');
  }finally{if(browser)await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(e=>{console.error(e);process.exitCode=1});
