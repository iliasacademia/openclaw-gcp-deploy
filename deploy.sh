#!/bin/bash
# =============================================================================
# OpenClaw GCP Deploy
# Deploys OpenClaw on a GCP VM with Vertex AI (Gemini) as the LLM backend.
# Run this from Cloud Shell — no configuration needed.
# =============================================================================
set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log()     { echo -e "${BLUE}▸${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
die()     { echo -e "\n${RED}✗ ERROR:${NC} $*\n"; exit 1; }
header()  { echo -e "\n${BOLD}$*${NC}"; echo -e "${DIM}$(printf '─%.0s' {1..50})${NC}"; }

# ── Live spinner for long-running operations ─────────────────────────────────
# gcloud commands like `services enable` go silent for 1-2 minutes, which
# makes Cloud Shell look frozen. with_spinner runs the command in the
# background and prints a braille spinner + elapsed seconds so the user can
# see we're still alive. On failure, dumps the captured output indented.
#
#   with_spinner "Doing thing" some-cmd --arg
#
# Use with_spinner_capture when the caller needs to inspect the output
# (e.g. parse stderr for specific error codes). Output path is exposed via
# the global WITH_SPINNER_LOG; the caller must `rm -f` it when done.
WITH_SPINNER_LOG=""

with_spinner() {
  local label="$1"; shift
  local logf; logf=$(mktemp)
  _spinner_run "$label" "$logf" "$@"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "" >&2
    sed 's/^/    /' "$logf" >&2
  fi
  rm -f "$logf"
  return "$rc"
}

with_spinner_capture() {
  local label="$1"; shift
  WITH_SPINNER_LOG=$(mktemp)
  _spinner_run "$label" "$WITH_SPINNER_LOG" "$@"
  return $?
}

_spinner_run() {
  local label="$1"; shift
  local logf="$1"; shift
  "$@" >"$logf" 2>&1 &
  local pid=$!
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  local i=0
  local start; start=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    local elapsed=$(( $(date +%s) - start ))
    local frame="${frames[i % ${#frames[@]}]}"
    printf "\r  ${BLUE}%s${NC} %s ${DIM}— %ds elapsed${NC}     " "$frame" "$label" "$elapsed"
    i=$((i + 1))
    sleep 0.2
  done
  local rc=0
  wait "$pid" || rc=$?
  local elapsed=$(( $(date +%s) - start ))
  if [ "$rc" -eq 0 ]; then
    printf "\r  ${GREEN}✓${NC} %s ${DIM}(%ds)${NC}                                                          \n" "$label" "$elapsed"
  else
    printf "\r  ${RED}✗${NC} %s ${DIM}(failed after %ds)${NC}                                                \n" "$label" "$elapsed"
  fi
  return "$rc"
}

# A simple visible countdown for fixed-length waits (e.g. API propagation).
countdown() {
  local label="$1"
  local total="$2"
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  local i=0
  for s in $(seq 1 "$total"); do
    local frame="${frames[i % ${#frames[@]}]}"
    local remaining=$(( total - s ))
    printf "\r  ${BLUE}%s${NC} %s ${DIM}— %ds remaining${NC}     " "$frame" "$label" "$remaining"
    i=$((i + 1))
    sleep 1
  done
  printf "\r  ${GREEN}✓${NC} %s ${DIM}(%ds elapsed)${NC}                                          \n" "$label" "$total"
}

# ── Banner ───────────────────────────────────────────────────────────────────
# Replaced the original figlet "OpenClaw" ASCII (which read as ambiguous block
# shapes rather than letters on first glance) with a plain centered title
# that says what it is. "GCP Deploy" stays as a dim subscript underneath.
clear
echo ""
echo -e "  ${BLUE}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "  ${BLUE}${BOLD}║${NC}                                                              ${BLUE}${BOLD}║${NC}"
echo -e "  ${BLUE}${BOLD}║${NC}                  ${BOLD}Easy OpenClaw Deployment${NC}                    ${BLUE}${BOLD}║${NC}"
echo -e "  ${BLUE}${BOLD}║${NC}                                                              ${BLUE}${BOLD}║${NC}"
echo -e "  ${BLUE}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Deploying OpenClaw on Google Cloud (~5 minutes)."
echo -e "  ${DIM}No configuration needed — just sit back.${NC}\n"

# ── Locate repo and find startup.sh ──────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "${SCRIPT_DIR}/startup.sh" ] \
  || die "startup.sh not found next to deploy.sh — run this from the cloned repo."

REPO_URL=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null \
  | sed 's/\.git$//' \
  | sed 's|git@github.com:|https://github.com/|' || true)
[ -n "$REPO_URL" ] \
  || die "Could not determine repo URL. Run this from inside the cloned repository."

# ── Prerequisite: billing ────────────────────────────────────────────────────
header "Checking prerequisites"

BILLING_ACCOUNT=$(gcloud billing accounts list \
  --format="value(name)" --filter="open=true" 2>/dev/null | head -1 || true)

if [ -z "$BILLING_ACCOUNT" ]; then
  die "No active billing account found.\n\n  Activate your free trial at:\n  ${BLUE}https://console.cloud.google.com/billing${NC}\n\n  Then re-run this script."
fi
success "Billing account: ${DIM}${BILLING_ACCOUNT}${NC}"
success "Repo: ${DIM}${REPO_URL}${NC}"

# ── Prerequisite: Google Cloud Application Default Credentials ───────────────
# OpenClaw 2026.5.20+ requires the google-vertex provider to find an ADC
# file with type=authorized_user. The GCE metadata-server credentials (what
# the VM's service account provides automatically) don't satisfy that check
# — only the JSON file produced by `gcloud auth application-default login`
# does. So we make sure that file exists on the user's Cloud Shell, then
# ship it to the VM via metadata.
ADC_FILE="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json"

if [ ! -f "$ADC_FILE" ]; then
  echo ""
  log "Setting up Google Cloud credentials for Vertex AI (one-time, ~30 seconds)..."
  log "${DIM}OpenClaw needs your Google account's credentials to call Gemini through Vertex AI.${NC}"
  log "${DIM}This is separate from the Cloud Shell login and only has to be done once per user.${NC}"
  echo ""
  log "${BOLD}Open the URL below in your browser, sign in, click Allow,${NC}"
  log "${BOLD}and paste the verification code back here.${NC}"
  echo ""

  # Cloud Shell IS a GCE VM, so `gcloud auth application-default login`
  # prints a multi-line "you're on GCE, use the SA instead" warning + Y/n
  # prompt. We're knowingly opting in to user-OAuth ADC (because OpenClaw
  # requires it), so silently auto-accept the prompt with "y" and strip the
  # warning from gcloud's output so the user sees a clean URL + code flow.
  #
  # Tricky bit: `cat </dev/tty` keeps reading from the terminal even after
  # gcloud has consumed the verification code and exited. Its next write to
  # the (now-closed) pipe triggers SIGPIPE, and `set -o pipefail` propagates
  # that as a pipeline failure even though gcloud actually succeeded. So we
  # locally disable pipefail and read gcloud's true exit code from
  # PIPESTATUS instead of the overall pipe exit. Also include "Do you want
  # to continue" in the grep filter — recent gcloud versions changed the
  # prompt wording from "Are you sure you want" to that.
  if curl -sf -m 2 -H "Metadata-Flavor: Google" \
       http://metadata.google.internal/computeMetadata/v1/ > /dev/null 2>&1; then
    set +o pipefail
    { printf "y\n"; exec cat </dev/tty; } | \
      gcloud auth application-default login --no-launch-browser 2>&1 | \
      grep --line-buffered -vE \
        "Compute Engine virtual machine|service credentials associated|automatically be used by Application|necessary to use this command|If you decide to proceed|user credentials may be visible|authenticate with your personal account|Are you sure you want|Do you want to continue"
    GCLOUD_EXIT=${PIPESTATUS[1]}
    set -o pipefail
    [ "$GCLOUD_EXIT" -eq 0 ] \
      || die "gcloud auth application-default login failed (exit ${GCLOUD_EXIT}). Re-run this script and complete the flow."
  else
    gcloud auth application-default login --no-launch-browser \
      || die "gcloud auth application-default login failed. Re-run this script and complete the flow."
  fi
  echo ""
fi

[ -f "$ADC_FILE" ] || die "Application Default Credentials file is still missing at ${ADC_FILE}. Re-run."

# Validate it's an authorized_user file (the only type OpenClaw's google-vertex
# provider accepts). gcloud sometimes also writes external_account or impersonated
# types; reject those with a clear error rather than letting the deploy succeed
# and the bot silently fail later.
ADC_TYPE=$(python3 -c "import json,sys; print(json.load(open('$ADC_FILE')).get('type','unknown'))" 2>/dev/null || echo parse_error)
if [ "$ADC_TYPE" != "authorized_user" ]; then
  die "ADC file at ${ADC_FILE} has type='${ADC_TYPE}', but OpenClaw needs 'authorized_user'.\n\n  Fix: run\n    gcloud auth application-default login\n  then re-run this script."
fi

# We pass the file as-is via --metadata-from-file (cleaner than base64ing it
# through --metadata, since metadata-from-file handles binary/multiline
# values and gcloud parses them server-side).
success "Application Default Credentials: ${DIM}${ADC_FILE}${NC}"

# ── Single-use tokens ────────────────────────────────────────────────────────
# Two distinct tokens: SETUP_TOKEN gates the setup wizard, GATEWAY_TOKEN gates
# the OpenClaw dashboard. Generated here so we can print URLs at the end.
gen_token() { head -c 24 /dev/urandom | base64 | tr -d '+/=' | head -c 32; }
SETUP_TOKEN=$(gen_token)
GATEWAY_TOKEN=$(gen_token)
GOG_KEYRING_PASSWORD=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')

# ── Clean up stale projects from previous failed runs ────────────────────────
header "Creating GCP project"

STALE=$(gcloud projects list \
  --filter="projectId:my-first-claw-* AND lifecycleState:ACTIVE" \
  --format="value(projectId)" 2>/dev/null || true)

if [ -n "$STALE" ]; then
  warn "Cleaning up project(s) from previous runs:"
  echo "$STALE" | while read -r pid; do
    [ -z "$pid" ] && continue
    with_spinner "Deleting ${pid}" gcloud projects delete "$pid" --quiet || true
  done
  countdown "Letting deletions register" 15
fi

SUFFIX=$(printf '%04d' $((RANDOM % 10000)))
PROJECT_ID="my-first-claw-${SUFFIX}"
PROJECT_NAME="My First Claw Agent"

log "Project name : ${PROJECT_NAME}"
log "Project ID   : ${PROJECT_ID}"

with_spinner "Creating project ${PROJECT_ID}" \
  gcloud projects create "$PROJECT_ID" --name="$PROJECT_NAME" --quiet \
  || die "Failed to create project — you may have hit the GCP project quota.\n\n  Fix:\n  1. Open ${BLUE}https://console.cloud.google.com/cloud-resource-manager${NC}\n  2. Permanently delete any pending-deletion 'my-first-claw-*' projects\n  3. Re-run this script."

# Link billing — we need to inspect stderr to detect the "billing quota
# exceeded" case and give a targeted fix, so use the capture variant.
if ! with_spinner_capture "Linking billing account" \
    gcloud billing projects link "$PROJECT_ID" \
      --billing-account="$BILLING_ACCOUNT" --quiet; then
  BILLING_ERR=$(cat "$WITH_SPINNER_LOG")
  rm -f "$WITH_SPINNER_LOG"
  if echo "$BILLING_ERR" | grep -q "billing quota exceeded"; then
    die "GCP billing quota exceeded.\n\n  Fix:\n  1. Open ${BLUE}https://console.cloud.google.com/cloud-resource-manager${NC}\n  2. Permanently delete any pending-deletion projects\n  3. Wait ~5 minutes, then re-run this script."
  fi
  die "Could not link billing.\n  ${BILLING_ERR}"
fi
rm -f "$WITH_SPINNER_LOG"

# ── Enable APIs ──────────────────────────────────────────────────────────────
header "Enabling GCP APIs"

# gcloud bundles all 11 services into a single backend operation and emits
# basically no output until it completes — often 60-120s. with_spinner gives
# the user a visible heartbeat instead of a dead-looking terminal.
with_spinner "Enabling 11 GCP APIs (Compute / Vertex AI / IAM / Workspace)" \
  gcloud services enable \
    compute.googleapis.com \
    aiplatform.googleapis.com \
    iam.googleapis.com \
    iamcredentials.googleapis.com \
    cloudresourcemanager.googleapis.com \
    gmail.googleapis.com \
    calendar-json.googleapis.com \
    drive.googleapis.com \
    people.googleapis.com \
    sheets.googleapis.com \
    docs.googleapis.com \
    --project="$PROJECT_ID" --quiet \
  || die "Failed to enable APIs — check that the project was created and billing is linked."

# APIs need ~30-60s to fully propagate before dependent operations work.
countdown "Waiting for API propagation" 60

# ── Dedicated service account for the VM ─────────────────────────────────────
# Using a dedicated SA avoids the default Compute Engine SA, which newer GCP
# projects may not auto-create (or may not auto-grant Editor to). Also lets us
# scope the VM to *only* aiplatform.user — least privilege.
header "Creating VM service account"

VM_SA_NAME="openclaw-vm"
VM_SA="${VM_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

with_spinner "Creating service account ${VM_SA_NAME}" \
  gcloud iam service-accounts create "$VM_SA_NAME" \
    --display-name="OpenClaw VM service account" \
    --project="$PROJECT_ID" --quiet \
  || die "Could not create service account ${VM_SA_NAME}"

# SA creation can take a few seconds to be visible to IAM bindings.
for i in 1 2 3 4 5; do
  if gcloud projects add-iam-policy-binding "$PROJECT_ID" \
       --member="serviceAccount:${VM_SA}" \
       --role="roles/aiplatform.user" \
       --quiet >/dev/null 2>&1; then
    break
  fi
  log "IAM binding attempt ${i}/5 — waiting for SA propagation..."
  sleep 5
done
success "Granted aiplatform.user to ${DIM}${VM_SA}${NC}"

# ── Create VM ────────────────────────────────────────────────────────────────
header "Creating VM"

VM_NAME="openclaw-vm"
MACHINE_TYPE="n2-standard-2"

# n2 capacity varies by zone — try several.
ZONES=(us-central1-a us-central1-b us-central1-c us-central1-f
       us-east1-b   us-east1-c   us-west1-a    us-west1-b)

log "Machine: ${MACHINE_TYPE}  OS: Debian 13  Disk: 20 GB"

ZONE=""
# VM creation per zone can take 30-60s and frequently fails on the first
# couple of zones due to capacity exhaustion. with_spinner_capture lets us
# show progress AND inspect the error so we can distinguish "zone full"
# (try next) from "real failure" (show details).
for z in "${ZONES[@]}"; do
  if with_spinner_capture "Trying zone ${z}" \
      gcloud compute instances create "$VM_NAME" \
        --project="$PROJECT_ID" \
        --zone="$z" \
        --machine-type="$MACHINE_TYPE" \
        --image-family="debian-13" \
        --image-project="debian-cloud" \
        --boot-disk-size="20GB" \
        --boot-disk-type="pd-balanced" \
        --tags="openclaw" \
        --service-account="$VM_SA" \
        --scopes="cloud-platform" \
        --metadata="repo-url=${REPO_URL},setup-token=${SETUP_TOKEN},gateway-token=${GATEWAY_TOKEN},gog-keyring=${GOG_KEYRING_PASSWORD}" \
        --metadata-from-file="startup-script=${SCRIPT_DIR}/startup.sh,gcp-adc=${ADC_FILE}" \
        --quiet; then
    ZONE="$z"
    rm -f "$WITH_SPINNER_LOG"
    break
  fi
  # Detect the specific "zone is full" error and report it cleanly. Anything
  # else (auth, quota, etc.) is a real failure — print the captured stderr.
  if grep -q "ZONE_RESOURCE_POOL_EXHAUSTED\|does not have enough resources" "$WITH_SPINNER_LOG"; then
    warn "  ${z} is at capacity, trying next zone…"
  else
    warn "  ${z} failed for an unexpected reason. Details:"
    sed 's/^/    /' "$WITH_SPINNER_LOG"
  fi
  rm -f "$WITH_SPINNER_LOG"
done
[ -n "$ZONE" ] || die "Could not create VM in any zone — likely a transient GCP capacity issue. Wait a few minutes and re-run."

VM_IP=$(gcloud compute instances describe "$VM_NAME" \
  --project="$PROJECT_ID" --zone="$ZONE" \
  --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || true)
# Validate we actually got an IPv4 — if `describe` failed or returned something
# weird, the URL we print later would be broken and the user would be stuck.
if ! echo "$VM_IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
  die "Could not read the VM's external IP (got: '${VM_IP}'). The VM was created in ${ZONE} but the deploy script can't continue without its IP. Try:\n  gcloud compute instances describe ${VM_NAME} --project=${PROJECT_ID} --zone=${ZONE}"
fi
success "VM created in ${ZONE} — IP: ${BOLD}${VM_IP}${NC}"

# ── Firewall ─────────────────────────────────────────────────────────────────
header "Opening ports"

with_spinner "Creating firewall rule allow-openclaw" \
  gcloud compute firewall-rules create allow-openclaw \
    --project="$PROJECT_ID" \
    --direction=INGRESS \
    --priority=1000 \
    --network=default \
    --action=ALLOW \
    --rules=tcp:80,tcp:443,tcp:8080,tcp:18789 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=openclaw \
    --quiet \
  || die "Could not create firewall rule allow-openclaw."

success "Port 80    → Caddy / Let's Encrypt ACME"
success "Port 443   → OpenClaw dashboard (HTTPS via sslip.io)"
success "Port 8080  → Setup wizard"
success "Port 18789 → Gateway (proxied by Caddy)"

# ── Print URL UPFRONT so the user can copy it even if Cloud Shell dies ──────
# We used to wait for the polling loop to complete before printing the URL.
# Cloud Shell sessions can drop (idle timeout, network blip, accidental tab
# close) during the 5-7 minute wait — at which point the user had NO way to
# recover the URL without SSHing into the VM. Print it NOW.
SETUP_LINK="http://${VM_IP}:8080?token=${SETUP_TOKEN}"

echo ""
echo -e "${BLUE}${BOLD}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BLUE}${BOLD}│  📋  Your setup URL (copy this NOW — save it somewhere):    │${NC}"
echo -e "${BLUE}${BOLD}└─────────────────────────────────────────────────────────────┘${NC}"
echo -e "      ${GREEN}${BOLD}${SETUP_LINK}${NC}"
echo ""
echo -e "  ${DIM}Project : ${PROJECT_NAME} (${PROJECT_ID})"
echo -e "  VM      : ${VM_NAME}  /  ${ZONE}"
echo -e "  VM IP   : ${VM_IP}${NC}"
echo ""

# ── Wait for setup wizard ────────────────────────────────────────────────────
header "Waiting for OpenClaw to finish installing on the VM"
log "Installing Node 24 + OpenClaw + setup wizard + Caddy (TLS cert)..."
log "${DIM}Typical install time: 4-6 minutes. If you have the URL above you can${NC}"
log "${DIM}leave this Cloud Shell tab — the VM will keep installing on its own.${NC}"

SETUP_HEALTH="http://${VM_IP}:8080/health"
MAX_ATTEMPTS=120   # 120 × 5s = 10 minutes
READY=false
HEALTH_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

for i in $(seq 1 $MAX_ATTEMPTS); do
  frame="${HEALTH_FRAMES[i % ${#HEALTH_FRAMES[@]}]}"
  elapsed=$(( i * 5 ))
  printf "\r  ${BLUE}%s${NC} Waiting for setup wizard ${DIM}— %ds elapsed, attempt %d/%d${NC}     " \
    "$frame" "$elapsed" "$i" "$MAX_ATTEMPTS"
  if curl -sf --max-time 5 "$SETUP_HEALTH" >/dev/null 2>&1; then
    READY=true
    printf "\r  ${GREEN}✓${NC} Setup wizard responded ${DIM}(after %ds)${NC}                                          \n" "$elapsed"
    break
  fi
  sleep 5
done
[ "$READY" = true ] || echo ""

# ── Final status ─────────────────────────────────────────────────────────────
# We re-print the URL with the same prominence as the upfront copy so the
# user doesn't need to scroll back through 7 minutes of polling output.
echo ""
echo ""
if [ "$READY" = true ]; then
  echo -e "${GREEN}${BOLD}┌─────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${GREEN}${BOLD}│  ✅  OpenClaw is ready! Open this URL to finish setup:      │${NC}"
  echo -e "${GREEN}${BOLD}└─────────────────────────────────────────────────────────────┘${NC}"
  echo -e "      ${GREEN}${BOLD}${SETUP_LINK}${NC}"
  echo ""
  echo -e "  ${DIM}(Use a regular Chrome/Firefox/Safari window — not Incognito.)${NC}"
else
  echo -e "${YELLOW}${BOLD}┌─────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${YELLOW}${BOLD}│  ⏳  VM didn't respond in 10 min — try the URL anyway:      │${NC}"
  echo -e "${YELLOW}${BOLD}└─────────────────────────────────────────────────────────────┘${NC}"
  echo -e "      ${BLUE}${BOLD}${SETUP_LINK}${NC}"
  echo ""
  echo -e "  ${DIM}The VM may still be installing. If the page never loads, SSH in:"
  echo -e "    gcloud compute ssh ${VM_NAME} --project=${PROJECT_ID} --zone=${ZONE}"
  echo -e "    sudo tail -100 /var/log/openclaw-startup.log${NC}"
fi
echo ""
echo -e "  ${DIM}Project : ${PROJECT_NAME} (${PROJECT_ID})"
echo -e "  VM      : ${VM_NAME}  /  ${ZONE}"
echo -e "  VM IP   : ${VM_IP}${NC}"
echo ""
