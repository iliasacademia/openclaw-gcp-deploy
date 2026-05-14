'use strict';

// deploy.sh embeds a single-use setup token in the URL. Without it, the
// server rejects every API call.
const SETUP_TOKEN = new URLSearchParams(window.location.search).get('token') || '';

let previousScreenId = null;

// ── Screens ──────────────────────────────────────────────────────────────────
function showScreen(id) {
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  const el = document.getElementById(id);
  if (el) el.classList.add('active');
}

function setBadge(text, cls) {
  const b = document.getElementById('status-badge');
  if (!b) return;
  b.textContent = text;
  b.className   = 'badge ' + (cls || '');
}

// ── API ──────────────────────────────────────────────────────────────────────
async function api(path, options = {}) {
  const sep = path.includes('?') ? '&' : '?';
  const url = `${path}${sep}token=${encodeURIComponent(SETUP_TOKEN)}`;
  return fetch(url, options);
}

// ── Init ─────────────────────────────────────────────────────────────────────
async function init() {
  if (!SETUP_TOKEN) {
    showScreen('screen-unauthorized');
    setBadge('No token', 'error');
    return;
  }

  showScreen('screen-loading');
  setBadge('Connecting…', 'starting');

  try {
    const res = await api('/api/status');

    if (res.status === 403) {
      showScreen('screen-unauthorized');
      setBadge('Unauthorized', 'error');
      return;
    }

    const data = await res.json();

    if (data.startupFailure) {
      setBadge('Boot failed', 'error');
      showDiagnostics();
      return;
    }

    if (data.openclawRunning) setBadge('Running', 'running');
    else                      setBadge('Starting…', 'starting');

    setDashboardLink(data.dashboardUrl);

    if (data.telegramConfigured) {
      showScreen('screen-done');
    } else {
      showScreen('screen-telegram');
    }
  } catch (err) {
    console.error('Status check failed:', err);
    setBadge('Error', 'error');
    showScreen('screen-telegram');
  }
}

// ── Telegram form ────────────────────────────────────────────────────────────
function clearError() {
  const err = document.getElementById('telegram-error');
  const inp = document.getElementById('telegram-token');
  if (err) { err.textContent = ''; err.classList.add('hidden'); }
  if (inp) inp.classList.remove('error');
}

function showError(msg) {
  const err = document.getElementById('telegram-error');
  const inp = document.getElementById('telegram-token');
  if (err) { err.textContent = msg; err.classList.remove('hidden'); }
  if (inp) inp.classList.add('error');
}

async function submitTelegram() {
  clearError();

  const inp   = document.getElementById('telegram-token');
  const btn   = document.getElementById('btn-telegram');
  const token = (inp?.value || '').trim();

  if (!token) {
    showError('Please paste your bot token before continuing.');
    inp?.focus();
    return;
  }

  btn.disabled    = true;
  btn.textContent = 'Connecting…';

  try {
    const res  = await api('/api/telegram', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ token }),
    });
    const data = await res.json();

    if (!res.ok || data.error) {
      showError(data.error || 'Something went wrong — please check the token and try again.');
      btn.disabled    = false;
      btn.textContent = 'Connect →';
      return;
    }

    setBadge('Running', 'running');
    setDashboardLink(data.dashboardUrl);
    showScreen('screen-done');

  } catch (err) {
    showError('Network error — is OpenClaw still starting? Wait 30 seconds and try again.');
    btn.disabled    = false;
    btn.textContent = 'Connect →';
  }
}

function setDashboardLink(url) {
  const a = document.getElementById('dashboard-link');
  if (a && url) a.href = url;
}

// ── Diagnostics ──────────────────────────────────────────────────────────────
function showDiagnostics(ev) {
  if (ev) ev.preventDefault();
  const current = document.querySelector('.screen.active');
  previousScreenId = current ? current.id : 'screen-telegram';
  showScreen('screen-diagnostics');
  loadDiagnostics();
}

function hideDiagnostics() {
  showScreen(previousScreenId || 'screen-telegram');
}

async function loadDiagnostics() {
  setText('diag-gateway',       'Loading…');
  setText('diag-vm',            'Loading…');
  setText('diag-log-gateway',   'Loading…');
  setText('diag-log-startup',   'Loading…');
  setText('diag-log-setup',     'Loading…');
  setText('diag-config',        'Loading…');

  try {
    const res = await api('/api/diagnostics');
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const d = await res.json();

    const failureEl = document.getElementById('diag-failure');
    if (d.startupFailure) {
      failureEl.textContent = 'Startup failed on the VM: ' + d.startupFailure;
      failureEl.classList.remove('hidden');
    } else {
      failureEl.classList.add('hidden');
    }

    setText('diag-gateway',
      `Service:    ${d.gateway?.serviceName || '-'}\n` +
      `State:      ${d.gateway?.activeRaw  || '-'}\n` +
      `Details:    ${d.gateway?.details    || '-'}\n` +
      `Dashboard:  ${d.dashboardUrl}`);

    setText('diag-vm',
      `IP:         ${d.vmIp}\n` +
      `Project:    ${d.projectId}\n` +
      `Region:     ${d.region}\n` +
      `Wizard ver: ${d.setupServerVersion || '?'}\n` +
      `Time:       ${d.timestamp}`);

    setText('diag-log-gateway', d.logs?.gateway || '(no logs yet)');
    setText('diag-log-startup', d.logs?.startup || '(no startup log)');
    setText('diag-log-setup',   d.logs?.setup   || '(no setup-wizard log)');
    setText('diag-config',      d.config ? JSON.stringify(d.config, null, 2) : '(no config)');

  } catch (err) {
    setText('diag-gateway', 'Failed to load diagnostics: ' + err.message);
  }
}

function setText(id, text) {
  const el = document.getElementById(id);
  if (el) el.textContent = text;
}

// ── Wire up Enter key + init ─────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
  const inp = document.getElementById('telegram-token');
  if (inp) {
    inp.addEventListener('keydown', e => { if (e.key === 'Enter') submitTelegram(); });
    inp.addEventListener('input', clearError);
  }
  init();
});
