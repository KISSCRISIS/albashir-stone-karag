CREATE OR REPLACE FUNCTION public.validate_and_use_qr_token(p_token text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  input_uuid uuid;
  consumed_id uuid;
begin
  begin
    input_uuid := nullif(trim(coalesce(p_token, '')), '')::uuid;
  exception when others then
    return false;
  end;

  update public.qr_sessions
  set used_at = now()
  where token = input_uuid
    and used_at is null
    and expires_at > now()
  returning id into consumed_id;

  if consumed_id is not null then
    return true;
  end if;

  update public.qr_sessions
  set claim_used_at = now()
  where claim_token = input_uuid
    and claim_used_at is null
    and claim_expires_at > now()
  returning id into consumed_id;

  return consumed_id is not null;
end;
$function$
;
