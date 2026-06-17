# GurbaniLens

Real-time Kirtan-to-Pangti detection system. Listens to live or recorded Kirtan audio, identifies the currently-sung Shabad and Pangti from Sri Guru Granth Sahib Ji, and displays the Gurmukhi text with transliteration and translations — automatically scrolling as the Ragi sings.

**Tagline:** Bring the Bani into focus.

---

## Vision

Help Sangat follow Kirtan live, improve accessibility (hearing-impaired, non-Punjabi speakers, learners), and deepen Gurbani engagement. Built as Seva, best-effort quality, no compromises because it will be used in Darbar Sahib and Gurdwaras worldwide.

---

## Target Use Cases

### Use Case 1: Personal Follow-Along App
Individual Sangat member opens the app on their phone while listening to Kirtan (YouTube, in-Gurdwara, broadcast). App listens via mic, identifies Shabad, displays Pangti with transliteration/translation, auto-scrolls as Ragi progresses.

- Phone mic, noisy environments
- Latency-tolerant (1–3 seconds acceptable)
- Single user, on-device or light server
- Forgiving accuracy bar

### Use Case 2: Gurdwara Projector System
Ragi performs Kirtan, app listens (ideally via line-in from mixer), and the active Pangti is projected on the Darbar Sahib screen — Pangti by Pangti, in sync with the Ragi. If the Ragi repeats or goes back to a previous Pangti, the projection follows. Translations shown below for Sangat to read along.

- Clean audio (line-in preferred, ambient mic fallback)
- Latency-critical (<1 second target)
- Public-facing — high accuracy bar, Sevadaar override required
- Must handle backward tracking, Rahao repetition, alaap/improvisation
- Operator control panel (Sevadaar on tablet/laptop) — pause, lock, manual jump, switch Shabad

---

## Phase 1: CLI Proof-of-Concept (COMPLETE 2026-05-12)

See [PHASE_1_CONCLUSION.md](./PHASE_1_CONCLUSION.md) for the full close-out.

**Outcome:** architecture validated end-to-end. Matcher is solid; Whisper-medium ASR is the binding constraint on accuracy.

| Model | Confident matches (≥75) | Negative test |
|---|---|---|
| `medium` | 4 / 13 (31%) | ✅ rejected |
| `large-v3` | 6 / 13 (46%) | ✅ rejected |

Original success criterion (≥70% Shabad-hit on clean studio recordings) was met for the 4 clean studio recordings we have (babiha 2, harjinder 1/3/5 — all confidently matched); the headline rate is dragged down by live/melodic samples. Most importantly, the matcher correctly refuses to match on Simran audio — the non-negotiable safety property for Use Case 2.

**Phase 1 stack** (preserved as reference implementation):
- Python 3.11+, `faster-whisper`, `rapidfuzz`, `indic-transliteration`
- SGGS corpus: `shabados/database` v4.8.7 SQLite (not Khalis BaniDB which is API-only)
- Matcher: naive `rapidfuzz` partial_ratio × token-coverage × length factor
- Latin matching surface (Whisper Devanagari → IAST → ASCII)

---

## Phase 2 plan (post-Phase 1 decision)

### Phase 2A — Voice-search Gurbani (CURRENT, pivoted 2026-06-17)

Tap a button → speak/recite a Pangti → Whisper transcribes → matcher finds Pangti → app shows the full Shabad. Foreground only, tap-to-speak, no continuous listening, no background audio.

Why this is the right v1:
- **Spoken Punjabi recitation is the best possible ASR input.** Phase 1 measured Japji at 96.6 confidence on `large-v3` — clean speech vs sung Kirtan is night-and-day for Whisper.
- Ships without Kirtan fine-tuning. Removes the only Phase 1 blocker.
- Foreground tap-to-record removes a huge class of platform headaches (background audio entitlements, foreground services, AVAudioSession edge cases).
- Most-requested user need: "I half-remember a Pangti, find the Shabad for me."

Phase 2A v1 stack:
- iOS first (Swift/SwiftUI), Android in parallel (Kotlin/Compose)
- On-device whisper.cpp; bundled `small` model (~200 MB) at install; settings option to download `base`/`medium`/`large-v3`
- Offline-capable: SGGS corpus + matcher fully on-device
- Anvaad-js (build-time) for Anmol Lipi → Unicode Gurmukhi conversion
- Matcher: port of Phase 1 Python to Swift (✅ shipped) + Kotlin (in flight)

Out of scope for v1 — explicitly deferred to v2 / v3:
- Continuous live listening / auto-follow (v2)
- Background audio, screen-off resilience (v2)
- Sehaj Paath find-the-reader, Akhand Paath long-session (v2)
- Sevadaar override controls, Gurdwara projector deployment (v3)

### Phase 2A v2 — Continuous live Paath/Kirtan auto-follow (DEFERRED)

The original Phase 2A spec: continuous mic, auto-scroll, Sehaj Paath, Akhand Paath. Deferred behind v1 ship + v2-grade Kirtan dataset from Phase 2B.

See [docs/PHASE_2A_ARCHITECTURE.md](./docs/PHASE_2A_ARCHITECTURE.md) — most of that document describes v2 scope. Read with the v1/v2/v3 versioning header in mind.

### Phase 2A v3 — Gurdwara projector + Sevadaar control panel (DEFERRED)

Use Case 2. Strict accuracy required. Waits for v2 polish + Phase 2B fine-tuned ASR.

### Phase 2B — Kirtan dataset + fine-tuned ASR (parallel, prep)

Build a labeled Kirtan dataset (transcript + audio alignment), then fine-tune Whisper on it. Two preparation tracks running in the background:
- `scripts/fetch_samples.py` — Deep gathers more Kirtan recordings systematically
- aeneas forced-alignment spike — given a known Shabad and audio, can we auto-align word-to-time?

Phase 2B is what unlocks Phase 2A v2 and v3.

### Later phases

- Desktop Pro install (Mac/PC permanent Gurdwara deployment)
- Multi-language UI expansion (Punjabi/Hindi/English/Spanish)
- Additional Banis, gutkas, Bhai Gurdas Vaaran, Dasam Granth selections

---

## Architectural Principles

- **Seva-first:** open-source core, free for individuals and Gurdwaras forever, no ads, no tracking, no data harvesting
- **Privacy:** on-device processing preferred; server fallback acceptable for older devices
- **Offline-capable:** SGGS corpus cached locally; works without internet for core matching
- **Best-effort quality:** this is used in Darbar Sahib — embarrassment cost of a wrong Pangti is high
- **Human safety net:** for projector use, always include Sevadaar override controls

---

## Data Sources

- **BaniDB** (https://banidb.com) — open Gurbani database maintained by GurbaniNow team. SGGS text, transliterations, translations (English, Punjabi, Hindi, Spanish).
- **SikhiToTheMax** open data where applicable
- Sample Kirtan recordings: stored in `./samples/` for testing

---

## Working Style

- Owner: Deep (Taaj Studios, Ludhiana, India)
- Primary collaborator: Claude
- **Discuss approach before implementation** — propose plan, agree, then code
- Bias toward simple, working code over clever architecture
- Iterate fast in Phase 1 — throwaway Python is fine, we're validating feasibility
- Keep strategic/design discussions in claude.ai chat; keep building in Claude Code

---

## Repository Structure (to be created)

```
gurbanilens/
├── CLAUDE.md                  # this file
├── README.md
├── pyproject.toml             # Python project config
├── samples/                   # sample Kirtan audio files (gitignored if large)
├── data/
│   └── sggs/                  # cached BaniDB SGGS corpus
├── src/
│   └── gurbanilens/
│       ├── __init__.py
│       ├── cli.py             # CLI entry point
│       ├── audio.py           # audio loading, preprocessing
│       ├── asr.py             # Whisper wrapper, streaming transcription
│       ├── corpus.py          # SGGS data loading, indexing
│       ├── matcher.py         # fuzzy Pangti matcher, state tracking
│       └── output.py          # formatted result printing
├── tests/
│   └── ...
└── scripts/
    ├── fetch_banidb.py        # one-time corpus download
    └── evaluate.py            # accuracy measurement across samples
```

---

## Current Status

For the up-to-date project state, see [STATUS.md](./STATUS.md). High-level:

- ✅ Project scoped and designed
- ✅ Phase 1 CLI built, evaluated, closed (see [PHASE_1_CONCLUSION.md](./PHASE_1_CONCLUSION.md))
- ✅ Phase 2A architecture LOCKED 2026-05-12 — see [docs/PHASE_2A_ARCHITECTURE.md](./docs/PHASE_2A_ARCHITECTURE.md). Versioned v1 / v2 / v3 since 2026-06-17.
- ✅ Phase 2A foundation: repo `src/` → `core/`, Anvaad-js build pipeline → ~77 MB app SQLite, port-parity infrastructure, **Swift matcher 11/11 port-parity PASS**
- ✅ Phase 2A iOS smoke test code written; awaiting Deep to install Xcode + run on device
- 🟢 **Phase 2A v1 voice-search pivot announced 2026-06-17.** Android scaffold + Kotlin matcher port + voice-search MVP in flight (this agent).
- ⏸️ Phase 2A v2 (continuous live listen) — deferred behind v1 ship + Phase 2B fine-tune
- ⏸️ Phase 2A v3 (Gurdwara projector) — deferred behind v2
- ✅ Phase 2B preparation tracks: `scripts/fetch_samples.py` (Track B); faster-whisper word_timestamps (Track C)
- ✅ Server skeleton (`server/`) + privacy contract committed; not deployed
- ✅ Opt-in feedback channel spec

## Known Phase 2A gating items
- **Continuous-listen / Sehaj Paath gated on matcher perf and Kirtan fine-tune.** v2 scope, not v1. Swift `partial_ratio` is a brute-force port — correct (11/11 port-parity) but too slow for full-60K-line search at projector latency. Tap-to-search v1 is unaffected (one-shot query, latency-tolerant). v2 will need Hyyro's bitmap algorithm or an n-gram prefilter; decision deferred.
- **Whisper non-determinism.** Phase 1 finding (`temperature=0`, no fallback, fixed seed where supported) is wired into the iOS `WhisperASR.Config` defaults. Apply identically in the Android JNI wrapper.
