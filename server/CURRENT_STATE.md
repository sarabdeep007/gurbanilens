# Server skeleton — current state (2026-06-17)

Inventory done as Task 1 of the Phase 2A server brief. This file is the
status report before Task 2; no code touched yet.

## Files present

```
server/
├── .env.example        # PORT/HOST + WHISPER_DISABLED + WHISPER_MODEL_PATH + FEEDBACK_QUEUE_DIR
├── README.md           # privacy contract + endpoint sketches + status table
├── package.json        # fastify 4.27 + @fastify/websocket 10.0
└── src/
    └── index.js        # 93 lines — all endpoints inline, all stubbed
```

No `node_modules/`, no lockfile, no tests, no Dockerfile, no PM2 config,
no middleware, no persistence layer, no auth layer, no rate limiter.

## Endpoints currently implemented (stub level)

| Method | Path | Status | Notes |
|---|---|---|---|
| GET  | `/healthz`               | ✅ live | returns `{status:"ok", whisper:<bool>}` |
| GET  | `/transcribe`            | 🟡 stub | **WebSocket** endpoint — accepts PCM stream, returns `not_implemented` |
| POST | `/feedback/correction`   | 🟡 stub | accepts JSON, validates shape only, returns 202, persists nothing |
| GET  | `/feedback/submissions`  | 🟡 stub | returns empty list |
| DEL  | `/feedback/submissions`  | 🟡 stub | no-op, returns `{deleted:0}` |

## Auth mechanism sketched

- **None on `/transcribe`** — WebSocket has no token check.
- **In-body session_token** on `/feedback/correction` — per the
  `docs/feedback_channel_spec.md` wire format (Authorization header
  is explicitly *not* used in the spec; the token goes in the JSON body).

## Env vars expected

- `PORT` (default 8443)
- `HOST` (default 0.0.0.0)
- `WHISPER_DISABLED` (dev escape hatch)
- `WHISPER_MODEL_PATH` (`/var/lib/gurbanilens/models/ggml-large-v3.bin`)
- `FEEDBACK_QUEUE_DIR` (`/var/lib/gurbanilens/feedback-queue`)

## Privacy contract (already stated in README)

The README documents seven commitments — they are baked into intent but
not all into code yet:

1. ✅ No audio storage — easy because nothing persists yet
2. 🟡 No content logging — Fastify logger has custom serializers stripping
   headers/IPs/bodies, but the logger config is inline in `src/index.js`
   and easy to break accidentally. **Should move to dedicated middleware.**
3. ✅ No user identifier — ephemeral session token only
4. ✅ DE jurisdiction — documented, depends on deploy target
5. ✅ Source-available — repo is OSS
6. ✅ Opt-in per session — client-side concern, server is passive
7. ✅ Always reversible — client-side concern

## Dependencies (package.json)

```json
"fastify":            "^4.27.0",
"@fastify/websocket": "^10.0.1"
```

No multipart parser, no validator (zod / ajv), no SQLite driver, no
rate-limiter plugin, no test runner.

---

## Gaps for a deployable v1 fallback server

### Critical (block ship)

1. **Endpoint shape mismatch with brief.** The current `/transcribe` is a
   WebSocket streaming endpoint, designed for the *original* Phase 2A
   scope (continuous live listening). The brief — and the updated
   CLAUDE.md — pivot v1 to **tap-to-speak voice search**. That needs
   `POST /transcribe` accepting a multipart/form-data audio file
   (WAV/MP3/M4A, ≤60s, ≤10MB), one request, one response. The WebSocket
   variant is **Phase 2A v2 scope, deferred**.
2. **No actual ASR.** No `faster-whisper` subprocess wired up. No model
   on disk in this dev env, and `/transcribe` returns
   `not_implemented` regardless.
3. **No auth.** Brief mandates a bearer session token on `/transcribe`
   in the Authorization header. None implemented.
4. **No rate limiting.** Brief specifies 60 req/hr/session on
   `/transcribe` and 20/hr/session on `/feedback`. Nothing in place.
5. **Port number drift.** Skeleton listens on 8443; brief specifies 4040
   (PM2 host already has 12 services running — verified port 4040 is
   free).

### Important (block clean ship)

6. **No `/readyz`.** `/healthz` exists. The brief asks for both.
7. **No multipart parser.** Need `@fastify/multipart` for file uploads.
8. **No persistence for feedback.** `/feedback/correction` returns 202
   but nothing is stored. Brief calls for SQLite at
   `server/data/feedback.db` with a concrete schema.
9. **No input validation.** Hand-rolled `typeof` checks won't survive
   real traffic. Zod (or Fastify's built-in JSON schema) needed.
10. **Privacy contract not enforced as middleware.** It lives in
    Fastify's `serializers` block — one careless edit breaks the
    guarantee. The brief wants a dedicated middleware module so it can
    be code-reviewed in isolation.

### Deployment readiness gaps (Task 5 scope)

11. No `Dockerfile`.
12. No `ecosystem.config.js` (PM2).
13. No `DEPLOY.md` runbook.
14. No tests at all (`npm test` runs `node --test tests/` and that
    directory doesn't exist).

---

## Architectural tensions to flag before Task 2

These need a decision so I'm not silently doing the wrong thing:

### A. `/feedback` body shape — brief vs. existing spec

The brief in this dispatch describes `POST /feedback` with this body:

```json
{
  "session_token": "...",
  "audio_blob_url": null,
  "transcript": "...",
  "matched_ang": ...,
  "matched_pangti": ...,
  "matched_confidence": ...,
  "user_correction_text": "..." | null,
  "user_correction_ang": ... | null,
  "user_correction_pangti": ... | null,
  "timestamp": "..."
}
```

The authoritative `docs/feedback_channel_spec.md` (already committed,
already reviewed by Deep) describes `POST /feedback/correction` with a
*different, richer* schema: structured `match` and `correction`
sub-objects, `audio_base64` inline (not a URL), `app_version`,
`platform`, `model_size`, `mode`, `matcher_window_text_latin`.

**My read:** the spec wins. It's been thought-through end-to-end; the
brief's shape looks like a quick sketch. I'll implement `POST
/feedback/correction` per the spec — and store the spec's full payload
in SQLite with a column-per-field schema. If Deep wants the
brief's flatter shape, easy revert.

### B. Auth header vs. in-body token

- Brief on `/transcribe`: bearer session token in `Authorization` header.
- Spec on `/feedback/correction`: session token in JSON body.

These can coexist (different endpoints, different conventions). I'll
implement both as specified — but I'll factor the rate-limit bucket
lookup into a shared helper that takes a token from either source.

### C. faster-whisper invocation strategy

Brief allows: "faster-whisper Python subprocess (or node-faster-whisper
if available — pick whichever ships reliably) on Linux".

**Pick:** Python subprocess. `node-faster-whisper` is npm-immature and
the canonical, battle-tested path is the upstream Python package. We
ship `server/src/asr/whisper_worker.py` that takes a path on argv and
emits JSON to stdout. Easier to debug, matches Phase 1's CLI
implementation 1:1, and faster-whisper releases hit Python first.

### D. `temperature=0` non-determinism guard

Phase 1 finding from CLAUDE.md: Whisper non-determinism is a known
flag. The on-device Swift wrapper already pins `temperature=0`. The
server should too — bake into `whisper_worker.py` config.

---

## What I plan to do in Task 2

1. Add deps: `@fastify/multipart`, `zod`, `@fastify/rate-limit`,
   `better-sqlite3`. (SQLite goes in for Task 3, but I'll add it now to
   avoid a second `npm install` round-trip.)
2. Replace the WebSocket `/transcribe` with `POST /transcribe`
   (multipart). Keep the WebSocket variant commented out / archived
   for the v2 scope so it's easy to bring back.
3. Wire the Python `faster-whisper` subprocess with a strict timeout
   and in-memory temp file (deleted on response).
4. Add bearer-token middleware + in-memory rate limiter (60/hr).
5. Add `/readyz` that checks the model file exists.
6. Bind to port 4040.

I will stop and HOLD with curl test output before moving on.

---

**HOLDING for next dispatch.**
