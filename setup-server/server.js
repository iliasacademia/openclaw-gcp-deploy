'use strict';

const express      = require('express');
const fs           = require('fs');
const path         = require('path');
const { execSync } = require('child_process');

const PKG_VERSION = require('./package.json').version;

// ── Config ───────────────────────────────────────────────────────────────────
const PORT             = parseInt(process.env.PORT || '8080', 10);
const VM_IP            = process.env.VM_IP || 'localhost';
const PROJECT_ID       = process.env.PROJECT_ID || '';
const REGION           = process.env.REGION || '';
const SETUP_TOKEN      = process.env.SETUP_TOKEN || '';
const GATEWAY_TOKEN    = process.env.GATEWAY_TOKEN || '';
const OPENCLAW_CONFIG  = process.env.OPENCLAW_CONFIG || '/home/openclaw/.openclaw/openclaw.json';
const STARTUP_LOG      = process.env.STARTUP_LOG || '/var/log/openclaw-startup.log';
const STARTUP_FAILED   = '/var/log/openclaw-startup.failed';
const SERVICE_NAME     = 'openclaw-gateway';
const SSLIP_DOMAIN     = process.env.SSLIP_DOMAIN || '';
const GOG_CREDS_PATH   = '/home/openclaw/.gog/client_secret.json';

// HTTPS dashboard URL via sslip.io + Caddy. Falls back to plain HTTP for
// dev/test environments where Caddy isn't running.
const DASHBOARD_BASE_URL = process.env.DASHBOARD_BASE_URL || `http://${VM_IP}:18789`;
const DASHBOARD_URL = GATEWAY_TOKEN
  ? `${DASHBOARD_BASE_URL}/?token=${encodeURIComponent(GATEWAY_TOKEN)}`
  : DASHBOARD_BASE_URL;

// Fail closed: refuse to start if the setup token is missing. The wizard
// writes config and restarts a service; an open endpoint here is a serious
// security hole.
if (!SETUP_TOKEN) {
  console.error('FATAL: SETUP_TOKEN env var is empty. Refusing to start.');
  process.exit(1);
}

// ── Logging ──────────────────────────────────────────────────────────────────
// Structured one-line JSON per event. Picked up by journalctl -u openclaw-setup
// and surfaced back to users via /api/diagnostics.
function logEvent(level, event, fields = {}) {
  const line = JSON.stringify({
    ts: new Date().toISOString(),
    level,
    event,
    ...fields,
  });
  (level === 'error' ? process.stderr : process.stdout).write(line + '\n');
}

// ── App ──────────────────────────────────────────────────────────────────────
const app = express();
app.use(express.json({ limit: '16kb' }));
app.use(express.static(path.join(__dirname, 'public')));

// ── Auth middleware ──────────────────────────────────────────────────────────
function requireToken(req, res, next) {
  const provided = req.query.token || req.headers['x-setup-token'] || '';
  if (provided !== SETUP_TOKEN) {
    logEvent('warn', 'auth_denied', { path: req.path, ip: req.ip });
    return res.status(403).json({ error: 'Invalid or missing setup token.' });
  }
  return next();
}

// ── Helpers ──────────────────────────────────────────────────────────────────
function readConfig() {
  return JSON.parse(fs.readFileSync(OPENCLAW_CONFIG, 'utf8'));
}

function writeConfig(config) {
  // Atomic write: temp file in same directory, then rename. Prevents the
  // gateway's hot-reload from picking up a half-written file.
  const dir = path.dirname(OPENCLAW_CONFIG);
  const tmp = path.join(dir, `.openclaw.json.tmp.${process.pid}`);
  fs.writeFileSync(tmp, JSON.stringify(config, null, 2), 'utf8');
  fs.renameSync(tmp, OPENCLAW_CONFIG);
}

function safeExec(cmd, timeout = 3000) {
  try {
    return { ok: true, out: execSync(cmd, { timeout, encoding: 'utf8' }).trim() };
  } catch (err) {
    return { ok: false, out: (err.stdout || '').toString(), err: err.message };
  }
}

function gatewayServiceStatus() {
  const active = safeExec(`systemctl is-active ${SERVICE_NAME}`);
  const sub    = safeExec(`systemctl show ${SERVICE_NAME} --no-page -p ActiveState,SubState,ExecMainStatus,Result --value`);
  return {
    active:        active.out === 'active',
    activeRaw:     active.out,
    details:       sub.out,
  };
}

function tailFile(filepath, lines = 80) {
  if (!fs.existsSync(filepath)) return null;
  // Use the system tail — efficient and predictable. Cap at 500 lines.
  const n = Math.min(Math.max(lines, 1), 500);
  const r = safeExec(`tail -n ${n} ${JSON.stringify(filepath)}`, 5000);
  return r.ok ? r.out : null;
}

function journalTail(unit, lines = 80) {
  const n = Math.min(Math.max(lines, 1), 500);
  const r = safeExec(`journalctl -u ${unit} -n ${n} --no-pager --output=short-iso`, 5000);
  return r.ok ? r.out : null;
}

function startupFailed() {
  if (!fs.existsSync(STARTUP_FAILED)) return null;
  try { return fs.readFileSync(STARTUP_FAILED, 'utf8').trim(); } catch { return null; }
}

function restartGateway() {
  const r = safeExec(`sudo systemctl restart ${SERVICE_NAME}`, 15000);
  if (!r.ok) logEvent('error', 'gateway_restart_failed', { err: r.err });
  else       logEvent('info',  'gateway_restarted');
  return r.ok;
}

function validateTelegramToken(token) {
  // Telegram bot tokens: <bot_id>:<secret>. Bot IDs are typically 9-10 digits;
  // we accept 6-15 to handle old/new ranges. Secret is base64url-ish, ~35 chars.
  return typeof token === 'string'
    && /^\d{6,15}:[A-Za-z0-9_-]{20,}$/.test(token.trim());
}

// Ask Telegram's getMe for the bot's username so we can build a tg:// deep
// link the user can one-click to open their bot. Best-effort — if Telegram
// is unreachable or the token is wrong (we already format-validated it but
// it could still be revoked), we return null and the UI falls back to text
// instructions.
async function fetchBotUsername(token) {
  try {
    const r = await fetch(`https://api.telegram.org/bot${token}/getMe`, {
      signal: AbortSignal.timeout(5000),
    });
    const d = await r.json();
    if (d.ok && d.result?.username) return d.result.username;
    return null;
  } catch (err) {
    logEvent('warn', 'telegram_getme_failed', { err: err.message });
    return null;
  }
}

// Ask Caddy whether the HTTPS dashboard URL is responding. Returns true once
// the TLS cert is provisioned AND the gateway is reachable through Caddy's
// reverse-proxy. We use this to gate the "Open Dashboard" button so users
// never hit raw browser cert errors.
async function checkDashboardReady() {
  if (!SSLIP_DOMAIN) return true; // dev/local — assume ready
  try {
    const r = await fetch(`https://${SSLIP_DOMAIN}/`, {
      signal: AbortSignal.timeout(4000),
      redirect: 'manual',
    });
    // Any HTTP response (200, 301, 401, even 404) means TLS handshake
    // succeeded and Caddy is proxying. A TLS error throws and lands in
    // the catch.
    return r.status > 0;
  } catch (err) {
    return false;
  }
}

// Pairing codes from OpenClaw are uppercase alphanumeric, currently 8 chars.
// Accept a generous range to stay forward-compatible.
const PAIRING_CODE_RE = /^[A-Z0-9]{4,32}$/;

function pairingList() {
  // openclaw CLI talks to the gateway via WebSocket RPC, using auth from
  // ~/.openclaw/openclaw.json (which we own). Our service runs as the
  // openclaw user, so HOME is already /home/openclaw.
  const r = safeExec(
    `env HOME=/home/openclaw OPENCLAW_NO_RESPAWN=1 openclaw pairing list telegram --json`,
    8000
  );
  if (!r.ok) return { ok: false, err: r.err };
  try { return { ok: true, list: JSON.parse(r.out) }; }
  catch (e) { return { ok: false, err: 'parse: ' + e.message, raw: r.out }; }
}

function pairingApprove(code) {
  // --notify tells OpenClaw to message the user back on Telegram confirming
  // they're approved.
  const r = safeExec(
    `env HOME=/home/openclaw OPENCLAW_NO_RESPAWN=1 openclaw pairing approve telegram ${code} --notify`,
    15000
  );
  return { ok: r.ok, out: r.out, err: r.err };
}

// ── Routes ───────────────────────────────────────────────────────────────────

// Health probe — no auth. deploy.sh polls this to know the VM is up.
app.get('/health', (_req, res) => {
  res.json({ status: 'ok' });
});

// Setup status — what the wizard renders on load.
app.get('/api/status', requireToken, (_req, res) => {
  let config = null;
  let configError = null;
  try { config = readConfig(); }
  catch (err) { configError = err.message; }

  const telegramConfigured = !!(
    config?.channels?.telegram?.enabled &&
    config?.channels?.telegram?.botToken
  );
  const gw = gatewayServiceStatus();

  res.json({
    telegramConfigured,
    openclawRunning: gw.active,
    gatewayActiveState: gw.activeRaw,
    dashboardUrl: DASHBOARD_URL,
    projectId: PROJECT_ID,
    region: REGION,
    vmIp: VM_IP,
    startupFailure: startupFailed(),
    configError,
  });
});

// Full diagnostics — for the troubleshooting panel.
app.get('/api/diagnostics', requireToken, (_req, res) => {
  const gw = gatewayServiceStatus();
  let configRedacted = null;
  try {
    const c = readConfig();
    if (c?.gateway?.auth?.token) c.gateway.auth.token = '***';
    if (c?.channels?.telegram?.botToken) c.channels.telegram.botToken = '***';
    configRedacted = c;
  } catch (err) {
    configRedacted = { error: err.message };
  }

  res.json({
    setupServerVersion: PKG_VERSION,
    timestamp:   new Date().toISOString(),
    vmIp:        VM_IP,
    projectId:   PROJECT_ID,
    region:      REGION,
    dashboardUrl: DASHBOARD_URL,
    gateway:     { ...gw, serviceName: SERVICE_NAME },
    startupFailure: startupFailed(),
    config:      configRedacted,
    logs: {
      startup:    tailFile(STARTUP_LOG, 120),
      gateway:    journalTail(SERVICE_NAME, 80),
      setup:      journalTail('openclaw-setup', 40),
    },
  });
});

// List pending Telegram pairing requests.
app.get('/api/pairings', requireToken, (_req, res) => {
  const r = pairingList();
  if (!r.ok) {
    logEvent('warn', 'pairing_list_failed', { err: r.err });
    return res.status(200).json({ pending: [], error: r.err });
  }
  // openclaw returns either an array of pending objects or an object with
  // an items array — normalise both shapes to { pending: [...] }.
  const items = Array.isArray(r.list) ? r.list
                : Array.isArray(r.list?.items) ? r.list.items
                : Array.isArray(r.list?.pending) ? r.list.pending
                : [];
  res.json({ pending: items });
});

// Approve a pending pairing code.
app.post('/api/pairings/approve', requireToken, (req, res) => {
  const code = String(req.body?.code || '').trim().toUpperCase();
  if (!PAIRING_CODE_RE.test(code)) {
    return res.status(400).json({ error: 'Invalid pairing code format.' });
  }
  const r = pairingApprove(code);
  if (!r.ok) {
    logEvent('warn', 'pairing_approve_failed', { code, err: r.err });
    return res.status(500).json({ error: r.err || 'pairing approve failed', detail: r.out });
  }
  logEvent('info', 'pairing_approved', { code });
  res.json({ success: true, output: r.out });
});

// Is the OpenClaw dashboard reachable over HTTPS yet?
// Used by the wizard to wait for Caddy's first Let's Encrypt cert before
// linking the user out — prevents the "browser cert error" UX.
app.get('/api/dashboard-ready', requireToken, async (_req, res) => {
  const ready = await checkDashboardReady();
  res.json({ ready, dashboardUrl: DASHBOARD_URL });
});

// Save Google OAuth client_secret.json so gog can use it.
// This is the file the user downloads from GCP Console after creating an
// OAuth Desktop client. We write it where gog expects it and (best-effort)
// register it with gog. The user still has to complete the OAuth approval
// flow itself from the OpenClaw dashboard — that part requires a browser
// click that only Google can render.
app.post('/api/gog/credentials', requireToken, (req, res) => {
  const raw = (req.body?.clientSecret || '').trim();

  let parsed;
  try { parsed = JSON.parse(raw); }
  catch (e) {
    return res.status(400).json({
      error: 'That doesn\'t look like JSON. Open client_secret.json in a text editor and paste its full contents.',
    });
  }
  const clientId = parsed.installed?.client_id || parsed.web?.client_id;
  if (!clientId) {
    return res.status(400).json({
      error: 'JSON is missing an OAuth client_id. Make sure you downloaded an OAuth client (Desktop app), not a service-account key.',
    });
  }

  try {
    const dir = path.dirname(GOG_CREDS_PATH);
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    fs.writeFileSync(GOG_CREDS_PATH, raw, { mode: 0o600 });
  } catch (err) {
    logEvent('error', 'gog_creds_write_failed', { err: err.message });
    return res.status(500).json({ error: 'Could not save credentials: ' + err.message });
  }

  // Tell gog about the credentials. If gog isn't installed (some
  // deploys may skip it), surface a clear message.
  const r = safeExec(`env HOME=/home/openclaw gog auth credentials ${GOG_CREDS_PATH}`, 10000);
  if (!r.ok) {
    logEvent('warn', 'gog_auth_credentials_failed', { err: r.err });
    // Still consider the file save a success — the user can finish via the
    // dashboard or SSH if gog cli has issues.
    return res.json({
      success: true,
      gogConfigured: false,
      warning: 'Saved credentials to ' + GOG_CREDS_PATH + ', but `gog auth credentials` reported: ' + (r.err || 'unknown error'),
    });
  }
  logEvent('info', 'gog_credentials_saved', { clientId });
  res.json({ success: true, gogConfigured: true });
});

// Save Telegram bot token.
app.post('/api/telegram', requireToken, async (req, res) => {
  const token = (req.body?.token || '').trim();

  if (!validateTelegramToken(token)) {
    return res.status(400).json({
      error: 'Invalid token format. Expected "<bot_id>:<secret>" — e.g. 123456789:ABCdef…',
    });
  }

  let config;
  try { config = readConfig(); }
  catch (err) {
    logEvent('error', 'config_read_failed', { err: err.message });
    return res.status(500).json({ error: 'Could not read OpenClaw config: ' + err.message });
  }

  config.channels                   = config.channels                   || {};
  config.channels.telegram          = config.channels.telegram          || {};
  config.channels.telegram.enabled  = true;
  config.channels.telegram.botToken = token;
  config.channels.telegram.dmPolicy = config.channels.telegram.dmPolicy || 'pairing';

  try { writeConfig(config); }
  catch (err) {
    logEvent('error', 'config_write_failed', { err: err.message });
    return res.status(500).json({ error: 'Could not write config: ' + err.message });
  }

  logEvent('info', 'telegram_configured');

  // Look up the bot's username so the wizard can show a one-click
  // tg://resolve link in the pairing step. Don't fail the request if this
  // call fails — the wizard falls back to text instructions.
  const botUsername = await fetchBotUsername(token);

  // Restart so the bot connects immediately. Hot-reload also works for some
  // changes, but channel reconnects are more reliable with a fresh process.
  const restarted = restartGateway();

  res.json({
    success: true,
    restarted,
    dashboardUrl: DASHBOARD_URL,
    projectId: PROJECT_ID,
    botUsername,
  });
});

// ── Start ────────────────────────────────────────────────────────────────────
app.listen(PORT, '0.0.0.0', () => {
  logEvent('info', 'server_listening', {
    version:     PKG_VERSION,
    port:        PORT,
    vmIp:        VM_IP,
    projectId:   PROJECT_ID,
    region:      REGION,
    configPath:  OPENCLAW_CONFIG,
    authMode:    'token-required',
  });
});
