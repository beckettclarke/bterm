import AppKit
import Flint
import SwiftUI

// A tiny app for trying Flint. Build a bundle with scripts/make-demo-app.sh.
//
//   FLINT_CHECK=1     open the update window on launch
//   FLINT_HEADLESS=1  find, download and install without UI, then exit (for testing)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let env = ProcessInfo.processInfo.environment

    func applicationDidFinishLaunching(_ notification: Notification) {
        if env["FLINT_HEADLESS"] != nil { return runHeadless() }

        NSApp.mainMenu = makeMenu()
        let window = NSWindow(contentViewController: NSHostingController(rootView: DemoView()))
        window.title = "Flint Demo"
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)

        Updater.shared.start()
        if env["FLINT_CHECK"] != nil { Updater.shared.checkForUpdates() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func makeMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Flint Demo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(Updater.shared.makeMenuItem())
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Flint Demo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let root = NSMenuItem()
        root.submenu = appMenu
        let menu = NSMenu()
        menu.addItem(root)
        return menu
    }

    private func runHeadless() {
        Task { @MainActor in
            let updater = Updater.shared
            do {
                guard let release = try await updater.findUpdate() else {
                    print("up to date")
                    exit(0)
                }
                print("found \(release.version) → \(release.downloadURL.absoluteString)")
                if env["FLINT_HEADLESS"] == "find" { exit(0) }
                let update = try await updater.prepare(release) { received, total in
                    print("downloaded \(received)/\(total)")
                }
                print("prepared \(update.appURL.path)")
                try updater.install(update, relaunch: false)
                print("installed")
                exit(0)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
    }
}

struct DemoView: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Flint Demo").font(.title.bold())
            Text("Version \(version)").foregroundStyle(.secondary)
            Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            ChannelPicker(updater: .shared)
                .fixedSize()
        }
        .padding(40)
        .frame(width: 360)
    }
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.run()
}
