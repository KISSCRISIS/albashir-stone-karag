-- Owner-approved Staging upload compatibility correction, 2026-10-07.
-- Storage may supply contentLength rather than size during permission probes,
-- or omit length for multipart. Bucket limits enforce actual bytes independently.
-- No SELECT/UPDATE/DELETE access is added. Content authenticity is admin-reviewed.
DO $$ BEGIN
 IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id='employee-photos'
   AND public=false AND file_size_limit=2097152
   AND allowed_mime_types @> ARRAY['image/jpeg','image/png','image/webp']::text[]
   AND allowed_mime_types <@ ARRAY['image/jpeg','image/png','image/webp']::text[])
 THEN RAISE EXCEPTION 'Unexpected bucket baseline'; END IF;
END $$;
ALTER POLICY "Registration can upload employee photos" ON storage.objects
WITH CHECK (
 bucket_id='employee-photos'
 AND (storage.foldername(name))[1]='registrations'
 AND lower(storage.extension(name)) IN ('jpg','jpeg','png','webp')
 AND lower(coalesce(metadata->>'mimetype','')) IN ('image/jpeg','image/png','image/webp')
 AND ((metadata->>'size') IS NULL
      OR (metadata->>'size')::bigint BETWEEN 1 AND 2097152)
);
