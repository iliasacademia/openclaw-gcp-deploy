'use strict';

const express = require('express');
const fs      = require('fs');
const os      = require('os');
const path    = require('path');
const { execSync } = require('child_process');

// ── Config ───────────────────────────────────────────────────────────────────
const PORT           = parseInt(process.env.PORT           || '8080');
const VM_IP          = process.env.VM_IP                   || 'localhost';
const PROJECT_ID     = process.env.PROJECT_ID              || '';
const OPENCLAW_CONFIG = process.env.OPENCLAW_CONFIG        || '/home/openclaw/.openclaw/openclaw.json';
const DASHBOARD_URL  = `http://${VM_IP}:18789`;

// ── App ──────────────────────────────────────────────────────────────────────
const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// ── Helpers ──────────────────────────────────────────────────────────────────

function readConfig() {
  try {
    return JSON.parse(fs.readFileSync(OPENCLAW_CONFIG, 'utf8'));
  } catch {
    return {};
  }
}

function writeConfig(config) {
  // Atomic write: write to temp file in same directory, then rename.
  // This prevents OpenClaw's hot-reload from reading a half-written file.
  const dir  = path.dirname(OPENCLAW_CONFIG);
  const tmp  = path.join(dir, `.openclaw.json.tmp.${process.pid}`);
  fs.writeFileSync(tmp, JSON.stringify(config, null, 2), 'utf8');
  fs.renameSync(tmp, OPENCLAW_CONFIG);
}

function isOpenclawRunning() {
  try {
    execSync('systemctl is-active --quiet openclaw', { timeout: 3000 });
    return true;
  } catch {
    return false;
  }
}

function restartOpenclaw() {
  try {
    // OpenClaw hot-reloads config automatically.
    // For channel changes (Telegram), a restart ensures the connection is live.
    execSync('sudo systemctl restart openclaw', { timeout: 15000 });
  } catch (err) {
    console.warn('Could not restart openclaw service:', err.message);
  }
}

function validateTelegramToken(token) {
  // Telegram bot tokens: <numeric_bot_id>:<alphanumeric_secret>
  // Bot IDs range from ~6 digits (old bots) to 12+ digits (new bots).
  // Secret part is typically 35 chars but can vary.
  return typeof token === 'string' && /^\d{4,15}:[A-Za-z0-9_-]{20,}$/.test(token.trim());
}

// ── Routes ───────────────────────────────────────────────────────────────────

// Health check — deploy.sh polls this to know the VM is ready
app.get('/health', (_req, res) => {
  res.json({ status: 'ok', vm_ip: VM_IP, project_id: PROJECT_ID });
});

// Current setup status
app.get('/api/status', (_req, res) => {
  const config = readConfig();
  const telegramEnabled = !!(
    config.channels?.telegram?.enabled &&
    config.channels?.telegram?.botToken
  );

  res.json({
    telegramConfigured: telegramEnabled,
    openclawRunning:    isOpenclawRunning(),
    dashboardUrl:       DASHBOARD_URL,
    projectId:          PROJECT_ID,
    vmIp:               VM_IP,
  });
});

// Save Telegram bot token
app.post('/api/telegram', (req, res) => {
  const token = (req.body?.token || '').trim();

  if (!validateTelegramToken(token)) {
    return res.status(400).json({
      error: 'Invalid token format. Expected something like 123456789:ABCdef...',
    });
  }

  try {
    const config = readConfig();

    config.channels           = config.channels           || {};
    config.channels.telegram  = config.channels.telegram  || {};
    config.channels.telegram.enabled   = true;
    config.channels.telegram.botToken  = token;
    config.channels.telegram.dmPolicy  = config.channels.telegram.dmPolicy || 'pairing';

    writeConfig(config);
    restartOpenclaw();

    res.json({ success: true, dashboardUrl: DASHBOARD_URL });
  } catch (err) {
    console.error('Failed to save Telegram token:', err);
    res.status(500).json({ error: 'Failed to write config: ' + err.message });
  }
});

// ── Start ────────────────────────────────────────────────────────────────────
app.listen(PORT, '0.0.0.0', () => {
  console.log(`OpenClaw setup wizard listening on port ${PORT}`);
  console.log(`VM IP      : ${VM_IP}`);
  console.log(`Dashboard  : ${DASHBOARD_URL}`);
  console.log(`Config     : ${OPENCLAW_CONFIG}`);
});
