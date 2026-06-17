#!/usr/bin/env bash
# Fetch a Whisper GGML model and convert its encoder to CoreML.
# Usage:  bash build/fetch_whisper_models.sh <size>
# <size> ∈ {tiny, base, small, medium, large-v3}

set -euo pipefail

SIZE="${1:-small}"
case "$SIZE" in
  tiny|base|small|medium|large-v3) ;;
  *) echo "Unknown model size: $SIZE. Use tiny/base/small/medium/large-v3." >&2; exit 2;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
WHISPER_DIR="${BUILD_DIR}/whisper.cpp"

if [ ! -d "$WHISPER_DIR" ]; then
  echo "Cloning whisper.cpp into $WHISPER_DIR ..."
  git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git "$WHISPER_DIR"
fi

cd "$WHISPER_DIR"

# 1. GGML weights
if [ ! -f "models/ggml-${SIZE}.bin" ]; then
  echo "Downloading ggml-${SIZE}.bin ..."
  bash models/download-ggml-model.sh "$SIZE"
else
  echo "ggml-${SIZE}.bin already present, skipping download."
fi

# 2. CoreML conversion
if [ ! -d "models/ggml-${SIZE}-encoder.mlmodelc" ]; then
  echo "Setting up Python venv for CoreML conversion ..."
  if [ ! -d ".coreml-venv" ]; then
    python3 -m venv .coreml-venv
  fi
  # shellcheck disable=SC1091
  source .coreml-venv/bin/activate
  pip install --upgrade pip --quiet
  pip install ane_transformers openai-whisper coremltools --quiet

  echo "Converting ${SIZE} encoder to CoreML (this can take 10-30 minutes) ..."
  bash models/generate-coreml-model.sh "$SIZE"

  deactivate
else
  echo "ggml-${SIZE}-encoder.mlmodelc already present, skipping conversion."
fi

echo ""
echo "Outputs:"
ls -lh "models/ggml-${SIZE}.bin" 2>/dev/null || echo "  (missing .bin)"
ls -ld "models/ggml-${SIZE}-encoder.mlmodelc" 2>/dev/null || echo "  (missing .mlmodelc)"

echo ""
echo "Next: copy into the iOS app bundle:"
echo "  mkdir -p ${REPO_ROOT}/ios/GurbaniLens/GurbaniLens/Resources/Models"
echo "  cp models/ggml-${SIZE}.bin                  ${REPO_ROOT}/ios/GurbaniLens/GurbaniLens/Resources/Models/"
echo "  cp -R models/ggml-${SIZE}-encoder.mlmodelc  ${REPO_ROOT}/ios/GurbaniLens/GurbaniLens/Resources/Models/"
