# Flint

A tiny auto-updater for macOS apps, in the spirit of Sparkle, that installs straight from **GitHub Releases**. You don't need EdDSA keys, an appcast, or a Developer ID. Tag a release, attach a zip, and your users get a native-looking update window.

- **Small:** about 400 KB in a release build, with no dependencies. It uses SwiftUI, URLSession, `ditto` and `hdiutil` from the system.
- **Zero config:** add one Info.plist key (`FlintGitHubRepository`) and call one line of code.
- **Formats:** reads `.zip`, `.dmg` and `.tar.gz`. When a release has several assets, it picks the right Mac asset and prefers your CPU architecture.
- **Integrity:** verifies GitHub's SHA-256 asset digests automatically. It checks that the bundle ID matches and, if your app is Developer ID signed, that the team ID matches.
- **Native UI:** release notes are rendered from the GitHub Markdown. It supports light and dark mode, Skip, Remind Me Later, Install on Quit, and Restart Now.
- **Channels:** set up stable, beta, nightly, or your own channels. Tag releases like `v1.4.0-beta.2` and users choose which channel to follow.
- **Permissions:** apps the user can't write to (for example, installed by another admin) are updated after a single password prompt.

| Update available | Ready to install | Up to date |
| --- | --- | --- |
| ![](docs/update-available.png) | ![](docs/ready.png) | ![](docs/up-to-date.png) |

## Setup

> **Using a coding agent?** Point it at [`skills/integrate-flint/SKILL.md`](skills/integrate-flint/SKILL.md), for example: "Follow ~/Developer/ai-slop/flint/skills/integrate-flint/SKILL.md to add auto-updates to this app." The file walks the agent through every step: it checks whether the app can use Flint, vendors Flint, links it (XcodeGen, Tuist, SwiftPM or a plain `.xcodeproj`), wires up the menu item, verifies the build, and sets up releases. For a plain `.xcodeproj`, `scripts/add-to-xcodeproj.py` handles the `project.pbxproj` edits. Claude Code can also load the file as a skill when you copy the `integrate-flint` folder into a repo's `.claude/skills/`.

**1. Add the package.** In Xcode, choose *File → Add Package Dependencies… → Add Local…* and pick this folder. To depend on it by URL, move it into its own repo, because SwiftPM needs `Package.swift` at the repo root.

**2. Point it at your repo** in Info.plist:

```xml
<key>FlintGitHubRepository</key>
<string>you/your-app</string>
```

**3. Start it** and add a menu item:

```swift
import Flint

// AppKit
func applicationDidFinishLaunching(_ note: Notification) {
    Updater.shared.start()   // checks shortly after launch, then daily
    appMenu.insertItem(Updater.shared.makeMenuItem(), at: 1)
}

// SwiftUI
@main struct MyApp: App {
    init() { Updater.shared.start() }
    var body: some Scene {
        WindowGroup { ContentView() }
            .commands {
                CommandGroup(after: .appInfo) { CheckForUpdatesButton(updater: .shared) }
            }
    }
}
```

## Shipping an update

1. Bump `CFBundleShortVersionString`, for example to `1.3.0`.
2. Build your app and run:

   ```sh
   scripts/publish.sh build/MyApp.app --notes CHANGES.md   # or omit --notes to auto-generate
   ```

   The script zips the app with `ditto`, which keeps symlinks and signatures intact, and creates the `v1.3.0` release with the GitHub CLI. Creating the release by hand works too: the tag is the version (with or without a `v`), and the body is the release notes.

Flint ignores drafts. To ship to a channel instead of everyone, give the version a suffix, such as `1.4.0-beta.2` (see below). `publish.sh` marks those as GitHub pre-releases, so the repo's "Latest" badge stays on the stable release.

## Channels

Each release belongs to a channel, determined by its version suffix:

| Tag | Channel |
| --- | --- |
| `v1.4.0` | stable |
| `v1.4.0-beta.2`, `v1.4.0-rc.1`, `v1.4.0-alpha.3` | beta (`rc`, `alpha`, `pre` and `preview` are aliases) |
| `v1.5.0-nightly.20261118` | nightly (`dev`, `canary` and `snapshot` are aliases) |

Each user follows one channel. They're offered the newest release on that channel or on any more stable one. A beta tester on `1.4.0-beta.2` therefore gets `1.4.0-beta.3`, and then `1.4.0` when it ships, with no extra steps. Nobody is ever offered a downgrade: someone who switches from beta back to stable stays on their beta until a newer stable release exists.

**Declaring channels.** Stable and beta are on by default. To add more, list them in Info.plist, most stable first. Stable is always included first, so you don't need to list it:

```xml
<key>FlintChannels</key>
<array>
  <string>beta</string>
  <string>nightly</string>
  <!-- custom: name, plus optional aliases and title -->
  <dict>
    <key>name</key><string>internal</string>
    <key>aliases</key><array><string>dogfood</string></array>
    <key>title</key><string>Internal Testing</string>
  </dict>
</array>
```

You can also declare them in code: `Updater(source: GitHubSource("you/app"), channels: [.beta, .nightly, Channel("internal", aliases: ["dogfood"])])`.

A release whose suffix matches none of your channels is never offered. You can publish nightlies before you turn the nightly channel on, and nobody will receive them. A release that's ticked "pre-release" on GitHub but has no suffix goes to the first channel after stable.

**Which channel a user follows.** Until the user picks one, a build follows its own channel: a `1.4.0-beta.2` build stays on beta, so testers who download a beta keep getting betas. To set a build's channel explicitly, add `FlintDefaultChannel` to its Info.plist (for example, CI nightly builds can use `nightly`). After the user picks a channel, that choice is saved and wins. Add the ready-made picker to your settings:

```swift
Form {
    ChannelPicker(updater: .shared)   // hidden when stable is the only channel
}
```

You can also set `Updater.shared.channel = .beta` yourself. Changing the channel triggers a check right away.

**Versioning tips**

- **Put the full version in Info.plist.** `CFBundleShortVersionString` should include the suffix (`1.4.0-beta.2`), because that's what Flint compares against. If the plist says `1.4.0` while the tag says `1.4.0-beta.2`, your beta testers won't be offered the real `1.4.0`, since it looks like the version they already have.
- **Make nightlies sort.** Nightlies need a sortable suffix, such as `1.5.0-nightly.20261118`. Version them against the *next* release: after `1.4.0` ships, nightlies become `1.5.0-nightly.*`. Rolling tags like `nightly` that get overwritten each build won't work.
- **How suffixes compare.** Within the same base version, semver puts `alpha < beta < nightly < rc`.
- **Large repos.** GitHub lists the 100 newest releases. If you publish more than 100 nightlies between stable releases, stable users won't see the last stable release.

## Configuration

| Info.plist key | |
| --- | --- |
| `FlintGitHubRepository` | `owner/name` of a public repo |
| `FlintAssetPattern` | Optional glob for the asset to download, such as `MyApp-*.zip`, when the automatic choice isn't right |
| `FlintFeedURL` | Use a JSON feed instead of GitHub (see below) |
| `FlintChannels` | Channels besides stable, most stable first (see [Channels](#channels)) |
| `FlintDefaultChannel` | The channel this build follows until the user picks one |

In code, `Updater(source:)` takes any `UpdateSource`. You can also set `checkInterval` (default: one day), `automaticallyChecksForUpdates` (a user preference, shown as a checkbox in the window), and `channel` (also a user preference).

### JSON feed

If you're not using GitHub, host a file anywhere:

```json
{
  "version": "1.3.0",
  "url": "https://example.com/MyApp-1.3.0.zip",
  "notes": "## What's new\n- Faster everything",
  "date": "2026-11-12",
  "sha256": "…",
  "minimumSystemVersion": "13.0"
}
```

Only `version` and `url` are required. `notes` can be Markdown or HTML. The file can hold an array of releases, and an optional `"channel": "beta"` overrides the channel implied by the version.

### Your own UI

The window is optional. The headless API works the same way:

```swift
if let release = try await updater.findUpdate() {
    let update = try await updater.prepare(release) { received, total in … }
    try updater.install(update, relaunch: true)
}
```

## How it works

1. **Check:** Flint calls `GET /repos/{repo}/releases`, takes the highest version among published releases that have a usable asset, and compares it to `CFBundleShortVersionString`. Versions are compared like semver (`1.10 > 1.9`, `1.0-beta < 1.0`).
2. **Download:** the archive goes to a temporary folder on the same volume as the app.
3. **Verify:** Flint checks the SHA-256 against GitHub's asset `digest`, a `.sha256` or `SHA256SUMS` asset, or the feed's `sha256`. The bundle identifier must match. If the running app has a Team ID, the update must have a valid signature from the same team.
4. **Install:** Flint removes the quarantine flag and swaps the bundle with two renames. If the second rename fails, it rolls back. It then waits for the app to exit and reopens it.

### Security, honestly

Without signing keys, a release is only as trustworthy as **your GitHub account and HTTPS**. Someone who can publish releases to your repo can ship your users an update. Sparkle's EdDSA signatures exist to close that gap. If your app is Developer ID signed, Flint's team-ID check closes it too: a malicious build would need your signing certificate. Otherwise, protect the GitHub account with 2FA.

### Limitations

- macOS 13 or later; sandboxed apps aren't supported, because they can't replace their own bundle.
- Apps running from a disk image or App Translocation are asked to move to Applications first.
- Only public repos: the GitHub API is unauthenticated, which allows 60 checks per hour per IP and is plenty for daily checks.

## Demo

```sh
scripts/make-demo-app.sh 1.0.0 build FlintGitHubRepository=you/your-repo
FLINT_CHECK=1 open build/FlintDemo.app      # opens the update window right away
```

`swift test` runs the version, asset-picking, channel and Markdown tests.
