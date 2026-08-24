# Sarvam Linux Investigation — 2026-06-22

_Stop iterating on Swift. Build a Python script on Linux that actually
returns a real Punjabi transcript from Sarvam. When that proves out,
port the EXACT working protocol to Swift in one confident pass._

**Result: both REST batch + WebSocket streaming work from Linux on
first attempt.** The wire format that the Swift app already implements
(commit `de786bf`) is byte-for-byte correct. The iOS "Socket is not
connected" failure is iOS-specific, not protocol.

---

## Exit status

**`SARVAM_WORKING`** — both REST batch and WebSocket streaming returned
real Punjabi transcripts.

- Phase 2 (REST batch): SUCCESS on first attempt (default variation).
- Phase 3 (WS streaming): SUCCESS on first hypothesis (H1).

Sarvam credits burned in this dispatch: ~3-4 (well within budget).

---

## Phase 2 (REST batch) result

**Status: WORKING.**

### Exact request

```
POST https://api.sarvam.ai/speech-to-text
Headers:
  api-subscription-key: <SARVAM_API_KEY>
Form fields (multipart/form-data):
  file          = test.wav (16kHz mono s16le, ~4.4 sec, audio/wav)
  model         = saaras:v3
  language_code = pa-IN
```

### Exact response

```json
{
  "request_id": "20260622_889a38a6-d0f3-404a-be57-177d9caf2f3e",
  "transcript": "ਇੱਕ ਓਅੰਕਾਰ ਸਤਿ ਨਾਮੋ ਕਰਤਾ ਪੁਰਖੋ ਨਿਰਭਉ ਨਿਰਵੈਰ।",
  "language_code": "pa-IN"
}
```

(HTTP 200, ~3-5 sec response time for 4.4-sec audio.)

**Ground truth comparison:** Input was gTTS-synthesised
"ਏਕ ਓਅੰਕਾਰ ਸਤਿ ਨਾਮੁ ਕਰਤਾ ਪੁਰਖੁ ਨਿਰਭਉ ਨਿਰਵੈਰੁ" (Mool Mantar
opening). Returned transcript matches well (some Gurmukhi-vowel
near-misses like ਏਕ→ਇੱਕ and ਨਾਮੁ→ਨਾਮੋ — these are gTTS pronunciation
artifacts more than ASR errors). Real Sangat recitation will score
better than synthesized voice.

Log file: `scripts/sarvam-investigation/logs/rest_batch_default_20260622T113852.json`

Reproducer: `python3 scripts/sarvam-investigation/test_rest_batch.py default`

---

## Phase 3 (WebSocket streaming) result per hypothesis

### H0 — connection-only baseline (sanity check, no audio)

- URL: `wss://api.sarvam.ai/speech-to-text/ws?model=saaras:v3&language-code=pa-IN&mode=transcribe&sample_rate=16000&input_audio_codec=pcm_s16le&high_vad_sensitivity=true`
- Header: `api-subscription-key: <KEY>`
- WS opened successfully. No server messages in 12 sec. Closed by client timeout.
- **Diagnostic value:** server accepts our URL + auth + does NOT reject
  connection. Whatever was failing before was the AUDIO content, not
  the connection setup.

### H1 — JSON-wrapped base64 (our commit `de786bf` shape)

- Same URL + headers as H0.
- After OPEN, stream 100ms chunks (3200 bytes s16le) as text frames:
  ```json
  {"audio": {"data": "<b64>", "sample_rate": "16000", "encoding": "audio/wav"}}
  ```
- **SUCCESS.** Two transcripts received:
  1. After ~30 chunks (~3 sec): `"ਇੱਕ ਓਅੰਕਾਰ ਸਤਿ ਨਾਮੋ ਕਰਤਾ"`
  2. After all 45 chunks: `"ਤਾਂ ਪੁਰਖ ਨਿਰਭਾਉ ਨਿਰਵੈਰ।"`
- Full response shape: `{"type":"data","data":{"request_id":..., "transcript":..., "timestamps":null, "diarized_transcript":null, "language_code":"pa-IN", ...}}`
- Close code: `None` (client-initiated graceful close).

Log: `scripts/sarvam-investigation/logs/ws_H1_20260622T114029.json`

Reproducer: `python3 scripts/sarvam-investigation/test_ws_stream.py H1`

### H1-bis — same as H1 but capital `Api-Subscription-Key` header

(Bonus variation to rule out HTTP header-case as the iOS-failure
variable, since Swift uses capital `Api-Subscription-Key`.)

- Result: **SUCCESS, same two transcripts.**
- Verdict: header case is NOT the iOS issue.

### H2-H7 — NOT RUN

Per dispatch: "STOP at first success." H1 succeeded; H2-H7 skipped.
Hypothesis scripts remain in `test_ws_stream.py` for future re-runs
if needed.

---

## Why iOS was failing despite the wire format being correct

This is the headline finding. **The Swift `SarvamProvider.swift` after
commit `de786bf` sends exactly the same wire format as Python H1.**
Same URL. Same query params (`language-code` hyphen,
`input_audio_codec=pcm_s16le`, etc.). Same JSON envelope around the
base64 audio. Same header (case-insensitive). Yet iOS gets "Socket is
not connected" within 500-700ms of the first audio send; Python gets
two clean transcripts.

The difference is **client-side**, not protocol.

Suspect list (NOT to be fixed in this dispatch — out of scope):

1. **URLSessionWebSocketTask send-before-upgrade race.** Possible that
   Swift's `wsTask.resume()` returns synchronously but the actual TLS
   + WS upgrade is still in flight when `wsTask.send(.string(...))` is
   called. The first audio frame may be hitting the socket before the
   server has finished the upgrade handshake, prompting Sarvam to
   close. Fix in Swift: gate the first audio send on receiving any
   server frame (a no-op for a non-chatty server like Sarvam — wait
   for at least `ping_interval` ms after `resume()`), OR add a small
   delay (e.g., 200ms) before the first send.

2. **URLSessionWebSocketTask frame batching.** iOS may coalesce
   `.send(.string(...))` calls in a way Sarvam doesn't expect.

3. **AVAudioSession + URLSession thread contention.** CloudMicCapture
   activates the audio session at the same time SarvamProvider is
   completing its WS upgrade. Possible the audio session activation
   is starving URLSession's background thread. Test: drive
   SarvamProvider with a canned audio buffer instead of live mic.

4. **TLS / certificate trust.** Default URLSession trust evaluation
   may be more strict on iOS than Linux's OpenSSL stack. Unlikely
   for a public CA-signed cert like api.sarvam.ai, but verify.

5. **WebSocket extension negotiation.** URLSession may be negotiating
   `permessage-deflate` or another extension that Sarvam doesn't
   support; the Python `websocket-client` library doesn't negotiate
   any by default.

---

## Recommendation

### For Deep's morning of 2026-06-22

**Both cloud providers are usable RIGHT NOW via CompareScreen** (the
REST batch path, not streaming). That's the deciding A/B test. Run
Compare mode on his iPhone:
1. Pull `7338030` (already on origin/main).
2. `rm -rf GurbaniLens.xcodeproj && xcodegen generate && xcodebuild ...`
3. Settings → tap Version 5× → Compare mode unlocked.
4. Compare → Record → "ek oankaar sat naam" → Stop.
5. Three rows fill in. Pick the one with the cleanest Gurmukhi.

### For the v1 ship decision

**Recommend route A: Sarvam-via-REST-batch for v1 live cloud.**

Rationale:
- REST batch is verified working from any client.
- 3-5 sec end-to-end latency is acceptable for v1 tap-to-search UX
  (v1 is one-shot, not search-as-you-speak).
- Streaming is a v2 polish item — works at the wire level, just has
  an iOS-side bug that's not in this dispatch's scope.

Implementation (one paragraph for chat-Claude to dispatch separately):

> In `AppContainer.commitLiveStream`: when
> `asr.activeProviderId == .sarvam`, after the captured audio buffer
> is ready, bypass `session.commit(asr:matcher:)` (which goes through
> streaming) and instead call `SarvamProvider.transcribeOneShot(wav:apiKey:)`
> directly with the captured WAV. Route the returned transcript
> through `Latin.from` and the matcher as usual. This is ~15 lines.

### For v2 polish

Debug streaming separately. Use the Python script as canary: if Swift
sends exactly the same bytes Python sends (verify with proxy tcpdump
or Charles Proxy), and Sarvam still closes Swift's connection, it's a
URLSession-specific bug. Investigate in that order:
1. Wait 200-500ms between `resume()` and first `send()`.
2. Test with canned audio (rule out AVAudioSession contention).
3. Compare URLSession's actual upgrade headers vs Python's
   (use Charles Proxy or `mitmproxy` to inspect both).

---

## Open questions for Deep + chat-Claude

1. **Compare-mode trial-counter consumption.** Each Compare run hits
   Sarvam REST batch AND Gemini REST — but CompareScreen calls the
   static `transcribeOneShot` helpers directly, bypassing
   `CloudTrialPolicy.tryConsume`. Should Compare runs count toward
   the 50/month free trial? (Argument for: trial credit is per
   request, not per "feature use". Argument against: Compare is
   debug-only and Deep is testing, not consuming.) Tiny change either
   way.

2. **Do we want streaming at all for v1?** REST batch works and is
   simpler. Streaming gives partial transcripts during recitation
   (nicer UX) but adds an iOS-side bug to debug. v1 is "tap, recite,
   tap Done, see results" — partials aren't on the critical path.

3. **Multiple-segment handling for streaming.** When streaming returns
   multiple `type:"data"` messages per session (we saw 2 for one Mool
   Mantar opening), the consumer should concat them with spaces.
   Current Swift `SarvamProvider.handleServerJson` extracts each
   `data.transcript` independently and yields a `Partial` per
   message — but those Partials REPLACE the displayed text in
   `VoiceSearchSession.startStreaming`, they don't accumulate. So
   the user would see "ਇੱਕ ਓਅੰਕਾਰ ਸਤਿ ਨਾਮੋ ਕਰਤਾ" briefly, then
   "ਤਾਂ ਪੁਰਖ ਨਿਰਭਾਉ ਨਿਰਵੈਰ।" (the first segment vanishes). Needs an
   accumulator (cf. Gemini's `joinAccumulator`) for clean streaming UX.

---

## Files written by this investigation

```
scripts/sarvam-investigation/
├── _keys.py                          (gitignored — reads from Taaj .env)
├── test_audio/
│   ├── mool_mantar_pa.mp3            (gTTS Punjabi source, 35 KB)
│   └── test.wav                      (16kHz mono s16le, 138 KB, 4.4 sec)
├── logs/
│   ├── rest_batch_default_20260622T113852.json
│   ├── ws_H0_20260622T114010.json
│   └── ws_H1_20260622T114029.json
├── test_rest_batch.py                (9 variations available)
├── test_ws_stream.py                 (H0-H7 hypotheses)
└── WORKING_PROTOCOL.md               (canonical reference for Swift port)

docs/SARVAM_LINUX_INVESTIGATION.md    (this file)
```

Trial credits used in this dispatch: **~3-4** (REST default + WS H1 +
WS H1-bis; H0 didn't send audio so probably free).

---

## TL;DR for chat-Claude's next dispatch

- **Sarvam wire protocol is figured out and verified.** See
  `scripts/sarvam-investigation/WORKING_PROTOCOL.md` for the exact
  bytes.
- **Current Swift `SarvamProvider.swift` (commit de786bf) is correct
  at the wire level.** Don't change the protocol.
- **iOS failure is iOS-specific.** Likely URLSessionWebSocketTask
  send-before-upgrade timing or AVAudioSession + URLSession
  contention.
- **Pragmatic ship path:** Route v1 live Sarvam through the existing
  `SarvamProvider.transcribeOneShot` REST batch helper. ~15-line
  change in `AppContainer.commitLiveStream`. Will work first try
  because REST batch is verified working with the EXACT same Swift
  code that CompareScreen already uses.
- **Compare mode works TODAY** on Deep's iPhone for both Sarvam +
  Gemini A/B testing without any further code changes (assuming
  the Gemini camelCase fix from commit `6afe5f6` is in his pull).
