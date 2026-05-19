'use strict';

// deploy.sh embeds a single-use setup token in the URL. Without it, the
// server rejects every API call.
const SETUP_TOKEN = new URLSearchParams(window.location.search).get('token') || '';

const LS_BOT_USERNAME = 'openclaw.botUsername';

let previousScreenId = null;
let pairingPollTimer = null;
let pairingPollCount = 0;
let readyPollTimer   = null;
let readyPollCount   = 0;
let currentPairingCode = null;
let cachedProjectId    = null;
let cachedHttpDashboardUrl = null;

// Timeouts: after this many polls (each ~3s), show a fallback UI instead of
// spinning forever. 60 × 3s = 3 min for pairing; 100 × 3s = 5 min for the
// TLS cert (Let's Encrypt can sometimes take a couple of minutes if it
// retries internally).
const PAIRING_POLL_TIMEOUT_TICKS = 60;
const READY_POLL_TIMEOUT_TICKS   = 100;

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

    // Distinguish between "still booting" and "actually broken". A failed
    // service in a restart loop should NOT look like "starting" to the user.
    const gwState = (data.gatewayActiveState || '').trim();
    if (data.openclawRunning) {
      setBadge('Running', 'running');
    } else if (gwState === 'failed' || gwState === 'inactive') {
      setBadge('Gateway failed', 'error');
    } else if (gwState === 'activating') {
      setBadge('Starting…', 'starting');
    } else {
      setBadge('Starting…', 'starting');
    }

    cachedProjectId = data.projectId;
    setDashboardLink(data.dashboardUrl);
    setOauthLinks(data.projectId);

    if (data.telegramConfigured) {
      // Telegram is wired up, but the user may not have paired yet. Route to
      // the pairing step, which auto-advances when they hit Approve or Skip.
      enterPairingScreen();
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
function clearTelegramError() {
  const err = document.getElementById('telegram-error');
  const inp = document.getElementById('telegram-token');
  if (err) { err.textContent = ''; err.classList.add('hidden'); }
  if (inp) inp.classList.remove('error');
}

function showTelegramError(msg) {
  const err = document.getElementById('telegram-error');
  const inp = document.getElementById('telegram-token');
  if (err) { err.textContent = msg; err.classList.remove('hidden'); }
  if (inp) inp.classList.add('error');
}

async function submitTelegram() {
  clearTelegramError();

  const inp   = document.getElementById('telegram-token');
  const btn   = document.getElementById('btn-telegram');
  const token = (inp?.value || '').trim();

  if (!token) {
    showTelegramError('Please paste your bot token before continuing.');
    inp?.focus();
    return;
  }

  // Loading state: keep user informed about what we're doing. This call
  // does (1) write the config, (2) restart the gateway, (3) look up the bot
  // username on Telegram. 1-2 seconds typically.
  btn.disabled    = true;
  btn.textContent = 'Connecting your bot…';

  try {
    const res  = await api('/api/telegram', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ token }),
    });
    const data = await res.json();

    if (!res.ok || data.error) {
      showTelegramError(data.error || 'Something went wrong — please check the token and try again.');
      btn.disabled    = false;
      btn.textContent = 'Connect →';
      return;
    }

    setBadge('Running', 'running');
    setDashboardLink(data.dashboardUrl);
    if (data.projectId) {
      cachedProjectId = data.projectId;
      setOauthLinks(data.projectId);
    }
    if (data.botUsername) {
      try { localStorage.setItem(LS_BOT_USERNAME, data.botUsername); } catch {}
    }
    // Don't go straight to "done" — the user still has to send /start and
    // approve their pairing for the bot to actually respond.
    enterPairingScreen();

  } catch (err) {
    showTelegramError('Network error — is OpenClaw still starting? Wait 30 seconds and try again.');
    btn.disabled    = false;
    btn.textContent = 'Connect →';
  }
}

function setDashboardLink(url) {
  const a = document.getElementById('dashboard-link');
  if (a && url) a.href = url;
  const a2 = document.getElementById('g-open-dashboard');
  if (a2 && url) a2.href = url;
}

// ── Pairing flow ─────────────────────────────────────────────────────────────
function enterPairingScreen() {
  showScreen('screen-pairing');
  setBadge('Running', 'running');
  document.getElementById('pairing-waiting').classList.remove('hidden');
  document.getElementById('pairing-pending').classList.add('hidden');
  document.getElementById('pairing-timeout').classList.add('hidden');
  currentPairingCode = null;
  pairingPollCount   = 0;
  populateBotLink();
  pollForPairings();
}

function retryPairingPoll() {
  pairingPollCount = 0;
  document.getElementById('pairing-timeout').classList.add('hidden');
  document.getElementById('pairing-waiting').classList.remove('hidden');
  pollForPairings();
}

function restartTelegram(ev) {
  if (ev) ev.preventDefault();
  leavePairingScreen();
  showScreen('screen-telegram');
  const inp = document.getElementById('telegram-token');
  if (inp) inp.value = '';
}

async function populateBotLink() {
  // Prefer localStorage (instant, no network) — this is set when the user
  // submits their token in this browser. If missing (different browser, etc.),
  // fall back to /api/status which reads from a server-side cache.
  let username = null;
  try { username = localStorage.getItem(LS_BOT_USERNAME); } catch {}

  if (!username) {
    try {
      const res  = await api('/api/status');
      const data = await res.json();
      if (data.botUsername) {
        username = data.botUsername;
        try { localStorage.setItem(LS_BOT_USERNAME, username); } catch {}
      }
    } catch {}
  }

  const btnEl  = document.getElementById('bot-link');
  const fbEl   = document.getElementById('bot-link-fallback');
  const fbName = document.getElementById('bot-link-fallback-name');

  if (username) {
    btnEl.href = `tg://resolve?domain=${encodeURIComponent(username)}&start=1`;
    btnEl.classList.remove('hidden');
    if (fbName) fbName.textContent = '@' + username;
    if (fbEl)   fbEl.classList.remove('hidden');
  } else {
    btnEl.classList.add('hidden');
    if (fbEl) fbEl.classList.add('hidden');
  }
}

function leavePairingScreen() {
  if (pairingPollTimer) { clearTimeout(pairingPollTimer); pairingPollTimer = null; }
}

// Progressive hint messages shown while waiting for a /start to arrive.
// Better UX than silence-then-bail-at-3-min: at each threshold the user
// gets a more specific, more actionable suggestion. If pairing succeeds at
// any point the screen transitions away and these never fire.
//
// Polls happen every 3s, so tick counts map to seconds × 3.
//   ticks <10  (<30s) — first message, just "Waiting…"
//   ticks <20  (<60s) — nudge: "Did you send /start? Tap the button above"
//   ticks <40  (<120s) — checklist: right bot, right command, etc.
//   ticks <60  (<180s) — escalate: point at diagnostics
//   ticks ≥60 (≥180s) — full troubleshooting card replaces the spinner
function pairingWaitMessage(ticks, botUsername) {
  const bot = botUsername ? '@' + botUsername : 'your bot';
  if (ticks < 10) {
    return `Waiting for your <code>/start</code> message to arrive…`;
  }
  if (ticks < 20) {
    return `Still waiting — have you sent <code>/start</code> to ${bot} yet?<br/>
            <span class="dim">Tap the blue button above if you haven't.</span>`;
  }
  if (ticks < 40) {
    return `Not seeing your message yet. Quick checklist:<br/>
            <span class="dim">• You're messaging the right bot (${bot}, not a different one)<br/>
            • You sent <code>/start</code> as a normal message<br/>
            • The bot already replied to you in Telegram (if not, the token may be wrong)</span>`;
  }
  if (ticks < 60) {
    return `Still nothing after 2 minutes — the gateway might be having trouble.<br/>
            <span class="dim">Open <a href="#" onclick="showDiagnostics(event); return false;">diagnostics</a>
            to see whether your <code>/start</code> reached the gateway.</span>`;
  }
  // ≥ 60: the full troubleshooting card takes over instead of this message.
  return '';
}

async function pollForPairings() {
  pairingPollCount++;
  try {
    const res  = await api('/api/pairings');
    const data = await res.json();
    const pending = data.pending || [];

    if (pending.length > 0) {
      const item = pending[0];
      const code = item.code || item.pairingCode || item.token || '';
      const user = item.userId || item.sender || item.from || item.id || 'new sender';
      if (code) {
        currentPairingCode = code;
        document.getElementById('pairing-code').textContent    = code;
        document.getElementById('pairing-user-id').textContent = user;
        document.getElementById('pairing-waiting').classList.add('hidden');
        document.getElementById('pairing-pending').classList.remove('hidden');
        return; // stop polling; wait for user click
      }
    }
  } catch (_) {
    // Network blips happen during boot — keep polling.
  }

  if (pairingPollCount >= PAIRING_POLL_TIMEOUT_TICKS) {
    // Final fallback: full troubleshooting card with retry / start-over /
    // diagnostics. Only kicks in after the progressive hints didn't help.
    document.getElementById('pairing-waiting').classList.add('hidden');
    document.getElementById('pairing-timeout').classList.remove('hidden');
    return;
  }

  // Update the wait message progressively so the user always knows what
  // to do next, instead of staring at a frozen spinner. Re-read the
  // username on every poll so it picks up the value once /api/status
  // populates it (matters for cross-browser reloads where the cache is
  // hydrated asynchronously by populateBotLink()).
  let username = null;
  try { username = localStorage.getItem(LS_BOT_USERNAME); } catch {}
  const msg = pairingWaitMessage(pairingPollCount, username);
  const el = document.getElementById('pairing-wait-msg');
  if (el && msg) el.innerHTML = msg;

  pairingPollTimer = setTimeout(pollForPairings, 3000);
}

async function approvePairing() {
  if (!currentPairingCode) return;
  const btn = document.getElementById('btn-approve');
  const err = document.getElementById('pairing-error');
  err.classList.add('hidden');
  btn.disabled = true;
  btn.textContent = 'Approving…';
  try {
    const res = await api('/api/pairings/approve', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ code: currentPairingCode }),
    });
    const data = await res.json();
    if (!res.ok || data.error) {
      err.textContent = data.error || 'Approve failed — try again.';
      err.classList.remove('hidden');
      btn.disabled = false;
      btn.textContent = 'Approve this user →';
      return;
    }
    leavePairingScreen();
    enterDoneScreen();
  } catch (e) {
    err.textContent = 'Network error: ' + e.message;
    err.classList.remove('hidden');
    btn.disabled = false;
    btn.textContent = 'Approve this user →';
  }
}

function skipPairing(ev) {
  if (ev) ev.preventDefault();
  leavePairingScreen();
  enterDoneScreen();
}

// ── Done screen with dashboard-readiness gate ────────────────────────────────
function enterDoneScreen() {
  showScreen('screen-done');
  document.getElementById('dashboard-link').classList.add('hidden');
  document.getElementById('dashboard-not-ready').classList.remove('hidden');
  document.getElementById('dashboard-timeout').classList.add('hidden');
  readyPollCount = 0;
  pollDashboardReady();
}

function leaveDoneScreen() {
  if (readyPollTimer) { clearTimeout(readyPollTimer); readyPollTimer = null; }
}

function retryDashboardPoll() {
  readyPollCount = 0;
  document.getElementById('dashboard-timeout').classList.add('hidden');
  document.getElementById('dashboard-not-ready').classList.remove('hidden');
  pollDashboardReady();
}

async function pollDashboardReady() {
  readyPollCount++;
  try {
    const res = await api('/api/dashboard-ready');
    const d   = await res.json();
    if (d.ready) {
      document.getElementById('dashboard-not-ready').classList.add('hidden');
      document.getElementById('dashboard-timeout').classList.add('hidden');
      const link = document.getElementById('dashboard-link');
      if (d.dashboardUrl) link.href = d.dashboardUrl;
      link.classList.remove('hidden');
      return; // stop polling
    }
    if (d.httpDashboardUrl) cachedHttpDashboardUrl = d.httpDashboardUrl;
  } catch (_) {
    // Keep polling.
  }

  if (readyPollCount >= READY_POLL_TIMEOUT_TICKS) {
    // Surface the HTTP fallback so the user isn't blocked.
    document.getElementById('dashboard-not-ready').classList.add('hidden');
    const httpLink = document.getElementById('dashboard-http-link');
    if (httpLink && cachedHttpDashboardUrl) httpLink.href = cachedHttpDashboardUrl;
    document.getElementById('dashboard-timeout').classList.remove('hidden');
    return;
  }
  // Update the wait message periodically so the user can tell it's making
  // progress, not frozen.
  const waitMsg = document.getElementById('dashboard-wait-msg');
  if (waitMsg && readyPollCount === 10) {
    waitMsg.innerHTML = 'Still waiting on Let\'s Encrypt — sometimes this takes a minute or two.<br/><span class="dim">(You can chat with your bot on Telegram right now while this finishes.)</span>';
  } else if (waitMsg && readyPollCount === 30) {
    waitMsg.innerHTML = 'Letting Let\'s Encrypt retry — almost there…<br/><span class="dim">(Your bot is fully working on Telegram independent of the dashboard.)</span>';
  }
  readyPollTimer = setTimeout(pollDashboardReady, 3000);
}

// ── Google / gog OAuth panel ─────────────────────────────────────────────────
function enterGoogleScreen(ev) {
  if (ev) ev.preventDefault();
  showScreen('screen-google');
  setOauthLinks(cachedProjectId);
  document.getElementById('g-saved').classList.add('hidden');
  document.getElementById('g-saving').classList.add('hidden');
  const err = document.getElementById('g-error');
  if (err) err.classList.add('hidden');
  const ta = document.getElementById('g-json');
  if (ta) ta.value = '';
  const btn = document.getElementById('g-save');
  if (btn) {
    btn.disabled = false;
    btn.textContent = 'Save credentials →';
  }
}

function exitGoogleScreen(ev) {
  if (ev) ev.preventDefault();
  showScreen('screen-done');
}

async function saveGoogleCredentials() {
  const ta  = document.getElementById('g-json');
  const btn = document.getElementById('g-save');
  const err = document.getElementById('g-error');

  err.classList.add('hidden');
  const raw = (ta?.value || '').trim();
  if (!raw) {
    err.textContent = 'Please paste the JSON before clicking Save.';
    err.classList.remove('hidden');
    return;
  }

  // Loading state: hide form, show spinner.
  btn.disabled    = true;
  btn.textContent = 'Saving…';
  document.getElementById('g-saving').classList.remove('hidden');

  try {
    const res  = await api('/api/gog/credentials', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ clientSecret: raw }),
    });
    const data = await res.json();
    document.getElementById('g-saving').classList.add('hidden');

    if (!res.ok || data.error) {
      err.textContent = data.error || 'Save failed — check the JSON and try again.';
      err.classList.remove('hidden');
      btn.disabled    = false;
      btn.textContent = 'Save credentials →';
      return;
    }

    // Success — flip to the "now go to the dashboard" panel.
    document.getElementById('g-saved').classList.remove('hidden');
    // Hide the input form so it's clear that step is done.
    const stepsEl = document.querySelector('#screen-google .g-steps');
    if (stepsEl) stepsEl.style.opacity = '0.4';

  } catch (e) {
    document.getElementById('g-saving').classList.add('hidden');
    err.textContent = 'Network error: ' + e.message;
    err.classList.remove('hidden');
    btn.disabled    = false;
    btn.textContent = 'Save credentials →';
  }
}

// Deep links into the user's own GCP project for the OAuth consent screen +
// credentials pages. Called whenever we know the project id.
function setOauthLinks(projectId) {
  if (!projectId) return;
  const set = (id, url) => {
    const el = document.getElementById(id);
    if (el) el.href = url;
  };
  set('oauth-consent-link',    `https://console.cloud.google.com/apis/credentials/consent?project=${encodeURIComponent(projectId)}`);
  set('oauth-credentials-link', `https://console.cloud.google.com/apis/credentials?project=${encodeURIComponent(projectId)}`);
  set('g-consent-link',         `https://console.cloud.google.com/apis/credentials/consent?project=${encodeURIComponent(projectId)}`);
  set('g-credentials-link',     `https://console.cloud.google.com/apis/credentials/oauthclient?project=${encodeURIComponent(projectId)}`);
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
    setText('diag-log-caddy',   d.logs?.caddy   || '(no caddy log)');
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
    inp.addEventListener('input', clearTelegramError);
  }
  init();
});
