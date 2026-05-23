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

REPO_URL=$(md      "instance/attributes/repo-url"           || echo "")
SETUP_TOKEN=$(md   "instance/attributes/setup-token"        || echo "")
GATEWAY_TOKEN=$(md "instance/attributes/gateway-token"      || echo "")
GOG_KEYRING=$(md   "instance/attributes/gog-keyring"        || echo "")
VM_IP=$(md         "instance/network-interfaces/0/access-configs/0/external-ip")
PROJECT_ID=$(md    "project/project-id")
ZONE=$(md          "instance/zone" | awk -F'/' '{print $NF}')
REGION=$(echo "$ZONE" | sed 's/-[a-z]$//')

[ -n "$REPO_URL" ]      || fail "metadata: repo-url is empty"
[ -n "$SETUP_TOKEN" ]   || fail "metadata: setup-token is empty"
[ -n "$GATEWAY_TOKEN" ] || fail "metadata: gateway-token is empty"
[ -n "$GOG_KEYRING" ]   || fail "metadata: gog-keyring is empty"
[ -n "$VM_IP" ]         || fail "metadata: external IP unavailable"
[ -n "$PROJECT_ID" ]    || fail "metadata: project ID unavailable (needed for Vertex AI)"
[ -n "$ZONE" ]          || fail "metadata: zone unavailable"

# sslip.io maps <dashed-ip>.sslip.io → that IP. We compute the hostname once
# here and reuse it for Caddy, the openclaw.json allowedOrigins, and the
# setup-server's DASHBOARD_BASE_URL.
VM_IP_DASHED=$(echo "$VM_IP" | tr '.' '-')
SSLIP_DOMAIN="${VM_IP_DASHED}.sslip.io"

echo "PROJECT_ID=${PROJECT_ID}  REGION=${REGION}  ZONE=${ZONE}  VM_IP=${VM_IP}"
echo "REPO_URL=${REPO_URL}"

# Retry an apt-get install several times — transient mirror failures are
# common enough that one shot isn't safe.
apt_install() {
  for attempt in 1 2 3; do
    apt-get install -y -qq "$@" && return 0
    echo "apt-get install $* failed (${attempt}/3), retrying in 10s..."
    sleep 10
  done
  return 1
}

# ── System packages ──────────────────────────────────────────────────────────
echo "--- Installing system packages ---"
for attempt in 1 2 3; do
  apt-get update -qq && break
  echo "apt-get update failed (${attempt}/3), retrying in 10s..."
  sleep 10
done
apt_install curl git ca-certificates gnupg jq || fail "apt-get install (base packages) failed after 3 retries"

# ── Node.js 24 ───────────────────────────────────────────────────────────────
echo "--- Installing Node.js 24 ---"
curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
  || fail "NodeSource setup_24.x failed"
apt_install nodejs || fail "apt-get install nodejs failed after 3 retries"
NODE_BIN=$(command -v node || true)
[ -n "$NODE_BIN" ] || fail "node binary not found after install"
echo "Node.js $(node --version) / npm $(npm --version)"

# ── openclaw system user ─────────────────────────────────────────────────────
# If the user already exists (re-run / image reuse), just keep it. If creation
# fails for any other reason, fail loudly — silently swallowing this would
# cause every subsequent chown/runuser to break with confusing errors.
echo "--- Creating openclaw user ---"
if ! id openclaw >/dev/null 2>&1; then
  useradd -r -m -d /home/openclaw -s /bin/bash openclaw \
    || fail "useradd openclaw failed"
fi

# Grant journal read access so the setup wizard's diagnostics endpoint can
# tail `journalctl -u openclaw-gateway` etc. Without this, the diagnostics
# panel shows "(no logs yet)" even when the service is happily running and
# we lose our most useful debug surface. systemd-journal exists by default
# on Debian; -a is idempotent.
if getent group systemd-journal >/dev/null 2>&1; then
  usermod -a -G systemd-journal openclaw \
    || echo "WARN: could not add openclaw to systemd-journal group (diagnostics will be incomplete)"
fi

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
DASHBOARD_BASE_URL=https://${SSLIP_DOMAIN}
SSLIP_DOMAIN=${SSLIP_DOMAIN}
STARTUP_LOG=/var/log/openclaw-startup.log
GOG_KEYRING_PASSWORD=${GOG_KEYRING}
SENV
chmod 0600 /opt/openclaw-deploy/setup-server/.env

# ── Caddy: auto-HTTPS for the gateway dashboard ──────────────────────────────
# OpenClaw's Control UI calls Web Crypto APIs that the browser BLOCKS outside
# a secure context (HTTPS or localhost). Plain HTTP at the VM's public IP
# fails that check before any backend logic runs, so the dashboard never
# loads from a remote browser — even with controlUi.allowInsecureAuth: true,
# which only helps loopback access.
#
# Fix: a real domain + real cert. sslip.io is a free DNS service that resolves
# <ip-with-dashes>.sslip.io → that IP. Caddy fetches a Let's Encrypt cert for
# that hostname automatically. Result: a valid HTTPS URL with zero domain
# registration and zero cert management.
echo "--- Installing Caddy for auto-HTTPS ---"
CADDY_VERSION=2.9.1
case "$(dpkg --print-architecture)" in
  amd64) CADDY_ARCH=amd64 ;;
  arm64) CADDY_ARCH=arm64 ;;
  *)     fail "unsupported arch for Caddy" ;;
esac
curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${CADDY_ARCH}.tar.gz" \
  | tar -xzC /tmp caddy 2>/dev/null
[ -f /tmp/caddy ] || fail "Caddy download failed"
mv /tmp/caddy /usr/local/bin/caddy
chmod +x /usr/local/bin/caddy

if ! id caddy >/dev/null 2>&1; then
  useradd --system --home /var/lib/caddy --shell /usr/sbin/nologin caddy \
    || fail "useradd caddy failed"
fi
mkdir -p /etc/caddy /var/lib/caddy /var/log/caddy
chown -R caddy:caddy /var/lib/caddy /var/log/caddy

echo "Dashboard HTTPS host: ${SSLIP_DOMAIN}"

cat > /etc/caddy/Caddyfile << CADDYFILE
{
  email admin@${SSLIP_DOMAIN}
}

${SSLIP_DOMAIN} {
  reverse_proxy localhost:18789
}
CADDYFILE

cat > /etc/systemd/system/caddy.service << SVC
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
Environment=HOME=/var/lib/caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable --now caddy.service

# Write openclaw.json now (before the slow npm install -g openclaw). The
# wizard's /api/status and /api/telegram never see a missing config and a
# fast user can't race ahead of the gateway binary install.
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
      "dangerouslyDisableDeviceAuth": true,
      "allowedOrigins": [
        "http://${VM_IP}:18789",
        "https://${SSLIP_DOMAIN}"
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
  },
  "skills": {
    "entries": {
      "gog": { "enabled": true }
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

# Poll for the service to come up. `Type=simple` units flip to active as soon
# as ExecStart spawns, so this usually settles in well under a second — but a
# fixed sleep is fragile on a slow VM.
for i in 1 2 3 4 5 6 7 8 9 10; do
  if systemctl is-active --quiet openclaw-setup.service; then break; fi
  sleep 1
done
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

# ── Install gog (Google Workspace CLI) ───────────────────────────────────────
# The "gog" skill that OpenClaw uses for Gmail/Calendar/Drive requires the
# `gog` binary in PATH. Install it from upstream release tarball — no brew on
# Debian. Best-effort: if this fails the rest of the deploy still works, just
# the gog skill won't be usable until the user installs it manually.
echo "--- Installing gog (Google Workspace CLI) ---"
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
  amd64) GOG_ARCH=amd64 ;;
  arm64) GOG_ARCH=arm64 ;;
  *)     GOG_ARCH="" ;;
esac
if [ -n "$GOG_ARCH" ]; then
  echo "  arch: ${ARCH} → gog asset arch: ${GOG_ARCH}"
  # Latest-release filename uses the actual version (e.g. gogcli_1.2.3_linux_amd64.tar.gz).
  # Resolve the tag via GitHub's API so we can construct the exact URL.
  GOG_TAG=$(curl -sf https://api.github.com/repos/openclaw/gogcli/releases/latest \
    | grep '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')
  if [ -n "$GOG_TAG" ]; then
    GOG_URL="https://github.com/openclaw/gogcli/releases/download/v${GOG_TAG}/gogcli_${GOG_TAG}_linux_${GOG_ARCH}.tar.gz"
    echo "  resolved release: v${GOG_TAG}"
    echo "  url: ${GOG_URL}"
    # Download to a tempfile first so we can log size / inspect on failure,
    # instead of piping straight to tar where a 404 silently produces an
    # empty tar stream.
    rm -f /tmp/gog.tar.gz
    if curl -fSL --max-time 60 -o /tmp/gog.tar.gz "$GOG_URL" 2>/tmp/gog.curl.err; then
      GOG_SIZE=$(stat -c%s /tmp/gog.tar.gz 2>/dev/null || echo "?")
      echo "  download ok (size: ${GOG_SIZE} bytes)"
      if tar -xzf /tmp/gog.tar.gz -C /usr/local/bin gog 2>/tmp/gog.tar.err; then
        chmod +x /usr/local/bin/gog
        echo "gog $(gog --version 2>/dev/null || echo installed)"
      else
        echo "WARN: tar extract failed for ${GOG_URL}"
        echo "WARN:   tar stderr: $(tr '\n' ' ' < /tmp/gog.tar.err)"
        echo "WARN:   first 200 bytes of payload: $(head -c 200 /tmp/gog.tar.gz | tr -c '[:print:]' '?')"
      fi
    else
      echo "WARN: curl download failed for ${GOG_URL}"
      echo "WARN:   curl stderr: $(tr '\n' ' ' < /tmp/gog.curl.err)"
    fi
    rm -f /tmp/gog.tar.gz /tmp/gog.curl.err /tmp/gog.tar.err
  else
    echo "WARN: could not resolve gog latest release tag from GitHub API (continuing without gog)"
  fi
else
  echo "WARN: unsupported arch '${ARCH}' for gog (continuing without gog)"
fi

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
Environment=GOG_KEYRING_PASSWORD=${GOG_KEYRING}
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
