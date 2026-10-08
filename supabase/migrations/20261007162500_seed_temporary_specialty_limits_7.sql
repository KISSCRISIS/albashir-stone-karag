-- Default temporary/external specialty limits.
-- Owner decision: start all registration-page temporary specialties at 7/day.
-- Administrators may change the limit or active state later from the admin dashboard.

insert into public.specialty_daily_limits (specialty_name, daily_limit, is_active)
values
  ('جراحة عامة', 7, true),
  ('باطني', 7, true),
  ('أطفال', 7, true),
  ('ENT', 7, true),
  ('نسائية', 7, true),
  ('مسالك بولية', 7, true),
  ('عيون', 7, true),
  ('جراحة دماغ وأعصاب', 7, true),
  ('تخدير', 7, true),
  ('جراحة أوعية دموية', 7, true),
  ('أشعة', 7, true),
  ('مختبرات', 7, true),
  ('صيانة', 7, true),
  ('إدارة', 7, true),
  ('أمن', 7, true),
  ('أخرى', 7, true)
on conflict (specialty_name) do update
set daily_limit = excluded.daily_limit,
    is_active = excluded.is_active,
    updated_at = now();
