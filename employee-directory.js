/* Administrative directory uses existing authorized registration records only. */
(() => {
  const el = id => document.getElementById(id);
  let records = [], page = 0, catalog = {};
  const size = 24;
  const category = row => ['PERMANENT', 'TEMPORARY'].includes(row.registration_category) ? row.registration_category : 'UNKNOWN';
  const labels = {PERMANENT:'موظفو مستشفى البشير — تسجيل دائم', TEMPORARY:'موظفو الجهات الأخرى — مؤقت / خارجي', UNKNOWN:'غير مصنّفين'};
  const statuses = {APPROVED:'معتمد', PENDING:'بانتظار الاعتماد', PENDING_FIRST_ENTRY:'بانتظار الدخول الأول', NEW:'طلب جديد', REJECTED:'مرفوض'};
  const normalize = value => String(value || '').toLocaleLowerCase().replace(/[٠-٩]/g, n => '٠١٢٣٤٥٦٧٨٩'.indexOf(n)).trim();
  const fieldValue=(row,field)=>row[field]||'غير محددة';
  function isOtherEntity(row){return !!row.affiliated_entity&&!catalog.affiliated_entity?.some(o=>o.value===row.affiliated_entity&&o.value!=='OTHER');}
  function options(id, field) {
    const select = el(id), previous = select.value;
    select.replaceChildren(new Option('الكل', ''));
    const values=new Map((catalog[field]||[]).map(o=>[o.value,o.label]));
    records.forEach(row=>{const value=fieldValue(row,field);if(!values.has(value))values.set(value,value);});
    [...values].sort((a,b)=>a[1].localeCompare(b[1],'ar')).forEach(([value,label])=>{const count=records.filter(r=>field==='affiliated_entity'&&value==='OTHER'?isOtherEntity(r):fieldValue(r,field)===value).length;select.add(new Option(label+' ('+count+')',value));});
    if ([...select.options].some(o=>o.value===previous)) select.value=previous;
  }
  function line(parent, label, value) {
    const p=document.createElement('p'), title=document.createElement('strong');
    title.textContent=label+': '; p.append(title,document.createTextNode(String(value || 'غير مسجّل'))); parent.append(p);
  }
  function render() {
    const query=normalize(el('directorySearch').value), selected=el('directoryCategory').value, status=el('directoryStatus').value;
    const rows=records.filter(r=>(!selected||category(r)===selected)&&(!status||(status==='PENDING'?['PENDING','NEW','PENDING_FIRST_ENTRY'].includes(r.status):r.status===status))&&['Job','Specialty','Entity','Department'].every((key,i)=>{const value=el('directory'+key).value,field=['job_type','specialty','affiliated_entity','department'][i];return !value||(field==='affiliated_entity'&&value==='OTHER'?isOtherEntity(r):fieldValue(r,field)===value);})&&(!query||[r.full_name,r.employee_id,r.mobile_number].some(v=>normalize(v).includes(query))));
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
  window.EmployeeDirectory={update(rows){records=rows.slice();options('directoryJob','job_type');options('directorySpecialty','specialty');options('directoryEntity','affiliated_entity');options('directoryDepartment','department');
    const approved=records.filter(r=>r.status==='APPROVED');
    el('directorySummary').textContent='المعتمدون: '+approved.length+' | تسجيل دائم: '+approved.filter(r=>category(r)==='PERMANENT').length+' | مؤقت / خارجي: '+approved.filter(r=>category(r)==='TEMPORARY').length+' | غير مصنّفين: '+approved.filter(r=>category(r)==='UNKNOWN').length;
    render();}};
  for(const id of ['Search','Category','Status','Job','Specialty','Entity','Department'])el('directory'+id).addEventListener(id==='Search'?'input':'change',()=>{page=0;render();});
  fetch('./register.html',{cache:'no-store'}).then(response=>{if(!response.ok)throw Error('catalog unavailable');return response.text();}).then(html=>{
    const source=new DOMParser().parseFromString(html,'text/html');
    for(const [field,id] of [['job_type','jobType'],['specialty','specialty'],['affiliated_entity','affiliatedEntity'],['department','department']]){
      const select=source.getElementById(id);if(!select)throw Error('registration options unavailable');
      catalog[field]=[...select.options].filter(o=>o.value).map(o=>({value:o.value,label:o.textContent.trim()}));
    }
    window.EmployeeDirectory.update(records);
  }).catch(()=>{el('directoryCatalogStatus').textContent='تعذر تحميل خيارات التسجيل الكاملة. حدّث الصفحة لإعادة المحاولة؛ تبقى خيارات السجلات الحالية متاحة.';});
  el('directoryPrevious').onclick=()=>{page--;render();};el('directoryNext').onclick=()=>{page++;render();};
})();
