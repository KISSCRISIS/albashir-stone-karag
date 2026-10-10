# Employee-based admin appointment — owner approved Staging scope, implementation validated

## Requested behavior
Replace manual creation of new admins with selection of an APPROVED employee from employee_registrations. SUPER_ADMIN chooses either unrestricted SUPER_ADMIN or restricted SUB_ADMIN and the six existing permission switches. Name/phone/photo are read from the employee record, not re-entered by the owner. Existing admins remain editable and can be disabled.

## Employee completion
After appointment, show an in-app reminder in the authenticated employee profile and remembered employee journey. Employee completes their own email and password (current minimum 12 characters), verifies the email, and activates the separately authenticated admin account. Show appointment as awaiting account completion until activation. Do not send external messages without further authorization. Reminder remains available while pending. Full employee details cannot be obtained merely by knowing an appointment ID.

## Backend addition required
Private appointment record: registration UUID, selected role and fixed permission set, assigning SUPER_ADMIN UUID, pending/active/revoked state and timestamps, linked Auth user UUID. Unique active/pending nomination per registration. Owner-scoped RPCs create/update/revoke/list nominations; employee-scoped retrieval and completion require server-verified employee identity. One-use short-lived completion proof binds the verified employee and verified Auth account. Server-side completion creates admin_profiles from the stored assignment only, without trusting client-submitted role/permissions or user_metadata. No direct public table access.

## Invariants and rollout
Only APPROVED employee records can be appointed and activated; revoked/rejected employee identity cannot redeem a pending assignment. Owner may grant full authority explicitly; last active SUPER_ADMIN and existing owner safeguards retained. Revoking an assignment prevents completion and disabling an active admin uses existing authorization safeguards. Audit appointment, permission changes, completion and revocation without passwords/tokens. Keep employee parking authorization, Mandatory QR, manual_employee_check and daily limits unchanged.

Staging only after explicit migration approval. Tests: unauthorized nomination denied; cross-employee redemption denied; role/permission tampering denied; pending/rejected employees denied; duplicate completion idempotent; revoked proof denied; verified-email ownership required; existing admin modification/disable retained; responsive owner picker and employee reminder/completion. Production untouched.

## Implemented RPC contract
Owner: super_admin_assign_employee, super_admin_employee_assignments, super_admin_revoke_employee_assignment. Employee identity: employee_admin_assignment and employee_admin_claim. Verified Auth user: employee_admin_complete. Private proof is bound to appointment/email, expires in 10 minutes and is consumed transactionally. Existing linked accounts can be reactivated by explicit owner reappointment; other existing administrator accounts cannot be overwritten by this completion flow. Standard Supabase signup sends email confirmation on employee submission; the application never stores or audits the password.

## Validation — 2026-10-10
All 37 local test suites and all 10 browser suites passed. The scoped migration was applied to Staging adwvokwucotohwayorgx. A transaction with rolled-back synthetic fixtures verified nomination, employee identity, confirmed email, exact grants, idempotent activation and revocation. HTTP checks verified anonymous activation denial. Private table RLS and denied direct client reads were checked. manual_employee_check remained unchanged. Real email delivery still requires an employee acceptance trial; no test emails were sent. Production was not modified.
