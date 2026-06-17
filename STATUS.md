# GurbaniLens — STATUS

_Last updated: 2026-06-17 by Claude (Android agent), reflecting tonight's v1 voice-search pivot._

This is the up-to-the-minute state file. CLAUDE.md is the durable project doc; STATUS.md is for "what's happening right now."

---

## Current Phase

**Phase 2A v1 — voice-search Gurbani.** Tap a button, recite/speak a Pangti, app transcribes via Whisper, matcher returns the top Shabad candidates, user picks one, full Shabad is shown with translations.

Pivoted from "continuous-listen Paath companion" on **2026-06-17**. Original Phase 2A spec preserved in [docs/PHASE_2A_ARCHITECTURE.md](./docs/PHASE_2A_ARCHITECTURE.md) and marked as v2.

---

## What's Done

- ✅ **Phase 1 CLI** — Python `core/gurbanilens/{corpus,matcher,asr,cli}.py`. Matcher solid; ASR is the bottleneck for sung Kirtan. See [PHASE_1_CONCLUSION.md](./PHASE_1_CONCLUSION.md).
- ✅ **Phase 2A architecture LOCKED 2026-05-12** — [docs/PHASE_2A_ARCHITECTURE.md](./docs/PHASE_2A_ARCHITECTURE.md).
- ✅ **Repo restructure** — `src/gurbanilens/` → `core/gurbanilens/`. Python is canonical reference; Swift and Kotlin ports validate against `core/tests/portparity/test_vectors.json`.
- ✅ **Anvaad-js build pipeline** — `build/convert_anmol_to_unicode.js` + `build/build_app_database.py` → ~77 MB `app_database.sqlite` (bundled into iOS / Android).
- ✅ **Swift matcher port** — `ios/GurbaniLensCore/`. 11/11 port-parity PASS against canonical Python on the full 60K-line SGGS corpus.
- ✅ **iOS smoke-test app code** — `ios/GurbaniLens/`. XcodeGen project, `AudioSource` protocol + `MicSource` + `FileSource` + `LineInSource` stub, whisper.cpp + CoreML wrapper, SwiftUI smoke-test view. Awaiting Deep to run on device.
- ✅ **Phase 2B prep tracks** — `scripts/fetch_samples.py` (Track B sample gathering), `docs/aeneas_spike.md` (Track C alignment, pivoted to `faster-whisper` word_timestamps).
- ✅ **Server skeleton + privacy contract** — `server/` directory, FastAPI scaffold. Not deployed; documents the v2 fallback policy.
- ✅ **Opt-in feedback channel spec** — `docs/feedback_channel_spec.md`.

---

## What's In Flight

- 🟢 **Android v1 voice-search app** (this agent, Brief 1):
    - Doc reset (this commit)
    - `android/` Kotlin/Compose scaffold, `:app` + `:core` modules
    - Kotlin matcher port at `android/core/src/main/kotlin/.../core/`
    - 11/11 port-parity test using `core/tests/portparity/test_vectors.json`
    - Voice search MVP UI: Home, Recording, Results, Shabad, Settings
    - `AudioRecord` + whisper.cpp JNI integration
- 🟢 **Deep — iOS smoke test on device.** Xcode install + run on iPhone with free Apple ID. See `docs/PHASE_2A_IOS_SETUP.md`. Independent of Android track.
- 🟢 **Phase 2B Kirtan dataset gathering** (separate agent track) — continues feeding v2.

---

## What's Deferred

| Item | Why deferred | Gating |
|---|---|---|
| Phase 2A **v2** — continuous live listen, auto-follow, Nitnem, Sukhmani, AKV, Sehaj Paath, Akhand Paath | Sung-Kirtan ASR accuracy too low for projector-grade reliability per Phase 1 finding | v1 ship + Phase 2B Kirtan fine-tune |
| Phase 2A **v3** — Gurdwara projector + Sevadaar control panel + line-in source | Strict-accuracy UX is Use Case 2; needs v2 polish first | v2 stable + Phase 2B |
| Server-side ASR fallback | v1 is on-device only; older devices that can't run `small` get told so | v2 |
| Background audio / foreground service for listening | Not needed for tap-to-search v1 | v2 |
| Hyyro / n-gram prefilter for Swift+Kotlin partial_ratio | v1 single-shot query is latency-tolerant; brute-force port is fine | v2 (full-corpus continuous search needs it) |

---

## Blockers

None right now. Android track is fully unblocked; iOS device validation is on Deep's plate independently.

---

## Tooling & Conventions

- **Source of truth for the matcher:** `core/gurbanilens/matcher.py` (Python). Swift (`ios/GurbaniLensCore/`) and Kotlin (`android/core/`) must produce identical results modulo a ±2-point score tolerance.
- **Port-parity battery:** `core/tests/portparity/test_vectors.json` — 11 cases, 6 "good" / 5 "bad". Every port runs this. Must be 11/11 PASS before any matcher-touching work merges.
- **Corpus source of truth:** `shabados/database` v4.8.7 SQLite (Anmol Lipi). App-bundled DB is the Anvaad-js-augmented `build/app_database.sqlite` (~77 MB).
- **Commit style:** Conventional commits (e.g. `feat(android):`, `chore(docs):`, `test(core):`).
- **Push to origin/main** after each logical unit; this is a 1-person project + Claude, no PR gating.
- **HOLD convention:** agents stop at scoped checkpoints and end the message with literal text "HOLDING for next dispatch." — that triggers Deep's observer email notification.

---

## Key Files

| Path | Purpose |
|---|---|
| `CLAUDE.md` | Project master doc (vision, use cases, principles) |
| `STATUS.md` | This file — current state |
| `PHASE_1_CONCLUSION.md` | Phase 1 closeout |
| `docs/PHASE_2A_ARCHITECTURE.md` | Architecture, **versioned v1/v2/v3** |
| `core/gurbanilens/matcher.py` | Canonical matcher (read-only for all port agents) |
| `core/tests/portparity/test_vectors.json` | Port-parity battery (read-only) |
| `ios/GurbaniLensCore/` | Swift matcher port (different agent's territory) |
| `android/` | Kotlin/Compose v1 app + matcher port (this agent's territory) |
| `server/` | FastAPI v2-fallback skeleton (different agent's territory) |
| `build/` | Anvaad-js + app DB build pipeline |
| `evaluation/` | Phase 1 historical artifacts (frozen) |

---

## Next Concrete Actions

1. ✅ Doc reset commit (this) — CLAUDE.md + ARCHITECTURE + STATUS.
2. 🟢 Android Kotlin/Compose scaffold, `:app` + `:core` Gradle modules.
3. 🟢 Kotlin matcher port + 11/11 port-parity passing.
4. 🟢 Voice-search MVP screens (Compose).
5. 🟢 `AudioRecord` capture + whisper.cpp JNI binding.
6. 🟢 End-to-end smoke test on emulator → HOLD for Deep on-device validation.
7. ⏸ Deep — install Xcode, run iOS smoke test on iPhone.

---

## How chat-Claude should orient

Read in this order:
1. This file (STATUS.md) — current state.
2. CLAUDE.md — durable vision and principles.
3. PHASE_1_CONCLUSION.md — what we learned and why we pivoted to Paath-then-voice-search.
4. docs/PHASE_2A_ARCHITECTURE.md — read the **"Phase 2A versioning"** header first, then the v1 delta. Most of the original document describes v2.
5. The relevant code surface (`core/gurbanilens/matcher.py` if matcher-related, `ios/GurbaniLensCore/` for Swift, `android/` for Kotlin).

When in doubt: **v1 is voice-search, foreground, tap-to-record.** v2 is the continuous-listen vision. v3 is the projector. If a request sounds like continuous listening or background audio, it's v2 — confirm whether the dispatcher means v1 or v2 before coding.
