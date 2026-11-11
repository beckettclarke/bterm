import AppKit

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        let first = openWindow(cwd: nil)
        NSApp.activate(ignoringOtherApps: true)

        // Development hooks: BTERM_SLOWMO=10 slows every animation, BTERM_RUN types into the first pane.
        let env = ProcessInfo.processInfo.environment
        if let f = env["BTERM_SLOWMO"].flatMap(Float.init), f > 0 {
            first.root.layer?.speed = 1 / f
        }
        if let actions = env["BTERM_ACTIONS"]?.split(separator: ",") {
            for (i, a) in actions.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(i) * 0.8) {
                    // A leading "@" goes through the key window's responder chain, like a key press.
                    let viaChain = a.hasPrefix("@")
                    let sel = Selector(String(viaChain ? a.dropFirst() : a))
                    NSApp.sendAction(sel, to: !viaChain && first.responds(to: sel) ? first : nil, from: nil)
                }
            }
        }
        if let run = env["BTERM_RUN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                first.focusedPane?.term.send(txt: run.replacingOccurrences(of: "\\n", with: "\r"))
            }
        }
        // BTERM_SNAPSHOT=out.png renders the key window to a PNG after BTERM_SNAPSHOT_DELAY
        // seconds (default 4) and quits. Used for the README and site screenshots.
        if let out = env["BTERM_SNAPSHOT"] {
            let delay = env["BTERM_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Self.snapshot(NSApp.keyWindow ?? first.window, to: out)
                exit(0)
            }
        }
    }

    /// Draws the window's layer tree, frame included, into a PNG at the backing scale.
    private static func snapshot(_ window: NSWindow?, to path: String) {
        guard let window, let view = window.contentView?.superview ?? window.contentView,
              let layer = view.layer else { return }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        func canvas() -> (NSBitmapImageRep, CGContext)? {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }
            return (rep, ctx)
        }
        guard let (layers, ctx) = canvas(), let (out, outCtx) = canvas() else { return }
        ctx.scaleBy(x: scale, y: scale)
        if layer.isGeometryFlipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        layer.render(in: ctx)
        // Backgrounds painted by the window server are missing from the layer tree, so lay the
        // render over the terminal background.
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(out.pixelsWide), height: CGFloat(out.pixelsHigh))
        outCtx.setFillColor(Settings.shared.theme.bgColor.cgColor)
        outCtx.fill(bounds)
        if let image = layers.cgImage { outCtx.draw(image, in: bounds) }
        try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openWindow(cwd: nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = TerminalWindowController.all.flatMap(\.tabs).flatMap(\.panes).filter { $0.term.isRunningCommand }
        guard !busy.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit bterm?"
        let names = Array(Set(busy.compactMap { $0.term.foregroundName })).sorted().joined(separator: ", ")
        alert.informativeText = "Running processes will be terminated: \(names)"
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Open folders dropped on the Dock icon (or `open -a bterm <dir>`) in a new window.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            openWindow(cwd: isDir.boolValue ? url.path : url.deletingLastPathComponent().path)
        }
    }

    @discardableResult
    func openWindow(cwd: String?) -> TerminalWindowController {
        let previous = NSApp.keyWindow ?? TerminalWindowController.all.last?.window
        let c = TerminalWindowController(cwd: cwd)
        TerminalWindowController.all.append(c)
        c.present(cascadeFrom: previous)
        return c
    }

    @objc func newWindow(_ sender: Any?) {
        let key = NSApp.keyWindow?.windowController as? TerminalWindowController
        openWindow(cwd: key?.focusedPane?.directory)
    }

    /// ⌘W fallback: terminal windows handle `closePane:` themselves (earlier in the
    /// responder chain); any other window (Settings, About) just closes.
    @objc func closePane(_ sender: Any?) {
        NSApp.keyWindow?.performClose(sender)
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "bterm",
            .credits: NSAttributedString(string: "A small, fast terminal.\nEmulation by SwiftTerm.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                      .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let host = NSMenuItem()
            host.submenu = m
            main.addItem(host)
            return m
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            return i
        }

        let C: NSEvent.ModifierFlags = .command
        let CS: NSEvent.ModifierFlags = [.command, .shift]
        let CO: NSEvent.ModifierFlags = [.command, .option]

        _ = menu("bterm", [
            item("About bterm", #selector(showAbout(_:)), ""),
            .separator(),
            item("Settings…", #selector(showSettings(_:)), ",", C),
            .separator(),
            item("Hide bterm", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit bterm", #selector(NSApplication.terminate(_:)), "q"),
        ])

        _ = menu("Shell", [
            item("New Window", #selector(newWindow(_:)), "n"),
            item("New Tab", #selector(TerminalWindowController.newTab(_:)), "t"),
            .separator(),
            item("Split Right", #selector(TerminalWindowController.splitRight(_:)), "d"),
            item("Split Down", #selector(TerminalWindowController.splitDown(_:)), "d", CS),
            .separator(),
            item("Close Pane", #selector(TerminalWindowController.closePane(_:)), "w"),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", CS),
        ])

        let find = item("Find…", #selector(NSResponder.performTextFinderAction(_:)), "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        let findNext = item("Find Next", #selector(NSResponder.performTextFinderAction(_:)), "g")
        findNext.tag = NSTextFinder.Action.nextMatch.rawValue
        let findPrev = item("Find Previous", #selector(NSResponder.performTextFinderAction(_:)), "g", CS)
        findPrev.tag = NSTextFinder.Action.previousMatch.rawValue
        _ = menu("Edit", [
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Clear Buffer", #selector(TerminalWindowController.clearBuffer(_:)), "k"),
            .separator(),
            find, findNext, findPrev,
        ])

        _ = menu("View", [
            item("Command Palette", #selector(TerminalWindowController.showPalette(_:)), "p"),
            item("Command Palette", #selector(TerminalWindowController.showPalette(_:)), "p", CS).hiddenAlternate(),
            .separator(),
            item("Bigger", #selector(TerminalWindowController.biggerFont(_:)), "="),
            item("Bigger", #selector(TerminalWindowController.biggerFont(_:)), "+").hiddenAlternate(),
            item("Smaller", #selector(TerminalWindowController.smallerFont(_:)), "-"),
            item("Actual Size", #selector(TerminalWindowController.resetFont(_:)), "0"),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])

        var windowItems: [NSMenuItem] = [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Show Next Tab", #selector(TerminalWindowController.nextTab(_:)), "]", CS),
            item("Show Previous Tab", #selector(TerminalWindowController.previousTab(_:)), "[", CS),
            item("Next Pane", #selector(TerminalWindowController.nextPane(_:)), "]"),
            item("Previous Pane", #selector(TerminalWindowController.previousPane(_:)), "["),
            item("Pane Left", #selector(TerminalWindowController.paneLeft(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), CO),
            item("Pane Right", #selector(TerminalWindowController.paneRight(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), CO),
            item("Pane Up", #selector(TerminalWindowController.paneUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), CO),
            item("Pane Down", #selector(TerminalWindowController.paneDown(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), CO),
            .separator(),
        ]
        for n in 1...9 {
            windowItems.append(item(n == 9 ? "Last Tab" : "Tab \(n)",
                                    #selector(TerminalWindowController.selectTabByTag(_:)), "\(n)", C, tag: n))
        }
        windowItems += [.separator(), item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))]
        NSApp.windowsMenu = menu("Window", windowItems)
        return main
    }
}

private extension NSMenuItem {
    /// Extra key equivalent for the same action without cluttering the menu.
    func hiddenAlternate() -> NSMenuItem {
        isHidden = true
        allowsKeyEquivalentWhenHidden = true
        return self
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
