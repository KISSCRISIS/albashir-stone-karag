/* Owner-selected grants; database RPCs make every authorization decision. */
window.AdminAppointments=(() => {
 const el=id=>document.getElementById(id);let editing=false,selected='';
 async function rpc(name,args={}){const {data,error}=await supabaseClient.rpc(name,args);if(error||data?.ok!==true)throw Error(data?.message||'تعذر حفظ التعيين.');return data;}
 function employees(rows){
  const picker=el('adminEmployeePicker');if(!picker)return;const value=picker.value;
  picker.replaceChildren(new Option('اختر موظفًا معتمدًا',''));
  rows.filter(r=>r.status==='APPROVED').sort((a,b)=>String(a.full_name).localeCompare(String(b.full_name),'ar')).forEach(row=>picker.add(new Option((row.full_name||'موظف')+' — '+row.employee_id,row.id)));
  if([...picker.options].some(o=>o.value===value))picker.value=value;
  preview();
 }
 function preview(){const row=registrationsData.find(r=>r.id===el('adminEmployeePicker').value);selected=row?.id||'';const host=el('adminEmployeePreview');host.replaceChildren();if(!row)return;
  if(row.employee_photo_url){const img=document.createElement('img');img.alt='صورة الموظف';img.dataset.photoRef=row.employee_photo_url;img.width=72;img.height=72;host.append(img);}
  const text=document.createElement('p');text.textContent=(row.full_name||'')+' — '+(row.job_type||'')+' — '+(row.mobile_number||'');host.append(text);hydrateAdminPhotos(host);
 }
 async function load(){if(typeof adminProfile==='undefined'||adminProfile?.role!=='SUPER_ADMIN')return;try{const data=await rpc('super_admin_employee_assignments');const host=el('adminAssignmentList');host.replaceChildren();
  for(const a of data.assignments){const card=document.createElement('article');card.className='directory-card';const heading=document.createElement('h3');heading.textContent=a.full_name+' — '+a.employee_id;const text=document.createElement('p');text.textContent=({PENDING:'بانتظار إكمال حساب الإدارة',ACTIVE:'حساب الإدارة مفعّل',REVOKED:'التعيين ملغى'}[a.status]||a.status)+' — '+(a.role==='SUPER_ADMIN'?'صلاحية كاملة':'صلاحيات محددة');card.append(heading,text);
   if(a.status==='PENDING'){const edit=document.createElement('button');edit.type='button';edit.textContent='تعديل التعيين';edit.onclick=()=>{clearAdminForm();el('adminEmployeePicker').value=a.registration_id;preview();el('adminRole').value=a.role;setPermissionCheckboxes(a.permissions);lockFullRole();el('adminEmployeePicker').focus();};card.append(edit);}
   if(a.status!=='REVOKED'){const revoke=document.createElement('button');revoke.type='button';revoke.className='btn-red';revoke.textContent='إلغاء التعيين';revoke.onclick=async()=>{if(!confirm('إلغاء تعيين الموظف وتعطيل حساب الإدارة إن كان مفعّلًا؟'))return;revoke.disabled=true;try{const response=await rpc('super_admin_revoke_employee_assignment',{p_id:a.id});showToast(response.message,'ok');await load();await loadAdmins();}catch(e){showToast(e.message,'error');revoke.disabled=false;}};card.append(revoke);}host.append(card);
  }
  if(!data.assignments.length)host.textContent='لا توجد تعيينات موظفين بعد.';
 }catch(e){el('adminAppointmentStatus').textContent=e.message;}}
 function lockFullRole(){const full=el('adminRole').value==='SUPER_ADMIN';for(const id of ['permApprove','permViolations','permLogs','permExport','permLimits','permAudit']){el(id).disabled=full;if(full)el(id).checked=true;}}
 const oldClear=window.clearAdminForm,oldFill=window.fillAdminByIndex,oldSave=window.saveAdmin,oldRole=window.applyRoleDefaultPermissions;
 window.clearAdminForm=function(){oldClear();editing=false;el('adminExistingIdentity').hidden=true;el('adminEmployeeSelection').hidden=false;el('adminEmployeePicker').value='';preview();el('adminActive').value='true';el('adminActive').parentElement.hidden=true;el('saveAdminButton').textContent='تعيين الموظف كمشرف';lockFullRole();};
 window.fillAdminByIndex=function(index){oldFill(index);editing=true;el('adminExistingIdentity').hidden=false;el('adminEmployeeSelection').hidden=true;el('adminActive').parentElement.hidden=false;lockFullRole();};
 window.applyRoleDefaultPermissions=function(){oldRole();lockFullRole();};
 window.saveAdmin=async function(){if(editing)return oldSave();if(adminProfile?.role!=='SUPER_ADMIN'){showToast('هذه العملية للمشرف الرئيسي فقط.','error');return;}if(!selected){showToast('اختر موظفًا معتمدًا.','error');return;}
  const button=el('saveAdminButton');if(button.disabled)return;button.disabled=true;try{const data=await rpc('super_admin_assign_employee',{p_registration_id:selected,p_role:el('adminRole').value,p_permissions:getAdminPermissionsFromForm()});showToast(data.message,'ok');clearAdminForm();await load();await loadAudit();}catch(e){showToast(e.message,'error');}finally{button.disabled=false;}
 };
 el('adminEmployeePicker').onchange=preview;clearAdminForm();
 return {employees,load};
})();
