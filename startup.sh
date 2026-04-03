#!/bin/bash
# =============================================================================
# OpenClaw VM Startup Script
# Runs automatically on first boot via GCP startup-script metadata.
# Installs Node.js 24, OpenClaw, and the setup wizard server.
#
# NOTE: We intentionally do NOT use `set -e` here. A startup script that dies
# on the first transient apt/npm error leaves the user with a broken VM and
# zero diagnostics. Instead, each critical step checks its own exit code and
# either retries or logs a clear message.
# =============================================================================

# Log everything to a file for debugging
exec > >(tee /var/log/openclaw-startup.log) 2>&1
echo "=== OpenClaw Startup: $(date) ==="

fail() { echo "FATAL: $*"; exit 1; }

# ── Read GCP instance metadata ───────────────────────────────────────────────
META="http://metadata.google.internal/computeMetadata/v1"
GH()  { curl -sf -H "Metadata-Flavor: Google" "$META/$1"; }

REPO_URL=$(GH "instance/attributes/repo-url"   || echo "")
VM_IP=$(GH   "instance/network-interfaces/0/access-configs/0/external-ip")
PROJECT_ID=$(GH "project/project-id")
ZONE=$(GH    "instance/zone" | awk -F'/' '{print $NF}')
REGION=$(echo "$ZONE" | sed 's/-[a-z]$//')

echo "VM_IP=${VM_IP}  PROJECT_ID=${PROJECT_ID}  REGION=${REGION}  ZONE=${ZONE}"
echo "REPO_URL=${REPO_URL}"

# ── System packages ──────────────────────────────────────────────────────────
echo "--- Installing system packages ---"
for attempt in 1 2 3; do
  apt-get update -qq && break
  echo "apt-get update failed (attempt ${attempt}/3), retrying in 10s..."
  sleep 10
done
apt-get install -y -qq curl git ca-certificates gnupg || fail "Could not install base packages"

# ── Node.js 24 via NodeSource ────────────────────────────────────────────────
echo "--- Installing Node.js 24 ---"
curl -fsSL https://deb.nodesource.com/setup_24.x | bash - || fail "NodeSource setup failed"
apt-get install -y -qq nodejs || fail "Could not install Node.js"
echo "Node.js $(node --version)  npm $(npm --version)"

# ── OpenClaw system user ──────────────────────────────────────────────────────
echo "--- Creating openclaw user ---"
useradd -r -m -d /home/openclaw -s /bin/bash openclaw 2>/dev/null || true

# ── Install OpenClaw ─────────────────────────────────────────────────────────
echo "--- Installing OpenClaw ---"
for attempt in 1 2 3; do
  npm install -g openclaw@latest && break
  echo "npm install openclaw failed (attempt ${attempt}/3), retrying in 15s..."
  sleep 15
done
command -v openclaw >/dev/null || fail "openclaw not found after 3 install attempts"

# Detect actual binary path (npm may install to /usr/bin, /usr/local/bin, etc.)
OPENCLAW_BIN=$(command -v openclaw || true)
NODE_BIN=$(command -v node || true)

if [ -z "$OPENCLAW_BIN" ]; then
  fail "openclaw binary not found in PATH after install"
fi
if [ -z "$NODE_BIN" ]; then
  fail "node binary not found in PATH after install"
fi
echo "OpenClaw binary: ${OPENCLAW_BIN}"
echo "Node binary:     ${NODE_BIN}"
echo "OpenClaw version: $(openclaw --version 2>/dev/null || echo 'unknown')"

# ── OpenClaw config ───────────────────────────────────────────────────────────
echo "--- Writing OpenClaw config ---"
mkdir -p /home/openclaw/.openclaw

cat > /home/openclaw/.openclaw/openclaw.json << OCCONF
{
  "agent": {
    "model": "google-vertex/gemini-3.1-pro-preview-customtools",
    "timezone": "UTC",
    "compactionStrategy": "summarize"
  },
  "models": {
    "providers": {
      "google-vertex": {
        "project": "${PROJECT_ID}",
        "location": "${REGION}"
      }
    }
  },
  "gateway": {
    "port": 18789,
    "bind": "0.0.0.0",
    "auth": "token"
  },
  "channels": {
    "telegram": {
      "enabled": false
    }
  }
}
OCCONF

chown -R openclaw:openclaw /home/openclaw

# ── sudoers: allow openclaw to restart itself ─────────────────────────────────
echo "openclaw ALL=(ALL) NOPASSWD: /bin/systemctl restart openclaw" \
  > /etc/sudoers.d/openclaw
chmod 0440 /etc/sudoers.d/openclaw

# ── Setup wizard server ───────────────────────────────────────────────────────
echo "--- Cloning deploy repo for setup server ---"
if [ -z "$REPO_URL" ]; then
  fail "No repo URL in metadata — setup server cannot be installed."
fi

for attempt in 1 2 3; do
  git clone "$REPO_URL" /opt/openclaw-deploy --depth=1 --quiet && break
  echo "git clone failed (attempt ${attempt}/3), retrying in 10s..."
  rm -rf /opt/openclaw-deploy
  sleep 10
done

if [ ! -d /opt/openclaw-deploy/setup-server ]; then
  fail "setup-server directory not found after clone"
fi

cd /opt/openclaw-deploy/setup-server
for attempt in 1 2 3; do
  npm install --omit=dev && break
  echo "npm install for setup-server failed (attempt ${attempt}/3), retrying in 10s..."
  sleep 10
done
if [ ! -d /opt/openclaw-deploy/setup-server/node_modules ]; then
  fail "setup-server node_modules missing after 3 install attempts"
fi

# Runtime env for the setup server
cat > /opt/openclaw-deploy/setup-server/.env << SENV
VM_IP=${VM_IP}
PROJECT_ID=${PROJECT_ID}
OPENCLAW_CONFIG=/home/openclaw/.openclaw/openclaw.json
PORT=8080
SENV

chown -R openclaw:openclaw /opt/openclaw-deploy

# ── Detect the right openclaw start command ──────────────────────────────────
# IMPORTANT: We must NOT run `openclaw start --help` because some CLIs ignore
# unknown flags and actually execute the subcommand, which would hang this script.
# Instead, inspect the top-level help text for available subcommands.
echo "--- Detecting OpenClaw start command ---"
OPENCLAW_HELP=$("${OPENCLAW_BIN}" --help 2>&1 || true)
OPENCLAW_CMD="${OPENCLAW_BIN} start"  # default fallback

if echo "$OPENCLAW_HELP" | grep -qw "start"; then
  OPENCLAW_CMD="${OPENCLAW_BIN} start"
  echo "Detected subcommand 'start' — using: ${OPENCLAW_CMD}"
elif echo "$OPENCLAW_HELP" | grep -qw "gateway"; then
  OPENCLAW_CMD="${OPENCLAW_BIN} gateway"
  echo "Detected subcommand 'gateway' — using: ${OPENCLAW_CMD}"
else
  echo "WARN: Could not detect start command from help output, defaulting to: ${OPENCLAW_CMD}"
  echo "      Available help output:"
  echo "$OPENCLAW_HELP" | head -20
  echo "      If OpenClaw fails to start, SSH in and run: openclaw onboard --install-daemon"
fi

# ── systemd: openclaw.service ─────────────────────────────────────────────────
cat > /etc/systemd/system/openclaw.service << SVC
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openclaw
ExecStart=${OPENCLAW_CMD}
Restart=on-failure
RestartSec=10
WorkingDirectory=/home/openclaw
Environment=HOME=/home/openclaw

[Install]
WantedBy=multi-user.target
SVC

# ── systemd: openclaw-setup.service ──────────────────────────────────────────
cat > /etc/systemd/system/openclaw-setup.service << SVC
[Unit]
Description=OpenClaw Setup Wizard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openclaw
ExecStart=${NODE_BIN} /opt/openclaw-deploy/setup-server/server.js
Restart=on-failure
RestartSec=5
WorkingDirectory=/opt/openclaw-deploy/setup-server
EnvironmentFile=/opt/openclaw-deploy/setup-server/.env

[Install]
WantedBy=multi-user.target
SVC

# ── Start services ────────────────────────────────────────────────────────────
systemctl daemon-reload
systemctl enable openclaw.service openclaw-setup.service

# Start setup server first — it's the health check target
systemctl start openclaw-setup.service
echo "Setup server started: http://${VM_IP}:8080"

# Start OpenClaw (may take a moment; don't block on it)
systemctl start openclaw.service
if systemctl is-active --quiet openclaw.service; then
  echo "OpenClaw service started successfully"
else
  echo "WARN: OpenClaw service may still be starting. Check: journalctl -u openclaw -f"
fi

echo "=== Startup complete: $(date) ==="
echo "Setup wizard: http://${VM_IP}:8080"
echo "Dashboard:    http://${VM_IP}:18789"
