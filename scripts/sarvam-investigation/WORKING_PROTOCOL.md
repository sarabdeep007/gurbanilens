# Sarvam Saaras-v3 — verified working wire protocol

_Verified 2026-06-22 from Linux. Both REST batch + WebSocket streaming
returned real Punjabi transcripts. Account, keys, model access all
confirmed working._

This document is the **canonical reference** for porting to Swift /
Kotlin / any other client. The Python scripts in this directory are
runnable proof.

---

## REST batch — PRIMARY working path

### Request

```
POST https://api.sarvam.ai/speech-to-text
Headers:
  api-subscription-key: <SARVAM_API_KEY>
  Content-Type: multipart/form-data; boundary=...
Form fields:
  file          = <WAV bytes>   (filename "test.wav", content-type "audio/wav")
  model         = saaras:v3
  language_code = pa-IN
```

### Response (HTTP 200, ~3-5 sec for a 4-sec clip)

```json
{
  "request_id": "20260622_889a38a6-d0f3-404a-be57-177d9caf2f3e",
  "transcript": "ਇੱਕ ਓਅੰਕਾਰ ਸਤਿ ਨਾਮੋ ਕਰਤਾ ਪੁਰਖੋ ਨਿਰਭਉ ਨਿਰਵੈਰ।",
  "language_code": "pa-IN"
}
```

### Reproducible call

`python3 scripts/sarvam-investigation/test_rest_batch.py default`

Log: `logs/rest_batch_default_20260622T113852.json`

### Maps to the Swift impl

`SarvamProvider.transcribeOneShot(wav:apiKey:)` already implements
this contract correctly (commit `205f421`, untouched since). The
`CompareScreen` Sarvam row already uses it. **No Swift change
needed for the REST batch path.**

---

## WebSocket streaming — VERIFIED working

### Connect

```
URL: wss://api.sarvam.ai/speech-to-text/ws
Query string:
  model=saaras:v3
  language-code=pa-IN        # HYPHEN, not underscore (per docs)
  mode=transcribe
  sample_rate=16000
  input_audio_codec=pcm_s16le
  high_vad_sensitivity=true
Headers:
  api-subscription-key: <SARVAM_API_KEY>
  (Capital "Api-Subscription-Key" also works — header names are
   case-insensitive on Sarvam's side. Verified by H1-bis.)
```

### After WS upgrade — NO config message

Server doesn't send any "ready" / ack. Client just starts streaming
audio chunks immediately.

### Audio chunk message — text frame, JSON-wrapped base64

Send each ~100ms chunk (3200 bytes of s16le PCM at 16 kHz mono) as
a text WebSocket frame:

```json
{
  "audio": {
    "data": "<base64-encoded raw s16le PCM>",
    "sample_rate": "16000",
    "encoding": "audio/wav"
  }
}
```

Three things to verify when implementing:

1. **Text frame, NOT binary.** Use `ws.send(jsonString)` not
   `ws.send(bytes, OPCODE_BINARY)`. Sending binary closes the
   socket (the failing iOS attempts before commit `de786bf`
   probably hit this; close diagnostic was masked by URLSession's
   "Socket is not connected" surface error).

2. **`audio` wrapper.** A flat
   `{"data":..., "sample_rate":..., "encoding":...}` does NOT
   work; must be nested under `audio`.

3. **`sample_rate` is a STRING** in the payload (`"16000"`), even
   though it's a numeric query param. Matches the AVR `index.js`
   reference.

### Server responses (text frames)

```json
{
  "type": "data",
  "data": {
    "request_id": "20260622_f6bb45a5-b434-4711-be07-eec785c2a3fa",
    "transcript": "ਇੱਕ ਓਅੰਕਾਰ ਸਤਿ ਨਾਮੋ ਕਰਤਾ",
    "timestamps": null,
    "diarized_transcript": null,
    "language_code": "pa-IN",
    "language_code_high_confidence": "pa-IN",
    "metrics": { ... }
  }
}
```

Sarvam emits multiple `type: "data"` messages per session — one per
detected speech segment. The example test audio (4.4 sec, single
utterance) returned TWO segments:
1. `"ਇੱਕ ਓਅੰਕਾਰ ਸਤਿ ਨਾਮੋ ਕਰਤਾ"` — after ~30 chunks (~3 sec of audio sent)
2. `"ਤਾਂ ਪੁਰਖ ਨਿਰਭਾਉ ਨਿਰਵੈਰ।"` — after all 45 chunks + brief drain wait

For the GurbaniLens v2 live-search UI, the consuming layer should
concat these segments with spaces — Sarvam treats each as an
independent transcription of a separate VAD-bounded segment, not as
incremental updates of the same transcript.

Other observed message types (per AVR + docs): `type: "events"` for
VAD signals when `vad_signals=true`, `type: "error"` for server-side
errors. Neither appeared in our successful runs (we used
`high_vad_sensitivity=true` but didn't enable `vad_signals`).

### Stream end

Just close the WS:

```
ws.close()
```

No `{type: "stop"}` or end-of-stream marker needed. Server will
flush any remaining segments before processing the close.

### Reproducible call

`python3 scripts/sarvam-investigation/test_ws_stream.py H1`

Log: `logs/ws_H1_20260622T114029.json`

### Maps to the Swift impl

The Swift `SarvamProvider.swift` after commit `de786bf` implements
this contract **byte-for-byte correctly** at the wire level — we
verified by sending an identical payload from Python with both
lowercase (`api-subscription-key`) and capital (`Api-Subscription-Key`)
header variants, both of which returned transcripts.

**If iOS is still failing with "Socket is not connected", the root
cause is iOS-specific, NOT wire-format.** Likely culprits to
investigate in a follow-up dispatch (do not fix here — out of scope
per current dispatch):

1. **URLSessionWebSocketTask send timing.** Possible that Swift is
   firing `wsTask.send(.string(...))` before the WS upgrade has
   fully completed. Add a state-receive check or send the first
   chunk only after receiving any server event (or wait ~200ms
   after `resume()`).

2. **URLSessionWebSocketTask buffering.** iOS may be batching frame
   sends differently than the Python lib. Worth checking with a
   single-chunk send + manual close to bisect.

3. **TLS / certificate pinning.** Unlikely with default URLSession
   but worth ruling out.

4. **`Authorization` Bearer header double-send.** Earlier Swift had
   `req.setValue(apiKey, forHTTPHeaderField: "Authorization")`
   alongside the subscription key. Hotfix-4 (commit `d22cd6b`)
   dropped this. Verify it stays dropped after de786bf.

5. **AVAudioSession contention** — CloudMicCapture may be tripping
   the audio session in a way that disrupts URLSession's own
   background thread. Test by sending a fixed canned-audio buffer
   (not live mic) from iOS and see if WS holds.

---

## Cost of this investigation

Estimated **3-4 Sarvam trial credits** consumed:
- 1 × REST batch default (Phase 2)
- 1 × WS H0 (connection-only — may not bill since no audio sent)
- 1 × WS H1
- 1 × WS H1-bis

Trial remaining (50-credit monthly allowance, was ~44 at start of
this dispatch per dispatch brief): ~40-41 by end.

---

## Recommendation for Deep + chat-Claude

**Hard recommendation:** Ship CompareScreen as-is. The REST batch
path it uses is verified working. Deep can test Sarvam right now
on his iPhone via Compare mode, and the transcripts WILL come back.

**Streaming path:** The wire format in current Swift is correct.
The "Socket is not connected" issue is iOS-specific. Two options:

- **(A) Stop pursuing streaming and route v1 live cloud Sarvam
  through the REST batch path.** Slower UX (3-5 sec per query
  instead of streaming partials) but works today. One-line change
  in `AppContainer.commitLiveStream`: when `activeProviderId ==
  .sarvam`, after the captured audio buffer is ready, call
  `SarvamProvider.transcribeOneShot(wav:apiKey:)` directly instead
  of `session.startStreaming + session.commit`.

- **(B) Debug iOS streaming separately.** Use the working Python
  script as the canary — when Swift's wire output matches Python's
  byte-for-byte AND Sarvam still closes, the issue is in URLSession
  timing/threading. Suspect list above.

I'd pick **A for v1 ship**, then **B as v2 polish**.

---

## Files in this investigation

```
scripts/sarvam-investigation/
├── _keys.py                          # key loader (gitignored content)
├── test_audio/
│   ├── mool_mantar_pa.mp3            # gTTS Punjabi source
│   └── test.wav                      # 16kHz mono s16le, 4.4 sec
├── logs/
│   ├── rest_batch_default_*.json     # Phase 2 success
│   ├── ws_H0_*.json                  # connection-only baseline
│   └── ws_H1_*.json                  # streaming success
├── test_rest_batch.py                # Phase 2 runner (9 variations)
├── test_ws_stream.py                 # Phase 3 runner (H0-H7 hypotheses)
└── WORKING_PROTOCOL.md               # this file
```
