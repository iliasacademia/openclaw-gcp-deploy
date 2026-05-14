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

// Dashboard URL embeds the gateway token so the user can click straight through.
const DASHBOARD_URL = GATEWAY_TOKEN
  ? `http://${VM_IP}:18789/?token=${encodeURIComponent(GATEWAY_TOKEN)}`
  : `http://${VM_IP}:18789`;

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

// Save Telegram bot token.
app.post('/api/telegram', requireToken, (req, res) => {
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

  // Restart so the bot connects immediately. Hot-reload also works for some
  // changes, but channel reconnects are more reliable with a fresh process.
  const restarted = restartGateway();

  res.json({
    success: true,
    restarted,
    dashboardUrl: DASHBOARD_URL,
    projectId: PROJECT_ID,
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
