# Whisper + CoreML conversion for GurbaniLens iOS

This documents the one-time setup to fetch a Whisper model and convert its encoder to CoreML so it runs on the Apple Neural Engine (3–5× faster than CPU on supported devices).

## What you end up with

For each model size (`base`, `small`, `medium`):

- `ggml-<size>.bin` — quantised GGML weights consumed by whisper.cpp at runtime. ~150 MB (base) / 250 MB (small) / 500 MB (medium).
- `ggml-<size>-encoder.mlmodelc` — compiled CoreML model for the encoder, used automatically by whisper.cpp when it sits next to the .bin.

Both files go into `ios/GurbaniLens/GurbaniLens/Resources/Models/`.

## Prerequisites

- macOS with Xcode installed (we use `xcrun coremlcompiler`)
- Python 3.10+ with venv
- About 4 GB of free disk for the conversion temporaries
- Ample patience — `medium` CoreML conversion can take 30 minutes on a base M1

## Quick start (the helper script)

```bash
bash build/fetch_whisper_models.sh small
```

This:
1. Clones `ggerganov/whisper.cpp` into `build/whisper.cpp/` (if not already there)
2. Downloads `ggml-small.bin` via the bundled `models/download-ggml-model.sh`
3. Runs `models/generate-coreml-model.sh small` which:
   - Creates a Python venv
   - Installs `ane_transformers`, `openai-whisper`, `coremltools` (Apple's official toolchain)
   - Loads the small Whisper checkpoint
   - Converts the encoder to a `.mlpackage`
   - Compiles to `.mlmodelc` via `xcrun coremlcompiler`
4. Leaves outputs in `build/whisper.cpp/models/`

Copy into the app bundle:
```bash
mkdir -p ios/GurbaniLens/GurbaniLens/Resources/Models
cp build/whisper.cpp/models/ggml-small.bin                  ios/GurbaniLens/GurbaniLens/Resources/Models/
cp -R build/whisper.cpp/models/ggml-small-encoder.mlmodelc  ios/GurbaniLens/GurbaniLens/Resources/Models/
```

## Manual procedure (in case the helper script breaks)

1. Clone whisper.cpp:
   ```bash
   git clone https://github.com/ggerganov/whisper.cpp.git build/whisper.cpp
   cd build/whisper.cpp
   ```

2. Download the GGML weights:
   ```bash
   bash models/download-ggml-model.sh small
   ```

3. Set up the conversion venv:
   ```bash
   python3 -m venv .coreml-venv
   source .coreml-venv/bin/activate
   pip install -U pip
   pip install ane_transformers openai-whisper coremltools
   ```

4. Run the conversion (this is what `generate-coreml-model.sh` does):
   ```bash
   bash models/generate-coreml-model.sh small
   ```

5. Verify outputs:
   ```bash
   ls -lh models/ggml-small.bin models/ggml-small-encoder.mlmodelc
   ```

## Switching the bundled model

The smoke-test `SmokeTestViewModel.findBundledModel()` looks for `ggml-small`, `ggml-base`, `ggml-medium` (in that order). To switch, just place a different model's pair into `Resources/Models/`. No code change needed.

## Settings UI flow (Phase 2A step 9)

We'll surface model selection in the Settings screen:
- Pre-bundled: small (default)
- "Download base (faster, lower quality)" — pulls from server CDN, ~150 MB
- "Download medium (slower, higher quality)" — ~500 MB
- "Download large-v3 (best, much slower)" — ~1.5 GB, big battery + heat warning

The downloaded model files live in the app's documents directory, not the bundle, so we don't bloat the .ipa.

## Known issues

- **`coremltools` Python version constraints.** It generally requires Python 3.10 or 3.11. If you hit "no compatible version found" on `pip install`, switch to a Python 3.11 venv.
- **Apple Silicon required for CoreML conversion.** Intel Macs can still run whisper.cpp at runtime but can't generate the .mlmodelc. Use a colleague's M-series Mac if needed.
- **`large-v3` CoreML conversion is fiddly.** Community reports suggest 30–60% success rate; sometimes hits unsupported ops. If you need large-v3 and conversion fails, ship the `.bin` alone — whisper.cpp falls back to GPU/CPU and is still usable, just slower.
