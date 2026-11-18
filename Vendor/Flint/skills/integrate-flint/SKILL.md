---
name: integrate-flint
description: Add Flint auto-updates (GitHub Releases, no signing keys) to an existing macOS app repo. Use when asked to add auto-updating, "Check for Updates", Sparkle-style updates or Flint to a Mac app.
---

# Add Flint to an existing macOS app

You are adding Flint, a small auto-updater, to the app in the current repo. Flint checks the app's GitHub Releases, shows an update window, and replaces the app in place. Follow the steps in order. Don't skip the checks: most failures come from the project setup, not from Flint.

**Ground rules**
- Don't change code signing, entitlements, the bundle identifier or the deployment target unless the user agrees.
- Don't push, tag, create releases or commit unless the user asks.
- Leave unrelated code alone. Match the repo's style: indentation, file layout and comment density.

## 1. Survey the project

Run these and note the answers:

```sh
ls; git remote get-url origin
find . -maxdepth 3 \( -name "*.xcodeproj" -o -name "*.xcworkspace" -o -name project.yml -o -name Project.swift -o -name Package.swift \) -not -path "*/.build/*" -not -path "*/Pods/*"
grep -rn --include=*.swift -e "@main" -e "NSApplicationDelegate" -e "MenuBarExtra" -e "import Sparkle" . | grep -v "/.build/" | head
grep -rn "MACOSX_DEPLOYMENT_TARGET\|ENABLE_APP_SANDBOX\|MARKETING_VERSION" --include=project.pbxproj --include=*.yml --include=*.xcconfig . | sort -u | head
grep -rl "com.apple.security.app-sandbox" --include=*.entitlements . | xargs grep -A1 "app-sandbox" 2>/dev/null
```

From the output, work out:

| Question | How to tell |
| --- | --- |
| Project type | `project.yml` → **XcodeGen**. `Project.swift` → **Tuist**. Only `Package.swift` → **SwiftPM app**. Otherwise → **plain .xcodeproj**. |
| App target | The `application` target (not tests or extensions) |
| UI lifecycle | `@main struct …: App` → **SwiftUI**. `NSApplicationDelegate` / `main.swift` / storyboard → **AppKit**. `MenuBarExtra` or `LSUIElement` → **menu bar app** |
| GitHub repo | `owner/name` from the remote URL |

**Stop and tell the user** if any of these apply. Flint can't work in these setups:
- **Sandboxed:** the app is sandboxed (`ENABLE_APP_SANDBOX = YES` or `com.apple.security.app-sandbox` is true). Sandboxed apps can't replace their own bundle.
- **Old deployment target:** it's below macOS 13.
- **Private repo:** the repo is private. Check with `gh repo view --json visibility -q .visibility` if `gh` is available, otherwise ask. Flint reads releases without authentication.
- **Not on GitHub:** the remote isn't GitHub. Flint can use a JSON feed instead (see Flint's README, "JSON feed"); ask the user where they'll host it.
- **Mac App Store:** the app ships through the Mac App Store, which updates apps itself.

**Ask the user** only about what you can't infer:
- **Existing updater:** if the app already uses Sparkle or another updater, ask whether to replace it. If yes, remove its package, code, `SU*` Info.plist keys and menu item as part of this change.
- **Channels:** ask whether they want beta or nightly builds. The default is stable plus beta, which needs no setup.

## 2. Vendor Flint into the repo

Flint is the folder this skill came from: this file is `<flint>/skills/integrate-flint/SKILL.md`, so Flint is two directories above it. If this file was copied elsewhere and you can't find the folder, ask the user for its path. You can't clone it from GitHub.

Copy it to `Vendor/Flint`. Keep the folder name `Flint`, because SwiftPM derives the package name from it:

```sh
mkdir -p Vendor
rsync -a --exclude .build --exclude .swiftpm --exclude build --exclude docs <path-to-flint>/ Vendor/Flint/
```

If the repo already keeps third-party code somewhere else (for example `Packages/` or `ThirdParty/`), use that location and adjust the paths below.

## 3. Link the package to the app target

Use the method that matches the project type. **Never** hand-edit a `.pbxproj` that XcodeGen or Tuist generates: your edits would be overwritten.

**XcodeGen** (`project.yml`): add Flint under `packages`, and add it to the app target's `dependencies`. Merge into existing keys instead of adding duplicates.

```yaml
packages:
  Flint:
    path: Vendor/Flint
targets:
  MyApp:
    dependencies:
      - package: Flint
```

Then run `xcodegen generate`.

**Tuist** (`Project.swift`): add `.package(path: "Vendor/Flint")` to the project's packages (or follow the repo's existing pattern for local packages) and `.package(product: "Flint")` to the app target's dependencies. Then run `tuist generate`.

**SwiftPM app** (`Package.swift`): add `.package(path: "Vendor/Flint")` to `dependencies` and `.product(name: "Flint", package: "Flint")` to the app target.

**Plain .xcodeproj:** use the bundled script. It adds the package reference, the product dependency and the Frameworks build file (creating the phase if needed), keeps a `.bak`, and validates the result:

```sh
python3 Vendor/Flint/scripts/add-to-xcodeproj.py MyApp.xcodeproj MyApp Vendor/Flint
```

The second argument is the app target's name (`xcodebuild -list -project MyApp.xcodeproj` shows the targets). The script needs Xcode 15 or later. Delete the `.bak` file once the build succeeds.

**If the project uses a workspace** (`.xcworkspace`, for example with CocoaPods), still link the package to the `.xcodeproj`, but build with `-workspace`.

## 4. Wire it into the app

Configure the updater in code. Put the extension in the file that holds the app's entry point (the `App` struct or `AppDelegate`). Don't create a new file: with plain `.xcodeproj` projects that use classic groups (no `PBXFileSystemSynchronizedRootGroup` in the `.pbxproj`), a new file isn't compiled unless it's also added to the project.

```swift
import Flint

extension Updater {
    /// The app's updater; it reads GitHub Releases of this repo.
    static let app = Updater(source: GitHubSource("owner/name"))
}
```

Use `Updater.app` everywhere. Don't use `Updater.shared`, which expects Info.plist keys that you're not adding.

If the user wants extra channels, pass them: `Updater(source: GitHubSource("owner/name"), channels: [.beta, .nightly])`.

If the release asset name is ambiguous (several `.zip` or `.dmg` files per release), pin it: `GitHubSource("owner/name", assetPattern: "MyApp-*.zip")`.

**SwiftUI lifecycle.** Start the updater in the `App` initializer, and add the menu command. Merge into an existing `.commands { }` if there is one:

```swift
@main
struct MyApp: App {
    init() { Updater.app.start() }

    var body: some Scene {
        WindowGroup { ContentView() }
            .commands {
                CommandGroup(after: .appInfo) { CheckForUpdatesButton(updater: .app) }
            }
    }
}
```

If the app has an existing `init()`, add the `start()` line to it.

**AppKit lifecycle.** At the top of `applicationDidFinishLaunching`, add:

```swift
Updater.app.start()
NSApp.mainMenu?.items.first?.submenu?.insertItem(Updater.app.makeMenuItem(), at: 1)
```

This puts "Check for Updates…" in the app menu, right after "About". It works with storyboard, xib and code-built menus. If the app builds its menu in code, you can instead add `Updater.app.makeMenuItem()` where the About item is created.

**Menu bar apps** (no app menu): call `Updater.app.start()` at launch, and add `Updater.app.makeMenuItem()` (AppKit `NSMenu`) or `CheckForUpdatesButton(updater: .app)` (SwiftUI `MenuBarExtra`) next to the app's Quit item. Flint's window activates the app itself.

**Settings (optional).** If the app has a Settings window and uses more than one channel, add the picker to it:

```swift
ChannelPicker(updater: .app)   // shows nothing when stable is the only channel
```

## 5. Check the version setup

Flint compares the release tag with the running app's `CFBundleShortVersionString`. To confirm the version wiring, run:

```sh
grep -rn "CFBundleShortVersionString" --include=*.plist --include=project.yml --exclude-dir=build --exclude-dir=.build --exclude-dir=DerivedData --exclude-dir=Vendor .
```

- The value should come from `MARKETING_VERSION` (`$(MARKETING_VERSION)`) or be a literal version. Either is fine. Note how the user bumps it, because releases depend on it.
- Release tags must be the same version, with an optional `v` prefix: `MARKETING_VERSION = 1.4.0` → tag `v1.4.0`.
- Beta or nightly builds need the suffix in `MARKETING_VERSION` itself, such as `1.4.0-beta.2`, not only in the tag.

## 6. Build and verify

1. **Build the app.** Build it the way the repo already does (for example a Makefile or scripts). If there's no existing build process, run:

   ```sh
   xcodebuild -project MyApp.xcodeproj -scheme MyApp -configuration Release -derivedDataPath build/flint-check CODE_SIGNING_ALLOWED=NO build
   ```

   Fix any errors you introduced. A failure about `XCLocalSwiftPackageReference` means Xcode is older than 15: tell the user.

2. **Check release discovery.** If the repo already has a release with a `.zip` or `.dmg` asset, confirm Flint can find it. Use Flint's demo app at version `0.0.1` so that any real release counts as newer:

   ```sh
   Vendor/Flint/scripts/make-demo-app.sh 0.0.1 build/flint-check FlintGitHubRepository=owner/name
   FLINT_HEADLESS=find build/flint-check/FlintDemo.app/Contents/MacOS/FlintDemo
   ```

   Expect `found <version> → <asset URL>`. Check that the URL is the Mac app archive. If the wrong asset is picked, set `assetPattern`. `up to date` means there are no usable releases yet, which is fine for a new setup. Add `FlintDefaultChannel=beta` to the `make-demo-app.sh` arguments to check beta releases. Delete `build/flint-check` afterwards.

3. **Try the update window.** If you can launch GUI apps, run the built app and use "Check for Updates…". You can do this with a `MARKETING_VERSION=0.0.1` override on the `xcodebuild` command line, but don't commit that override.

## 7. Set up releases

Each release must have a zipped `.app` whose bundle identifier matches the installed app. Use `ditto` to zip it, never `zip`: plain `zip` breaks symlinks and signatures.

- **Existing release process:** if the repo already has one (scripts, fastlane, CI), add a step there that zips the built app with `ditto -c -k --sequesterRsrc --keepParent MyApp.app MyApp-<version>.zip` and uploads it to the GitHub release.
- **No release process yet:** point the user to `Vendor/Flint/scripts/publish.sh build/…/MyApp.app`. It zips the app, creates the `v<version>` release with `gh`, and marks suffixed versions (`-beta.2`) as pre-releases.
- **CI:** only if the user asks for it, add a GitHub Actions workflow that builds the app on tag push and runs `publish.sh`. Have the workflow fail if the built app's `CFBundleShortVersionString` doesn't match the tag. Ask how the app should be signed: Developer ID needs certificate secrets, while ad-hoc signing (`CODE_SIGN_IDENTITY=-`) works without any.

Apps that aren't Developer ID signed and notarized trigger Gatekeeper on first install. Users must open them via right-click → Open, or via System Settings → Privacy & Security → Open Anyway. Updates installed by Flint don't trigger this again. Tell the user so they can mention it in their install instructions.

## 8. Report back

Tell the user:
- **Changes:** which files you changed, and where Flint is vendored.
- **Results:** whether the build passed, and what the release-discovery check printed.
- **Shipping:** how to ship an update in their setup, for example "bump `MARKETING_VERSION`, build, run `publish.sh`".
- **Caveats:** anything you couldn't do or verify, such as GUI testing or private-repo questions, and any Gatekeeper note for unsigned apps.
