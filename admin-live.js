window.AdminLive = (() => {
  'use strict';
  const $ = id => document.getElementById(id);
  let timer, busy=false, started=false, initialized=false, seen=new Set(), publicKey='', enabled=false, preference='', device='';
  const targets=new Set(['registrations','profileChanges','violations','limits','logs','notifications']);
  const status=text=>{$('adminNoticeStatus').textContent=text;};
  async function rpc(name,payload={}) {
    const controller=new AbortController(), timeout=setTimeout(()=>controller.abort(),10000);
    try { const {data,error}=await supabaseClient.rpc(name,payload).abortSignal(controller.signal); if(error||data?.ok!==true) throw Error('تعذر تحديث الإشعارات؛ أعد المحاولة.'); return data; }
    finally {clearTimeout(timeout);}
  }
  function open(target) {
    if(!targets.has(target)) target='notifications';
    const button=[...document.querySelectorAll('.tab-btn')].find(b=>(b.getAttribute('onclick')||'').includes("'"+target+"'"));
    showTab(target,button); document.getElementById(target)?.scrollIntoView({block:'start'});
  }
  async function refresh() {
    if(busy||!started) return; busy=true;
    try {
      const data=await rpc('admin_notice_feed'); publicKey=data.vapid_public||'';
      if(!started)return;
      const wasInitialized=initialized;
      const unread=data.events.filter(e=>!e.read); $('adminNoticeCount').textContent=String(unread.length);
      $('adminNoticeList').replaceChildren();
      for(const event of data.events) {
        const card=document.createElement('button'); card.type='button'; card.className='panel'; card.style.cssText='display:block;width:100%;text-align:right;margin:10px 0;background:#09263d;color:#e5f2ff';
        card.textContent=(event.read?'':'● ')+event.title+' — '+event.body+' — '+new Date(event.created_at).toLocaleString('ar-JO',{timeZone:'Asia/Amman'});
        card.onclick=async()=>{card.disabled=true;try {await rpc('admin_notice_read',{p_id:event.id});open(event.target==='guardRequests'?'notifications':event.target);if(event.target==='guardRequests') {await window.GuardAdmin?.load();$('guardAdminPanel').scrollIntoView({block:'start'});}await refresh();}catch(err){status(err.message);card.disabled=false;}};
        $('adminNoticeList').append(card);
        if(!seen.has(event.id)&&wasInitialized&&enabled&&!event.read&&document.visibilityState==='visible') {
          showToast(event.title+' — '+event.body,'ok');
          // Registration already has a live chime in the dashboard; avoid doubling it.
          if(event.topic!=='REGISTRATION'&&adminAlertsEnabled) playWatarLikeChime();
        }
      }
      seen=new Set(data.events.map(e=>e.id));
      initialized=true;
      for(const button of document.querySelectorAll('.tab-btn')) {
        const destination=[...targets].find(t=>(button.getAttribute('onclick')||'').includes("'"+t+"'")); if(!destination||destination==='notifications')continue;
        const count=unread.filter(e=>e.target===destination).length;
        let badge=button.querySelector('.live-notice-badge'); if(!badge){badge=document.createElement('span');badge.className='badge yellow live-notice-badge';button.append(badge);}
        badge.textContent=' '+count+' جديد';badge.hidden=count===0;button.classList.toggle('has-new-notice',count>0);
      }
      status(enabled?'تنبيهات هذا الجهاز مفعلة.':'اضغط تفعيل لحفظ الجهاز وتشغيل التنبيهات.');
    } catch(err){status(err.message);} finally{busy=false;}
  }
  async function enable() {
    $('adminNoticeEnable').disabled=true;
    try {
      ensureAudioContext();
      let subscription=null;
      if('Notification' in window&&'serviceWorker' in navigator&&'PushManager' in window&&publicKey) {
        const permission=await Notification.requestPermission();
        if(permission==='granted') {
          const registration=await navigator.serviceWorker.register('./service-worker.js'); await navigator.serviceWorker.ready;
          subscription=await registration.pushManager.getSubscription();
          if(!subscription){const base64=publicKey.replace(/-/g,'+').replace(/_/g,'/');const key=Uint8Array.from(atob(base64+'='.repeat((4-base64.length%4)%4)),c=>c.charCodeAt(0));subscription=await registration.pushManager.subscribe({userVisibleOnly:true,applicationServerKey:key});}
        }
      }
      await rpc('admin_notice_device',{p_id:device,p_label:navigator.userAgent.slice(0,100),p_subscription:subscription?.toJSON()||null,p_enabled:true});
      enabled=true;localStorage.setItem(preference,'true');rememberSound(true);adminAlertsEnabled=true;localStorage.setItem('adminAlertsEnabled_v2','true');updateAdminAlertState();playWatarLikeChime();
      status(subscription?'تم حفظ الجهاز وتفعيل الإشعارات المباشرة وإشعارات الهاتف.':'تم حفظ الجهاز وتفعيل تنبيهات اللوحة. إشعارات الخلفية تحتاج متصفحًا داعمًا وإذن الإشعارات؛ على iPhone أضف التطبيق للشاشة الرئيسية.');
    }catch(err){status(err.message||'تعذر تفعيل تنبيهات الجهاز.');}finally{$('adminNoticeEnable').disabled=false;}
  }
  async function stop(disable=false) {
    clearInterval(timer);started=false;
    if(disable&&device) {await rpc('admin_notice_device',{p_id:device,p_label:'',p_subscription:null,p_enabled:false});enabled=false;localStorage.setItem(preference,'false');}
  }
  async function start() {
    if(started||!adminProfile)return;started=true;
    const {data}=await supabaseClient.auth.getSession();const uid=data?.session?.user?.id;if(!uid){started=false;return;}
    preference='alb_admin_notices_'+uid;
    try {device=localStorage.getItem('alb_admin_notice_device_v1')||crypto.randomUUID();localStorage.setItem('alb_admin_notice_device_v1',device);enabled=localStorage.getItem(preference)==='true';}catch(_){device=crypto.randomUUID();}
    try {adminAlertsEnabled=localStorage.getItem(preference+'_sound')==='true';}catch(_){adminAlertsEnabled=false;}updateAdminAlertState();
    $('adminNoticeEnable').onclick=enable;
    $('adminNoticeDisable').onclick=async()=>{try {await stop(true);await start();status('أوقفت تنبيهات هذا الجهاز.');}catch(err){status(err.message);}};
    await refresh();timer=setInterval(refresh,10000);
    const target=new URL(location.href).searchParams.get('section');if(targets.has(target))open(target);
    if(target==='guardRequests'){open('notifications');await window.GuardAdmin?.load();$('guardAdminPanel').scrollIntoView({block:'start'});}
  }
  window.addEventListener('pagehide',()=>{clearInterval(timer);});
  window.addEventListener('pageshow',()=>{if(started){clearInterval(timer);timer=setInterval(refresh,10000);refresh();}});
  document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')refresh();});
  function rememberSound(value) {if(preference)try{localStorage.setItem(preference+'_sound',String(value));}catch(_){} }
  return {start,refresh,stop,rememberSound};
})();
