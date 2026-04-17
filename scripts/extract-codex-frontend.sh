#!/bin/bash
# Extract React frontend from Codex.app for CodexNative
set -euo pipefail

CODEX_APP="${CODEX_APP:-/Applications/Codex.app}"
ASAR="$CODEX_APP/Contents/Resources/app.asar"
OUTPUT="${1:-Sources/CodexNative/Resources/codex-web}"

if [ ! -f "$ASAR" ]; then
    echo "ERROR: $ASAR not found. Install Codex.app first."
    exit 1
fi

echo "Extracting from $ASAR..."

# Create temp dir for extraction
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Extract asar
npx --yes asar extract "$ASAR" "$TMPDIR/extracted"

# Clear existing output (except .gitkeep)
find "$OUTPUT" -mindepth 1 -not -name '.gitkeep' -delete 2>/dev/null || true
mkdir -p "$OUTPUT/assets"

# Copy webview assets (the React frontend)
cp -r "$TMPDIR/extracted/webview/"* "$OUTPUT/"

# Read Codex version
VERSION=$(defaults read "$CODEX_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "unknown")
BUILD=$(defaults read "$CODEX_APP/Contents/Info" CFBundleVersion 2>/dev/null || echo "unknown")

# Write version marker
echo "{\"version\": \"$VERSION\", \"build\": \"$BUILD\", \"extracted_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$OUTPUT/codex-version.json"

echo "Frontend extracted: Codex $VERSION (build $BUILD)"
echo "Output: $OUTPUT"
echo "Assets: $(ls "$OUTPUT/assets/" | wc -l | tr -d ' ') files"
