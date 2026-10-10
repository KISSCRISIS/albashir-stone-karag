/* Employee enters own Auth credentials; grants are exclusively server assigned. */
(() => {
 const el=id=>document.getElementById(id);let assignment=null,identity=null,busy=false;
 const authClient=window.supabase.createClient(APP_CONFIG.SUPABASE_URL,APP_CONFIG.SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false},global:{fetch:ALBASHIRRuntime.fetchWithTimeout}});
 function message(text){el('employeeAdminStatus').textContent=text;}
 async function rpc(name,args={}){const {data,error}=await authClient.rpc(name,args);if(error||data?.ok!==true)throw Error(data?.message||'تعذر إكمال حساب الإدارة.');return data;}
 window.EmployeeAdminCompletion={async refresh(credentials){identity=credentials;assignment=null;el('employeeAdminPanel').hidden=true;if(!identity)return;try{const data=await rpc('employee_admin_assignment',{p_employee_id:identity.employeeId,p_mobile_number:identity.mobileNumber});assignment=data.assignment;if(!assignment)return;
   el('employeeAdminPanel').hidden=false;el('employeeAdminForm').hidden=assignment.status!=='PENDING';el('employeeAdminAssignedRole').textContent=assignment.role==='SUPER_ADMIN'?'تم تعيينك مشرفًا بصلاحية كاملة.':'تم تعيينك مشرفًا بصلاحيات يحددها المشرف الرئيسي.';
   message(assignment.status==='ACTIVE'?'حساب الإدارة مفعّل. يمكنك الدخول ببريدك وكلمة مرورك من بوابة الإدارة.':'أكمل بريدك وكلمة مرورك بنفسك. بعد تأكيد البريد، عد إلى ملفك الشخصي واضغط «تفعيل حسابي المؤكد».');
  }catch(e){el('employeeAdminPanel').hidden=false;el('employeeAdminForm').hidden=true;message(e.message);}}};
 async function run(create){if(busy||!assignment||assignment.status!=='PENDING'||!identity)return;const form=el('employeeAdminForm');if(!form.reportValidity())return;busy=true;form.querySelectorAll('button').forEach(b=>b.disabled=true);
  const email=el('employeeAdminEmail').value.trim(),password=el('employeeAdminPassword').value;
  try{
   if(create){await rpc('employee_admin_claim',{p_id:assignment.id,p_employee_id:identity.employeeId,p_mobile_number:identity.mobileNumber,p_email:email});
    const {error}=await authClient.auth.signUp({email,password,options:{emailRedirectTo:window.location.origin+'/profile.html'}});if(error)throw error;message('طلب إنشاء الحساب أُرسل. تحقق من بريدك لتأكيده، ثم عد واضغط «تفعيل حسابي المؤكد». إذا كان لديك حساب بالفعل فاستخدم زر التفعيل.');
   }else{
    const {error}=await authClient.auth.signInWithPassword({email,password});if(error)throw Error('تعذر الدخول؛ تأكد من البريد وكلمة المرور وتأكيد البريد.');
    const claim=await rpc('employee_admin_claim',{p_id:assignment.id,p_employee_id:identity.employeeId,p_mobile_number:identity.mobileNumber,p_email:email});const completed=await rpc('employee_admin_complete',{p_proof:claim.proof});message(completed.message);assignment.status='ACTIVE';form.hidden=true;
   }
  }catch(e){message(e.message||'تعذر الاتصال. أعد المحاولة.');}finally{el('employeeAdminPassword').value='';await authClient.auth.signOut({scope:'local'}).catch(()=>{});busy=false;form.querySelectorAll('button').forEach(b=>b.disabled=false);}
 }
 el('employeeAdminForm').onsubmit=e=>{e.preventDefault();run(true);};el('employeeAdminActivate').onclick=()=>run(false);
})();
