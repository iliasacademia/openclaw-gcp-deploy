# 🦞 OpenClaw — One-Click GCP Deploy

Deploy [OpenClaw](https://openclaw.ai) on Google Cloud in ~4 minutes with a single button click. No terminal experience needed.

**What you get:**
- OpenClaw running on a dedicated GCP VM
- Gemini 3.1 Pro (Vertex AI) as the AI brain — no API key required, uses your GCP credits
- A guided setup wizard to connect your Telegram bot
- Full OpenClaw dashboard at your VM's IP

---

## Prerequisites

1. **A Google account** — [sign up here](https://accounts.google.com)
2. **A Google Cloud account with free trial activated** — [start here](https://console.cloud.google.com/freetrial)
   - You get **$300 in free credits** valid for 90 days
   - A credit card is required to verify identity — you won't be charged

That's it. Everything else is automated.

---

## Deploy

Click the button below. It opens Google Cloud Shell (a browser-based terminal) and runs the deploy script automatically.

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/open?git_repo=https://github.com/iliasacademia/openclaw-gcp-deploy&tutorial=cloudshell_tutorial.md&shellonly=true&open_in_editor=deploy.sh)

> **Note:** After clicking, Cloud Shell will open and clone this repo. Run the script with:
> ```bash
> bash deploy.sh
> ```

---

## What the script does

| Step | What happens |
|------|-------------|
| 1 | Creates a new GCP project called **My First Claw Agent** |
| 2 | Enables Compute Engine + Vertex AI APIs |
| 3 | Creates a VM (Debian 13, n2-standard-2, us-central1) |
| 4 | Grants the VM automatic access to Vertex AI (no keys needed) |
| 5 | Opens firewall ports for the dashboard and setup wizard |
| 6 | Installs Node.js 24 + OpenClaw on the VM |
| 7 | Starts OpenClaw and the setup wizard |
| 8 | Prints your setup URL |

**Total time: ~4 minutes.**

---

## After deploy

1. Visit the setup wizard URL printed at the end (e.g. `http://YOUR_IP:8080`)
2. Follow the one-step wizard to connect your Telegram bot
3. You'll be redirected to the OpenClaw dashboard
4. From the dashboard, connect Google (Drive, Gmail, Calendar) via the **gog** skill

---

## Estimated cost

| Resource | Cost |
|----------|------|
| n2-standard-2 VM | ~$0.10/hr (~$2.40/day) |
| Vertex AI (Gemini 3.1 Pro) | Pay per token — low for personal use |
| **$300 free credits** | Covers months of testing |

To avoid charges after testing, stop or delete the VM from the [GCP Console](https://console.cloud.google.com/compute).

---

## Project structure

```
openclaw-gcp-deploy/
├── deploy.sh              # Main script — runs in Cloud Shell
├── startup.sh             # Runs on VM at first boot
└── setup-server/
    ├── server.js          # Express setup wizard (port 8080)
    ├── package.json
    └── public/            # Setup wizard UI
```

---

## Troubleshooting

**Setup wizard not loading?**
The VM needs ~4 minutes to install everything. Wait and refresh.

**"No billing account" error?**
Activate your free trial at https://console.cloud.google.com/freetrial first.

**OpenClaw dashboard unreachable?**
SSH into the VM and check: `sudo journalctl -u openclaw -f`

---

Built with ❤️ to make OpenClaw easy to try.
