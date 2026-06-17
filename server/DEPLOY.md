# Deployment runbook — gurbanilens server

Use when Deep decides to flip on the opt-in server fallback. Until then
the iOS app talks only to its bundled whisper.cpp.

## TL;DR cost

- Hetzner CCX23 (4 vCPU dedicated, 16 GB RAM, 240 GB NVMe) — **~€24.50 / mo**
- Falkenstein DE location (GDPR jurisdiction)
- Outbound traffic ~20 TB included → free in normal use
- Domain `server.gurbanilens.com` — already owned

Total expected steady-state spend: **~€25 / month** for the full server
fleet at v1 scale.

## Pre-deploy checklist

- [ ] Hetzner Cloud project created
- [ ] SSH key uploaded to the Hetzner project
- [ ] DNS A record `server.gurbanilens.com` → Hetzner IPv4
- [ ] DNS AAAA record `server.gurbanilens.com` → Hetzner IPv6
- [ ] Generated production `FEEDBACK_HMAC_SECRET` via `openssl rand -hex 32`
- [ ] Decided which Whisper model to ship (`large-v3` is default; `medium` for ~1 GB savings)

## 1. Provision the box

Hetzner Cloud → New Project → Add server:
- Location: Falkenstein DE (fsn1)
- Image: Ubuntu 24.04 LTS
- Type: CCX23 (4 vCPU dedicated, 16 GB)
- SSH keys: your dev key
- Backups: enable (20% of base cost; recovers a corrupted SQLite)
- Name: `gurbanilens-prod-1`

## 2. Base setup

```bash
ssh root@<IP>

# Unattended security upgrades
apt update && apt -y full-upgrade
apt -y install unattended-upgrades fail2ban ufw curl ca-certificates git ffmpeg

# Non-root deploy user
adduser --disabled-password --gecos "" gurbanilens
usermod -aG sudo gurbanilens
mkdir -p /home/gurbanilens/.ssh
cp /root/.ssh/authorized_keys /home/gurbanilens/.ssh/
chown -R gurbanilens:gurbanilens /home/gurbanilens/.ssh
chmod 700 /home/gurbanilens/.ssh
chmod 600 /home/gurbanilens/.ssh/authorized_keys

# Firewall: only 22 + 80 + 443
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw enable
```

## 3. Install Node 22 + Python venv tooling

```bash
# Node 22 via NodeSource. No build-essential needed — sql.js is pure WASM
# and we don't compile native modules.
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt -y install nodejs

# uv for Python venv
sudo -u gurbanilens bash -c "curl -LsSf https://astral.sh/uv/install.sh | sh"

# PM2 globally
npm i -g pm2
```

## 4. Deploy the app

```bash
# As gurbanilens user
sudo -iu gurbanilens
git clone https://github.com/<org>/gurbanilens.git
cd gurbanilens/server
npm ci --omit=dev

# Python venv
~/.local/bin/uv venv .venv-asr
~/.local/bin/uv pip install --python .venv-asr/bin/python faster-whisper

# Encrypted directory for the feedback queue (LUKS or just chmod for v1).
# v1 ships no audio, so the DB is the only sensitive asset and it
# contains HMAC-keyed metadata only.
mkdir -p data
chmod 700 data
```

## 5. Configure environment

`/etc/gurbanilens/server.env` (root-owned, mode 600):

```
NODE_ENV=production
PORT=4040
HOST=127.0.0.1
LOG_LEVEL=info

WHISPER_MODEL=large-v3
WHISPER_PYTHON=/home/gurbanilens/gurbanilens/server/.venv-asr/bin/python
WHISPER_WORKER=/home/gurbanilens/gurbanilens/server/src/asr/whisper_worker.py

FEEDBACK_DB_PATH=/home/gurbanilens/gurbanilens/server/data/feedback.db
FEEDBACK_HMAC_SECRET=<openssl rand -hex 32 output here>
```

## 6. Pre-warm the Whisper model

```bash
# Forces faster-whisper to download large-v3 (~3 GB) before serving traffic
sudo -iu gurbanilens
cd gurbanilens/server
WHISPER_MODEL=large-v3 .venv-asr/bin/python -c \
  "from faster_whisper import WhisperModel; WhisperModel('large-v3', device='auto', compute_type='auto')"
```

## 7. Start under PM2

```bash
sudo -iu gurbanilens
cd gurbanilens/server
pm2 start ecosystem.config.js --env production --update-env
pm2 save
pm2 startup systemd -u gurbanilens --hp /home/gurbanilens
# pm2 prints a sudo command — run it as root
```

## 8. Nginx reverse proxy + TLS

`/etc/nginx/sites-available/gurbanilens`:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name server.gurbanilens.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name server.gurbanilens.com;

    # certbot-managed
    ssl_certificate     /etc/letsencrypt/live/server.gurbanilens.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/server.gurbanilens.com/privkey.pem;

    # Privacy contract enforcement at the edge:
    # strip IP-revealing headers before they reach the app.
    proxy_hide_header  X-Forwarded-For;
    proxy_hide_header  X-Real-IP;
    proxy_hide_header  X-Forwarded-Host;

    # Cap upload size at /transcribe limit.
    client_max_body_size 12M;

    # Security headers (defence in depth — app already sets these).
    add_header X-Robots-Tag "noindex" always;
    add_header Cache-Control "no-store" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    location / {
        proxy_pass http://127.0.0.1:4040;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        # Intentionally NOT setting X-Forwarded-For / X-Real-IP — the
        # app's privacy contract requires no IP propagation.
    }
}
```

```bash
apt -y install nginx certbot python3-certbot-nginx
ln -s /etc/nginx/sites-available/gurbanilens /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
certbot --nginx -d server.gurbanilens.com
```

## 9. Verify

```bash
curl https://server.gurbanilens.com/healthz
# {"status":"ok","whisper_disabled":false}

curl https://server.gurbanilens.com/readyz
# {"ready":true,...}

# Auth-required endpoint
curl -X POST https://server.gurbanilens.com/transcribe \
  -H "Authorization: Bearer test-from-laptop-$(date +%s)" \
  -F "audio=@some-sample.wav"
```

## 10. Monitoring

- `pm2 status` — process health
- `pm2 logs gurbanilens-server` — runtime logs (already privacy-filtered)
- `journalctl -u nginx` — proxy errors
- Hetzner Cloud Console — CPU / RAM / disk graphs

### Health checks to wire into external monitoring

| Endpoint | Healthy response |
|---|---|
| `GET https://server.gurbanilens.com/healthz` | 200 + `{"status":"ok"}` |
| `GET https://server.gurbanilens.com/readyz`  | 200 + `{"ready":true}` |

Alert on:
- `/healthz` non-200 for > 5 min
- 5xx rate > 1% over 10 min
- p99 latency > 30 s (large-v3 normal range: 5–15 s)

## 11. Rollback

```bash
sudo -iu gurbanilens
cd gurbanilens/server
git fetch
git checkout <last-good-sha>
npm ci --omit=dev
pm2 restart gurbanilens-server --update-env
```

If a SQLite migration introduced corruption: restore from
`data/feedback.db.bak.<timestamp>` (PM2's cron-job-backed snapshot,
configured separately).

## 12. Decommission

If we ever turn the fallback off, the policy is: **delete the SQLite
file**. There is no other persistent state about users on the box.

```bash
sudo -iu gurbanilens
cd gurbanilens/server
pm2 stop gurbanilens-server
rm -f data/feedback.db data/feedback.db-{shm,wal}
pm2 delete gurbanilens-server
```

Wipe and resell the Hetzner box via the standard Hetzner "delete server
+ securely erase disks" workflow.

## 13. Source-availability commitment

This entire runbook is in the public repo. Any infra change (DNS, env
var, Nginx config) must be reflected here before merging. If you find a
discrepancy between this doc and the live box, the *doc* is the bug —
PR it.
