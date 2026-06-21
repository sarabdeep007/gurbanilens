#!/usr/bin/env bash
#
# inject_env_to_plist.sh — read SARVAM_API_KEY + GEMINI_API_KEY from the
# repo-root .env file and write them as string entries into the built
# app's Info.plist so SarvamProvider + GeminiProvider can read them via
# `Bundle.main.object(forInfoDictionaryKey:)` at runtime.
#
# Wired as a postBuildScript in ios/GurbaniLens/project.yml. Runs after
# Copy Bundle Resources (so the built Info.plist already exists) and
# before code signing (so the signature covers our additions).
#
# Behaviour:
#   - .env missing            → emit a warning, do nothing (the providers
#                              throw "missing key" at start time, user
#                              falls back to WhisperKit via Settings)
#   - key missing in .env     → skip that key only
#   - empty value             → skip
#   - either key set          → PlistBuddy Add (or Set if already there)
#
# Never commits keys back to the repo. .env is in .gitignore.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

# In a build phase Xcode provides BUILT_PRODUCTS_DIR + INFOPLIST_PATH.
# Allow an override for manual testing outside Xcode.
if [ -n "$INFO_PLIST_PATH_OVERRIDE" ]; then
    INFO_PLIST="$INFO_PLIST_PATH_OVERRIDE"
elif [ -n "$BUILT_PRODUCTS_DIR" ] && [ -n "$INFOPLIST_PATH" ]; then
    INFO_PLIST="$BUILT_PRODUCTS_DIR/$INFOPLIST_PATH"
else
    echo "warning: inject_env_to_plist.sh: BUILT_PRODUCTS_DIR / INFOPLIST_PATH not set; pass INFO_PLIST_PATH_OVERRIDE when running outside Xcode."
    exit 0
fi

if [ ! -f "$INFO_PLIST" ]; then
    echo "warning: inject_env_to_plist.sh: Info.plist not found at $INFO_PLIST — skipping cloud key injection"
    exit 0
fi

if [ ! -f "$ENV_FILE" ]; then
    echo "warning: inject_env_to_plist.sh: $ENV_FILE not found — copy .env.example to .env and populate SARVAM_API_KEY / GEMINI_API_KEY to enable cloud providers."
    exit 0
fi

# Parse .env. Trivial KEY=VALUE; ignore comments + blanks. No quote handling
# beyond stripping a single pair of surrounding quotes; keys with literal
# embedded newlines or unescaped = chars are not supported.
SARVAM_API_KEY=""
GEMINI_API_KEY=""
while IFS= read -r line || [ -n "$line" ]; do
    # Strip CRLF
    line="${line%$'\r'}"
    # Skip blanks + comments
    case "$line" in
        ''|'#'*) continue ;;
    esac
    # Split on first =
    key="${line%%=*}"
    value="${line#*=}"
    # Trim leading + trailing whitespace from key
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    # Strip surrounding single OR double quotes from value
    case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    case "$key" in
        SARVAM_API_KEY) SARVAM_API_KEY="$value" ;;
        GEMINI_API_KEY) GEMINI_API_KEY="$value" ;;
    esac
done < "$ENV_FILE"

inject_key() {
    local plist_key="$1"
    local plist_value="$2"
    if [ -z "$plist_value" ]; then
        echo "note: inject_env_to_plist.sh: $plist_key not set in .env — skipping"
        return 0
    fi
    if /usr/libexec/PlistBuddy -c "Add :$plist_key string $plist_value" "$INFO_PLIST" 2>/dev/null; then
        echo "note: inject_env_to_plist.sh: injected $plist_key (len=${#plist_value})"
    else
        /usr/libexec/PlistBuddy -c "Set :$plist_key $plist_value" "$INFO_PLIST"
        echo "note: inject_env_to_plist.sh: replaced $plist_key (len=${#plist_value})"
    fi
}

inject_key "SARVAM_API_KEY" "$SARVAM_API_KEY"
inject_key "GEMINI_API_KEY" "$GEMINI_API_KEY"

echo "note: inject_env_to_plist.sh complete (plist=$INFO_PLIST)"
