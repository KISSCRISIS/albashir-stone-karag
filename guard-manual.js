(() => {
  'use strict';
  const $ = id => document.getElementById(id), storageKey = 'alb_guard_session_v1';
  let token = '', busy = false, pending = null, emergencyEnabled = false;
  // Emergency availability must come from the server, not a browser-controlled flag.
  // Until station-scoped server authorization is deployed, fail closed.
  const qrFailureOnThisPhone = () => false;
  try { token = localStorage.getItem(storageKey) || ''; } catch (_) {}
  const message = text => { $('guardManualMessage').textContent = text; };
  function panelState(open) {
    document.body.classList.toggle('guard-panel-open',open);
    for(const child of document.querySelector('main').children) if(!['guardManualPanel','result'].includes(child.id)) child.inert=open;
  }
  function clearSession() {
    token = ''; pending = null;
    try { localStorage.removeItem(storageKey); } catch (_) {}
    $('guardLoginForm').hidden = false; $('guardEntryForm').hidden = true;
    $('manualEmployeeId').value = ''; $('guardPhone').value = '';
    if ($('guardSessionHeader')) $('guardSessionHeader').hidden = true;
    if ($('guardAvatar')) { $('guardAvatar').hidden = true; $('guardAvatar').removeAttribute('src'); }
  }
  async function showIdentity() {
    if (!token || !$('guardSessionHeader')) return;
    try {
      const data = await rpc('guard_session_profile',{p_token:token});
      $('guardSessionName').textContent = data.full_name || 'حارس';
      $('guardSessionTime').textContent = 'وقت الدخول: ' + new Date(data.logged_in_at).toLocaleString('ar-JO',{timeZone:'Asia/Amman'});
      $('guardAvatar').hidden = !data.photo_base64;
      if (data.photo_base64) $('guardAvatar').src = 'data:image/jpeg;base64,'+data.photo_base64.replace(/\s/g,'');
      else $('guardAvatar').removeAttribute('src');
      $('guardSessionHeader').hidden = false;
    } catch (err) { message(err.message); }
  }
  function authenticated(data) {
    $('guardLoginForm').hidden = true; $('guardEntryForm').hidden = false;
    $('guardWelcome').textContent = data.full_name ? 'مرحبًا ' + data.full_name : 'مرحبًا بك في شاشة الحارس';
    emergencyEnabled = data.emergency_enabled === true;
    if ($('guardEmergencyToggle')) $('guardEmergencyToggle').textContent = emergencyEnabled ? 'إيقاف وضع الطوارئ' : 'تفعيل وضع الطوارئ';
    message(emergencyEnabled ? 'أدخل رقم الموظف لتسجيل الزيارة.' : 'فعّل الدخول اليدوي عند تعطل QR؛ تسجّل الزيارات وتحتسب ضمن الحد اليومي.');
    $('guardEntryButton').disabled = !data.emergency_enabled || !qrFailureOnThisPhone();
    if ($('guardEmergencyToggle')) $('guardEmergencyToggle').disabled = !qrFailureOnThisPhone() && !emergencyEnabled;
    if (data.emergency_enabled) $('manualEmployeeId').focus();
  }
  async function rpc(name, payload) {
    const { data, error } = await guardRpc(name, payload, 8000);
    if (error) throw Error('تعذر الاتصال بالخادم. حاول مجددًا.');
    if (data?.ok !== true) {
      if (data?.error === 'AUTH_REQUIRED') clearSession();
      throw Error(data?.message || 'تعذر إكمال الطلب؛ سجل دخول الحارس مجددًا.');
    }
    return data;
  }
  $('manualOpen').onclick = async () => {
    $('guardManualPanel').hidden = false; panelState(true); message('');

    if (!token) { clearSession(); $('guardIdentity').focus(); return; }
    try { authenticated(await rpc('guard_session_status', { p_token: token })); }
    catch (err) { message(err.message); }
  };
  $('manualClose').onclick = () => { $('guardManualPanel').hidden = true; panelState(false); $('manualEmployeeId').value = ''; $('manualOpen').focus(); };
  $('guardManualPanel').addEventListener('keydown',event=>{
    if(event.key==='Escape'){event.preventDefault();$('manualClose').click();return;}
    if(event.key!=='Tab')return;
    const controls=[...$('guardManualPanel').querySelectorAll('button,input,a,summary')].filter(e=>!e.disabled&&e.getClientRects().length);
    const first=controls[0],last=controls[controls.length-1];
    if(event.shiftKey&&document.activeElement===first){event.preventDefault();last?.focus();}
    else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first?.focus();}
  });
  $('guardLoginForm').onsubmit = async event => {
    event.preventDefault(); if (busy) return;
    busy = true; $('guardLoginButton').disabled = true;
    try {
      const data = await rpc('guard_login', { p_identity: $('guardIdentity').value.trim(), p_phone: $('guardPhone').value });
      token = data.token;
      try { localStorage.setItem(storageKey, token); } catch (_) {}
      $('guardPhone').value = ''; authenticated(data); await showIdentity();
    } catch (err) { message(err.message); }
    finally { busy = false; $('guardLoginButton').disabled = false; }
  };
  $('guardLogoutButton').onclick = async () => {
    if (busy) return;
    try { await rpc('guard_logout', { p_token: token }); clearSession(); message('تم تسجيل خروج الحارس.'); }
    catch (err) { message('تعذر إلغاء الجلسة؛ أعد محاولة الخروج عند عودة الاتصال.'); }
  };
  if ($('guardEmergencyToggle')) $('guardEmergencyToggle').onclick = async () => {
    if (busy || !token) return;
    if (!emergencyEnabled && !qrFailureOnThisPhone()) { message('الدخول اليدوي متاح فقط عند تعطل توليد QR على هذا الهاتف.'); return; }
    busy = true; $('guardEmergencyToggle').disabled = true;
    try { const data = await rpc('guard_set_emergency',{p_token:token,p_enabled:!emergencyEnabled}); authenticated(await rpc('guard_session_status',{p_token:token})); message(data.message); }
    catch(err) { message(err.message); } finally { busy=false; $('guardEmergencyToggle').disabled=!qrFailureOnThisPhone() && !emergencyEnabled; }
  };
  $('guardEntryForm').onsubmit = async event => {
    event.preventDefault(); if (busy || !token) return;
    if (!qrFailureOnThisPhone()) { message('لا يمكن الدخول اليدوي ما دام توليد QR يعمل على هذا الهاتف.'); return; }
    const employeeId = $('manualEmployeeId').value.trim();
    if (!employeeId) return;
    if (!pending || pending.employeeId !== employeeId) pending = { employeeId, id: crypto.randomUUID() };
    busy = true; $('guardEntryButton').disabled = true; message('جارِ تسجيل الزيارة...');
    try {
      const data = await rpc('guard_manual_employee_entry', { p_token: token, p_employee_id: employeeId, p_request_id: pending.id });
      pending = null; $('manualEmployeeId').value = ''; $('guardManualPanel').hidden = true; panelState(false);
      // Reuse the existing result/photo display and its ten-second cleanup.
      resultUntil = Date.now() + 10000;
      $('result').className = ({ ALLOWED: 'allowed', LIMITED: 'limited', DENIED: 'denied' })[data.result] || 'denied';
      $('decision').textContent = ({ ALLOWED: 'مسموح بالدخول', LIMITED: 'مسموح بشكل مؤقت', DENIED: 'غير مسموح بالدخول' })[data.result] || 'غير مسموح بالدخول';
      const employee = data.employee || {};
      $('name').textContent = employee.full_name || '';
      $('job').textContent = employee.job_type ? 'الوظيفة: ' + employee.job_type : '';
      $('specialty').textContent = employee.specialty ? 'الاختصاص: ' + employee.specialty : '';
      photoGeneration++; $('photo').hidden = true; $('photo').removeAttribute('src');
      if (photoBlob) { URL.revokeObjectURL(photoBlob); photoBlob = null; }
      $('result').hidden = false; $('qrPanel').hidden = true;
      if (employee.has_photo && data.read_key) loadPhoto(data.read_key);
    } catch (err) { message('لم تُؤكد نتيجة الطلب. ' + err.message + ' إعادة المحاولة بنفس الرقم لا تحتسب زيارة ثانية.'); }
    finally { busy = false; $('guardEntryButton').disabled = !emergencyEnabled || !qrFailureOnThisPhone(); }
  };
  if ($('guardSharedLogin')) $('guardSharedLogin').onclick = () => { $('guardIdentity').value = '7000000000'; $('guardPhone').focus(); };
  window.addEventListener('guard-qr-health-change', () => {
    if ($('guardEntryButton')) $('guardEntryButton').disabled = !emergencyEnabled || !qrFailureOnThisPhone();
    if ($('guardEmergencyToggle')) $('guardEmergencyToggle').disabled = !qrFailureOnThisPhone();
    if (!qrFailureOnThisPhone()) pending = null;
  });
  showIdentity();
})();
