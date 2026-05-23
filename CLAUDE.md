# OpenClaw GCP Deploy — Project Context

> **This is the living context file for the project.** Keep it in sync as
> things change — Claude Code (and other AI assistants) auto-load this on
> session start so it's the fastest way to bring a new chatbot up to speed.
> When you ship a meaningful change (new feature, new architectural
> decision, gotcha discovered, version bumped), update the relevant
> section here too.

**Current version:** setup-server `1.6.24` · **Last reviewed:** 2026-05-23

**Repo:** [github.com/iliasacademia/openclaw-gcp-deploy](https://github.com/iliasacademia/openclaw-gcp-deploy)

---

## 1. What this project is

An **easy "Deploy to GCP" tool** for [OpenClaw](https://openclaw.ai)
(a personal AI assistant with channel integrations like Telegram).
The goal is that a **non-technical user** can:

1. Click a button on the GitHub README
2. Trust the repo in Cloud Shell, click Authorize Cloud Shell
3. Type `bash deploy.sh`
4. **One-time** Google OAuth approval (~30s — prints a URL, paste back the verification code)
5. Wait ~5-7 minutes for the VM to come up
6. Paste a Telegram bot token in the resulting web wizard
7. Send `/start` to their bot
8. Click "Approve" in the wizard
9. (Optional) Connect Google — upload an OAuth client JSON + an in-wizard Google sign-in flow
10. Chat with the assistant on Telegram

…and have a working AI assistant. **No SSH, no manual config files,
no CLI commands.** The one user-driven interactive step (Google OAuth
for ADC) is wrapped inside `deploy.sh` itself via `expect`, with a
labeled "Paste verification code here" prompt.

Vertex AI is the LLM brain (Gemini 3.1 Pro). OpenClaw 2026.5.20's
google-vertex provider requires `authorized_user` ADC (the GCE
metadata-server service-account credentials are not honored — see §5
#2c), so the deploy ships the user's `~/.config/gcloud/application_default_credentials.json`
to the VM via metadata. Billing for Vertex tokens lands on the user's
GCP project, covered by the $300 free trial.

---

## 2. End-to-end user flow

```
┌──────────────────┐  click   ┌──────────────────────┐  type   ┌─────────────┐
│ GitHub README    │ ────────▶│ Cloud Shell:         │ ───────▶│ bash        │
│ "Open in Cloud   │          │  - Trust repo        │         │ deploy.sh   │
│  Shell" button   │          │  - Authorize         │         │             │
└──────────────────┘          └──────────────────────┘         └──────┬──────┘
                                                                      │
                              ┌───────────────────────────────────────┘
                              ▼
        ┌─────────────────────────────────────────────────┐
        │ deploy.sh asks for Google OAuth approval        │
        │  (expect-driven, ~30s):                         │
        │   - prints URL, labeled "Paste code here:"      │
        │   - writes authorized_user ADC for the user     │
        │   - file shipped to VM via metadata             │
        └─────────────────────┬───────────────────────────┘
                              │  (~5-7 min)
                              ▼
        ┌─────────────────────────────────────────────┐
        │ GCP project + dedicated SA + VM + firewall  │
        │ + Caddy + Let's Encrypt cert via sslip.io   │
        │ + OpenClaw + setup wizard + gog CLI         │
        └─────────────────────┬───────────────────────┘
                              │  deploy.sh prints
                              ▼
        http://<VM_IP>:8080?token=<single-use SETUP_TOKEN>
                              │  user opens URL
                              ▼
        ┌─────────────────────────────────────────────┐
        │ SETUP WIZARD (Express on VM, port 8080)     │
        │                                             │
        │ Step 1 of 2: paste Telegram bot token       │
        │   ↓ /api/telegram validates against         │
        │     Telegram getMe, writes openclaw.json,   │
        │     restarts gateway                        │
        │ Step 2 of 2: pair                           │
        │   - user sends /start on Telegram           │
        │   - wizard polls openclaw pairing list      │
        │   - shows pending pairing card with name    │
        │   - user clicks "Approve this user"         │
        │ Done: bot replies via Vertex/Gemini         │
        │                                             │
        │ Optional next step (Connect Google):        │
        │   - drag client_secret_*.json dropzone      │
        │   - enter Google email                      │
        │   - "Open Google sign-in" → user follows    │
        │     3 Google screens → "site can't be       │
        │     reached" → paste URL back into wizard   │
        │   - wizard exchanges code via gog --remote  │
        │     --step 2, stores refresh tokens         │
        └─────────────────────┬───────────────────────┘
                              │  link is https://<ip-dashed>.sslip.io/#token=<GATEWAY_TOKEN>
                              ▼
        ┌─────────────────────────────────────────────┐
        │ OPENCLAW DASHBOARD (Caddy → port 18789)     │
        │ - token in URL fragment (#token=...)        │
        │ - chat, skills, agents, settings            │
        └─────────────────────────────────────────────┘
```

---

## 3. Architecture / what runs where

### Cloud Shell (user's browser, ephemeral)
- Runs `deploy.sh` once
- Has gcloud authenticated as the user
- Creates the project, SA, IAM, VM, firewall

### The VM (Debian 13 trixie, n2-standard-2, 20 GB)
Four systemd services run as four different users:

| Service | User | Listens on | What it does |
|---|---|---|---|
| `openclaw-gateway.service` | `openclaw` | `:18789` (loopback + LAN) | The actual OpenClaw gateway. WebSocket RPC + HTTP dashboard. |
| `openclaw-setup.service` | `openclaw` | `:8080` | The Express setup wizard. Reads/writes `openclaw.json`, drives pairing approval. |
| `caddy.service` | `caddy` | `:80`, `:443` | TLS termination + reverse-proxy to `:18789`. Auto-fetches Let's Encrypt cert. |
| `google-startup-scripts.service` | root | — | Runs `startup.sh` once at first boot. |

### URLs the user actually sees
- **Setup wizard**: `http://<VM_IP>:8080?token=<SETUP_TOKEN>` (single-use token)
- **OpenClaw dashboard**: `https://<dashed-ip>.sslip.io/?token=<GATEWAY_TOKEN>` (long-lived token; user should bookmark)

### Tokens
- `SETUP_TOKEN` — generated by deploy.sh, passed via VM metadata, embedded in setup-wizard URL. Gates `/api/*` on the wizard. ~24-byte base64.
- `GATEWAY_TOKEN` — generated by deploy.sh, passed via VM metadata, written into `openclaw.json` as `gateway.auth.token`, also embedded in the dashboard URL. ~24-byte base64. Anyone with this token has full agent admin.
- `GOG_KEYRING_PASSWORD` — 32-byte hex, passed via VM metadata, set as a systemd `Environment=` on the gateway service. Used by the `gog` CLI to encrypt stored OAuth tokens.

---

## 4. Key decisions and why

### Dedicated VM service account, not the default compute SA
The default Compute Engine SA (`<num>-compute@developer.gserviceaccount.com`)
isn't reliably created on newer GCP projects and may not have Editor.
We create `openclaw-vm@<project>.iam.gserviceaccount.com` and grant it
**only** `roles/aiplatform.user`. Least privilege.

### IAM binding happens BEFORE VM creation
Previously the VM came up first and IAM was attached afterwards,
producing a race where the first Vertex call could 403. Now the SA has
the role before the VM ever boots.

### Setup wizard starts BEFORE the slow `npm install -g openclaw`
The express dependency is tiny; openclaw is ~75 MB unpacked. We start
the wizard early so that if the openclaw install fails, the user can
still reach `/api/diagnostics` and see logs.

### `openclaw.json` is written EARLY too
Before the gateway binary exists. Eliminates a race where a fast user
hits the wizard before the config file exists. The config shape is
fully knowable at boot (gateway token from metadata, schema fixed).

### Caddy + sslip.io for HTTPS, not Tailscale or ngrok
The OpenClaw Control UI calls Web Crypto APIs (`crypto.subtle.generateKey`)
that browsers **block outside a secure context** (HTTPS or localhost).
Plain HTTP at a public IP fails this check before any backend logic
runs. `gateway.controlUi.allowInsecureAuth: true` does NOT help — it
only relaxes the server-side check; the browser-side failure is
unconditional.

Self-contained HTTPS options considered:
- Tailscale Serve: requires user to install Tailscale client. Too technical.
- ngrok: requires account, URL changes per session.
- Cloudflare Tunnel: requires Cloudflare account.
- Self-signed cert: browser shows "not secure" warning.
- **sslip.io + Caddy + Let's Encrypt**: zero-touch, real cert. ← chosen.

### Pairing approval in our wizard, not OpenClaw's dashboard
OpenClaw's "approve under Access" UX was opaque to non-technical users
(the bot also responds with an intimidating CLI hint). We added
`/api/pairings/list` and `/api/pairings/approve` to the setup-server,
and a wizard step that polls and shows a one-click Approve button.

### Setup wizard is fail-closed
If `SETUP_TOKEN` is empty, server.js exits 1. The wizard writes config
and restarts a service — an open endpoint on the public internet is a
serious hole.

### We don't pin `openclaw@latest`
Tradeoff: pinning gets stale, `@latest` could break. We accept the
breakage risk in exchange for getting bug fixes automatically. `bash
test.sh` validates the generated config against the installed openclaw
schema, so a schema-incompatible release fails loudly at deploy time
rather than silently misbehaving later.

---

## 5. Non-obvious gotchas / things that bit us

In rough order of how confusing they were when first encountered:

1. **There is no `openclaw start` subcommand.** The CLI verb is
   `openclaw gateway`. The original autodetect that grep'd for the
   word "start" in `--help` output produced a false positive.

2. **The openclaw config schema is strictly validated.** Any unknown
   key causes the gateway to refuse to start. Real schema is in
   `dist/extensions/...` and reachable via `openclaw config schema`
   if you have the CLI installed. Notable surprises:
   - `agents.defaults.model.primary` (not `agent.model`)
   - `gateway.bind` is an enum: `loopback|lan|tailnet|auto|custom`
     (NOT a raw IP)
   - `gateway.auth` is an object `{mode, token}` (NOT a string)
   - `gateway.mode: "local"` is **required** — without it the gateway
     refuses to boot
   - `models.providers.google-vertex` does NOT accept `project`/`location`
     keys; those come from env vars `GOOGLE_CLOUD_PROJECT` and
     `GOOGLE_CLOUD_LOCATION` on the gateway service

2b. **`openclaw pairing list <channel> --json` output uses the `requests`
    key**, not `items` / `pending` / a bare array. Each entry has nested
    `meta.{username, firstName, lastName, accountId}`. Approve verb is
    `openclaw pairing approve <channel> <code>`. Discovered the hard
    way via wizard diagnostics in v1.6.4 — initial parser guessed three
    different key names, all wrong.

2c. **The `google-vertex` provider requires `type: "authorized_user"` ADC.**
    The implementation at `dist/vertex-adc--LQQpRFG.js::hasGoogleVertexAuthorizedUserAdcSync`
    reads `$HOME/.config/gcloud/application_default_credentials.json` and
    rejects anything that isn't `type: "authorized_user"`. **It does NOT
    honor the GCE metadata-server service-account credentials** that the
    VM gets automatically from `--service-account` and `--scopes=cloud-platform`
    on `gcloud compute instances create`. So our VM SA is enough to enable
    Vertex APIs, list models, etc., but **not** to invoke the model from
    OpenClaw. Workaround (v1.6.10+): user runs `gcloud auth
    application-default login` in Cloud Shell, we ship the resulting file
    via `--metadata-from-file=gcp-adc=…` and `startup.sh` installs it at
    `/home/openclaw/.config/gcloud/application_default_credentials.json`.
    If OpenClaw ever supports service-account ADC or metadata-server creds
    in the google-vertex provider, we can drop the interactive step.

3. **`gateway.controlUi.allowedOrigins` is mandatory** for any
   non-loopback access. Lists exact origins (no wildcards). Ours is
   `[http://<ip>:18789, https://<dashed-ip>.sslip.io]`.

4. **The dashboard requires HTTPS or localhost.** Browser Web Crypto
   restriction. `allowInsecureAuth: true` does NOT fix it for remote
   access. The only real fix is HTTPS (Caddy + sslip.io).

5. **`sudo -u openclaw` and `runuser -u openclaw` both keep the caller's
   $HOME**. To make openclaw look in `/home/openclaw/.openclaw/openclaw.json`,
   pass `env HOME=/home/openclaw` explicitly.

6. **Vertex AI Gemini 3.1 Pro on Vertex** uses model id
   `google-vertex/gemini-3.1-pro-preview` (NOT
   `…-preview-customtools`, which is a fake name from the original
   broken code) and runs in region `global` (not `us-central1`).

7. **NodeSource setup_24.x DOES work on Debian 13.** Their repo uses
   a `Suites: nodistro` suite so distro detection is bypassed. We
   originally suspected this was broken; it isn't.

8. **GCP project IDs are reused-once.** A pending-deletion project
   blocks reuse of its ID. `deploy.sh` randomises the suffix
   (`my-first-claw-NNNN`) so collision is unlikely; `cleanup.sh`
   schedules deletion (recoverable for 30 days).

9. **OAuth client creation cannot be fully automated by Google's
   design.** The consent screen setup requires UI clicks in Cloud
   Console; no API. Our flow installs `gog`, enables the Workspace
   APIs, generates the keyring password, but the user must:
   - Configure OAuth consent screen (External + add self as Test user)
   - Create OAuth client (Desktop app type) → download JSON
   - Run gog auth with the JSON

10. **Cloud Shell's "Trust repo" prompt cannot be bypassed.** Google
    added it as a security gate; no URL parameter overrides it.

11. **Device pairing is required by default for the Control UI.** The
    correct schema key to disable it is
    `gateway.controlUi.dangerouslyDisableDeviceAuth: true` (NOT
    `requireDevicePairing` — that's an unknown key rejected by strict
    schema validation). Without this, every new browser must be
    approved via `openclaw devices approve <id>` on the CLI.

---

## 6. File-by-file map

```
openclaw-gcp-deploy/
├── README.md                  # user-facing docs + the Cloud Shell button
├── HANDOFF.md                 # ← this file, if checked into the repo
├── deploy.sh                  # 1. runs in Cloud Shell
├── startup.sh                 # 2. runs on the VM at first boot
├── cleanup.sh                 # tears down the project
├── test.sh                    # local test harness (~17 checks)
├── cloudshell_tutorial.md     # shown in the Cloud Shell tutorial pane
├── cloudshell_banner.txt      # printed in Cloud Shell terminal at start
└── setup-server/
    ├── package.json           # version is the canonical app version
    ├── server.js              # Express app: /health, /api/{status,
    │                          #   diagnostics, telegram, pairings, …}
    └── public/
        ├── index.html         # wizard screens: loading, telegram,
        │                      #   pairing, done, diagnostics, unauth
        ├── app.js             # screen routing, polling, API calls
        └── style.css          # dark theme styling
```

Each file has a clear responsibility — don't be afraid to make focused
edits.

---

## 7. How to develop and ship a change

```bash
# 1. Clone or pull
git clone https://github.com/iliasacademia/openclaw-gcp-deploy /tmp/openclaw-gcp-deploy
cd /tmp/openclaw-gcp-deploy

# 2. Make changes

# 3. Local tests (5s, free, no GCP)
bash test.sh
# expect: 17/17 pass (skip openclaw config validate unless openclaw is
# globally installed; with `npm i -g openclaw` you'd see 18/18)

# 4. Bump version in setup-server/package.json

# 5. Commit + push
git add -A && git commit -m "..." && git push origin main

# 6. End-to-end test: open the Cloud Shell button on GitHub from a
#    private/fresh browser window, run `bash deploy.sh`, walk the flow.
#    Tear down with `bash cleanup.sh`.
```

The user is `iliasacademia` (GitHub) / `ilias@academia.edu` (email).
Pushing to `main` requires explicit user authorization once per
session; from inside Claude Code that may produce a denial message.

---

## 8. Local test harness — what it covers

`bash test.sh` runs:

- `bash -n` on every shell script
- `node --check` on server.js + app.js
- JSON validity on package.json
- Generated `openclaw.json` shape — extracts the heredoc body from
  startup.sh, substitutes template vars, validates as JSON, and if
  `openclaw` is in PATH also runs `openclaw config validate` against
  the live schema
- End-to-end against a running setup-server: `/health` no-auth,
  `/api/*` token-required, 403 on wrong token, 400 on malformed
  Telegram token, atomic config write, secrets redacted in diagnostics,
  setupServerVersion exposed, fail-closed exit on empty `SETUP_TOKEN`

**What it doesn't cover**: anything GCP-side (project create, IAM, VM
boot, Caddy/Let's Encrypt cert acquisition) and anything OpenClaw-side
(gateway actually connecting to Vertex, Telegram, OAuth approvals).
Those require a real deploy.

---

## 9. What's NOT solved / open work

### Google Console setup steps require user clicks
The Connect Google flow still requires the user to click through three
things in Google Cloud Console:
1. Configure the OAuth consent screen (the new Google Auth Platform
   wizard: App Info → Audience → Contact Info → Finish).
2. Add themselves as a Test User on the Audience page.
3. Create an OAuth Desktop client and download the JSON.

Google's API does not allow programmatic OAuth-consent-screen
configuration for external user types, so these clicks are
unavoidable. The wizard provides step-by-step instructions with
exact field names, recommended values (with copy buttons), and deep
links to the right Google Console pages.

The OAuth sign-in itself (was the missing piece pre-v1.6.14) IS now
fully driven from the wizard via `gog auth add --remote --step 1 /
--step 2`. User pastes the redirect URL, server exchanges the code.

### Caddy / Let's Encrypt failure mode is rough
If port 80 is blocked, the sslip.io shared LE rate limit is hit, or
Caddy's request to LE just fails, the dashboard URL returns TLS
errors. The wizard's done screen polls `/api/dashboard-ready` and
surfaces "Open over HTTP anyway" after ~5 minutes, but the HTTP
dashboard fails OpenClaw's secure-context guard for some features.
Possible mitigation: try `nip.io` as a fallback domain since it has
a separate LE quota; not yet implemented.

### No upgrade path
There's no way to update an existing deploy. The user has to
`cleanup.sh` and redeploy. Acceptable for v1; git tags from
v1.6.0 onwards make rollback simple if a future deploy regresses.

### Setup wizard is still plain HTTP
We HTTPS the dashboard via Caddy, but the wizard at port 8080 is plain
HTTP. The wizard token travels in cleartext over the public internet
for ~5 minutes between deploy.sh printing it and the user finishing.
Token is single-use and short-lived, so practical risk is small; a
clean solution would put both behind Caddy. Note: `navigator.clipboard`
is unavailable on HTTP origins, so the wizard's copy buttons use
`document.execCommand('copy')` fallback.

### Vertex AI authorized_user ADC requirement
OpenClaw 2026.5.20 explicitly checks for `type: "authorized_user"` in
the ADC file. It does NOT honor service-account creds or the GCE
metadata server. This is why deploy.sh has to run `gcloud auth
application-default login` interactively. If OpenClaw ever broadens
its acceptable credential types (e.g. service account, metadata-server),
we can drop the interactive step and rely on the VM's SA.

### No HTTPS for the IP-based fallback
`controlUi.allowedOrigins` lists `http://<ip>:18789` for loopback
testing but in practice no one connects there. Could be removed.

---

## 10. Versioning and notable commits

setup-server's `package.json` version is the canonical app version.
Recent versions:

| Version | Highlights |
|---|---|
| 1.0.0 | Original — never functionally worked |
| 1.1.0 | Bug-fix wave: correct CLI command, schema-valid config, fail-closed wizard, dedicated SA |
| 1.1.1 | Cloud Shell tutorial copy + banner |
| 1.1.2 | `controlUi.allowedOrigins` |
| 1.1.3 | Pre-write `openclaw.json` (race fix) |
| 1.1.4 | Hardening (PROJECT_ID validation, apt retries, useradd) + cleanup.sh |
| 1.1.5 | Drop fake "▶ Run in Cloud Shell" label from tutorial |
| 1.1.6 | `shellonly=true` on Cloud Shell button |
| 1.2.0 | gog CLI install + Workspace APIs + skill pre-enable + OAuth deep-links |
| 1.2.1 | (now removed) `allowInsecureAuth` attempt |
| 1.3.0 | Pairing approval wizard step |
| 1.4.0 | Caddy + sslip.io HTTPS for the dashboard |
| 1.5.0 | Loading states everywhere; Telegram bot deep link; cert-readiness gate; Google OAuth wizard panel; gcloud zone-retry stderr suppression |
| 1.6.0 | Robustness pass: URL printed early; pairing/cert poll timeouts with fallback; hard-fail bad Telegram tokens; correct gog success semantics; Caddy logs in diagnostics; gateway 'Failed' badge state |
| 1.6.1 | URL re-printed at end of deploy with same prominence as the upfront copy; pairing wait shows progressive hints (30s/60s/120s/180s) instead of a static "Waiting…" message |
| 1.6.2 | Fix step-counter copy (Step 1 of 2, not "1 of 1"); validate Telegram token before persisting to config (prevents stuck pairing screen after a bad-token submit); diagnostics now surface a connectivity probe (loopback / LAN / sslip HTTPS) and the raw `openclaw pairing list` stdout+stderr; verbose gog install logging with download size + curl/tar stderr |
| 1.6.3 | Live spinners + elapsed-seconds counters on every long gcloud call (`services enable`, `projects create`, billing link, SA create, VM create per zone, firewall create) so Cloud Shell no longer looks frozen for minutes. Drop the Cloud Shell tutorial pane (and its misleading START button) — banner in the terminal already covers what to do. Wizard health-poll loop now shows elapsed seconds, not just an attempt counter. |
| 1.6.4 | **Pairing parser actually works — `openclaw pairing list <channel> --json` returns `{ channel, requests: [...] }`, not the `items`/`pending`/bare-array shapes we'd guessed. Pairing card now shows the user's friendly name (Ilias Beshimov / @iliasbeshimov) instead of the raw Telegram id. `openclaw` user added to `systemd-journal` group so gateway logs surface in diagnostics (was showing "(no logs yet)" even with the service happily running).** |
| 1.6.5 | Disable device-auth for the Control UI (`dangerouslyDisableDeviceAuth: true`) so new browsers with a valid token can connect without CLI approval. First attempt used a wrong key name (`requireDevicePairing`) which failed schema validation — fixed to use the actual schema key. |
| 1.6.6 | Stop showing "Gateway failed" badge during the install window — systemd's `inactive` state on a not-yet-created unit was being conflated with a real failure. Only systemd's explicit `failed` state should trigger that badge; everything else is "Starting…". Caught by Playwright E2E. Also: dashboard URL token moved to URL fragment (`#token=`) instead of query string (`?token=`) to stop OpenClaw's secure-context console warning and avoid leaking tokens via proxy/CDN access logs. |
| 1.6.7 | Rewrote the "Connect Google" OAuth instructions to match Google's current Auth Platform UI (the old "+ Create Credentials" → "OAuth client ID" menu was replaced by a single "+ Create client" button). Prose-with-arrows replaced by explicit numbered substeps with exact field names + recommended values. Concrete values (App name, Client name) get inline copy buttons that fall back to `document.execCommand('copy')` because the wizard runs over HTTP (no secure-context `navigator.clipboard`). OAuth deep links point to the new `/auth/overview` and `/auth/clients` URLs. |
| 1.6.8 | Fix gog keyring auth failure on the wizard side — `GOG_KEYRING_PASSWORD` was set on `openclaw-gateway.service` but missing from the setup-wizard's `.env`, so `gog auth credentials` invoked by the wizard hit "no TTY available for keyring file backend password prompt". Now propagated to both services. Also: replaced the "open the file in TextEdit and paste it" textarea on the Connect-Google step with a real file dropzone (drag-and-drop + click-to-browse) with client-side JSON validation. The textarea is still available behind an "Advanced: paste JSON manually" toggle. |
| 1.6.9 | Replace the figlet "OpenClaw" ASCII banner at the top of deploy.sh with a clean centered title — `Easy OpenClaw Deploy by Ilias` with `· GCP Deploy ·` as a dim subscript below. The original ASCII was ambiguous block-shapes on first glance; the new banner says what it is in legible text. |
| 1.6.10 | Fix the actual bot-doesn't-reply blocker. OpenClaw 2026.5.20's google-vertex provider requires `application_default_credentials.json` with `type: "authorized_user"` — it doesn't honor the VM's GCE metadata-server service-account creds. deploy.sh now runs `gcloud auth application-default login` (interactive, one-time per Cloud Shell user) if no ADC file exists, then ships the file via `--metadata-from-file=gcp-adc=…`. startup.sh stages the payload, validates it's `authorized_user` type, and installs it at `/home/openclaw/.config/gcloud/application_default_credentials.json` after the openclaw user is created. Without this, every Vertex call returns "No API key found for provider google-vertex". Also softened the misleading "You can now chat" wording on the Done screen — first reply takes a few seconds, and the cert wait copy no longer over-promises. |
| 1.6.11 | Suppress the gcloud "you're on GCE, why use personal account?" warning + Y/n prompt during the ADC step. Cloud Shell IS a GCE VM so the warning fires, but we're deliberately opting in to user-OAuth ADC because OpenClaw needs it. Detect GCE via metadata server, auto-feed "y" via process substitution, and `grep -v` the eight warning lines out of gcloud's stdout so a non-technical user only sees a clean URL + code prompt. |
| 1.6.12 | Connect Google Step 1 instructions now mention the "Get started" button. Google's OAuth Platform page first lands the user on a "not configured yet" overview that requires clicking a blue Get started button before the 4-step wizard opens. We were jumping straight to "fill the App Information section" without acknowledging that gate. |
| 1.6.13 | Remove the stray dot at the top of Connect Google Step 3. The body started with `<strong>Upload the JSON file</strong>.` and the CSS for `.g-steps > li > strong` makes the strong a block, which pushed the literal period onto its own line. |
| 1.6.14 | Drive the `gog auth add` OAuth flow inside the wizard. The "Last step: dashboard → Skills → gog → Authorise" instruction we'd been telling users was wrong — OpenClaw 2026.5.20's dashboard skill page only has an Enabled toggle, no Authorise button. Built a new two-step UI after "Credentials saved": (1) email input → POST `/api/gog/start-auth` which runs `gog auth add <email> --remote --step 1 --no-input` to capture the Google OAuth URL → wizard shows URL with "Open Google sign-in" button + input field; (2) user signs in, gets redirected to a localhost URL that won't load, copies that URL from the address bar, pastes it back → POST `/api/gog/complete-auth` which runs `gog auth add --remote --step 2 --auth-url <pasted-url>` to exchange the code for a refresh token. Validates the pasted URL contains `code=` before invoking gog so we give a targeted error if the user pastes the wrong thing. |
| 1.6.15 | Better copy on "Optional next steps" — chevron (›) bullets looked like clickable expanders, replaced with real dot bullets (•). Also expanded the Connect-Google value-prop both on the Done screen tile and the Sign-in step: spelled out concretely that the agent can write research notes/meeting recaps into new Docs and Sheets, not just abstract "file/email/calendar superpowers". |
| 1.6.16 | Rewrote the gog OAuth "Sign in to Google" step. Three fixes: (1) action-first ordering — "Open Google sign-in" button is now the FIRST element instead of being buried below the explanatory steps that depended on clicking it; (2) walks through Google's actual three screens (unverified-app warning → consent → scope selection with "Select all") instead of saying "click Allow" once; (3) explicitly names the "This site can't be reached" browser error that the OAuth redirect produces and shows the URL shape (with `/oauth2/callback?state=…&code=…`) so users know what to look for and copy. Restructured into four labeled card blocks for better scanability. |
| 1.6.17 | Flag the 2-Step Verification requirement BEFORE the user hits it. Google blocks OAuth client creation for accounts without 2SV, but we were silent about it until the user was already deep into Connect Google. Now mentioned in three places: README Prerequisites (new bullet #2 with deep link to enable 2SV), Telegram step of the wizard (yellow heads-up card priming the user for what's coming), and the top of Connect Google itself (prerequisite callout right before Step 1). New `.heads-up` CSS class for the callouts. |
| 1.6.18 | README Deploy section now also documents the "Authorize Cloud Shell" dialog that pops up alongside (or shortly after) the "Trust repo" dialog. Users were confused by the second dialog because we only documented the first. Both are now listed as expected dialogs to click through before reaching the terminal. |
| 1.6.19 | README Prerequisites gains a fourth bullet: a Telegram account (with link to install Telegram). We assumed everyone had Telegram and made the wizard's Step 1 invent a bot via @BotFather without ever calling out that prerequisite up front. |
| 1.6.20 | Stop abbreviating "two-step verification" as "2SV" in the README. The abbreviation was confusing to readers who aren't already familiar with the term. Spell it out in full. Wizard HTML already used the Google-branded form "2-Step Verification" as link text only, no abbreviation, so no changes there. |
| 1.6.21 | Fix the ADC step dying with `gcloud auth application-default login failed` even though gcloud actually succeeded. Root cause: `{ printf "y\n"; exec cat </dev/tty; }` keeps reading after gcloud exits; its next write to the closed pipe triggers SIGPIPE; `set -o pipefail` propagates that as pipeline failure. Now disable pipefail around just that pipeline and check gcloud's true exit via `PIPESTATUS[1]`. Also adds "Do you want to continue" to the warning-line grep filter. Banner simplified to one line "Easy OpenClaw Deployment". README adds a callout about re-clicking the deploy button if Cloud Shell stalls. |
| 1.6.22 | Replace the printf+cat hack for ADC auth with an `expect` script. The old hack consumed the user's verification-code paste BEFORE gcloud printed its "Once finished, enter the verification code:" prompt — so the prompt appeared with no visible cursor (paste already in the pipe), the user thought it failed, pasted again, and the second paste hit a closed pipe. With `expect`, we wait for gcloud's prompt FIRST, then ask the user with a labeled "▸ Paste verification code here and press Enter:" prompt. |
| 1.6.23 | Add a "Use a different bot" link to the pairing screen footer, next to "Already paired earlier? Skip to dashboard". The restartTelegram path already existed but was only reachable after the 3-minute timeout. Now visible from the start, for the case where a Telegram bot token is in use by an older OpenClaw VM that's still polling — the new claw never sees `/start` because the old one grabs it first. |
| 1.6.24 | **Docs refresh after the v1.6.0-v1.6.23 functional work: README's "What you get" / "What the script does" / "After deploy" sections now describe the actual current flow (ADC step, in-wizard gog OAuth with paste-the-redirect-URL, the URL-fragment dashboard token). CLAUDE.md §1, §2 (flow diagram), and §9 (open work) updated — §9 stops claiming the wizard "directs the user to the OpenClaw dashboard's gog skill" since v1.6.14+ does the whole flow in our own UI.** ← current |

Browse the full commit history with `git log --oneline` from the repo
root.

### Tags and rollback

Every published version is tagged in git (`v1.6.0` … `v1.6.9` etc.) so
you can pin or roll back without hunting for commit hashes.

**To deploy a specific older version** (e.g. v1.6.6 after a regression):

```bash
git clone https://github.com/iliasacademia/openclaw-gcp-deploy /tmp/ocd
cd /tmp/ocd
git checkout v1.6.6      # detached HEAD on that tag
bash deploy.sh           # uses startup.sh from this checkout
```

This works because `deploy.sh` reads `startup.sh` from `$SCRIPT_DIR`
(its own directory). But note: the running VM also `git clone`s the
repo at first boot — currently from `main`, so a long-running VM would
self-update on restart. If you need a VM pinned to a tag, either patch
`startup.sh`'s `git clone` to add `--branch v1.6.6` or hot-pin the VM:

```bash
gcloud compute ssh openclaw-vm --project=<id> --zone=<zone> --command='
  cd /opt/openclaw-deploy &&
  sudo -u openclaw git fetch --tags &&
  sudo -u openclaw git checkout v1.6.6 &&
  sudo systemctl restart openclaw-setup openclaw-gateway'
```

**To find which version a deployed VM is running**, hit
`/api/diagnostics?token=<setup-token>` — the response has a
`setupServerVersion` field.

**To revert main itself** (rare — usually pin a deploy instead):

```bash
git revert <bad-commit-hash>   # creates a new "undo" commit
git push origin main
```

Avoid force-pushing or rewriting history on `main`; revert commits are
auditable and easier to reason about.

---

## 11. Things a new chatbot session should know

- The repo is on GitHub; the canonical state is `origin/main`. Don't
  trust local-only state.
- Working directory in past sessions: `/tmp/openclaw-gcp-deploy/` (a
  fresh clone). The user's primary working directory
  `/Users/iliasbeshimov/Documents/Dev Folders/Easy Claw Deploy via GCP`
  is intentionally empty.
- For the OpenClaw CLI documentation, the npm tarball contains
  `docs/` markdown and `dist/extensions/*/openclaw.plugin.json` —
  these are authoritative when in doubt about config keys, model ids,
  etc. `npm pack openclaw@latest && tar -xzf openclaw-*.tgz` gets you
  a local copy.
- `openclaw config validate` and `openclaw config schema` are
  invaluable when changing the config shape — they catch every typo.
- The user prefers terse, action-oriented responses. They don't want
  preamble. State what changed and what's next.
- The user is comfortable with shell, GCP, and reading code — but is
  building this FOR non-technical users. Always optimise the
  end-user UX, not the developer-user UX.
- Don't push to `main` without explicit user authorization. Bash
  policy denies it by default; the user has authorised it before but
  the authorisation doesn't carry across sessions.

---

## 12. Quick start for a new session

```bash
# Get the code
git clone https://github.com/iliasacademia/openclaw-gcp-deploy /tmp/openclaw-gcp-deploy
cd /tmp/openclaw-gcp-deploy

# Read the recent commit messages — they contain the "why"
git log --oneline -20

# See what tests run
cat test.sh

# Run them
bash test.sh

# Read the schema reference (requires openclaw installed)
npm install -g openclaw@latest
openclaw config schema | less

# Optionally explore the OpenClaw docs that ship with the package
npm pack openclaw@latest
tar -xzf openclaw-*.tgz
ls package/docs/
```

If you (the new chatbot) get stuck on what a config key does, run
`openclaw config schema | jq '.properties.gateway'` (or whichever
section). The OpenClaw CLI is the source of truth.
