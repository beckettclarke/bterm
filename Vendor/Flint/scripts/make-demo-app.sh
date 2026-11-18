#!/bin/bash
# Builds FlintDemo.app at a given version, for trying updates end to end.
#
#   scripts/make-demo-app.sh 1.0.0 build FlintGitHubRepository=you/your-repo
#   scripts/make-demo-app.sh 1.0.0 build FlintFeedURL=file:///tmp/feed.json
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: make-demo-app.sh <version> <output-dir> [InfoKey=value ...]}
OUT=${2:?usage: make-demo-app.sh <version> <output-dir> [InfoKey=value ...]}
shift 2

swift build -c release --product FlintDemo >/dev/null
BIN="$(swift build -c release --show-bin-path)/FlintDemo"

APP="$OUT/FlintDemo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/FlintDemo"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.flint.demo</string>
  <key>CFBundleName</key><string>Flint Demo</string>
  <key>CFBundleExecutable</key><string>FlintDemo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
for pair in "$@"; do
  /usr/libexec/PlistBuddy -c "Add :${pair%%=*} string ${pair#*=}" "$APP/Contents/Info.plist"
done
codesign --force --sign - "$APP" 2>/dev/null
echo "$APP"
