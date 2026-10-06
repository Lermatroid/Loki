#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
ARCH="${ARCH:-$(uname -m)}"
swift build -c release --arch "$ARCH" --disable-sandbox
BIN_DIR=$(swift build -c release --arch "$ARCH" --show-bin-path)
APP="$PWD/dist/Loki.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/Loki" "$APP/Contents/MacOS/Loki"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    SIGNING_ARGS=(--force --sign "$SIGNING_IDENTITY" --options runtime --timestamp)
    if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then
        SIGNING_ARGS+=(--keychain "$SIGNING_KEYCHAIN")
    fi
    codesign "${SIGNING_ARGS[@]}" "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"
echo "$APP"
