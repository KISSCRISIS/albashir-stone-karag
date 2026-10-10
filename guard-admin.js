window.GuardAdmin = (() => {
  'use strict';
  const $ = id => document.getElementById(id); let editing = null;
  const notice = text => { $('guardAdminMessage').textContent = text; };
  async function rpc(name, payload = {}) {
    const { data, error } = await supabaseClient.rpc(name, payload);
    if (error || data?.ok !== true) throw Error(data?.message || 'تعذر تحديث ملفات الحراس.');
    return data;
  }
  async function load() {
    if (adminProfile?.role !== 'SUPER_ADMIN') return;
    $('guardAdminPanel').hidden = false;
    try {
      const data = await rpc('admin_list_guards');
      $('guardEmergencyEnabled').checked = data.emergency_enabled;
      $('guardAccountsList').replaceChildren();
      for (const guard of data.guards) {
        if (guard.national_id === '7000000000') continue; // Managed separately to preserve the shared identity.
        const row = document.createElement('p'), text = document.createElement('span'), edit = document.createElement('button');
        text.textContent = (guard.full_name || 'حارس') + ' — ' + guard.national_id + ' — ' + (guard.is_active ? 'فعال' : 'معطّل') + ' ';
        edit.textContent = 'تعديل / تعطيل'; edit.type = 'button';
        edit.onclick = () => { editing = guard.id; $('guardAdminName').value = guard.full_name; $('guardAdminNational').value = guard.national_id;
          $('guardAdminPhone').value = ''; $('guardAdminPhone').placeholder = 'اتركه فارغًا للإبقاء على الهاتف؛ آخره ' + guard.phone_hint;
          $('guardAdminActive').checked = guard.is_active; $('guardAdminName').focus(); };
        row.append(text, edit); $('guardAccountsList').append(row);
      }
      const applications = await rpc('admin_guard_requests');
      $('guardRequestsList').replaceChildren(); $('guardSigninList').replaceChildren();
      for (const request of applications.requests) {
        const card = document.createElement('article'); card.className = 'panel';
        if (request.photo_base64) { const img = document.createElement('img'); img.src = 'data:image/jpeg;base64,'+request.photo_base64.replace(/\s/g,''); img.alt = 'صورة الحارس'; img.width = 64; img.height = 64; card.append(img); }
        const text = document.createElement('p');
        text.textContent = [request.full_name || 'اسم اختياري غير مضاف',request.national_id,'آخر الهاتف: '+request.phone_hint,request.age ? 'العمر: '+request.age : '',request.residence,request.about,request.status,new Date(request.created_at).toLocaleString('ar-JO',{timeZone:'Asia/Amman'})].filter(Boolean).join(' — '); card.append(text);
        if (request.status === 'PENDING') for (const approve of [true,false]) {
          const button = document.createElement('button'); button.type = 'button'; button.textContent = approve ? 'موافقة' : 'رفض';
          button.onclick = async () => { if (button.disabled) return; card.querySelectorAll('button').forEach(b=>b.disabled=true); try { const result = await rpc('admin_review_guard_request',{p_id:request.id,p_approve:approve}); notice(result.message); await load(); } catch(err) { notice(err.message); card.querySelectorAll('button').forEach(b=>b.disabled=false); } }; card.append(button);
        }
        $('guardRequestsList').append(card);
      }
      for (const entry of applications.signins) { const row = document.createElement('p'); row.textContent = (entry.is_shared ? 'الحساب الجماعي' : entry.full_name || 'حارس شخصي')+' — '+new Date(entry.created_at).toLocaleString('ar-JO',{timeZone:'Asia/Amman'}); $('guardSigninList').append(row); }
    } catch (err) { notice(err.message); }
  }
  $('guardAdminForm').onsubmit = async event => {
    event.preventDefault(); const button = $('guardAdminSave'); if (button.disabled) return; button.disabled = true;
    try {
      const data = await rpc('admin_save_guard', { p_guard_id: editing, p_full_name: $('guardAdminName').value.trim(),
        p_national_id: $('guardAdminNational').value.trim(), p_phone: $('guardAdminPhone').value, p_is_active: $('guardAdminActive').checked });
      editing = null; $('guardAdminForm').reset(); $('guardAdminPhone').value = ''; notice(data.message); await load();
    } catch (err) { notice(err.message); } finally { button.disabled = false; }
  };
  $('guardAdminNew').onclick = () => { editing = null; $('guardAdminForm').reset(); $('guardAdminPhone').placeholder = 'رقم هاتف الحارس'; };
  $('guardSharedForm').onsubmit = async event => { event.preventDefault(); const button = event.submitter; if (button.disabled) return; button.disabled = true; try { const result = await rpc('admin_configure_shared_guard',{p_phone:$('guardSharedPhone').value,p_enabled:$('guardSharedEnabled').checked}); $('guardSharedPhone').value = ''; notice(result.message+' — اسم المستخدم: 7000000000'); await load(); } catch(err) { notice(err.message); } finally { button.disabled = false; } };
  $('guardEmergencySave').onclick = async () => {
    const button = $('guardEmergencySave'); if (button.disabled) return; button.disabled = true;
    try { const data = await rpc('admin_set_guard_emergency', { p_enabled: $('guardEmergencyEnabled').checked }); notice(data.message); }
    catch (err) { notice(err.message); } finally { button.disabled = false; }
  };
  return { load };
})();
if (adminProfile?.role === 'SUPER_ADMIN') window.GuardAdmin.load();
