(function () {
  "use strict";

  const STORAGE_KEY = "erp_global_hospital_leadership_v1";
  const HOSPITAL_NAME = "ALBASHIR EMERGENCY HOSPITAL";
  const SUPABASE_URL = "https://qinsfvlspdticposbvst.supabase.co";
  const SUPABASE_ANON_KEY = "sb_publishable_okoDqbwZNNvrCZQ025RkPw_qFXkA7I8";
  const defaults = [
    {
      medal: "🥇",
      tier: "gold",
      name: "Dr. Salah Qazqi",
      title: "Director of Emergency Hospital, Emergency Department & Outpatient Clinics"
    },
    {
      medal: "🥈",
      tier: "silver",
      name: "Dr. Suleiman Mohammad Abu Awad",
      title: "Assistant Director for Medical and Technical Affairs, Emergency Hospital / ALBASHIR EMERGENCY HOSPITAL"
    },
    {
      medal: "🥉",
      tier: "bronze",
      name: "Dr. Hassan Shehadeh",
      title: "Head of Emergency Department & Outpatient Clinics"
    }
  ];

  function loadLeadership() {
    try {
      const saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || "null");
      if (Array.isArray(saved) && saved.length === 3) return saved;
    } catch (_) {}
    return defaults.map((item) => ({ ...item }));
  }

  function getClient() {
    if (!window.supabase?.createClient) return null;
    try {
      if (typeof supabaseClient !== "undefined" && supabaseClient) return supabaseClient;
      if (typeof client !== "undefined" && client) return client;
    } catch (_) {}
    if (!window.__albLeadershipClient) {
      window.__albLeadershipClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
        auth: {
          persistSession: false,
          autoRefreshToken: false,
          detectSessionInUrl: false
        }
      });
    }
    return window.__albLeadershipClient;
  }

  async function refreshLeadership() {
    const client = getClient();
    if (!client || !navigator.onLine) return;
    try {
      const { data, error } = await client
        .from("hospital_settings")
        .select("setting_value")
        .eq("setting_key", "leadership")
        .maybeSingle();
      if (error || !Array.isArray(data?.setting_value) || data.setting_value.length !== 3) return;
      localStorage.setItem(STORAGE_KEY, JSON.stringify(data.setting_value));
      render();
    } catch (_) {}
  }

  function addStyles() {
    if (document.getElementById("globalLeadershipStyles")) return;
    const style = document.createElement("style");
    style.id = "globalLeadershipStyles";
    style.textContent = `
      .global-leadership{position:relative;width:100%;margin-top:24px;padding:18px max(16px,calc((100vw - 1380px)/2));direction:ltr;color:#eaf6ff;background:linear-gradient(135deg,#020b17 0%,#062743 50%,#031524 100%);border-top:1px solid rgba(56,189,248,.28);box-shadow:0 -16px 40px rgba(0,0,0,.18);font-family:"Segoe UI",Tahoma,Arial,sans-serif;z-index:5}
      .global-leadership__head{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:13px}
      .global-leadership__head-actions{display:flex;align-items:center;gap:8px;flex-wrap:wrap;justify-content:flex-end}
      .global-leadership__eyebrow{color:#7dd3fc;font-size:10px;font-weight:800;text-transform:uppercase;letter-spacing:.08em}
      .global-leadership__title{margin:3px 0 0;font-size:16px;font-weight:900;letter-spacing:0}
      .global-leadership__grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:10px}
      .global-leadership__person{display:grid;grid-template-columns:48px 1fr;gap:11px;align-items:center;min-height:86px;padding:12px;border:1px solid rgba(148,163,184,.18);border-radius:12px;background:rgba(6,30,53,.78)}
      .global-leadership__badge{width:44px;height:44px;display:grid;place-items:center;border-radius:50%;font-size:23px;background:#071827;border:2px solid currentColor;box-shadow:0 0 18px currentColor}
      .global-leadership__person.gold{color:#facc15}.global-leadership__person.silver{color:#cbd5e1}.global-leadership__person.bronze{color:#fb923c}
      .global-leadership__copy{color:#eaf6ff}.global-leadership__name{font-size:14px;font-weight:900;line-height:1.35}.global-leadership__role{margin-top:4px;color:#a8c4db;font-size:10px;line-height:1.45}
      .global-leadership__edit{display:none;border:1px solid rgba(56,189,248,.32);border-radius:9px;padding:8px 10px;background:rgba(8,43,75,.9);color:#e0f2fe;font:inherit;font-size:11px;font-weight:800;cursor:pointer}
      .registration-copy-shortcut{position:fixed;top:calc(12px + env(safe-area-inset-top));left:calc(12px + env(safe-area-inset-left));z-index:10000;width:auto;margin:0;border:1px solid rgba(34,197,94,.42);border-radius:9px;padding:9px 12px;background:linear-gradient(135deg,rgba(21,128,61,.96),rgba(22,163,74,.92));color:#f0fdf4;font:800 12px "Segoe UI",Tahoma,Arial,sans-serif;box-shadow:0 14px 34px rgba(0,0,0,.28);cursor:pointer}
      .global-leadership__toast{position:fixed;left:50%;bottom:22px;transform:translateX(-50%);z-index:100000;padding:10px 14px;border:1px solid rgba(34,197,94,.42);border-radius:999px;background:#052e1a;color:#dcfce7;font-size:12px;font-weight:800;box-shadow:0 18px 45px rgba(0,0,0,.35)}
      body[data-super-admin="true"] .global-leadership__edit{display:inline-flex}
      .global-leadership__modal{position:fixed;inset:0;display:none;place-items:center;padding:18px;background:rgba(0,7,15,.78);z-index:99999;direction:rtl}
      .global-leadership__modal.open{display:grid}.global-leadership__dialog{width:min(720px,100%);max-height:90vh;overflow:auto;padding:18px;border:1px solid rgba(56,189,248,.3);border-radius:14px;background:#061b32;color:#eaf6ff;box-shadow:0 30px 90px rgba(0,0,0,.55)}
      .global-leadership__form{display:grid;gap:11px}.global-leadership__field{display:grid;grid-template-columns:1fr 2fr;gap:8px}.global-leadership__field input{width:100%;padding:10px;border:1px solid rgba(148,163,184,.24);border-radius:9px;background:#020d1b;color:#eaf6ff;font:inherit}
      .global-leadership__actions{display:flex;gap:8px;justify-content:flex-start;margin-top:12px}.global-leadership__actions button{border:0;border-radius:9px;padding:9px 13px;color:#fff;background:#0284c7;font:inherit;font-weight:800;cursor:pointer}.global-leadership__actions .secondary{background:#334155}
      .global-leadership.admin-context{padding-left:max(236px,calc((100vw - 1160px)/2 + 220px))}
      @media(max-width:850px){.registration-copy-shortcut{top:calc(8px + env(safe-area-inset-top));left:calc(8px + env(safe-area-inset-left));padding:8px 10px;font-size:11px}.global-leadership__head{align-items:flex-start;flex-direction:column}.global-leadership__head-actions{width:100%;justify-content:flex-start}.global-leadership__grid{grid-template-columns:1fr}.global-leadership__person{min-height:72px}.global-leadership__field{grid-template-columns:1fr}.global-leadership__title{font-size:15px}.global-leadership.admin-context{padding-left:16px}}
    `;
    document.head.appendChild(style);
  }

  function render() {
    addStyles();
    document.getElementById("globalLeadership")?.remove();
    const data = loadLeadership();
    const section = document.createElement("section");
    section.id = "globalLeadership";
    section.className = "global-leadership";
    if (document.querySelector(".nav-tabs")) section.classList.add("admin-context");
    section.setAttribute("aria-label", "Hospital leadership");

    const head = document.createElement("div");
    head.className = "global-leadership__head";
    head.innerHTML = `<div><div class="global-leadership__eyebrow">${HOSPITAL_NAME}</div><h2 class="global-leadership__title">Hospital Leadership</h2></div>`;
    const actions = document.createElement("div");
    actions.className = "global-leadership__head-actions";
    const edit = document.createElement("button");
    edit.type = "button";
    edit.className = "global-leadership__edit";
    edit.textContent = "Edit Leadership";
    edit.addEventListener("click", openEditor);
    actions.append(edit);
    head.appendChild(actions);

    const grid = document.createElement("div");
    grid.className = "global-leadership__grid";
    data.forEach((person) => {
      const card = document.createElement("article");
      card.className = `global-leadership__person ${person.tier}`;
      const badge = document.createElement("div");
      badge.className = "global-leadership__badge";
      badge.textContent = person.medal;
      const copy = document.createElement("div");
      copy.className = "global-leadership__copy";
      const name = document.createElement("div");
      name.className = "global-leadership__name";
      name.textContent = person.name;
      const role = document.createElement("div");
      role.className = "global-leadership__role";
      role.textContent = person.title;
      copy.append(name, role);
      card.append(badge, copy);
      grid.appendChild(card);
    });
    section.append(head, grid);
    document.body.appendChild(section);
    renderRegistrationShortcut();
  }

  function renderRegistrationShortcut() {
    document.getElementById("registrationCopyShortcut")?.remove();
    const button = document.createElement("button");
    button.id = "registrationCopyShortcut";
    button.type = "button";
    button.className = "registration-copy-shortcut";
    button.textContent = "نسخ رابط التسجيل";
    button.addEventListener("click", copyRegistrationLink);
    document.body.appendChild(button);
  }

  function getRegistrationUrl() {
    return new URL("./register.html", window.location.href).toString();
  }

  function showCopyToast(message) {
    document.querySelector(".global-leadership__toast")?.remove();
    const toast = document.createElement("div");
    toast.className = "global-leadership__toast";
    toast.textContent = message;
    document.body.appendChild(toast);
    setTimeout(() => toast.remove(), 2600);
  }

  async function copyRegistrationLink() {
    const link = getRegistrationUrl();
    try {
      await navigator.clipboard.writeText(link);
      showCopyToast("تم نسخ رابط التسجيل المباشر");
    } catch (_) {
      window.prompt("رابط التسجيل المباشر للموظفين:", link);
    }
  }

  function openEditor() {
    if (document.body.dataset.superAdmin !== "true") return;
    document.getElementById("globalLeadershipModal")?.remove();
    const data = loadLeadership();
    const modal = document.createElement("div");
    modal.id = "globalLeadershipModal";
    modal.className = "global-leadership__modal open";
    const dialog = document.createElement("div");
    dialog.className = "global-leadership__dialog";
    const title = document.createElement("h2");
    title.textContent = "Edit Hospital Leadership";
    const form = document.createElement("form");
    form.className = "global-leadership__form";
    data.forEach((person, index) => {
      const field = document.createElement("div");
      field.className = "global-leadership__field";
      field.innerHTML = `<input data-index="${index}" data-key="name" value=""><input data-index="${index}" data-key="title" value="">`;
      field.children[0].value = person.name;
      field.children[1].value = person.title;
      form.appendChild(field);
    });
    const actions = document.createElement("div");
    actions.className = "global-leadership__actions";
    const save = document.createElement("button"); save.type = "submit"; save.textContent = "Save";
    const cancel = document.createElement("button"); cancel.type = "button"; cancel.className = "secondary"; cancel.textContent = "Cancel"; cancel.addEventListener("click", () => modal.remove());
    actions.append(save, cancel); form.appendChild(actions);
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      if (document.body.dataset.superAdmin !== "true") return;
      const next = data.map((item) => ({ ...item }));
      form.querySelectorAll("input").forEach((input) => { next[Number(input.dataset.index)][input.dataset.key] = input.value.trim(); });
      const client = getClient();
      if (!client) return;
      save.disabled = true;
      try {
        const { error } = await client.from("hospital_settings").upsert({
          setting_key: "leadership",
          setting_value: next,
          updated_at: new Date().toISOString()
        });
        if (error) throw error;
        localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
        modal.remove();
        render();
      } catch (error) {
        save.disabled = false;
        alert("تعذر حفظ بيانات القيادة: " + (error.message || String(error)));
      }
    });
    dialog.append(title, form); modal.appendChild(dialog); document.body.appendChild(modal);
    modal.addEventListener("click", (event) => { if (event.target === modal) modal.remove(); });
  }

  function init() {
    render();
    refreshLeadership();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init, { once: true });
  } else {
    init();
  }
})();
