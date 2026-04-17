#!/bin/bash
# Build CodexNative.app — the native macOS replacement for Codex Electron
set -euo pipefail

APP_NAME="CodexNative"
APP_DIR="/Applications/$APP_NAME.app"
BUILD_DIR=".build/release"

echo "=== Building $APP_NAME ==="

# 1. Ensure React frontend is extracted
if [ ! -f "Sources/CodexNative/Resources/codex-web/index.html" ]; then
    echo "Extracting React frontend..."
    ./scripts/extract-codex-frontend.sh
fi

# 2. Build the Swift binary
swift build -c release --target CodexNative

# 3. Create app bundle
echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/CodexNative" "$APP_DIR/Contents/MacOS/CodexNative"

# Copy resources
cp -r Sources/CodexNative/Resources/codex-web "$APP_DIR/Contents/Resources/"
cp Sources/CodexNative/Resources/preload-shim.js "$APP_DIR/Contents/Resources/"

# Find and copy the codex binary for the app-server
CODEX_BIN=$(which codex 2>/dev/null || echo "/opt/homebrew/bin/codex")
if [ -f "$CODEX_BIN" ]; then
    cp "$CODEX_BIN" "$APP_DIR/Contents/Resources/codex"
    chmod 755 "$APP_DIR/Contents/Resources/codex"
fi

# Write Info.plist
cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>CodexNative</string>
    <key>CFBundleIdentifier</key>
    <string>com.codexswitch.native</string>
    <key>CFBundleName</key>
    <string>CodexNative</string>
    <key>CFBundleDisplayName</key>
    <string>Codex</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Codex uses the microphone for voice input.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

# 4. Code sign
codesign --force --deep --sign - "$APP_DIR"
xattr -cr "$APP_DIR"

echo "=== Built: $APP_DIR ==="
echo "Bundle size: $(du -sh "$APP_DIR" | cut -f1)"
echo "Run: open -a $APP_NAME"
