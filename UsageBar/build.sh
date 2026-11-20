#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="${1:-$PWD/Usage Bar.app}"
mkdir -p "$app/Contents/"{MacOS,Resources}
cp Info.plist "$app/Contents/"
cp Icons/*.svg "$app/Contents/Resources/"
xcrun --sdk macosx swiftc -swift-version 6 -O -warnings-as-errors \
    -module-cache-path "${TMPDIR:-/tmp}/usage-bar-modules" \
    -target arm64-apple-macosx13.0 UsageBar.swift -o "$app/Contents/MacOS/UsageBar"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
