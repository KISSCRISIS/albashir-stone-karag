/* Reminder only; never establishes an admin role or changes employee routing. */
(() => {
 const employee=window.ALBASHIRAccess?.readSession();if(employee?.role!=='EMPLOYEE'||!employee.employeeId||!employee.mobileNumber)return;
 const config=typeof APP_CONFIG!=='undefined'?APP_CONFIG:null;if(!config||!window.supabase)return;
 const client=window.supabase.createClient(config.SUPABASE_URL,config.SUPABASE_ANON_KEY,{auth:{persistSession:false,detectSessionInUrl:false},global:{fetch:ALBASHIRRuntime.fetchWithTimeout}});
 client.rpc('employee_admin_assignment',{p_employee_id:employee.employeeId,p_mobile_number:employee.mobileNumber}).then(({data,error})=>{if(error||data?.ok!==true||data.assignment?.status!=='PENDING')return;const banner=document.createElement('aside');banner.className='notice';banner.setAttribute('role','status');const text=document.createElement('p');text.textContent='تم تعيينك مشرفًا. أكمل بيانات حساب الإدارة في ملفك الشخصي.';const link=document.createElement('a');link.href='./profile.html';link.textContent='إكمال حساب الإدارة';banner.append(text,link);document.querySelector('main')?.prepend(banner);}).catch(()=>{});
})();
