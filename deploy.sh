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
echo -e "  This script will deploy OpenClaw on Google Cloud (~4 minutes)."
echo -e "  ${DIM}No configuration needed — just sit back.${NC}\n"

# ── Prerequisite: billing ────────────────────────────────────────────────────
header "Checking prerequisites"

BILLING_ACCOUNT=$(gcloud billing accounts list \
  --format="value(name)" --filter="open=true" 2>/dev/null | head -1 || true)

if [ -z "$BILLING_ACCOUNT" ]; then
  die "No active billing account found.\n\n  Please activate your free trial at:\n  ${BLUE}https://console.cloud.google.com/billing${NC}\n\n  Then re-run this script."
fi
success "Billing account found: ${DIM}${BILLING_ACCOUNT}${NC}"

# ── Derive repo URL from git remote ──────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null \
  | sed 's/\.git$//' \
  | sed 's|git@github.com:|https://github.com/|' \
  || true)

if [ -z "$REPO_URL" ]; then
  die "Could not determine repo URL.\n  Please run from inside the cloned repository."
fi
success "Repo: ${DIM}${REPO_URL}${NC}"

# ── Create GCP project ───────────────────────────────────────────────────────
header "Creating GCP project"

SUFFIX=$(od -A n -t u4 -N 2 /dev/urandom | tr -d ' ' | tail -c 4)
PROJECT_ID="my-first-claw-${SUFFIX}"
PROJECT_NAME="My First Claw Agent"

log "Project name : ${PROJECT_NAME}"
log "Project ID   : ${PROJECT_ID}"

gcloud projects create "$PROJECT_ID" \
  --name="$PROJECT_NAME" \
  --quiet || die "Failed to create project. You may have hit the project quota limit."

gcloud config set project "$PROJECT_ID" --quiet

gcloud billing projects link "$PROJECT_ID" \
  --billing-account="$BILLING_ACCOUNT" \
  --quiet

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
  --quiet

log "Waiting 60 seconds for APIs to propagate..."
for i in $(seq 1 60); do
  printf "\r  ${DIM}[%02d/60]${NC}" "$i"
  sleep 1
done
echo ""
success "APIs enabled"

# ── Create VM ────────────────────────────────────────────────────────────────
header "Creating VM"

VM_NAME="openclaw-vm"
ZONE="us-central1-a"

log "Machine type : n2-standard-2 (2 vCPU, 8 GB RAM)"
log "OS           : Debian 13 (trixie)"
log "Disk         : 10 GB"
log "Zone         : ${ZONE}"

gcloud compute instances create "$VM_NAME" \
  --zone="$ZONE" \
  --machine-type="n2-standard-2" \
  --image-family="debian-13" \
  --image-project="debian-cloud" \
  --boot-disk-size="10GB" \
  --boot-disk-type="pd-balanced" \
  --tags="openclaw" \
  --scopes="cloud-platform" \
  --metadata="repo-url=${REPO_URL}" \
  --metadata-from-file="startup-script=${SCRIPT_DIR}/startup.sh" \
  --quiet

VM_IP=$(gcloud compute instances describe "$VM_NAME" \
  --zone="$ZONE" \
  --format="value(networkInterfaces[0].accessConfigs[0].natIP)")

success "VM created — IP: ${BOLD}${VM_IP}${NC}"

# ── Vertex AI: grant role to VM service account ──────────────────────────────
header "Configuring Vertex AI access"

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA}" \
  --role="roles/aiplatform.user" \
  --quiet

success "Vertex AI User role granted to VM service account (ADC)"

# ── Firewall ─────────────────────────────────────────────────────────────────
header "Opening ports"

gcloud compute firewall-rules create allow-openclaw \
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

# ── Wait for setup server ────────────────────────────────────────────────────
header "Waiting for VM to initialise"
log "Installing Node.js 24 + OpenClaw on the VM (~3 minutes)..."

SETUP_URL="http://${VM_IP}:8080/health"
READY=false

for i in $(seq 1 36); do
  printf "\r  ${DIM}Attempt %d/36 — checking http://%s:8080 ...${NC}" "$i" "$VM_IP"
  if curl -sf --max-time 3 "$SETUP_URL" >/dev/null 2>&1; then
    READY=true
    break
  fi
  sleep 5
done
echo ""

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}┌─────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}${BOLD}│         ✅  OpenClaw deployed!                  │${NC}"
echo -e "${GREEN}${BOLD}└─────────────────────────────────────────────────┘${NC}"
echo ""

if [ "$READY" = true ]; then
  echo -e "  👉  Complete setup at:"
  echo -e "      ${BLUE}${BOLD}http://${VM_IP}:8080${NC}"
else
  warn "Setup server is still starting up."
  echo -e "  👉  Try this URL in ~1 minute:"
  echo -e "      ${BLUE}${BOLD}http://${VM_IP}:8080${NC}"
fi

echo ""
echo -e "  ${DIM}Project : ${PROJECT_NAME} (${PROJECT_ID})"
echo -e "  VM IP   : ${VM_IP}"
echo -e "  Zone    : ${ZONE}${NC}"
echo ""
