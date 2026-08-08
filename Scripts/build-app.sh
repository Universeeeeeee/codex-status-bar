#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/outputs/Codex Status.app"
BUILD="$ROOT/.build"

cd "$ROOT"
mkdir -p "$BUILD/module-cache"
clang -fobjc-arc -O2 -mmacosx-version-min=13.0 \
    -fmodules-cache-path="$BUILD/module-cache" \
    -framework Cocoa \
    -lsqlite3 \
    Sources/CodexStatusBar/*.m \
    -o "$BUILD/CodexStatusBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/CodexStatusBar" "$APP/Contents/MacOS/CodexStatusBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Completion.png "$APP/Contents/Resources/Completion.png"
codesign --force --deep --sign - "$APP"

echo "$APP"
