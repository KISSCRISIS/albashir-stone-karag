const CACHE_VERSION = "emergency-room-parking-offline-v25";

const OFFLINE_ASSETS = [
  "./index.html",
  "./portal.html",
  "./verify.html",
  "./profile.html",
  "./login.html",
  "./admin_dashboard.html",
  "./global-leadership.js",
  "./global-theme.css",
  "./access-control.js",
  "./app-runtime.js",
  "./manifest.json",
  "./qrcode.min.js",
  "./jsqr.min.js",
  "./supabase.min.js",
  "./favicon.svg",
  "./albashir-gate-logo.png",
  "./hospital-hero.png",
  "./logo.jpeg",
  "./hero.jpeg",
  "./assets/js/ui-components.js",
  "./assets/js/app-state.js",
  "./assets/css/responsive.css",
  "./assets/css/components.css",
  "./assets/css/design-system.css",
  "./index.css",
  "./verify.css",
  "./admin_dashboard.css",
  "./portal.css",
  "./profile.css",
  "./verify-shared.js",
  "./employee-photo.js",

  "./register.html"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_VERSION).then((cache) =>
      Promise.all(
        OFFLINE_ASSETS.map((asset) =>
          cache.add(asset).catch((error) => {
            console.warn("[SW] Failed to cache asset:", asset, error);
            return null;
          })
        )
      )
    )
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys
          .filter((key) => key !== CACHE_VERSION)
          .map((key) => caches.delete(key))
      )
    )
  );
  self.clients.claim();
});

self.addEventListener("message", (event) => {
  if (event.data && event.data.type === "SKIP_WAITING") {
    self.skipWaiting();
  }
});

// Only these static assets may be persisted offline. Never cache URLs carrying
// QR tokens, query credentials, authenticated responses or arbitrary GET data.
const STATIC_ASSET_PATHS = new Set(OFFLINE_ASSETS.map(asset =>
  new URL(asset, self.location.href).pathname
));
const OFFLINE_PAGE_PATHS = new Set(
  OFFLINE_ASSETS.filter(asset => asset.endsWith(".html")).map(asset =>
    new URL(asset, self.location.href).pathname
  )
);
function cacheable(response) {
  const policy = response.headers?.get("cache-control") || "";
  return response.status === 200 && !/\b(?:no-store|private)\b/i.test(policy);
}
self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  // Explicitly bypass Supabase auth, database, storage and edge-function traffic.
  if (url.hostname.endsWith(".supabase.co")) {
    event.respondWith(fetch(request));
    return;
  }
  if (url.origin !== self.location.origin) return;
  if (url.pathname.startsWith("/auth/") || url.pathname.startsWith("/rest/") ||
      url.pathname.startsWith("/storage/") || url.pathname.startsWith("/functions/")) return;

  if (request.mode === "navigate") {
    const isRoot = url.pathname === "/";
    const pagePath = isRoot ? new URL("./portal.html", self.location.href).pathname : url.pathname;
    // QR tokens in navigation query strings must never be persisted.
    const canCache = !url.search && OFFLINE_PAGE_PATHS.has(pagePath);
    event.respondWith(
      fetch(request).then(response => {
        if (canCache && cacheable(response)) {
          event.waitUntil(caches.open(CACHE_VERSION).then(cache =>
            cache.put(pagePath, response.clone())
          ).catch(error => console.warn("[SW] Page cache write failed", error)));
        }
        return response;
      }).catch(async () => {
        if (canCache || isRoot) {
          const cached = await caches.match(pagePath);
          if (cached) return cached;
        }
        // Never substitute a cached page for a credential-bearing QR URL.
        return Response.error();
      })
    );
    return;
  }
  if (!url.search && STATIC_ASSET_PATHS.has(url.pathname)) {
    event.respondWith(
      fetch(request).then(response => {
        if (cacheable(response)) {
          event.waitUntil(caches.open(CACHE_VERSION).then(cache =>
            cache.put(url.pathname, response.clone())
          ).catch(error => console.warn("[SW] Asset cache write failed", error)));
        }
        return response;
      }).catch(async () => {
        const cached = await caches.match(url.pathname);
        if (cached) return cached;
        return Response.error();
      })
    );
  }
});
