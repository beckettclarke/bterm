#!/bin/bash
# Zips an app and publishes it as a GitHub release that Flint will pick up.
# The tag is "v" + CFBundleShortVersionString, so 1.4.0-beta.2 ships on the beta
# channel and 1.4.0 on stable. Needs the GitHub CLI (gh).
#
#   scripts/publish.sh build/MyApp.app [--repo you/my-app] [--notes notes.md] [--prerelease] [--draft]
set -euo pipefail

APP=${1:?usage: publish.sh path/to/App.app [--repo owner/name] [--notes file.md] [--prerelease] [--draft]}
shift
APP=${APP%/}
[[ -d "$APP/Contents" ]] || { echo "error: $APP is not an app bundle" >&2; exit 1; }

ARGS=()
NOTES=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --repo) ARGS+=(--repo "$2"); shift 2 ;;
    --notes) NOTES=$2; shift 2 ;;
    --prerelease|--draft) ARGS+=("$1"); shift ;;
    *) echo "error: unknown option $1" >&2; exit 1 ;;
  esac
done

PLIST="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
NAME=$(basename "$APP" .app)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ZIP="$WORK/${NAME// /-}-$VERSION.zip"

# ditto keeps symlinks, permissions and code signatures intact; plain `zip` doesn't.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "Packed $(du -h "$ZIP" | cut -f1 | xargs) → $(basename "$ZIP")"

# Versions like 1.4.0-beta.2 are channel builds: keep them off GitHub's "Latest" badge.
if [[ $VERSION == *-* && ! " ${ARGS[*]-} " =~ " --prerelease " ]]; then ARGS+=(--prerelease); fi
if [[ -n $NOTES ]]; then ARGS+=(--notes-file "$NOTES"); else ARGS+=(--generate-notes); fi
gh release create "v$VERSION" "$ZIP" --title "$NAME $VERSION" "${ARGS[@]}"
