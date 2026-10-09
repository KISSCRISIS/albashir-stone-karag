(function () {
  'use strict';
  const states = { connection: navigator.onLine ? 'unknown' : 'offline', photo: 'unknown' };
  const TIMEOUT_MS = 8000;
  async function fetchWithTimeout(input, options = {}) {
    const controller = new AbortController();
    const backendRequest = /^https:\/\/[^/]+\.supabase\.co(?:\/|$)/.test(String(input));
    const abort = () => controller.abort();
    if (options.signal?.aborted) abort();
    options.signal?.addEventListener('abort', abort, { once: true });
    const timer = setTimeout(abort, TIMEOUT_MS);
    try {
      const response = await fetch(input, { ...options, signal: controller.signal });
      // Keep the deadline active until the body arrives, preserving the original Response for the SDK.
      if (typeof response.clone === 'function') await response.clone().arrayBuffer();
      if (backendRequest) report('connection', response.ok ? 'ready' : 'failed');
      return response;
    } catch (error) {
      if (backendRequest) report('connection', 'failed');
      if (controller.signal.aborted && !options.signal?.aborted) {
        throw new Error('NETWORK_TIMEOUT: انتهت مهلة الاتصال. أعد المحاولة.');
      }
      throw error;
    } finally {
      clearTimeout(timer);
      options.signal?.removeEventListener('abort', abort);
    }
  }
  function errorMessage(error, fallback) {
    const message = String(error?.message || '');
    return /NETWORK_TIMEOUT|RPC_TIMEOUT|AbortError|timeout/i.test(message)
      ? 'انتهت مهلة الاتصال. أعد المحاولة.' : message || fallback;
  }
  function report(kind, state) {
    if (!['connection', 'photo'].includes(kind) || !['ready', 'failed', 'offline', 'unknown'].includes(state)) return;
    states[kind] = state;
    const target = document.getElementById('appDiagnosticState');
    if (target) target.textContent = `الاتصال: ${navigator.onLine ? ({ready:'جاهز',failed:'تعذر آخر طلب',unknown:'غير مفحوص',offline:'غير متصل'}[states.connection]) : 'غير متصل'} — الصور: ${{ready:'آخر تحميل ناجح',failed:'تعذر آخر تحميل',unknown:'لم تُفحص',offline:'غير متصل'}[states.photo]}`;
  }
  async function showDiagnostics() {
    const target = document.getElementById('appVersion');
    if (!target) return;
    try {
      const response = await fetchWithTimeout('./app-version.json', { cache: 'no-store' });
      if (!response.ok) throw new Error('Version unavailable');
      const data = await response.json();
      target.textContent = /^[a-f0-9]{7,40}$/.test(data.version) ? data.version : 'غير متوفر';
    } catch (_) { target.textContent = 'غير متوفر'; }
    report('connection', states.connection);
  }
  window.ALBASHIRRuntime = { fetchWithTimeout, errorMessage, report };
  window.addEventListener('online', () => report('connection', 'unknown'));
  window.addEventListener('offline', () => report('connection', 'offline'));
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', showDiagnostics, { once: true });
  else showDiagnostics();
})();
