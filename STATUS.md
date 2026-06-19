# GurbaniLens — STATUS

_Last updated: 2026-06-19 by Claude (iOS agent) — Phase 2A v1 voice-search SwiftUI app written, matching Android Compose architecture._

This is the up-to-the-minute state file. CLAUDE.md is the durable project doc; STATUS.md is for "what's happening right now."

---

## Current Phase

**Phase 2A v1 — voice-search Gurbani.** Tap a button, recite/speak a Pangti, app transcribes via Whisper, matcher returns the top Shabad candidates, user picks one, full Shabad is shown with translations.

Pivoted from "continuous-listen Paath companion" on **2026-06-17**. Original Phase 2A spec preserved in [docs/PHASE_2A_ARCHITECTURE.md](./docs/PHASE_2A_ARCHITECTURE.md) and marked as v2.

---

## What's Done

- ✅ **Phase 1 CLI** — Python `core/gurbanilens/{corpus,matcher,asr,cli}.py`. Matcher solid; ASR is the bottleneck for sung Kirtan. See [PHASE_1_CONCLUSION.md](./PHASE_1_CONCLUSION.md).
- ✅ **Phase 2A architecture LOCKED 2026-05-12** — [docs/PHASE_2A_ARCHITECTURE.md](./docs/PHASE_2A_ARCHITECTURE.md). Versioned v1 / v2 / v3 since 2026-06-17.
- ✅ **Repo restructure** — `src/gurbanilens/` → `core/gurbanilens/`. Python is canonical reference; Swift and Kotlin ports validate against `core/tests/portparity/test_vectors.json`.
- ✅ **Anvaad-js build pipeline** — `build/convert_anmol_to_unicode.js` + `build/build_app_database.py` → ~77 MB `app_database.sqlite` (bundled into iOS / Android).
- ✅ **Swift matcher port** — `ios/GurbaniLensCore/`. 11/11 port-parity PASS against canonical Python on the full 60K-line SGGS corpus. `Corpus.shabadLines(shabadId:)` added 2026-06-19 for the v1 Shabad screen.
- ✅ **iOS v1 voice-search app code** — `ios/GurbaniLens/`. Saffron-on-indigo `Theme`, `@MainActor` `VoiceSearchSession` state machine, five SwiftUI screens (Home / Recording / Results / Shabad / Settings) wired through `NavigationStack` + `AppNavGraph`, `AppContainer` orchestrator owning corpus/matcher/asr, `RecordingCapture` on top of `MicSource`, `WhisperOneShot` actor wrapping whisper.cpp single-shot transcription with Phase 1 deterministic config locked (greedy / temperature=0 / no fallback / `language="pa"` / `greedy.best_of=1`). Entry point switched from `SmokeTestView` to `AppNavGraph`; smoke test code preserved as v2 reference. iOS 16+ (NavigationStack). Awaiting Deep to run on device.
- ✅ **iOS smoke-test app code** — `ios/GurbaniLens/`. XcodeGen project, `AudioSource` protocol + `MicSource` + `FileSource` + `LineInSource` stub, whisper.cpp + CoreML wrapper, SwiftUI smoke-test view. Kept as the v2 reference implementation (continuous streaming, sliding-window ASR); no longer the app entry point in v1.
- ✅ **`scripts/fetch_ios_deps.sh`** — re-runnable bootstrap that mirrors the Android script: downloads `ggml-small.bin` (~250 MB) from HuggingFace into `ios/GurbaniLens/GurbaniLens/Resources/Models/` and copies `data/sggs/database.sqlite` into `Resources/Data/app_database.sqlite`. Both dirs gitignored.
- ✅ **Phase 2B prep tracks** — `scripts/fetch_samples.py` (Track B sample gathering), `docs/aeneas_spike.md` (Track C alignment, pivoted to `faster-whisper` word_timestamps).
- ✅ **Server skeleton + privacy contract** — `server/` directory, FastAPI scaffold. Not deployed; documents the v2 fallback policy.
- ✅ **Opt-in feedback channel spec** — `docs/feedback_channel_spec.md`.
- ✅ **Android scaffold** — Kotlin/Compose Gradle multi-module (`:app` + `:core`). AGP 8.6.1, Kotlin 2.0.21, Compose BOM 2024.10.01.
- ✅ **Kotlin matcher port** — `android/core/src/main/kotlin/.../core/`. **11 / 11 port-parity PASS** against canonical Python on the full 60K-line SGGS corpus.
- ✅ **v1 voice-search MVP UI** — 5 Compose screens (Home / Recording / Results / Shabad / Settings) wired through a NavHost with shared `VoiceSearchSession` state holder.
- ✅ **AudioRecord capture** — 16 kHz mono Float32 PCM, tap-to-record, peak-amplitude live VU bar.
- ✅ **whisper.cpp prebuilt integration** — vendored arm64-v8a / armeabi-v7a / x86 / x86_64 `libwhisper*.so` (54 MB) from `litongjava/whisper.cpp.android.java.demo` v1.0.0; Kotlin JNI binding at `com.whispercppdemo.whisper.WhisperLib`; idiomatic wrapper at `com.taajsingh.gurbanilens.domain.WhisperAsr`.
- ✅ **Whisper model bundled** — multilingual `ggml-base.bin` (~148 MB) downloaded from HuggingFace into `app/src/main/assets/`. (The previous `ggml-tiny.en.bin` was English-only and couldn't transcribe Punjabi; multilingual base is the smallest model that handles `pa`.)
- ✅ **`scripts/fetch_android_deps.sh`** — re-runnable bootstrap that populates the gitignored Android binary deps: prebuilt `libwhisper*.so` files, `ggml-base.bin`, and `sggs.sqlite` (copied from `data/sggs/database.sqlite`). `app/src/main/jniLibs/` and `app/src/main/assets/ggml-*.bin` are now explicit in `.gitignore`.
- ✅ **End-to-end voice-search unit test** — synthetic PCM → MockAsr → Matcher → SearchResult; verified strong-confidence match on exact transcript, low-confidence reject on unrelated query, empty matches on empty transcript.

---

## What's In Flight

- 🟢 **Deep — iOS v1 voice-search on device.** Xcode install + `bash scripts/fetch_ios_deps.sh` + `xcodegen generate` + run on iPhone with free Apple ID. See [docs/PHASE_2A_IOS_SETUP.md](./docs/PHASE_2A_IOS_SETUP.md). Independent of Android track.
- 🟢 **Phase 2B Kirtan dataset gathering** (separate agent track) — continues feeding v2.
- 🟡 **iOS v1 deferred polish** (next dispatch, gated on Deep's first device run):
  - Bundle CoreML-converted `ggml-small-encoder.mlmodelc` alongside the .bin (Apple Neural Engine path; current code falls back to CPU/Metal which is fine).
  - Bundle the Anvaad-trimmed `app_database.sqlite` (~77 MB) once the build pipeline produces it. Until then the corpus is the raw shabados/database (~150 MB) — works but bigger app size.
  - Wire `WhisperModelChoice` from `SettingsScreen` to a runtime model swap (currently the setting is persisted but `AppContainer` only looks for the bundled `ggml-small.bin`).
- 🟡 **Android v1 deferred polish** (next dispatch):
  - Replace `MockAsr` in `MainActivity` with `WhisperAsr.fromAssetOrNull(...)` once Robolectric + UI smoke runs land. JNI wiring + model are in place; just the activity wire-up.
  - Bundle the Anvaad-trimmed `app_database.sqlite` (~77 MB) into `app/src/main/assets/sggs.sqlite` once the build pipeline produces it. Right now `AndroidAssetCorpus` falls back to an empty matcher when the asset is absent; users see "no results" until then.
  - Move JNI prebuilt source off the 2023 litongjava demo to either (a) self-built NDK CMake against whisper.cpp upstream (gets us `language="pa"` + fixed seed) or (b) a more recent community AAR. Current deviation documented in `WhisperLib.kt` class kdoc.

---

## What's Deferred

| Item | Why deferred | Gating |
|---|---|---|
| Phase 2A **v2** — continuous live listen, auto-follow, Nitnem, Sukhmani, AKV, Sehaj Paath, Akhand Paath | Sung-Kirtan ASR accuracy too low for projector-grade reliability per Phase 1 finding | v1 ship + Phase 2B Kirtan fine-tune |
| Phase 2A **v3** — Gurdwara projector + Sevadaar control panel + line-in source | Strict-accuracy UX is Use Case 2; needs v2 polish first | v2 stable + Phase 2B |
| Server-side ASR fallback | v1 is on-device only; older devices that can't run `tiny.en` get told so | v2 |
| Background audio / foreground service for listening | Not needed for tap-to-search v1 | v2 |
| Hyyro / n-gram prefilter for Swift+Kotlin partial_ratio | v1 single-shot query is latency-tolerant; brute-force port is fine | v2 (full-corpus continuous search needs it) |
| `language="pa"` + fixed Whisper seed | Prebuilt .so JNI hardcodes `language="en"` + no seed knob | Replace prebuilt with NDK-compiled-from-source (next chunk) |
| Real-device validation of `WhisperAsr` | Headless taaj-portal can't run an APK against the mic | Deep runs `./gradlew :app:installDebug` on a connected device |

---

## Blockers

None right now. v1 Android scaffold compiles + tests pass + APK builds clean on the headless build host. v1 iOS source is written but unverified — taaj-portal has no Xcode toolchain, so a real build is on Deep's plate (`bash scripts/fetch_ios_deps.sh && cd ios/GurbaniLens && xcodegen generate && open GurbaniLens.xcodeproj`).

---

## Tooling & Conventions

- **Source of truth for the matcher:** `core/gurbanilens/matcher.py` (Python). Swift (`ios/GurbaniLensCore/`) and Kotlin (`android/core/`) must produce identical results modulo a ±2-point score tolerance.
- **Port-parity battery:** `core/tests/portparity/test_vectors.json` — 11 cases, 6 "good" / 5 "bad". Every port runs this. Must be 11/11 PASS before any matcher-touching work merges.
- **Corpus source of truth:** `shabados/database` v4.8.7 SQLite (Anmol Lipi). App-bundled DB is the Anvaad-js-augmented `build/app_database.sqlite` (~77 MB).
- **Commit style:** Conventional commits (e.g. `feat(android):`, `chore(docs):`, `test(core):`).
- **Push to origin/main** after each logical unit; this is a 1-person project + Claude, no PR gating.
- **HOLD convention:** agents stop at scoped checkpoints and end the message with literal text "HOLDING for next dispatch." — that triggers Deep's observer email notification.
- **Headless build toolchain (Linux taaj-portal):** Temurin JDK 21 + Kotlin 2.1.0 + Android SDK cmdline-tools + platform-34 + build-tools 34.0.0 + Gradle 8.10.2 (via wrapper). Set `ANDROID_HOME=/home/deep/.local/opt/android-sdk` and `JAVA_HOME=/home/deep/.local/opt/jdk` before `./gradlew :app:assembleDebug`.

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
| `android/app/` | Voice-search MVP — Compose UI + AudioRecord + WhisperAsr |
| `android/app/src/main/jniLibs/` | Prebuilt libwhisper.so (arm64-v8a / armeabi-v7a / x86 / x86_64) — gitignored, fetched by `scripts/fetch_android_deps.sh` |
| `android/app/src/main/assets/ggml-base.bin` | Bundled multilingual Whisper model (~148 MB) — gitignored, fetched by `scripts/fetch_android_deps.sh` |
| `android/app/src/main/assets/sggs.sqlite` | Bundled SGGS corpus — gitignored, copied from `data/sggs/database.sqlite` by `scripts/fetch_android_deps.sh` |
| `scripts/fetch_android_deps.sh` | Re-runnable bootstrap for the three above |
| `android/core/` | Kotlin matcher port (11/11 port-parity PASS) |
| `server/` | FastAPI v2-fallback skeleton (different agent's territory) |
| `build/` | Anvaad-js + app DB build pipeline |
| `evaluation/` | Phase 1 historical artifacts (frozen) |

---

## Next Concrete Actions

1. ✅ Doc reset commit — CLAUDE.md + ARCHITECTURE + STATUS.
2. ✅ Android Kotlin/Compose scaffold, `:app` + `:core` Gradle modules.
3. ✅ Kotlin matcher port + 11/11 port-parity passing.
4. ✅ Voice-search MVP screens (Compose).
5. ✅ `AudioRecord` capture + JVM Robolectric unit tests.
6. ✅ whisper.cpp prebuilt .so + JNI Kotlin binding + `WhisperAsr` wrapper.
7. ✅ `ggml-tiny.en.bin` bundled in assets.
8. ✅ End-to-end voice → transcript → matcher → result JVM test.
9. ✅ `./gradlew :app:assembleDebug` produces a clean debug APK on the headless build host.
10. ⏳ Deep — install Xcode, run iOS v1 voice-search on iPhone (`scripts/fetch_ios_deps.sh` + `xcodegen generate` + Cmd-R).
11. ⏳ Deep — sideload the Android debug APK onto a phone and confirm real-mic + on-device Whisper produces a sane transcript.
12. ⏸ NDK-compile whisper.cpp from source to regain `language="pa"` + fixed seed.
13. ⏸ Wire `WhisperAsr` into `MainActivity` (currently uses `MockAsr` until real-device validation lands).
14. ⏸ Bundle the Anvaad-trimmed `app_database.sqlite` into both Android and iOS assets.
15. ✅ iOS v1 voice-search SwiftUI screens + AppNavGraph + AppContainer + WhisperOneShot wired.

---

## How chat-Claude should orient

Read in this order:
1. This file (STATUS.md) — current state.
2. CLAUDE.md — durable vision and principles.
3. PHASE_1_CONCLUSION.md — what we learned and why we pivoted to Paath-then-voice-search.
4. docs/PHASE_2A_ARCHITECTURE.md — read the **"Phase 2A versioning"** header first, then the v1 delta. Most of the original document describes v2.
5. The relevant code surface (`core/gurbanilens/matcher.py` if matcher-related, `ios/GurbaniLensCore/` for Swift, `android/` for Kotlin).

When in doubt: **v1 is voice-search, foreground, tap-to-record.** v2 is the continuous-listen vision. v3 is the projector. If a request sounds like continuous listening or background audio, it's v2 — confirm whether the dispatcher means v1 or v2 before coding.
