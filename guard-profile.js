(() => {
  'use strict';
  const $ = id => document.getElementById(id), key = 'alb_guard_session_v1';
  const client = supabase.createClient(APP_CONFIG.SUPABASE_URL, APP_CONFIG.SUPABASE_ANON_KEY, {auth:{persistSession:false,autoRefreshToken:false}});
  let token = '', picture, removePicture = false, processing = false, busy = false;
  try { token = localStorage.getItem(key) || ''; } catch (_) {}
  const notice = text => { $('profileStatus').textContent = text; };
  async function rpc(name, payload) {
    const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 10000);
    try {
      const {data,error} = await client.rpc(name, payload).abortSignal(controller.signal);
      if (error) throw Error('تعذر الاتصال؛ أعد المحاولة.');
      if (data?.error === 'AUTH_REQUIRED') {
        token = ''; $('guardProfileForm').hidden = true;
        try { localStorage.removeItem(key); } catch (_) {}
        throw Error('سجّل دخول الحارس أولًا من شاشة الحارس.');
      }
      if (data?.ok !== true) throw Error(data?.message || 'تعذر حفظ المعلومات.');
      return data;
    } finally { clearTimeout(timer); }
  }
  $('profileBack').onclick = () => history.back();
  function preview(base64) {
    $('profilePreview').hidden = !base64; $('profileRemovePhoto').hidden = !base64;
    if (base64) $('profilePreview').src = 'data:image/jpeg;base64,' + base64.replace(/\s/g,'');
    else $('profilePreview').removeAttribute('src');
  }
  $('profileRemovePhoto').onclick = () => { picture = undefined; removePicture = true; $('profilePhoto').value = ''; preview(null); };
  $('profilePhoto').onchange = async () => {
    const file = $('profilePhoto').files[0]; if (!file) return;
    if (processing) return; processing = true; $('profileSave').disabled = true;
    let url;
    try {
      if (!file.type.startsWith('image/') || file.size > 20 * 1024 * 1024) throw Error('اختر صورة لا تتجاوز 20 ميجابايت.');
      url = URL.createObjectURL(file); const img = new Image(); img.src = url; await img.decode();
      if (!img.naturalWidth || !img.naturalHeight) throw Error('صورة غير صالحة.');
      const ratio = Math.min(1,512/img.naturalWidth,512/img.naturalHeight), canvas = document.createElement('canvas');
      canvas.width = Math.max(1,Math.round(img.naturalWidth*ratio)); canvas.height = Math.max(1,Math.round(img.naturalHeight*ratio));
      const ctx = canvas.getContext('2d'); ctx.fillStyle = '#fff'; ctx.fillRect(0,0,canvas.width,canvas.height); ctx.drawImage(img,0,0,canvas.width,canvas.height);
      let data = canvas.toDataURL('image/jpeg',.8), base64 = data.split(',')[1];
      if (base64.length > 262144) { data = canvas.toDataURL('image/jpeg',.55); base64 = data.split(',')[1]; }
      if (!data.startsWith('data:image/jpeg;base64,') || base64.length > 262144) throw Error('تعذر ضغط الصورة؛ اختر صورة أصغر.');
      picture = base64; removePicture = false; preview(picture); notice('الصورة جاهزة؛ اضغط حفظ معلوماتي.');
    } catch (_) { $('profilePhoto').value = ''; notice('تعذرت قراءة الصورة. اختر JPG أو PNG أو WEBP صالحًا.'); }
    finally { if (url) URL.revokeObjectURL(url); processing = false; $('profileSave').disabled = false; }
  };
  $('guardProfileForm').onsubmit = async event => {
    event.preventDefault(); if (busy || processing || !token) return;
    const name = $('profileName').value.trim();
    if (name.length === 1) { notice('أدخل اسمًا من حرفين على الأقل أو اتركه فارغًا.'); return; }
    const profile = {full_name:name,age:$('profileAge').value || null,residence:$('profileResidence').value.trim(),about:$('profileAbout').value.trim()};
    if (picture !== undefined) profile.photo_base64 = picture;
    if (removePicture) profile.remove_photo = true;
    busy = true; $('profileSave').disabled = true;
    try { const data = await rpc('guard_save_profile',{p_token:token,p_profile:profile}); picture = undefined; removePicture = false; notice(data.message); }
    catch (err) { notice(err.message); }
    finally { busy = false; $('profileSave').disabled = false; }
  };
  (async () => {
    if (!token) { notice('سجّل دخول الحارس أولًا من شاشة الحارس، ثم افتح صفحتك الشخصية.'); return; }
    try {
      const {profile:p} = await rpc('guard_get_profile',{p_token:token});
      $('profileNational').value = p.national_id; $('profileName').value = p.full_name || '';
      $('profileAge').value = p.age ?? ''; $('profileResidence').value = p.residence || ''; $('profileAbout').value = p.about || '';
      preview(p.photo_base64); $('guardProfileForm').hidden = false; notice('يمكنك حفظ الملف دون ملء أي معلومات اختيارية.');
    } catch (err) { notice(err.message); }
  })();
})();
