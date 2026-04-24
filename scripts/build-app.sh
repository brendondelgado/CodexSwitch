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

# Bundle the desktop patcher used by CodexAutoPatchMonitor. Keeping this inside
# the installed app avoids depending on whichever checkout happens to exist.
cp "$PROJECT_DIR/scripts/patch-asar.py" "$APP_BUNDLE/Contents/Resources/patch-asar.py"
chmod 755 "$APP_BUNDLE/Contents/Resources/patch-asar.py"

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
    print(f"Warning: AppKit icon generation failed, using fallback icon: {result.stderr}", file=sys.stderr)

    import struct
    import zlib

    def write_png(path, width, height):
        rows = []
        for y in range(height):
            row = bytearray()
            for x in range(width):
                dx = (x + 0.5 - width / 2) / (width / 2)
                dy = (y + 0.5 - height / 2) / (height / 2)
                inside = dx * dx + dy * dy <= 0.82
                if inside:
                    row.extend((54, 211, 92, 255))
                else:
                    row.extend((35, 36, 43, 255))
            rows.append(b"\x00" + bytes(row))

        raw = b"".join(rows)

        def chunk(kind, data):
            return (
                struct.pack(">I", len(data))
                + kind
                + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
            )

        png = (
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b"")
        )
        with open(path, "wb") as f:
            f.write(png)

    fallback_sizes = [
        (16, 1), (16, 2),
        (32, 1), (32, 2),
        (128, 1), (128, 2),
        (256, 1), (256, 2),
        (512, 1), (512, 2),
    ]
    for size, scale in fallback_sizes:
        px = int(size * scale)
        suffix = f"_{size}x{size}@2x.png" if scale == 2 else f"_{size}x{size}.png"
        name = f"icon{suffix}"
        write_png(os.path.join(iconset, name), px, px)
        print(f"  Generated fallback {name}")

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
