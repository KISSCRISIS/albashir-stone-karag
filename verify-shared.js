// verify-shared.js
// Shared infrastructure for register.html / verify.html / guard.html.
// Classic (non-module) script: top-level `let`/`const`/`function` declarations
// here share the same global scope as the page's own inline <script> that is
// loaded after this file, exactly like the old single-file verify.html did.
// This file intentionally has NO page-specific DOM wiring (no form submit
// listeners, no result-card updates) — each page keeps that itself.

const APP_CONFIG = {
  APP_NAME: "ALBASHIR EMERGENCY HOSPITAL",
  SUPABASE_URL: "https://qinsfvlspdticposbvst.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFpbnNmdmxzcGR0aWNwb3NidnN0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA1OTY5MjgsImV4cCI6MjEwNjE3MjkyOH0.6HsEob0w4BOD0VYt_KgzYEYpCBQgbciCP7nJ-owqqTY"
};

let supabaseClient = null;

const TRUSTED_DEVICE_STORAGE_KEY = "erp_trusted_device_token_v1";
const TRUSTED_DEVICE_ID_STORAGE_KEY = "erp_trusted_device_id_v1";
const PENDING_REGISTRATION_STORAGE_KEY = "erp_pending_registration_v1";
const GATE_DEVICE_STORAGE_KEY = "erp_gate_device_v1";
const OFFLINE_DEVICE_TOKEN_STORAGE_KEY = "erp_offline_device_token_v1";
const OFFLINE_DB_NAME = "erp_offline_gate_mode";
const OFFLINE_DB_VERSION = 2;
const OFFLINE_ACCESS_STORE = "offline_access_queue";
const OFFLINE_CRYPTO_STORE = "offline_crypto_meta";
const OFFLINE_CRYPTO_KEY_ID = "offline-sensitive-fields-v1";
const CACHE_VERSION = "emergency-room-parking-offline-v15";
const APP_VERSION = "2026.09.28-24x7";

let syncingLock = false;

function normalizeRpcData(data, fnName) {
  let value = Array.isArray(data) ? data[0] : data;
  if (typeof value === "string") { try { value = JSON.parse(value); } catch { return null; } }
  if (value && fnName && value[fnName]) value = value[fnName];
  if (typeof value === "string") { try { value = JSON.parse(value); } catch { return null; } }
  return value;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function extractQrToken(value) {
  const raw = String(value || "").trim();
  if (!raw) return "";
  try {
    const url = new URL(raw, window.location.href);
    return url.searchParams.get("token") || raw;
  } catch {
    return raw;
  }
}

function renderEmployeeDetails(employee) {
  if (!employee) return "";
  const photo = employee.photo_url || employee.employee_photo_url || "";
  return `
    <div class="employee-card">
      ${photo ? `<img class="employee-photo" src="${escapeHtml(photo)}" alt="صورة الموظف" />` : `<div class="employee-photo"></div>`}
      <div class="employee-info">
        <div class="employee-field"><span>الاسم</span><strong>${escapeHtml(employee.full_name || "-")}</strong></div>
        <div class="employee-field"><span>الرقم الوظيفي/الوطني</span><strong>${escapeHtml(employee.employee_id || "-")}</strong></div>
        <div class="employee-field"><span>القسم</span><strong>${escapeHtml(employee.department || "-")}</strong></div>
        <div class="employee-field"><span>الاختصاص</span><strong>${escapeHtml(employee.specialty || "-")}</strong></div>
        <div class="employee-field"><span>تصنيف الموظف</span><strong>${escapeHtml(employee.classification || employee.employee_type || employee.job_type || "-")}</strong></div>
        <div class="employee-field"><span>الحالة</span><strong>${escapeHtml(employee.status || "-")}</strong></div>
      </div>
    </div>
  `;
}

function createSupabaseClient() {
  if (!window.supabase || !APP_CONFIG.SUPABASE_URL || !APP_CONFIG.SUPABASE_ANON_KEY) return null;
  return supabase.createClient(APP_CONFIG.SUPABASE_URL, APP_CONFIG.SUPABASE_ANON_KEY);
}

/* ---------- Gate / offline device identity ---------- */

function getGateDevice() {
  let device = null;
  try { device = JSON.parse(localStorage.getItem(GATE_DEVICE_STORAGE_KEY) || "null"); } catch { device = null; }
  if (device?.device_code) return device;
  device = {
    device_code: "gate-" + Math.random().toString(16).slice(2) + "-" + Date.now().toString(36),
    gate_name: "Emergency Room Gate",
    cache_version: CACHE_VERSION,
    created_at: new Date().toISOString()
  };
  localStorage.setItem(GATE_DEVICE_STORAGE_KEY, JSON.stringify(device));
  return device;
}

function getOfflineDeviceToken() {
  let token = localStorage.getItem(OFFLINE_DEVICE_TOKEN_STORAGE_KEY) || "";
  if (token) return token;
  const bytes = new Uint8Array(48);
  crypto.getRandomValues(bytes);
  token = Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("");
  localStorage.setItem(OFFLINE_DEVICE_TOKEN_STORAGE_KEY, token);
  return token;
}

/* ---------- Trusted device (employee's own phone) ---------- */

function getTrustedDeviceToken() { return localStorage.getItem(TRUSTED_DEVICE_STORAGE_KEY) || ""; }
function saveTrustedDeviceToken(token) { localStorage.setItem(TRUSTED_DEVICE_STORAGE_KEY, token); }
function clearTrustedDeviceToken() {
  localStorage.removeItem(TRUSTED_DEVICE_STORAGE_KEY);
  localStorage.removeItem(PENDING_REGISTRATION_STORAGE_KEY);
}
function generateTrustedDeviceToken() {
  const bytes = new Uint8Array(48); crypto.getRandomValues(bytes);
  return Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("");
}

function readPendingRegistrationContext() {
  try {
    const value = JSON.parse(localStorage.getItem(PENDING_REGISTRATION_STORAGE_KEY) || "null");
    const employeeId = String(value?.employee_id || "").trim();
    const deviceId = String(value?.device_id || "").trim();
    const token = String(value?.token || "").trim();
    if (!employeeId || !deviceId || token.length < 40) return null;
    return { employeeId, deviceId, token };
  } catch { return null; }
}

function savePendingRegistrationContext(employeeId, deviceId, token) {
  localStorage.setItem(PENDING_REGISTRATION_STORAGE_KEY, JSON.stringify({
    employee_id: String(employeeId || "").trim(),
    device_id: String(deviceId || "").trim(),
    token: String(token || "").trim()
  }));
}

function getOrCreatePendingRegistrationToken(employeeId, deviceId) {
  const cleanEmployeeId = String(employeeId || "").trim();
  const cleanDeviceId = String(deviceId || "").trim();
  const existing = readPendingRegistrationContext();
  if (existing && existing.employeeId === cleanEmployeeId && existing.deviceId === cleanDeviceId) {
    return existing.token;
  }
  if (!existing) {
    const legacyStoredToken = getTrustedDeviceToken();
    if (legacyStoredToken.length >= 40) {
      savePendingRegistrationContext(cleanEmployeeId, cleanDeviceId, legacyStoredToken);
      return legacyStoredToken;
    }
  }
  const token = generateTrustedDeviceToken();
  savePendingRegistrationContext(cleanEmployeeId, cleanDeviceId, token);
  return token;
}

function getTrustedDeviceId() {
  let id = localStorage.getItem(TRUSTED_DEVICE_ID_STORAGE_KEY);
  if (!id) {
    id = "mobile-" + (crypto.randomUUID?.() || Date.now().toString(36) + "-" + Math.random().toString(16).slice(2));
    localStorage.setItem(TRUSTED_DEVICE_ID_STORAGE_KEY, id);
  }
  return id;
}

function getDeviceType() {
  const ua = navigator.userAgent || "";
  if (/iPad|iPhone|iPod/i.test(ua)) return "iOS";
  if (/Android/i.test(ua)) return "Android";
  return "Web";
}

function getDeviceName() {
  const ua = navigator.userAgent || "";
  const match = ua.match(/(iPhone|iPad|iPod|Android|Windows Phone|Macintosh|Windows NT)/i);
  return match ? match[1] : "Mobile Browser";
}

/* ---------- Offline Gate Mode: IndexedDB queue + AES-GCM field encryption ---------- */

function openOfflineDb() {
  return new Promise((resolve, reject) => {
    if (!("indexedDB" in window)) { reject(new Error("IndexedDB غير مدعوم في هذا المتصفح.")); return; }
    const request = indexedDB.open(OFFLINE_DB_NAME, OFFLINE_DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(OFFLINE_ACCESS_STORE)) {
        const store = db.createObjectStore(OFFLINE_ACCESS_STORE, { keyPath: "client_log_id" });
        store.createIndex("offline_created_at", "offline_created_at");
        store.createIndex("gate_device_code", "gate_device_code");
      }
      if (!db.objectStoreNames.contains(OFFLINE_CRYPTO_STORE)) {
        db.createObjectStore(OFFLINE_CRYPTO_STORE, { keyPath: "key_id" });
      }
    };
    request.onsuccess = async () => {
      const db = request.result;
      try {
        const key = await getOrCreateOfflineCryptoKey(db);
        await migrateOfflineAccessQueue(db, key);
        resolve(db);
      } catch (error) {
        db.close();
        reject(error);
      }
    };
    request.onerror = () => reject(request.error);
  });
}

function idbRequest(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error || new Error("فشل طلب IndexedDB."));
  });
}

function idbTransactionComplete(transaction) {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error || new Error("فشلت معاملة IndexedDB."));
    transaction.onabort = () => reject(transaction.error || new Error("أُلغيت معاملة IndexedDB."));
  });
}

async function getOrCreateOfflineCryptoKey(db) {
  const readTx = db.transaction(OFFLINE_CRYPTO_STORE, "readonly");
  const existing = await idbRequest(readTx.objectStore(OFFLINE_CRYPTO_STORE).get(OFFLINE_CRYPTO_KEY_ID));
  if (existing?.key) return existing.key;

  if (!window.crypto?.subtle) throw new Error("Web Crypto غير متاح لتأمين وضع Offline.");
  const candidate = await crypto.subtle.generateKey(
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"]
  );
  try {
    const writeTx = db.transaction(OFFLINE_CRYPTO_STORE, "readwrite");
    writeTx.objectStore(OFFLINE_CRYPTO_STORE).add({
      key_id: OFFLINE_CRYPTO_KEY_ID,
      key: candidate,
      created_at: new Date().toISOString()
    });
    await idbTransactionComplete(writeTx);
    return candidate;
  } catch (error) {
    const retryTx = db.transaction(OFFLINE_CRYPTO_STORE, "readonly");
    const winner = await idbRequest(retryTx.objectStore(OFFLINE_CRYPTO_STORE).get(OFFLINE_CRYPTO_KEY_ID));
    if (winner?.key) return winner.key;
    throw error;
  }
}

function asUint8Array(value) {
  if (value instanceof Uint8Array) return value;
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  return new Uint8Array(value || []);
}

async function encryptOfflineSensitiveFields(key, fields) {
  const cleanFields = Object.fromEntries(Object.entries(fields || {}).filter(([, value]) => value !== null && value !== undefined && value !== ""));
  if (!Object.keys(cleanFields).length) return null;
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const plaintext = new TextEncoder().encode(JSON.stringify(cleanFields));
  const ciphertext = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, plaintext);
  return { version: 1, iv, ciphertext };
}

async function decryptOfflineSensitiveFields(key, envelope) {
  if (!envelope?.iv || !envelope?.ciphertext) return {};
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: asUint8Array(envelope.iv) },
    key,
    asUint8Array(envelope.ciphertext)
  );
  const value = JSON.parse(new TextDecoder().decode(plaintext));
  return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

async function migrateOfflineAccessQueue(db, key) {
  const readTx = db.transaction(OFFLINE_ACCESS_STORE, "readonly");
  const logs = await idbRequest(readTx.objectStore(OFFLINE_ACCESS_STORE).getAll());
  const updates = [];
  for (const log of logs || []) {
    const hasLegacyFields = ["employee_id", "mobile_number", "qr_token", "payload"].some((field) => Object.prototype.hasOwnProperty.call(log, field));
    if (!hasLegacyFields && Object.prototype.hasOwnProperty.call(log, "encrypted_sensitive")) continue;

    const legacyPayload = log.payload && typeof log.payload === "object" && !Array.isArray(log.payload) ? log.payload : {};
    const encryptedSensitive = log.encrypted_sensitive || await encryptOfflineSensitiveFields(key, {
      employee_id: log.employee_id ?? legacyPayload.p_employee_id,
      qr_token: log.qr_token ?? legacyPayload.p_qr_token
    });
    const migrated = { ...log, encrypted_sensitive: encryptedSensitive };
    delete migrated.employee_id;
    delete migrated.mobile_number;
    delete migrated.qr_token;
    delete migrated.payload;
    delete migrated.gate_device_code;
    updates.push(migrated);
  }
  if (!updates.length) return;
  const writeTx = db.transaction(OFFLINE_ACCESS_STORE, "readwrite");
  const store = writeTx.objectStore(OFFLINE_ACCESS_STORE);
  updates.forEach((log) => store.put(log));
  await idbTransactionComplete(writeTx);
}

async function readOfflineAccessLogs() {
  const db = await openOfflineDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(OFFLINE_ACCESS_STORE, "readonly");
    const request = tx.objectStore(OFFLINE_ACCESS_STORE).getAll();
    request.onsuccess = () => resolve(request.result || []);
    request.onerror = () => reject(request.error);
    tx.oncomplete = () => db.close();
  });
}

async function countOfflineAccessLogs() {
  const db = await openOfflineDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(OFFLINE_ACCESS_STORE, "readonly");
    const request = tx.objectStore(OFFLINE_ACCESS_STORE).count();
    request.onsuccess = () => resolve(request.result || 0);
    request.onerror = () => reject(request.error);
    tx.oncomplete = () => db.close();
  });
}

async function clearSyncedOfflineAccessLogs(logs) {
  const db = await openOfflineDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(OFFLINE_ACCESS_STORE, "readwrite");
    const store = tx.objectStore(OFFLINE_ACCESS_STORE);
    logs.forEach((log) => store.delete(log.client_log_id));
    tx.oncomplete = () => { db.close(); resolve(); };
    tx.onerror = () => { db.close(); reject(tx.error); };
  });
}

async function incrementOfflineRetryCounts(logs) {
  if (!logs?.length) return;
  const db = await openOfflineDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(OFFLINE_ACCESS_STORE, "readwrite");
    const store = tx.objectStore(OFFLINE_ACCESS_STORE);
    logs.forEach((log) => {
      log.retry_count = Number(log.retry_count || 0) + 1;
      log.last_retry_at = new Date().toISOString();
      store.put(log);
    });
    tx.oncomplete = () => { db.close(); resolve(); };
    tx.onerror = () => { db.close(); reject(tx.error); };
  });
}

async function updateOfflinePendingBadge() {
  const el = document.getElementById("offlinePendingBadge");
  if (!el) return;
  const count = await countOfflineAccessLogs().catch(() => 0);
  if (count > 0) {
    el.textContent = `محاولات محفوظة بانتظار المزامنة: ${count}`;
    el.className = "notice";
    if (!navigator.onLine) el.classList.add("error");
    el.classList.remove("hidden");
  } else {
    el.classList.add("hidden");
  }
}

async function queueOfflineAccessLog(payload, reason = "OFFLINE_ATTEMPT") {
  const device = getGateDevice();
  const db = await openOfflineDb();
  try {
    const key = await getOrCreateOfflineCryptoKey(db);
    const encryptedSensitive = await encryptOfflineSensitiveFields(key, {
      employee_id: payload.p_employee_id || null,
      qr_token: payload.p_qr_token || null
    });
    const entry = {
      client_log_id: "offline-" + Date.now().toString(36) + "-" + Math.random().toString(16).slice(2),
      gate_name: device.gate_name,
      result: "DENIED",
      reason,
      offline_created_at: new Date().toISOString(),
      retry_count: 0,
      encrypted_sensitive: encryptedSensitive
    };
    await new Promise((resolve, reject) => {
      const tx = db.transaction(OFFLINE_ACCESS_STORE, "readwrite");
      tx.objectStore(OFFLINE_ACCESS_STORE).put(entry);
      tx.oncomplete = resolve;
      tx.onerror = () => reject(tx.error);
    });
  } catch (error) {
    db.close();
    throw error;
  } finally {
    db.close();
  }
  const count = await countOfflineAccessLogs();
  updateOfflinePendingBadge();
  return count;
}

async function decryptOfflineAccessLogs(logs) {
  const db = await openOfflineDb();
  try {
    const key = await getOrCreateOfflineCryptoKey(db);
    const decrypted = [];
    for (const log of logs || []) {
      const sensitive = await decryptOfflineSensitiveFields(key, log.encrypted_sensitive);
      decrypted.push({
        client_log_id: log.client_log_id,
        gate_name: log.gate_name || null,
        employee_id: sensitive.employee_id || null,
        result: log.result || "DENIED",
        reason: log.reason || null,
        qr_token: sensitive.qr_token || null,
        offline_created_at: log.offline_created_at
      });
    }
    return decrypted;
  } finally {
    db.close();
  }
}

async function syncGateDeviceHeartbeat() {
  if (!supabaseClient || !navigator.onLine) return;
  const device = getGateDevice();
  const pendingCount = await countOfflineAccessLogs().catch(() => 0);
  const payload = {
    p_device_code: device.device_code,
    p_gate_name: device.gate_name,
    p_cache_version: CACHE_VERSION,
    p_user_agent: navigator.userAgent,
    p_pending_count: pendingCount,
    p_device_token: getOfflineDeviceToken(),
    p_app_version: APP_VERSION
  };
  try {
    const { error } = await supabaseClient.rpc("upsert_gate_device_heartbeat", payload);
    if (error) throw error;
  } catch (err) {
    if (/p_app_version|schema cache|function/i.test(err.message || "")) {
      try {
        await supabaseClient.rpc("upsert_gate_device_heartbeat", {
          p_device_code: device.device_code,
          p_gate_name: device.gate_name,
          p_cache_version: CACHE_VERSION,
          p_user_agent: navigator.userAgent,
          p_pending_count: pendingCount,
          p_device_token: payload.p_device_token
        });
        return;
      } catch (fallbackErr) {
        console.warn("Gate device heartbeat fallback failed:", fallbackErr);
      }
    }
    console.warn("Gate device heartbeat failed:", err);
  }
}

async function syncOfflineAccessLogs() {
  if (syncingLock || !supabaseClient || !navigator.onLine) return;
  syncingLock = true;
  let logs = [];
  try {
    logs = await readOfflineAccessLogs();
    if (!logs.length) return;
    const rpcLogs = await decryptOfflineAccessLogs(logs);
    const { data, error } = await supabaseClient.rpc("sync_offline_access_logs", {
      p_device_code: getGateDevice().device_code,
      p_logs: rpcLogs,
      p_device_token: getOfflineDeviceToken()
    });
    if (error) throw error;
    const result = normalizeRpcData(data, "sync_offline_access_logs") || data;
    if (result && result.ok === false) throw new Error(result.message || "رفضت قاعدة البيانات مزامنة سجلات Offline.");
    await clearSyncedOfflineAccessLogs(logs);
    await updateOfflinePendingBadge();
    await syncGateDeviceHeartbeat();
  } catch (err) {
    await incrementOfflineRetryCounts(logs).catch(() => {});
    await updateOfflinePendingBadge();
    console.warn("Offline access log sync failed:", err);
  } finally {
    syncingLock = false;
  }
}

function registerOfflineGateMode() {
  if (!("serviceWorker" in navigator)) return;
  navigator.serviceWorker.register("./service-worker.js").catch((err) => {
    console.warn("Offline Gate Mode registration failed:", err);
  });
}
