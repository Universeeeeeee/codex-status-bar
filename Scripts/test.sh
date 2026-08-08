#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$ROOT/.build"

cd "$ROOT"
mkdir -p "$BUILD/module-cache"
clang -fobjc-arc -g -mmacosx-version-min=13.0 \
    -fmodules-cache-path="$BUILD/module-cache" \
    -framework Cocoa \
    -lsqlite3 \
    Sources/CodexStatusBar/*.m \
    -o "$BUILD/CodexStatusBarTests"
"$BUILD/CodexStatusBarTests" --self-test
