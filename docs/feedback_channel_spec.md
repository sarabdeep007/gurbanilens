# Opt-in feedback channel — specification

Per Phase 2A architecture §17 (Addition 1). Captures user corrections to matcher output so the future fine-tuning dataset (Phase 3) has real-world labels.

**Hard rules:**
- Strictly opt-in. Default OFF. Toggle must be explicit, plain-language, single-screen.
- No user identity in any form.
- Same privacy contract as ASR fallback (see `server/README.md`).
- Capture path wired from launch even though server is stubbed; can't retro-generate user feedback.

## On-device flow

### 1. Onboarding consent (first launch)

Plain-language toggle, shown once:

> **Help improve GurbaniLens?**
> If something looks wrong, you can tap "This isn't right" to send a corrected match. We use it to improve recognition for everyone.
>
> What gets sent: a 5–10 second audio clip, our guess, your correction.
> What we never send: who you are, where you are, anything else.
> Audio goes to our server in Germany, gets queued for our research dataset, then deleted from the queue once we've used it for training.
>
> [ ☐ I'd like to help — share corrections ]
> [ Maybe later ]

Off by default. User can toggle in Settings → Help improve GurbaniLens.

### 2. "This isn't right" button

Visible on every matched Pangti in the Follow View when feedback is enabled. Tap → bottom sheet:

> **What's wrong?**
> - It's a different Pangti  → tap the correct line below
> - I don't know what this is → just send "unknown"
> - Cancel

Tapping the correct Pangti shows the audio + corrected-match preview, then a single **Send** button.

### 3. View / delete submissions

Settings → "View my submitted corrections" lists every submission this device has made. Each row: timestamp, original Ang/Pangti, corrected Ang/Pangti. Tap to remove a single submission. "Delete all my submissions" wipes them server-side.

## Wire format

`POST https://server.gurbanilens.com/feedback/correction`

Headers:
- `Content-Type: application/json`
- (no auth header — session token is in the body)

Body schema:

```json
{
  "session_token": "a4e7c0b9-...-ephemeral",
  "app_version": "0.1.0",
  "platform": "ios-17.4",
  "model_size": "small",

  "audio_base64": "Opus-encoded 5-10s window, mono 16kHz",
  "audio_duration_sec": 7.2,
  "audio_codec": "opus",

  "match": {
    "ang": 462,
    "pangti": 3,
    "shabad_id": "ABC",
    "score": 64.2,
    "coverage": 0.78,
    "line_type": "Pankti"
  },

  "correction": {
    "type": "wrong_pangti",
    "ang": 462,
    "pangti": 5
  },

  "mode": "sehaj_paath",
  "matcher_window_text_latin": "naanak gaaviyam gunee nidhaan"
}
```

Correction types:

| Type | Meaning | Extra fields |
|---|---|---|
| `wrong_pangti` | Wrong Pangti, user knows the right one | `ang`, `pangti` |
| `wrong_shabad` | Wrong Shabad entirely | `ang`, `pangti` of correct line |
| `not_gurbani` | Audio isn't Gurbani at all (e.g. announcement, Simran) | none |
| `unknown` | User doesn't know what it is | none |
| `partial_match` | Right shabad area but timestamp off | `notes` (free text, optional) |

### What is NEVER in the body

- `device_id` (no persistent identifier)
- `user_id` / email / Apple ID
- `location` / geolocation
- `ip` (server proxy strips this)
- `audio_filename` (the recording is in-memory only)

### Session token

Opaque UUIDv4, generated on the device once per listening session. Not tied to any user account. Server uses it only to fulfil the "view my submissions" and "delete all my submissions" requests *within this session*. Once the session ends, the token expires and there's no way to map old submissions back to the device.

This is intentional: we trade post-session UX (you can't view month-old submissions from a new session) for stronger anonymity (your submissions can't be linked to you ever).

## Server-side

`server/src/index.js` handles `POST /feedback/correction` by:

1. Light schema validation (reject if shape wrong)
2. Generate a server-side opaque submission id (UUIDv4)
3. Write `<FEEDBACK_QUEUE_DIR>/<id>.json` (in Phase 2A polish; currently stubbed to accept-but-not-persist)
4. Reply `202 Accepted, {"id": ..., "status": "accepted_but_not_persisted_yet"}` until persistence lands

The queue dir is on a LUKS-encrypted volume on the Hetzner host. Backup policy: none — these are research artifacts, losing the queue is acceptable.

## Dataset extraction (Phase 3)

Periodic (weekly?) job:
1. Read all submissions in queue
2. Manual review by Deep / Sevadaar reviewers — discard junk, validate corrections
3. Append reviewed corrections to the labelled training set
4. Delete originals from the queue (privacy commitment: queue is transient)

## Why capture this now

Even though Phase 3 (fine-tuning) is months out, the value of user-collected corrections compounds with time. A year of "Bhai Harjinder Singh recordings → matches identified at conf 65 → user clicked correct line → now we have ground truth" is the kind of dataset that turns the matcher from "30% confident" to "95% confident" on real Kirtan.

Without this capture path in V1, we'd start the Phase 3 dataset collection from zero. With it, we start with a year of free supervised data from actual app users.

## Auditing

The full code path is in this repo. Anyone can verify:
- `ios/GurbaniLens/GurbaniLens/UI/` — what gets sent client-side
- `server/src/index.js` — what gets received + how it's stored
- `server/README.md` — the privacy contract

Pull requests welcome.
