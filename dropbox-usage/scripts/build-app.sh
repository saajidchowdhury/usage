#!/bin/zsh

set -euo pipefail

root=${0:A:h:h}
app="$root/build/Dropbox Usage.app"
sdk=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
cache=/private/tmp/dropbox-usage-clang-cache
swiftpm_cache=/private/tmp/dropbox-usage-swiftpm-cache

cd "$root"
env SDKROOT="$sdk" CLANG_MODULE_CACHE_PATH="$cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$swiftpm_cache" \
    swift build --disable-sandbox -c release --product DropboxUsage

/bin/rm -rf "$app"
/bin/mkdir -p "$app/Contents/MacOS"
/bin/cp "$root/.build/release/DropboxUsage" "$app/Contents/MacOS/DropboxUsage"
/bin/cp "$root/App/Info.plist" "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app"

echo "$app"
