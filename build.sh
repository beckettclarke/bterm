#!/bin/bash
# Builds build/bterm.app (release, stripped, ad-hoc signed).
#
#   ./build.sh               build for this Mac's architecture
#   ./build.sh --universal   build for Apple silicon and Intel
#   ./build.sh --install     also copy the app to /Applications
#
# BTERM_VERSION=1.2.0 sets the version in Info.plist; otherwise it's taken from the
# latest v* git tag, falling back to the version in Resources/Info.plist.
set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL=0
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        --install) INSTALL=1 ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

./scripts/fetch-swiftterm.sh

ARCHS=()
if [ "$UNIVERSAL" = 1 ]; then ARCHS=(--arch arm64 --arch x86_64); fi
FLAGS=(-c release --product bterm ${ARCHS[@]+"${ARCHS[@]}"}
       -Xswiftc -Osize -Xswiftc -gnone -Xlinker -dead_strip -Xlinker -x)

echo "› compiling (release$([ "$UNIVERSAL" = 1 ] && echo ", universal"))"
mkdir -p build
if ! swift build "${FLAGS[@]}" > build/swift-build.log 2>&1; then
    grep -E "error:" build/swift-build.log || tail -40 build/swift-build.log
    echo "build failed (full log: build/swift-build.log)" >&2
    exit 1
fi
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/bterm"
[ -x "$BIN" ] || { echo "build failed: no binary at $BIN" >&2; exit 1; }

VERSION="${BTERM_VERSION:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)"
fi
if [ -z "$VERSION" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
fi
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

APP="build/bterm.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/bterm"
strip -x "$APP/Contents/MacOS/bterm" 2>/dev/null || true
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
# Metal shader source for the optional GPU renderer (compiled at runtime).
cp Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp Vendor/SwiftTerm/LICENSE "$APP/Contents/Resources/SwiftTerm-LICENSE"

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
echo "› built $APP $VERSION ($(du -sh "$APP" | cut -f1), $(lipo -archs "$APP/Contents/MacOS/bterm"))"

if [ "$INSTALL" = 1 ]; then
    rm -rf /Applications/bterm.app
    cp -R "$APP" /Applications/
    echo "› installed to /Applications/bterm.app"
fi
