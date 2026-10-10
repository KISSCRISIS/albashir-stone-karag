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
        const row = document.createElement('p'), text = document.createElement('span'), edit = document.createElement('button');
        text.textContent = (guard.full_name || 'حارس') + ' — ' + guard.national_id + ' — ' + (guard.is_active ? 'فعال' : 'معطّل') + ' ';
        edit.textContent = 'تعديل / تعطيل'; edit.type = 'button';
        edit.onclick = () => { editing = guard.id; $('guardAdminName').value = guard.full_name; $('guardAdminNational').value = guard.national_id;
          $('guardAdminPhone').value = ''; $('guardAdminPhone').placeholder = 'اتركه فارغًا للإبقاء على الهاتف؛ آخره ' + guard.phone_hint;
          $('guardAdminActive').checked = guard.is_active; $('guardAdminName').focus(); };
        row.append(text, edit); $('guardAccountsList').append(row);
      }
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
  $('guardEmergencySave').onclick = async () => {
    const button = $('guardEmergencySave'); if (button.disabled) return; button.disabled = true;
    try { const data = await rpc('admin_set_guard_emergency', { p_enabled: $('guardEmergencyEnabled').checked }); notice(data.message); }
    catch (err) { notice(err.message); } finally { button.disabled = false; }
  };
  return { load };
})();
if (adminProfile?.role === 'SUPER_ADMIN') window.GuardAdmin.load();
