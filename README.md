# 🦞 OpenClaw — One-Click GCP Deploy

Deploy [OpenClaw](https://openclaw.ai) on Google Cloud in ~5 minutes with a single button click. No terminal experience needed.

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

Click the button below. It opens Google Cloud Shell (a browser-based terminal) with this repo cloned, a tutorial pane on the right, and a banner in the terminal telling you the next command.

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/open?git_repo=https://github.com/iliasacademia/openclaw-gcp-deploy&tutorial=cloudshell_tutorial.md&cloudshell_print=cloudshell_banner.txt)

You'll see a **"Trust repo"** dialog first — check the box and click **Confirm**. (This is Google's security gate for every Cloud Shell deploy button; it can't be bypassed.)

Then click into the terminal at the bottom of Cloud Shell and type:

```bash
bash deploy.sh
```

Press Enter and sit back — it takes about 5 minutes and asks no questions.

---

## What the script does

| Step | What happens |
|------|-------------|
| 1 | Creates a new GCP project called **My First Claw Agent** |
| 2 | Enables Compute Engine + Vertex AI + IAM APIs |
| 3 | Creates a dedicated service account with **only** Vertex AI access (least privilege) |
| 4 | Creates a VM (Debian 13, n2-standard-2, 20 GB disk) — tries 8 zones for capacity |
| 5 | Opens firewall ports for the dashboard and setup wizard |
| 6 | Installs Node.js 24 + OpenClaw on the VM |
| 7 | Validates the OpenClaw config before starting the gateway |
| 8 | Starts OpenClaw + the setup wizard |
| 9 | Prints your setup URL |

**Total time: ~5 minutes.**

---

## After deploy

1. Visit the setup wizard URL printed at the end (e.g. `http://YOUR_IP:8080?token=...`)
2. Follow the one-step wizard to connect your Telegram bot
3. Click "Open OpenClaw Dashboard" — the link includes your gateway token
4. From the dashboard, connect Google (Drive, Gmail, Calendar) via the **gog** skill

The dashboard token is the only thing protecting your gateway — bookmark the link with the token included, and don't share it.

---

## Estimated cost

| Resource | Cost |
|----------|------|
| n2-standard-2 VM | ~$0.10/hr (~$2.40/day) |
| Vertex AI (Gemini 3.1 Pro) | Pay per token — low for personal use |
| **$300 free credits** | Covers months of testing |

To avoid charges after testing, run `bash cleanup.sh` from the same Cloud Shell session, or delete the project at the [GCP Console](https://console.cloud.google.com/cloud-resource-manager).

---

## Project structure

```
openclaw-gcp-deploy/
├── deploy.sh              # Main script — runs in Cloud Shell
├── startup.sh             # Runs on VM at first boot
├── cleanup.sh             # Tears down the project when you're done
├── cloudshell_tutorial.md # Tutorial shown in the Cloud Shell pane
└── setup-server/
    ├── server.js          # Express setup wizard (port 8080)
    ├── package.json
    └── public/            # Setup wizard UI (incl. diagnostics)
```

---

## Troubleshooting

**Setup wizard not loading?**
The VM needs ~5 minutes to install everything. The deploy script polls for 10 minutes — if it times out, wait 1-2 more minutes and refresh.

**Wizard loads but says "Boot failed" or shows diagnostics?**
The diagnostics panel surfaces the failure reason and the last lines of every relevant log (VM startup, gateway service, setup wizard). Share that output if you open an issue.

**"No billing account" error?**
Activate your free trial at https://console.cloud.google.com/freetrial first.

**OpenClaw dashboard unreachable?**
SSH into the VM and check:
```bash
sudo journalctl -u openclaw-gateway -f
sudo tail -100 /var/log/openclaw-startup.log
```

**"Billing quota exceeded"?**
GCP limits projects per billing account. The deploy script tries to auto-clean stale `my-first-claw-*` projects, but you can permanently delete them at [Resource Manager](https://console.cloud.google.com/cloud-resource-manager).

---

Built with ❤️ to make OpenClaw easy to try.
