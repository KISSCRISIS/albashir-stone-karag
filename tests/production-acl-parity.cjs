const fs = require("fs");
const path = require("path");
const assert = require("assert/strict");

const root = path.resolve(__dirname, "..");
const read = (name) => fs.readFileSync(path.join(root, "supabase", "migrations", name), "utf8");

const violation = read("20261007143000_disable_violation_operational_access.sql");
const admin = read("20261007143100_harden_admin_rpc_execute_acl.sql");
const helpers = read("20261007143200_harden_internal_security_helpers_acl.sql");

function normalized(sql) {
  return sql.replace(/\s+/g, " ").trim();
}

const v = normalized(violation);
assert.match(v, /REVOKE EXECUTE ON FUNCTION public\.submit_violation_report\(text, text, text\) FROM PUBLIC, anon, authenticated;/i);
assert.match(v, /REVOKE EXECUTE ON FUNCTION public\.admin_update_violation_status\(uuid, text\) FROM PUBLIC, anon, authenticated;/i);
assert.match(v, /REVOKE ALL PRIVILEGES ON TABLE public\.violation_reports FROM anon;/i);
assert.match(v, /REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE public\.violation_reports FROM authenticated;/i);
assert.match(v, /DROP POLICY IF EXISTS "Gate can upload violation photos" ON storage\.objects;/i);

const a = normalized(admin);
for (const signature of [
  "admin_review_employee_data_change\\(uuid, text, text\\)",
  "admin_set_trusted_device\\(uuid, boolean, boolean\\)",
  "admin_upsert_specialty_limit\\(text, integer, boolean\\)",
  "super_admin_delete_admin_profile\\(uuid\\)",
  "super_admin_disable_admin_profile\\(uuid\\)",
  "super_admin_upsert_admin_profile\\(text, text, text, boolean\\)",
  "super_admin_upsert_admin_profile\\(text, text, text, text, boolean, jsonb\\)"
]) {
  assert.match(a, new RegExp("REVOKE EXECUTE ON FUNCTION public\\." + signature + " FROM PUBLIC, anon;", "i"));
}

const h = normalized(helpers);
for (const signature of [
  "current_admin_role\\(\\)",
  "is_admin\\(\\)",
  "is_super_admin\\(\\)",
  "has_admin_permission\\(text\\)"
]) {
  assert.match(h, new RegExp("REVOKE EXECUTE ON FUNCTION public\\." + signature + " FROM PUBLIC, anon;", "i"));
}
for (const signature of [
  "cleanup_expired_qr_sessions\\(\\)",
  "rls_auto_enable\\(\\)",
  "write_security_attempt\\(text, text, text, boolean\\)"
]) {
  assert.match(h, new RegExp("REVOKE EXECUTE ON FUNCTION public\\." + signature + " FROM PUBLIC, anon, authenticated;", "i"));
}

for (const sql of [violation, admin, helpers]) {
  assert.match(sql, /NOTIFY pgrst, 'reload schema';/);
}

console.log("PASS Production ACL parity migrations preserve violation shutdown, admin RPC hardening and internal helper restrictions");
