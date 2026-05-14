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

# ── Banner ───────────────────────────────────────────────────────────────────
clear
echo -e "${BLUE}${BOLD}"
cat << 'EOF'
   ___                  ____ _
  / _ \ _ __   ___ _ __|  _ \ |__ ____      __
 | | | | '_ \ / _ \ '_ \ | | | '_ V _ \ /\/  |
 | |_| | |_) |  __/ | | | |_| | | | | | |>  <|
  \___/| .__/ \___|_| |_|____/|_| |_| |_/_/\_\
       |_|                          GCP Deploy
EOF
echo -e "${NC}"
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
    warn "  deleting ${pid}..."
    gcloud projects delete "$pid" --quiet 2>/dev/null || true
  done
  log "Waiting 15s for deletions to register..."
  sleep 15
fi

SUFFIX=$(printf '%04d' $((RANDOM % 10000)))
PROJECT_ID="my-first-claw-${SUFFIX}"
PROJECT_NAME="My First Claw Agent"

log "Project name : ${PROJECT_NAME}"
log "Project ID   : ${PROJECT_ID}"

gcloud projects create "$PROJECT_ID" --name="$PROJECT_NAME" --quiet \
  || die "Failed to create project — you may have hit the GCP project quota.\n\n  Fix:\n  1. Open ${BLUE}https://console.cloud.google.com/cloud-resource-manager${NC}\n  2. Permanently delete any pending-deletion 'my-first-claw-*' projects\n  3. Re-run this script."

BILLING_ERR=$(gcloud billing projects link "$PROJECT_ID" \
  --billing-account="$BILLING_ACCOUNT" --quiet 2>&1) || {
  if echo "$BILLING_ERR" | grep -q "billing quota exceeded"; then
    die "GCP billing quota exceeded.\n\n  Fix:\n  1. Open ${BLUE}https://console.cloud.google.com/cloud-resource-manager${NC}\n  2. Permanently delete any pending-deletion projects\n  3. Wait ~5 minutes, then re-run this script."
  fi
  die "Could not link billing.\n  ${BILLING_ERR}"
}
success "Project created and billing linked"

# ── Enable APIs ──────────────────────────────────────────────────────────────
header "Enabling GCP APIs"
log "Enabling Compute Engine, Vertex AI, IAM..."

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
  --project="$PROJECT_ID" --quiet

# APIs need ~30-60s to fully propagate before dependent operations work.
log "Waiting 60s for API propagation..."
for i in $(seq 1 60); do
  printf "\r  ${DIM}[%02d/60]${NC}" "$i"; sleep 1
done
echo ""
success "APIs enabled"

# ── Dedicated service account for the VM ─────────────────────────────────────
# Using a dedicated SA avoids the default Compute Engine SA, which newer GCP
# projects may not auto-create (or may not auto-grant Editor to). Also lets us
# scope the VM to *only* aiplatform.user — least privilege.
header "Creating VM service account"

VM_SA_NAME="openclaw-vm"
VM_SA="${VM_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

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
for z in "${ZONES[@]}"; do
  log "Trying zone ${z}..."
  if gcloud compute instances create "$VM_NAME" \
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
      --metadata-from-file="startup-script=${SCRIPT_DIR}/startup.sh" \
      --quiet 2>&1 >/dev/null; then
    ZONE="$z"
    break
  fi
  warn "  zone ${z} unavailable, trying next..."
done
[ -n "$ZONE" ] || die "Could not create VM in any zone — likely a transient GCP capacity issue. Wait a few minutes and re-run."

VM_IP=$(gcloud compute instances describe "$VM_NAME" \
  --project="$PROJECT_ID" --zone="$ZONE" \
  --format="value(networkInterfaces[0].accessConfigs[0].natIP)")
success "VM created in ${ZONE} — IP: ${BOLD}${VM_IP}${NC}"

# ── Firewall ─────────────────────────────────────────────────────────────────
header "Opening ports"

gcloud compute firewall-rules create allow-openclaw \
  --project="$PROJECT_ID" \
  --direction=INGRESS \
  --priority=1000 \
  --network=default \
  --action=ALLOW \
  --rules=tcp:8080,tcp:18789 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=openclaw \
  --quiet

success "Port 8080  → Setup wizard"
success "Port 18789 → OpenClaw dashboard"

# ── Wait for setup wizard ────────────────────────────────────────────────────
header "Waiting for VM to provision OpenClaw"
log "Installing Node 24 + OpenClaw + setup wizard on the VM..."
log "${DIM}Typical install time: 4-6 minutes${NC}"

SETUP_HEALTH="http://${VM_IP}:8080/health"
MAX_ATTEMPTS=120   # 120 × 5s = 10 minutes
READY=false

for i in $(seq 1 $MAX_ATTEMPTS); do
  printf "\r  ${DIM}Attempt %d/%d — polling %s${NC}" "$i" "$MAX_ATTEMPTS" "$SETUP_HEALTH"
  if curl -sf --max-time 5 "$SETUP_HEALTH" >/dev/null 2>&1; then
    READY=true
    break
  fi
  sleep 5
done
echo ""

# ── Done ─────────────────────────────────────────────────────────────────────
SETUP_LINK="http://${VM_IP}:8080?token=${SETUP_TOKEN}"

echo ""
echo -e "${GREEN}${BOLD}┌─────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}${BOLD}│         ✅  OpenClaw deployed!                  │${NC}"
echo -e "${GREEN}${BOLD}└─────────────────────────────────────────────────┘${NC}"
echo ""

if [ "$READY" = true ]; then
  echo -e "  👉  Open the setup wizard:"
  echo -e "      ${BLUE}${BOLD}${SETUP_LINK}${NC}"
else
  warn "Setup wizard did not respond within 10 minutes."
  echo -e "  The VM may still be installing. Try the URL in 1-2 minutes:"
  echo -e "      ${BLUE}${BOLD}${SETUP_LINK}${NC}"
  echo ""
  echo -e "  ${DIM}If it still fails, SSH in for logs:"
  echo -e "    gcloud compute ssh ${VM_NAME} --project=${PROJECT_ID} --zone=${ZONE}"
  echo -e "    sudo tail -100 /var/log/openclaw-startup.log${NC}"
fi

echo ""
echo -e "  ${DIM}Project : ${PROJECT_NAME} (${PROJECT_ID})"
echo -e "  VM      : ${VM_NAME}  /  ${ZONE}"
echo -e "  VM IP   : ${VM_IP}${NC}"
echo ""
