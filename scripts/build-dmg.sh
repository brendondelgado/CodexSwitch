#!/bin/bash
set -euo pipefail

# Build CodexSwitch.dmg for distribution
# Usage: ./scripts/build-dmg.sh
#
# Produces: build/CodexSwitch-{version}.dmg
# Requires: build-app.sh (invoked automatically)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_BUNDLE="$PROJECT_DIR/build/CodexSwitch.app"
DMG_DIR="$PROJECT_DIR/build/dmg-staging"

# Extract version from build-app.sh's Info.plist (after build)
get_version() {
    local plist="$APP_BUNDLE/Contents/Info.plist"
    if command -v /usr/libexec/PlistBuddy &>/dev/null; then
        /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null || echo "1.0.0"
    else
        echo "1.0.0"
    fi
}

# Step 1: Build the app bundle
echo "=== Building app bundle ==="
"$SCRIPT_DIR/build-app.sh"

VERSION="$(get_version)"
DMG_NAME="CodexSwitch-${VERSION}.dmg"
DMG_PATH="$PROJECT_DIR/build/$DMG_NAME"

echo ""
echo "=== Creating DMG (v${VERSION}) ==="

# Step 2: Prepare staging directory
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"

# Copy app bundle into staging
cp -R "$APP_BUNDLE" "$DMG_DIR/"

# Create Applications symlink for drag-to-install
ln -s /Applications "$DMG_DIR/Applications"

# Step 3: Create DMG
rm -f "$DMG_PATH"

echo "Packaging into $DMG_NAME..."
hdiutil create \
    -volname "CodexSwitch" \
    -srcfolder "$DMG_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"

# Clean up staging
rm -rf "$DMG_DIR"

echo ""
echo "=== DMG created ==="
echo "  File: $DMG_PATH"
echo "  Size: $(du -h "$DMG_PATH" | cut -f1)"
echo ""
echo "To install: open the DMG and drag CodexSwitch to Applications."
