-- Follow-up within the owner-approved Staging transition.
-- Only database-owned scheduled jobs may use the network extension.
DO $$ BEGIN
 IF EXISTS(select 1 from pg_namespace where nspname='net') THEN
 EXECUTE 'revoke usage on schema net from public,anon,authenticated';
 EXECUTE 'revoke execute on all functions in schema net from public,anon,authenticated';
 END IF;
END $$;
create function private.profile_change_notice_trigger() returns trigger language plpgsql security definer set search_path=pg_catalog,private,public as $$
begin
 if new.status='PENDING' then perform private.add_admin_notice('profile:'||new.id||':'||new.created_at,'PROFILE_CHANGE','طلب تعديل بيانات جديد','وصل طلب تعديل بيانات موظف للمراجعة.','profileChanges');end if;
 return new;
end;$$;
revoke all on function private.profile_change_notice_trigger() from public,anon,authenticated;
create trigger profile_change_request_notice after insert on public.employee_data_change_requests for each row execute function private.profile_change_notice_trigger();
create function public.guard_set_emergency(p_token text,p_enabled boolean) returns jsonb language plpgsql security definer set search_path=pg_catalog,private,public as $$
declare gid uuid:=private.guard_session_id(p_token);
begin
 if gid is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED');end if;
 if p_enabled is null then return jsonb_build_object('ok',false,'message','اختيار غير صالح');end if;
 perform 1 from private.guard_accounts where id=gid for share;
 if private.guard_session_id(p_token) is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED');end if;
 update private.guard_emergency_settings set enabled=p_enabled;
 insert into public.admin_audit_logs(action,target_table,target_id,details) values('GUARD_SET_EMERGENCY','guard_emergency_settings','true',jsonb_build_object('guard_id',gid,'enabled',p_enabled));
 return jsonb_build_object('ok',true,'emergency_enabled',p_enabled,'message',case when p_enabled then 'تم تفعيل الدخول اليدوي للطوارئ؛ كل زيارة تسجل وتحتسب' else 'تم إيقاف الدخول اليدوي للطوارئ' end);
end;$$;
revoke all on function public.guard_set_emergency(text,boolean) from public;grant execute on function public.guard_set_emergency(text,boolean) to anon,authenticated;
