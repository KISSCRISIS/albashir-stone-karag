/* Administrative directory uses existing authorized registration records only. */
(() => {
  const el = id => document.getElementById(id);
  let records = [], page = 0;
  const size = 24;
  const category = row => ['PERMANENT', 'TEMPORARY'].includes(row.registration_category) ? row.registration_category : 'UNKNOWN';
  const labels = {PERMANENT:'موظفو مستشفى البشير — تسجيل دائم', TEMPORARY:'موظفو الجهات الأخرى — مؤقت / خارجي', UNKNOWN:'غير مصنّفين'};
  const statuses = {APPROVED:'معتمد', PENDING:'بانتظار الاعتماد', PENDING_FIRST_ENTRY:'بانتظار الدخول الأول', NEW:'طلب جديد', REJECTED:'مرفوض'};
  const normalize = value => String(value || '').toLocaleLowerCase().replace(/[٠-٩]/g, n => '٠١٢٣٤٥٦٧٨٩'.indexOf(n)).trim();
  function options(id, field) {
    const select = el(id), previous = select.value;
    select.replaceChildren(new Option('الكل', ''));
    [...new Set(records.map(r => r[field] || 'غير محددة'))].sort((a,b)=>a.localeCompare(b,'ar')).forEach(value => select.add(new Option(value+' ('+records.filter(r=>(r[field]||'غير محددة')===value).length+')', value)));
    if ([...select.options].some(o=>o.value===previous)) select.value=previous;
  }
  function line(parent, label, value) {
    const p=document.createElement('p'), title=document.createElement('strong');
    title.textContent=label+': '; p.append(title,document.createTextNode(String(value || 'غير مسجّل'))); parent.append(p);
  }
  function render() {
    const query=normalize(el('directorySearch').value), selected=el('directoryCategory').value, status=el('directoryStatus').value;
    const rows=records.filter(r=>(!selected||category(r)===selected)&&(!status||(status==='PENDING'?['PENDING','NEW','PENDING_FIRST_ENTRY'].includes(r.status):r.status===status))&&['Job','Specialty','Entity'].every((key,i)=>!el('directory'+key).value||(r[['job_type','specialty','affiliated_entity'][i]]||'غير محددة')===el('directory'+key).value)&&(!query||[r.full_name,r.employee_id,r.mobile_number].some(v=>normalize(v).includes(query))));
    page=Math.min(page,Math.max(0,Math.ceil(rows.length/size)-1));
    el('directoryCount').textContent='نتائج التصفية: '+rows.length+' سجل موظف';
    const host=el('directoryCards'); host.replaceChildren();
    rows.slice(page*size,(page+1)*size).forEach(row=>{
      const card=document.createElement('article');card.className='directory-card';
      const header=document.createElement('header');
      if(row.employee_photo_url){const img=document.createElement('img');img.alt='صورة الموظف';img.dataset.photoRef=row.employee_photo_url;header.append(img);}else{const span=document.createElement('span');span.textContent='لا توجد صورة';header.append(span);}
      const name=document.createElement('h3');name.textContent=row.full_name||'اسم غير مسجّل';header.append(name);card.append(header);
      line(card,'رقم الموظف',row.employee_id);line(card,'الحالة',statuses[row.status]||row.status);line(card,'مجموعة التسجيل',labels[category(row)]);
      line(card,'الوظيفة',row.job_type);line(card,'الاختصاص',row.specialty);line(card,'الجهة',row.affiliated_entity);
      const details=document.createElement('details'),summary=document.createElement('summary');summary.textContent='معلومات الموظف';details.append(summary);
      line(details,'رقم الهاتف',row.mobile_number);line(details,'القسم',row.department);
      for(const [label,key] of [['تاريخ التسجيل','created_at'],['الدخول الأول','first_entry_at']])line(details,label,row[key]?new Date(row[key]).toLocaleString('ar-JO'):null);
      line(details,'التحقق السريع',row.trusted_device_enabled?'مفعّل':'غير مفعّل');card.append(details);host.append(card);
    });
    if(!rows.length)host.textContent='لا توجد سجلات تطابق هذه الخيارات.';
    el('directoryPage').textContent=(page+1)+' / '+Math.max(1,Math.ceil(rows.length/size));
    el('directoryPrevious').disabled=page===0;el('directoryNext').disabled=(page+1)*size>=rows.length;
    if(typeof hydrateAdminPhotos==='function')hydrateAdminPhotos(host);
  }
  window.EmployeeDirectory={update(rows){records=rows.slice();options('directoryJob','job_type');options('directorySpecialty','specialty');options('directoryEntity','affiliated_entity');
    const approved=records.filter(r=>r.status==='APPROVED');
    el('directorySummary').textContent='المعتمدون: '+approved.length+' | تسجيل دائم: '+approved.filter(r=>category(r)==='PERMANENT').length+' | مؤقت / خارجي: '+approved.filter(r=>category(r)==='TEMPORARY').length+' | غير مصنّفين: '+approved.filter(r=>category(r)==='UNKNOWN').length;
    render();}};
  for(const id of ['Search','Category','Status','Job','Specialty','Entity'])el('directory'+id).addEventListener(id==='Search'?'input':'change',()=>{page=0;render();});
  el('directoryPrevious').onclick=()=>{page--;render();};el('directoryNext').onclick=()=>{page++;render();};
})();
