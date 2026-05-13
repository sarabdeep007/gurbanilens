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

### Phase 2A — Paath / Bani recitation companion app (CURRENT)

Full Paath companion: Nitnem Banis (Japji, Jaap, Tav-Prasad Savaiye, Chaupai, Anand, Rehras, Kirtan Sohila), Sukhmani Sahib, Asa Ki Vaar, **Sehaj Paath** (find reader anywhere in SGGS), **Akhand Paath** (continuous 48hr, multi-Pathi).

- iOS first (Swift/SwiftUI), Android right after (Kotlin/Compose)
- On-device ASR via whisper.cpp + CoreML where the device can handle it; server fallback for older devices (opt-in due to privacy)
- Background-tolerant (screen off, app backgrounded → still listening)
- Offline-capable for the SGGS corpus
- Anvaad-js (build-time) for Anmol Lipi → Unicode Gurmukhi conversion

See [docs/PHASE_2A_ARCHITECTURE.md](./docs/PHASE_2A_ARCHITECTURE.md) for stack decisions, repo structure, data flow, and implementation roadmap.

### Phase 2B — Kirtan dataset + fine-tuned ASR (parallel)

Build a labeled Kirtan dataset (transcript + audio alignment), then fine-tune Whisper on it. Two preparation tracks running in the background:
- `scripts/fetch_samples.py` — Deep gathers more Kirtan recordings systematically
- aeneas forced-alignment spike — given a known Shabad and audio, can we auto-align word-to-time?

### Phase 2C — Gurdwara projector + Sevadaar control panel (gated on 2A polish + 2B fine-tuning)

Use Case 2. Strict accuracy required. Includes Sevadaar override controls. Waits for fine-tuned ASR.

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

- ✅ Project scoped and designed (in claude.ai chat)
- ✅ Name chosen: GurbaniLens
- ✅ Domain: GurbaniLens.com (to be registered)
- ✅ 13 sample Kirtan recordings gathered in `./samples/` (gitignored)
- ✅ Phase 1 CLI built, evaluated, closed (see [PHASE_1_CONCLUSION.md](./PHASE_1_CONCLUSION.md))
- ✅ Phase 2A architecture **LOCKED 2026-05-12** — see [docs/PHASE_2A_ARCHITECTURE.md](./docs/PHASE_2A_ARCHITECTURE.md). Sign-off table at top of doc.
- ⏳ Phase 2A implementation in progress — starting with repo restructure + build pipeline + port-parity vectors (step 1 of §14)
- ⏳ Phase 2B preparation tracks running in parallel: `scripts/fetch_samples.py` (Track B) and aeneas forced-alignment spike (Track C, writeup at [docs/aeneas_spike.md](./docs/aeneas_spike.md))
