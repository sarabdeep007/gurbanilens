#!/usr/bin/env bash
# fetch_ios_deps.sh — populate the iOS app's gitignored binary deps.
#
# Pulls two things into ios/GurbaniLens/GurbaniLens/Resources/:
#   1. Models/ggml-small.bin   (~248 MB Whisper multilingual small)
#   2. Data/app_database.sqlite (SGGS corpus, copied from
#                                data/sggs/database.sqlite)
#
# Re-runnable: skips downloads that are already present and pass a basic size
# sanity check. Pass --force to re-download.
#
# Pass --model {tiny|base|small|medium|large-v3} to override the default
# (small). Larger models give better accuracy at the cost of bundle size —
# Phase 1 finding: spoken Punjabi recitation on `large-v3` scored 96.6 on
# Japji. `small` is the v1 default ship.
#
# Run from anywhere; resolves paths relative to the repo root.
#
# Source: huggingface.co/ggerganov/whisper.cpp

set -euo pipefail

FORCE=0
MODEL_SIZE="small"
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --model=*) MODEL_SIZE="${arg#*=}" ;;
    --model)   shift; MODEL_SIZE="${1:-small}" ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *)
      echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

case "$MODEL_SIZE" in
  tiny|base|small|medium|large-v3) ;;
  *) echo "Unknown model size: $MODEL_SIZE" >&2; exit 2;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES_DIR="${REPO_ROOT}/ios/GurbaniLens/GurbaniLens/Resources"
MODELS_DIR="${RES_DIR}/Models"
DATA_DIR="${RES_DIR}/Data"
CACHE_DIR="${REPO_ROOT}/build/ios-deps-cache"

mkdir -p "$MODELS_DIR" "$DATA_DIR" "$CACHE_DIR"

# ---------------------------------------------------------------- model --
WHISPER_MODEL_NAME="ggml-${MODEL_SIZE}.bin"
WHISPER_MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${WHISPER_MODEL_NAME}"
# Min-size sanity checks per model so we catch HTML error pages.
case "$MODEL_SIZE" in
  tiny)     WHISPER_MODEL_MIN_BYTES=35000000 ;;
  base)     WHISPER_MODEL_MIN_BYTES=140000000 ;;
  small)    WHISPER_MODEL_MIN_BYTES=460000000 ;;
  medium)   WHISPER_MODEL_MIN_BYTES=1400000000 ;;
  large-v3) WHISPER_MODEL_MIN_BYTES=2900000000 ;;
esac

# ---------------------------------------------------------------- corpus --
SGGS_SOURCE="${REPO_ROOT}/data/sggs/database.sqlite"
# Use app_database.sqlite as the bundled name (matches the Anvaad-augmented
# build pipeline output — once that lands, the app will pick it up without
# touching code, since AppContainer searches for app_database, sggs, or
# database in order).
SGGS_DEST="${DATA_DIR}/app_database.sqlite"

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

fetch_whisper_model() {
  local dest="${MODELS_DIR}/${WHISPER_MODEL_NAME}"
  if [[ $FORCE -eq 0 && -f "$dest" && $(filesize "$dest") -ge $WHISPER_MODEL_MIN_BYTES ]]; then
    log "Whisper model already present at $dest ($(filesize "$dest") B) — skipping"
    return
  fi
  log "Downloading $WHISPER_MODEL_NAME from huggingface.co (~$((WHISPER_MODEL_MIN_BYTES/1024/1024)) MB) ..."
  curl -L --fail --progress-bar -o "${dest}.partial" "$WHISPER_MODEL_URL"
  local sz; sz=$(filesize "${dest}.partial")
  if [[ "$sz" -lt $WHISPER_MODEL_MIN_BYTES ]]; then
    rm -f "${dest}.partial"
    err "Downloaded ${WHISPER_MODEL_NAME} is only ${sz} B — expected ≥ ${WHISPER_MODEL_MIN_BYTES}. Likely an HTML error page."
  fi
  mv "${dest}.partial" "$dest"
  log "Saved $dest ($sz B)"
}

copy_sggs_db() {
  if [[ ! -f "$SGGS_SOURCE" ]]; then
    warn "SGGS source DB not found at $SGGS_SOURCE"
    warn "Run: python scripts/fetch_corpus.py"
    warn "(skipping — iOS will fall back to bundled-asset error in AppContainer)"
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

# ---------------------------------------------------------------- main --
ensure_tool curl

fetch_whisper_model
copy_sggs_db

cat <<EOF

iOS deps in place:
  $(ls -lh "${MODELS_DIR}/${WHISPER_MODEL_NAME}" 2>/dev/null | awk '{print $5, $NF}')
  $(ls -lh "${SGGS_DEST}"                       2>/dev/null | awk '{print $5, $NF}')

Next:
  cd ios/GurbaniLens
  xcodegen generate
  open GurbaniLens.xcodeproj
EOF
