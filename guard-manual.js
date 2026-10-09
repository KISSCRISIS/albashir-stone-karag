(() => {
  'use strict';
  const $ = id => document.getElementById(id), storageKey = 'alb_guard_session_v1';
  let token = '', busy = false, pending = null;
  try { token = localStorage.getItem(storageKey) || ''; } catch (_) {}
  const message = text => { $('guardManualMessage').textContent = text; };
  function clearSession() {
    token = ''; pending = null;
    try { localStorage.removeItem(storageKey); } catch (_) {}
    $('guardLoginForm').hidden = false; $('guardEntryForm').hidden = true;
    $('manualEmployeeId').value = ''; $('guardPhone').value = '';
  }
  function authenticated(data) {
    $('guardLoginForm').hidden = true; $('guardEntryForm').hidden = false;
    $('guardWelcome').textContent = 'الحارس: ' + data.full_name;
    message(data.emergency_enabled ? 'أدخل رقم الموظف لتسجيل الزيارة.' : 'وضع الطوارئ غير مفعّل؛ تطلب الإدارة تفعيله عند الحاجة.');
    $('guardEntryButton').disabled = !data.emergency_enabled;
    if (data.emergency_enabled) $('manualEmployeeId').focus();
  }
  async function rpc(name, payload) {
    const { data, error } = await guardRpc(name, payload, 8000);
    if (error) throw Error('تعذر الاتصال. أعد المحاولة بنفس الرقم.');
    if (data?.ok !== true) {
      if (data?.error === 'AUTH_REQUIRED') clearSession();
      throw Error(data?.message || 'تعذر إكمال الطلب؛ سجل دخول الحارس مجددًا.');
    }
    return data;
  }
  $('manualOpen').onclick = async () => {
    $('guardManualPanel').hidden = false; message('');
    $('guardManualPanel').scrollIntoView({ behavior: 'smooth', block: 'start' });
    if (!token) { clearSession(); $('guardIdentity').focus(); return; }
    try { authenticated(await rpc('guard_session_status', { p_token: token })); }
    catch (err) { message(err.message); }
  };
  $('manualClose').onclick = () => { $('guardManualPanel').hidden = true; $('manualEmployeeId').value = ''; };
  $('guardLoginForm').onsubmit = async event => {
    event.preventDefault(); if (busy) return;
    busy = true; $('guardLoginButton').disabled = true;
    try {
      const data = await rpc('guard_login', { p_identity: $('guardIdentity').value.trim(), p_phone: $('guardPhone').value });
      token = data.token;
      try { localStorage.setItem(storageKey, token); } catch (_) {}
      $('guardPhone').value = ''; authenticated(data);
    } catch (err) { message(err.message); }
    finally { busy = false; $('guardLoginButton').disabled = false; }
  };
  $('guardLogoutButton').onclick = async () => {
    if (busy) return;
    try { await rpc('guard_logout', { p_token: token }); clearSession(); message('تم تسجيل خروج الحارس.'); }
    catch (err) { message('تعذر إلغاء الجلسة؛ أعد محاولة الخروج عند عودة الاتصال.'); }
  };
  $('guardEntryForm').onsubmit = async event => {
    event.preventDefault(); if (busy || !token) return;
    const employeeId = $('manualEmployeeId').value.trim();
    if (!employeeId) return;
    if (!pending || pending.employeeId !== employeeId) pending = { employeeId, id: crypto.randomUUID() };
    busy = true; $('guardEntryButton').disabled = true; message('جارِ تسجيل الزيارة...');
    try {
      const data = await rpc('guard_manual_employee_entry', { p_token: token, p_employee_id: employeeId, p_request_id: pending.id });
      pending = null; $('manualEmployeeId').value = ''; $('guardManualPanel').hidden = true;
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
    finally { busy = false; $('guardEntryButton').disabled = false; }
  };
})();
