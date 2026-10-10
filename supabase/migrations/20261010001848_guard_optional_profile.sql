-- Owner requested: national ID only login; optional private guard profile.
alter table private.guard_accounts drop constraint guard_accounts_full_name_check;
alter table private.guard_accounts add constraint guard_accounts_full_name_check check(length(full_name)=0 or length(full_name) between 2 and 100);
drop index private.guard_accounts_name_unique;
create or replace function public.admin_save_guard(p_guard_id uuid,p_full_name text,p_national_id text,p_phone text,p_is_active boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private,extensions as $$
declare g_id uuid; phone text:=private.guard_normalize_phone(p_phone); name text:=trim(coalesce(p_full_name,'')); national text:=translate(trim(p_national_id),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789');
begin
  if not public.is_super_admin() then return jsonb_build_object('ok',false,'message','هذه العملية للسوبر أدمن فقط'); end if;
  if length(name)>100 or length(name)=1 or national is null or national !~ '^[0-9]{6,20}$'
     or p_is_active is null or (phone<>'' and phone !~ '^[0-9]{8,15}$') or (p_guard_id is null and phone='') then
    return jsonb_build_object('ok',false,'message','تحقق من الرقم الوطني ورقم الهاتف؛ الاسم اختياري');
  end if;
  if p_guard_id is null then
    insert into private.guard_accounts(full_name,national_id,phone_hash,phone_hint,is_active)
    values(name,national,extensions.crypt(phone,extensions.gen_salt('bf',10)),right(phone,4),p_is_active) returning id into g_id;
  else
    update private.guard_accounts set full_name=name,national_id=national,is_active=p_is_active,
      phone_hash=case when phone='' then phone_hash else extensions.crypt(phone,extensions.gen_salt('bf',10)) end,
      phone_hint=case when phone='' then phone_hint else right(phone,4) end
    where id=p_guard_id returning id into g_id;
    if g_id is null then return jsonb_build_object('ok',false,'message','ملف الحارس غير موجود'); end if;
    -- Editing identity, phone or status revokes all existing sessions immediately.
    delete from private.guard_sessions where guard_id=g_id;
  end if;
  insert into public.admin_audit_logs(admin_auth_user_id,action,target_table,target_id,details)
  values(auth.uid(),'SAVE_GUARD_ACCOUNT','guard_accounts',g_id::text,jsonb_build_object('is_active',p_is_active));
  return jsonb_build_object('ok',true,'message','تم حفظ ملف الحارس');
exception when unique_violation then
  return jsonb_build_object('ok',false,'message','الرقم الوطني مستخدم لحارس آخر');
end; $$;
revoke all on function public.admin_save_guard(uuid,text,text,text,boolean) from public,anon;
grant execute on function public.admin_save_guard(uuid,text,text,text,boolean) to authenticated;

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
  token:=encode(extensions.gen_random_bytes(32),'hex');
  delete from private.guard_sessions where guard_id=g.id;
  insert into private.guard_sessions(token_hash,guard_id,expires_at) values(encode(extensions.digest(token,'sha256'),'hex'),g.id,expiry);
  return jsonb_build_object('ok',true,'token',token,'expires_at',expiry,'full_name',g.full_name,
    'emergency_enabled',(select enabled from private.guard_emergency_settings));
end; $$;
revoke all on function public.guard_login(text,text) from public;
grant execute on function public.guard_login(text,text) to anon,authenticated;

create table private.guard_profiles (
 guard_id uuid primary key references private.guard_accounts(id) on delete cascade,
 age integer check(age between 16 and 100), residence text not null default '' check(length(residence)<=200),
 about text not null default '' check(length(about)<=1000), photo bytea,
 updated_at timestamptz not null default now(),
 check(photo is null or (octet_length(photo) between 4 and 196608 and encode(substring(photo from 1 for 3),'hex')='ffd8ff'))
);
alter table private.guard_profiles enable row level security;
revoke all on private.guard_profiles from public,anon,authenticated;

create function public.guard_get_profile(p_token text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,private,public as $$
declare gid uuid:=private.guard_session_id(p_token); g private.guard_accounts%rowtype; p private.guard_profiles%rowtype;
begin
 if gid is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
 select * into g from private.guard_accounts where id=gid;
 select * into p from private.guard_profiles where guard_id=gid;
 return jsonb_build_object('ok',true,'profile',jsonb_build_object('full_name',g.full_name,'national_id',g.national_id,
 'age',p.age,'residence',coalesce(p.residence,''),'about',coalesce(p.about,''),
 'photo_base64',case when p.photo is null then null else encode(p.photo,'base64') end));
end; $$;
revoke all on function public.guard_get_profile(text) from public;
grant execute on function public.guard_get_profile(text) to anon,authenticated;

create function public.guard_save_profile(p_token text,p_profile jsonb) returns jsonb
language plpgsql security definer set search_path=pg_catalog,private,public as $$
declare gid uuid:=private.guard_session_id(p_token); n text; a integer; r text; b text; picture bytea;
begin
 if gid is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
 perform 1 from private.guard_accounts where id=gid for update;
 if private.guard_session_id(p_token) is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
 if p_profile is null or jsonb_typeof(p_profile)<>'object' then return jsonb_build_object('ok',false,'message','بيانات غير صحيحة'); end if;
 n:=trim(coalesce(p_profile->>'full_name','')); r:=trim(coalesce(p_profile->>'residence','')); b:=trim(coalesce(p_profile->>'about',''));
 if length(n)>100 or length(n)=1 or length(r)>200 or length(b)>1000 then return jsonb_build_object('ok',false,'message','تحقق من طول المعلومات المدخلة'); end if;
 if nullif(p_profile->>'age','') is not null then
  if (p_profile->>'age') !~ '^[0-9]{2,3}$' then return jsonb_build_object('ok',false,'message','أدخل عمرًا صحيحًا أو اتركه فارغًا'); end if;
  a:=(p_profile->>'age')::integer;
  if a not between 16 and 100 then return jsonb_build_object('ok',false,'message','العمر بين 16 و100 سنة'); end if;
 end if;
 if p_profile ? 'photo_base64' then
  if length(coalesce(p_profile->>'photo_base64',''))>262144 then return jsonb_build_object('ok',false,'message','الصورة كبيرة؛ اختر صورة أصغر'); end if;
  picture:=decode(coalesce(p_profile->>'photo_base64',''),'base64');
  if octet_length(picture) not between 4 and 196608 or encode(substring(picture from 1 for 3),'hex')<>'ffd8ff' then
   return jsonb_build_object('ok',false,'message','الصورة غير صالحة');
  end if;
 end if;
 insert into private.guard_profiles(guard_id,age,residence,about,photo)
 values(gid,a,r,b,picture)
 on conflict(guard_id) do update set age=excluded.age,residence=excluded.residence,about=excluded.about,
 photo=case when p_profile->>'remove_photo'='true' then null when p_profile ? 'photo_base64' then excluded.photo else guard_profiles.photo end,updated_at=now();
 update private.guard_accounts set full_name=n where id=gid;
 insert into public.admin_audit_logs(action,target_table,target_id,details)
 values('GUARD_UPDATE_OWN_PROFILE','guard_profiles',gid::text,jsonb_build_object('photo_changed',p_profile ? 'photo_base64' or p_profile->>'remove_photo'='true'));
 return jsonb_build_object('ok',true,'message','تم حفظ صفحتك الشخصية');
exception when invalid_parameter_value or data_exception then
 return jsonb_build_object('ok',false,'message','بيانات الصورة غير صالحة');
end; $$;
revoke all on function public.guard_save_profile(text,jsonb) from public;
grant execute on function public.guard_save_profile(text,jsonb) to anon,authenticated;
