#!/bin/bash
# =============================================================================
# OpenClaw VM Startup Script
# Runs automatically on first boot via GCP startup-script metadata.
# Installs Node.js 24, OpenClaw, and the setup wizard server.
# =============================================================================
set -euo pipefail

# Log everything to a file for debugging
exec > >(tee /var/log/openclaw-startup.log) 2>&1
echo "=== OpenClaw Startup: $(date) ==="

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
apt-get update -qq
apt-get install -y -qq curl git ca-certificates gnupg

# ── Node.js 24 via NodeSource ────────────────────────────────────────────────
echo "--- Installing Node.js 24 ---"
curl -fsSL https://deb.nodesource.com/setup_24.x | bash - >/dev/null 2>&1
apt-get install -y -qq nodejs
echo "Node.js $(node --version)  npm $(npm --version)"

# ── OpenClaw system user ──────────────────────────────────────────────────────
echo "--- Creating openclaw user ---"
useradd -r -m -d /home/openclaw -s /bin/bash openclaw 2>/dev/null || true

# ── Install OpenClaw ─────────────────────────────────────────────────────────
echo "--- Installing OpenClaw ---"
npm install -g openclaw@latest --quiet
echo "OpenClaw installed: $(openclaw --version 2>/dev/null || echo 'ok')"

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
if [ -n "$REPO_URL" ]; then
  git clone "$REPO_URL" /opt/openclaw-deploy --depth=1 --quiet
else
  echo "WARN: No repo URL in metadata — setup server will not be available."
  exit 0
fi

cd /opt/openclaw-deploy/setup-server
npm install --omit=dev --quiet

# Runtime env for the setup server
cat > /opt/openclaw-deploy/setup-server/.env << SENV
VM_IP=${VM_IP}
PROJECT_ID=${PROJECT_ID}
OPENCLAW_CONFIG=/home/openclaw/.openclaw/openclaw.json
PORT=8080
SENV

chown -R openclaw:openclaw /opt/openclaw-deploy

# ── systemd: openclaw.service ─────────────────────────────────────────────────
cat > /etc/systemd/system/openclaw.service << 'SVC'
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openclaw
ExecStart=/usr/bin/openclaw start
Restart=on-failure
RestartSec=10
WorkingDirectory=/home/openclaw
Environment=HOME=/home/openclaw

[Install]
WantedBy=multi-user.target
SVC

# ── systemd: openclaw-setup.service ──────────────────────────────────────────
cat > /etc/systemd/system/openclaw-setup.service << 'SVC'
[Unit]
Description=OpenClaw Setup Wizard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openclaw
ExecStart=/usr/bin/node /opt/openclaw-deploy/setup-server/server.js
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
systemctl start openclaw.service
systemctl start openclaw-setup.service

echo "=== Startup complete: $(date) ==="
echo "Setup wizard: http://${VM_IP}:8080"
echo "Dashboard:    http://${VM_IP}:18789"
