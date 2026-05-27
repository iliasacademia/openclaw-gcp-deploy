# 🦞 OpenClaw — Easy GCP Deploy

Deploy [OpenClaw](https://openclaw.ai) on Google Cloud in ~5 minutes with a single button click. No terminal experience needed beyond clicking through a few Google sign-in screens.

**What you get:**
- OpenClaw running on a dedicated GCP VM (Debian 13, n2-standard-2)
- Gemini 2.5 Pro via Vertex AI — billed to your $300 GCP free trial, no separate API key
- A guided web wizard for Telegram bot pairing
- Optional in-wizard Google sign-in for Gmail / Drive / Calendar access (the agent can read your inbox, save research notes to Docs/Sheets, manage Calendar)
- HTTPS-ready OpenClaw dashboard at a `<ip>.sslip.io` subdomain (auto Let's Encrypt cert)

---

## Prerequisites

1. **A new Google account** — [create one here](https://accounts.google.com/signup). I strongly recommend creating a fresh account rather than using your everyday Gmail because:
   - The $300 Google Cloud free-trial credit only applies the first time a billing profile signs up — a fresh account keeps you eligible.
   - It's a blank, low-risk playground: even if you grant the agent access to "your Gmail" later, that inbox is brand new and contains no personal mail.
   - When the agent is given access to your Drive, Calendar, etc., those are this fresh account's — your personal account stays untouched.

2. **Two-step verification enabled on that new account** — [turn it on here](https://myaccount.google.com/signinoptions/twosv). Google requires two-step verification before you can create the OAuth client you'll need later to give the agent access to Gmail, Drive, and Calendar. Easier to do this now than to be blocked partway through.

3. **A Google Cloud Billing account with the free trial activated** — [start here](https://console.cloud.google.com/freetrial). Signing up gives you all of the following at once, which is everything my `deploy.sh` needs to create your project:
   - **$300 in free credits** valid for 90 days (covers compute + Vertex AI tokens — comfortably enough for personal use)
   - A linked **Cloud Billing account** (this is what `deploy.sh` attaches to the new project so VMs can actually run)
   - A credit card is required to verify identity — you won't be charged unless you explicitly upgrade to the paid tier after the trial

4. **A Telegram account** — [install Telegram](https://telegram.org/) on your phone or desktop and sign in. The wizard walks you through creating a private bot through Telegram's `@BotFather` once the deploy finishes; you'll talk to your assistant through that bot.

5. **Strongly recommended: a dedicated Chrome profile signed into the new Google account.** In Chrome, click your avatar (top-right) → **Add** → sign in with the new account from step 1, and do the entire deploy from that profile's window. This keeps the new account separate from your everyday Gmail, so every link in this guide (Cloud Shell, the Cloud Console, the Google sign-in screens during the optional Google-services step) opens as the right account automatically — no "wrong account" errors or account-picker confusion. [How to add a Chrome profile](https://support.google.com/chrome/answer/2364824).

That's it. Everything else is automated.

---

## Deploy

Click the button below. It opens Google Cloud Shell (a browser-based terminal) with this repo cloned and a banner in the terminal telling you the next command.

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/open?git_repo=https://github.com/iliasacademia/openclaw-gcp-deploy&cloudshell_print=cloudshell_banner.txt&shellonly=true)

Cloud Shell will show you two Google dialogs before you reach the terminal — these are normal:

1. **"Trust repo"** — check the box and click **Confirm**. (Google's security gate for every Cloud Shell deploy button; can't be bypassed.)
2. **"Authorize Cloud Shell"** — click **Authorize**. (Lets Cloud Shell use your Google credentials to make API calls. This is required for `gcloud` to work; you may also see it pop up again later in the session.)

> 💡 **If the Cloud Shell terminal doesn't appear** within ~30 seconds — common on a fresh Google account where Cloud Shell may interrupt the flow to confirm your identity or settings — just **click the "Open in Cloud Shell" button again**. It will pick up where you left off. Repeat if needed.

Then click into the terminal at the bottom of Cloud Shell and type:

```bash
bash deploy.sh
```

Press Enter. The script takes about 5-7 minutes total. The **first time you ever run it on a Cloud Shell account** it pauses once for a 30-second Google OAuth approval (so OpenClaw can talk to Vertex AI on your behalf) — open the URL it prints, click Allow, paste the code back. Subsequent runs skip this step.

---

## What the script does

| Step | What happens |
|------|-------------|
| 0 | (First run on a Cloud Shell account only) Pauses for a ~30-second Google OAuth approval. Open the URL the script prints, click Allow, paste the verification code back. This gives OpenClaw your Google account's permission to call Vertex AI — the equivalent of an API key. |
| 1 | Creates a new GCP project called **My First Claw Agent** |
| 2 | Enables Compute Engine + Vertex AI + IAM + Workspace APIs |
| 3 | Creates a dedicated service account for the VM with `roles/aiplatform.user` (least privilege) |
| 4 | Creates a VM (Debian 13, n2-standard-2, 20 GB disk) — tries 8 zones for capacity |
| 5 | Opens firewall ports 80 / 443 / 8080 / 18789 |
| 6 | Installs Node.js 24 + OpenClaw + the `gog` Google Workspace CLI + Caddy on the VM |
| 7 | Validates the OpenClaw config before starting the gateway |
| 8 | Starts the setup wizard and the OpenClaw gateway |
| 9 | Prints your setup wizard URL |

**Total time: ~5-7 minutes** (most of it the VM's first-boot install).

---

## After deploy — walk the wizard

1. Open the setup wizard URL printed at the end (e.g. `http://YOUR_IP:8080?token=...`) in your browser.
   - **Use a regular Chrome / Firefox / Safari window — not Incognito.** Incognito blocks plain HTTP and will show a "site doesn't support secure connection" warning. (The wizard runs over HTTP because it doesn't have a domain. The OpenClaw dashboard at the end runs over HTTPS.)

2. **Step 1 of 2 — Connect Telegram.** The wizard shows step-by-step BotFather instructions; you create a private bot, copy the token BotFather sends, paste it in. The wizard verifies the token against Telegram and configures OpenClaw to use it.

3. **Step 2 of 2 — Pair your account.** Click "Open my bot in Telegram", send `/start` to the bot. Within a few seconds the wizard shows a card with your name and a one-click Approve button.

4. **Done screen.** You see "You're all set!" with a link to the OpenClaw dashboard (HTTPS, via the sslip.io / Let's Encrypt cert auto-fetched in the background). Send your bot a message on Telegram — it replies via Vertex AI / Gemini 2.5 Pro. First reply may take a few seconds while the model warms up.

5. **Optional — Connect Google.** From the Done screen, click "Connect Google" if you want your assistant to read Gmail, search Drive, save research notes into new Docs / Sheets, or manage Calendar. The wizard walks you through:
   - Configuring the OAuth consent screen in Google Cloud Console (the wizard tells you exactly what to type and click).
   - Creating an OAuth Desktop client and downloading its JSON.
   - Uploading that JSON via a drag-and-drop dropzone in the wizard.
   - An **in-wizard** Google sign-in: the wizard opens a Google sign-in page in a new tab, you sign in, the browser redirects to `localhost:...?code=...` (a "site can't be reached" page — that's expected), you copy the URL from the address bar and paste it back into the wizard. The wizard exchanges the code for refresh tokens and stores them. No SSH, no CLI commands.

Bookmark the dashboard URL **with its `#token=` fragment** — that token is the only thing protecting your gateway. Don't share it.

---

## Estimated cost

| Resource | Cost |
|----------|------|
| n2-standard-2 VM | ~$0.10/hr (~$2.40/day) |
| Vertex AI (Gemini 2.5 Pro) | Pay per token — low for personal use |
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
