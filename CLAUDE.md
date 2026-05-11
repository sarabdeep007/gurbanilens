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

## Phase 1: CLI Proof-of-Concept (CURRENT)

**Goal:** Validate that ASR + fuzzy matching against the SGGS corpus works reliably on varied Kirtan recordings *before* investing in mobile/desktop apps.

**Approach:**
1. Take an audio file (MP3/WAV) as input
2. Run streaming ASR (Whisper) with Punjabi language hint
3. Match transcribed text against pre-indexed SGGS corpus (BaniDB)
4. Output matched Pangtis with timestamps and confidence scores

**Sample CLI output target:**
```
$ gurbanilens match-file ./samples/bhai-harjinder-asa-ki-vaar.mp3
[00:12] Matched: SGGS Ang 462, Pangti 3 (confidence 0.87)
        ਆਸਾ ਮਹਲਾ ੧ ॥
[00:18] Matched: SGGS Ang 462, Pangti 4 (confidence 0.91)
        ਵਾਰ ਸਲੋਕਾ ਨਾਲਿ ਸਲੋਕ ਭੀ ਮਹਲੇ ਪਹਿਲੇ ਕੇ ਲਿਖੇ ...
```

**Stack:**
- Python 3.11+
- `faster-whisper` (efficient Whisper implementation) or OpenAI Whisper
- BaniDB API / SGGS corpus (downloaded locally for offline indexing)
- Custom fuzzy matcher (n-gram + phonetic, biased toward sequential progression)

**Success criteria for Phase 1:**
- Correctly identifies Shabad on at least 70% of clean studio recordings
- Tracks Pangti progression with reasonable lag
- Surface accuracy data per sample for analysis
- Decision point: if matching works, proceed to native apps. If not, fine-tune Whisper on Kirtan data first.

---

## Future Phases (post-validation)

- **Phase 2:** Core engine ported to C++/Rust for cross-platform reuse
- **Phase 3:** iOS app (Swift/SwiftUI) — Use Case 1 MVP
- **Phase 4:** Android app (Kotlin/Compose)
- **Phase 5:** Projector display + Sevadaar control panel — Use Case 2
- **Phase 6:** Desktop Pro install (Mac/PC permanent Gurdwara deployment)
- **Phase 7:** Fine-tune ASR on Kirtan-specific audio for robustness across raags, jathas, noise

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
- ✅ Sample Kirtan recordings gathered (~15-20 files in `./samples/`)
- ⏳ Phase 1 CLI build — starting now
