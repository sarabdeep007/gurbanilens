#!/usr/bin/env bash
# fetch_ios_deps.sh — populate the iOS app's gitignored binary deps.
#
# Default (no flags) only handles the SGGS corpus:
#   Data/app_database.sqlite  ← data/sggs/database.sqlite (~150 MB)
#
# With --bundle-model also pre-bundles the WhisperKit CoreML model so the
# first launch doesn't need network:
#   Models/openai_whisper-small/  ← huggingface.co/argmaxinc/whisperkit-coreml
#                                   /tree/main/openai_whisper-small
#                                   (~250 MB across multiple .mlmodelc dirs)
#
# Why two modes:
#   The previous dispatch's whisper.cpp wrapper expected a single
#   `ggml-small.bin` file. WhisperKit instead expects a *directory tree* of
#   CoreML models (AudioEncoder.mlmodelc, TextDecoder.mlmodelc,
#   MelSpectrogram.mlmodelc, + tokenizer json). WhisperKit will
#   auto-download that tree from huggingface.co on first app launch and
#   cache it in the app's Documents/Caches; bundling it just makes the
#   first launch offline-capable. v1 default is "let WhisperKit
#   auto-download" — pre-bundling is opt-in.
#
# Flags:
#   --bundle-model     also fetch the WhisperKit CoreML model tree
#   --model=NAME       override the WhisperKit model id (default
#                      openai_whisper-small)
#   --force            re-download / re-copy even if already present
#
# Source: github.com/argmaxinc/WhisperKit + huggingface.co/argmaxinc/
#         whisperkit-coreml

set -euo pipefail

FORCE=0
BUNDLE_MODEL=0
MODEL_NAME="openai_whisper-small"
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --bundle-model) BUNDLE_MODEL=1 ;;
    --model=*) MODEL_NAME="${arg#*=}" ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *)
      echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES_DIR="${REPO_ROOT}/ios/GurbaniLens/GurbaniLens/Resources"
MODELS_DIR="${RES_DIR}/Models"
DATA_DIR="${RES_DIR}/Data"
FONTS_DIR="${RES_DIR}/Fonts"
CACHE_DIR="${REPO_ROOT}/build/ios-deps-cache"

mkdir -p "$MODELS_DIR" "$DATA_DIR" "$FONTS_DIR" "$CACHE_DIR"

# ---------------------------------------------------------------- corpus --
SGGS_SOURCE="${REPO_ROOT}/data/sggs/database.sqlite"
# Bundle as app_database.sqlite so the Anvaad-augmented build pipeline's
# output (when it lands) is a drop-in replacement.
SGGS_DEST="${DATA_DIR}/app_database.sqlite"

# ---------------------------------------------------------------- model --
# argmaxinc CoreML repo layout (per huggingface.co/argmaxinc/whisperkit-coreml):
#   openai_whisper-small/
#     ├── AudioEncoder.mlmodelc/        (folder, multiple files)
#     ├── TextDecoder.mlmodelc/         (folder, multiple files)
#     ├── MelSpectrogram.mlmodelc/      (folder, multiple files)
#     ├── config.json
#     ├── generation_config.json
#     ├── tokenizer.json
#     └── ... (more tokenizer files)
WHISPERKIT_MODEL_REPO="argmaxinc/whisperkit-coreml"
WHISPERKIT_MODEL_TREE_BASE="https://huggingface.co/${WHISPERKIT_MODEL_REPO}/resolve/main/${MODEL_NAME}"

# ---------------------------------------------------------------- helpers --
log()  { printf "==> %s\n" "$*"; }
warn() { printf "!!  %s\n" "$*" >&2; }
err()  { printf "XX  %s\n" "$*" >&2; exit 1; }

ensure_tool() {
  command -v "$1" >/dev/null 2>&1 || err "Required tool not found: $1"
}

filesize() {
  if stat -c%s "$1" >/dev/null 2>&1; then stat -c%s "$1"
  elif stat -f%z "$1" >/dev/null 2>&1; then stat -f%z "$1"
  else wc -c <"$1"; fi
}

copy_sggs_db() {
  if [[ ! -f "$SGGS_SOURCE" ]]; then
    warn "SGGS source DB not found at $SGGS_SOURCE"
    warn "Run: python scripts/fetch_corpus.py"
    warn "(skipping — iOS will surface a clear bundle-missing error in AppContainer)"
    return
  fi
  if [[ $FORCE -eq 0 && -f "$SGGS_DEST" && $(filesize "$SGGS_DEST") -eq $(filesize "$SGGS_SOURCE") ]]; then
    log "SGGS DB already at $SGGS_DEST ($(filesize "$SGGS_DEST") B) — skipping"
    return
  fi
  log "Copying SGGS DB → $SGGS_DEST"
  cp -f "$SGGS_SOURCE" "$SGGS_DEST"
  log "Copied $(filesize "$SGGS_DEST") B"
}

# Use `huggingface-cli download` when available (handles LFS + directory
# layout cleanly). Otherwise fall back to git lfs clone, then git checkout
# only the requested model subdir.
fetch_whisperkit_model() {
  local dest="${MODELS_DIR}/${MODEL_NAME}"
  if [[ $FORCE -eq 0 && -d "$dest" && -d "${dest}/AudioEncoder.mlmodelc" ]]; then
    log "WhisperKit model already present at $dest — skipping"
    return
  fi
  rm -rf "$dest"
  mkdir -p "$dest"

  if command -v huggingface-cli >/dev/null 2>&1; then
    log "Downloading ${MODEL_NAME} via huggingface-cli ..."
    huggingface-cli download "$WHISPERKIT_MODEL_REPO" \
      --include "${MODEL_NAME}/*" \
      --local-dir "$MODELS_DIR" \
      --local-dir-use-symlinks False
    # huggingface-cli lays the tree out as MODELS_DIR/MODEL_NAME/...
    # — already where we want it.
  elif command -v git >/dev/null 2>&1; then
    log "huggingface-cli not found — falling back to git LFS clone (slower) ..."
    local tmp="${CACHE_DIR}/whisperkit-coreml"
    if [[ ! -d "$tmp/.git" ]]; then
      GIT_LFS_SKIP_SMUDGE=1 git clone "https://huggingface.co/${WHISPERKIT_MODEL_REPO}" "$tmp"
    fi
    ( cd "$tmp" && git lfs pull --include="${MODEL_NAME}/*" )
    cp -R "$tmp/${MODEL_NAME}/." "$dest/"
  else
    err "Need either huggingface-cli (pip install huggingface_hub) or git+git-lfs to fetch the WhisperKit model."
  fi

  # Sanity check
  if [[ ! -d "${dest}/AudioEncoder.mlmodelc" ]]; then
    err "Downloaded model at $dest is missing AudioEncoder.mlmodelc — layout may have changed upstream."
  fi
  log "WhisperKit model at $dest"
}

# -------------------------------------------------- noto serif gurmukhi --
#
# Variable Noto Serif Gurmukhi (a single TTF carrying the full weight
# axis) is bundled into Resources/Fonts/ so SwiftUI `Font.custom("Noto
# Serif Gurmukhi", size:)` resolves. Registered via UIAppFonts in
# project.yml. Source is google/fonts (the same repo Google Fonts the
# web service hosts) — OFL-1.1 licensed; Seva-compatible. The upstream
# filename has literal square brackets ("NotoSerifGurmukhi[wght].ttf")
# which are awkward in iOS bundle paths, so we rename on copy.
NOTO_FONT_URL="https://raw.githubusercontent.com/google/fonts/main/ofl/notoserifgurmukhi/NotoSerifGurmukhi%5Bwght%5D.ttf"
NOTO_LICENSE_URL="https://raw.githubusercontent.com/google/fonts/main/ofl/notoserifgurmukhi/OFL.txt"
NOTO_FONT_DEST="${FONTS_DIR}/NotoSerifGurmukhi-Variable.ttf"
NOTO_LICENSE_DEST="${FONTS_DIR}/NotoSerifGurmukhi-OFL.txt"

fetch_noto_font() {
  if [[ $FORCE -eq 0 && -f "$NOTO_FONT_DEST" && $(filesize "$NOTO_FONT_DEST") -gt 100000 ]]; then
    log "Noto Serif Gurmukhi already at $NOTO_FONT_DEST ($(filesize "$NOTO_FONT_DEST") B) — skipping"
    return
  fi
  log "Downloading Noto Serif Gurmukhi → $NOTO_FONT_DEST"
  curl -fSL --max-time 60 -o "$NOTO_FONT_DEST" "$NOTO_FONT_URL"
  curl -fSL --max-time 30 -o "$NOTO_LICENSE_DEST" "$NOTO_LICENSE_URL" \
    || warn "OFL.txt download failed — font itself OK"
  log "Noto Serif Gurmukhi at $NOTO_FONT_DEST ($(filesize "$NOTO_FONT_DEST") B)"
}

# ---------------------------------------------------------------- main --
ensure_tool curl

copy_sggs_db
fetch_noto_font
if [[ $BUNDLE_MODEL -eq 1 ]]; then
  fetch_whisperkit_model
fi

cat <<EOF

iOS deps in place:
  $(ls -lh "${SGGS_DEST}" 2>/dev/null | awk '{print $5, $NF}')
  $(ls -lh "${NOTO_FONT_DEST}" 2>/dev/null | awk '{print $5, $NF}')
EOF

if [[ $BUNDLE_MODEL -eq 1 ]]; then
  echo "  WhisperKit model: ${MODELS_DIR}/${MODEL_NAME}/"
else
  echo "  WhisperKit model: NOT bundled — will auto-download on first launch"
  echo "                    (run with --bundle-model to pre-bundle ~250 MB)"
fi

cat <<EOF

Next:
  cd ios/GurbaniLens
  rm -rf GurbaniLens.xcodeproj
  xcodegen generate
  open GurbaniLens.xcodeproj
EOF
