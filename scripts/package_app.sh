#!/usr/bin/env bash
# Builds a self-contained, double-click-able .app + .dmg for one of the
# two games, with no Xcode/Command Line Tools and no system Python
# required on the machine that runs it -- just this script, run on a Mac
# with the Xcode Command Line Tools installed (that machine still needs
# them, to build; the *result* doesn't).
#
# Usage:
#   scripts/package_app.sh classic  <output-dir>
#   scripts/package_app.sh island2  <output-dir>
#
# Produces <output-dir>/<dmg-name>.dmg. Meant to be run by
# .github/workflows/release.yml on a macos-14 (Apple silicon) runner,
# which is why the Swift build below asks for both architectures
# explicitly rather than relying on the runner's native one -- but it
# works the same way run locally on a dev Mac.
set -euo pipefail

TARGET="${1:-}"
OUT_DIR="${2:-}"
if [[ -z "$TARGET" || -z "$OUT_DIR" ]]; then
    echo "Usage: $0 <classic|island2> <output-dir>" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# python-build-standalone release to embed -- pinned so builds are
# reproducible; bump these two lines to pick up a newer CPython.
PBS_RELEASE_TAG="${PBS_RELEASE_TAG:-20240814}"
PBS_PYTHON_VERSION="${PBS_PYTHON_VERSION:-3.11.9}"
PBS_BASE_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE_TAG}"

case "$TARGET" in
    classic)
        PKG_DIR="$REPO_ROOT/app/IslandOfSecrets"
        PRODUCT_NAME="IslandOfSecrets"
        APP_DISPLAY_NAME="Island of Secrets"
        BUNDLE_ID="com.ozdweller.islandofsecrets"
        DMG_NAME="Island-of-Secrets-Classic-macOS"
        VOLNAME="Island of Secrets (Classic)"
        ;;
    island2)
        PKG_DIR="$REPO_ROOT/Island 2.0/app/IslandOfSecrets2"
        PRODUCT_NAME="IslandOfSecrets2"
        APP_DISPLAY_NAME="Island of Secrets 2.0"
        BUNDLE_ID="com.ozdweller.islandofsecrets2"
        DMG_NAME="Island-of-Secrets-2.0-macOS"
        VOLNAME="Island of Secrets 2.0"
        ;;
    *)
        echo "Unknown target '$TARGET' (expected classic or island2)" >&2
        exit 1
        ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== [$TARGET] Building universal Swift binary =="
( cd "$PKG_DIR" && swift build -c release --arch arm64 --arch x86_64 )

BIN_PATH="$PKG_DIR/.build/apple/Products/Release/$PRODUCT_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
    # Fallback for older SwiftPM layouts / single-arch local runs.
    BIN_PATH="$PKG_DIR/.build/release/$PRODUCT_NAME"
fi
if [[ ! -f "$BIN_PATH" ]]; then
    echo "Couldn't find the built binary under $PKG_DIR/.build -- looked for" >&2
    echo "  .build/apple/Products/Release/$PRODUCT_NAME and .build/release/$PRODUCT_NAME" >&2
    exit 1
fi
echo "Using binary: $BIN_PATH"
file "$BIN_PATH" || true

APP_PATH="$WORK/$APP_DISPLAY_NAME.app"
CONTENTS="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
mkdir -p "$MACOS_DIR" "$RESOURCES"

cp "$BIN_PATH" "$MACOS_DIR/$PRODUCT_NAME"
chmod +x "$MACOS_DIR/$PRODUCT_NAME"

echo "== [$TARGET] Copying game resources into Contents/Resources =="
case "$TARGET" in
    classic)
        mkdir -p "$RESOURCES/engine" "$RESOURCES/art/rooms" "$RESOURCES/art/items" "$RESOURCES/data"
        cp "$REPO_ROOT"/engine/*.py "$RESOURCES/engine/"
        cp "$REPO_ROOT/listing.bas" "$RESOURCES/listing.bas"
        cp "$REPO_ROOT/art/app_icon.png" "$RESOURCES/art/app_icon.png"
        cp -R "$REPO_ROOT/art/rooms/." "$RESOURCES/art/rooms/"
        cp -R "$REPO_ROOT/art/items/." "$RESOURCES/art/items/"
        # data/ just needs to exist -- GameEngine.swift's --save-path
        # override means nothing is actually read from here at runtime,
        # but PROJECT_ROOT/data is where play_ipc.py's own default
        # points, so keep the directory present for anyone invoking the
        # bundled interpreter by hand.
        ;;
    island2)
        mkdir -p "$RESOURCES/Island 2.0/engine" "$RESOURCES/art/rooms" "$RESOURCES/art/characters" "$RESOURCES/data"
        cp "$REPO_ROOT/Island 2.0/engine/"*.py "$RESOURCES/Island 2.0/engine/"
        cp "$REPO_ROOT/art/app_icon.png" "$RESOURCES/art/app_icon.png"
        cp -R "$REPO_ROOT/art/rooms/." "$RESOURCES/art/rooms/"
        cp -R "$REPO_ROOT/art/characters/." "$RESOURCES/art/characters/"
        cp "$REPO_ROOT/data/"*.json "$RESOURCES/data/"
        ;;
esac
find "$RESOURCES" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

echo "== [$TARGET] Building app icon =="
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
SRC_ICON="$REPO_ROOT/art/app_icon.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SRC_ICON" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$SRC_ICON" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"

echo "== [$TARGET] Writing Info.plist =="
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$PRODUCT_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_DISPLAY_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.adventure-games</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Non-commercial fan adaptation. See LICENSE.</string>
</dict>
</plist>
PLIST
echo -n "APPL????" > "$CONTENTS/PkgInfo"

echo "== [$TARGET] Embedding a self-contained Python runtime =="
for arch in aarch64 x86_64; do
    case "$arch" in
        aarch64) folder="arm64" ;;
        x86_64)  folder="x86_64" ;;
    esac
    url="${PBS_BASE_URL}/cpython-${PBS_PYTHON_VERSION}+${PBS_RELEASE_TAG}-${arch}-apple-darwin-install_only.tar.gz"
    tarball="$WORK/python-${arch}.tar.gz"
    echo "Downloading $url"
    curl -fL --retry 3 -o "$tarball" "$url"
    extract_dir="$WORK/python-${arch}"
    mkdir -p "$extract_dir"
    tar -xzf "$tarball" -C "$extract_dir"
    # python-build-standalone's install_only tarball unpacks to
    # <extract_dir>/python/{bin,lib,include,...}
    src="$extract_dir/python"
    dest="$RESOURCES/python-runtime/$folder"
    mkdir -p "$dest"
    cp -R "$src/." "$dest/"
    # Trim what the engines never use to keep the download reasonable --
    # no Tk (no GUI toolkit needed), no test suite, no IDLE.
    rm -rf "$dest/lib/python3."*/test \
           "$dest/lib/python3."*/idlelib \
           "$dest/lib/python3."*/tkinter \
           "$dest/lib/python3."*/turtledemo \
           "$dest"/lib/python3.*/lib-dynload/_tkinter*.so \
           "$dest/share" 2>/dev/null || true
    find "$dest" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    if [[ ! -e "$dest/bin/python3" ]]; then
        # install_only layouts usually already have a python3 -> python3.X
        # symlink; add one if this particular build didn't.
        versioned="$(ls "$dest"/bin/python3.* 2>/dev/null | head -n1 || true)"
        if [[ -n "$versioned" ]]; then
            ln -sf "$(basename "$versioned")" "$dest/bin/python3"
        fi
    fi
done

echo "== [$TARGET] Ad-hoc code signing (no Apple Developer ID -- see README) =="
# Apple silicon refuses to run an unsigned Mach-O at all, so everything
# executable needs at least an ad-hoc signature. This does NOT satisfy
# Gatekeeper's separate "downloaded from the internet" quarantine check --
# that still needs a real Developer ID to clear silently. Without one,
# first-launch still needs the right-click-Open (or System Settings ->
# Privacy & Security -> Open Anyway) step documented in the README.
find "$RESOURCES/python-runtime" -type f \( -perm -u+x -o -name "*.dylib" -o -name "*.so" \) -print0 \
    | xargs -0 -I{} codesign --force --sign - "{}" 2>/dev/null || true
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

echo "== [$TARGET] Building DMG =="
DMG_STAGING="$WORK/dmg"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
DMG_PATH="$OUT_DIR/$DMG_NAME.dmg"
rm -f "$DMG_PATH"
hdiutil create -volname "$VOLNAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH"

echo "== [$TARGET] Done: $DMG_PATH =="
du -sh "$DMG_PATH"
