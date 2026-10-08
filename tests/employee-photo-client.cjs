// ============================================================================
// employee-photo-client.cjs
//
// Behaviour of the shared browser client (employee-photo.js) with a fake DOM,
// a fake fetch and a fake clock. No browser, no network and no Production call.
//
// Focus: a signed URL is a temporary credential, so it must never be written to
// a cache or to persistent storage.
// ============================================================================
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const SOURCE = fs.readFileSync(path.join(__dirname, "../employee-photo.js"), "utf8");

const OWN_PATH = "registrations/80632/1790627850001-7df3b32a22b418.jpeg";
const SIGNED_URL =
  "https://qinsfvlspdticposbvst.supabase.co/storage/v1/object/sign/employee-photos/" +
  OWN_PATH +
  "?token=abc.def";
const CONFIG = {
  SUPABASE_URL: "https://qinsfvlspdticposbvst.supabase.co",
  SUPABASE_ANON_KEY: "sb_publishable_test"
};
const ACTOR = { type: "employee", employee_id: "80632", mobile_number: "0790000000" };

function makeElement(attributes = {}) {
  const map = new Map(Object.entries(attributes));
  return {
    src: "",
    href: "",
    style: {},
    getAttribute(key) {
      return map.has(key) ? map.get(key) : null;
    },
    setAttribute(key, value) {
      map.set(key, String(value));
    },
    removeAttribute(key) {
      map.delete(key);
    },
    matches() {
      return false;
    },
    attributes: map
  };
}

function makeRoot(elements = [], links = []) {
  return {
    querySelectorAll(selector) {
      if (selector === "[data-photo-ref]") return elements;
      if (selector === "[data-photo-href]") return links;
      return [];
    },
    matches() {
      return false;
    }
  };
}

function load({ resolverResponse, imageFails = false, now } = {}) {
  const calls = { resolver: [], image: [] };
  const created = [];
  const revoked = [];
  const clock = { value: now ?? Date.parse("2026-10-06T12:00:00.000Z") };

  const context = {
    console: { warn() {}, log() {}, error() {} },
    setTimeout,
    clearTimeout,
    AbortController,
    crypto: require('node:crypto').webcrypto,
    Promise,
    Map,
    Set,
    JSON,
    Number,
    String,
    Array,
    Object,
    Error,
    Date: { now: () => clock.value }
  };
  context.window = context;
  context.URL = {
    createObjectURL(blob) {
      const url = `blob:https://gate.test/${created.length}`;
      created.push({ url, blob });
      return url;
    },
    revokeObjectURL(url) {
      revoked.push(url);
    }
  };
  // Any attempt to persist the credential is a test failure.
  Object.defineProperty(context, "localStorage", {
    get() {
      throw new Error("localStorage must never be used");
    }
  });
  Object.defineProperty(context, "sessionStorage", {
    get() {
      throw new Error("sessionStorage must never be used");
    }
  });
  Object.defineProperty(context, "document", {
    get() {
      throw new Error("document must not be touched when a root element is supplied");
    }
  });

  context.fetch = async (target, options = {}) => {
    const url = String(target);
    if (url.includes("/functions/v1/employee-photo-url")) {
      calls.resolver.push({ url, options, body: JSON.parse(options.body || "{}") });
      const payload =
        typeof resolverResponse === "function" ? resolverResponse(calls.resolver.length) : resolverResponse;
      if (payload === null) throw new Error("resolver unreachable");
      const status = payload.status ?? 200;
      return {
        ok: status < 400,
        status,
        json: async () => payload.body ?? payload
      };
    }
    calls.image.push({ url, options });
    if (imageFails) throw new Error("CORS blocked the no-store fetch");
    return { ok: true, status: 200, blob: async () => ({ size: 2048 }) };
  };

  vm.createContext(context);
  vm.runInContext(SOURCE, context);
  return { client: context.EmployeePhoto, calls, created, revoked, clock, context };
}

const okPayload = (overrides = {}) => ({
  ok: true,
  url: SIGNED_URL,
  expires_in: 60,
  expires_at: "2026-10-06T12:01:00.000Z",
  ...overrides
});

(async () => {
  // ------------------------------------------------------------ resolver call shape
  {
    const { client, calls } = load({ resolverResponse: okPayload() });
    const url = await client.resolve(OWN_PATH, ACTOR, CONFIG);
    assert.equal(url, SIGNED_URL);
    assert.equal(calls.resolver.length, 1);
    assert.equal(calls.resolver[0].options.method, "POST");
    assert.equal(calls.resolver[0].options.headers.apikey, CONFIG.SUPABASE_ANON_KEY);
    assert.deepEqual(calls.resolver[0].body, { action: "resolve", path: OWN_PATH, actor: ACTOR });
    console.log("PASS resolve() calls the resolver once with the actor and path");
  }

  // ------------------------------------------------------------ no-store blob display
  {
    const { client, calls, created } = load({ resolverResponse: okPayload() });
    const element = makeElement({ "data-photo-ref": OWN_PATH, "data-photo-fallback": "./logo.jpeg" });
    await client.hydrate(makeRoot([element]), ACTOR, CONFIG);

    assert.equal(element.src, created[0].url, "the element must display the blob URL");
    assert.ok(element.src.startsWith("blob:"), "the signed URL must not become the element src");
    assert.equal(element.getAttribute("data-photo-ref"), null, "the reference is consumed");
    assert.equal(element.getAttribute("data-photo-fallback"), "./logo.jpeg", "the fallback attribute is preserved");

    assert.equal(calls.image.length, 1);
    assert.equal(new URL(calls.image[0].url).searchParams.get('token'), new URL(SIGNED_URL).searchParams.get('token'));
    assert.ok(new URL(calls.image[0].url).searchParams.get('cacheNonce'));
    assert.notEqual(calls.image[0].url, SIGNED_URL);
    assert.equal(calls.image[0].options.cache, "no-store", "the signed URL must bypass the browser cache");
    assert.equal(calls.image[0].options.credentials, "omit");
    assert.equal(calls.image[0].options.referrerPolicy, "no-referrer");
    console.log("PASS signed URLs are fetched with cache:no-store and displayed as a blob URL");
  }
  {
    const { client, calls, created } = load({ resolverResponse: okPayload(), imageFails: true });
    const element = makeElement({ "data-photo-ref": OWN_PATH, "data-photo-fallback": "./logo.jpeg" });
    await client.hydrate(makeRoot([element]), ACTOR, CONFIG);
    assert.equal(element.src, "./logo.jpeg", "a blocked no-store fetch must show the placeholder");
    assert.equal(created.length, 0);
    assert.equal(calls.image[0].options.cache, "no-store");
    console.log("PASS a blocked no-store fetch shows the placeholder");
  }
  {
    const { client, created } = load({ resolverResponse: okPayload() });
    const link = makeElement({ "data-photo-href": OWN_PATH });
    const element = makeElement({ "data-photo-ref": OWN_PATH });
    await client.hydrate(makeRoot([element], [link]), ACTOR, CONFIG);
    assert.ok(link.href.startsWith("blob:"), "thumbnail links must use a no-store blob");
    assert.equal(link.getAttribute("data-photo-href"), null);
    assert.equal(created.length, 2, "images and links both use blob URLs");
    console.log("PASS thumbnail links and images both use blob URLs");
  }

  // ------------------------------------------------------------ denials and fallbacks
  {
    const { client, calls } = load({ resolverResponse: { status: 403, body: { ok: false, error: "DENIED" } } });
    const element = makeElement({ "data-photo-ref": OWN_PATH, "data-photo-fallback": "./logo.jpeg" });
    await client.hydrate(makeRoot([element]), ACTOR, CONFIG);
    assert.equal(element.src, "./logo.jpeg", "a denied photo falls back and never reaches storage");
    assert.equal(calls.image.length, 0, "no image request is made for a denied reference");
    console.log("PASS denied photos never trigger a storage request");
  }
  {
    const { client, calls } = load({ resolverResponse: { status: 403, body: { ok: false, error: "DENIED" } } });
    const element = makeElement({ "data-photo-ref": OWN_PATH });
    await client.hydrate(makeRoot([element]), ACTOR, CONFIG);
    assert.equal(element.src, "", "without a fallback the image stays empty");
    assert.equal(element.style.display, "none", "and it is hidden instead of showing a broken image");
    assert.equal(calls.image.length, 0);
    console.log("PASS a denied photo without fallback is hidden");
  }

  // ------------------------------------------------------------ lifetime and cleanup
  {
    const { client, calls, clock } = load({ resolverResponse: okPayload() });
    const root = makeRoot([makeElement({ "data-photo-ref": OWN_PATH })]);
    await client.hydrate(root, ACTOR, CONFIG);
    await client.hydrate(makeRoot([makeElement({ "data-photo-ref": OWN_PATH })]), ACTOR, CONFIG);
    assert.equal(calls.resolver.length, 1, "a URL still valid is reused instead of re-minted");

    clock.value += 51 * 1000; // past the 50s usable window (60s TTL - 10s skew)
    await client.hydrate(makeRoot([makeElement({ "data-photo-ref": OWN_PATH })]), ACTOR, CONFIG);
    assert.equal(calls.resolver.length, 2, "an expired URL is never reused");
    console.log("PASS the in-memory cache expires 10s before the 60s signed URL does");
  }
  {
    const { client, created, revoked } = load({ resolverResponse: okPayload() });
    const element = makeElement({ "data-photo-ref": OWN_PATH });
    await client.hydrate(makeRoot([element]), ACTOR, CONFIG);
    client.clearCache();
    assert.deepEqual(revoked, [created[0].url], "blob URLs are revoked when the cache is cleared");
    console.log("PASS clearCache() revokes the blob URLs it created");
  }
  {
    const { client, created, revoked } = load({ resolverResponse: okPayload() });
    const element = makeElement({ "data-photo-ref": OWN_PATH });
    await client.hydrate(makeRoot([element]), ACTOR, CONFIG);
    // Re-rendering the same element (for example after a data refresh) must not
    // leak the previous blob URL.
    element.setAttribute("data-photo-ref", OWN_PATH);
    await client.hydrate(makeRoot([element]), ACTOR, CONFIG);
    assert.equal(created.length, 2, "re-displaying fetches again because the old URL was released");
    assert.deepEqual(revoked, [created[0].url], "the replaced blob URL is revoked");
    console.log("PASS re-displaying an element releases its previous blob URL");
  }

  {
    const { client, calls } = load({ resolverResponse: okPayload() });
    await client.resolve(OWN_PATH, ACTOR, CONFIG);
    await client.resolve(OWN_PATH, { ...ACTOR, mobile_number: "invalid" }, CONFIG);
    assert.equal(calls.resolver.length, 2, "changed credentials require a new authorization request");
    console.log("PASS credential changes cannot reuse prior authorization cache");
  }
  {
    const { client, context } = load({ resolverResponse: okPayload() });
    let release;
    context.fetch = () => new Promise(resolve => { release = resolve; });
    const pending = client.resolve(OWN_PATH, ACTOR, CONFIG);
    client.clearCache();
    release({ ok: true, json: async () => okPayload() });
    assert.equal(await pending, "");
    assert.equal(client.peek(OWN_PATH, ACTOR), "");
    console.log("PASS logout invalidates pending resolver results");
  }
  {
    const { client, context, revoked } = load({ resolverResponse: okPayload() });
    const originalFetch = context.fetch;
    let release;
    context.fetch = (url, options) => String(url).includes("/functions/")
      ? originalFetch(url, options)
      : new Promise(resolve => { release = resolve; });
    const element = makeElement({ "data-photo-ref": OWN_PATH });
    const pending = client.hydrate(makeRoot([element]), ACTOR, CONFIG);
    while (!release) await Promise.resolve();
    client.clearCache();
    release({ ok: true, blob: async () => ({ size: 100 }) });
    await pending;
    assert.equal(element.src, "");
    assert.equal(revoked.length, 1);
    console.log("PASS logout during image fetch prevents stale display and releases blob");
  }
  {
    const { client, calls } = load({ resolverResponse: okPayload() });
    await client.resolve(OWN_PATH, {type:"employee_device",device_token:"TOKEN",device_id:"device-A"}, CONFIG);
    await client.resolve(OWN_PATH, {type:"employee_device",device_token:"TOKEN",device_id:"device-B"}, CONFIG);
    assert.equal(calls.resolver.length, 2, "a copied token with another device ID cannot reuse authorized cache");
    assert.equal(await client.resolve(OWN_PATH, {type:"employee_device",device_token:"TOKEN"}, CONFIG), "");
    console.log("PASS device identity participates in photo authorization cache; missing identity denied locally");
  }
  console.log("\nAll employee-photo client cache tests passed.");
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
