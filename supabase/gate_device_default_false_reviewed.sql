-- Pending owner review before Production application. Existing rows unchanged.
ALTER TABLE public.gate_devices ALTER COLUMN is_active SET DEFAULT false;
