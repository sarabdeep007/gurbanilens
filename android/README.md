# GurbaniLens — Android (Phase 2A v1)

Kotlin/Compose Android app for Phase 2A v1 voice-search Gurbani.

## Status

- ✅ Gradle multi-module scaffold (`:app` Android application + `:core` JVM library)
- ✅ Kotlin matcher port — `core/src/main/kotlin/com/taajsingh/gurbanilens/core/`
- ✅ Port-parity battery — **11 / 11 PASS** against canonical Python on full 60K-line SGGS corpus
- ⏳ Voice search UI (Home / Recording / Results / Shabad / Settings) — next commit
- ⏳ `AudioRecord` capture + whisper.cpp JNI binding — after UI scaffold

See `../STATUS.md` for the up-to-date project state.

## Modules

| Module | Plugin | Purpose |
|---|---|---|
| `:app` | `com.android.application` | Android app; UI, mic capture, whisper.cpp wiring |
| `:core` | `kotlin("jvm")` | Pure-Kotlin matcher + types — JVM-testable, Android-compatible |

The matcher lives in `:core` so the port-parity test runs on the host JVM
(no emulator needed). The Android-specific corpus loader (using
`android.database.sqlite`) lives in `:app` and feeds lines to
`Matcher.fromLines(...)`. For JVM tests, `:core/src/test/kotlin/.../JvmSqliteCorpus.kt`
provides the same shape using `org.xerial:sqlite-jdbc`.

## Running port-parity tests

```bash
# From repo root: fetch the corpus first if you haven't.
python scripts/fetch_corpus.py

cd android
export GURBANILENS_CORPUS_PATH=$(realpath ../data/sggs/database.sqlite)
./gradlew :core:test
```

Tests skip if `GURBANILENS_CORPUS_PATH` is unset / file missing (same skip
behaviour as the Swift port).

## Building the app

Open `android/` in Android Studio (Iguana 2023.2.1 or newer). First sync
will download the Gradle 8.10.2 distribution and AGP 8.6.1. Then:

- Build → Make Project
- Run → Run 'app' on an emulator (API 26+) or connected device

`applicationId` is `com.taajsingh.gurbanilens` (placeholder — Deep to confirm
before any Play Store submission).

## Conventions

- **Matcher source of truth:** `core/gurbanilens/matcher.py` (Python). Any
  changes to algorithm or thresholds happen there first, then propagate to
  Swift (`ios/`) and Kotlin (`android/core/`). Port-parity tests guard drift.
- **Module:** pure-Kotlin `:core` is intentionally Android-API-free so the
  matcher stays JVM-portable. Don't add `androidx.*` deps to `:core`.
- **Compose:** Material 3, Compose BOM-managed versions.
