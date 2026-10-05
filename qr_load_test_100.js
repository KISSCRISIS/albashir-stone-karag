/*
  QR load test for ALBASHIR EMERGENCY HOSPITAL Gate.

  This script is intentionally disabled by default because it creates real
  QR sessions in Supabase. Run it only against a staging project or during
  an approved production maintenance window.

  PowerShell example:
    $env:RUN_REAL_LOAD_TEST="1"
    $env:SUPABASE_URL="https://PROJECT.supabase.co"
    $env:SUPABASE_ANON_KEY="ANON_KEY"
    node qr_load_test_100.js
*/

const CONCURRENCY = Number(process.env.CONCURRENCY || 100);
const RUN_REAL_LOAD_TEST = process.env.RUN_REAL_LOAD_TEST === "1";
const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;
const GATE_DEVICE_CODE = process.env.GATE_DEVICE_CODE;
const GATE_DEVICE_TOKEN = process.env.GATE_DEVICE_TOKEN;

function percentile(values, p) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return sorted[index];
}

async function createQrSession(index) {
  const startedAt = performance.now();
  const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/create_qr_session`, {
    method: "POST",
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      p_device_code: GATE_DEVICE_CODE,
      p_device_token: GATE_DEVICE_TOKEN
    })
  });
  const durationMs = Math.round(performance.now() - startedAt);
  const text = await response.text();
  let payload = null;
  try {
    payload = text ? JSON.parse(text) : null;
  } catch {
    payload = text;
  }
  return {
    index,
    ok: response.ok && (payload?.ok === true || payload?.create_qr_session?.ok === true),
    status: response.status,
    durationMs,
    payload
  };
}

async function main() {
  if (!RUN_REAL_LOAD_TEST) {
    console.log(JSON.stringify({
      ok: false,
      skipped: true,
      reason: "Set RUN_REAL_LOAD_TEST=1 to run the real Supabase 100 QR concurrency test.",
      concurrency: CONCURRENCY
    }, null, 2));
    return;
  }

  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !GATE_DEVICE_CODE || !GATE_DEVICE_TOKEN) {
    throw new Error("SUPABASE_URL, SUPABASE_ANON_KEY, GATE_DEVICE_CODE, and GATE_DEVICE_TOKEN are required.");
  }

  const startedAt = performance.now();
  const results = await Promise.allSettled(
    Array.from({ length: CONCURRENCY }, (_, index) => createQrSession(index + 1))
  );

  const fulfilled = results.filter((item) => item.status === "fulfilled").map((item) => item.value);
  const rejected = results.filter((item) => item.status === "rejected");
  const success = fulfilled.filter((item) => item.ok);
  const durations = fulfilled.map((item) => item.durationMs);

  console.log(JSON.stringify({
    ok: rejected.length === 0 && success.length === CONCURRENCY,
    total: CONCURRENCY,
    success: success.length,
    failed: CONCURRENCY - success.length,
    rejected: rejected.length,
    totalDurationMs: Math.round(performance.now() - startedAt),
    latencyMs: {
      min: Math.min(...durations),
      p50: percentile(durations, 50),
      p95: percentile(durations, 95),
      max: Math.max(...durations)
    },
    nonOkSamples: fulfilled.filter((item) => !item.ok).slice(0, 5)
  }, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
