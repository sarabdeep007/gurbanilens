# Phase 2A Architecture — Paath / Bani Recitation Companion

_Drafted 2026-05-12. Status: awaiting Deep's sign-off before iOS implementation begins._

This doc covers the engineering decisions for Phase 2A. **Decisions flagged ⚠️ are the ones Deep should explicitly approve, push back on, or amend before we lock them in.**

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

## 2. Repository structure ⚠️

**Recommendation: keep monorepo, add `ios/`, `android/`, `build/`, `server/` to the existing `gurbanilens/` repo.**

```
gurbanilens/
├── CLAUDE.md
├── PHASE_1_CONCLUSION.md
├── docs/
│   └── PHASE_2A_ARCHITECTURE.md            (this file)
├── src/gurbanilens/                        (Phase 1 Python — preserved as reference)
├── samples/
├── data/sggs/                              (raw shabados/database v4.8.7)
├── evaluation/                             (Phase 1 reports stay here)
├── scripts/
│   ├── fetch_corpus.py                     (Phase 1)
│   ├── evaluate.py                         (Phase 1)
│   ├── fetch_samples.py                    (Phase 2B — track B)
│   └── aeneas_spike.py                     (Phase 2B — track C)
├── build/                                  (NEW — corpus pre-processing pipeline)
│   ├── convert_anmol_to_unicode.js         (Node.js + anvaad-js)
│   └── build_app_database.py               (produces app-ready SQLite from data/sggs)
├── ios/                                    (NEW — Xcode project)
│   ├── GurbaniLens.xcodeproj
│   └── GurbaniLens/
│       ├── App/                            (SwiftUI entrypoint)
│       ├── Core/                           (matcher + corpus loader, Swift)
│       ├── ASR/                            (whisper.cpp wrapper)
│       ├── Audio/                          (AVAudioEngine pipeline)
│       └── UI/                             (Bani selection, follow view, settings)
├── android/                                (NEW — when iOS is buildable; later)
└── server/                                 (NEW — only if device-capability detection needs it)
```

Rationale for monorepo over separate repos:
- 1-person team (Deep + Claude); coordination over isolation
- Shared corpus artifact (`build/app_database.sqlite`) goes into both iOS and Android bundles — easier as siblings than as a 3rd cross-repo
- Phase 1 evaluation harness needs to stay accessible — porting matcher to Swift, the Python ref impl is right there for diff/regression

Push back if you'd rather isolate the iOS Xcode project in its own repo. Real reason to do that: if you ever want to open-source the iOS app alone without the dataset gathering work.

---

## 3. Core engine language ⚠️ (the big one)

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

---

## 4. SGGS corpus pipeline ⚠️

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

### Corpus size on device

Raw v4.8.7 SQLite is 151 MB. App database with Unicode column will be ~155-160 MB. Acceptable for iOS app bundle. If we want it smaller:
- Drop translations we don't ship (Spanish, Urdu, multiple Punjabi teekas) → ~100 MB
- Or download corpus on first launch → smaller .ipa, requires network on first run

**Recommendation:** ship the full corpus inline for now (offline-from-first-launch principle). Optimize if App Store size becomes an issue.

---

## 5. ASR strategy ⚠️ (the second big one)

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
  - `ggml-base` (~150 MB) — fast, poor Punjabi quality
  - `ggml-medium` (~500 MB quantized) — Phase 1 baseline; works
  - `ggml-large-v3` (~1.5 GB quantized) — best quality; sizeable bundle hit

**Recommendation:** ship `medium` baseline in the bundle, allow user to download `large-v3` as an optional in-app upgrade from settings. Mirrors how Whisper desktop apps handle this.

### Server fallback

A single Hetzner CCX23 (~$25/mo, 4 vCPUs, 16 GB) running:
- FastAPI HTTP endpoint
- Receives raw 16kHz mono PCM chunks over WebSocket
- Runs `faster-whisper large-v3` (no need to bundle on device)
- Streams back Latin-normalised transcript

**Privacy considerations** (CLAUDE.md principle: privacy-first):
- Server fallback is **opt-in only** — explicit consent on first launch on an unsupported device
- Audio is not stored server-side; in-memory only, dropped after transcription
- Privacy policy explicit about this; clear "use server" toggle in settings always available

### Streaming chunking strategy

- Capture mic at 16 kHz mono → ring buffer
- Send 5-second sliding chunks (1s overlap) to ASR every 1 second
- Latest ASR result feeds the matcher; matcher updates UI position
- Total UI latency target: ~2 seconds (matches Phase 1's "1-3 seconds acceptable" for Use Case 1)

---

## 6. iOS audio capture

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

## 14. Implementation roadmap

I'll work through these in order; stops at the marked checkpoints.

| Step | What | Stop and check in? |
|---|---|---|
| 1 | Build pipeline: `build/convert_anmol_to_unicode.js` + `build_app_database.py` → bundle-ready SQLite | No (small, mechanical) |
| 2 | Swift corpus loader + matcher port (covering test battery from Phase 1) | No, but I'll show the test results |
| 3 | iOS Xcode project skeleton, AVAudioEngine pipeline, whisper.cpp wired in | **Yes — checkpoint 1: lock in architecture decisions before UI work** |
| 4 | Bani Picker + Follow View for one Nitnem Bani (Japji) end-to-end | **Yes — checkpoint 2: first buildable iOS prototype, you try it on your phone** |
| 5 | Remaining Nitnem Banis, Sukhmani, AKV | Incremental commits, no formal checkpoint |
| 6 | Sehaj Paath mode (full SGGS + state machine) | No (architectural; show telemetry) |
| 7 | Akhand Paath mode (long-session resilience) | No |
| 8 | Settings, translations toggle, model upgrade flow | No |
| 9 | Background mode polish, battery/thermal handling | No |
| 10 | App Store submission readiness | **Yes — checkpoint 3: before TestFlight / submission** |

Parallel work tracks (lower priority, scheduled when I'm waiting on user feedback):
- **Track B:** `scripts/fetch_samples.py` for Kirtan sample gathering (Phase 2B prep)
- **Track C:** aeneas forced-alignment spike (Phase 2B prep)

---

## 15. Open questions / risks

- **iPhone Neural Engine performance on whisper-medium** — needs real measurement; if too slow at real-time, we drop to whisper-base or move to server-only for some operations. Benchmark in step 3.
- **CoreML conversion of large-v3** — community tooling exists but is fiddly. Plan to ship medium baseline and treat large-v3 as a stretch.
- **Gurmukhi font rendering** — system fonts may render some conjuncts incorrectly. Plan: bundle a known-good font (Gurbani Akhar Slim / Gurbani Akhar) under appropriate licence.
- **Akhand Paath voice handoff** — DRIFTING-state recovery is a guess until we test on a real recording with multiple Pathis. Phase 2B sample gathering should include one.
- **Server fallback privacy review** — opt-in is the answer but the framing of the consent screen needs care. Lawyer? Possibly worth a small consultation when we get to that step.

---

## 16. What I'd like Deep to weigh in on before I start

In priority order:

1. **§3 — Core engine language:** Swift+Kotlin re-impl vs Rust core. My recommendation is the lighter Swift+Kotlin path. Decide if you want to invest in Rust earlier.
2. **§5 — ASR strategy:** confirm medium-baseline + optional large-v3 download, and confirm server fallback is opt-in only.
3. **§2 — Repo structure:** confirm monorepo is fine vs separating ios/ into its own repo.
4. **§4 — Corpus pipeline:** ship full 155 MB or trim translations to save bundle size?
5. **§14 — Implementation order:** any reordering you want?

Once you sign off (or amend), I lock these in and begin step 1.
