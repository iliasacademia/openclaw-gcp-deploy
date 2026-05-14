#!/bin/bash
# =============================================================================
# OpenClaw GCP Cleanup
# Deletes the GCP project(s) created by deploy.sh. Run from Cloud Shell when
# you're done testing. This stops the VM, removes the firewall rule, releases
# the service account, and puts the project into GCP's 30-day pending-delete
# state — at which point billing stops.
# =============================================================================
set -euo pipefail

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

PROJECTS=$(gcloud projects list \
  --filter="projectId:my-first-claw-* AND lifecycleState:ACTIVE" \
  --format="value(projectId)" 2>/dev/null || true)

if [ -z "$PROJECTS" ]; then
  echo "No active my-first-claw-* projects found."
  exit 0
fi

echo -e "${YELLOW}This will delete the following projects:${NC}"
for p in $PROJECTS; do echo "  - $p"; done
echo
read -p "Type 'yes' to confirm: " ans
[ "$ans" = "yes" ] || { echo "Aborted."; exit 1; }

for p in $PROJECTS; do
  echo -e "${BLUE}Deleting ${p}...${NC}"
  gcloud projects delete "$p" --quiet
done

echo -e "${GREEN}Done.${NC} Projects are pending deletion (recoverable for 30 days)."
echo "Permanently delete them now at:"
echo "  https://console.cloud.google.com/cloud-resource-manager"
