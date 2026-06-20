# Phase 2A v2 — Incremental Search-as-You-Speak

_Drafted 2026-06-20 by Claude (iOS spec agent). **Status: AWAITING DEEP APPROVAL.** No code work begins until the Spec sign-off section is filled in._

This document specifies the v2 voice-search UX. v1 (one-shot tap-to-record) shipped 2026-06-20 and works end-to-end; v2 swaps the one-shot paradigm for an incremental "search as you speak" flow that mirrors how Sangat actually use type-search apps like SikhiToTheMax. v2 reuses v1's matcher and corpus untouched; the changes are concentrated in the ASR + state-machine + UI layers.

---

## Why v2

**Sangat behaviour, observed.** In SikhiToTheMax and similar Gurbani search apps the user types one Gurmukhi letter at a time. After "h" the app shows all Pangtis starting with "h". After "h r" the list filters. By "h r f" the target line is usually visible at position 3-5 — the user taps it before typing the rest. The app's job is to make the right line visible as cheaply as possible; the user's job is to recognise it. Search is a conversation, not a one-shot query.

**v1's limitation.** v1 forces the user to recite a complete Pangti, tap Done, then wait 5-40 seconds (depending on cold/warm) for a single batch answer. If the recitation was off by one word or the Whisper-small model picked the wrong syllable, the user gets one shot at a wrong-ish result and has to start over. The two-button (Cancel/Done) UX is also wrong: Sangat are accustomed to "type letters, see filter, tap a row" — not "speak a complete query, wait, accept or retry". v2 brings the voice flow into the same UX shape Sangat already know.

---

## Architecture overview

```
┌──────────────────────────────────┐
│  iPhone microphone                │
└────────────┬─────────────────────┘
             │  AVAudioEngine tap (16 kHz mono Float32)
             ▼
┌──────────────────────────────────┐
│  WhisperKit.AudioProcessor        │   owns the mic + AVAudioEngine
│  (open class, public, AVAudioEngine internal)
└────────────┬─────────────────────┘
             │  audioSamples: ContiguousArray<Float>
             ▼
┌──────────────────────────────────────────────────┐
│  WhisperKit.AudioStreamTranscriber (public actor)│   v1.0.0+
│  • Energy VAD detects speech / silence            │
│  • Sliding-window CoreML decode on confirmed buf  │
│  • Confirmed-vs-unconfirmed segment split         │
│  • stateChangeCallback(old: State, new: State)    │
└────────────┬─────────────────────────────────────┘
             │  State.{currentText, confirmedSegments,
             │         unconfirmedSegments, unconfirmedText,
             │         isRecording, bufferEnergy}
             ▼
┌──────────────────────────────────┐
│  StreamingASR (our actor — NEW)   │   ios/GurbaniLens/.../ASR/StreamingASR.swift
│  • Wraps WhisperKit's callback    │
│  • Repetition-guard on currentText│
│  • Latin.from(currentText)        │
│  • Publishes AsyncStream<Partial> │
└────────────┬─────────────────────┘
             │  Partial { text, latin, isConfirmed, energy }
             ▼
┌──────────────────────────────────────────────┐
│  VoiceSearchSession (v2 state machine — UPDATED) │
│  State: .listening(partial, liveMatches)     │
│  • Debounce 300 ms on unconfirmed text       │
│  • Matcher.matchByFirstLetters(latin, 5)     │
│  • Re-publish state on each tick             │
└────────────┬─────────────────────────────────┘
             │  liveMatches: [Match] (top-5 by first-letters prefix)
             ▼
┌──────────────────────────────────────────────┐
│  LiveResultsScreen (SwiftUI — NEW)            │
│  • Sticky live-transcript header              │
│  • Animated list of candidates (insert/move)  │
│  • Tap row → commit + push Shabad screen      │
│  • Stop button → commit + run full fuzzy      │
│  • Auto-commit on 2 s sustained silence       │
└──────────────────────────────────────────────┘

  on commit (any path)
             │
             ▼
┌──────────────────────────────────┐
│  Matcher.match (full Stage 0+1+2) │   one-shot, ~2-5 s on iPhone
└────────────┬─────────────────────┘
             ▼
┌──────────────────────────────────┐
│  ResultsScreen → ShabadScreen     │   v1's screens, reused
└──────────────────────────────────┘
```

---

## Key decisions

### 1. WhisperKit streaming vs chunking

**Decision: Use `WhisperKit.AudioStreamTranscriber`.**

WhisperKit ≥ 1.0.0 ships a `public actor AudioStreamTranscriber` at `Sources/WhisperKit/Core/Audio/AudioStreamTranscriber.swift` (verified 2026-06-20). It exposes `startStreamTranscription()` / `stopStreamTranscription()` and delivers partial transcripts via:

```swift
public typealias AudioStreamTranscriberCallback = @Sendable (
    AudioStreamTranscriber.State, // old
    AudioStreamTranscriber.State  // new
) -> Void
```

The `State` struct includes `currentText: String`, `confirmedSegments: [TranscriptionSegment]`, `unconfirmedSegments: [TranscriptionSegment]`, `unconfirmedText: [String]`, `bufferEnergy: [Float]`, and `isRecording: Bool`. WhisperKit owns the mic via its own `AudioProcessor` (an `AVAudioEngine` wrapper).

**Why not chunking.** A chunked workaround — restart the one-shot `WhisperKit.transcribe(audioArray:)` every 1-2 s on a growing buffer — was the fallback plan. It's strictly worse than the built-in streaming actor because:

- Each chunk pays first-token CoreML startup latency (~200 ms).
- Re-transcribing the same audio prefix is wasteful and produces non-monotonic transcripts (each pass might pick a different language hint).
- We'd have to rebuild WhisperKit's confirmed-vs-unconfirmed segment stability ourselves.

**Rejected alternative.** Continue with `WhisperOneShot` and just lower the audio window. Same problem at smaller scale; gives up the VAD + segment-stability work WhisperKit already does for us.

---

### 2. Partial transcript accumulation

**Decision: Mirror WhisperKit's `currentText` directly. No client-side accumulation.**

The `State.currentText` field is WhisperKit's authoritative "best guess so far" — it's the concatenation of confirmed segments plus the latest unconfirmed text, already de-duplicated across mid-stream corrections. Whisper's internal decoder handles the "said `ham`, corrected to `hum`" case by emitting a new unconfirmed segment that supersedes the prior one; `currentText` reflects the post-correction view.

`StreamingASR` will simply re-publish `currentText` (Latin-normalised) on each callback. **No** locally maintained ring buffer of partial transcripts.

**`confirmedSegments` vs `unconfirmedSegments` split** is preserved in our `Partial` struct via an `isConfirmed` flag per emitted update — the UI uses this to render confirmed text in white and unconfirmed text in lighter saffron (preview opacity 0.6). This visually signals "this part of what we heard is locked in; this part may still change."

**Rejected alternative.** Keep our own [String] ring buffer indexed by segment id. Rejected as duplicated state — we'd diverge from WhisperKit's view the first time Whisper rewrites a segment.

---

### 3. Matcher query during partial

**Decision: Debounce 300 ms on `currentText` changes; run matcher only when the debounced text has changed since the last match call.**

Implementation: in `VoiceSearchSession` (v2 mode), each new `Partial` cancels any pending debounce Task and starts a fresh one. After 300 ms with no further updates, run the matcher. If `currentText` is identical to the last matched query, skip — no need to re-match the same string.

Concretely: a typical recitation produces a `currentText` update every 100-300 ms during active speech. Without debounce we'd call the matcher 3-10× per second. With 300 ms debounce we call it once per natural pause (every 1-3 words spoken). That's the right cadence for a live list to feel responsive but not jittery.

**Rejected alternative.** Run matcher on every callback (no debounce). Wasteful and produces visually noisy result-list updates (rows flicker between intermediate states).

**Rejected alternative.** Run matcher only when a confirmed segment lands (every 1-3 seconds). Too slow — Sangat won't perceive forward progress between confirmations.

---

### 4. First-letters matching during partial

**Decision: Yes. v2's live-matching uses a NEW `Matcher.matchByFirstLetters(query:topN:)` that operates purely on the first-letters abbreviation index. Full fuzzy `match()` runs once at commit.**

Live matching needs to be **fast** — well under 100 ms over the full 60K-line corpus — so the UI feels like type-search. The existing `Matcher.match()` (Stage 0 first-letters pre-filter + Stage 1 full `partial_ratio` + Stage 2 token coverage) is 2-5 s on iPhone. Too slow for live.

`matchByFirstLetters(query:topN:)` is essentially the **existing Stage 0** stripped of Stage 1+2:

1. Extract `qFL` from the query (first letter of each token, lowercased).
2. For each corpus line: `score = StringMetrics.partialRatio(qFL, line.firstLetters)`.
3. Sort by score, return top-N.

The expensive Stage 1 full `partial_ratio(query, line.normalizedText)` does not run. Result: ~50-100 ms on iPhone over 60K lines (the existing `prefilterMs` measurement from v1 DIAG logs).

**Quality trade-off.** First-letters scoring is what type-search apps actually do. Two Pangtis with identical first-letters abbreviations ("har naam ras" and "hari nirbhau ras" both = "hnr") will be indistinguishable by FL score; they'll appear adjacent in the live list. Acceptable — the user picks the right one visually, the same way they do when typing.

**Commit-time full fuzzy.** When the user commits (tap row, tap Stop, or auto-silence), `VoiceSearchSession` runs the existing full `Matcher.match()` once on the accumulated `currentText`. Top-N is replaced with the fuzzy-correct ordering, and the UI re-renders before transitioning to ResultsScreen.

**Rejected alternative.** Trigram inverted index over normalised text. More accurate per query but requires a new index structure (~30 MB additional in-memory) and per-query trigram intersection logic. First-letters is sufficient for v2 ship — trigram is a v2.1 polish if first-letters quality is insufficient.

**Rejected alternative.** Run full fuzzy continuously. Even with first-letters pre-filter (Stage 0), full Stage 1+2 is 2-5 s — that latency budget is fine at commit but not for every 300 ms debounce tick.

---

### 5. UI model

**Decision: Option (b) — new `LiveResultsScreen` with sticky live-transcript header + animated candidate list. v1's `RecordingScreen` is preserved for v1 mode.**

ASCII sketch:

```
┌─ Navigation bar ─────────────────────┐
│  ✕ Cancel                  ● Stop    │   Cancel returns home; Stop commits
├──────────────────────────────────────┤
│                                       │
│  You said:                            │   sticky header
│  ham rulte firte koi baat             │   confirmed (white)
│  na poochta                           │   unconfirmed (saffron 60%)
│  ━━━━━━━━━━━━━━━━━ ▮                  │   underline pulses with VU
│                                       │
├── Searching… ────────────────────────┤
│                                       │
│  ┌─ Ang 167 · Pankti 10 ───────────┐ │   live candidate cards
│  │ hum rulte firte koi baat na…   │ │   tap → commit + ShabadScreen
│  │ Strong match • 91              │ │
│  └────────────────────────────────┘ │
│                                       │
│  ┌─ Ang 712 · Pankti 3 ────────────┐ │
│  │ hum rule jagat me…              │ │
│  │ Possible match • 64             │ │
│  └────────────────────────────────┘ │
│                                       │
│  ┌─ Ang 354 · Pankti 1 ────────────┐ │
│  │ …                                │ │
│  │ Possible match • 58             │ │
│  └────────────────────────────────┘ │
└──────────────────────────────────────┘
```

SwiftUI structure (pseudocode):

```swift
struct LiveResultsScreen: View {
    @ObservedObject var session: VoiceSearchSession
    let onCommit: (Match) -> Void
    let onStop: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            LiveTranscriptHeader(
                confirmed: session.confirmedText,
                unconfirmed: session.unconfirmedText,
                vuEnergy: session.bufferEnergy
            )
            .background(Theme.background)
            // sticky via .safeAreaInset(edge: .top) on the scroll view

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(session.liveMatches, id: \.line.id) { match in
                        CandidateCard(match: match) { onCommit(match) }
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.85),
                           value: session.liveMatchKeys)
            }
        }
        .toolbar { /* Cancel + Stop buttons */ }
        .themed()
    }
}
```

The `transition` + `animation` combo gives free SwiftUI list-diff animations — when matcher returns a new top-5 with one card removed and one inserted, SwiftUI fades the old and slides the new into place.

**Why not (a) "reuse Results screen, just animate the list":** Results screen's layout is "transcript strip + confidence pill + matchCard + alternates" — designed around a frozen final result. The live view needs a constantly-moving transcript header and a constantly-rebuilding list. Different visual hierarchy; cleaner as a new screen.

**Why not (c) "different layout entirely":** v2 isn't a UX rethink. Same colour palette, same navigation patterns, same Match card style as v1 — just live updates instead of frozen. Sangat already familiar with the v1 visual language.

---

### 6. Stopping criteria

**Decision: All three (a) tap row, (b) Stop button, (c) silence-based auto-commit. WhisperKit's built-in VAD provides (c) at no implementation cost.**

WhisperKit's `AudioStreamTranscriber.init` accepts `silenceThreshold: Float = 0.3` and `useVAD: Bool = true`. The default 0.3 threshold + VAD already terminates the stream after ~2 s of sustained silence; the `State.isRecording` flag flips to `false` in the callback. Our `StreamingASR` translates this into an `AsyncStream` finish event; `VoiceSearchSession` reacts by committing.

Behaviour table:

| User action | Behaviour |
|---|---|
| Tap a candidate row | Commit current `currentText`, run full fuzzy match, push `ShabadScreen` directly to the tapped match's Shabad. |
| Tap Stop button | Commit current `currentText`, run full fuzzy match, transition to ResultsScreen with the final top-5. |
| Stop speaking for ~2 s | WhisperKit's VAD trips; same path as tapping Stop (auto-commit). Configurable via Settings: `Stop on silence ✓`. |
| Tap Cancel | Stop stream, discard everything, return home. |

The (c) silence threshold is exposed in Settings (default 2 s). Power users in noisy Gurdwaras can disable auto-commit and rely on the Stop button.

---

### 7. State machine

```
                ┌────────┐
                │ .idle  │  (Home screen)
                └───┬────┘
                    │ user taps mic
                    ▼
              ┌────────────┐                       ┌────────┐
              │ .listening │ ─── any error ──────► │ .error │
              └──┬─────┬───┘                       └────┬───┘
                 │     │                                │ ack
                 │     │ silence-VAD / Stop / row-tap   ▼
                 │     ▼                             .idle
                 │  ┌──────────────┐
                 │  │ .committing  │  (full Matcher.match running)
                 │  └──────┬───────┘
                 │         │ matcher returns
                 │         ▼
                 │    ┌─────────┐
                 │    │ .done   │  (final SearchResult; push Results or Shabad)
                 │    └────┬────┘
                 │         │ user taps row / back
                 │         ▼
                 └────► .idle
                 ▲
                 │ partial transcript update (re-enter same state, new payload)
                 │
              (loop)
```

**Swift enum:**

```swift
public enum State: Equatable {
    case idle
    case listening(
        confirmedText: String,
        unconfirmedText: String,
        liveMatches: [Match],
        vuEnergy: Float
    )
    case committing(query: String)         // full Matcher.match running
    case done(SearchResult)                // final results frozen
    case error(String)
}
```

**Transitions (`VoiceSearchSession` API):**

| From | Trigger | To | Notes |
|---|---|---|---|
| `.idle` | `startListening()` | `.listening(empty)` | Starts WhisperKit stream |
| `.listening` | partial update | `.listening(new payload)` | Re-publish; debounce triggers matcher |
| `.listening` | `commit()` (any of 3 paths) | `.committing` | Stop stream; kick off full matcher |
| `.committing` | matcher returns | `.done(result)` | UI auto-navigates |
| any | error | `.error(msg)` | Alert; ack returns to `.idle` |
| any | `cancel()` | `.idle` | Stop stream cleanly |

**Re-entry of `.listening`** is the common case. Each `Partial` from `StreamingASR` causes `VoiceSearchSession` to publish a new `.listening(…)` with updated payload. SwiftUI's `@Published` + view re-render is the natural fit.

---

## UI mockup

(See decision §5 for the ASCII sketch.) Two SwiftUI views ship in v2:

- `LiveResultsScreen` — the main v2 surface (Home → tap mic → here).
- `LiveTranscriptHeader` — extracted subview rendering the confirmed/unconfirmed text + VU underline. Standalone for SwiftUI preview.

`AppNavGraph` gains:

```swift
enum Route: Hashable {
    case recording           // v1 batch mode
    case liveRecording       // v2 streaming mode  ← NEW
    case results
    case shabad(ShabadPayload)
    case settings
}
```

`HomeScreen`'s mic-tap routes to `.recording` or `.liveRecording` based on the persisted `SearchModeChoice` in `SettingsScreen` (see §10).

Existing `ResultsScreen` and `ShabadScreen` are reused unchanged — v2 commit lands on the same Results screen layout as v1.

---

## Matcher changes needed

All inside `ios/GurbaniLensCore/Sources/GurbaniLensCore/Matcher.swift`. **Zero changes to existing v1 `match()` semantics.**

**Added public API:**

```swift
extension Matcher {
    /// Live-matching fast path. Scores corpus lines by
    /// `partial_ratio(query first-letters, line first-letters)` only —
    /// no Stage 1 full `partial_ratio`, no Stage 2 token coverage.
    /// Sub-100 ms on iPhone over 60K lines.
    public func matchByFirstLetters(_ query: String, topN: Int = 5) -> [Match]
}
```

**Internals:**

- Reuses the existing `firstLetters: [String]` index built at init.
- Extracts `qFL` from normalised query.
- Single pass over `firstLetters[]`: compute `partial_ratio(qFL, lineFL)`, keep top-N.
- Returns `[Match]` with `partialRatio = first-letters score`, `coverage = 1.0`, `score = first-letters score`. The `coverage = 1.0` claim is a lie (we didn't compute coverage), but it lets the existing UI layer use the same `Match` struct uniformly. Documented in the kdoc.

**No port-parity impact.** The existing `core/tests/portparity/test_vectors.json` battery validates `match()` — `matchByFirstLetters()` is a v2-only fast path with its own future test vectors. Python `core/gurbanilens/matcher.py` does not need a `match_by_first_letters` equivalent yet — that's a v2.1 follow-up if we want Mac-side baseline numbers.

**Kotlin parity.** Same `matchByFirstLetters()` added to `android/core/.../matcher/Matcher.kt` when Android v2 lands. Out of iOS-only v2 scope.

---

## Audio pipeline changes needed

**v1 mode (untouched):**
- `MicSource` (bulk-convert at stop)
- `RecordingCapture` (one-shot mic wrapper)
- `WhisperOneShot` (one-shot WhisperKit.transcribe)

These stay byte-for-byte the same. v1 mode continues to work.

**v2 mode (NEW):**
- `StreamingASR` actor (NEW file `ios/GurbaniLens/GurbaniLens/ASR/StreamingASR.swift`).
- Wraps `WhisperKit.AudioStreamTranscriber`.
- WhisperKit owns the mic via its built-in `AudioProcessor` (the actor's `audioProcessor: any AudioProcessing` init parameter). **We do not pass our `MicSource`** — `AudioProcessor` provides the mic capture for v2.
- Publishes an `AsyncStream<Partial>` for `VoiceSearchSession` to consume.

```swift
public actor StreamingASR {
    public struct Partial: Sendable {
        public let confirmedText: String     // Latin-normalised
        public let unconfirmedText: String   // Latin-normalised
        public let bufferEnergy: Float       // for VU bar
        public let isStillRecording: Bool
    }

    public init(pipe: WhisperKit, decode: DecodingOptions) { … }

    /// Starts the mic + decoder, returns an AsyncStream that emits one
    /// Partial per WhisperKit state-change callback. The stream finishes
    /// when WhisperKit's VAD detects sustained silence OR `stop()` is
    /// called.
    public func stream() -> AsyncStream<Partial>

    public func stop() async
}
```

**`StreamingASR` internal flow:**

1. Construct `AudioStreamTranscriber(audioEncoder: pipe.audioEncoder, featureExtractor: pipe.featureExtractor, segmentSeeker: pipe.segmentSeeker, textDecoder: pipe.textDecoder, tokenizer: pipe.tokenizer, audioProcessor: pipe.audioProcessor, decodingOptions: decode, requiredSegmentsForConfirmation: 2, silenceThreshold: 0.3, useVAD: true, stateChangeCallback: …)`.
2. In the callback, translate `(old, new) -> Partial`. Apply the existing `WhisperOneShot.isRepetitionHallucination(_:)` to `new.currentText` — if tripped, emit a `Partial` with empty text (Live UI will go quiet, user can re-recite).
3. Yield `Partial` into the AsyncStream's continuation.
4. When `new.isRecording == false`, finish the stream.

**WhisperKit `pipe` construction is shared with v1.** `AppContainer.ensureAsr()` already lazy-constructs a `WhisperKit` instance through `WhisperOneShot`. For v2, expose the underlying `WhisperKit` instance through a new method on `WhisperOneShot` (or refactor pipe construction into a small `WhisperPipeProvider` that both `WhisperOneShot` and `StreamingASR` use). The `DecodingOptions` (language remap `pa→hi`, temperature ladder, etc.) are identical between v1 and v2.

**Risk: audio session conflict.** WhisperKit's `AudioProcessor` configures the audio session internally. Our `MicSource` (v1) also configures it on every start. If a user switches v1 ↔ v2 in Settings during a session, we may need to explicitly tear down WhisperKit's mic before reconfiguring. Mitigation: enforce app-restart-on-mode-change in Settings (we already require that for `WhisperModelChoice`), OR move all session config into a single `AudioSessionManager` that both paths consult. Decision deferred until v2 wiring is in place.

---

## Phased implementation plan

Each day is one dispatch (1-3 hours of focused agent work + Deep on-device test cycle).

### Day 1 — Streaming wiring

**Goal: see partial transcripts arrive in NSLog from a real device recording.**

- New `StreamingASR.swift` wrapping `AudioStreamTranscriber`.
- Refactor `WhisperOneShot` to expose its `WhisperKit` instance (or extract `WhisperPipeProvider`).
- Smoke test: a debug button (or a temporary entry point in `SettingsScreen`) that starts `StreamingASR.stream()`, logs every `Partial` via `[DIAG]`, runs until user taps a Stop button.
- **Acceptance:** Deep records "ek oankaar sat naam" on device; console shows `[DIAG] StreamingASR partial confirmed="…" unconfirmed="…" energy=…` lines arriving every 200-500 ms. Final partial after silence has `isStillRecording=false`.

### Day 2 — Matcher fast path

**Goal: `Matcher.matchByFirstLetters()` returns top-5 in under 100 ms on iPhone.**

- Add `matchByFirstLetters()` to `Matcher` in `GurbaniLensCore`.
- Reuse the existing `firstLetters` index — no schema change.
- Add `[DIAG] Matcher.matchByFirstLetters` log: `totalLines`, `qFL`, `topScore`, `totalMs`.
- Add unit tests (XCTest in `GurbaniLensCoreTests`): synthesise a small `Matcher(prebuilt:)`, verify ordering and top-N count.
- **Acceptance:** `swift test` passes including new tests. Deep runs on device with day-1 wiring + matcher hooked into the partial stream; `[DIAG] Matcher.matchByFirstLetters … totalMs=<100>` in console.

### Day 3 — UI live-update

**Goal: working `LiveResultsScreen` with header + animated candidate list.**

- `VoiceSearchSession` v2 mode: add `.listening(…)` and `.committing(…)` cases. Keep v1 `.recording`, `.transcribing`, `.matching`, `.done`, `.error` for v1 mode.
- `LiveResultsScreen` + `LiveTranscriptHeader` SwiftUI views.
- `AppNavGraph.Route.liveRecording` added; `HomeScreen` mic tap reads `@AppStorage("settings.searchMode")` → routes accordingly.
- Settings: add `SearchModeChoice = { live, oneShot }` enum + a section in `SettingsScreen`. Default `.live`.
- **Acceptance:** Deep records on device; sees sticky header text appear as he speaks, candidate list updates as he gets further into the recitation, list animates inserts/removals smoothly. Tapping a row commits + opens that Shabad. Tapping Stop commits + opens Results. Silence for 2 s auto-commits.

### Day 4 — Polish + edge cases

**Goal: ship-ready v2.**

- Hallucination guard during stream (call `WhisperOneShot.isRepetitionHallucination(_:)` on `currentText`; if trips, render a "didn't catch that, try again" inline message in the header instead of garbage Devanagari).
- Mic-permission flow on first launch (currently surfaces in `MicSource` for v1; need an equivalent in `WhisperKit.AudioProcessor` path — verify it asks for permission via `AVAudioSession.requestRecordPermission` or surface a clear instruction if not).
- Settings: silence-threshold slider (0.5 / 1 / 2 / off).
- VU bar: use `bufferEnergy` from WhisperKit's State (last value of `[Float]`) to animate the underline pulse.
- Migrate the live-transcript header's "you said" label to localised strings (Punjabi / English / Hindi) — same key as v1.
- **Acceptance:** Deep ships v2 to Sangat testers; ≥ 3 testers use it for 1+ Pangti search each in real Gurdwara / home settings; feedback collected before v2.1.

**Day 5+ (deferred):** Android v2 port, Settings model-size selector wiring, trigram index if first-letters quality is insufficient.

---

## Known risks

### Risk 1 — Whisper-small Punjabi remap (`pa → hi`) under streaming

**Severity: MEDIUM.** v1 confirmed that Whisper-small produces Telugu glyphs for clean Punjabi audio when given `language="pa"`; `pa→hi` remap fixes it. **Whether streaming behaves the same way is untested.** WhisperKit's `AudioStreamTranscriber` accepts a `DecodingOptions` parameter — we'll pass the same `language="hi"`, but the streaming decoder uses a different sliding-window context and may exhibit different language drift on segment boundaries.

**Mitigation:**
- Day 1 acceptance includes a Devanagari sanity check. If streaming output is Telugu garbage, drop back to chunked one-shot before investing in the UI work.
- The hallucination guard from v1 applies on every `currentText` update.
- Plan B: if streaming is unusable on `openai_whisper-small`, bump default model to `openai_whisper-base` (~150 MB → ~400 MB bundle delta) which has better Punjabi/Hindi coverage. This is a Settings-level switch; v2 architecture is unaffected.

### Risk 2 — Matcher first-letters quality

**Severity: MEDIUM.** First-letters scoring is what type-search apps use, so the pattern is validated for typed input. But Whisper's transcription drops tokens occasionally — if the user recites 8 words and Whisper only transcribes 6, the abbreviation has 6 chars instead of 8 and first-letters matching may not find the target line in the top-5.

**Mitigation:**
- Day 3 dogfood: Deep records 5-10 Pangtis and checks whether target appears in live top-5 by the time he's mid-recitation. If hit rate < 70%, escalate.
- Plan B: add a Stage 0.5 — when query length ≥ 4 first-letters AND no candidate in top-5 has score ≥ 75, broaden to top-50 by first-letters and add a brief Stage 1 sub-pass with a 200 ms time budget.
- Plan C (v2.1): trigram inverted index. Defer until first-letters quality is empirically shown to be insufficient.

### Risk 3 — ANE/GPU compute units under streaming

**Severity: LOW.** v1 pinned `ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine)` explicitly. These are passed via the `WhisperKitConfig` used to construct the `WhisperKit` instance; `AudioStreamTranscriber` then reuses the same `audioEncoder` / `textDecoder` instances. ANE should be active automatically.

**Mitigation:** Day 1 acceptance includes a `[DIAG]` log of compute-unit assignment by reading `pipe.audioEncoder.computeUnits` (if exposed; otherwise an Instruments time-profile during dogfood). Cold-start cost (~30 s on v1 first launch) is a one-time investment per app session and dominates first-recording perception; subsequent recordings should be much snappier.

### Risk 4 — WhisperKit AudioProcessor + our `MicSource` audio-session conflict

**Severity: MEDIUM.** WhisperKit's `AudioProcessor.setupEngine()` configures `AVAudioSession` on its own. If the user toggles Settings from v2 (live) to v1 (one-shot) mid-session, both could try to own the session.

**Mitigation:**
- Require app restart when changing search mode (a one-line warning in Settings UI). Same pattern as `WhisperModelChoice`.
- Or: extract session management into a shared `AudioSessionManager` that both paths consult before configuring. Decision deferred to Day 1 implementation.

### Risk 5 — Latency budget

**Severity: LOW.** End-to-end live perception: Whisper streaming decode ~500-1000 ms per confirmed segment + 300 ms debounce + ~50-100 ms matcher = ~1-1.5 s from "spoke a word" to "new candidates in list". This is slower than type-search (where typing → matcher is ~10 ms) but is the irreducible cost of going through Whisper. Acceptable for v2 ship.

**Mitigation:** Make sure the `LiveTranscriptHeader`'s VU underline + saffron text continue to animate during the gap, so the user sees the mic is alive even when the list hasn't updated yet.

---

## Backwards compatibility

**Decision: v1 and v2 coexist via a Settings toggle. Default = v2 (live) once v2 ships.**

`SettingsScreen` gains:

```swift
enum SearchModeChoice: String, CaseIterable {
    case live      // v2 — incremental search-as-you-speak (default)
    case oneShot   // v1 — tap, recite, tap Done
}
```

Persisted via `@AppStorage("settings.searchMode")`.

`HomeScreen` reads this on mic tap and pushes either `Route.liveRecording` (v2) or `Route.recording` (v1). The rest of the navigation graph is shared — both modes commit to the same `ResultsScreen` and `ShabadScreen`.

**Why keep v1.**
- v1 is more reliable in noisy environments (Gurdwara bhog with background sangat conversation) because the user has manual stop control.
- v1 is the right mode for slow connections / cold-launched WhisperKit — one-shot is more predictable than streaming on first-launch.
- v1 path is already tested on device. Removing it would be a regression risk for a single-mode v2 ship.

**Migration.** Users who installed v1 keep v1 mode by default (UserDefaults missing key reads as nil → first read after v2 ship reads `.live` only on fresh installs; we explicitly set `.live` for upgrading installs via a v2 migration in `AppContainer.init` — see Day 4 acceptance).

---

## Spec sign-off

This section is filled in by Deep after review. **No v2 implementation work begins until this section says APPROVED.**

| Item | Status | Notes |
|---|---|---|
| Decision 1 (WhisperKit streaming, no chunking) | ⬜ pending | |
| Decision 2 (mirror `currentText`) | ⬜ pending | |
| Decision 3 (300 ms debounce) | ⬜ pending | |
| Decision 4 (first-letters live matching) | ⬜ pending | |
| Decision 5 (new `LiveResultsScreen`) | ⬜ pending | |
| Decision 6 (all three stopping criteria) | ⬜ pending | |
| Decision 7 (v2 state machine) | ⬜ pending | |
| Decision 8 (audio pipeline split v1/v2) | ⬜ pending | |
| Decision 9 (error handling) | ⬜ pending | |
| Decision 10 (Settings toggle, default `.live`) | ⬜ pending | |
| Risk 1 (`pa → hi` under streaming) | ⬜ acknowledged | |
| Risk 2 (first-letters quality) | ⬜ acknowledged | |
| Risk 3 (ANE under streaming) | ⬜ acknowledged | |
| Risk 4 (session conflict) | ⬜ acknowledged | |
| Risk 5 (latency budget) | ⬜ acknowledged | |
| Day 1-4 phased plan | ⬜ approved | |

**Overall:** ⬜ APPROVED / ⬜ APPROVED WITH CHANGES (list below) / ⬜ NEEDS REWORK

Changes requested (if any):

```
(Deep fills in)
```

---

## References

- WhisperKit v1.0.0 release: https://github.com/argmaxinc/WhisperKit/releases/tag/v1.0.0
- `AudioStreamTranscriber` source: https://github.com/argmaxinc/WhisperKit/blob/main/Sources/WhisperKit/Core/Audio/AudioStreamTranscriber.swift
- `AudioProcessor` source: https://github.com/argmaxinc/WhisperKit/blob/main/Sources/WhisperKit/Core/Audio/AudioProcessor.swift
- WhisperKit-CoreML models: https://huggingface.co/argmaxinc/whisperkit-coreml
- v1 architecture (this doc's predecessor): [PHASE_2A_ARCHITECTURE.md](./PHASE_2A_ARCHITECTURE.md)
- v1 iOS setup (build / device run): [PHASE_2A_IOS_SETUP.md](./PHASE_2A_IOS_SETUP.md)
- Phase 1 conclusion (matcher characterisation): [../PHASE_1_CONCLUSION.md](../PHASE_1_CONCLUSION.md)
