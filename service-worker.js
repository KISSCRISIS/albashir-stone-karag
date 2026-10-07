const CACHE_VERSION = "emergency-room-parking-offline-v20";

const OFFLINE_ASSETS = [
  "./",
  "./index.html",
  "./portal.html",
  "./verify.html",
  "./profile.html",
  "./login.html",
  "./admin_dashboard.html",
  "./global-leadership.js",
  "./global-theme.css",
  "./access-control.js",
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

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;

  const request = event.request;
  const url = new URL(request.url);

  // Authentication and database responses must always come from Supabase.
  if (
    url.hostname.endsWith(".supabase.co") ||
    url.pathname.startsWith("/auth/") ||
    url.pathname.startsWith("/rest/") ||
    url.pathname.startsWith("/storage/")
  ) {
    event.respondWith(fetch(request));
    return;
  }

  if (request.mode === "navigate") {
    // Cache the page shell, never the QR/session credentials in its query.
    const pageKey = new URL(url.pathname, url.origin).href;
    event.respondWith(
      fetch(request)
        .then((response) => {
          const responseCopy = response.clone();
          if (response.status === 200) event.waitUntil(
            caches.open(CACHE_VERSION).then((cache) => cache.put(pageKey, responseCopy))
              .catch((error) => console.warn("[SW] Page cache write failed", error))
          );
          return response;
        })
        .catch(async () => {
          const cached = await caches.match(request, { ignoreSearch: true });
          if (cached) return cached;

          const page = url.pathname.split("/").pop() || "portal.html";
          const allowedPages = new Set([
            "index.html",
            "portal.html",
            "verify.html",
            "profile.html",
            "login.html",
            "admin_dashboard.html",
            "register.html"
          ]);
          return caches.match(allowedPages.has(page) ? `./${page}` : "./portal.html");
        })
    );
    return;
  }

  if (url.origin === self.location.origin) {
    event.respondWith(
      fetch(request)
        .then((response) => {
          if (response && response.status === 200) {
            const responseCopy = response.clone();
            event.waitUntil(caches.open(CACHE_VERSION).then((cache) => cache.put(request, responseCopy))
              .catch((error) => console.warn("[SW] Asset cache write failed", error)));
          }
          return response;
        })
        .catch(async () => {
          const cached = await caches.match(request, { ignoreSearch: true });
          if (cached) return cached;
          throw new Error("Offline asset unavailable");
        })
    );
    return;
  }

  // Third-party responses may carry credentials; never persist them.
  event.respondWith(fetch(request));
});
