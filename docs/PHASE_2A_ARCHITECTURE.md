# Phase 2A Architecture — Paath / Bani Recitation Companion

_Drafted 2026-05-12. **Status: architecture LOCKED 2026-05-12. Sign-offs and amendments below.**_

| Decision | Status | Amendment |
|---|---|---|
| §3 Core engine | ✅ approved | Python = canonical source of truth; `tests/portparity/` JSON validates all ports |
| §5 ASR strategy | ✅ approved | Default model = `small` / `base` (~200 MB), not `medium`. Server privacy contract documented inline. |
| §2 Repo layout | ✅ approved | Phase 1 Python moves to `core/` |
| §4 Corpus bundle | ✅ amended | Trim to ~100 MB; curated translations only; additional translations server-downloadable |
| §14 Implementation order | ✅ amended | Anvaad-js / Unicode rendering moves **before** first end-to-end Bani checkpoint |
| Flag A Akhand Paath line-in | ✅ approved | `AudioSource` abstraction with `MicSource` (Phase 2A) + `LineInSource` (Phase 2C); architect for it now |
| Flag B Tracks B + C | ✅ spun up | `scripts/fetch_samples.py` + `scripts/aeneas_spike.py`; aeneas write-up at `docs/aeneas_spike.md` |
| Flag C Whisper non-determinism | ✅ deferred | tuning task in §15: `temperature=0, no fallback, fixed seed where supported` |
| Addition 1 | ✅ added | Opt-in feedback channel (§17) — capture from launch |
| Addition 2 | ✅ added | Accessibility (§18) — core feature, not bolt-on |

---

## 1. Scope and modes

| Mode | What it does | Search space | Difficulty |
|---|---|---|---|
| **Nitnem Banis** | Japji, Jaap, Tav-Prasad Savaiye, Chaupai, Anand, Rehras, Kirtan Sohila | Known Bani — hundreds of Pangtis | Easy (constrained search) |
| **Sukhmani Sahib** | 24 Ashtpadis × 8 Pauris ≈ 192 Pangtis | Known Bani | Easy |
| **Asa Ki Vaar** | 24 Pauris with embedded Shabads + Sloks | Known Bani | Easy-Medium (mixed Salok / Shabad / Pauri pattern) |
| **Sehaj Paath** | Reader anywhere in SGGS, app finds them and follows | Full SGGS (~60K lines) | Hard (full corpus search + sequential bias) |
| **Akhand Paath** | Continuous 48-hour recitation, multi-Pathi rotation | Full SGGS sequentially | Hardest (long session, voice handoff, gap tolerance) |

Out of scope for Phase 2A:
- Sevadaar override controls (Phase 2C, projector)
- Multi-Pathi voice profile recognition (Phase 2C+)
- Translations beyond English/Punjabi (later)
- Audio-only mode without UI (future)

---

## 2. Repository structure ✅

Monorepo. Phase 1 Python becomes `core/` — emphasising its role as **canonical reference + evaluation harness**, not a runtime dependency.

```
gurbanilens/
├── CLAUDE.md
├── PHASE_1_CONCLUSION.md
├── docs/
│   ├── PHASE_2A_ARCHITECTURE.md            (this file)
│   └── aeneas_spike.md                     (Track C writeup)
├── core/                                   (RENAMED from src/gurbanilens/)
│   ├── pyproject.toml
│   ├── gurbanilens/                        (Phase 1 Python — canonical reference impl)
│   │   ├── corpus.py
│   │   ├── matcher.py
│   │   ├── asr.py
│   │   └── cli.py
│   └── tests/
│       ├── test_corpus.py
│       ├── test_matcher.py
│       └── portparity/
│           ├── test_vectors.json           (11-case JSON; ports validate against this)
│           └── README.md                   (port-parity contract)
├── samples/
├── data/sggs/                              (raw shabados/database v4.8.7)
├── evaluation/                             (Phase 1 reports)
├── scripts/
│   ├── fetch_corpus.py                     (Phase 1)
│   ├── evaluate.py                         (Phase 1)
│   ├── fetch_samples.py                    (Phase 2B — track B)
│   └── aeneas_spike.py                     (Phase 2B — track C)
├── build/                                  (corpus pre-processing pipeline)
│   ├── convert_anmol_to_unicode.js         (Node.js + anvaad-js)
│   ├── build_app_database.py               (trims to ~100MB, produces app SQLite)
│   └── package.json                        (Node deps: anvaad-js, better-sqlite3)
├── ios/                                    (Xcode project; created when we start step 3)
│   └── GurbaniLensCore/                    (Swift Package — testable without Xcode)
│       ├── Package.swift
│       └── Sources/
│           ├── GurbaniLensCore/            (Swift matcher + corpus loader)
│           └── GurbaniLensCoreTests/       (port-parity runner)
├── android/                                (placeholder — populated when iOS is buildable)
└── server/                                 (placeholder — only if server-fallback ASR ships)
```

Rationale for monorepo over separate repos:
- 1-person team (Deep + Claude); coordination over isolation
- Shared corpus artifact (`build/app_database.sqlite`) goes into both iOS and Android bundles — easier as siblings than as a 3rd cross-repo
- Phase 1 evaluation harness needs to stay accessible — porting matcher to Swift, the Python ref impl is right there for diff/regression

Push back if you'd rather isolate the iOS Xcode project in its own repo. Real reason to do that: if you ever want to open-source the iOS app alone without the dataset gathering work.

---

## 3. Core engine language ✅

Options I considered:

| Option | iOS path | Android path | Maintenance | First-prototype risk |
|---|---|---|---|---|
| **A. Swift core, Kotlin port** | Native Swift in `ios/Core/` | Native Kotlin in `android/Core/` | 2 implementations, ~150 LOC each | Lowest — pure Swift |
| **B. Rust core + UniFFI** | Rust lib compiled to `.framework`, Swift bindings | Same Rust lib, Kotlin bindings via JNI | 1 implementation; build infra non-trivial | Medium — UniFFI is real but not familiar territory |
| **C. C++ core + Swift/JNI** | C++ in `ios/Core/`, Swift wrappers | Same C++ via JNI | 1 implementation; FFI ergonomics worse than Rust | Medium-high — manual FFI |
| **D. Kotlin Multiplatform** | Kotlin compiled to Apple via KMM | Native Kotlin | 1 implementation; KMM iOS toolchain still maturing | Medium — newer, smaller community |

**Recommendation: A (Swift + Kotlin re-implementation).**

Reasoning:
- Matcher is ~150 LOC of clean algorithm. Both ports are a half-day each. Maintenance cost of 2 implementations is tiny vs build-infra cost of Rust/UniFFI.
- Pure Swift / pure Kotlin means **no FFI debugging, no toolchain headaches on iOS first build**. Important because you said "move fast on code generation."
- We keep the Python ref impl. Any divergence between Swift, Kotlin, and Python is caught by re-running the test battery in each language.
- The matcher is the only thing that benefits from "shared core". Corpus loader is just SQLite-over-driver — trivial in both languages. ASR is whisper.cpp — already C++ shared via the same library. Audio capture is platform-specific anyway.

**When this recommendation would be wrong:** if Phase 2C projector + a future desktop app both want to reuse the matcher in a third language (Python/Rust desktop, or web/WASM), then a Rust core pays back. But that's Phase 3+ territory — premature now.

**Push back here especially if you want Rust early** — happy to switch direction. But my honest read is the matcher is so simple that "shared core" is a discipline issue, not a code issue: write 3 implementations against 1 spec (the test battery) and they stay in sync.

### Port-parity discipline (amendment)

Python (`core/`) is the canonical reference. Swift (`ios/GurbaniLensCore/`) and Kotlin ports must produce **identical** results.

The contract: `core/tests/portparity/test_vectors.json` — 11 test cases (the same battery from Phase 1's `test_matcher.py`) encoded as JSON. Every port has a runner that loads this file and asserts:

- Top match's `ang` and `pangti` match the expected values
- Final score ≥ `expected_score_at_least`
- Coverage ≥ `expected_coverage_at_least`

CI runs all three port runners on every PR touching matcher code. Any drift = port bug, blocked from merging.

Threshold constants (also in JSON, shared across ports):
```json
{
  "TOKEN_MATCH_THRESHOLD": 55.0,
  "LONG_TOKEN_MIN": 3,
  "MIN_LONG_TOKENS_FOR_FULL_CONFIDENCE": 4,
  "CANDIDATE_POOL": 50,
  "MATCH_THRESHOLD": 75.0
}
```

---

## 4. SGGS corpus pipeline ✅

### Build-time conversion (one-time per release)

```
data/sggs/database.sqlite           (shabados/database v4.8.7 raw — Anmol Lipi)
            ↓
build/convert_anmol_to_unicode.js   (Node.js, requires anvaad-js)
            ↓
build/app_database.sqlite           (augmented — adds gurmukhi_unicode column)
            ↓
ios/GurbaniLens/Resources/corpus.sqlite       (bundled)
android/app/src/main/assets/corpus.sqlite     (bundled)
```

**`build/convert_anmol_to_unicode.js`** reads every `lines.gurmukhi` cell, converts via anvaad-js, writes a new `gurmukhi_unicode` column. Idempotent — re-runnable on schema bumps. Output committed to repo (the app database is the deliverable artifact). Anvaad-js stays a build-tool dependency only — no runtime JS bridge needed.

### Bani indexing

`shabados/database` has a `banis` table that lists which lines belong to each Nitnem Bani. We'll use it directly. Sample: `bani_lines` table has `(line_id, bani_id, line_group)` — exactly what we need to constrain the Nitnem matcher search space.

For Banis the table doesn't cover (e.g., specific Asa Ki Vaar pauri groupings if needed), we add them in `build/` as supplementary tables.

### Corpus size on device — trim to ~100 MB

Bundle the **curated** corpus:
- ✅ Anmol Lipi Gurmukhi (`lines.gurmukhi`)
- ✅ Unicode Gurmukhi (`lines.gurmukhi_unicode` — built via anvaad-js)
- ✅ English transliteration (`transliterations.transliteration` where `language=English`)
- ✅ One English translation — **Bhai Manmohan Singh** by default (traditional voice; can be switched to Sant Singh Khalsa in settings)
- ✅ One Punjabi Teeka — **Prof. Sahib Singh** (the canonical Sikh exegesis)

Drop from default bundle (server-downloadable on demand via "Download additional translations" in Settings):
- Spanish, French, German translations
- Urdu transliteration
- Hindi transliteration (Devanagari)
- Additional English translations (multiple Khalsa variants, etc.)
- Additional Punjabi teekas (Fareedkot Teeka, etc.)
- `pronunciation_information` (the lengthy commentary column — saves several MB)

Build target: ≤ 100 MB. Anything additional is fetched per-user via the server endpoint into the app's documents directory.

---

## 5. ASR strategy ✅

### Recommended pipeline

```
iOS device → check capability tier:
   • Apple Neural Engine present (A12+, ≈ 2018 iPhone XS and newer)  → on-device whisper.cpp + CoreML
   • Older device                                                     → server fallback (opt-in, with privacy disclosure)
```

Most users will hit on-device. Server is a safety net, not the default.

### On-device choice

**whisper.cpp** with CoreML-converted model weights:
- whisper.cpp is the de-facto C++ implementation; SwiftPM-installable
- CoreML conversion offloads the encoder to the Apple Neural Engine — 3-5× speedup on supported devices
- Model size choices (4-bit quantized):
  - `ggml-base` (~150 MB) — fast, lower quality but **sufficient for spoken Paath**
  - `ggml-small` (~250 MB quantized) — slightly better than base
  - `ggml-medium` (~500 MB quantized) — Phase 1 baseline; clear quality bump
  - `ggml-large-v3` (~1.5 GB quantized) — best quality; sizeable bundle hit

**Default = `small` (~250 MB).** Settings UI offers upgrade to `medium` or `large-v3` with battery + storage warnings.

Rationale: most Paath users don't need medium-tier quality. Phase 1's `japji sahib 1.mp3` scored 96.6 on `large-v3`; even `small` will likely cover spoken Paath well. Bundle-size pressure (App Store / first-download impact) wins over marginal accuracy. Power users upgrade.

### Server fallback — privacy contract

A single Hetzner box (DE jurisdiction, ~$25/mo, 4 vCPUs, 16 GB) running:
- FastAPI HTTP endpoint, source-available (this repo's `server/`)
- Receives raw 16kHz mono PCM chunks over WebSocket
- Runs `faster-whisper large-v3`
- Streams back Latin-normalised transcript

**Privacy contract — committed in writing, surfaced in-app, enforced in code:**

1. **No audio storage.** PCM chunks held only in process memory during transcription; dropped immediately after the WebSocket closes. No disk writes, no temp files, no log records of audio content.
2. **No content logging.** Server logs include: timestamp, request duration, error codes. They explicitly **do not include**: transcript text, audio bytes, IP addresses (stripped at the reverse proxy), user agents, device fingerprints.
3. **No user identifier.** Authentication is a per-session ephemeral token generated by the app at the start of each listening session. The token is opaque, not tied to any user account, and expires when the session ends. No persistent user ID exists server-side.
4. **DE jurisdiction.** Hetzner data centre in Germany. GDPR-aligned defaults. No US Cloud Act exposure.
5. **Source-available server code.** The `server/` directory ships under the same OSS licence as the rest of the project. Anyone can audit that the policy above is what the code does.
6. **Opt-in per session, not per install.** Each listening session that needs server fallback prompts: "Use server-based recognition for this session? Audio will be processed in Germany and immediately discarded. [Just for now] [Always allow] [Never use server]". "Just for now" is the default. The "Always allow" path requires a more explicit consent screen.
7. **In-app consent flow** before any audio leaves the device. UI shows the policy above in plain language plus a link to the full privacy policy.
8. **Always reversible.** "Never use server" in settings is honoured immediately and persistently.

The server fallback is a **last-resort** — older devices with no Neural Engine, or low-storage devices that can't download even the `small` model. The 90%+ case is fully on-device.

### Streaming chunking strategy

- Capture mic at 16 kHz mono → ring buffer
- Send 5-second sliding chunks (1s overlap) to ASR every 1 second
- Latest ASR result feeds the matcher; matcher updates UI position
- Total UI latency target: ~2 seconds (matches Phase 1's "1-3 seconds acceptable" for Use Case 1)

---

## 6. iOS audio capture

### AudioSource abstraction (Flag A) — architect now, ship MicSource only

```swift
protocol AudioSource {
    /// Begin streaming 16 kHz mono Float32 buffers via the callback.
    func start(_ onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws
    func stop()
    var isRunning: Bool { get }
    var configurationDescription: String { get }   // for UI / telemetry
}

final class MicSource: AudioSource { /* Phase 2A — AVAudioEngine impl */ }

// Stub — Phase 2C (Gurdwara projector / line-in from mixer console)
final class LineInSource: AudioSource {
    init() { fatalError("LineInSource not yet implemented — Phase 2C") }
}
```

30-min design tax during Phase 2A; Phase 2C drops in `LineInSource` (uses `AVCaptureDevice` USB-audio routing or AudioUnit HAL) without touching anything downstream.

### AVAudioEngine config

```swift
let engine = AVAudioEngine()
let inputNode = engine.inputNode
let nativeFormat = inputNode.outputFormat(forBus: 0)
let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                  sampleRate: 16000, channels: 1,
                                  interleaved: false)!
// Install tap on input node, resample to 16kHz mono via AVAudioConverter,
// emit 1024-sample buffers to the ASR ring buffer.
```

### AVAudioSession category

```swift
try AVAudioSession.sharedInstance().setCategory(
    .playAndRecord,
    mode: .measurement,
    options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers]
)
```

`.mixWithOthers` is critical — Sangat may have YouTube/SikhiToTheMax audio playing alongside; our app shouldn't kill it.

### Background mode

Info.plist:
```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

This + an active `.playAndRecord` session keeps the mic running with screen off / app backgrounded.

### Battery / thermal

Continuous mic + ASR on Neural Engine is moderate drain (~10-15% per hour on iPhone 15 Pro per my expectation; needs measurement). For Akhand Paath (48 hours) we'll surface a clear "plug in your device" prompt.

---

## 7. Android equivalents (preview — full doc when iOS is buildable)

- Audio: `AudioRecord` API with 16 kHz mono config
- Background: `ForegroundService` with `FOREGROUND_SERVICE_MICROPHONE` permission (API 28+), persistent notification while recording
- ASR: whisper.cpp via JNI; same CoreML-equivalent acceleration via NNAPI / GPU delegate where available
- UI: Jetpack Compose, MVVM same as iOS

---

## 8. Matcher port (Swift)

The Phase 1 matcher is ~150 LOC of pure algorithm. Direct Swift port:

```swift
struct Match { let line: Line; let score: Double; let coverage: Double }

final class Matcher {
    private let lines: [Line]
    private let normalizedTexts: [String]
    private let tokens: [[String]]
    private let mode: Mode  // .bani(banId) or .sehaj or .akhand

    init(corpus: Corpus, mode: Mode) {
        // Build indices for either: a single Bani's lines, or all SGGS lines
        ...
    }

    func match(_ query: String, topN: Int = 5) -> [Match] {
        // Stage 1: partial-ratio recall (Swift port of rapidfuzz.partial_ratio
        //   or use Swift's built-in NSString rangeOfString fuzzy logic; benchmark)
        // Stage 2: token-coverage re-rank (port of _token_coverage)
        // Sequential-progression bias if state has recent locked match
        ...
    }
}
```

We'll need a Swift Levenshtein implementation or use a library like `swift-fuzzy-match`. Benchmark on 60K lines on iPhone target: should be well under 100ms per query.

**Sequential-progression bias (new for Phase 2A):**
- Maintain `lastConfidentLine: Line?` state
- When evaluating candidates, boost score for lines within ±N order_id of `lastConfidentLine`
- Decay boost if confidence drops
- Reset boost on mode change / explicit user "reset"

This handles Sehaj Paath naturally: lock on once, then track sequentially. Same logic works for Akhand Paath.

---

## 9. Sehaj Paath mode

The hard mode. Reader is at an unknown position in SGGS; app must find them and follow.

State machine:

```
SEARCHING ──(confident match)──→ LOCKED ──(low confidence streak)──→ DRIFTING
   ↑                                                                      │
   └──────────────(extended low-confidence streak)──────────────────────┘
```

- **SEARCHING:** full 60K-line scan, no sequential bias, look for confidence ≥ 75
- **LOCKED:** narrow search to lines within ±200 order_id of last confident match, sequential bias on. Most queries finish in <10ms.
- **DRIFTING:** widen search window to ±2000 order_id, lower threshold to 65, sequential bias on but with lower weight
- **Back to SEARCHING:** if confidence stays <50 for 30+ seconds

UI surfaces these states subtly: locked = solid scroll-following; drifting = momentarily paused with "?" indicator; searching = "Looking for your position…" overlay.

---

## 10. Akhand Paath mode

Continuous Sehaj Paath. Additional requirements:

- **48-hour session resilience:** save state periodically (current order_id + confidence) so a device restart resumes from approximately the right place
- **Pathi handoff tolerance:** when audio character changes (different voice), confidence will dip briefly. State machine moves to DRIFTING, holds position, recovers when new voice stabilises. Don't reset to SEARCHING on voice change alone.
- **Silence handling:** gap of 10-30 seconds (water break, prayer pause) — hold position, do nothing. Gap of 5+ minutes — surface "Are you still reading?" prompt.
- **Power management:** continuous mic burns battery. App should:
  - Show prominent "plug in device" reminder
  - On low battery (<20%) drop on-device ASR to lower-quality model OR surface warning
  - Save state to disk every 30 seconds in case of unexpected shutdown

Note: a 48-hour Akhand Paath in a real Gurdwara likely needs a line-in from the mixing console, not phone mic. That's a Phase 2C / projector concern, not Phase 2A. Phase 2A handles personal-listener Akhand Paath (user listening to a livestream / recording while app tracks).

---

## 11. UI architecture (SwiftUI, MVVM)

Three primary screens:

1. **Bani Picker** — list of Nitnem Banis, Sukhmani, AKV, Sehaj Paath, Akhand Paath modes. Tap to start.
2. **Follow View** — the heart of the app. Shows:
   - Current Pangti highlighted, surrounding Pangtis visible above/below for context
   - Auto-scrolls as matcher updates position
   - Toggleable layers: Gurmukhi (always), transliteration (Latin/Devanagari), translation (Punjabi/English)
   - Confidence indicator (subtle dot or colour) — green=locked, amber=drifting, grey=searching
   - Tap a Pangti to manually lock to it (user override; matcher uses it as ground truth for sequential bias)
3. **Settings** — model size, on-device vs server, language preferences, background-mode permission status, privacy disclosures

### Visual style

- Big Gurmukhi text (Gurbani Akhar font, or system Gurmukhi)
- High contrast, low chrome — meant to be read while reciting, not visually busy
- Dark mode by default for evening Rehras / morning Paath

---

## 12. Background + screen-off resilience

iOS-specific:
- Background audio entitlement (covered in §6)
- App must be configured to NOT idle-timeout the screen during active sessions (handled, not user-toggleable per session by default — surfaceable in settings)
- Lock-screen "Now Reciting" media-control widget showing current Bani (uses `MPNowPlayingInfoCenter`)
- Apple Watch companion (later — not Phase 2A scope but architect for it: matcher state should be syncable)

Edge cases handled:
- Incoming phone call → app pauses listening, resumes after call
- Other audio (YouTube, music) playing → `.mixWithOthers` lets it coexist
- Headphones unplugged → audio session interruption handler keeps listening on speaker
- Backgrounded for >30 minutes with no audio → save state and stop listening to preserve battery; resume requires user tap

---

## 13. Data flow

```
┌──────────────────────────────────────────────────────────────────────────┐
│                            iOS app process                                │
│                                                                          │
│  ┌────────────┐    ┌─────────────────┐    ┌────────────────────────┐    │
│  │ Bani Picker│───→│  Mode + corpus  │←───│ corpus.sqlite (bundled)│    │
│  │   (UI)     │    │  initialisation │    └────────────────────────┘    │
│  └────────────┘    └────────┬────────┘                                   │
│                              │                                            │
│                              ▼                                            │
│  ┌────────────┐    ┌─────────────────┐    ┌────────────────────────┐    │
│  │ Mic        │───→│  AVAudioEngine  │───→│   16kHz mono ring buf  │    │
│  │ (input)    │    │  (resample tap) │    └────────────┬───────────┘    │
│  └────────────┘    └─────────────────┘                 │                │
│                                                          │                │
│                              ┌───────────────────────────┘                │
│                              ▼                                            │
│  ┌──────────────────────────────────────────────────────┐                │
│  │  whisper.cpp + CoreML  (5s sliding chunks, 1s step)  │                │
│  │  → Unicode Gurmukhi/Devanagari per chunk             │                │
│  └────────────────────────────┬─────────────────────────┘                │
│                                │                                          │
│                                ▼                                          │
│  ┌──────────────────────────────────────────────────────┐                │
│  │  to_latin(): script-detect → IAST → ASCII Latin      │                │
│  │  (Swift port of Phase 1 to_latin)                    │                │
│  └────────────────────────────┬─────────────────────────┘                │
│                                │                                          │
│                                ▼                                          │
│  ┌──────────────────────────────────────────────────────┐                │
│  │  Matcher (Swift)                                     │                │
│  │  - Search space: Bani lines OR full SGGS             │                │
│  │  - Sequential bias from state machine                │                │
│  │  - Returns top-N (line, score, coverage)             │                │
│  └────────────────────────────┬─────────────────────────┘                │
│                                │                                          │
│                                ▼                                          │
│  ┌──────────────────────────────────────────────────────┐                │
│  │  Follow View                                         │                │
│  │  - Auto-scroll to top match line                     │                │
│  │  - Highlight, show transliteration + translation     │                │
│  │  - Confidence indicator                              │                │
│  └──────────────────────────────────────────────────────┘                │
└──────────────────────────────────────────────────────────────────────────┘

   On older devices, replace whisper.cpp block with WebSocket to server:
       audio buffer ───→ wss://server/asr ───→ Latin transcript
```

---

## 14. Implementation roadmap ✅ (Unicode rendering moved before first Bani checkpoint)

| Step | What | Stop and check in? |
|---|---|---|
| 1 | Repo restructure (`src/gurbanilens/` → `core/`), build pipeline (`build/convert_anmol_to_unicode.js` + `build_app_database.py`), port-parity test vectors JSON | No (mechanical) |
| 2 | Swift Package (`ios/GurbaniLensCore/`) — corpus loader + matcher port. Validates against `tests/portparity/test_vectors.json`. | No, but I'll show test pass rate |
| 3 | iOS Xcode project skeleton, `AudioSource`/`MicSource`, AVAudioEngine pipeline, whisper.cpp wired in | **Yes — checkpoint 1: try recording + transcribing, before UI work** |
| 4 | **Anvaad-js / Unicode Gurmukhi rendering pipeline** (moved up per amendment) — bundled font, conjunct + vishraam rendering test cases, dark-mode + large-text variants | No, but I'll show side-by-side rendering samples |
| 5 | Bani Picker + Follow View for one Nitnem Bani (Japji) end-to-end | **Yes — checkpoint 2: first buildable iOS prototype, you try it on your phone** |
| 6 | Remaining Nitnem Banis, Sukhmani, AKV | Incremental commits, no formal checkpoint |
| 7 | Sehaj Paath mode (full SGGS + state machine) | No (architectural; show telemetry) |
| 8 | Akhand Paath mode (long-session resilience, phone-mic case only — line-in is Phase 2C) | No |
| 9 | Settings, translations toggle, server-download flow for non-default translations, model upgrade flow | No |
| 10 | Opt-in feedback channel (§17) — wire from launch even if backend is stub | No |
| 11 | Accessibility pass (§18) — VoiceOver/TalkBack, large-text, haptics, high-contrast | No |
| 12 | Background mode polish, battery/thermal handling | No |
| 13 | App Store submission readiness | **Yes — checkpoint 3: before TestFlight / submission** |

Parallel work tracks (lower priority, scheduled when I'm waiting on user feedback):
- **Track B:** `scripts/fetch_samples.py` for Kirtan sample gathering (Phase 2B prep)
- **Track C:** aeneas forced-alignment spike (Phase 2B prep)

---

## 15. Open questions / known tuning tasks

- **iPhone Neural Engine performance on `small`/`medium`** — needs real measurement; if too slow at real-time, we drop a tier. Benchmark in step 3.
- **CoreML conversion of large-v3** — community tooling exists but is fiddly. Plan to ship `small` baseline and treat `medium`/`large-v3` as user-downloaded upgrades.
- **Akhand Paath voice handoff** — DRIFTING-state recovery is a guess until we test on a real recording with multiple Pathis. Phase 2B sample gathering should include one.
- **Server fallback consent UX** — opt-in is the answer; the framing of the consent screen needs careful copywriting (some users will reflexively decline anything that asks for audio permissions). Possibly worth UX testing with a small Sangat group.
- **Whisper non-determinism (Flag C, known tuning task)** — Phase 1 surfaced that the same audio produces different transcripts across runs. For projector reliability we need to set Whisper's `temperature=0`, disable temperature-fallback retries (`temperature_increment_on_fallback=null`), and use a fixed seed where the library supports it. faster-whisper exposes `temperature=[0.0]` to fix this; whisper.cpp has `params.temperature = 0.0f`. Apply during step 3 instrumentation.

---

## 16. Decision log

See the sign-off table at the top of this document. Architecture locked 2026-05-12; implementation begins step 1.

---

## 17. Opt-in feedback channel (Addition 1)

A "This isn't right" button on every matched Pangti in the Follow View. Captures (anonymous device ID, audio segment, our match, user's suggested correction) and POSTs to the server.

**Strictly opt-in.** First-launch onboarding includes a single, plain-language toggle: "Help improve GurbaniLens — share corrected matches when something looks wrong? Audio + correction goes to our research dataset under the same privacy contract as ASR fallback." Off by default; user must explicitly enable.

**What gets captured per correction:**
- Anonymous device ID (UUID generated on first launch, scoped to this app install, no link to Apple/Google ID)
- The 5-10 second audio segment that produced the wrong match (raw PCM, same privacy treatment as server-fallback audio)
- Our top match (Ang, Pangti, confidence, full window text)
- The user's correction — either a tap on the correct Pangti from the list, or "I don't know what this is"
- Mode context (Nitnem Bani name, or Sehaj/Akhand)
- App version, model size

**What does NOT get captured:**
- User identity in any form
- Location
- Device characteristics beyond OS major version
- Any session content other than the corrected window

**Server endpoint:** `POST /feedback/correction`. Stores in a queue (encrypted at rest), processed asynchronously into a labeled dataset for future matcher/ASR improvement. Source-available alongside the ASR fallback server.

**Visibility:** Settings → "View my submitted corrections" lists every submission this device has made. "Delete all my submissions" removes them from the server (we honour the request; per device, server-side, immediate).

**Why capture from launch:** even if Phase 3 is when we act on this data, we can't retro-generate user feedback. The cost of building the capture path now is low; the value of having year-one corrections when fine-tuning begins is high.

---

## 18. Accessibility (Addition 2)

This is a Seva app. Accessibility is a **core feature**, not a bolt-on. Phase 2A ships with all of these working, not as a follow-up release.

### Visual

- **Large-text mode:** Honour iOS Dynamic Type. Gurmukhi, transliteration, and translation all scale together with system text-size setting. Tested at the largest accessibility size (AccessibilityXXXLarge).
- **Pinch-to-zoom Gurmukhi:** in the Follow View, a pinch gesture independently scales the Gurmukhi text up to 4×. Layout reflows. Setting is per-Bani persisted.
- **High-contrast mode:** Honour "Increase Contrast" iOS setting. Custom palette with WCAG AAA contrast ratios. Dark mode default with optional light mode.
- **Reduced-motion mode:** Honour "Reduce Motion" — auto-scroll becomes instant snap instead of animated; confidence-indicator pulse becomes static colour change.

### Audio / motor / hearing

- **VoiceOver / TalkBack:** every matched Pangti is announced when locked. The user can swipe to step through Pangtis manually. Transliteration or English translation can be set as the spoken form (so blind Sangat following along by ear can have the current line spoken in their preferred language). Critically: VoiceOver focus follows the matched line automatically.
- **Haptic / vibration cues:** new-Pangti-match triggers a soft haptic. Hearing-impaired Sangat can follow without sound. Configurable intensity in settings.
- **Switch Control compatible:** all buttons reachable via Switch Control / external keyboard. No gesture-only interactions.

### Cognitive

- **Plain-language onboarding** — no jargon. Explain what the app does, what it doesn't, what data leaves the device.
- **Clear error states** — when the matcher loses the thread, the UI says so plainly: "I lost track of where you are. Tap the line you're on now." Never silent failure.

### Verification

Each Bani's Follow View ships with an automated accessibility test in `ios/GurbaniLensTests/AccessibilityTests.swift`: VoiceOver announcement order, contrast ratios, Dynamic Type scaling, haptic firing. Failures block release.
