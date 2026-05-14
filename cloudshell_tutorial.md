# 🦞 Deploy OpenClaw to GCP

This will deploy OpenClaw on a new GCP VM in about **5 minutes**.

**What happens automatically:**
- A new GCP project is created ("My First Claw Agent")
- A VM is provisioned with Debian 13 + Node.js 24
- OpenClaw is installed and started
- Vertex AI (Gemini 3.1 Pro) is connected — no API key needed
- A setup wizard opens at the end for your Telegram bot

---

## Run the deploy script

Click the button below, then press **Enter**.

```bash
bash deploy.sh
```

---

When it finishes, you'll see a URL like `http://YOUR_IP:8080?token=...` — open it to complete setup. The token in the URL is single-use; bookmark or copy the full URL.

If the script reports the wizard didn't respond in time, wait 1-2 minutes and try the URL anyway — the VM is usually still finishing the OpenClaw install.
