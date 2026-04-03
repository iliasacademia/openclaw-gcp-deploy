'use strict';

// ── Screen manager ────────────────────────────────────────────────────────────
function showScreen(id) {
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  const el = document.getElementById(id);
  if (el) el.classList.add('active');
}

// ── Status badge ──────────────────────────────────────────────────────────────
function setBadge(text, cls) {
  const b = document.getElementById('status-badge');
  if (!b) return;
  b.textContent = text;
  b.className   = 'badge ' + (cls || '');
}

// ── Bootstrap: check current status on load ───────────────────────────────────
async function init() {
  showScreen('screen-loading');
  setBadge('Connecting…', 'starting');

  try {
    const res  = await fetch('/api/status');
    const data = await res.json();

    if (data.openclawRunning) {
      setBadge('Running', 'running');
    } else {
      setBadge('Starting…', 'starting');
    }

    if (data.telegramConfigured) {
      // Already fully configured — skip straight to done
      setDashboardLink(data.dashboardUrl);
      showScreen('screen-done');
    } else {
      showScreen('screen-telegram');
    }
  } catch (err) {
    console.error('Status check failed:', err);
    setBadge('Error', 'error');
    // Still show the form — user can try to set up even if status check failed
    showScreen('screen-telegram');
  }
}

// ── Telegram form ─────────────────────────────────────────────────────────────
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

  btn.disabled   = true;
  btn.textContent = 'Connecting…';

  try {
    const res  = await fetch('/api/telegram', {
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

    // Success
    setBadge('Running', 'running');
    setDashboardLink(data.dashboardUrl);
    showScreen('screen-done');

  } catch (err) {
    showError('Network error — is OpenClaw still starting? Wait 30 seconds and try again.');
    btn.disabled    = false;
    btn.textContent = 'Connect →';
  }
}

// ── Dashboard link ────────────────────────────────────────────────────────────
function setDashboardLink(url) {
  const a = document.getElementById('dashboard-link');
  if (a && url) a.href = url;
}

// ── Allow Enter key in token input ────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
  const inp = document.getElementById('telegram-token');
  if (inp) {
    inp.addEventListener('keydown', e => {
      if (e.key === 'Enter') submitTelegram();
    });
    // Clear error styling on input
    inp.addEventListener('input', clearError);
  }

  init();
});
