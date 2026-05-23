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
2. **2-Step Verification enabled on that Google account** — [turn it on here](https://myaccount.google.com/signinoptions/twosv). Google requires 2SV before you can create the OAuth client we'll need later to give the agent access to Gmail, Drive, and Calendar. Easier to do this now than to be blocked partway through.
3. **A Google Cloud account with free trial activated** — [start here](https://console.cloud.google.com/freetrial)
   - You get **$300 in free credits** valid for 90 days
   - A credit card is required to verify identity — you won't be charged

That's it. Everything else is automated.

---

## Deploy

Click the button below. It opens Google Cloud Shell (a browser-based terminal) with this repo cloned and a banner in the terminal telling you the next command.

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/open?git_repo=https://github.com/iliasacademia/openclaw-gcp-deploy&cloudshell_print=cloudshell_banner.txt&shellonly=true)

Cloud Shell will show you two Google dialogs before you reach the terminal — these are normal:

1. **"Trust repo"** — check the box and click **Confirm**. (Google's security gate for every Cloud Shell deploy button; can't be bypassed.)
2. **"Authorize Cloud Shell"** — click **Authorize**. (Lets Cloud Shell use your Google credentials to make API calls. This is required for `gcloud` to work; you may also see it pop up again later in the session.)

Then click into the terminal at the bottom of Cloud Shell and type:

```bash
bash deploy.sh
```

Press Enter. The script takes about 5-7 minutes total. The **first time you ever run it on a Cloud Shell account** it pauses once for a 30-second Google OAuth approval (so OpenClaw can talk to Vertex AI on your behalf) — open the URL it prints, click Allow, paste the code back. Subsequent runs skip this step.

---

## What the script does

| Step | What happens |
|------|-------------|
| 0 | (First run only) Asks you to approve Vertex AI access via Google OAuth — paste the verification code back |
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

1. Open the setup wizard URL printed at the end (e.g. `http://YOUR_IP:8080?token=...`) in your browser.
   - **Use a regular Chrome/Firefox/Safari window — not Incognito.** Incognito mode blocks plain HTTP and will show a "site doesn't support secure connection" warning. (The wizard itself is HTTP because we don't have a domain; the OpenClaw dashboard *is* HTTPS via Let's Encrypt.)
2. Step 1 of 2 — paste your Telegram bot token (the wizard explains how to get one from @BotFather).
3. Step 2 of 2 — click the **Open my bot in Telegram** button and send `/start`. The wizard polls for your pairing request and shows an **Approve** button when it arrives. One click and you're done.
4. Click **Open OpenClaw Dashboard** — the link includes your gateway token, and Caddy provides a valid Let's Encrypt cert so there's no browser warning.
5. (Optional) Click **Connect Google** in the wizard for Gmail/Drive/Calendar access. The wizard walks you through OAuth setup in Google Cloud Console.

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
