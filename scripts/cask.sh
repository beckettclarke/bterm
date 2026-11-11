#!/bin/bash
# Prints the Homebrew cask for a release: scripts/cask.sh <version> <sha256 of bterm.zip>
# SIGNED=true leaves out the quarantine workaround needed for unnotarized builds.
set -euo pipefail
VERSION="${1:?usage: $0 <version> <sha256>}"
SHA="${2:?usage: $0 <version> <sha256>}"

cat <<CASK
cask "bterm" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/beckettclarke/bterm/releases/download/v#{version}/bterm.zip"
  name "bterm"
  desc "Small, fast, native terminal"
  homepage "https://term.beckettclarke.ca/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :ventura

  app "bterm.app"
CASK

if [ "${SIGNED:-false}" != "true" ]; then
cat <<'CASK'

  # bterm releases are ad-hoc signed, not notarized. Clearing the quarantine flag lets
  # the app open without the "can't be checked for malicious software" prompt.
  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-dr", "com.apple.quarantine", "{{appdir}}/bterm.app"],
        writable_paths: ["{{appdir}}/bterm.app"],
        must_succeed:   false
  end
CASK
fi

cat <<'CASK'

  zap trash: [
    "~/Library/Preferences/dev.bterm.app.plist",
    "~/Library/Saved Application State/dev.bterm.app.savedState",
  ]
end
CASK
