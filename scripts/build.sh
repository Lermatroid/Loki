#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift build -c release --disable-sandbox
APP="$PWD/dist/Loki.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Loki "$APP/Contents/MacOS/Loki"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "$APP"
