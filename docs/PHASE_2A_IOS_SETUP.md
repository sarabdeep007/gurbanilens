# Phase 2A — iOS Setup (Deep)

This is the one-time setup to get the GurbaniLens iOS app (v1 voice-search) running on your iPhone with a free Apple ID. Total time: about 30–45 minutes the first run, including Xcode install.

> **v1 voice-search delta (2026-06-17).** The app now launches into the v1 voice-search UI (Home → Recording → Results → Shabad → Settings) instead of the original Smoke Test. The Smoke Test view (continuous listen + scrolling transcript) is still in the source tree as the v2 reference but is no longer the entry point. See §9 for the new expected behaviour.

## 0. Prerequisites

- **macOS 14 or later** (Sonoma / Sequoia / etc.)
- **Apple ID** — your existing personal Apple ID is fine. No paid Developer Program needed.
- An iPhone running iOS 16 or later (v1 deployment target — needed for `NavigationStack` and `ShareLink`)
- USB-C / Lightning cable to plug the phone into the Mac

## 1. Install Xcode (full, not just Command Line Tools)

Xcode Command Line Tools won't sign apps for on-device install. You need the full Xcode app.

```bash
# Option A — App Store (slowest, ~10+ GB, easiest)
# Open the App Store, search "Xcode", install, then launch once to accept licences.

# Option B — direct download from developer.apple.com/download
# (faster on a fast connection; needs an Apple ID sign-in)
```

After install, run once and accept the licence + install additional components:

```bash
sudo xcodebuild -license accept
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

Verify:
```bash
xcodebuild -version
# Should print something like: Xcode 15.x, Build version 15Cxxx
```

## 2. Install XcodeGen

XcodeGen lets us generate the `.xcodeproj` from `ios/GurbaniLens/project.yml`. The project file isn't checked in (it churns a lot in git; XcodeGen-from-YAML is the convention).

```bash
brew install xcodegen
```

## 3. Fetch the bundled binary deps

Single re-runnable script that downloads the Whisper model and copies the SGGS corpus into the app's Resources folder (both gitignored):

```bash
bash scripts/fetch_ios_deps.sh
# Default: --model small (~250 MB). Override with --model base, --model medium, etc.
```

What it does:
- Downloads `ggml-small.bin` from `huggingface.co/ggerganov/whisper.cpp` → `ios/GurbaniLens/GurbaniLens/Resources/Models/`
- Copies `data/sggs/database.sqlite` → `ios/GurbaniLens/GurbaniLens/Resources/Data/app_database.sqlite`

If `data/sggs/database.sqlite` is missing first, populate it with the existing Python helper (one-time, ~30 s download):
```bash
python scripts/fetch_corpus.py
```

> **CoreML acceleration (optional, slower setup).** For the Apple Neural Engine encoder bump, `build/fetch_whisper_models.sh small` does the full CoreML conversion (~30 min on Apple Silicon). Drop the resulting `ggml-small-encoder.mlmodelc` into the same Models folder. v1 runs fine without it; the CPU path is plenty for tap-to-speak. Full details in [`docs/whisper_coreml_setup.md`](./whisper_coreml_setup.md).

## 5. Generate the Xcode project

```bash
cd ios/GurbaniLens
xcodegen generate
# Output: GurbaniLens.xcodeproj
open GurbaniLens.xcodeproj
```

Xcode will resolve the `GurbaniLensCore` (sibling SPM) and `whisper.cpp` (remote) packages on first open. The status bar at the top of Xcode shows progress; wait until "Package resolution" finishes.

## 6. Sign with your free Apple ID

In Xcode:

1. Click the **GurbaniLens** target in the left sidebar (top of the file list).
2. Open the **Signing & Capabilities** tab.
3. Tick **"Automatically manage signing"**.
4. In the **Team** dropdown, pick **(Your Name)** — the free / "Personal Team" entry. (If your Apple Developer org account approval lands later, this dropdown will list the org team too — just switch to it.)
5. Confirm the bundle identifier reads `com.taajstudios.gurbanilens`. If a duplicate is rejected (free Apple IDs can't share bundle IDs across two Macs), append your initials: `com.taajstudios.gurbanilens.deep`.

## 7. Enable Developer Mode on the iPhone

Plug your iPhone in. Trust the computer if prompted.

On iOS 16+: **Settings → Privacy & Security → Developer Mode → On.** The phone reboots. After reboot, confirm Developer Mode.

## 8. Run

Back in Xcode:
1. From the top toolbar, choose your iPhone as the run destination (where it currently says "iPhone 15 Pro" simulator or similar).
2. Hit **Cmd-R**.
3. First build takes a couple of minutes (whisper.cpp compiles).
4. The first install on the phone will ask you to trust the developer in **Settings → General → VPN & Device Management → Apple Development: (Your Apple ID) → Trust.**
5. The app launches.

## 9. The v1 voice-search flow

You should see a saffron-on-indigo Home screen with:
- Title: **GurbaniLens** (gear icon to Settings in the top-right)
- Tagline: *Bring the Bani into focus.*
- A big circular saffron **mic button**

Tap the mic. iOS will prompt for microphone permission the first time — tap "Allow". Then:

- The Recording screen pushes in — pulsing saffron mic, "Listening…" label
- Recite any Pangti aloud (5–15 s is the v1 sweet spot)
- Tap **Done** → "Transcribing…" briefly → auto-advances to Results
- Results shows the Pangti you said (monospaced), a confidence pill, the top match card (Ang:Pangti + transliteration), and up to 4 "Did you mean…" alternates
- Tap the top match → Shabad screen shows the full Shabad scrolled to the matched line; toggles for script (Gurmukhi / Transliteration / Both) + English

## 10. What to report back

Tell me:
1. Did the app build and install at all? If not, what's the Xcode error?
2. Does the Home → Recording transition happen on tap?
3. Does the mic VU bar (the pulsing saffron circle) actually respond to your voice volume?
4. After "Done", does Results show a confidence pill and at least one match card?
5. Do confident recitations produce a "Strong match" (green pill)?
6. Tap a match — does the Shabad screen scroll to the matched line and show the full Shabad?
7. Any crashes, freezes, or weird logs from the Xcode console?

A screenshot of the running app + the Xcode console output is the perfect handoff back. Then we iterate.

## Free Apple ID limitations to know

- **7-day install lifetime.** Apps signed with a personal team expire after 7 days. Plug the phone in and re-run from Xcode (Cmd-R) to refresh.
- **Max 3 apps installed at a time** per Apple ID.
- **No TestFlight, no App Store distribution.** When your org Developer Program approval lands, switch the Team in Signing & Capabilities to the org team and these limits all go away.

## When the org Developer account lands

In Xcode → Signing & Capabilities, change the Team dropdown from "(Your Name)" to the org team. That's the only change required — no project file edits, no code changes.
