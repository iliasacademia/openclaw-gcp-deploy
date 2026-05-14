#!/bin/bash
# =============================================================================
# OpenClaw VM Startup Script
# Runs automatically on first boot via GCP startup-script metadata.
# Installs Node.js 24, the setup wizard (early, so diagnostics work), and
# OpenClaw itself.
#
# NOTE: We intentionally do NOT use `set -e`. A startup script that dies on
# the first transient apt/npm error leaves the user with no diagnostics. Each
# critical step checks its own exit code and either retries or fails via
# fail(), which writes a marker that the setup wizard exposes.
# =============================================================================

exec > >(tee /var/log/openclaw-startup.log) 2>&1
echo "=== OpenClaw VM startup: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

fail() {
  echo "FATAL: $*"
  # Marker file picked up by the setup wizard's /api/diagnostics.
  echo "$*" > /var/log/openclaw-startup.failed
  exit 1
}

# ── Read instance metadata ───────────────────────────────────────────────────
META="http://metadata.google.internal/computeMetadata/v1"
md() { curl -sf -H "Metadata-Flavor: Google" "$META/$1"; }

REPO_URL=$(md      "instance/attributes/repo-url"        || echo "")
SETUP_TOKEN=$(md   "instance/attributes/setup-token"     || echo "")
GATEWAY_TOKEN=$(md "instance/attributes/gateway-token"   || echo "")
VM_IP=$(md         "instance/network-interfaces/0/access-configs/0/external-ip")
PROJECT_ID=$(md    "project/project-id")
ZONE=$(md          "instance/zone" | awk -F'/' '{print $NF}')
REGION=$(echo "$ZONE" | sed 's/-[a-z]$//')

[ -n "$REPO_URL" ]      || fail "metadata: repo-url is empty"
[ -n "$SETUP_TOKEN" ]   || fail "metadata: setup-token is empty"
[ -n "$GATEWAY_TOKEN" ] || fail "metadata: gateway-token is empty"
[ -n "$VM_IP" ]         || fail "metadata: external IP unavailable"

echo "PROJECT_ID=${PROJECT_ID}  REGION=${REGION}  ZONE=${ZONE}  VM_IP=${VM_IP}"
echo "REPO_URL=${REPO_URL}"

# ── System packages ──────────────────────────────────────────────────────────
echo "--- Installing system packages ---"
for attempt in 1 2 3; do
  apt-get update -qq && break
  echo "apt-get update failed (${attempt}/3), retrying in 10s..."
  sleep 10
done
apt-get install -y -qq curl git ca-certificates gnupg jq || fail "apt-get install failed"

# ── Node.js 24 ───────────────────────────────────────────────────────────────
echo "--- Installing Node.js 24 ---"
curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
  || fail "NodeSource setup_24.x failed"
apt-get install -y -qq nodejs || fail "apt-get install nodejs failed"
NODE_BIN=$(command -v node || true)
[ -n "$NODE_BIN" ] || fail "node binary not found after install"
echo "Node.js $(node --version) / npm $(npm --version)"

# ── openclaw system user ─────────────────────────────────────────────────────
echo "--- Creating openclaw user ---"
useradd -r -m -d /home/openclaw -s /bin/bash openclaw 2>/dev/null || true

# ── Setup wizard install (early — before the slow openclaw install) ──────────
# Starting the wizard BEFORE installing OpenClaw means that if the OpenClaw
# install or first-start fails, the user can still reach /api/diagnostics and
# see exactly why.
echo "--- Installing setup wizard from ${REPO_URL} ---"
rm -rf /opt/openclaw-deploy
for attempt in 1 2 3; do
  git clone "$REPO_URL" /opt/openclaw-deploy --depth=1 --quiet && break
  echo "git clone failed (${attempt}/3), retrying in 10s..."
  rm -rf /opt/openclaw-deploy
  sleep 10
done
[ -d /opt/openclaw-deploy/setup-server ] \
  || fail "setup-server directory missing after clone"

cd /opt/openclaw-deploy/setup-server
for attempt in 1 2 3; do
  npm install --omit=dev --no-audit --no-fund && break
  echo "npm install for setup-server failed (${attempt}/3), retrying in 10s..."
  sleep 10
done
[ -d /opt/openclaw-deploy/setup-server/node_modules ] \
  || fail "setup-server node_modules missing after install"

cat > /opt/openclaw-deploy/setup-server/.env << SENV
PORT=8080
VM_IP=${VM_IP}
PROJECT_ID=${PROJECT_ID}
REGION=${REGION}
OPENCLAW_CONFIG=/home/openclaw/.openclaw/openclaw.json
SETUP_TOKEN=${SETUP_TOKEN}
GATEWAY_TOKEN=${GATEWAY_TOKEN}
STARTUP_LOG=/var/log/openclaw-startup.log
SENV
chmod 0600 /opt/openclaw-deploy/setup-server/.env

# Write openclaw.json now (before the slow npm install -g openclaw). This way
# the setup wizard's /api/status and /api/telegram never see a missing config
# — eliminating a race where a fast user opens the wizard before the gateway
# binary is installed. The schema is fixed and the gateway token is known
# from VM metadata, so we can write the final shape upfront.
#
# Vertex project/location come from env vars on the gateway service unit, NOT
# this file — the provider config schema rejects unknown keys.
mkdir -p /home/openclaw/.openclaw
cat > /home/openclaw/.openclaw/openclaw.json << OCCONF
{
  "gateway": {
    "mode": "local",
    "port": 18789,
    "bind": "lan",
    "auth": {
      "mode": "token",
      "token": "${GATEWAY_TOKEN}"
    },
    "controlUi": {
      "allowedOrigins": [
        "http://${VM_IP}:18789"
      ]
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "google-vertex/gemini-3.1-pro-preview"
      }
    }
  },
  "channels": {
    "telegram": {
      "enabled": false,
      "dmPolicy": "pairing"
    }
  }
}
OCCONF

chown -R openclaw:openclaw /home/openclaw /opt/openclaw-deploy

# Write + start the setup-wizard systemd unit. We do this now so the user can
# reach the wizard even if everything below this point fails.
cat > /etc/systemd/system/openclaw-setup.service << SVC
[Unit]
Description=OpenClaw Setup Wizard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openclaw
WorkingDirectory=/opt/openclaw-deploy/setup-server
ExecStart=${NODE_BIN} /opt/openclaw-deploy/setup-server/server.js
Restart=on-failure
RestartSec=5
EnvironmentFile=/opt/openclaw-deploy/setup-server/.env

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable --now openclaw-setup.service
sleep 2
systemctl is-active --quiet openclaw-setup.service \
  || fail "openclaw-setup.service did not start — see journalctl -u openclaw-setup"
echo "openclaw-setup running: http://${VM_IP}:8080"

# ── Install OpenClaw globally ────────────────────────────────────────────────
echo "--- Installing OpenClaw via npm (this is the slow step) ---"
for attempt in 1 2 3; do
  npm install -g openclaw@latest && break
  echo "npm install openclaw failed (${attempt}/3), retrying in 15s..."
  sleep 15
done

OPENCLAW_BIN=$(command -v openclaw || true)
[ -n "$OPENCLAW_BIN" ] || fail "openclaw binary not found after install"
echo "openclaw: ${OPENCLAW_BIN} ($(openclaw --version 2>/dev/null || echo unknown))"

# Validate the config we wrote earlier — now that the openclaw binary exists,
# we can surface schema errors with a clear message instead of a systemd
# restart loop.
# Both runuser and sudo -u keep the caller's HOME, so set it explicitly via
# env. openclaw uses $HOME to locate ~/.openclaw/openclaw.json.
runuser -u openclaw -- env HOME=/home/openclaw OPENCLAW_NO_RESPAWN=1 \
  "${OPENCLAW_BIN}" config validate 2>&1 | tee /var/log/openclaw-config-validate.log
VALIDATE_RC=${PIPESTATUS[0]}
[ "$VALIDATE_RC" -eq 0 ] || fail "openclaw config validate rejected the generated config (rc=$VALIDATE_RC)"

# ── sudoers: openclaw can restart its own gateway service ────────────────────
# Debian has usrmerge so /bin and /usr/bin point to the same systemctl; list
# both to keep sudo's strict path matching happy regardless of PATH lookup.
echo "openclaw ALL=(ALL) NOPASSWD: /bin/systemctl restart openclaw-gateway, /usr/bin/systemctl restart openclaw-gateway" \
  > /etc/sudoers.d/openclaw-gateway
chmod 0440 /etc/sudoers.d/openclaw-gateway

# ── openclaw-gateway.service ─────────────────────────────────────────────────
# Service name matches OpenClaw's upstream convention so docs/tools work.
# GOOGLE_CLOUD_PROJECT/LOCATION are required by the google-vertex provider.
cat > /etc/systemd/system/openclaw-gateway.service << SVC
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openclaw
WorkingDirectory=/home/openclaw
ExecStart=${OPENCLAW_BIN} gateway
Restart=on-failure
RestartSec=10
TimeoutStartSec=120
Environment=HOME=/home/openclaw
Environment=GOOGLE_CLOUD_PROJECT=${PROJECT_ID}
Environment=GOOGLE_CLOUD_LOCATION=global
Environment=OPENCLAW_NO_RESPAWN=1

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable --now openclaw-gateway.service
sleep 3
systemctl is-active --quiet openclaw-gateway.service \
  && echo "openclaw-gateway started" \
  || echo "WARN: openclaw-gateway not active — check journalctl -u openclaw-gateway"

echo "=== Startup complete: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "Setup wizard: http://${VM_IP}:8080"
echo "Dashboard:    http://${VM_IP}:18789"
