// ============================================================================
// employee-photo.js — client for the employee-photo-url resolver
//
// The employee-photos bucket is private: the browser can no longer build a
// permanent public URL. Every photo is displayed through a 60-second signed URL
// minted by the employee-photo-url Edge Function after it verifies the actor.
//
// Usage
//   render:  <img data-photo-ref="<path-or-legacy-url>" data-photo-fallback="./logo.jpeg">
//   hydrate: EmployeePhoto.hydrate(rootElement, actor, config)
//   manual:  const url = await EmployeePhoto.resolve(ref, actor, config)
//
// Actors
//   { type: "admin",           access_token }                      // reviews any employee
//   { type: "employee",        employee_id, mobile_number }        // own photo only
//   { type: "employee_device", device_token, device_id }           // own photo only
//   { type: "guard_device",    device_code, device_token }         // gate screen
//
// Cache policy
//   A signed URL is a temporary credential, so it must not be stored anywhere.
//   The URL is fetched with cache: "no-store" and displayed as a same-origin
//   blob URL, and it is never written to localStorage/sessionStorage. The
//   service worker never caches *.supabase.co responses. Failed no-store fetches
//   show the configured placeholder; signed URLs never become src or href.
// ============================================================================
(function () {
  "use strict";

  const RESOLVER_PATH = "/functions/v1/employee-photo-url";
  const SIGNED_URL_TTL_SECONDS = 60;
  const CACHE_SKEW_MS = 10000;
  const REQUEST_TIMEOUT_MS = 8000;
  const MAX_INPUT_LENGTH = 512;
  const PATH_PATTERN = /^registrations\/[A-Za-z0-9_-]{1,64}\/[A-Za-z0-9._-]{1,120}$/;
  const ALLOWED_EXTENSIONS = ["jpg", "jpeg", "png", "webp"];
  const PUBLIC_MARKER = "/storage/v1/object/public/employee-photos/";
  const SIGNED_MARKER = "/storage/v1/object/sign/employee-photos/";

  const urlCache = new Map();
  const inflight = new Map();
  const warned = new Set();
  const objectUrls = new Map();
  let generation = 0;
  const renderVersions = new WeakMap();

  function normalizePath(value) {
    const raw = String(value ?? "").trim();
    if (!raw || raw.length > MAX_INPUT_LENGTH) return "";
    if (raw.startsWith("registrations/")) return isWellFormedPath(raw) ? raw : "";
    let candidate = "";
    if (raw.includes(PUBLIC_MARKER)) candidate = raw.split(PUBLIC_MARKER)[1] || "";
    else if (raw.includes(SIGNED_MARKER)) candidate = (raw.split(SIGNED_MARKER)[1] || "").split("?")[0];
    if (!candidate) return "";
    try {
      candidate = decodeURIComponent(candidate);
    } catch {
      return "";
    }
    candidate = candidate.trim();
    return isWellFormedPath(candidate) ? candidate : "";
  }

  function isWellFormedPath(path) {
    if (!PATH_PATTERN.test(path)) return false;
    return ALLOWED_EXTENSIONS.includes(path.split(".").pop().toLowerCase());
  }

  function actorKey(actor) {
    if (!actor || typeof actor !== "object") return "";
    const type = String(actor.type || "");
    const credentials =
      type === "employee" ? [actor.employee_id, actor.mobile_number] :
      type === "guard_device" ? [actor.device_code, actor.device_token] :
      type === "employee_device" ? [actor.device_token, actor.device_id] :
      type === "admin" ? [actor.access_token] : [];
    if (!credentials.length || credentials.some(value => !String(value || "").trim())) return "";
    // Credentials stay only in this page's memory; never log or persist this key.
    return JSON.stringify([type, ...credentials]);
  }

  function endpoint(config) {
    const base = String(config?.SUPABASE_URL || "").replace(/\/+$/, "");
    if (!base) return "";
    return `${base}${RESOLVER_PATH}`;
  }

  function readCached(key) {
    const entry = urlCache.get(key);
    if (!entry) return "";
    if (entry.expiresAt <= Date.now()) {
      urlCache.delete(key);
      return "";
    }
    return entry.url;
  }

  function warnOnce(reason) {
    const key = String(reason || "UNKNOWN");
    if (warned.has(key)) return;
    warned.add(key);
    try {
      console.warn("[employee-photo] resolver denied the request:", key);
    } catch {}
  }

  async function requestResolver(config, payload) {
    const url = endpoint(config);
    const anonKey = String(config?.SUPABASE_ANON_KEY || "");
    if (!url || !anonKey) return null;

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
    try {
      const response = await fetch(url, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          apikey: anonKey,
          authorization: `Bearer ${anonKey}`
        },
        body: JSON.stringify(payload),
        signal: controller.signal
      });
      const data = await response.json().catch(() => null);
      if (!response.ok || !data || data.ok !== true) {
        warnOnce(data?.reason || `HTTP_${response.status}`);
        return null;
      }
      return data;
    } catch {
      return null;
    } finally {
      clearTimeout(timer);
    }
  }

  /**
   * Resolves a photo reference into a short-lived signed URL.
   * Returns "" when the actor is not authorised, the photo is missing, or the
   * resolver is unreachable — callers must always have a fallback.
   */
  async function resolve(value, actor, config, options = {}) {
    const path = normalizePath(value);
    const key = actorKey(actor);
    if (!path || !key) return "";

    const cacheKey = `${key}|${path}`;
    if (options.force !== true) {
      const cached = readCached(cacheKey);
      if (cached) return cached;
    }

    if (inflight.has(cacheKey)) return inflight.get(cacheKey);

    const requestGeneration = generation;
    const requestStart = Date.now();
    const task = (async () => {
      const data = await requestResolver(config, { action: "resolve", path, actor });
      if (!data?.url || requestGeneration !== generation) return "";
      const ttlSeconds = Number(data.expires_in) > 0 ? Number(data.expires_in) : SIGNED_URL_TTL_SECONDS;
      urlCache.set(cacheKey, {
        url: data.url,
        expiresAt: requestStart + ttlSeconds * 1000 - CACHE_SKEW_MS
      });
      return data.url;
    })().finally(() => { if (inflight.get(cacheKey) === task) inflight.delete(cacheKey); });

    inflight.set(cacheKey, task);
    return task;
  }

  function applyFallback(element, fallback) {
    if (fallback) {
      element.src = fallback;
      element.removeAttribute("data-photo-ref");
      return;
    }
    element.removeAttribute("src");
    element.style.display = "none";
  }

  function releaseObjectUrl(element) {
    const previous = objectUrls.get(element);
    if (!previous) return;
    objectUrls.delete(element);
    try {
      URL.revokeObjectURL(previous);
    } catch {}
  }

  function releaseAllObjectUrls() {
    for (const element of Array.from(objectUrls.keys())) {
      releaseObjectUrl(element);
      element.removeAttribute("src");
      element.removeAttribute("href");
      element.src = "";
      element.href = "";
    }
  }

  /**
   * Fetches a signed URL without touching any cache and returns a same-origin
   * blob URL. Returns "" when the browser refuses the fetch (CORS, offline),
   * so the caller can show a placeholder.
   */
  async function fetchAsObjectUrl(url) {
    try {
      const downloadUrl = url + (url.includes('?') ? '&' : '?') + 'cacheNonce=' + encodeURIComponent(crypto.randomUUID());
      const response = await fetch(downloadUrl, {
        cache: "no-store",
        credentials: "omit",
        mode: "cors",
        referrerPolicy: "no-referrer"
      });
      if (!response.ok) return "";
      const blob = await response.blob();
      if (!blob || blob.size === 0) return "";
      return URL.createObjectURL(blob);
    } catch {
      return "";
    }
  }

  /**
   * Displays one resolved photo. The signed URL never becomes the element's
   * src; a failed no-store fetch shows the placeholder.
   */
  async function display(element, url, fallback, renderGeneration, version, isLink = false) {
    if (renderGeneration !== generation || renderVersions.get(element) !== version) return false;
    releaseObjectUrl(element);
    const objectUrl = url ? await fetchAsObjectUrl(url) : "";
    if (renderGeneration !== generation || renderVersions.get(element) !== version) {
      if (objectUrl) URL.revokeObjectURL(objectUrl);
      return false;
    }
    if (!objectUrl) {
      if (isLink) { element.removeAttribute("href"); element.href = ""; }
      else applyFallback(element, fallback);
      return false;
    }
    objectUrls.set(element, objectUrl);
    element[isLink ? "href" : "src"] = objectUrl;
    element.style.display = "";
    element.removeAttribute(isLink ? "data-photo-href" : "data-photo-ref");
    return true;
  }

  /**
   * Resolves every [data-photo-ref] element inside `root`.
   * `data-photo-fallback` keeps its current visual behaviour when resolution
   * fails (for example "./logo.jpeg" on the guard screen).
   * `data-photo-href` elements (thumbnails wrapped in a link) receive the
   * blob URL as their href.
   */
  async function hydrate(root, actor, config, options = {}) {
    const scope = root || document;
    const elements = Array.from(scope.querySelectorAll("[data-photo-ref]"));
    const links = Array.from(scope.querySelectorAll("[data-photo-href]"));
    if (scope.matches && scope.matches("[data-photo-ref]")) elements.unshift(scope);
    if (scope.matches && scope.matches("[data-photo-href]")) links.unshift(scope);
    const renderGeneration = generation;
    await Promise.all([
      ...elements.map(async (element) => {
        const version = (renderVersions.get(element) || 0) + 1;
        renderVersions.set(element, version);
        const reference = element.getAttribute("data-photo-ref");
        const fallback = element.getAttribute("data-photo-fallback") || "";
        const url = await resolve(reference, actor, config, options);
        await display(element, url, fallback, renderGeneration, version);
      }),
      ...links.map(async (element) => {
        const version = (renderVersions.get(element) || 0) + 1;
        renderVersions.set(element, version);
        const url = await resolve(element.getAttribute("data-photo-href"), actor, config, options);
        await display(element, url, "", renderGeneration, version, true);
      })
    ]);
    return elements.length + links.length;
  }

  function peek(value, actor) {
    const path = normalizePath(value);
    const key = actorKey(actor);
    if (!path || !key) return "";
    return readCached(`${key}|${path}`);
  }

  function clearCache() {
    generation += 1;
    releaseAllObjectUrls();
    urlCache.clear();
    inflight.clear();
  }

  window.EmployeePhoto = {
    normalizePath,
    resolve,
    hydrate,
    peek,
    clearCache,
    SIGNED_URL_TTL_SECONDS,
    CACHE_SKEW_MS,
    RESOLVER_PATH
  };
})();
