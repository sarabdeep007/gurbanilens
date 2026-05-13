# GurbaniLens server

Optional Hetzner-hosted server that runs Whisper-large-v3 for devices that can't (or don't want to) run on-device ASR, and receives opt-in correction feedback for future fine-tuning.

**Not deployed yet.** This is the source-available skeleton documenting the privacy contract and the two endpoints. Phase 2A iOS will hit on-device ASR exclusively; this server activates only when the user opts in.

## Privacy contract (committed in writing)

These guarantees are enforced in code. Audit them in `src/`.

1. **No audio storage.** PCM chunks live only in process memory during transcription; dropped immediately after the WebSocket closes. No disk writes, no temp files, no log records of audio content.
2. **No content logging.** Server logs contain only: timestamp, request duration, error codes. They explicitly **do not** contain transcript text, audio bytes, IP addresses (stripped at the reverse proxy / Fastify hook), user agents, or device fingerprints.
3. **No user identifier.** Auth uses a per-session ephemeral token generated client-side. The token is opaque, expires when the session ends, and is not tied to any account. No persistent user ID exists.
4. **DE jurisdiction.** Hetzner data centre in Germany. GDPR-aligned defaults. No US Cloud Act exposure.
5. **Source-available.** This directory ships under the same OSS licence as the rest of the project.
6. **Opt-in per session.** Each session that uses server fallback prompts the user explicitly. "Always allow" requires a more explicit consent screen.
7. **Always reversible.** Settings → "Never use server" is honoured immediately and persistently.

## Endpoints

### `POST /transcribe` (WebSocket)

Client opens a WebSocket. Streams 16 kHz mono Int16 PCM frames in binary messages. Server runs `faster-whisper` (large-v3 by default) and streams back JSON segments:

```json
{ "start": 1.23, "end": 4.56, "text": "ਨਾਨਕ ਗਾਵੀਐ ਗੁਣੀ ਨਿਧਾਨੁ", "lang": "pa" }
```

### `POST /feedback/correction` (HTTP, JSON)

Opt-in user corrections. Body shape — see `docs/feedback_channel_spec.md` for the authoritative spec.

```json
{
  "session_token": "ephemeral-uuid",
  "app_version": "0.1.0",
  "audio_base64": "...",          // 5–10 second window, OPUS-encoded
  "audio_duration_sec": 7.2,
  "match": { "ang": 462, "pangti": 3, "score": 64.2 },
  "correction": { "type": "wrong_pangti", "ang": 462, "pangti": 5 },
  "mode": "sehaj_paath"
}
```

Server side: encrypt-at-rest into a queue (filesystem or SQLite), no further processing — processed manually / by batch job for Phase 3 dataset building.

### `GET /feedback/submissions?session_token=...`

Returns this device's prior submissions (empty for a new ephemeral token; the client also persists IDs locally to surface them in Settings → "View my submitted corrections").

### `DELETE /feedback/submissions?session_token=...`

Honours user's "Delete all my submissions" request. Server-side, immediate.

## Running locally (dev)

```bash
cd server
npm install
cp .env.example .env
# Edit .env: paths to models, port, etc.
node src/index.js
```

The dev server runs without Whisper if `WHISPER_DISABLED=1` is set — for endpoint shape verification only.

## Deployment plan (when Phase 2A polish lands)

- Hetzner CCX23 (4 vCPU, 16 GB, ~€25/mo) in Falkenstein DE
- `apt install ffmpeg` + Python 3.11 + `pip install faster-whisper`
- systemd service running this Node app on port 8443
- Caddy reverse proxy for TLS + IP-stripping middleware
- Daily security updates, source-of-truth in this repo

## Status

| Endpoint | Status |
|---|---|
| `/transcribe` | stub returns `{"error":"not_implemented"}` |
| `/feedback/correction` | stub returns 202 Accepted, writes nothing |
| `/feedback/submissions` | stub returns empty list |

This skeleton exists to land the privacy contract in writing before any audio leaves a device. Phase 2A doesn't depend on the server; this gates Phase 2C and the Settings → "Download additional translations" flow.
