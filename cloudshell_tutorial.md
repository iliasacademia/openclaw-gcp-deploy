# 🦞 Deploy OpenClaw to GCP

This will deploy OpenClaw on a new GCP VM in about **4 minutes**.

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

When it finishes, you'll see a URL like `http://YOUR_IP:8080` — open it to complete setup.
