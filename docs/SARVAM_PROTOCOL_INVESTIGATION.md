# Sarvam Saaras-v3 streaming WebSocket protocol — investigation

_Overnight 2026-06-21/22, ahead of Deep's morning rebuild. Triggered by
4 consecutive failed test attempts on `SarvamProvider` returning
"Socket is not connected" ~500-700ms after `CloudMicCapture.start`._

**Verdict.** Root cause is **wire-format mismatch**: our impl sends
audio as raw binary WebSocket frames, but Sarvam expects JSON-wrapped
base64. Three smaller parameter-name fixes piggyback. All four
findings have multiple independent citations (official Sarvam docs +
AVR production reference + Pipecat SDK).

Status: **fixed-not-tested** — code change ready, evidence-backed,
awaiting Deep's on-device retry.

---

## Sources consulted

1. **Sarvam official docs — WebSocket reference**
   https://docs.sarvam.ai/api-reference-docs/speech-to-text/transcribe/ws
2. **Sarvam official docs — streaming API guide**
   https://docs.sarvam.ai/api-reference-docs/api-guides-tutorials/speech-to-text/streaming-api
3. **AVR (Agent Voice Response) avr-asr-sarvam — production reference impl**
   https://github.com/agentvoiceresponse/avr-asr-sarvam
   Full `index.js` source dumped in this investigation; quoted verbatim
   in §"Evidence — AVR reference impl" below.
4. **Pipecat SarvamSTTService — Python SDK consumer**
   https://github.com/pipecat-ai/pipecat/blob/main/src/pipecat/services/sarvam/stt.py
   Wraps the official Sarvam Python SDK; same wire format guaranteed
   since the SDK serializes to the same shape on the socket.
5. **Sarvam Saaras V3 model card**
   https://www.sarvam.ai/blogs/asr

---

## The Sarvam contract (definitive, cited)

### 1. URL

```
wss://api.sarvam.ai/speech-to-text/ws
```

(Our current `defaultEndpoint` after hotfix-4 already uses this.
Source: AVR `index.js` line `process.env.SARVAM_WEBSOCKET_URL ||
'wss://api.sarvam.ai/speech-to-text/ws'`; Sarvam docs §"WebSocket
Speech-to-Text Format → Base URL".)

### 2. URL query parameters (config goes here, not in a JSON handshake)

Per AVR `index.js`:

```javascript
const params = new URLSearchParams({
  'language-code': process.env.SARVAM_SPEECH_RECOGNITION_LANGUAGE || 'en-IN',
  model: process.env.SARVAM_SPEECH_RECOGNITION_MODEL || 'saarika:v2.5',
  mode: process.env.SARVAM_SPEECH_RECOGNITION_MODE || 'transcribe',
  sample_rate: 8000,
  input_audio_codec: 'pcm_s16le',
});
```

Key points:
- **`language-code` uses HYPHEN, not underscore.** Sarvam docs confirm:
  query parameters include `language-code` (e.g., en-IN, hi-IN). Our
  current code uses `language_code` with underscore.
- `input_audio_codec=pcm_s16le` is REQUIRED to tell Sarvam the wire
  audio format. Our current code omits this entirely.
- `sample_rate` belongs in URL (numeric, no quotes) AND in the
  per-chunk JSON payload (stringified). Our current code passes
  neither.
- `high_vad_sensitivity` is per-docs supported as a query param. Our
  current code passes it; keep.

### 3. Authentication

Single header on the WS upgrade:

```
Api-Subscription-Key: <key>
```

(AVR `index.js`: `'Api-Subscription-Key': process.env.SARVAM_API_KEY`.
Sarvam docs: `"Api-Subscription-Key"` header required in the
WebSocket handshake.)

**No Bearer/Authorization header.** Hotfix-4 already dropped our
speculative `Authorization` header — confirmed correct.

### 4. Initial handshake message

**There is none.** After WS upgrade, the next message on the socket is
the first audio chunk. Sarvam docs §"Client Handshake/Config" state:
"The spec shows no explicit handshake message — configuration occurs
entirely through query parameters during connection establishment."

(Confirmed by AVR — `sarvamWs.on('open', ...)` just logs; the next
client action is the audio handler.)

**This means our hotfix-4 — which still does NOT send a JSON config
message — was correct on that point.** The remaining bug is the audio
format.

### 5. Audio chunk format (THE ROOT CAUSE BUG)

Each audio chunk is sent as a JSON-encoded text WebSocket frame with
this exact shape (AVR `index.js`, verbatim):

```javascript
sarvamWs.send(JSON.stringify({
  audio: {
    data: Buffer.from(chunk).toString('base64'),
    sample_rate: "8000",
    encoding: "audio/wav"
  }
})) ;
```

Cross-validated by Pipecat (which wraps the official Python SDK):

```python
audio_base64 = base64.b64encode(audio).decode("utf-8")
encoding = (
    self._input_audio_codec
    if self._input_audio_codec.startswith("audio/")
    else f"audio/{self._input_audio_codec}"
)
method_kwargs = {
    "audio": audio_base64,
    "encoding": encoding,
    "sample_rate": self.sample_rate,
}
```

Key facts:
- **JSON text frame**, not binary frame. (We send `.data(...)` — wrong.)
- `audio.data` is the raw s16le PCM bytes, base64-encoded.
- `audio.sample_rate` is a **string** in the JSON payload (AVR uses
  `"8000"`, our payload sample rate would be `"16000"`).
- `audio.encoding` is one of `audio/wav`, `pcm_s16le`, `pcm_l16`,
  `pcm_raw`. AVR uses `audio/wav`. Pipecat normalizes
  `pcm_s16le` → `audio/pcm_s16le` (prepends `audio/` if missing).
  Both forms work; the `audio/wav` form is the one in Sarvam's
  documented examples. We'll use `audio/wav`.

**Frame size hint** (from Sarvam docs & Saaras V3 model card):
"One frame is 512 audio samples — 32 ms at 16 kHz, 64 ms at 8 kHz."
This means Sarvam's VAD operates on 512-sample windows internally.
The chunk size we send doesn't have to be exactly 512; the server
buffers + windows internally. AVR doesn't pin a chunk size; it just
forwards whatever the upstream HTTP request body delivers. We can
keep CloudMicCapture's ~85ms (1365-sample) chunks.

### 6. Server response format

Sarvam sends JSON text frames with this envelope:

```json
{
  "type": "data",
  "data": {
    "request_id": "...",
    "transcript": "...",
    "language_code": "hi-IN",
    "metrics": {
      "audio_duration": 2.5,
      "processing_latency": 0.8
    }
  }
}
```

Other types:
- `"type": "error"` → `{data: {message: "..."}}` (per AVR)
- `"type": "events"` → VAD events (Pipecat handles
  `signal_type` / `occured_at`) (when `vad_signals=true`)

Our current `extractSarvamTranscript` handles the `transcript`,
`data.transcript`, and `text` keys — needs to also recognize the
`type: "data"` discriminator and skip non-`data` types cleanly.
Current code in `handleServerJson` already does this loosely
(checks `error` key first, falls through). Acceptable.

### 7. End of stream

AVR just closes the socket when the client request ends:

```javascript
req.on('end', () => {
  if (sarvamWs && sarvamWs.readyState === WebSocket.OPEN) {
    sarvamWs.close();
  }
});
```

No "stop" message needed. Our `wsTask.cancel(with: .normalClosure)`
is the Swift equivalent. (Our hotfix-3 still sends a speculative
`{"type":"stop"}` before close — harmless if Sarvam ignores unknown
JSON, but we should drop it for cleanliness.)

---

## Evidence — AVR reference impl (full source)

This is the working production code that AVR uses to bridge Asterisk
audio → Sarvam. Source:
https://raw.githubusercontent.com/agentvoiceresponse/avr-asr-sarvam/main/index.js

The two critical lines:

**(A) URL + headers:**
```javascript
sarvamWs = new WebSocket(url, {
  headers: {
    'Api-Subscription-Key': process.env.SARVAM_API_KEY,
  }
});
```
where `url` = `wss://api.sarvam.ai/speech-to-text/ws` + URL-encoded
query params (see §2 above).

**(B) Audio chunk send:**
```javascript
req.on('data', (chunk) => {
  if (sarvamWs && sarvamWs.readyState === WebSocket.OPEN) {
    sarvamWs.send(JSON.stringify({
      audio: {
        data: Buffer.from(chunk).toString('base64'),
        sample_rate: "8000",
        encoding: "audio/wav"
      }
    })) ;
  }
});
```

**(C) Response parsing:**
```javascript
sarvamWs.on('message', (data) => {
  try {
    const response = JSON.parse(data.toString());
    switch (response.type) {
      case 'data':
        console.log('Data:', response.data.transcript);
        res.write(response.data.transcript);
        break;
      case 'error':
        console.error('Error:', response.data.message);
        ...
    }
  } catch (err) { ... }
});
```

These three blocks are the entire contract surface. Everything else
is HTTP request/response plumbing irrelevant to GurbaniLens.

---

## Current `SarvamProvider.swift` vs reality — numbered deltas

State as of commit `d22cd6b` (hotfix-4):

| # | Current code does | Sarvam expects | Fix |
|---|---|---|---|
| 1 | `wsTask.send(.data(chunk))` — raw binary frame | JSON text frame `{audio: {data: base64, sample_rate: "16000", encoding: "audio/wav"}}` | Build JSON, base64-encode PCM, send via `.string(...)` |
| 2 | URL query param `language_code=pa-IN` (underscore) | `language-code=pa-IN` (hyphen) | Rename query item to `language-code` |
| 3 | No `input_audio_codec` query param | `input_audio_codec=pcm_s16le` required | Add query item |
| 4 | No `sample_rate` query param | `sample_rate=16000` query param (defaults to 16000 if omitted, but explicit is safer) | Add query item `sample_rate=16000` |
| 5 | Speculative `{"type":"stop"}` JSON sent before close | Just close the socket | Drop the stop message |
| 6 | (correct) Header `api-subscription-key` | (correct) `Api-Subscription-Key` | HTTP headers case-insensitive — no change needed |
| 7 | (correct) `high_vad_sensitivity=true` query param | (correct, same) | No change |
| 8 | (correct) WS URL `/speech-to-text/ws` | (correct, same) | No change (already fixed in hotfix-4) |

Fix #1 is the root cause of the immediate disconnect. The others are
hygiene + correctness fixes that piggyback on the same edit.

---

## Why "Socket is not connected" appears 500-700ms in

When Sarvam receives a binary frame on a connection that expects
JSON text frames, the server doesn't gracefully send back an error
message — it closes the connection (presumably treating it as a
protocol violation). The client URLSession reports this as the
underlying `Socket is not connected` after the close handshake
completes, ~500-700ms after our first `wsTask.send(.data(...))`.

This matches Deep's [DIAG] timeline exactly:
- T+0ms: `CloudMicCapture.start` → WS upgrade succeeds, `start streaming begun`
- T+~85ms: first audio chunk arrives from mic tap; we send it as binary
- T+~500-700ms: Sarvam-side close propagates; `readLoop terminated`

After the fix, the same flow will land a JSON text frame instead, and
Sarvam will start emitting `{type: "data", data: {transcript: "..."}}`
messages within sub-second latency per the model card.

---

## What the fix looks like in code

See commit (to be applied after this doc lands):
`fix(ios): Sarvam audio frames are JSON-wrapped base64 (AVR + Pipecat ref)`

Touches only `SarvamProvider.swift`:

1. In `start()`: rename `language_code` query item → `language-code`;
   add `input_audio_codec=pcm_s16le` + `sample_rate=16000` query items.

2. In `sendAudio(_ chunk: Data)`: replace
   `try await task.send(.data(chunk))`
   with a base64-encode + JSON-serialize + `.string(...)` send.

3. In `stop()`: drop the `{"type":"stop"}` send before close.

4. In `handleServerJson`: explicitly check `type == "events"` and skip
   (VAD events would otherwise hit our extractTranscript path and
   silently drop, which is fine but noisy).

Does NOT touch `CloudMicCapture.swift` — the s16le PCM byte format
emitted by CloudMicCapture is exactly what `audio.data` (base64-
decoded) expects, so the upstream is correct as-is.

Does NOT touch the `transcribeOneShot` REST batch helper used by
CompareScreen — that's a different REST endpoint
(`/speech-to-text` multipart) and was not implicated.

---

## Confidence the morning rebuild will work

**Medium-high.** Evidence is independent + cross-validated:
- AVR is documented as a production integration shipping audio to
  Sarvam every day.
- Pipecat's SDK consumer confirms the same wire format on a different
  language/stack.
- Sarvam's own docs page describes the same envelope.

Remaining risks (why not high):
- **Mode parameter.** AVR uses `mode=transcribe`. We don't pass it
  explicitly. Sarvam docs say it defaults to `transcribe`, but our
  inherited default might be different for some account configs. If
  the rebuild fails with a similar close-on-first-audio, adding
  `mode=transcribe` to the query is the next thing to try.
- **`input_audio_codec=pcm_s16le` vs the JSON payload's
  `encoding=audio/wav`.** AVR has these two NOT matching (`pcm_s16le`
  in the URL, `audio/wav` in the payload). The AVR setup ships with
  Asterisk audio which is raw PCM but they label the payload as
  `audio/wav`. This might be Sarvam being lenient. We'll mirror AVR's
  exact pattern. If Sarvam rejects with a complaint about format
  mismatch, normalise both to `pcm_s16le`.
- **Saaras-v3 vs Saarika.** AVR uses `saarika:v2.5` (an older STT-only
  model). We use `saaras:v3` (newer, STT+translate, what Deep wants).
  The wire format is the same for both per Sarvam's docs (`saaras:v3`
  is the documented default and recommended model). Risk that there's
  a Saaras-v3-specific protocol delta is low but non-zero.
- **Free-trial credit was burned each attempt.** Deep used 4/50
  credits in the failed-rebuild loop. Remaining: 46/50 for June.
  CloudTrialPolicy will keep counting.

If the morning rebuild still fails: paste the new [DIAG] lines and we
adjust. The investigation has covered enough ground that diagnosis on
the next failure should take minutes not hours.

---

## Other Sarvam reference impls considered but not deep-fetched

- **`sarvam-ai-python` official SDK** — does the same JSON serialization
  internally; not worth the extra fetch given AVR + Pipecat agreement.
- **`livekit-plugins-sarvam`** — search results found a TTS-focused
  plugin (`pratham-sarvam`'s PR #2356 is for TTS, not STT). STT
  coverage may be Pipecat-only as of mid-2026.
- **Sarvam Rust SDK (`sarvamai/sarvam-ai-rust`)** — search didn't
  surface it; either doesn't exist publicly or is private. Not needed
  given AVR + Pipecat agreement.

If the morning rebuild fails and we need a third independent source,
the next thing to try is fetching the Python SDK's
`sarvamai/speech_to_text/streaming/__init__.py` directly and reading
its `.connect()` + audio-sending plumbing.
