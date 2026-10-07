# Employee Photos — Staging execution results

Target: `adwvokwucotohwayorgx` only. Date: 2026-10-07.
Production was not modified. No rollback, blanket db push, or Trusted Device migration was run.

## Applied scope

- Reviewed fresh-install baseline: applied; 15 application tables have RLS, 53 function definitions matched isolated expected definitions.
- Synthetic fixtures only: two employees/images, gate/trusted credentials, synthetic admin.
- Reviewed private employee photos migration: applied.
- employee-photo-url: deployed ACTIVE v1 with pinned SDK and custom actor authorization.
- No hosted Staging frontend deployed: owner has no separate Vercel project.
- No new commit/push/PR/CI was performed in this execution.

## Acceptance evidence

| Check | Status | Evidence / limitation |
|---|---|---|
| Staging identity and repository privacy | PASS | Explicit staging identity; repository PRIVATE |
| Baseline DB/RPC/RLS/ACL | PASS | Checkpoint and 53 definition comparisons |
| Private bucket and backfill | PASS | employee-photos private; http references = 0 |
| Public URL to existing image | PASS | HTTP400 JSON NoSuchBucket, embedded404; no image bytes; same image readable signed |
| Signed URL before expiry | PASS | HTTP200, fixture bytes match, expires_in60 |
| Same original URL after expiry | PASS | HTTP400 InvalidJWT, exp claim timestamp check failed; elapsed374 seconds |
| Employee own image | PASS | Resolver200 |
| Employee IDOR | PASS | HTTP403 exact opaque DENIED |
| Anonymous / incorrect employee credentials | PASS | HTTP403 opaque denial |
| Gate actor | PASS | Valid gate200, invalid token403 |
| Trusted actor | PASS | Own200, other employee403 |
| Admin actor and cleanup dry-run | PASS | Real synthetic Auth session; resolve200; mode DRY_RUN, no deletion |
| Valid browser JPG1MiB upload | NOT RUN | Hosted frontend unavailable; API valid PNG already fails |
| Valid PNG at2MiB via Storage API | FAIL | HTTP400 embedded403 AccessDenied; new row violates row-level security policy |
| SVG and3MiB denial via Storage API | PASS | InvalidMimeType415 and EntityTooLarge413 respectively; browser picker not tested |
| Renamed MZ with forged image MIME | BLOCKED | Rejected by same RLS as valid images; content validation not established |
| Storage/CDN cache headers | FAIL | Cache-Control absent on tested signed GET; explicit non-shared caching guarantee not established |

The initial harness incorrectly matched only the word expired and expected dry_run:true. Its assertions now match the actual InvalidJWT expiry response and mode:DRY_RUN contract. The corrected results supersede those two initial FAIL classifications.

## Stop conditions / next review

The upload policy checks metadata MIME/size during INSERT. Actual Storage API rejects valid PNG with RLS. This establishes a compatibility defect; the precise Storage insertion lifecycle still needs confirmation before policy revision. Do not remove security checks blindly. Any proposed SQL adjustment must be separately reviewed, retain path/extension restrictions and bucket limits, and address server-side non-image rejection explicitly.

No additional migration/policy write was performed after this acceptance failure. Production remains blocked. Absence of Cache-Control is recorded as failure to meet the documented acceptance guarantee, not proof of a demonstrated shared-cache leak.

Next: review a scoped upload-policy/content-validation fix and cache behavior; rerun upload tests with actual decoded valid images and a separate Staging frontend. No real phone or camera testing is claimed.

Evidence is stored locally in redacted http-acceptance-results.json and http-followup-results.json. Synthetic credentials and signed URLs are excluded from this report and must never be committed.

## Follow-up diagnosis — 2026-10-07

Official Storage uploader source performs the permission probe with metadata.mimetype and metadata.contentLength, not the final metadata.size required by the current policy. A new isolated diagnostic test reproduces that mismatch for anon and authenticated. This is a diagnostic of the existing defect, not a passing upload acceptance result.

A complete fix must inspect/decode image content on the server before storing it and prevent bypass by direct Storage writes. Merely relaxing the policy restores upload but does not reject forged MIME. A scoped upload Edge Function, register.html caller, and removal of direct upload access are proposed; existing employee registration RPC and QR logic remain unchanged. Decoder choice must preserve JPG/PNG/WEBP support and enforce bounded dimensions/memory. Dependencies must be pinned. No implementation of that new route has occurred pending the owner's specific architecture choice.

Reference: https://raw.githubusercontent.com/supabase/storage/master/src/storage/uploader.ts

## Owner acceptance and upload fix — 2026-10-07

Content review is now ACCEPTED BY OWNER / ADMIN REVIEW, not deferred. There is no claim that forged non-image content is automatically rejected. The owner explicitly selected this scope; direct upload architecture is retained.

The scoped SQL correction was applied only to Staging. Valid PNG and PNG exactly2MiB now upload. SVG and3MiB fail with specific Storage validation errors. The cache option now requests max-age=0, no-store for new registration uploads. The signed endpoint still omits Cache-Control in observed responses even when object metadata requests no-store; therefore the provider-level no-store acceptance remains NOT ESTABLISHED. Client no-store/blob guarantees pass local regression tests. No hosted frontend or real-device acceptance is claimed.

The earlier upload FAIL and proposed server-upload route are superseded by this correction and owner choice. The initial MZ rejection was an RLS failure, not content validation; after correction, MZ is accepted, as allowed by the owner's administrative-review scope.

## Final scoped verification

- Actual binary and multipart uploads: JPG1MiB and PNG2MiB PASS; Chromium image.decode PASS after signed download.
- Corrected policy accepts missing final size during permission probe; Storage bucket remains responsible for real-byte limit. Multipart overhead is not mistaken for file size.
- Local npm test: PASS, including compatibility regression for both anon/authenticated and oversized final metadata denial.
- Content: ACCEPTED BY OWNER / ADMIN REVIEW; automated forged-content rejection was waived, not passed.
- Frontend no-store/blob regressions: PASS. Provider signed-response no-store header: NOT ESTABLISHED.
- Hosted frontend deployment: NOT RUN; no Vercel Staging project is available. Real device/camera: NOT RUN.
- Production: untouched. No commit/push/CI claim.

Fresh-install order: reviewed baseline -> private_employee_photos migration -> employee_photo_upload_compatibility_reviewed.sql -> resolver -> frontend. Do not rerun historical patches or use db push. The reviewed compatibility script represents the final predicate after the two scoped Staging revisions.

## Hosted Staging frontend — 2026-10-07

Deployed: https://albashir-staging.vercel.app
Project: kisscrisis-projects/albashir-staging (separate project, no Git main connection).
Deployment: dpl_B726Ff2LW34cC8bcwDC4jnnhkwto, READY.
Backend: adwvokwucotohwayorgx only. Runtime package:38 files; no SQL/tests/logs.
Live verification PASS: published pages/static config checked, zero Production requests,320/375/390/430 and568x320/844x390/1024x768 no registration-page horizontal overflow, synthetic photo resolve/download/blob decode and clearCache behavior.
No real-device or camera claim. Production app/database untouched. Owner administrative review remains accepted; CDN signed-response no-store header remains NOT ESTABLISHED and is not waived by frontend deployment.
Evidence: ALBASHIR_STAGING_LIVE_VERIFICATION.json in local workspace. Authentication files are outside the deploy package and must not be committed.

## Cache mitigation deployed — 2026-10-07

Resolver v2 returns Cache-Control:no-store, private; Pragma:no-cache; Expires:0. Live HTTP verified200 with those headers. Staging frontend deployment dpl_674muR6JkCL4iFz7HxwJiLqT3VPx adds a cryptographic unique cacheNonce for each signed-image download, following Supabase's documented origin-fetch/CDN bypass. no-store fetch, omitted credentials, no-referrer and blob display remain.

Original Storage endpoint Cache-Control remains outside app control; this is a verified client-path cache bypass mitigation, not a claim that Storage's response header changed. Real-device/camera testing is NOT RUN: requires an actual user-operated phone.

## User-performed real-device registration — 2026-10-07

Source: direct owner report in this conversation, not agent-operated browser automation.

| Environment | Scenario | Reported result |
|---|---|---|
| Desktop Google Chrome | Filled registration data and submitted request | PASS — user reported device data registered and pending review within registration request |
| iPhone 16e / Safari | Filled registration data and submitted request | PASS — same reported success message |

This confirms user-observed submission success only. Browser/OS versions were not supplied. Photo preview, orientation, image persistence, administrator approval, and real-device cache behavior were not independently confirmed by this report. No new backend reads or writes were performed to infer those outcomes. Do not label those additional checks PASS.

The prior real-device registration NOT RUN status is superseded for submission in these two environments. The agent did not operate a real phone. Production remains unchanged by this work.

## Admin acceptance — 2026-10-07

Verified hosted Staging dashboard with synthetic admin: both owner-submitted requests exist as PENDING and both photos resolve/decode as blob images. Only STG-ADMIN-REVIEW synthetic fixture was approved through the live dashboard; APPROVED, approved_at and approved_by were verified through authenticated API. Owner requests were not approved/rejected automatically. Evidence: ALBASHIR_STAGING_ADMIN_ACCEPTANCE.json (counts only, no personal data).
