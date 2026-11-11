#!/bin/bash
# Developer ID signing and notarization, used by the release workflow when the Apple secrets
# are set. Needs CODESIGN_IDENTITY (for "app"), APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD
# (an app-specific password).
#
#   scripts/notarize.sh app   sign build/bterm.app with the hardened runtime, notarize, staple
#   scripts/notarize.sh dmg   notarize and staple dist/bterm.dmg (run scripts/package.sh first)
set -euo pipefail
cd "$(dirname "$0")/.."

submit() {
    xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_PASSWORD" --wait --timeout 30m
}

case "${1:-}" in
    app)
        APP="build/bterm.app"
        codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP"
        codesign --verify --strict --verbose=2 "$APP"
        ZIP="$(mktemp -d)/bterm.zip"
        ditto -c -k --keepParent "$APP" "$ZIP"
        submit "$ZIP"
        xcrun stapler staple "$APP"
        spctl --assess --type execute --verbose "$APP"
        ;;
    dmg)
        submit dist/bterm.dmg
        xcrun stapler staple dist/bterm.dmg
        ;;
    *)
        echo "usage: $0 app|dmg" >&2
        exit 2
        ;;
esac
