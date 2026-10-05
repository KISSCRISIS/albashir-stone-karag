const CACHE_VERSION = "emergency-room-parking-offline-v16";

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
  "./guard.html",
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
    event.respondWith(
      fetch(request)
        .then((response) => {
          const responseCopy = response.clone();
          caches.open(CACHE_VERSION).then((cache) => cache.put(request, responseCopy));
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
            "guard.html",
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
            caches.open(CACHE_VERSION).then((cache) => cache.put(request, responseCopy));
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

  event.respondWith(
    caches.match(request).then((cached) => {
      if (cached) return cached;

      return fetch(request).then((response) => {
        if (response && response.status === 200) {
          const responseCopy = response.clone();
          caches.open(CACHE_VERSION).then((cache) => cache.put(request, responseCopy));
        }
        return response;
      });
    })
  );
});
