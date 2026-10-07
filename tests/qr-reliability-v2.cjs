const fs=require('node:fs');
const path=require('node:path');
const assert=require('node:assert/strict');
const root=path.join(__dirname,'..');
const read=f=>fs.readFileSync(path.join(root,f),'utf8');

const migration=read('supabase/migrations/20261007181500_qr_reliability_v2.sql');
const verify=read('verify.html');
const guard=read('guard.html');

assert.match(migration,/claim_request_id uuid/);
assert.match(migration,/private\.qr_verification_requests/);
assert.match(migration,/claim_qr_session_v2/);
assert.match(migration,/public_guard_auto_employee_check_v2/);
assert.match(migration,/public_guard_employee_check_v2/);
assert.match(migration,/payload_hash/);
assert.match(migration,/on conflict \(request_id\) do nothing/);
assert.match(migration,/for update/);
assert.match(migration,/q\.claim_request_id=p_request_id/);
assert.match(migration,/revoke all on table private\.qr_verification_requests from public, anon, authenticated/);

assert.match(verify,/activeQrRequestId/);
assert.match(verify,/rpcWithRetry/);
assert.match(verify,/claim_qr_session_v2/);
assert.match(verify,/public_guard_auto_employee_check_v2/);
assert.match(verify,/public_guard_employee_check_v2/);
assert.match(verify,/clearQrTokenFromUrl/);
assert.match(verify,/history\.replaceState/);
assert.match(verify,/timeoutMs:5000/);
assert.match(verify,/timeoutMs:8000/);

assert.match(guard,/async function prewarm\(/);
assert.match(guard,/function rotate\(/);
assert.match(guard,/lastHealthyAt/);
assert.match(guard,/errorCorrectionLevel:'M'/);
assert.match(guard,/margin:4/);
assert.match(guard,/Date\.now\(\)-lastHealthyAt>10000/);

console.log('PASS QR Reliability v2 idempotency, retries, pre-rotation and watchdog regression');
