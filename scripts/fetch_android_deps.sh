#!/usr/bin/env bash
# fetch_android_deps.sh — populate the Android app's gitignored binary deps.
#
# Pulls three things into android/app/src/main/:
#   1. jniLibs/<abi>/libwhisper*.so   (prebuilt whisper.cpp JNI .so files)
#   2. assets/ggml-base.bin            (multilingual Whisper base model, ~148 MB)
#   3. assets/sggs.sqtte               (Sri Guru Granth Sahib corpus, copied
#                                       from data/sggs/database.sqlite)
#
# Re-runnable: skips downloads that are already present and pass a basic size
# sanity check. Pass --force to re-download everything.
#
# Run from anywhere; resolves paths relative to the repo root.
#
# Source: huggingface.co/ggerganov/whisper.cpp + GitHub release
# litongjava/whisper.cpp.android.java.demo v1.0.0.

set -euo pipefail

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_MAIN="${REPO_ROOT}/android/app/src/main"
JNILIBS_DIR="${APP_MAIN}/jniLibs"
ASSETS_DIR="${APP_MAIN}/assets"
CACHE_DIR="${REPO_ROOT}/build/android-deps-cache"

mkdir -p "$JNILIBS_DIR" "$ASSETS_DIR" "$CACHE_DIR"

WHISPER_MODEL_NAME="ggml-base.bin"
WHISPER_MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${WHISPER_MODEL_NAME}"
WHISPER_MODEL_MIN_BYTES=140000000   # ~148 MB; sanity check

WHISPER_SO_TAG="v1.0.0"
WHISPER_SO_ZIP_NAME="AndroidWhisperCppLibrary-stripped_native_libs.zip"
WHISPER_SO_ZIP_URL="https://github.com/litongjava/whisper.cpp.android.java.demo/releases/download/${WHISPER_SO_TAG}/${WHISPER_SO_ZIP_NAME}"
WHISPER_SO_ZIP_MIN_BYTES=3000000    # ~3.5 MB

SGGS_SOURCE="${REPO_ROOT}/data/sggs/database.sqlite"
SGGS_DEST="${ASSETS_DIR}/sggs.sqlite"

# ---------------------------------------------------------------- helpers --
log() { printf "==> %s\n" "$*"; }
warn() { printf "!!  %s\n" "$*" >&2; }
err()  { printf "XX  %s\n" "$*" >&2; exit 1; }

ensure_tool() {
  command -v "$1" >/dev/null 2>&1 || err "Required tool not found: $1"
}

filesize() {
  # Portable: prefer stat -c, fall back to wc -c.
  if stat -c%s "$1" >/dev/null 2>&1; then stat -c%s "$1"; else wc -c <"$1"; fi
}

# ---------------------------------------------------------------- ggml-base --
fetch_whisper_model() {
  local dest="${ASSETS_DIR}/${WHISPER_MODEL_NAME}"
  if [[ $FORCE -eq 0 && -f "$dest" && $(filesize "$dest") -ge $WHISPER_MODEL_MIN_BYTES ]]; then
    log "Whisper model already present at $dest ($(filesize "$dest") B) — skipping"
    return
  fi
  log "Downloading $WHISPER_MODEL_NAME from huggingface.co ..."
  curl -L --fail --progress-bar -o "${dest}.partial" "$WHISPER_MODEL_URL"
  local sz; sz=$(filesize "${dest}.partial")
  if [[ "$sz" -lt $WHISPER_MODEL_MIN_BYTES ]]; then
    rm -f "${dest}.partial"
    err "Downloaded ${WHISPER_MODEL_NAME} is only ${sz} B — expected ≥ ${WHISPER_MODEL_MIN_BYTES}. Likely an HTML error page."
  fi
  mv "${dest}.partial" "$dest"
  log "Saved $dest ($sz B)"
}

# ---------------------------------------------------------------- .so files --
fetch_whisper_sos() {
  local primary="${JNILIBS_DIR}/arm64-v8a/libwhisper.so"
  if [[ $FORCE -eq 0 && -f "$primary" && $(filesize "$primary") -ge 1000000 ]]; then
    log "Whisper .so libs already present (saw arm64-v8a/libwhisper.so) — skipping"
    return
  fi

  ensure_tool unzip
  local zip="${CACHE_DIR}/${WHISPER_SO_ZIP_NAME}"
  if [[ $FORCE -eq 1 || ! -f "$zip" || $(filesize "$zip") -lt $WHISPER_SO_ZIP_MIN_BYTES ]]; then
    log "Downloading $WHISPER_SO_ZIP_NAME from GitHub releases ($WHISPER_SO_TAG) ..."
    curl -L --fail --progress-bar -o "${zip}.partial" "$WHISPER_SO_ZIP_URL"
    local sz; sz=$(filesize "${zip}.partial")
    if [[ "$sz" -lt $WHISPER_SO_ZIP_MIN_BYTES ]]; then
      rm -f "${zip}.partial"
      err "Downloaded ${WHISPER_SO_ZIP_NAME} is only ${sz} B — expected ≥ ${WHISPER_SO_ZIP_MIN_BYTES}."
    fi
    mv "${zip}.partial" "$zip"
  else
    log "Cached $zip already present — skipping download"
  fi

  log "Extracting .so files into $JNILIBS_DIR ..."
  # The zip contains lib/<abi>/lib*.so paths. Strip the leading lib/ so the
  # tree lands directly under jniLibs/<abi>/.
  local tmp; tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  unzip -q -o "$zip" -d "$tmp"

  local extracted=0
  for src in $(find "$tmp" -type f -name "*.so" | sort); do
    # Extract the .../<abi>/libfoo.so tail
    local abi rel
    rel="${src#${tmp}/}"
    abi=$(basename "$(dirname "$rel")")
    case "$abi" in
      arm64-v8a|armeabi-v7a|x86|x86_64) ;;
      *) warn "skipping unknown ABI in zip: $abi ($rel)"; continue ;;
    esac
    mkdir -p "${JNILIBS_DIR}/${abi}"
    cp -f "$src" "${JNILIBS_DIR}/${abi}/"
    extracted=$((extracted + 1))
  done
  if [[ $extracted -eq 0 ]]; then
    err "No .so files extracted from $zip — archive layout may have changed"
  fi
  log "Extracted $extracted .so file(s)"
}

# ---------------------------------------------------------------- SGGS DB --
copy_sggs_db() {
  if [[ ! -f "$SGGS_SOURCE" ]]; then
    warn "SGGS source DB not found at $SGGS_SOURCE"
    warn "Run: python scripts/fetch_corpus.py"
    warn "(skipping — Android will fall back to an empty matcher)"
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
fetch_whisper_sos
copy_sggs_db

cat <<EOF

All Android deps in place:
  $(ls -lh "${ASSETS_DIR}/${WHISPER_MODEL_NAME}" 2>/dev/null | awk '{print $5, $NF}')
  $(ls -lh "${SGGS_DEST}"                       2>/dev/null | awk '{print $5, $NF}')
  $(find "$JNILIBS_DIR" -name "*.so" | wc -l) .so file(s) under $JNILIBS_DIR

Next: cd android && ./gradlew :app:assembleDebug
EOF
