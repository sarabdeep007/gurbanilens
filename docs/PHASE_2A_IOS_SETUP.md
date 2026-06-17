# Phase 2A — iOS Setup (Deep)

This is the one-time setup to get the GurbaniLens iOS smoke test running on your iPhone with a free Apple ID. Total time: about 30–45 minutes the first run, including Xcode install.

## 0. Prerequisites

- **macOS 14 or later** (Sonoma / Sequoia / etc.)
- **Apple ID** — your existing personal Apple ID is fine. No paid Developer Program needed.
- An iPhone running iOS 15 or later (the deployment target)
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

## 3. Build the corpus database (once per release)

If you haven't already (it's in `.gitignore`):

```bash
cd build/
npm install
node convert_anmol_to_unicode.js
cd ..
python build/build_app_database.py
# Output: build/app_database.sqlite (~77 MB)
```

Copy it into the iOS app bundle's Resources folder:
```bash
mkdir -p ios/GurbaniLens/GurbaniLens/Resources/Database
cp build/app_database.sqlite ios/GurbaniLens/GurbaniLens/Resources/Database/
```

## 4. Bundle a Whisper model

Run the helper to fetch + CoreML-convert (~30 minutes the first time; large download + Apple Silicon ANE conversion):

```bash
bash build/fetch_whisper_models.sh small
```

This downloads `ggml-small.bin` (~250 MB) and produces `ggml-small-encoder.mlmodelc`. Copy both into the app bundle:

```bash
mkdir -p ios/GurbaniLens/GurbaniLens/Resources/Models
cp build/whisper-models/ggml-small.bin              ios/GurbaniLens/GurbaniLens/Resources/Models/
cp -R build/whisper-models/ggml-small-encoder.mlmodelc ios/GurbaniLens/GurbaniLens/Resources/Models/
```

Full Whisper + CoreML setup details (and how to switch to `base` or `medium`) are in [`docs/whisper_coreml_setup.md`](./whisper_coreml_setup.md).

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

## 9. The smoke test

You should see a screen titled "GurbaniLens Smoke Test" with:
- a **Status** line
- a **Best match** placeholder
- an empty **Transcript log**
- a big blue **Listen** button at the bottom

Tap **Listen**. iOS will prompt for microphone permission — tap "Allow".

Then start reciting any Bani slowly. Expected behaviour:
- Status changes to "Listening — Mic — ..."
- Within ~3 seconds, transcripts start appearing in the log (Devanagari text + Latin form)
- Within ~10 seconds, the "Best match" section shows an Ang:Pangti with green confidence
- The matched Pangti's Unicode Gurmukhi text appears

## 10. What to report back

Tell me:
1. Did the app build and install at all? If not, what's the Xcode error?
2. Does it load past "Loading corpus + matcher…"? If not, did you copy the SQLite into Resources/Database?
3. Does it load past "Loading Whisper model…"? If not, did you bundle the model into Resources/Models?
4. After tapping Listen, do transcripts show up in the log?
5. Do any transcripts produce a confident match (green confidence, ≥ 75)?
6. Any crashes, freezes, or weird logs from the Xcode console?

A screenshot of the running app + the Xcode console output is the perfect handoff back to me. Then we iterate.

## Free Apple ID limitations to know

- **7-day install lifetime.** Apps signed with a personal team expire after 7 days. Plug the phone in and re-run from Xcode (Cmd-R) to refresh.
- **Max 3 apps installed at a time** per Apple ID.
- **No TestFlight, no App Store distribution.** When your org Developer Program approval lands, switch the Team in Signing & Capabilities to the org team and these limits all go away.

## When the org Developer account lands

In Xcode → Signing & Capabilities, change the Team dropdown from "(Your Name)" to the org team. That's the only change required — no project file edits, no code changes.
