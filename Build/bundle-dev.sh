#!/bin/bash
# Build a development .app bundle from the SPM debug build.
#
# This is for local interactive testing only (e.g., the Phase 1 passthrough
# test). The release-signing-and-notarization flow is a separate script
# under Phase 4.
#
# Usage: ./Build/bundle-dev.sh [--clean]
#
# Output: Build/tap-n-filter.app (ad-hoc signed, runnable locally)

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--clean" ]]; then
    swift package clean
fi

echo "==> Building (swift build -c debug)…"
swift build -c debug

BIN=".build/debug/tap-n-filter"
APP="Build/tap-n-filter.app"

if [[ ! -f "$BIN" ]]; then
    echo "Build did not produce $BIN" >&2
    exit 1
fi

echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/tap-n-filter"
chmod +x "$APP/Contents/MacOS/tap-n-filter"

cp "Sources/tap-n-filter/Resources/Info.plist" "$APP/Contents/Info.plist"

# Copy any SPM-generated resource bundles next to the executable so
# Bundle.module continues to resolve at runtime.
for bundle in .build/debug/*.bundle; do
    if [[ -d "$bundle" ]]; then
        cp -R "$bundle" "$APP/Contents/Resources/"
    fi
done

echo "==> Ad-hoc signing…"
codesign --force --deep --sign - "$APP"

echo "==> Done: $APP"
echo "Launch with: open \"$APP\""
