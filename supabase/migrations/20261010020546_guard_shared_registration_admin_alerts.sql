-- Owner approved Staging-only shared transition, optional requests and notifications.
alter table private.guard_accounts add column is_shared boolean not null default false;
create unique index guard_one_shared on private.guard_accounts(is_shared) where is_shared;
alter table private.guard_sessions add column created_at timestamptz not null default now();
create table private.guard_signins(id uuid primary key default gen_random_uuid(),guard_id uuid not null references private.guard_accounts(id) on delete cascade,is_shared boolean not null,created_at timestamptz not null default now());
create index guard_signins_recent on private.guard_signins(guard_id,created_at desc);
alter table private.guard_signins enable row level security;
revoke all on private.guard_signins from public,anon,authenticated;
create table private.guard_registration_requests(
 id uuid primary key default gen_random_uuid(),national_id text not null unique check(national_id ~ '^[0-9]{6,20}$'),
 phone_hash text not null,phone_hint text not null,full_name text not null default '',age integer check(age between 16 and 100),residence text not null default '',about text not null default '',photo bytea,
 status text not null default 'PENDING' check(status in ('PENDING','APPROVED','REJECTED')),
 submitted_by uuid not null references private.guard_accounts(id),request_id uuid not null unique,created_at timestamptz not null default now(),reviewed_at timestamptz,reviewed_by uuid,
 check(length(full_name)<=100 and length(full_name)<>1 and length(residence)<=200 and length(about)<=1000),
 check(photo is null or (octet_length(photo) between 4 and 196608 and encode(substring(photo from 1 for 3),'hex')='ffd8ff'))
);
create index guard_requests_pending on private.guard_registration_requests(status,created_at desc);
alter table private.guard_registration_requests enable row level security;
revoke all on private.guard_registration_requests from public,anon,authenticated;
create function public.admin_configure_shared_guard(p_phone text,p_enabled boolean default true) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,private,extensions as $$
declare gid uuid; phone text:=private.guard_normalize_phone(p_phone);
begin
 if not public.is_super_admin() then return jsonb_build_object('ok',false,'message','غير مصرح'); end if;
 if phone !~ '^[0-9]{8,15}$' or p_enabled is null then return jsonb_build_object('ok',false,'message','أدخل كلمة مرور رقمية من 8–15 رقمًا'); end if;
 select id into gid from private.guard_accounts where is_shared for update;
 if gid is null then
 insert into private.guard_accounts(full_name,national_id,phone_hash,phone_hint,is_active,is_shared) values('حساب الحراس الجماعي','7000000000',extensions.crypt(phone,extensions.gen_salt('bf',10)),right(phone,4),p_enabled,true) returning id into gid;
 else update private.guard_accounts set phone_hash=extensions.crypt(phone,extensions.gen_salt('bf',10)),phone_hint=right(phone,4),is_active=p_enabled where id=gid;delete from private.guard_sessions where guard_id=gid; end if;
 insert into public.admin_audit_logs(admin_auth_user_id,action,target_table,target_id,details) values(auth.uid(),'CONFIGURE_SHARED_GUARD','guard_accounts',gid::text,jsonb_build_object('enabled',p_enabled));
 return jsonb_build_object('ok',true,'national_id','7000000000','message','تم تحديث الحساب الجماعي');
 exception when unique_violation then return jsonb_build_object('ok',false,'message','معرف الحساب الجماعي مستخدم؛ راجع مسؤول النظام');
end;$$;
revoke all on function public.admin_configure_shared_guard(text,boolean) from public,anon;grant execute on function public.admin_configure_shared_guard(text,boolean) to authenticated;
create function public.guard_session_profile(p_token text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,private,extensions as $$
declare gid uuid:=private.guard_session_id(p_token);
begin
 if gid is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
 return (select jsonb_build_object('ok',true,'is_shared',g.is_shared,'full_name',g.full_name,'photo_base64',case when g.is_shared or p.photo is null then null else encode(p.photo,'base64') end,'logged_in_at',s.created_at,'emergency_enabled',(select enabled from private.guard_emergency_settings)) from private.guard_accounts g left join private.guard_profiles p on p.guard_id=g.id join private.guard_sessions s on s.guard_id=g.id and s.token_hash=encode(extensions.digest(p_token,'sha256'),'hex') where g.id=gid);
end;$$;
revoke all on function public.guard_session_profile(text) from public;grant execute on function public.guard_session_profile(text) to anon,authenticated;
alter function public.guard_save_profile(text,jsonb) rename to guard_save_profile_personal;
alter function public.guard_save_profile_personal(text,jsonb) set schema private;
revoke all on function private.guard_save_profile_personal(text,jsonb) from public,anon,authenticated;
create function public.guard_save_profile(p_token text,p_profile jsonb) returns jsonb language plpgsql security definer set search_path=pg_catalog,private,public as $$
declare gid uuid:=private.guard_session_id(p_token);
begin
 if gid is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
 if (select is_shared from private.guard_accounts where id=gid) then return jsonb_build_object('ok',false,'message','الحساب الجماعي لا يملك ملفًا شخصيًا؛ أرسل طلب حساب مستقل اختياريًا'); end if;
 return private.guard_save_profile_personal(p_token,p_profile);
end;$$;
revoke all on function public.guard_save_profile(text,jsonb) from public;grant execute on function public.guard_save_profile(text,jsonb) to anon,authenticated;
create function public.guard_submit_registration(p_token text,p_request_id uuid,p_national_id text,p_phone text,p_profile jsonb) returns jsonb
language plpgsql security definer set search_path=pg_catalog,private,public,extensions as $$
declare gid uuid:=private.guard_session_id(p_token);nid text:=translate(trim(p_national_id),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789');phone text:=private.guard_normalize_phone(p_phone);n text:=trim(coalesce(p_profile->>'full_name',''));a integer;r text:=trim(coalesce(p_profile->>'residence',''));b text:=trim(coalesce(p_profile->>'about',''));picture bytea;prior private.guard_registration_requests%rowtype;rid uuid;
begin
 if gid is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
 perform 1 from private.guard_accounts where id=gid and is_shared for share;
 if not found or private.guard_session_id(p_token) is null then return jsonb_build_object('ok',false,'message','الطلب متاح من الحساب الجماعي الفعال فقط'); end if;
 if p_request_id is null or nid is null or nid !~ '^[0-9]{6,20}$' or phone !~ '^[0-9]{8,15}$' or p_profile is null or jsonb_typeof(p_profile)<>'object' or length(n)>100 or length(n)=1 or length(r)>200 or length(b)>1000 then return jsonb_build_object('ok',false,'message','تحقق من الرقم الوطني والهاتف والمعلومات'); end if;
 perform pg_advisory_xact_lock(hashtextextended(nid,61010));
 select * into prior from private.guard_registration_requests where request_id=p_request_id;
 if prior.id is not null then
 if prior.national_id=nid and prior.submitted_by=gid then return jsonb_build_object('ok',true,'message','تم إرسال الطلب سابقًا للموافقة');end if;
 return jsonb_build_object('ok',false,'message','أعد تحميل الصفحة لإرسال طلب جديد');end if;
 if exists(select 1 from private.guard_accounts where national_id=nid) or exists(select 1 from private.guard_registration_requests where national_id=nid and status in ('PENDING','APPROVED')) then return jsonb_build_object('ok',false,'message','الرقم مسجل أو لديه طلب قائم؛ راجع الإدارة'); end if;
 if (select count(*) from private.guard_registration_requests where submitted_by=gid and created_at>now()-interval '1 hour')>=30 then return jsonb_build_object('ok',false,'message','طلبات كثيرة؛ أعد المحاولة لاحقًا'); end if;
 if nullif(p_profile->>'age','') is not null then if p_profile->>'age' !~ '^[0-9]{2,3}$' then return jsonb_build_object('ok',false,'message','العمر غير صحيح');end if;a:=(p_profile->>'age')::integer;if a not between 16 and 100 then return jsonb_build_object('ok',false,'message','العمر بين 16 و100');end if;end if;
 if p_profile ? 'photo_base64' then if length(p_profile->>'photo_base64')>262144 then return jsonb_build_object('ok',false,'message','الصورة كبيرة');end if;picture:=decode(p_profile->>'photo_base64','base64');if octet_length(picture) not between 4 and 196608 or encode(substring(picture from 1 for 3),'hex')<>'ffd8ff' then return jsonb_build_object('ok',false,'message','الصورة غير صالحة');end if;end if;
 insert into private.guard_registration_requests(national_id,phone_hash,phone_hint,full_name,age,residence,about,photo,submitted_by,request_id) values(nid,extensions.crypt(phone,extensions.gen_salt('bf',10)),right(phone,4),n,a,r,b,picture,gid,p_request_id)
 on conflict(national_id) do update set phone_hash=excluded.phone_hash,phone_hint=excluded.phone_hint,full_name=excluded.full_name,age=excluded.age,residence=excluded.residence,about=excluded.about,photo=excluded.photo,status='PENDING',request_id=excluded.request_id,created_at=now(),reviewed_at=null,reviewed_by=null returning id into rid;
 insert into public.admin_audit_logs(action,target_table,target_id,details) values('GUARD_REGISTRATION_REQUEST','guard_registration_requests',rid::text,'{}');
 return jsonb_build_object('ok',true,'message','تم إرسال طلب حسابك للموافقة. يمكنك الاستمرار بالحساب الجماعي');
 exception when data_exception then return jsonb_build_object('ok',false,'message','بيانات الصورة أو العمر غير صالحة');
end;$$;
revoke all on function public.guard_submit_registration(text,uuid,text,text,jsonb) from public;grant execute on function public.guard_submit_registration(text,uuid,text,text,jsonb) to anon,authenticated;
create function public.admin_guard_requests() returns jsonb language plpgsql security definer set search_path=pg_catalog,private,public as $$
begin
 if not public.is_super_admin() then return jsonb_build_object('ok',false,'message','غير مصرح');end if;
 return jsonb_build_object('ok',true,'requests',coalesce((select jsonb_agg(jsonb_build_object('id',id,'national_id',national_id,'phone_hint',phone_hint,'full_name',full_name,'age',age,'residence',residence,'about',about,'photo_base64',case when photo is null then null else encode(photo,'base64') end,'status',status,'created_at',created_at) order by created_at desc) from (select * from private.guard_registration_requests order by created_at desc limit 100) r),'[]'::jsonb),'signins',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'full_name',g.full_name,'is_shared',s.is_shared,'created_at',s.created_at) order by s.created_at desc) from (select * from private.guard_signins order by created_at desc limit 100) s join private.guard_accounts g on g.id=s.guard_id),'[]'::jsonb));
end;$$;
revoke all on function public.admin_guard_requests() from public,anon;grant execute on function public.admin_guard_requests() to authenticated;
create function public.admin_review_guard_request(p_id uuid,p_approve boolean) returns jsonb language plpgsql security definer set search_path=pg_catalog,private,public as $$
declare r private.guard_registration_requests%rowtype;gid uuid;
begin
 if not public.is_super_admin() or p_approve is null then return jsonb_build_object('ok',false,'message','غير مصرح');end if;
 select * into r from private.guard_registration_requests where id=p_id for update;
 if r.id is null or r.status<>'PENDING' then return jsonb_build_object('ok',false,'message','تمت مراجعة الطلب أو لم يعد موجودًا');end if;
 if p_approve then
 insert into private.guard_accounts(full_name,national_id,phone_hash,phone_hint,is_active) values(r.full_name,r.national_id,r.phone_hash,r.phone_hint,true) returning id into gid;
 insert into private.guard_profiles(guard_id,age,residence,about,photo) values(gid,r.age,r.residence,r.about,r.photo);
 end if;
 update private.guard_registration_requests set status=case when p_approve then 'APPROVED' else 'REJECTED' end,reviewed_at=now(),reviewed_by=auth.uid() where id=p_id;
 insert into public.admin_audit_logs(admin_auth_user_id,action,target_table,target_id,details) values(auth.uid(),'REVIEW_GUARD_REQUEST','guard_registration_requests',p_id::text,jsonb_build_object('approved',p_approve));
 return jsonb_build_object('ok',true,'message',case when p_approve then 'تم اعتماد حساب الحارس الشخصي' else 'تم رفض الطلب' end);
 exception when unique_violation then return jsonb_build_object('ok',false,'message','الرقم مسجل؛ لم تتغير حالة الطلب');
end;$$;
revoke all on function public.admin_review_guard_request(uuid,boolean) from public,anon;grant execute on function public.admin_review_guard_request(uuid,boolean) to authenticated;
create or replace function public.guard_login(p_identity text,p_phone text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,private,extensions as $$
declare g private.guard_accounts%rowtype; identity text:=translate(lower(trim(coalesce(p_identity,''))),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789'); phone text:=private.guard_normalize_phone(p_phone);
  ih text; token text; expiry timestamptz:=now()+interval '24 hours';
begin
  if identity !~ '^[0-9]{6,20}$' or phone !~ '^[0-9]{8,15}$' then return jsonb_build_object('ok',false,'message','تحقق من الرقم الوطني ورقم الهاتف'); end if;
  perform pg_advisory_xact_lock(610100901);
  delete from private.guard_login_attempts where created_at<now()-interval '1 day';
  delete from private.guard_sessions where expires_at<=now();
  ih:=encode(extensions.digest(identity,'sha256'),'hex');
  if (select count(*) from private.guard_login_attempts where created_at>now()-interval '1 minute')>=120
     or (select count(*) from private.guard_login_attempts where identity_hash=ih and created_at>now()-interval '15 minutes')>=5 then
    return jsonb_build_object('ok',false,'message','محاولات كثيرة؛ انتظر 15 دقيقة ثم حاول مجددًا');
  end if;
  insert into private.guard_login_attempts(identity_hash) values(ih);
  select * into g from private.guard_accounts where national_id=identity for update;
  if g.id is null or not g.is_active then
    perform extensions.crypt(phone,extensions.gen_salt('bf',10));
    return jsonb_build_object('ok',false,'message','تحقق من الرقم الوطني ورقم الهاتف');
  end if;
  if extensions.crypt(phone,g.phone_hash)<>g.phone_hash then return jsonb_build_object('ok',false,'message','تحقق من الرقم الوطني ورقم الهاتف'); end if;
  if g.is_shared then delete from private.guard_login_attempts where identity_hash=ih; end if;
  token:=encode(extensions.gen_random_bytes(32),'hex');
  if not g.is_shared then delete from private.guard_sessions where guard_id=g.id; end if;
  insert into private.guard_sessions(token_hash,guard_id,expires_at) values(encode(extensions.digest(token,'sha256'),'hex'),g.id,expiry);
  insert into private.guard_signins(guard_id,is_shared) values(g.id,g.is_shared);
  return jsonb_build_object('is_shared',g.is_shared)||jsonb_build_object('ok',true,'token',token,'expires_at',expiry,'full_name',g.full_name,
    'emergency_enabled',(select enabled from private.guard_emergency_settings));
end; $$;
revoke all on function public.guard_login(text,text) from public;
grant execute on function public.guard_login(text,text) to anon,authenticated;

create table private.admin_notice_events(id uuid primary key default gen_random_uuid(),event_key text not null unique,topic text not null,title text not null,body text not null,target text not null,created_at timestamptz not null default now());
create index admin_notice_recent on private.admin_notice_events(created_at desc);
create table private.admin_notice_reads(admin_id uuid not null,event_id uuid not null references private.admin_notice_events(id) on delete cascade,primary key(admin_id,event_id));
create table private.admin_notice_devices(admin_id uuid not null,device_id uuid not null,label text not null default '',subscription jsonb,enabled boolean not null default true,last_seen_at timestamptz not null default now(),primary key(admin_id,device_id));
create table private.admin_notice_outbox(id uuid primary key default gen_random_uuid(),event_id uuid not null references private.admin_notice_events(id) on delete cascade,admin_id uuid not null,device_id uuid not null,attempts integer not null default 0,available_at timestamptz not null default now(),sent_at timestamptz,last_error text,unique(event_id,admin_id,device_id));
create table private.admin_notice_config(singleton boolean primary key default true check(singleton),enabled_at timestamptz not null default now(),vapid_public text,vapid_private text,dispatch_key_hash text);
insert into private.admin_notice_config(singleton) values(true);
alter table private.admin_notice_events enable row level security;alter table private.admin_notice_reads enable row level security;alter table private.admin_notice_devices enable row level security;alter table private.admin_notice_outbox enable row level security;alter table private.admin_notice_config enable row level security;
revoke all on private.admin_notice_events,private.admin_notice_reads,private.admin_notice_devices,private.admin_notice_outbox,private.admin_notice_config from public,anon,authenticated;
create function private.admin_notice_allowed(p_uid uuid,p_topic text) returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
 select coalesce((select is_active and (role='SUPER_ADMIN' or case p_topic when 'GUARD_REQUEST' then false when 'REGISTRATION' then coalesce((permissions->>'can_approve_requests')::boolean,false) when 'PROFILE_CHANGE' then coalesce((permissions->>'can_approve_requests')::boolean,false) when 'VIOLATION' then coalesce((permissions->>'can_review_violations')::boolean,false) when 'LIMIT' then coalesce((permissions->>'can_manage_limits')::boolean,false) when 'SHIFT' then coalesce((permissions->>'can_view_logs')::boolean,false) else false end) from public.admin_profiles where auth_user_id=p_uid),false);
$$;
revoke all on function private.admin_notice_allowed(uuid,text) from public,anon,authenticated;
create function private.add_admin_notice(p_key text,p_topic text,p_title text,p_body text,p_target text) returns void language plpgsql security definer set search_path=pg_catalog,private,public as $$
declare eid uuid;
begin
 insert into private.admin_notice_events(event_key,topic,title,body,target) values(p_key,p_topic,p_title,p_body,p_target) on conflict(event_key) do nothing returning id into eid;
 if eid is null then return;end if;
 insert into private.admin_notice_outbox(event_id,admin_id,device_id) select eid,d.admin_id,d.device_id from private.admin_notice_devices d where d.enabled and d.subscription is not null and private.admin_notice_allowed(d.admin_id,p_topic);
end;$$;
revoke all on function private.add_admin_notice(text,text,text,text,text) from public,anon,authenticated;
create function private.registration_notice_trigger() returns trigger language plpgsql security definer set search_path=pg_catalog,private,public as $$
begin
 if tg_table_name='guard_registration_requests' then
 if new.status='PENDING' then perform private.add_admin_notice('guard:'||new.id||':'||new.created_at,'GUARD_REQUEST','طلب حساب حارس جديد','وصل طلب اختياري لاعتماد حساب حارس.','guardRequests');end if;
 elsif tg_table_name='employee_registrations' then
 if new.status in ('PENDING','PENDING_FIRST_ENTRY','NEW') then perform private.add_admin_notice('employee:'||new.id||':'||new.created_at,'REGISTRATION','طلب تسجيل موظف جديد','يوجد طلب تسجيل بانتظار المراجعة.','registrations');end if;
 elsif tg_table_name='violation_reports' then
 perform private.add_admin_notice('violation:'||new.id,'VIOLATION','أمن الصخره وتبليغات التجاوزات','وصل بلاغ جديد للمراجعة.','violations');
 end if;
 return new;
end;$$;
revoke all on function private.registration_notice_trigger() from public,anon,authenticated;
create trigger guard_request_notice after insert or update of status on private.guard_registration_requests for each row execute function private.registration_notice_trigger();
create trigger employee_request_notice after insert on public.employee_registrations for each row execute function private.registration_notice_trigger();
create trigger violation_request_notice after insert on public.violation_reports for each row execute function private.registration_notice_trigger();
create function private.limit_notice_trigger() returns trigger language plpgsql security definer set search_path=pg_catalog,private,public as $$
declare lim integer;used integer;
begin
 if new.result<>'LIMITED' then return new;end if;
 select daily_limit into lim from public.specialty_daily_limits where specialty_name=new.specialty and is_active;
 if lim is null or lim<1 then return new;end if;
 select count(*) into used from public.gate_access_logs where specialty=new.specialty and result='LIMITED' and created_at>=date_trunc('day',now()) and created_at<date_trunc('day',now())+interval '1 day';
 if used>=lim then perform private.add_admin_notice('limit:'||new.specialty||':'||date_trunc('day',now()),'LIMIT','اكتمل الحد اليومي','الاختصاص: '||new.specialty||' — الحد: '||lim,'limits');end if;
 return new;
end;$$;
revoke all on function private.limit_notice_trigger() from public,anon,authenticated;
create trigger daily_limit_notice after insert on public.gate_access_logs for each row execute function private.limit_notice_trigger();
create function private.admin_notice_tick() returns void language plpgsql security definer set search_path=pg_catalog,private,public as $$
declare d date;h integer;end_at timestamptz;start_at timestamptz;stats text;label text;
begin
 for d in select generate_series((now() at time zone 'Asia/Amman')::date-1,(now() at time zone 'Asia/Amman')::date,interval '1 day')::date loop
 foreach h in array array[7,15,23] loop
 end_at:=(d+make_time(h,0,0)) at time zone 'Asia/Amman';start_at:=end_at-interval '8 hours';
 if end_at<=now() and end_at>=(select enabled_at from private.admin_notice_config) then
 label:=case h when 7 then 'C' when 15 then 'A' else 'B' end;
 select 'مسموح: '||count(*) filter(where result='ALLOWED')||'، مؤقت: '||count(*) filter(where result='LIMITED')||'، مرفوض: '||count(*) filter(where result='DENIED') into stats from public.gate_access_logs where created_at>=start_at and created_at<end_at;
 perform private.add_admin_notice('shift:'||end_at,'SHIFT','خلاصة نهاية الشفت '||label,stats,'logs');
 end if;
 end loop;end loop;
 delete from private.admin_notice_events where created_at<now()-interval '30 days';
 delete from private.guard_signins where created_at<now()-interval '90 days';
end;$$;
revoke all on function private.admin_notice_tick() from public,anon,authenticated;
create function public.admin_notice_feed() returns jsonb language plpgsql security definer set search_path=pg_catalog,private,public as $$
begin
 if not exists(select 1 from public.admin_profiles where auth_user_id=auth.uid() and is_active) then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED');end if;
 return jsonb_build_object('ok',true,'events',coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'title',e.title,'body',e.body,'topic',e.topic,'target',e.target,'created_at',e.created_at,'read',r.event_id is not null) order by e.created_at desc) from (select * from private.admin_notice_events where private.admin_notice_allowed(auth.uid(),topic) order by created_at desc limit 100) e left join private.admin_notice_reads r on r.event_id=e.id and r.admin_id=auth.uid()),'[]'::jsonb),'vapid_public',(select vapid_public from private.admin_notice_config));
end;$$;
revoke all on function public.admin_notice_feed() from public,anon;grant execute on function public.admin_notice_feed() to authenticated;
create function public.admin_notice_read(p_id uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog,private,public as $$
begin
 if not exists(select 1 from private.admin_notice_events where id=p_id and private.admin_notice_allowed(auth.uid(),topic)) then return jsonb_build_object('ok',false,'message','غير مصرح');end if;
 insert into private.admin_notice_reads(admin_id,event_id) values(auth.uid(),p_id) on conflict do nothing;return jsonb_build_object('ok',true);
end;$$;
revoke all on function public.admin_notice_read(uuid) from public,anon;grant execute on function public.admin_notice_read(uuid) to authenticated;
create function public.admin_notice_device(p_id uuid,p_label text,p_subscription jsonb,p_enabled boolean) returns jsonb language plpgsql security definer set search_path=pg_catalog,private,public as $$
begin
 if not exists(select 1 from public.admin_profiles where auth_user_id=auth.uid() and is_active) then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED');end if;
 if p_id is null or length(coalesce(p_label,''))>100 or p_enabled is null or (p_subscription is not null and (jsonb_typeof(p_subscription)<>'object' or length(p_subscription::text)>5000 or coalesce(p_subscription->>'endpoint','') !~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-zA-Z0-9-]+\.notify\.windows\.com)/' or coalesce(p_subscription#>>'{keys,p256dh}','') !~ '^[A-Za-z0-9_-]{80,100}$' or coalesce(p_subscription#>>'{keys,auth}','') !~ '^[A-Za-z0-9_-]{20,30}$')) then return jsonb_build_object('ok',false,'message','اشتراك الإشعارات غير صالح');end if;
 if (select count(*) from private.admin_notice_devices where admin_id=auth.uid())>=10 and not exists(select 1 from private.admin_notice_devices where admin_id=auth.uid() and device_id=p_id) then return jsonb_build_object('ok',false,'message','الحد عشرة أجهزة لكل مشرف؛ ألغِ جهازًا سابقًا');end if;
 insert into private.admin_notice_devices(admin_id,device_id,label,subscription,enabled) values(auth.uid(),p_id,coalesce(p_label,''),p_subscription,p_enabled) on conflict(admin_id,device_id) do update set label=excluded.label,subscription=excluded.subscription,enabled=excluded.enabled,last_seen_at=now();
 insert into public.admin_audit_logs(admin_auth_user_id,action,target_table,target_id,details) values(auth.uid(),'ADMIN_NOTICE_DEVICE','admin_notice_devices',p_id::text,jsonb_build_object('enabled',p_enabled));
 return jsonb_build_object('ok',true,'message','تم حفظ تفضيل إشعارات هذا الجهاز');
end;$$;
revoke all on function public.admin_notice_device(uuid,text,jsonb,boolean) from public,anon;grant execute on function public.admin_notice_device(uuid,text,jsonb,boolean) to authenticated;
create function public.admin_notice_claim(p_key text) returns jsonb language plpgsql security definer set search_path=pg_catalog,private,public,extensions as $$
declare jobs jsonb;
begin
 if p_key is null or length(p_key)<>64 or encode(extensions.digest(p_key,'sha256'),'hex') is distinct from (select dispatch_key_hash from private.admin_notice_config) then return jsonb_build_object('ok',false);end if;
 perform private.admin_notice_tick();
 with claim as (select o.id from private.admin_notice_outbox o join private.admin_notice_devices d on d.admin_id=o.admin_id and d.device_id=o.device_id join private.admin_notice_events e on e.id=o.event_id where o.sent_at is null and o.attempts<5 and o.available_at<=now() and d.enabled and d.subscription is not null and private.admin_notice_allowed(o.admin_id,e.topic) order by o.available_at limit 50 for update of o skip locked),updated as (update private.admin_notice_outbox o set attempts=attempts+1,available_at=now()+interval '5 minutes' from claim c where o.id=c.id returning o.*)
 select jsonb_agg(jsonb_build_object('id',o.id,'subscription',d.subscription,'title',e.title,'body',e.body,'event_id',e.id,'target',e.target)) into jobs from updated o join private.admin_notice_devices d on d.admin_id=o.admin_id and d.device_id=o.device_id join private.admin_notice_events e on e.id=o.event_id;
 return jsonb_build_object('ok',true,'jobs',coalesce(jobs,'[]'::jsonb),'vapid_public',(select vapid_public from private.admin_notice_config),'vapid_private',(select vapid_private from private.admin_notice_config));
end;$$;
revoke all on function public.admin_notice_claim(text) from public;grant execute on function public.admin_notice_claim(text) to anon,authenticated;
create function public.admin_notice_complete(p_key text,p_id uuid,p_status integer) returns jsonb language plpgsql security definer set search_path=pg_catalog,private,extensions as $$
begin
 if p_key is null or length(p_key)<>64 or encode(extensions.digest(p_key,'sha256'),'hex') is distinct from (select dispatch_key_hash from private.admin_notice_config) then return jsonb_build_object('ok',false);end if;
 update private.admin_notice_outbox set sent_at=case when p_status between 200 and 299 or p_status in (404,410) then now() else null end,last_error=case when p_status between 200 and 299 then null else p_status::text end where id=p_id;
 if p_status in (404,410) then update private.admin_notice_devices d set enabled=false,subscription=null from private.admin_notice_outbox o where o.id=p_id and d.admin_id=o.admin_id and d.device_id=o.device_id;end if;
 return jsonb_build_object('ok',true);
end;$$;
revoke all on function public.admin_notice_complete(text,uuid,integer) from public;grant execute on function public.admin_notice_complete(text,uuid,integer) to anon,authenticated;

alter table private.admin_notice_config add column dispatch_url text,add column publishable_key text;
create function private.admin_notice_dispatch() returns void language plpgsql security definer set search_path=pg_catalog,private as $$
declare cfg private.admin_notice_config%rowtype; credential text;
begin
 perform private.admin_notice_tick();
 select * into cfg from private.admin_notice_config;
 if cfg.dispatch_url is null or cfg.publishable_key is null then return;end if;
 select decrypted_secret into credential from vault.decrypted_secrets where name='admin_notice_dispatch_key';
 if credential is null then raise warning 'Notice dispatcher credential unavailable';return;end if;
 perform net.http_post(url:=cfg.dispatch_url,headers:=jsonb_build_object('Content-Type','application/json','apikey',cfg.publishable_key,'x-dispatch-key',credential),body:='{}'::jsonb,timeout_milliseconds:=60000);
end;$$;
revoke all on function private.admin_notice_dispatch() from public,anon,authenticated;
DO $$ BEGIN
 IF EXISTS(select 1 from pg_available_extensions where name='pg_cron') AND EXISTS(select 1 from pg_available_extensions where name='pg_net') THEN
 EXECUTE 'create extension if not exists pg_cron';EXECUTE 'create extension if not exists pg_net';
 PERFORM cron.schedule('admin-notice-dispatch','* * * * *','select private.admin_notice_dispatch()');
 END IF;
END $$;
