(function () {
  "use strict";

  const KEY = "alb_portal_session_v1";
  const currentScript = document.currentScript;
  const requiredRoles = (currentScript?.dataset.roles || "").split(",").map((role) => role.trim()).filter(Boolean);

  function normalizeRole(role) {
    return role === "SUB_ADMIN" ? "ADMIN" : String(role || "").toUpperCase();
  }

  function readSession() {
    try {
      const session = JSON.parse(sessionStorage.getItem(KEY) || "null");
      if (!session?.role || Number(session.expiresAt || 0) < Date.now()) {
        sessionStorage.removeItem(KEY);
        return null;
      }
      session.role = normalizeRole(session.role);
      return session;
    } catch (_) {
      sessionStorage.removeItem(KEY);
      return null;
    }
  }

  function setSession(role, extra = {}) {
    window.EmployeePhoto?.clearCache();
    const session = { role: normalizeRole(role), createdAt: Date.now(), expiresAt: Date.now() + 8 * 60 * 60 * 1000, ...extra };
    sessionStorage.setItem(KEY, JSON.stringify(session));
    return session;
  }

  function clearSession() {
    window.EmployeePhoto?.clearCache();
    sessionStorage.removeItem(KEY);
    Object.keys(localStorage).filter((key) => key.startsWith("sb-") && key.endsWith("-auth-token")).forEach((key) => localStorage.removeItem(key));
  }

  function safeNext() {
    const file = location.pathname.split(/[\\/]/).pop() || "portal.html";
    return file + location.search + location.hash;
  }

  function redirectToPortal() {
    const next = encodeURIComponent(safeNext());
    location.replace(`./portal.html?next=${next}`);
  }

  function isDirectRegistrationRequest() {
    const file = location.pathname.split(/[\\/]/).pop() || "";
    return file === "register.html";
  }

  function addRoleNavigation(session) {
    if (document.getElementById("portalRoleNavigation")) return;
    const style = document.createElement("style");
    style.textContent = `.portal-role-nav{position:relative;z-index:9990;display:flex;align-items:center;justify-content:space-between;gap:10px;padding:8px 14px;direction:rtl;background:#020d1b;color:#dbeafe;border-bottom:1px solid rgba(56,189,248,.24);font:12px "Segoe UI",Tahoma,Arial,sans-serif}.portal-role-nav__links{display:flex;align-items:center;gap:7px;flex-wrap:wrap}.portal-role-nav a,.portal-role-nav button{display:inline-flex;align-items:center;justify-content:center;width:auto;margin:0;padding:7px 10px;border:1px solid rgba(56,189,248,.24);border-radius:8px;background:#082b4b;color:#e0f2fe;text-decoration:none;font:inherit;font-weight:800;box-shadow:none;cursor:pointer}.portal-role-nav__role{font-weight:900;color:#7dd3fc}@media(max-width:540px){.portal-role-nav{align-items:flex-start;flex-direction:column}.portal-role-nav__links{width:100%}.portal-role-nav a,.portal-role-nav button{flex:1}}`;
    document.head.appendChild(style);
    const nav = document.createElement("nav");
    nav.id = "portalRoleNavigation";
    nav.className = "portal-role-nav";
    const role = document.createElement("div");
    role.className = "portal-role-nav__role";
    role.textContent = `ALBASHIR EMERGENCY HOSPITAL — ${session.role}`;
    const links = document.createElement("div");
    links.className = "portal-role-nav__links";
    const items = session.role === "EMPLOYEE"
      ? [["الملف الشخصي", "./profile.html"], ["مسح QR", "./verify.html"]]
      : session.role === "EMPLOYEE_ONBOARDING"
        ? [["طلب تسجيل", "./register.html"]]
        : session.role === "GUARD"
          ? [["شاشة الحارس", "./index.html"], ["تحقق يدوي", "./guard.html"]]
          : [["لوحة الإدارة", "./admin_dashboard.html"]];
    items.forEach(([label, href]) => { const link = document.createElement("a"); link.textContent = label; link.href = href; links.appendChild(link); });
    const logout = document.createElement("button");
    logout.type = "button";
    logout.textContent = "خروج";
    logout.addEventListener("click", () => { sessionStorage.setItem("alb_skip_fast_device_once", "1"); clearSession(); location.replace("./portal.html"); });
    links.appendChild(logout);
    nav.append(role, links);
    document.body.prepend(nav);
  }

  window.ALBASHIRAccess = { readSession, setSession, clearSession, normalizeRole };

  if (requiredRoles.length) {
    document.documentElement.style.visibility = "hidden";
    let session = readSession();
    const roles = requiredRoles.map(normalizeRole);
    if (isDirectRegistrationRequest() && roles.includes("EMPLOYEE_ONBOARDING") && (!session || !roles.includes(session.role))) {
      session = setSession("EMPLOYEE_ONBOARDING", { directRegistration: true });
    }
    const allowed = session && roles.includes(session.role);
    if (!allowed) {
      redirectToPortal();
    } else {
      document.documentElement.style.visibility = "";
      if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", () => addRoleNavigation(session), { once: true });
      else addRoleNavigation(session);
    }
  }
})();
