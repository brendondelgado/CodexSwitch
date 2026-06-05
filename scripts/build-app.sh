#!/bin/bash
set -euo pipefail

# Build CodexSwitch.app bundle from SPM
# Usage: ./scripts/build-app.sh [--install]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_NAME="CodexSwitch"
APP_BUNDLE="$PROJECT_DIR/build/${APP_NAME}.app"
IDENTIFIER="com.codexswitch"
APP_VERSION="${CODEXSWITCH_VERSION:-1.0.0}"
BUILD_NUMBER="${CODEXSWITCH_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
SOURCE_REVISION="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

select_codesign_identity() {
    if [[ -n "${CODEXSWITCH_CODESIGN_IDENTITY:-}" ]]; then
        printf '%s\n' "$CODEXSWITCH_CODESIGN_IDENTITY"
        return
    fi
    if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
        printf '%s\n' "$CODESIGN_IDENTITY"
        return
    fi

    local identities
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    local preferred
    preferred="$(printf '%s\n' "$identities" | sed -nE 's/.*"((Developer ID Application|Apple Development|Mac Developer)[^"]+)".*/\1/p' | head -n 1)"
    if [[ -n "$preferred" ]]; then
        printf '%s\n' "$preferred"
    else
        printf '%s\n' "-"
    fi
}

cd "$PROJECT_DIR"

echo "Building ${APP_NAME} (release)..."
swift_build_flags=()
if [[ "${CODEXSWITCH_SWIFTPM_DISABLE_SANDBOX:-0}" == "1" ]]; then
    swift_build_flags+=(--disable-sandbox)
fi
if [[ -n "${CODEXSWITCH_SWIFTPM_CACHE_PATH:-}" ]]; then
    swift_build_flags+=(--cache-path "$CODEXSWITCH_SWIFTPM_CACHE_PATH")
fi
if (( ${#swift_build_flags[@]} )); then
    swift build -c release "${swift_build_flags[@]}" --quiet
else
    swift build -c release --quiet
fi

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
cp "$PROJECT_DIR/scripts/patch-asar.py" "$APP_BUNDLE/Contents/Resources/"

# Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>CodexSwitch</string>
    <key>CFBundleDisplayName</key>
    <string>CodexSwitch</string>
    <key>CFBundleIdentifier</key>
    <string>com.codexswitch</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleSourceRevision</key>
    <string>${SOURCE_REVISION}</string>
    <key>CFBundleExecutable</key>
    <string>CodexSwitch</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

# Generate app icon from SF Symbol using Python + AppKit
python3 - "$APP_BUNDLE/Contents/Resources" << 'PYEOF'
import subprocess, sys, os

out_dir = sys.argv[1]
iconset = os.path.join(out_dir, "AppIcon.iconset")
os.makedirs(iconset, exist_ok=True)

# Generate icon PNGs using sips-compatible approach:
# Render a bolt.fill SF Symbol via AppKit
script = '''
import AppKit
import sys

def render_icon(size, scale, path):
    px = int(size * scale)
    img = AppKit.NSImage.alloc().initWithSize_((px, px))
    img.lockFocus()

    # Background circle
    ctx = AppKit.NSGraphicsContext.currentContext().CGContext()
    import Quartz
    Quartz.CGContextSetRGBFillColor(ctx, 0.18, 0.18, 0.22, 1.0)
    Quartz.CGContextFillEllipseInRect(ctx, ((0, 0), (px, px)))

    # Bolt symbol
    config = AppKit.NSImage.SymbolConfiguration.configurationWithPointSize_weight_scale_(
        px * 0.45, AppKit.NSFont.Weight(0.4), 2  # semibold, large
    )
    symbol = AppKit.NSImage.imageWithSystemSymbolName_accessibilityDescription_("bolt.fill", None)
    if symbol:
        symbol = symbol.imageWithSymbolConfiguration_(config)
        sym_size = symbol.size()
        x = (px - sym_size.width) / 2
        y = (px - sym_size.height) / 2
        symbol.drawInRect_fromRect_operation_fraction_(
            ((x, y), (sym_size.width, sym_size.height)),
            AppKit.NSZeroRect,
            AppKit.NSCompositingOperationSourceOver,
            1.0
        )
        # Tint green by drawing over with source-atop
        AppKit.NSColor.systemGreenColor().set()
        AppKit.NSBezierPath.fillRect_(((x, y), (sym_size.width, sym_size.height)))

    img.unlockFocus()

    tiff = img.TIFFRepresentation()
    rep = AppKit.NSBitmapImageRep.imageRepWithData_(tiff)
    png = rep.representationUsingType_properties_(AppKit.NSBitmapImageRep.FileType.PNG, {})
    with open(path, "wb") as f:
        f.write(png)

sizes = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]
iconset_dir = sys.argv[1]
for size, scale in sizes:
    suffix = f"_{size}x{size}@2x.png" if scale == 2 else f"_{size}x{size}.png"
    name = f"icon{suffix}"
    path = iconset_dir + "/" + name
    render_icon(size, scale, path)
    print(f"  Generated {name}")
'''

# Run icon generation
result = subprocess.run(
    [sys.executable, "-c", script, iconset],
    capture_output=True, text=True
)
if result.stdout:
    print(result.stdout, end='')
if result.returncode != 0:
    print(f"Warning: Icon generation failed: {result.stderr}", file=sys.stderr)
    # Create a minimal icon fallback
    sys.exit(0)

# Convert iconset to icns
result = subprocess.run(
    ["iconutil", "-c", "icns", iconset, "-o", os.path.join(out_dir, "AppIcon.icns")],
    capture_output=True, text=True
)
if result.returncode == 0:
    print("  Created AppIcon.icns")
    import shutil
    shutil.rmtree(iconset)
else:
    print(f"Warning: iconutil failed: {result.stderr}", file=sys.stderr)
PYEOF

# Sign the app. Prefer a real Apple signing identity when Xcode has installed
# a certificate plus private key in Keychain; otherwise fall back to ad-hoc.
SIGN_IDENTITY="$(select_codesign_identity)"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "Signing app with ad-hoc fallback (no usable code-signing identity found)"
else
    echo "Signing app with identity: $SIGN_IDENTITY"
fi
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE" 2>/dev/null || true

echo ""
echo "Built: $APP_BUNDLE"
echo ""

# Install if requested
if [[ "${1:-}" == "--install" ]]; then
    INSTALL_PATH="/Applications/${APP_NAME}.app"
    echo "Installing to $INSTALL_PATH..."
    rm -rf "$INSTALL_PATH"
    cp -R "$APP_BUNDLE" "$INSTALL_PATH"
    echo "Installed. You can now:"
    echo "  - Find it in /Applications"
    echo "  - Drag it to your Dock"
    echo "  - Launch at Login is in Settings (already built in)"
fi
