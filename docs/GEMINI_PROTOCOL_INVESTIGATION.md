# Gemini 2.5 Flash audio transcription — investigation

_Overnight 2026-06-21/22, ahead of Deep's morning rebuild._

**Verdict.** GeminiProvider's request body uses **snake_case** field
names (`inline_data`, `mime_type`); Google's official REST API expects
**camelCase** (`inlineData`, `mimeType`). The API does NOT reject
snake_case with a 4xx — it **silently ignores** the malformed fields.
Net effect: Gemini sees `parts: [{text: prompt}]` (no audio at all)
and returns either an empty response or a generic "I don't know"
without ever reading the audio.

Status: **fixed-not-tested** — Deep has not actually confirmed Gemini
returns a transcript (his test session only [DIAG]'d Sarvam; the
Gemini button may have been tapped but no Gemini-specific logs are in
the report).

---

## Sources consulted

1. **Google official — audio understanding docs**
   https://ai.google.dev/gemini-api/docs/audio
   Verbatim example: `{"inlineData": {"mimeType": "audio/mp3", "data": "..."}}`
2. **Google official — generateContent reference**
   https://ai.google.dev/api/generate-content
3. **LangChain4j issue #3559 — snake_case silently ignored**
   https://github.com/langchain4j/langchain4j/issues/3559
   Quote: _"the Google API silently ignores these important
   configuration settings"_ when the request uses snake_case keys.
4. **Vertex AI generateContent reference**
   https://docs.cloud.google.com/vertex-ai/generative-ai/docs/model-reference/inference

---

## The Gemini contract (definitive, cited)

### 1. URL

```
https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=<API_KEY>
```

Our current `defaultEndpointBase` is correct. Auth via `?key=` query
param works; the alternative `x-goog-api-key` header also works but
we don't need to switch.

### 2. Method

```
POST
Content-Type: application/json
```

(Already correct.)

### 3. Request body — camelCase REQUIRED

Per Google's official audio doc, verbatim:

```json
{
  "inlineData": {
    "mimeType": "audio/mp3",
    "data": "base64AudioFile"
  }
}
```

Full request for a transcription:

```json
{
  "contents": [{
    "role": "user",
    "parts": [
      {"text": "<prompt>"},
      {
        "inlineData": {
          "mimeType": "audio/wav",
          "data": "<base64>"
        }
      }
    ]
  }],
  "generationConfig": {
    "temperature": 0,
    "candidateCount": 1
  }
}
```

### 4. Supported audio MIME types

- `audio/wav` ← we use this
- `audio/mp3`
- `audio/aiff`
- `audio/aac`
- `audio/ogg`
- `audio/flac`

(Per https://ai.google.dev/gemini-api/docs/audio.)

### 5. Response

```json
{
  "candidates": [{
    "content": {
      "parts": [{
        "text": "<response>"
      }]
    }
  }]
}
```

`CloudParsing.extractGeminiText` already parses this correctly.
No change needed.

---

## Current `GeminiProvider.swift` vs reality — numbered deltas

State as of commit `d22cd6b`:

| # | Current code does | Gemini expects | Fix |
|---|---|---|---|
| 1 | `"inline_data":` (snake_case) | `"inlineData":` (camelCase) | Rename in `transcribeChunk` + `transcribeOneShot` request bodies |
| 2 | `"mime_type":` (snake_case) | `"mimeType":` (camelCase) | Rename in same two functions |
| 3 | (correct) `generationConfig`, `candidateCount`, `temperature` | (correct, camelCase) | No change |
| 4 | (correct) URL + `?key=...` | (correct) | No change |
| 5 | (correct) `Content-Type: application/json` | (correct) | No change |
| 6 | (correct) Response parsing via `candidates[0].content.parts[].text` | (correct) | No change |

### Why doesn't Gemini return a 400 for snake_case?

Google's REST gateway accepts arbitrary unknown fields in the JSON
body and routes the known fields to the gRPC service behind it. The
service treats `inline_data` as an unknown field and drops it (no
schema-validation error), then proceeds to call the model with
`parts: [{text: prompt}]` — no audio at all.

The model then either:
- Returns "I don't know" / a generic refusal (since the prompt
  references audio it cannot see), OR
- Hallucinates a "transcript" based on the prompt alone (in our case
  the prompt mentions "Punjabi Gurbani recitation", so it may emit
  some generic Gurbani-looking string).

This explains why no `400` ever surfaces in [DIAG] logs but the
transcript is junk / empty. The LangChain4j issue confirms the silent-
drop behavior for `generationConfig` fields; same mechanism applies to
`contents.parts.inline_data`.

---

## Was Gemini actually tested on 2026-06-21?

Deep's [DIAG] logs (per dispatch) show only `SarvamProvider` lines.
Either:

- (a) Deep never selected Gemini in Settings → only Sarvam was tried.
- (b) Deep selected Gemini, the request fired, and Gemini silently
  returned an empty/generic response — no `[DIAG] GeminiProvider`
  lines because we only log at chunk-send time (line 270/276 of
  GeminiProvider.swift), and the early failure paths log too.

We can't tell from the dispatch summary. The fix below is
forward-compatible: either Deep tries Gemini for the first time after
the morning rebuild, or it actually starts working where it was
silently failing before.

---

## What the fix looks like in code

Touches only `GeminiProvider.swift`, two functions:

1. `transcribeChunk(pcm:energy:isSpeaking:)` — the streaming path. The
   `inline_data` / `mime_type` keys in the request body dictionary
   become `inlineData` / `mimeType`.

2. `transcribeOneShot(wav:apiKey:endpointBase:prompt:urlSession:)` —
   the static helper used by CompareScreen. Same two key renames.

Does NOT touch:
- `CloudMicCapture` (the s16le PCM bytes are correct; only the JSON
  wrapper field names are wrong).
- Response parsing — already correct.
- Auth method — already correct.
- Endpoint URL — already correct.

---

## Confidence the morning rebuild will work

**Medium.** The field-name fix is well-cited and the silent-drop
mechanism is plausible. But unlike Sarvam (where I can point to AVR's
working production code as a guaranteed-correct reference), I can't
point to a working iOS Gemini audio integration that's run against
Punjabi recitation. The fix is necessary but not provably sufficient.

If after the rebuild Gemini still returns garbage or refuses to
transcribe Punjabi (Gemini may have safety policies around
non-English audio it doesn't understand well, or it may refuse
religious content), the fallback is:
- Test with English audio first to isolate "is the audio reaching
  Gemini at all" vs "Gemini doesn't transcribe Punjabi well".
- Tighten the prompt: explicitly say "if you cannot transcribe,
  respond with the literal text DECLINE so we can detect it."
- Consider Gemini 2.5 Pro instead of Flash — slower + more expensive
  but better at non-English audio.

---

## Other potential issues (not addressed in this commit)

These are pre-existing and shouldn't block morning testing, but
worth noting for future passes:

1. **Chunk size = 2 sec.** Gemini Flash latency is 2-4 sec/chunk per
   the dispatch. With our 2-sec chunks, the system is always one
   chunk behind. UX-wise this means the live transcript trails real
   speech by 4-6 sec. Not great for "search-as-you-speak" UX but
   acceptable for v2 A/B testing.

2. **Per-chunk model invocation cost.** Each 2-sec chunk = one full
   Gemini API call. A 10-sec recording = 5 API calls. CloudTrialPolicy
   consumes 1 credit per commit — but the API charges per call. If
   Deep burns through Gemini quota faster than expected, that's why.

3. **No retry on rate limit / 429.** If Gemini rate-limits, the chunk
   silently drops. Not blocking; a retry-with-backoff hook is a
   v2 polish item.

4. **`generationConfig.candidateCount: 1`** is the default. Could be
   removed to shrink the request body. Cosmetic.
