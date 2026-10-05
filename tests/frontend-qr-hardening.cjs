// Run with Playwright available on NODE_PATH. All runtime checks are local;
// page startup and network/database mutations are disabled by the test server.
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '..');
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
const pages = ['index', 'verify', 'register', 'profile', 'admin_dashboard'];
for (const name of [...pages, 'portal', 'guard']) {
  for (const match of read(name + '.html').matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
    if (!/src=/.test(match[1])) new vm.Script(match[2], { filename: name + '.html' });
  }
}
new vm.Script(read('verify-shared.js'));
const sw = read('service-worker.js');
assert.match(sw, /CACHE_VERSION = "emergency-room-parking-offline-v16"/);
assert.match(sw, /if \(event.request.method !== "GET"\) return/);
assert.match(sw, /url.hostname.endsWith\("\.supabase.co"\)/);
assert.match(read('index.html'), /LIVE_SITE_URL: window.location.origin/);
assert.match(read('profile.html'), /href="\.\/verify.html">مسح QR من شاشة الحارس/);
for (const name of ['index', 'verify', 'register', 'profile', 'admin_dashboard', 'guard', 'login']) {
  assert.ok(read('robots.txt').includes('Disallow: /' + name + '.html'));
}
const server = http.createServer((req, res) => {
  const name = decodeURIComponent(new URL(req.url, 'http://localhost').pathname).replace(/^\//, '');
  const file = path.resolve(root, name);
  if (!file.startsWith(root + path.sep)) { res.writeHead(403).end(); return; }
  try {
    const html = name.endsWith('.html');
    res.setHeader('Content-Type', html ? 'text/html; charset=utf-8' : name.endsWith('.css') ? 'text/css' : name.endsWith('.js') ? 'text/javascript' : 'application/octet-stream');
    const body = fs.readFileSync(file);
    res.end(html ? body.toString().replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '') : body);
  } catch { res.writeHead(404).end(); }
});
(async () => {
  let browser;
  try {
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const origin = 'http://127.0.0.1:' + server.address().port;
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({ serviceWorkers: 'block' });
    await context.route('**/*', route => new URL(route.request().url()).origin === origin ? route.continue() : route.abort());
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(origin + '/index.html');
    await page.addScriptTag({ url: origin + '/qrcode.min.js' });
    const source = [...read('index.html').matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)].find(m => !/src=/.test(m[1]))[2];
    await page.evaluate(source.slice(0, source.lastIndexOf('    registerOfflineGateMode();')) + `
      window.qrTest = { refreshQrNow, drawQr, clearExpiredQr,
        state: () => ({...lastValidQr, currentQrUrl}),
        client: value => {supabaseClient=value;}, cleanup: cleanupLifecycle };
    `);
    const runtime = await page.evaluate(async () => {
      const token = '12345678-1234-4234-8234-123456789abc';
      let requestAt;
      qrTest.client({rpc: async name => {
        if (name === 'create_qr_session') {
          requestAt = Date.now();
          await new Promise(r => setTimeout(r, 120));
          return {data:{ok:true,token,expires_in_seconds:0.5},error:null};
        }
        return {data:{ok:true},error:null};
      }});
      await qrTest.refreshQrNow();
      const anchored = qrTest.state().expiresAt <= requestAt + 500;
      const visibleBefore = !document.getElementById('qrCanvas').classList.contains('hidden');
      qrTest.client({rpc:async()=>({data:null,error:{message:'network failure'}})});
      await qrTest.refreshQrNow();
      const keptBeforeExpiry = !!qrTest.state().url;
      await new Promise(r=>setTimeout(r,600));
      const cleared = !qrTest.state().url && !qrTest.state().currentQrUrl &&
        document.getElementById('qrCanvas').classList.contains('hidden') &&
        !document.getElementById('qrLink').hasAttribute('href');
      const warning = document.getElementById('setupWarning').textContent;
      let expiredResponseAt;
      qrTest.client({rpc:async name=> {
        if(name==='create_qr_session') {
          expiredResponseAt=Date.now(); await new Promise(r=>setTimeout(r,100));
          return {data:{ok:true,token,expires_in_seconds:0.01},error:null};
        }
        return {data:{ok:true},error:null};
      }});
      await qrTest.refreshQrNow();
      const lateDenied = !qrTest.state().url;
      const absoluteExpiry = Date.now()+600;
      qrTest.client({rpc:async name=>({data:name==='create_qr_session'
        ? {ok:true,token,expires_at:new Date(absoluteExpiry).toISOString(),expires_in_seconds:999}
        : {ok:true},error:null})});
      await qrTest.refreshQrNow();
      const absolutePreferred = qrTest.state().expiresAt===absoluteExpiry;
      qrTest.cleanup();
      return {anchored,visibleBefore,keptBeforeExpiry,cleared,warning,lateDenied,absolutePreferred};
    });
    for(const key of ['anchored','visibleBefore','keptBeforeExpiry','cleared','lateDenied','absolutePreferred']) assert.equal(runtime[key],true,key);
    assert.equal(runtime.warning,'النظام غير متاح حالياً');
    console.log('QR expiry/failure/absolute-expiry checks PASS');
    await page.goto(origin+'/verify.html');
    await page.evaluate(read('verify-shared.js') + `
      window.heartbeatTest = async outcome => {
        let calls=0, visible=0, logged=0;
        countOfflineAccessLogs=async()=>0;
        getGateDevice=()=>({device_code:'test',gate_name:'test'});
        getOfflineDeviceToken=()=> 'test';
        window.setConnection=()=>{visible++;}; window.showSetupWarning=()=>{visible++;};
        const original=console.error; console.error=()=>{logged++;};
        supabaseClient={rpc:async()=>{calls++;if(outcome.throw)throw new Error('network');return outcome;}};
        try{await syncGateDeviceHeartbeat();return {calls,visible,logged};}finally{console.error=original;}
      };
    `);
    for(const outcome of [{throw:true},{error:{message:'transport'}},{data:{ok:false}},{data:{ok:true,pending_approval:true}},{data:{ok:true,revoked:true}},{data:{ok:true,approved:false}},{data:{ok:true,is_active:false}},{data:{ok:true,error:'rejected'}},{data:{ok:true,status:'REVOKED'}}]) {
      const result=await page.evaluate(outcome=>heartbeatTest(outcome),outcome);
      assert.equal(result.calls,1);assert.equal(result.visible,2);assert.equal(result.logged,1);
    }
    assert.deepEqual(await page.evaluate(()=>heartbeatTest({data:{ok:true}})),{calls:1,visible:0,logged:0});
    console.log('Heartbeat rejection/transport/no-retry checks PASS');
    for(const viewport of [{width:320,height:800},{width:375,height:812},{width:390,height:844},{width:430,height:932},{width:568,height:320},{width:844,height:390},{width:1024,height:768}]) {
      await page.setViewportSize(viewport);
      for(const name of pages) {
        await page.goto(origin+'/'+name+'.html');
        if(name==='index') {
          const leadership=read('global-leadership.js');
          await page.evaluate(leadership.slice(0,leadership.lastIndexOf('  if (document.readyState'))+'  addStyles(); renderRegistrationShortcut();\n})();');
        }
        const fits=await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth);
        assert.ok(fits,name+' page overflow at '+viewport.width);
        if(name==='index') {
          const result=await page.evaluate(()=>{
            const shortcut=document.getElementById('registrationCopyShortcut');
            const canvas=document.getElementById('qrCanvas'); canvas.classList.remove('hidden');
            const qr=canvas.getBoundingClientRect();
            const flow=getComputedStyle(shortcut).position==='static';
            const panel=document.getElementById('decisionPanel');panel.className='panel decision-panel allowed';
            const style=getComputedStyle(panel);
            return {flow,qrFits:qr.left>=0&&qr.right<=innerWidth,overlayScroll:style.overflowY==='auto',bounded:panel.getBoundingClientRect().height<=innerHeight+1};
          });
          for(const [key,value] of Object.entries(result))assert.ok(value,key+' at '+viewport.width);
        }
      }
      console.log('Layout emulation PASS '+viewport.width+'x'+viewport.height);
    }
    assert.deepEqual(errors,[]);
    console.log('All frontend checks PASS; no real-device or Production calls.');
  } finally { if(browser)await browser.close();server.close(); }
})().catch(error=>{console.error(error);process.exitCode=1;});
