const fs=require("fs"),path=require("path"),assert=require("assert/strict");
const root=path.resolve(__dirname,"..");
const portal=fs.readFileSync(path.join(root,"portal.html"),"utf8");
const css=fs.readFileSync(path.join(root,"portal.css"),"utf8");
const guard=fs.readFileSync(path.join(root,"guard.html"),"utf8");

assert(portal.includes('id="openPortalLogin"'),"landing must expose one explicit دخول button");
assert(portal.includes('portal-login-overlay--closed'),"login overlay must be hidden on initial landing");
assert(portal.includes("function openPortalLogin()"),"landing button must reveal login overlay");
assert(!portal.includes("\n  fastTrustedLogin();"),"trusted phone must not auto-skip the main landing screen");
assert(portal.includes('class="role-tab portal-guard-entry" data-role="guard"'),"guard tab must remain in code but be hidden");
assert(portal.includes('class="role-panel portal-guard-entry" id="guardPanel"'),"guard panel must remain in code but be hidden");
assert(css.includes(".portal-stage .portal-guard-entry{display:none!important}"),"guard option must be hidden by CSS");
assert(css.includes("font-size:clamp(18px,1.65cqw,26px)"),"employee/admin role tabs must use larger text");
assert(guard.includes("create_public_guard_qr"),"direct guard page must remain operational");
assert(!guard.includes("تسجيل جهاز الحارس")&&!guard.includes("توثيق جهاز الحارس"),"direct guard page must not expose manual guard-device documentation");
console.log("PASS hospital landing first, guard portal option hidden, and direct guard page unchanged without manual device documentation");
