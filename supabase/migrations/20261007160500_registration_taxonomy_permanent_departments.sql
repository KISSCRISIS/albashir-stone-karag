-- Owner-approved registration taxonomy for permanent hospital employees.
-- Permanent department values are treated as permanent gate access categories.
CREATE OR REPLACE FUNCTION public.is_permanently_allowed_specialty(p_specialty text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'pg_catalog'
AS $function$
declare
  v text;
begin
  v := public.normalize_specialty_name(p_specialty);
  return v in (
    public.normalize_specialty_name('الإسعاف والطوارئ (DRS/NRS/EMT/MLT)'),
    public.normalize_specialty_name('أطباء امتياز'),
    public.normalize_specialty_name('ممرضو رعاية حثيثة (ICU)'),
    public.normalize_specialty_name('فنيو أشعة وتصوير طبي'),
    public.normalize_specialty_name('فنيو مختبرات طبية'),
    public.normalize_specialty_name('صيادلة ومساعدو صيادلة'),
    public.normalize_specialty_name('مسعفون'),
    public.normalize_specialty_name('موظفو سجلات طبية واستعلامات'),
    public.normalize_specialty_name('موظفو محاسبة ودخول'),
    public.normalize_specialty_name('مدخلو بيانات'),
    public.normalize_specialty_name('كوادر أمن وحماية'),
    public.normalize_specialty_name('عمال خدمات ونظافة'),
    public.normalize_specialty_name('أخرى')
  );
end;
$function$;
