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
//
// Token goes in the URL fragment (`#token=`), NOT the query string. OpenClaw's
// dashboard reads from either, but warns in the browser console when query
// is used, because query parameters appear in server-side access logs of any
// proxy/CDN the request passes through. Fragments stay client-side.
const DASHBOARD_BASE_URL = process.env.DASHBOARD_BASE_URL || `http://${VM_IP}:18789`;
const DASHBOARD_URL = GATEWAY_TOKEN
  ? `${DASHBOARD_BASE_URL}/#token=${encodeURIComponent(GATEWAY_TOKEN)}`
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

// Call Telegram's getMe to (a) validate the bot token is actually live, and
// (b) get the bot's username so the wizard can show a one-click tg:// deep
// link. Returns:
//   { ok: true, username }                — token works, we got a username
//   { ok: false, reason, networkFailure } — token doesn't work, or we
//                                           couldn't reach Telegram
// Callers should treat networkFailure as soft (don't reject the token —
// Telegram might just be flaky right now) but reason='unauthorized' as a
// hard fail.
async function fetchBotInfo(token) {
  // Tests run against fake tokens; skip the live Telegram call when asked.
  if (process.env.SKIP_TELEGRAM_VERIFY === '1') {
    return { ok: true, username: 'testbot', firstName: 'Test Bot' };
  }
  try {
    const r = await fetch(`https://api.telegram.org/bot${token}/getMe`, {
      signal: AbortSignal.timeout(5000),
    });
    const d = await r.json();
    if (d.ok && d.result?.username) {
      return { ok: true, username: d.result.username, firstName: d.result.first_name };
    }
    // Telegram returned a structured "not ok" — e.g., revoked token. This is
    // a real config problem; the bot will never reply. Surface it.
    return {
      ok: false,
      reason: 'unauthorized',
      detail: d.description || 'Telegram rejected this bot token',
    };
  } catch (err) {
    logEvent('warn', 'telegram_getme_network_failed', { err: err.message });
    return { ok: false, reason: 'network', networkFailure: true, detail: err.message };
  }
}

// Where we cache the bot username so reloads / different browsers still
// get the deep link. Tiny JSON file the wizard reads via /api/status.
const BOT_INFO_CACHE = '/home/openclaw/.openclaw/.wizard-bot-info.json';

function saveBotInfo(info) {
  try {
    fs.writeFileSync(BOT_INFO_CACHE, JSON.stringify(info), { mode: 0o600 });
  } catch (err) {
    logEvent('warn', 'bot_info_cache_write_failed', { err: err.message });
  }
}

function readBotInfo() {
  try { return JSON.parse(fs.readFileSync(BOT_INFO_CACHE, 'utf8')); }
  catch { return null; }
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

const PAIRING_LIST_CMD = `env HOME=/home/openclaw OPENCLAW_NO_RESPAWN=1 openclaw pairing list telegram --json`;

// Cached output from the most recent pairing-list invocation. Surfaced in
// /api/diagnostics so if the CLI subcommand was renamed/removed upstream the
// raw stderr is visible without SSH.
let lastPairingProbe = null;

function pairingList() {
  // openclaw CLI talks to the gateway via WebSocket RPC, using auth from
  // ~/.openclaw/openclaw.json (which we own). Our service runs as the
  // openclaw user, so HOME is already /home/openclaw.
  // 2>&1 merges stderr into the captured output — important for diagnostics:
  // if the CLI no longer accepts these args, the error text is visible.
  const r = safeExec(`${PAIRING_LIST_CMD} 2>&1`, 8000);
  lastPairingProbe = {
    ts: new Date().toISOString(),
    command: PAIRING_LIST_CMD,
    ok: r.ok,
    rawOutput: (r.out || '').slice(0, 2000),
    error: r.err || null,
  };
  if (!r.ok) return { ok: false, err: r.err };
  try {
    const list = JSON.parse(r.out);
    // OpenClaw's actual output shape (discovered via diagnostics on a live
    // deploy) is `{ channel, requests: [...] }`. Older guesses included
    // `items` / `pending` or a bare array — we keep all four fallbacks so a
    // future format change doesn't break us silently again.
    if (!Array.isArray(list)
        && !Array.isArray(list?.items)
        && !Array.isArray(list?.pending)
        && !Array.isArray(list?.requests)) {
      logEvent('warn', 'pairing_list_unrecognized_shape', { sample: r.out.slice(0, 400) });
    }
    return { ok: true, list };
  } catch (e) {
    logEvent('warn', 'pairing_list_parse_failed', { err: e.message, sample: r.out.slice(0, 400) });
    return { ok: false, err: 'parse: ' + e.message, raw: r.out };
  }
}

// Three concentric reachability probes. If the dashboard doesn't load, we
// want to know exactly where the chain breaks:
//   loopback  — gateway is up AND bound on loopback (Caddy needs this)
//   lan       — gateway is up AND bound on LAN (matches our config bind=lan)
//   sslip     — Caddy is up AND has a Let's Encrypt cert AND can proxy
// `curl -w` prints status code, TLS verify result, and total time as a
// pipe-separated line, which the wizard renders verbatim in diagnostics.
function connectivityProbe() {
  const fmt = '%{http_code}|tls=%{ssl_verify_result}|t=%{time_total}s';
  const run = (url) => {
    const cmd = `curl -sS -o /dev/null -w ${JSON.stringify(fmt)} --max-time 4 ${JSON.stringify(url)} 2>&1`;
    const r = safeExec(cmd, 6000);
    return { url, ok: r.ok, output: r.out, error: r.err || null };
  };
  return {
    loopback: run('http://127.0.0.1:18789/'),
    lan:      run(`http://${VM_IP}:18789/`),
    sslip:    SSLIP_DOMAIN
      ? run(`https://${SSLIP_DOMAIN}/`)
      : { url: '(SSLIP_DOMAIN not set)', ok: false, output: '', error: 'not configured' },
  };
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

  const botInfo = readBotInfo();

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
    botUsername: botInfo?.username || null,
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

  // Run the connectivity probe and a live pairing probe so the diagnostics
  // dump always contains the freshest "where is the chain broken" data. Both
  // are best-effort and capped to a few seconds; failures land in the JSON.
  const connectivity = connectivityProbe();
  // Refresh pairing probe lazily — only if it's stale or absent.
  if (!lastPairingProbe || Date.now() - new Date(lastPairingProbe.ts).getTime() > 10000) {
    try { pairingList(); } catch (_) { /* probe stored in lastPairingProbe */ }
  }

  res.json({
    setupServerVersion: PKG_VERSION,
    timestamp:   new Date().toISOString(),
    vmIp:        VM_IP,
    projectId:   PROJECT_ID,
    region:      REGION,
    dashboardUrl: DASHBOARD_URL,
    sslipDomain: SSLIP_DOMAIN || null,
    gateway:     { ...gw, serviceName: SERVICE_NAME },
    startupFailure: startupFailed(),
    config:      configRedacted,
    connectivity,
    pairingProbe: lastPairingProbe,
    logs: {
      startup:    tailFile(STARTUP_LOG, 120),
      gateway:    journalTail(SERVICE_NAME, 80),
      setup:      journalTail('openclaw-setup', 40),
      caddy:      journalTail('caddy', 60),
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
  // openclaw's actual shape: `{ channel, requests: [...] }`. Older guesses
  // (items / pending / bare array) kept as fallbacks for forward-compat.
  const items = Array.isArray(r.list) ? r.list
                : Array.isArray(r.list?.requests) ? r.list.requests
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
  // Also expose an http://VM_IP fallback so the wizard can offer a "open
  // anyway" link when the cert is taking too long. The HTTP fallback hits
  // the dashboard's secure-context guard, but it's better than a blank page.
  const httpDashboardUrl = GATEWAY_TOKEN
    ? `http://${VM_IP}:18789/#token=${encodeURIComponent(GATEWAY_TOKEN)}`
    : `http://${VM_IP}:18789`;
  res.json({ ready, dashboardUrl: DASHBOARD_URL, httpDashboardUrl });
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

  // Check that gog is actually installed before pretending we succeeded.
  // The startup script's gog install is best-effort (logs WARN on failure
  // to keep the rest of the deploy alive). If gog isn't on the PATH, we
  // can't "configure credentials" — be honest about it.
  const which = safeExec('command -v gog', 2000);
  if (!which.ok || !which.out) {
    logEvent('error', 'gog_binary_missing');
    return res.status(500).json({
      error: 'The gog CLI is not installed on this VM (the startup script\'s install probably failed). Try redeploying, or SSH in and run `curl -sfL ... | tar` manually. Your client_secret.json has been saved but is unusable until gog is installed.',
    });
  }

  // Tell gog about the credentials.
  const r = safeExec(`env HOME=/home/openclaw gog auth credentials ${GOG_CREDS_PATH}`, 10000);
  if (!r.ok) {
    logEvent('error', 'gog_auth_credentials_failed', { err: r.err });
    return res.status(500).json({
      error: '`gog auth credentials` rejected the file. This usually means the JSON isn\'t an OAuth Desktop client — verify in Google Cloud Console that you picked Application type "Desktop app". Raw error: ' + (r.err || r.out || 'unknown'),
    });
  }
  logEvent('info', 'gog_credentials_saved', { clientId });
  res.json({ success: true, gogConfigured: true });
});

// gog's two-step server-side OAuth flow:
//   Step 1: print the Google OAuth URL (we capture and return it to the wizard).
//   User: opens URL, signs in, approves, gets redirected to a localhost URL
//         that fails to load (expected) — copies the URL from address bar.
//   Step 2: pass the pasted redirect URL back; gog exchanges the embedded code
//         for a refresh token and stores it in its keyring.
//
// This replaces the previous "go to the dashboard → Skills → gog → Authorise"
// instruction, because that dashboard control doesn't exist in the current
// OpenClaw build — only an Enabled toggle.
const GOG_SERVICES = 'gmail,calendar,drive,contacts,docs,sheets';

app.post('/api/gog/start-auth', requireToken, (req, res) => {
  const email = (req.body?.email || '').trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return res.status(400).json({ error: 'Please enter a valid email address.' });
  }

  // Step 1 prints the OAuth URL to stdout and exits. We capture and return it.
  // The `--no-input` flag tells gog never to prompt interactively (since we're
  // driving it from a parent process, not a TTY).
  const cmd = `env HOME=/home/openclaw gog auth add ${email} --services ${GOG_SERVICES} --remote --step 1 --no-input 2>&1`;
  const r = safeExec(cmd, 15000);
  if (!r.ok) {
    logEvent('error', 'gog_start_auth_failed', { email, err: r.err, out: (r.out || '').slice(0, 500) });
    return res.status(500).json({ error: 'Could not start Google sign-in: ' + ((r.out || r.err || 'unknown').slice(0, 400)) });
  }

  const urlMatch = (r.out || '').match(/https:\/\/accounts\.google\.com\/[^\s'"<>]+/);
  if (!urlMatch) {
    logEvent('warn', 'gog_start_auth_no_url', { sample: (r.out || '').slice(0, 400) });
    return res.status(500).json({
      error: 'gog did not produce an OAuth URL. Raw output: ' + (r.out || '').slice(0, 400),
    });
  }

  logEvent('info', 'gog_start_auth', { email });
  res.json({ url: urlMatch[0], email });
});

app.post('/api/gog/complete-auth', requireToken, (req, res) => {
  const email   = (req.body?.email   || '').trim().toLowerCase();
  const authUrl = (req.body?.authUrl || '').trim();

  if (!email || !authUrl) {
    return res.status(400).json({ error: 'Email and the pasted redirect URL are both required.' });
  }
  if (!/[?&]code=/.test(authUrl)) {
    return res.status(400).json({
      error: 'That URL doesn\'t look like a Google OAuth redirect — it should contain `code=...` in the query string. Copy the URL from the address bar AFTER you click Allow on the Google page (the page will fail to load — that\'s expected).',
    });
  }

  // Step 2 takes the redirect URL via --auth-url and exchanges the embedded
  // code for a refresh token. Quote the URL with JSON.stringify so the shell
  // doesn't interpret special chars from the query string.
  const cmd = `env HOME=/home/openclaw gog auth add ${email} --services ${GOG_SERVICES} --remote --step 2 --auth-url ${JSON.stringify(authUrl)} --no-input 2>&1`;
  const r = safeExec(cmd, 30000);
  if (!r.ok) {
    logEvent('error', 'gog_complete_auth_failed', { email, err: r.err, out: (r.out || '').slice(0, 500) });
    return res.status(400).json({
      error: 'Sign-in failed: ' + ((r.out || r.err || 'unknown').slice(0, 400)),
    });
  }

  logEvent('info', 'gog_complete_auth', { email });
  res.json({ success: true });
});

// Save Telegram bot token.
app.post('/api/telegram', requireToken, async (req, res) => {
  const token = (req.body?.token || '').trim();

  if (!validateTelegramToken(token)) {
    return res.status(400).json({
      error: 'Invalid token format. Expected "<bot_id>:<secret>" — e.g. 123456789:ABCdef…',
    });
  }

  // Verify the token actually works against Telegram BEFORE we persist it
  // to the config. Otherwise a revoked/wrong-but-correctly-formatted token
  // ends up on disk with telegram.enabled=true; the next page reload sees
  // telegramConfigured=true and routes the user to a pairing screen that
  // can never advance.
  const info = await fetchBotInfo(token);
  if (!info.ok && info.reason === 'unauthorized') {
    return res.status(400).json({
      error: 'Telegram rejected this bot token. Please check that you copied the WHOLE token from BotFather and try again. (' + (info.detail || 'unauthorized') + ')',
    });
  }
  // Network failures are soft — proceed; Telegram could be transiently
  // unreachable and the token may still be valid.

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

  logEvent('info', 'telegram_configured', { botUsername: info.username || null });

  if (info.ok) {
    saveBotInfo({ username: info.username, firstName: info.firstName });
  }

  // Restart so the bot connects immediately. Hot-reload also works for some
  // changes, but channel reconnects are more reliable with a fresh process.
  const restarted = restartGateway();

  res.json({
    success: true,
    restarted,
    dashboardUrl: DASHBOARD_URL,
    projectId: PROJECT_ID,
    botUsername: info.username || null,
    telegramOffline: !!info.networkFailure,
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
