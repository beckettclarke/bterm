#!/bin/bash
# Packages build/bterm.app for release:
#   dist/bterm.zip   the app, zipped with ditto (what the Homebrew cask installs)
#   dist/bterm.dmg   a disk image with the app and an Applications shortcut
#   dist/SHA256SUMS
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/bterm.app"
[ -d "$APP" ] || { echo "no $APP, run ./build.sh first" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

rm -rf dist && mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/bterm.zip

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# hdiutil sometimes reports "Resource busy" on CI machines; a retry clears it.
for attempt in 1 2 3 4 5; do
    if hdiutil create -quiet -volname "bterm $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov dist/bterm.dmg; then
        break
    fi
    [ "$attempt" = 5 ] && { echo "hdiutil failed" >&2; exit 1; }
    sleep $((attempt * 3))
done

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$CODESIGN_IDENTITY" --timestamp dist/bterm.dmg
fi

(cd dist && shasum -a 256 bterm.zip bterm.dmg > SHA256SUMS)
echo "› packaged bterm $VERSION"
sed 's/^/  /' dist/SHA256SUMS
