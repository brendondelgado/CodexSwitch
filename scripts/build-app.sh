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

cd "$PROJECT_DIR"

echo "Building ${APP_NAME} (release)..."
swift build -c release --quiet

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
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
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
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

# Sign the app (ad-hoc for local use)
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true

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
