#!/bin/bash
# Builds build/bterm.app (release, stripped, ad-hoc signed).
# Usage: ./build.sh [--install]   (--install copies the app to /Applications)
set -euo pipefail
cd "$(dirname "$0")"

./scripts/fetch-swiftterm.sh

echo "› compiling (release)"
swift build -c release --product bterm \
    -Xswiftc -Osize -Xswiftc -gnone \
    -Xlinker -dead_strip -Xlinker -x 2>&1 | grep -E "error|warning: unre|Compiling bterm|Build complete" || true

BIN="$(swift build -c release --show-bin-path)/bterm"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

APP="build/bterm.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/bterm"
strip -x "$APP/Contents/MacOS/bterm" 2>/dev/null || true
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Metal shader source for the optional GPU renderer (compiled at runtime).
cp Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal "$APP/Contents/Resources/"

echo "› icon"
ICONSET="build/AppIcon.iconset"
if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ]; then
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"
    swift scripts/make-icon.swift build/icon-1024.png
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "› built $APP ($(du -sh "$APP" | cut -f1))"

if [ "${1:-}" = "--install" ]; then
    rm -rf /Applications/bterm.app
    cp -R "$APP" /Applications/
    echo "› installed to /Applications/bterm.app"
fi
