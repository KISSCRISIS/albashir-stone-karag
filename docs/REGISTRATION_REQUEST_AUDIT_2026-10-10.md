# Registration request audit — Staging, 2026-10-10

Owner decision: preserve existing admission/data criteria. Incorrect names, identity, phone, photo or affiliation are reviewed and rejected by administration. No new format rule, migration, backend ACL or database schema modification authorized/applied in this audit.

## Current required fields
Both categories: full name, photo, employee/national ID, phone, registration category and accuracy acknowledgement. The form uses required controls; backend rejects empty/overlong base fields, missing photo reference and invalid category. Name structure, ownership of the phone/ID, likeness in the photo and accuracy of workplace are not automatically certified; administration must check them. The accuracy acknowledgement is a frontend requirement, not a persisted backend attestation.

Permanent employees: job and department; temporary/external: national/employee ID type, specialty and affiliated entity. Other affiliated entity requires entered text. Hidden category-inapplicable fields are disabled and sent as null. Job and permanent department are not additional server allowlists; temporary specialty must be active in specialty_daily_limits. All 16 displayed temporary specialties matched active Staging entries. ID type is used for presentation, not stored by the current RPC. These existing behaviors were preserved.

## Rejection versus operational failure
Missing fields or unchecked accuracy: browser prevents submission. Empty/overlong backend values, bad category/photo reference, inactive temporary specialty: RPC denies submission. A pending duplicate requires its original pending device token; opting out of saving does not permit an unauthorized resubmission, so that employee must contact administration for correction. Already rejected employee: review administration; already approved employee: registration does not replace QR/trusted-device authorization. Network/upload errors do not mean administrative rejection and preserve the form for retry. An accepted request remains PENDING until administration approves it; saving the phone does not grant immediate entry.

## Technical fixes
Submission lock prevents duplicate upload/RPC. Programmatic submit still checks native required fields/accuracy. DENIED results, including legacy ok=true DENIED responses, never reset the form or save trusted credentials. Failed upload leaves fields intact. Temporary preview URLs are released after success. Device-review indicator is only shown if device saving was requested. Device storage failure after an accepted server response is reported as a storage warning, not a failed request. Remember text states same-browser limits, shared-device caution, reset/expiry cases and optional nature.

## Existing backend finding preserved per owner instruction
The old eight-argument register_employee_request overload remains executable by anon on Staging; it contains older pending-update/first-entry behavior. Current register.html uses the fifteen-argument overload. This legacy exposure and the fact that photo references/accuracy are not comprehensively server-certified are NOT fixed by frontend validation. A separate explicitly approved backend cleanup would be required; no migration was created here.

## Validation
All 37 SQL/static suites passed. Real browser registration regression passed Chromium and WebKit: category switching, consent required, duplicate prevention, denied-form preservation, upload retry, optional saved device and request payloads. Real browser photo tests passed decoding, compression, MIME mismatch rejection, corrupt file rejection and unsupported HEIC explanation. Browser tests mock backend responses; actual phone camera/HEIC support varies by browser. No real employee request was submitted in testing. Production untouched.
