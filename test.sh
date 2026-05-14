#!/bin/bash
# =============================================================================
# OpenClaw GCP Deploy — local test harness
# Runs everything we can verify WITHOUT actually deploying to GCP:
#   - shell syntax (bash -n) on every .sh
#   - JS syntax (node --check) on server-side JS
#   - JSON validity on package.json
#   - Real openclaw config validate on the generated config shape
#     (skipped if openclaw isn't installed locally; install with:
#      npm install -g openclaw)
#   - End-to-end smoke test of the setup wizard against a temp config
#
# Usage:
#   bash test.sh
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

pass=0; fail=0; skip=0
check() {
  local name="$1"; shift
  if "$@" >/tmp/oc-test-out 2>&1; then
    echo -e "  ${GREEN}✓${NC} $name"
    pass=$((pass+1))
  else
    echo -e "  ${RED}✗${NC} $name"
    sed 's/^/      /' /tmp/oc-test-out
    fail=$((fail+1))
  fi
}
skip_test() { echo -e "  ${YELLOW}-${NC} $1 ${DIM}(skipped: $2)${NC}"; skip=$((skip+1)); }

echo -e "${BOLD}── Shell syntax ─────────────────────────────────────${NC}"
for f in deploy.sh startup.sh cleanup.sh; do
  check "bash -n $f" bash -n "$f"
done

echo -e "\n${BOLD}── JS syntax ────────────────────────────────────────${NC}"
check "node --check setup-server/server.js"     node --check setup-server/server.js
check "node --check setup-server/public/app.js" node --check setup-server/public/app.js

echo -e "\n${BOLD}── JSON files ───────────────────────────────────────${NC}"
check "setup-server/package.json is valid JSON" \
  python3 -c "import json; json.load(open('setup-server/package.json'))"

echo -e "\n${BOLD}── Generated openclaw.json shape ────────────────────${NC}"
GATEWAY_TOKEN="abc123def456789012345678901234ab"
VM_IP="1.2.3.4"
CONFIG=$(mktemp)
trap 'rm -f $CONFIG /tmp/oc-test-out' EXIT
# Extract the heredoc body literally from startup.sh, substitute the two
# template vars, write. We use sed (vs envsubst, which isn't on macOS).
awk '/cat > \/home\/openclaw\/.openclaw\/openclaw.json << OCCONF/{f=1; next} /^OCCONF$/{f=0} f' \
  startup.sh \
  | sed -e "s|\${GATEWAY_TOKEN}|${GATEWAY_TOKEN}|g" \
        -e "s|\${VM_IP}|${VM_IP}|g" > "$CONFIG"

check "extracted config is valid JSON" \
  python3 -c "import json; json.load(open('$CONFIG'))"

if command -v openclaw >/dev/null 2>&1; then
  check "openclaw config validate (real schema)" \
    env OPENCLAW_NO_RESPAWN=1 OPENCLAW_CONFIG_PATH="$CONFIG" openclaw config validate
else
  skip_test "openclaw config validate" "openclaw CLI not installed locally"
fi

echo -e "\n${BOLD}── Setup wizard smoke test ──────────────────────────${NC}"
if [ ! -d setup-server/node_modules ]; then
  echo "  installing setup-server deps..."
  (cd setup-server && npm install --omit=dev --no-audit --no-fund --silent)
fi

# Reuse the same temp config; seed with the schema-valid shape.
PORT=18099
PORT="$PORT" VM_IP="1.2.3.4" PROJECT_ID="test-proj" REGION="us-central1" \
SETUP_TOKEN="testtoken1234567890" GATEWAY_TOKEN="gwtoken1234567890" \
OPENCLAW_CONFIG="$CONFIG" STARTUP_LOG="$CONFIG.startup" \
node setup-server/server.js >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; rm -f $CONFIG $CONFIG.startup /tmp/oc-test-out' EXIT
echo "startup line" > "$CONFIG.startup"

# Wait for boot (up to 5s)
for i in 1 2 3 4 5 6 7 8 9 10; do
  curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && break
  sleep 0.5
done

# Helper: do a curl, capture body, echo just the HTTP code so `check` can
# string-compare. Inline-defined so the bash -c subshell sees it.
http_code() { curl -s -o /tmp/oc-test-out -w '%{http_code}' "$@"; }

check_code() {
  local name="$1" want="$2"; shift 2
  local got; got=$(http_code "$@")
  if [ "$got" = "$want" ]; then
    echo -e "  ${GREEN}✓${NC} $name ${DIM}(${got})${NC}"; pass=$((pass+1))
  else
    echo -e "  ${RED}✗${NC} $name ${DIM}(wanted ${want}, got ${got})${NC}"
    sed 's/^/      /' /tmp/oc-test-out
    fail=$((fail+1))
  fi
}

check_code "/health returns 200 (no auth)" 200 \
  "http://localhost:$PORT/health"

check_code "/api/status rejects missing token" 403 \
  "http://localhost:$PORT/api/status"

check_code "/api/status rejects wrong token" 403 \
  "http://localhost:$PORT/api/status?token=wrong"

check_code "/api/status accepts valid token" 200 \
  "http://localhost:$PORT/api/status?token=testtoken1234567890"

check_code "/api/telegram rejects malformed token" 400 \
  -X POST -H 'Content-Type: application/json' \
  -d '{"token":"bad"}' \
  "http://localhost:$PORT/api/telegram?token=testtoken1234567890"

check_code "/api/telegram accepts well-formed token" 200 \
  -X POST -H 'Content-Type: application/json' \
  -d '{"token":"123456789:ABCdefGHIjklMNOpqrSTUvwxYZabcdef0123"}' \
  "http://localhost:$PORT/api/telegram?token=testtoken1234567890"

DIAG=$(curl -s "http://localhost:$PORT/api/diagnostics?token=testtoken1234567890")

check "/api/diagnostics redacts gateway token" \
  bash -c "echo '$DIAG' | grep -q '\"token\":\"\\*\\*\\*\"'"

check "/api/diagnostics surfaces setupServerVersion" \
  bash -c "echo '$DIAG' | grep -q '\"setupServerVersion\":\"'"

check "config persisted after /api/telegram (telegram.enabled=true)" \
  python3 -c "import json; c=json.load(open('$CONFIG')); assert c['channels']['telegram']['enabled'] is True"

# Fail-closed: server should refuse to start without SETUP_TOKEN
fail_closed() {
  PORT=18098 VM_IP=x PROJECT_ID=x REGION=x SETUP_TOKEN= GATEWAY_TOKEN=x \
    OPENCLAW_CONFIG="$CONFIG" node setup-server/server.js
  [ $? -eq 1 ]
}
check "fail-closed: server exits 1 with empty SETUP_TOKEN" fail_closed

kill $SRV 2>/dev/null || true

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Result ───────────────────────────────────────────${NC}"
echo -e "  ${GREEN}pass=${pass}${NC}  ${RED}fail=${fail}${NC}  ${YELLOW}skip=${skip}${NC}"
[ "$fail" -eq 0 ]
