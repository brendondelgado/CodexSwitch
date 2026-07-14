#!/bin/bash
set -euo pipefail

# Build CodexSwitch.app bundle from SPM
# Usage: ./scripts/build-app.sh [--install]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_CONFIGURATION="${CODEXSWITCH_BUILD_CONFIGURATION:-release}"
case "$BUILD_CONFIGURATION" in
    debug|release) ;;
    *)
        echo "error: CODEXSWITCH_BUILD_CONFIGURATION must be debug or release" >&2
        exit 2
        ;;
esac
APP_NAME="CodexSwitch"
BUILD_DIR="$PROJECT_DIR/.build/$BUILD_CONFIGURATION"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"
APP_BUNDLE="$PROJECT_DIR/build/${APP_NAME}.app"
APP_VERSION="${CODEXSWITCH_VERSION:-1.0.0}"
BUILD_NUMBER="${CODEXSWITCH_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"

source_tree_fingerprint() {
    python3 - "$PROJECT_DIR" <<'PYEOF'
import hashlib
from pathlib import Path
import sys

root = Path(sys.argv[1])
paths = [path for path in (root / "Sources").rglob("*") if path.is_file()]
paths.extend([root / "Package.swift", root / "scripts" / "patch-asar.py"])

digest = hashlib.sha256()
for path in sorted(paths, key=lambda item: item.relative_to(root).as_posix()):
    relative = path.relative_to(root).as_posix().encode()
    digest.update(relative)
    digest.update(b"\0")
    digest.update(path.read_bytes())
    digest.update(b"\0")
print(digest.hexdigest()[:12])
PYEOF
}

source_revision() {
    if [[ -n "${CODEXSWITCH_SOURCE_REVISION:-}" ]]; then
        printf '%s\n' "$CODEXSWITCH_SOURCE_REVISION"
        return
    fi

    local commit
    commit="$(git -C "$PROJECT_DIR" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
    if [[ -n "$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
        printf '%s-dirty.%s\n' "$commit" "$(source_tree_fingerprint)"
    else
        printf '%s\n' "$commit"
    fi
}

SOURCE_REVISION="$(source_revision)"

select_codesign_identity() {
    if [[ -n "${CODEXSWITCH_CODESIGN_IDENTITY:-}" ]]; then
        printf '%s\n' "$CODEXSWITCH_CODESIGN_IDENTITY"
        return
    fi
    if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
        printf '%s\n' "$CODESIGN_IDENTITY"
        return
    fi

    local patcher="$PROJECT_DIR/scripts/patch-asar.py"
    if [[ -f "$patcher" ]]; then
        local selected
        selected="$(python3 "$patcher" --repair-codesign-identity 2>/dev/null | tail -n 1 || true)"
        if [[ -n "$selected" && "$selected" != "-" ]]; then
            printf '%s\n' "$selected"
            return
        fi
    fi

    local identities
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    local preferred
    preferred="$(printf '%s\n' "$identities" | sed -nE 's/.*"((Developer ID Application|Apple Distribution|Apple Development|Mac Developer|iPhone Developer)[^"]+)".*/\1/p' | head -n 1)"
    if [[ -n "$preferred" ]]; then
        printf '%s\n' "$preferred"
    else
        printf '%s\n' "-"
    fi
}

cd "$PROJECT_DIR"

# The macOS 27 Command Line Tools SDK references SwiftUI macros that are only
# shipped with full Xcode. Prefer the newest installed SDK that remains
# self-contained when the macro host plugin is absent.
if [[ -z "${SDKROOT:-}" \
    && ! -f /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib \
    && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
    echo "Using self-contained SDK: $SDKROOT"
fi

echo "Building ${APP_NAME} (${BUILD_CONFIGURATION})..."
swift_build_flags=(--jobs "${CODEXSWITCH_SWIFTPM_JOBS:-1}")
if [[ "${CODEXSWITCH_SWIFTPM_DISABLE_SANDBOX:-0}" == "1" ]]; then
    swift_build_flags+=(--disable-sandbox)
fi
if [[ -n "${CODEXSWITCH_SWIFTPM_CACHE_PATH:-}" ]]; then
    swift_build_flags+=(--cache-path "$CODEXSWITCH_SWIFTPM_CACHE_PATH")
fi
if [[ "${CODEXSWITCH_SKIP_SWIFT_BUILD:-0}" == "1" ]]; then
    legacy_build_binary="$PROJECT_DIR/.build/arm64-apple-macosx/$BUILD_CONFIGURATION/$APP_NAME"
    if [[ ! -x "$BUILD_BINARY" && -x "$legacy_build_binary" ]]; then
        BUILD_BINARY="$legacy_build_binary"
    fi
    if [[ ! -x "$BUILD_BINARY" ]]; then
        echo "error: no existing ${BUILD_CONFIGURATION} executable at $BUILD_BINARY" >&2
        exit 2
    fi
    echo "Using existing tested executable at $BUILD_BINARY"
elif (( ${#swift_build_flags[@]} )); then
    swift build -c "$BUILD_CONFIGURATION" "${swift_build_flags[@]}" --quiet
else
    swift build -c "$BUILD_CONFIGURATION" --quiet
fi

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BUILD_BINARY" "$APP_BUNDLE/Contents/MacOS/"

# Bundle the desktop patcher once. Keeping it inside the installed app avoids
# depending on whichever checkout happens to exist.
cp "$PROJECT_DIR/scripts/patch-asar.py" "$APP_BUNDLE/Contents/Resources/patch-asar.py"
chmod 755 "$APP_BUNDLE/Contents/Resources/patch-asar.py"

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
    existing_icon = "/Applications/CodexSwitch.app/Contents/Resources/AppIcon.icns"
    if os.path.exists(existing_icon):
        import shutil
        shutil.copy2(existing_icon, os.path.join(out_dir, "AppIcon.icns"))
        shutil.rmtree(iconset)
        print("  Reused existing AppIcon.icns")
    else:
        print("Error: unable to create AppIcon.icns and no existing icon fallback was found", file=sys.stderr)
        sys.exit(1)
PYEOF

# Sign the app. Prefer a real Apple signing identity when Xcode has installed
# a certificate plus private key in Keychain; otherwise fall back to ad-hoc.
SIGN_IDENTITY="$(select_codesign_identity)"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "Signing app with ad-hoc fallback (no usable code-signing identity found)"
else
    echo "Signing app with identity: $SIGN_IDENTITY"
fi
if ! codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"; then
    echo "Error: failed to sign $APP_BUNDLE" >&2
    exit 1
fi

echo ""
echo "Built: $APP_BUNDLE"
echo ""

# Install if requested
if [[ "${1:-}" == "--install" ]]; then
    INSTALL_PATH="/Applications/${APP_NAME}.app"
    if [[ -L "$INSTALL_PATH" ]]; then
        echo "Error: refusing to replace symlinked install path $INSTALL_PATH" >&2
        exit 1
    fi

    verify_bundle() {
        local bundle="$1"
        if [[ ! -x "$bundle/Contents/MacOS/$APP_NAME" ]]; then
            echo "Error: staged bundle has no executable: $bundle" >&2
            return 1
        fi
        if /usr/bin/strings "$bundle/Contents/MacOS/$APP_NAME" \
            | /usr/bin/grep -E 'LINUX_DEVBOX_ACTIVE_PUSH|pendingLinuxDevboxActive|pushLinuxDevboxActiveAccount' >/dev/null; then
            echo "Error: bundle still contains removed VPS active-push code: $bundle" >&2
            return 1
        fi
        /usr/bin/codesign --verify --strict --verbose=4 "$bundle"
    }

    INSTALL_WORKDIR="$(/usr/bin/mktemp -d /Applications/.codexswitch-install.XXXXXX)" || {
        echo "Error: cannot create a staging directory in /Applications; installed app was not changed" >&2
        exit 1
    }
    STAGED_PATH="$INSTALL_WORKDIR/${APP_NAME}.app"
    FAILED_PATH="$INSTALL_WORKDIR/${APP_NAME}.failed.app"
    HAD_PREVIOUS=0
    SWAPPED=0
    ACTIVATED=0
    PRESERVE_WORKDIR=0

    atomic_swap_paths() {
        python3 - "$1" "$2" <<'PYEOF'
import ctypes
import os
import sys

AT_FDCWD = -2
RENAME_SWAP = 0x00000002
libc = ctypes.CDLL(None, use_errno=True)
renameatx_np = libc.renameatx_np
renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameatx_np.restype = ctypes.c_int

left = os.fsencode(sys.argv[1])
right = os.fsencode(sys.argv[2])
if renameatx_np(AT_FDCWD, left, AT_FDCWD, right, RENAME_SWAP) != 0:
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error), f"{sys.argv[1]} <-> {sys.argv[2]}")
PYEOF
    }

    cleanup_install() {
        if [[ "$ACTIVATED" != "1" && "$SWAPPED" == "1" && "$HAD_PREVIOUS" == "1" \
            && -e "$INSTALL_PATH" && -e "$STAGED_PATH" ]]; then
            if ! atomic_swap_paths "$INSTALL_PATH" "$STAGED_PATH"; then
                PRESERVE_WORKDIR=1
                echo "Critical: rollback failed; preserving recovery bundle at $STAGED_PATH" >&2
            fi
        fi
        if [[ "$PRESERVE_WORKDIR" != "1" ]]; then
            /bin/rm -rf "$INSTALL_WORKDIR"
        fi
    }

    rollback_activation() {
        if [[ "$HAD_PREVIOUS" == "1" ]]; then
            if ! atomic_swap_paths "$INSTALL_PATH" "$STAGED_PATH"; then
                PRESERVE_WORKDIR=1
                echo "Critical: automatic rollback failed; recovery bundle is $STAGED_PATH" >&2
                return 1
            fi
        else
            /bin/mv "$INSTALL_PATH" "$FAILED_PATH" || return 1
        fi
        SWAPPED=0
    }
    trap cleanup_install EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    echo "Installing to $INSTALL_PATH..."
    /usr/bin/ditto --noextattr --noqtn "$APP_BUNDLE" "$STAGED_PATH"
    verify_bundle "$STAGED_PATH"

    /bin/launchctl bootout "gui/$(id -u)/com.codexswitch.watchdog" >/dev/null 2>&1 || true
    /usr/bin/osascript -e 'tell application "CodexSwitch" to quit' >/dev/null 2>&1 || true
    for _ in {1..20}; do
        if ! /usr/bin/pgrep -x "$APP_NAME" >/dev/null 2>&1; then
            break
        fi
        /bin/sleep 0.25
    done
    if /usr/bin/pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        echo "Error: $APP_NAME is still running; refusing to replace its installed bundle" >&2
        exit 1
    fi

    if [[ -e "$INSTALL_PATH" ]]; then
        HAD_PREVIOUS=1
        if ! atomic_swap_paths "$STAGED_PATH" "$INSTALL_PATH"; then
            echo "Error: failed to atomically activate staged app; installed app was not changed" >&2
            exit 1
        fi
    elif ! /bin/mv "$STAGED_PATH" "$INSTALL_PATH"; then
        echo "Error: failed to activate staged app" >&2
        exit 1
    fi
    SWAPPED=1

    if ! verify_bundle "$INSTALL_PATH"; then
        rollback_activation || exit 1
        echo "Error: installed verification failed; previous app was restored" >&2
        exit 1
    fi

    if ! /usr/bin/open "$INSTALL_PATH"; then
        rollback_activation || exit 1
        if [[ "$HAD_PREVIOUS" == "1" ]]; then
            /usr/bin/open "$INSTALL_PATH" >/dev/null 2>&1 || true
        fi
        echo "Error: replacement app did not launch; previous app was restored" >&2
        exit 1
    fi

    for _ in {1..20}; do
        if /usr/bin/pgrep -f "$INSTALL_PATH/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
            break
        fi
        /bin/sleep 0.25
    done
    if ! /usr/bin/pgrep -f "$INSTALL_PATH/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
        rollback_activation || exit 1
        if [[ "$HAD_PREVIOUS" == "1" ]]; then
            /usr/bin/open "$INSTALL_PATH" >/dev/null 2>&1 || true
        fi
        echo "Error: replacement app exited during launch; previous app was restored" >&2
        exit 1
    fi

    ACTIVATED=1
    trap - EXIT INT TERM
    /bin/rm -rf "$INSTALL_WORKDIR"
    echo "Installed and relaunched."
fi
