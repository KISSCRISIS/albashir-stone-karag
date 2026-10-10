-- Owner explicitly approved this feature on Staging only, 2026-10-10.
create table private.employee_admin_assignments (
 id uuid primary key default gen_random_uuid(), registration_id uuid not null unique references public.employee_registrations(id),
 role text not null check(role in ('SUPER_ADMIN','SUB_ADMIN')), permissions jsonb not null,
 assigned_by uuid not null, status text not null default 'PENDING' check(status in ('PENDING','ACTIVE','REVOKED')),
 auth_user_id uuid unique, created_at timestamptz not null default now(), activated_at timestamptz, revoked_at timestamptz
);
create table private.employee_admin_proofs (
 token_hash text primary key, assignment_id uuid not null references private.employee_admin_assignments(id) on delete cascade,
 email text not null, created_at timestamptz not null default now(), expires_at timestamptz not null, consumed_at timestamptz
);
create index employee_admin_proofs_assignment on private.employee_admin_proofs(assignment_id,created_at);
alter table private.employee_admin_assignments enable row level security;
alter table private.employee_admin_proofs enable row level security;
revoke all on private.employee_admin_assignments,private.employee_admin_proofs from public,anon,authenticated;

create function public.super_admin_assign_employee(p_registration_id uuid,p_role text,p_permissions jsonb) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,private,extensions as $$
declare a private.employee_admin_assignments; r public.employee_registrations;
begin
 if not public.is_super_admin() then return jsonb_build_object('ok',false,'message','هذه العملية للمشرف الرئيسي فقط.'); end if;
 if p_role is null or p_role not in ('SUPER_ADMIN','SUB_ADMIN') or jsonb_typeof(p_permissions) is distinct from 'object' then return jsonb_build_object('ok',false,'message','الدور والصلاحيات غير صحيحين.'); end if;
 if exists(select 1 from jsonb_each(p_permissions) e where jsonb_typeof(e.value)<>'boolean' or e.key not in ('can_approve_requests','can_review_violations','can_view_logs','can_export_csv','can_manage_limits','can_view_audit')) then return jsonb_build_object('ok',false,'message','صلاحية غير معروفة.'); end if;
 perform pg_advisory_xact_lock(8101009);
 select * into r from public.employee_registrations where id=p_registration_id for update;
 if r.id is null or r.status<>'APPROVED' then return jsonb_build_object('ok',false,'message','اختر موظفًا معتمدًا فقط.'); end if;
 select * into a from private.employee_admin_assignments where registration_id=r.id for update;
 if a.status='ACTIVE' then return jsonb_build_object('ok',false,'message','حساب الموظف مفعّل؛ عدّل صلاحياته من قائمة المشرفين الحاليين.'); end if;
 insert into private.employee_admin_assignments(registration_id,role,permissions,assigned_by) values(r.id,p_role,p_permissions,auth.uid())
 on conflict(registration_id) do update set role=excluded.role,permissions=excluded.permissions,assigned_by=excluded.assigned_by,status='PENDING',activated_at=null,revoked_at=null returning * into a;
 delete from private.employee_admin_proofs where assignment_id=a.id;
 insert into public.admin_audit_logs(admin_auth_user_id,action,target_table,target_id,details) values(auth.uid(),'APPOINT_EMPLOYEE_ADMIN','employee_admin_assignments',a.id::text,jsonb_build_object('registration_id',r.id,'role',p_role,'permissions',p_permissions));
 return jsonb_build_object('ok',true,'id',a.id,'message','تم تعيين الموظف؛ سيظهر له طلب إكمال حساب الإدارة في ملفه الشخصي.');
end $$;

create function public.super_admin_employee_assignments() returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private as $$
begin
 if not public.is_super_admin() then return jsonb_build_object('ok',false,'message','غير مصرح.'); end if;
 return jsonb_build_object('ok',true,'assignments',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'registration_id',r.id,'employee_id',r.employee_id,'full_name',r.full_name,'role',a.role,'permissions',a.permissions,'status',a.status,'employee_status',r.status,'created_at',a.created_at,'activated_at',a.activated_at) order by a.created_at desc) from private.employee_admin_assignments a join public.employee_registrations r on r.id=a.registration_id),'[]'::jsonb));
end $$;

create function public.super_admin_revoke_employee_assignment(p_id uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a private.employee_admin_assignments;
begin
 if not public.is_super_admin() then return jsonb_build_object('ok',false,'message','غير مصرح.'); end if;
 -- Serialize owner-affecting revocations; never disable the caller or last owner.
 perform pg_advisory_xact_lock(8101009);
 select * into a from private.employee_admin_assignments where id=p_id for update;
 if a.id is null then return jsonb_build_object('ok',false,'message','التعيين غير موجود.'); end if;
 if a.status='ACTIVE' and (a.auth_user_id=auth.uid() or (exists(select 1 from public.admin_profiles where auth_user_id=a.auth_user_id and role='SUPER_ADMIN' and is_active) and (select count(*) from public.admin_profiles where role='SUPER_ADMIN' and is_active)<=1)) then return jsonb_build_object('ok',false,'message','لا يمكن تعطيل حسابك أو آخر مشرف رئيسي.'); end if;
 if a.status='ACTIVE' then update public.admin_profiles set is_active=false where auth_user_id=a.auth_user_id; end if;
 update private.employee_admin_assignments set status='REVOKED',revoked_at=now() where id=a.id;
 delete from private.employee_admin_proofs where assignment_id=a.id;
 insert into public.admin_audit_logs(admin_auth_user_id,action,target_table,target_id,details) values(auth.uid(),'REVOKE_EMPLOYEE_ADMIN','employee_admin_assignments',a.id::text,'{}');
 return jsonb_build_object('ok',true,'message','تم إلغاء التعيين وتعطيل حساب الإدارة إن كان مفعّلًا.');
end $$;

create function public.employee_admin_assignment(p_employee_id text,p_mobile_number text) returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare identity jsonb; a private.employee_admin_assignments;
begin
 identity:=public.employee_profile_login(p_employee_id,p_mobile_number);
 if identity->>'ok'<>'true' then return jsonb_build_object('ok',false,'message','تعذر التحقق من هوية الموظف.'); end if;
 if identity->'profile'->>'status'<>'APPROVED' then return jsonb_build_object('ok',true,'assignment',null); end if;
 select * into a from private.employee_admin_assignments where registration_id=(identity->'profile'->>'id')::uuid and status in ('PENDING','ACTIVE');
 return jsonb_build_object('ok',true,'assignment',case when a.id is null then null else jsonb_build_object('id',a.id,'role',a.role,'status',a.status,'permissions',a.permissions) end);
end $$;

create function public.employee_admin_claim(p_id uuid,p_employee_id text,p_mobile_number text,p_email text) returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private,extensions as $$
declare identity jsonb; a private.employee_admin_assignments; proof text; email text:=lower(trim(p_email));
begin
 identity:=public.employee_profile_login(p_employee_id,p_mobile_number);
 if identity->>'ok'<>'true' or identity->'profile'->>'status'<>'APPROVED' then return jsonb_build_object('ok',false,'message','تعذر التحقق من موظف معتمد.'); end if;
 perform pg_advisory_xact_lock(8101009);
 select * into a from private.employee_admin_assignments where id=p_id and registration_id=(identity->'profile'->>'id')::uuid for update;
 if a.id is null or a.status<>'PENDING' then return jsonb_build_object('ok',false,'message','التعيين غير متاح للإكمال.'); end if;
 if email is null or length(email)>254 or email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then return jsonb_build_object('ok',false,'message','أدخل بريدًا صحيحًا.'); end if;
 delete from private.employee_admin_proofs where expires_at<now()-interval '1 day';
 if (select count(*) from private.employee_admin_proofs where assignment_id=a.id and created_at>now()-interval '10 minutes')>=5 then return jsonb_build_object('ok',false,'message','انتظر عشر دقائق قبل إعادة المحاولة.'); end if;
 proof:=encode(extensions.gen_random_bytes(32),'hex');
 insert into private.employee_admin_proofs(token_hash,assignment_id,email,expires_at) values(encode(extensions.digest(proof,'sha256'),'hex'),a.id,email,now()+interval '10 minutes');
 return jsonb_build_object('ok',true,'proof',proof,'expires_at',now()+interval '10 minutes');
end $$;

create function public.employee_admin_complete(p_proof text) returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private,extensions as $$
declare proof private.employee_admin_proofs; a private.employee_admin_assignments; r public.employee_registrations; mail text; confirmed timestamptz;
begin
 if auth.uid() is null then return jsonb_build_object('ok',false,'message','سجّل الدخول ببريدك المؤكد أولًا.'); end if;
 select lower(email),email_confirmed_at into mail,confirmed from auth.users where id=auth.uid();
 if confirmed is null then return jsonb_build_object('ok',false,'message','يجب تأكيد البريد أولًا.'); end if;
 perform pg_advisory_xact_lock(8101009);
 select * into proof from private.employee_admin_proofs where token_hash=encode(extensions.digest(coalesce(p_proof,''),'sha256'),'hex') for update;
 if proof.token_hash is null or proof.email is distinct from mail or proof.expires_at<now() then return jsonb_build_object('ok',false,'message','إثبات الإكمال غير صالح؛ أعد فتح الملف الشخصي.'); end if;
 select * into a from private.employee_admin_assignments where id=proof.assignment_id for update;
 if a.status='ACTIVE' and a.auth_user_id=auth.uid() then return jsonb_build_object('ok',true,'message','حساب الإدارة مفعّل بالفعل.'); end if;
 if a.status<>'PENDING' or proof.consumed_at is not null then return jsonb_build_object('ok',false,'message','التعيين غير متاح.'); end if;
 select * into r from public.employee_registrations where id=a.registration_id for update;
 if r.status<>'APPROVED' or not exists(select 1 from public.admin_profiles where auth_user_id=a.assigned_by and role='SUPER_ADMIN' and is_active) then return jsonb_build_object('ok',false,'message','التعيين أو اعتماد الموظف لم يعد صالحًا.'); end if;
 if (a.auth_user_id is not null and a.auth_user_id<>auth.uid()) or exists(select 1 from public.admin_profiles where (auth_user_id=auth.uid() or lower(email)=mail) and (a.auth_user_id is null or auth_user_id<>a.auth_user_id)) then return jsonb_build_object('ok',false,'message','البريد مرتبط بحساب إدارة موجود؛ راجع المشرف الرئيسي.'); end if;
 insert into public.admin_profiles(auth_user_id,email,full_name,phone_number,role,is_active,permissions) values(auth.uid(),mail,r.full_name,r.mobile_number,a.role,true,a.permissions) on conflict(auth_user_id) do update set full_name=excluded.full_name,phone_number=excluded.phone_number,role=excluded.role,is_active=true,permissions=excluded.permissions;
 update private.employee_admin_assignments set status='ACTIVE',auth_user_id=auth.uid(),activated_at=now() where id=a.id;
 update private.employee_admin_proofs set consumed_at=now() where assignment_id=a.id;
 insert into public.admin_audit_logs(admin_auth_user_id,action,target_table,target_id,details) values(auth.uid(),'ACTIVATE_EMPLOYEE_ADMIN','employee_admin_assignments',a.id::text,jsonb_build_object('assigned_by',a.assigned_by,'role',a.role));
 return jsonb_build_object('ok',true,'message','تم تفعيل حساب الإدارة بالصلاحيات التي حددها المشرف الرئيسي.');
end $$;

revoke all on function public.super_admin_assign_employee(uuid,text,jsonb),public.super_admin_employee_assignments(),public.super_admin_revoke_employee_assignment(uuid),public.employee_admin_assignment(text,text),public.employee_admin_claim(uuid,text,text,text),public.employee_admin_complete(text) from public,anon,authenticated;
grant execute on function public.super_admin_assign_employee(uuid,text,jsonb),public.super_admin_employee_assignments(),public.super_admin_revoke_employee_assignment(uuid),public.employee_admin_complete(text) to authenticated;
grant execute on function public.employee_admin_assignment(text,text),public.employee_admin_claim(uuid,text,text,text) to anon,authenticated;
