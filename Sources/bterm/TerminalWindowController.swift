import AppKit

/// A tab owns a tree of panes (nested split views with `PaneView` leaves).
final class TermTab {
    let id = UUID()
    let container = TabContainerView()
    weak var focused: PaneView?
    var hasActivity = false
    /// Set by renaming the tab; otherwise the title follows the focused pane.
    var customTitle: String?
    var panes: [PaneView] { container.panes }
    var title: String { customTitle ?? (focused ?? panes.first)?.shortTitle ?? "shell" }
}

final class TabContainerView: NSView {
    var root: NSView? {
        didSet {
            if oldValue?.superview === self { oldValue?.removeFromSuperview() }
            if let root { addSubview(root) }
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        root?.frame = bounds
    }

    var panes: [PaneView] {
        func walk(_ v: NSView?) -> [PaneView] {
            guard let v else { return [] }
            if let p = v as? PaneView { return [p] }
            return v.subviews.flatMap { walk($0) }
        }
        return walk(root)
    }
}

final class RootView: NSView {
    let glass = NSVisualEffectView()
    let tabBar = TabBarView()
    let content = NSView()
    let statusBar = StatusBarView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .followsWindowActiveState
        glass.isHidden = true
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        [glass, content, statusBar, tabBar].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        glass.frame = bounds
        tabBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: TabBarView.height)
        statusBar.frame = NSRect(x: 0, y: bounds.height - StatusBarView.height,
                                 width: bounds.width, height: StatusBarView.height)
        content.frame = NSRect(x: 0, y: TabBarView.height, width: bounds.width,
                               height: max(0, bounds.height - TabBarView.height - StatusBarView.height))
        for v in content.subviews { v.frame = content.bounds }
    }
}

/// Window that re-applies custom chrome after every AppKit layout pass
/// (title changes and key-state changes re-layout the standard buttons).
final class BTermWindow: NSWindow {
    var afterLayout: (() -> Void)?
    /// Returns true when the chrome AppKit just laid out needs correcting.
    var needsFix: (() -> Bool)?

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        // Fix up right after the layout pass, before the window draws, so the default positions never show.
        if needsFix?() == true { afterLayout?() }
    }
}

final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    static var all: [TerminalWindowController] = []

    let root = RootView()
    private(set) var tabs: [TermTab] = []
    private var current: TermTab?
    private var palette: CommandPalette?
    private var toast: ToastView?
    private var hud: ToastView?
    private var timer: Timer?
    private var refreshPending = false
    private var branchCache: (dir: String, branch: String?, at: Date)?
    private var settingsObserver: NSObjectProtocol?
    private var trafficSpacing: CGFloat?
    private var layingOutTraffic = false
    private var closingConfirmed = false

    var focusedPane: PaneView? { current?.focused ?? current?.panes.first }

    /// Opens a window around `tab` (a tab torn off another window), the tabs of a saved session,
    /// or a fresh shell in `cwd`.
    init(cwd: String?, tab: TermTab? = nil, restoring saved: SavedWindow? = nil, marker: String = "") {
        let window = BTermWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 520, height: 300)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = root
        window.title = "bterm"
        super.init(window: window)
        window.delegate = self
        window.afterLayout = { [weak self] in self?.layoutTrafficLights() }
        window.needsFix = { [weak self] in self?.trafficLightsMisplaced ?? false }

        let bar = root.tabBar
        bar.onSelect = { [weak self] id in self?.select(id: id) }
        bar.onClose = { [weak self] id in self?.closeTab(id: id) }
        bar.onNew = { [weak self] in self?.newTab(nil) }
        bar.onPalette = { [weak self] in self?.showPalette(nil) }
        bar.onReorder = { [weak self] ids in
            guard let self else { return }
            self.tabs.sort { (ids.firstIndex(of: $0.id) ?? 0) < (ids.firstIndex(of: $1.id) ?? 0) }
        }
        bar.onTearOff = { [weak self] id, grabX in self?.tearOff(id: id, grabX: grabX) }
        bar.onRename = { [weak self] id, name in self?.renamed(id: id, to: name) }
        bar.menuForTab = { [weak self] id in self?.menu(forTab: id) }

        applySettings(animated: false)
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .btermSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.applySettings(animated: true) }

        if let tab {
            adopt(tab, at: 0, animated: false)
        } else if let saved {
            restore(saved, marker: marker)
        } else {
            addTab(cwd: cwd, animated: false)
        }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refreshInfo() }
        t.tolerance = 0.4
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    // MARK: window

    /// Shows the window cascaded from `other`, at a restored `frame`, or where the main window was last.
    func present(cascadeFrom other: NSWindow?, frame: NSRect? = nil) {
        guard let window else { return }
        if let frame {
            window.setFrame(frame, display: false)
        } else if let other {
            let f = other.frame
            window.setFrame(NSRect(x: f.minX + 28, y: f.minY - 28, width: f.width, height: f.height), display: false)
        } else if !window.setFrameUsingName("bterm.main") {
            window.center()
        }
        window.setFrameAutosaveName(other == nil ? "bterm.main" : "")
        layoutTrafficLights()
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        animate(0.22) { window.animator().alphaValue = 1 }
        focusedPane?.appear()
        focus(focusedPane)
    }

    private var trafficLightsMisplaced: Bool {
        guard let w = window, !w.styleMask.contains(.fullScreen),
              let close = w.standardWindowButton(.closeButton) else { return false }
        return close.frame.minX != 16 || close.superview?.frame.height != TabBarView.height
    }

    /// Centers the traffic lights in the taller tab bar.
    func layoutTrafficLights() {
        guard let w = window, !w.styleMask.contains(.fullScreen),
              let close = w.standardWindowButton(.closeButton),
              let mini = w.standardWindowButton(.miniaturizeButton),
              let zoom = w.standardWindowButton(.zoomButton),
              let titlebar = close.superview, let container = titlebar.superview else { return }
        if trafficSpacing == nil { trafficSpacing = mini.frame.minX - close.frame.minX }
        guard !layingOutTraffic else { return }
        layingOutTraffic = true
        defer { layingOutTraffic = false }
        let h = TabBarView.height
        let cf = NSRect(x: 0, y: w.frame.height - h, width: w.frame.width, height: h)
        if container.frame != cf { container.frame = cf }
        if titlebar.frame != container.bounds { titlebar.frame = container.bounds }
        let spacing = trafficSpacing ?? 20
        for (i, b) in [close, mini, zoom].enumerated() {
            let o = NSPoint(x: 16 + CGFloat(i) * spacing, y: (h - b.frame.height) / 2)
            if b.frame.origin != o { b.setFrameOrigin(o) }
        }
        root.tabBar.leadingInset = 16 + spacing * 2 + close.frame.width + 18
    }

    func windowDidResize(_ notification: Notification) {
        layoutTrafficLights()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        hud?.scheduleHide(after: 0.5)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        root.tabBar.leadingInset = 12
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        layoutTrafficLights()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshInfo()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closingConfirmed { return true }
        let busy = tabs.flatMap(\.panes).filter { $0.term.isRunningCommand }
        if busy.isEmpty { return true }
        confirm(busy: busy, message: "Close this window?") { [weak self] in
            self?.closingConfirmed = true
            self?.window?.performClose(nil)
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        for p in tabs.flatMap(\.panes) { p.terminate() }
        tabs.removeAll()
        TerminalWindowController.all.removeAll { $0 === self }
    }

    private func confirm(busy: [PaneView], message: String, then: @escaping () -> Void) {
        guard let window else { return then() }
        let names = Array(Set(busy.compactMap { $0.term.foregroundName })).sorted().joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "Running processes will be terminated: \(names)"
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { r in if r == .alertFirstButtonReturn { then() } }
    }

    // MARK: panes

    private func makePane(cwd: String?, scrollback: String? = nil) -> PaneView {
        let pane = PaneView(cwd: cwd, scrollback: scrollback)
        wire(pane)
        return pane
    }

    /// Points a pane's callbacks at this window (again, when its tab moves here from another window).
    private func wire(_ pane: PaneView) {
        pane.onExit = { [weak self] p in self?.remove(pane: p) }
        pane.onFocus = { [weak self] p in self?.paneDidFocus(p) }
        pane.onChange = { [weak self] _ in self?.refreshSoon() }
        pane.onResize = { [weak self] p, c, r in self?.paneResized(p, cols: c, rows: r) }
        pane.onActivity = { [weak self] p in self?.paneActivity(p) }
    }

    private func tab(of pane: PaneView) -> TermTab? {
        tabs.first { $0.panes.contains(pane) }
    }

    func focus(_ pane: PaneView?) {
        guard let pane, let window else { return }
        if window.firstResponder !== pane.term { window.makeFirstResponder(pane.term) }
        paneDidFocus(pane)
    }

    private func paneDidFocus(_ pane: PaneView) {
        guard let tab = tab(of: pane) else { return }
        tab.focused = pane
        let panes = tab.panes
        for p in panes { p.setDimmed(panes.count > 1 && p !== pane) }
        if tab === current { refreshInfo() }
    }

    private func paneActivity(_ pane: PaneView) {
        if let t = tab(of: pane), t !== current, !t.hasActivity {
            t.hasActivity = true
            refreshInfo()
        }
        refreshSoon()
    }

    private func paneResized(_ pane: PaneView, cols: Int, rows: Int) {
        guard pane === focusedPane, window?.inLiveResize == true else { return }
        showHUD("\(cols) × \(rows)")
        refreshSoon()
    }

    func split(vertical: Bool) {
        guard let tab = current, let pane = focusedPane else { return }
        let fresh = makePane(cwd: pane.directory)
        if let parent = pane.superview as? PaneSplitView, parent.isVertical == vertical {
            let i = parent.arrangedSubviews.firstIndex(of: pane) ?? parent.arrangedSubviews.count - 1
            parent.insertArrangedSubview(fresh, at: i + 1)
            parent.equalize()
        } else {
            let split = PaneSplitView()
            split.isVertical = vertical
            split.lineColor = Settings.shared.theme.borderColor
            split.frame = pane.frame
            if let parent = pane.superview as? PaneSplitView {
                let i = parent.arrangedSubviews.firstIndex(of: pane) ?? 0
                parent.insertArrangedSubview(split, at: i)
                pane.removeFromSuperview()
            } else {
                tab.container.root = split
            }
            split.addArrangedSubview(pane)
            split.addArrangedSubview(fresh)
            split.equalize()
        }
        fresh.appear()
        focus(fresh)
    }

    /// Removes a pane from its tab; collapses single-child splits and closes empty tabs.
    private func remove(pane: PaneView) {
        guard let tab = tab(of: pane) else { return }
        if !pane.exited { pane.terminate() }
        let siblings = tab.panes
        guard siblings.count > 1, let split = pane.superview as? PaneSplitView else {
            closeTab(id: tab.id, confirmed: true)
            return
        }
        let idx = siblings.firstIndex(of: pane) ?? 0
        pane.removeFromSuperview()
        if split.arrangedSubviews.count == 1, let only = split.arrangedSubviews.first {
            only.removeFromSuperview()
            if let grand = split.superview as? PaneSplitView {
                let i = grand.arrangedSubviews.firstIndex(of: split) ?? 0
                grand.insertArrangedSubview(only, at: i)
                split.removeFromSuperview()
                grand.adjustSubviews()
            } else {
                tab.container.root = only
            }
        } else {
            split.equalize()
        }
        let remaining = tab.panes
        let next = remaining[min(idx, remaining.count - 1)]
        if tab === current { focus(next) } else { tab.focused = next }
        for p in remaining { p.setDimmed(remaining.count > 1 && p !== next) }
    }

    func movePaneFocus(_ step: Int) {
        guard let tab = current, let pane = focusedPane else { return }
        let panes = tab.panes
        guard panes.count > 1, let i = panes.firstIndex(of: pane) else { return }
        focus(panes[(i + step + panes.count) % panes.count])
    }

    /// Moves focus to the nearest pane in a direction (dx, dy in screen terms; dy > 0 is down).
    func movePaneFocus(dx: CGFloat, dy: CGFloat) {
        guard let tab = current, let pane = focusedPane else { return }
        let c = tab.container
        let from = c.convert(pane.bounds, from: pane)
        var best: (PaneView, CGFloat)?
        for p in tab.panes where p !== pane {
            let r = c.convert(p.bounds, from: p)
            let vx = r.midX - from.midX
            let vy = c.isFlipped ? r.midY - from.midY : from.midY - r.midY
            let along = vx * dx + vy * dy
            guard along > 1 else { continue }
            let across = abs(vx * dy) + abs(vy * dx)
            let score = along + across * 2
            if best == nil || score < best!.1 { best = (p, score) }
        }
        if let b = best { focus(b.0) }
    }

    // MARK: tabs

    /// Opens a shell in a new tab right after `after` (by default the current tab).
    func addTab(cwd: String?, after: TermTab? = nil, animated: Bool) {
        let tab = TermTab()
        let pane = makePane(cwd: cwd)
        tab.container.root = pane
        tab.focused = pane
        let at = (after ?? current).flatMap { c in tabs.firstIndex { $0 === c } }.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: at)
        show(tab, animated: animated)
        if animated { pane.appear() }
    }

    func select(id: UUID) {
        guard let t = tabs.first(where: { $0.id == id }), t !== current else { return }
        show(t, animated: true)
    }

    func selectTab(offset: Int) {
        guard let c = current, let i = tabs.firstIndex(where: { $0 === c }), tabs.count > 1 else { return }
        show(tabs[(i + offset + tabs.count) % tabs.count], animated: true)
    }

    func selectTab(index: Int) {
        guard !tabs.isEmpty else { return }
        let i = index >= 9 ? tabs.count - 1 : min(index, tabs.count - 1)
        if tabs[i] !== current { show(tabs[i], animated: true) }
    }

    private func show(_ tab: TermTab, animated: Bool) {
        let old = current
        let oldIndex = old.flatMap { o in tabs.firstIndex { $0 === o } } ?? 0
        let newIndex = tabs.firstIndex { $0 === tab } ?? 0
        current = tab
        tab.hasActivity = false

        let host = root.content
        tab.container.frame = host.bounds
        tab.container.alphaValue = 1
        if tab.container.superview !== host { host.addSubview(tab.container) }

        if animated, let old, old.container.superview === host {
            let dir: CGFloat = newIndex >= oldIndex ? 1 : -1
            let outgoing = old.container
            if let l = tab.container.layer {
                let slide = CABasicAnimation(keyPath: "transform.translation.x")
                slide.fromValue = 18 * dir
                slide.toValue = 0
                slide.isAdditive = true
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                let g = CAAnimationGroup()
                g.animations = [slide, fade]
                g.duration = 0.3
                g.timingFunction = easeOutExpo
                l.add(g, forKey: "tabIn")
            }
            animate(0.16, { outgoing.animator().alphaValue = 0 }, completion: { [weak self] in
                if self?.current?.container !== outgoing { outgoing.removeFromSuperview() }
                outgoing.alphaValue = 1
            })
        } else if let old, old !== tab {
            old.container.removeFromSuperview()
        }
        focus(tab.focused ?? tab.panes.first)
        refreshInfo(animated: animated)
    }

    func closeTab(id: UUID, confirmed: Bool = false) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[i]
        let busy = tab.panes.filter { $0.term.isRunningCommand && !$0.exited }
        if !confirmed && !busy.isEmpty {
            confirm(busy: busy, message: "Close this tab?") { [weak self] in self?.closeTab(id: id, confirmed: true) }
            return
        }
        for p in tab.panes where !p.exited { p.terminate() }
        tabs.remove(at: i)
        if tabs.isEmpty {
            closingConfirmed = true
            window?.close()
            return
        }
        if tab === current {
            current = nil
            let next = tabs[min(i, tabs.count - 1)]
            let outgoing = tab.container
            animate(0.14, { outgoing.animator().alphaValue = 0 }, completion: { outgoing.removeFromSuperview() })
            show(next, animated: true)
        } else {
            tab.container.removeFromSuperview()
            refreshInfo()
        }
    }

    /// Closes several tabs, asking once if any are running something.
    func closeTabs(_ ids: [UUID]) {
        let targets = tabs.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        let busy = targets.flatMap(\.panes).filter { $0.term.isRunningCommand && !$0.exited }
        let close = { [weak self] in for t in targets { self?.closeTab(id: t.id, confirmed: true) } }
        if busy.isEmpty { close() } else { confirm(busy: busy, message: "Close \(targets.count) tabs?", then: close) }
    }

    // MARK: tab menu and renaming

    private func menu(forTab id: UUID) -> NSMenu? {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs[i]
        let others = tabs.filter { $0 !== tab }.map(\.id)
        let right = tabs[(i + 1)...].map(\.id)
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(ActionMenuItem("Rename Tab…", symbol: "pencil") { [weak self] in self?.beginRename(id) })
        if tab.customTitle != nil {
            m.addItem(ActionMenuItem("Reset Title", symbol: "arrow.uturn.backward") { [weak self] in
                self?.renamed(id: id, to: "")
            })
        }
        m.addItem(.separator())
        m.addItem(ActionMenuItem("Duplicate Tab", symbol: "plus.square.on.square") { [weak self] in
            self?.addTab(cwd: (tab.focused ?? tab.panes.first)?.directory, after: tab, animated: true)
        })
        m.addItem(ActionMenuItem("Move to New Window", symbol: "macwindow.badge.plus", enabled: tabs.count > 1) { [weak self] in
            self?.moveToNewWindow(id: id)
        })
        m.addItem(.separator())
        m.addItem(ActionMenuItem("Close Tab", symbol: "xmark") { [weak self] in self?.closeTab(id: id) })
        m.addItem(ActionMenuItem("Close Other Tabs", symbol: "xmark.square", enabled: !others.isEmpty) { [weak self] in
            self?.closeTabs(others)
        })
        m.addItem(ActionMenuItem("Close Tabs to the Right", symbol: "arrow.right.to.line", enabled: !right.isEmpty) { [weak self] in
            self?.closeTabs(right)
        })
        return m
    }

    private func beginRename(_ id: UUID) {
        select(id: id)
        root.tabBar.beginRename(id: id)
    }

    /// A rename ended: `name` is nil when cancelled, and an empty name resets to the automatic title.
    private func renamed(id: UUID, to name: String?) {
        if let name, let tab = tabs.first(where: { $0.id == id }) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            tab.customTitle = trimmed.isEmpty ? nil : trimmed
            refreshInfo()
        }
        // Give the keyboard back to the shell, unless the click that ended editing went to a pane.
        DispatchQueue.main.async { [weak self] in
            guard let self, !(self.window?.firstResponder is BTermView) else { return }
            self.focus(self.focusedPane)
        }
    }

    // MARK: moving tabs between windows

    /// Takes a tab out of this window without ending its shells.
    private func detach(_ tab: TermTab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: i)
        tab.container.removeFromSuperview()
        if tab === current {
            current = nil
            if !tabs.isEmpty { show(tabs[min(i, tabs.count - 1)], animated: false) }
        } else {
            refreshInfo()
        }
    }

    private func adopt(_ tab: TermTab, at index: Int, animated: Bool) {
        for p in tab.panes { wire(p) }
        tabs.insert(tab, at: min(index, tabs.count))
        show(tab, animated: animated)
    }

    /// A tab was dragged out of the tab bar: move it to a new window that follows the cursor,
    /// or, for the only tab, drag this window along.
    private func tearOff(id: UUID, grabX: CGFloat) {
        guard let tab = tabs.first(where: { $0.id == id }), let window else { return }
        let fullScreen = window.styleMask.contains(.fullScreen)
        if tabs.count == 1 {
            if fullScreen { return }
            let m = NSEvent.mouseLocation
            followMouse(grab: NSPoint(x: m.x - window.frame.minX, y: window.frame.maxY - m.y))
            return
        }
        detach(tab)
        let size = fullScreen ? NSSize(width: 980, height: 620) : window.frame.size
        let c = TerminalWindowController(cwd: nil, tab: tab)
        TerminalWindowController.all.append(c)
        guard let w = c.window else { return }
        w.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        w.setFrameAutosaveName("")
        c.layoutTrafficLights()
        // Put the window under the cursor so the cursor holds the tab where it grabbed it.
        let grab = NSPoint(x: c.root.tabBar.leadingInset + grabX, y: TabBarView.height / 2)
        let m = NSEvent.mouseLocation
        w.setFrameTopLeftPoint(NSPoint(x: m.x - grab.x, y: m.y + grab.y))
        w.makeKeyAndOrderFront(nil)
        c.focus(c.focusedPane)
        c.followMouse(grab: grab)
    }

    private func moveToNewWindow(id: UUID) {
        guard tabs.count > 1, let tab = tabs.first(where: { $0.id == id }), let window else { return }
        detach(tab)
        let c = TerminalWindowController(cwd: nil, tab: tab)
        TerminalWindowController.all.append(c)
        if window.styleMask.contains(.fullScreen) {
            c.present(cascadeFrom: nil)
        } else {
            c.present(cascadeFrom: window)
        }
    }

    /// Moves this window with the cursor until the mouse is released (`grab` is the cursor's offset
    /// from the window's top-left). Hovering another window's tab bar previews the tab there,
    /// and releasing over it moves the tab into that window.
    private func followMouse(grab: NSPoint) {
        guard let window, let tab = tabs.first, tabs.count == 1 else { return }
        let info = TabInfo(id: tab.id, title: tab.title, state: .idle)
        let grabX = grab.x - root.tabBar.leadingInset
        var target: TerminalWindowController?
        while let e = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                      inMode: .eventTracking, dequeue: true) {
            if e.type == .leftMouseUp { break }
            let m = NSEvent.mouseLocation
            window.setFrameTopLeftPoint(NSPoint(x: m.x - grab.x, y: m.y + grab.y))
            let hit = dropTarget(at: m)
            if hit !== target {
                target?.root.tabBar.endDropPreview(keep: false)
                target = hit
                // Like Chrome, the window vanishes while its tab sits in another window's bar.
                window.alphaValue = hit == nil ? 1 : 0
            }
            target?.root.tabBar.showDropPreview(info, screenX: m.x, grabX: grabX)
        }
        guard let target, let index = target.root.tabBar.endDropPreview(keep: true) else {
            window.alphaValue = 1
            return
        }
        detach(tab)
        target.adopt(tab, at: index, animated: true)
        target.window?.makeKeyAndOrderFront(nil)
        closingConfirmed = true
        window.close()
    }

    /// The other terminal window whose tab bar is under `point` (screen coordinates), if any.
    private func dropTarget(at point: NSPoint) -> TerminalWindowController? {
        guard let window else { return nil }
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: window.windowNumber)
        guard let c = TerminalWindowController.all.first(where: { $0 !== self && $0.window?.windowNumber == number }),
              let w = c.window, !w.isMiniaturized else { return nil }
        let bar = c.root.tabBar
        let p = bar.convert(w.convertPoint(fromScreen: point), from: nil)
        return bar.bounds.insetBy(dx: 0, dy: -8).contains(p) ? c : nil
    }

    // MARK: info refresh

    private func refreshSoon() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refreshPending = false
            self?.refreshInfo()
        }
    }

    func refreshInfo(animated: Bool = true) {
        let infos = tabs.map { tab -> TabInfo in
            let running = tab.panes.contains { $0.isBusy }
            let state: TabState = running ? .running : (tab.hasActivity && tab !== current ? .activity : .idle)
            return TabInfo(id: tab.id, title: tab.title, state: state)
        }
        root.tabBar.update(tabs: infos, selected: current?.id, animated: animated)

        guard let pane = focusedPane else { return }
        let dir = pane.directory
        var branch: String?
        if let dir {
            if let c = branchCache, c.dir == dir, Date().timeIntervalSince(c.at) < 4 {
                branch = c.branch
            } else {
                branch = ProcInfo.gitBranch(in: dir)
                branchCache = (dir, branch, Date())
            }
        }
        let t = pane.term.terminal!
        root.statusBar.update(process: pane.processLabel,
                              running: pane.isBusy,
                              directory: dir.map(ProcInfo.abbreviate),
                              branch: branch, cols: t.cols, rows: t.rows)
        let title = pane.oscTitle.isEmpty ? (dir.map(ProcInfo.abbreviate) ?? "bterm") : pane.oscTitle
        if window?.title != title { window?.title = title }
    }

    // MARK: settings

    func applySettings(animated: Bool) {
        let s = Settings.shared
        let t = s.theme
        if animated, let l = root.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.3
            l.add(fade, forKey: "theme")
        }
        window?.appearance = t.appearance
        window?.isOpaque = !s.glass
        window?.backgroundColor = s.glass ? .clear : t.chromeColor
        root.glass.isHidden = !s.glass
        root.layer?.backgroundColor = s.glass ? NSColor.clear.cgColor : t.bgColor.cgColor
        root.content.layer?.backgroundColor = s.glass ? NSColor.clear.cgColor : t.bgColor.cgColor
        root.tabBar.applyTheme(t, glass: s.glass)
        root.statusBar.applyTheme(t, glass: s.glass)
        for tab in tabs {
            for p in tab.panes { p.applySettings() }
            func recolor(_ v: NSView) {
                if let sp = v as? PaneSplitView { sp.lineColor = t.borderColor }
                v.subviews.forEach(recolor)
            }
            recolor(tab.container)
        }
        refreshInfo(animated: false)
    }

    // MARK: overlays

    func showToast(_ text: String, symbol: String? = nil) {
        toast?.hide()
        let v = ToastView(placement: .bottom)
        v.configure(text: text, symbol: symbol, theme: Settings.shared.theme)
        root.addSubview(v, positioned: .below, relativeTo: palette)
        var area = root.content.frame
        area.size.height -= 4
        v.place(in: NSRect(x: area.minX, y: area.maxY - 34 - 36, width: area.width, height: 34))
        v.show(for: 1.4)
        toast = v
    }

    private func showHUD(_ text: String) {
        if let hud, !hud.dismissed {
            hud.configure(text: text, symbol: nil, theme: Settings.shared.theme, mono: true)
            hud.place(in: root.content.frame)
            hud.scheduleHide(after: 0.9)
            return
        }
        let v = ToastView(placement: .center)
        v.configure(text: text, symbol: nil, theme: Settings.shared.theme, mono: true)
        root.addSubview(v)
        v.place(in: root.content.frame)
        v.show(for: 0.9)
        hud = v
    }

    @objc func showPalette(_ sender: Any?) { openPalette(query: "") }

    private func openPalette(query: String) {
        if let palette, !palette.closing {
            palette.dismiss(ran: false)
            return
        }
        let p = CommandPalette(commands: commands(), theme: Settings.shared.theme, query: query)
        p.onClose = { [weak self] ran in
            guard let self else { return }
            if !ran, Settings.shared.previewThemeID != nil { Settings.shared.previewThemeID = nil }
            self.palette = nil
            self.focus(self.focusedPane)
        }
        p.onEndPreview = {
            if Settings.shared.previewThemeID != nil { Settings.shared.previewThemeID = nil }
        }
        palette = p
        p.present(in: root)
    }

    private func commands() -> [Command] {
        let s = Settings.shared
        var list: [Command] = [
            Command(title: "New Tab", group: "Shell", symbol: "plus.square.on.square", shortcut: "⌘T") { [weak self] in self?.newTab(nil) },
            Command(title: "Open Settings…", group: "Settings", symbol: "gearshape", shortcut: "⌘,") { SettingsWindowController.shared.show() },
            Command(title: "Rename Tab…", group: "Shell", symbol: "pencil") { [weak self] in self?.renameTab(nil) },
            Command(title: "New Window", group: "Shell", symbol: "macwindow.badge.plus", shortcut: "⌘N") { (NSApp.delegate as? AppDelegate)?.newWindow(nil) },
            Command(title: "Split Right", group: "Pane", symbol: "rectangle.split.2x1", shortcut: "⌘D") { [weak self] in self?.split(vertical: true) },
            Command(title: "Split Down", group: "Pane", symbol: "rectangle.split.1x2", shortcut: "⇧⌘D") { [weak self] in self?.split(vertical: false) },
            Command(title: "Close Pane", group: "Pane", symbol: "xmark.square", shortcut: "⌘W") { [weak self] in self?.closePane(nil) },
            Command(title: "Next Tab", group: "Navigate", symbol: "arrow.right.square", shortcut: "⇧⌘]") { [weak self] in self?.selectTab(offset: 1) },
            Command(title: "Previous Tab", group: "Navigate", symbol: "arrow.left.square", shortcut: "⇧⌘[") { [weak self] in self?.selectTab(offset: -1) },
            Command(title: "Next Pane", group: "Navigate", symbol: "square.on.square", shortcut: "⌘]") { [weak self] in self?.movePaneFocus(1) },
            Command(title: "Clear Buffer", group: "Terminal", symbol: "eraser", shortcut: "⌘K") { [weak self] in self?.focusedPane?.term.clearBuffer() },
            Command(title: "Find", group: "Terminal", symbol: "text.magnifyingglass", shortcut: "⌘F") { [weak self] in self?.find() },
            Command(title: "Increase Font Size", group: "View", symbol: "textformat.size.larger", shortcut: "⌘+") { [weak self] in self?.biggerFont(nil) },
            Command(title: "Decrease Font Size", group: "View", symbol: "textformat.size.smaller", shortcut: "⌘−") { [weak self] in self?.smallerFont(nil) },
            Command(title: "Reset Font Size", group: "View", symbol: "textformat.size", shortcut: "⌘0") { [weak self] in self?.resetFont(nil) },
            Command(title: "Toggle Full Screen", group: "View", symbol: "arrow.up.left.and.arrow.down.right", shortcut: "⌃⌘F") { [weak self] in self?.window?.toggleFullScreen(nil) },
        ]
        for t in Theme.all {
            list.append(Command(title: "Theme: \(t.name)", group: "Settings", symbol: t.isDark ? "moon" : "sun.max",
                                checked: s.themeID == t.id,
                                preview: { if Settings.shared.previewThemeID != t.id { Settings.shared.previewThemeID = t.id } },
                                run: { [weak self] in
                                    Settings.shared.previewThemeID = nil
                                    Settings.shared.themeID = t.id
                                    self?.showToast("Theme · \(t.name)", symbol: "paintpalette")
                                }))
        }
        for f in Settings.installedFonts {
            list.append(Command(title: "Font: \(f)", group: "Settings", symbol: "textformat", checked: s.displayFontName == f) { [weak self] in
                Settings.shared.fontName = f == "SF Mono" ? "" : f
                self?.showToast("\(f) · \(Int(Settings.shared.fontSize))pt", symbol: "textformat")
            })
        }
        for c in CursorShape.allCases {
            list.append(Command(title: "Cursor: \(c.rawValue.capitalized)", group: "Settings",
                                symbol: c == .bar ? "character.cursor.ibeam" : (c == .block ? "square.fill" : "underline"),
                                checked: s.cursor == c) { Settings.shared.cursor = c })
        }
        let toggles: [(String, String, ReferenceWritableKeyPath<Settings, Bool>)] = [
            ("Glass Background", "drop", \.glass),
            ("Smooth Scrolling", "arrow.up.and.down.text.horizontal", \.smoothScroll),
            ("Cursor Glide", "cursorarrow.motionlines", \.cursorGlide),
            ("Option as Meta Key", "option", \.optionAsMeta),
            ("GPU Renderer (Metal)", "cpu", \.gpu),
            ("Restore Session at Launch", "clock.arrow.circlepath", \.restoreSession),
        ]
        for (title, symbol, kp) in toggles {
            list.append(Command(title: title, group: "Settings", symbol: symbol, checked: s[keyPath: kp]) { [weak self] in
                Settings.shared[keyPath: kp].toggle()
                self?.showToast("\(title) \(Settings.shared[keyPath: kp] ? "on" : "off")", symbol: symbol)
            })
        }
        return list
    }

    private func find() {
        guard let term = focusedPane?.term else { return }
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        term.performFindPanelAction(item)
    }

    // MARK: menu actions

    @objc func newTab(_ sender: Any?) { addTab(cwd: focusedPane?.directory, animated: true) }
    @objc func splitRight(_ sender: Any?) { split(vertical: true) }
    @objc func splitDown(_ sender: Any?) { split(vertical: false) }
    @objc func nextTab(_ sender: Any?) { selectTab(offset: 1) }
    @objc func previousTab(_ sender: Any?) { selectTab(offset: -1) }
    @objc func nextPane(_ sender: Any?) { movePaneFocus(1) }
    @objc func previousPane(_ sender: Any?) { movePaneFocus(-1) }
    @objc func paneLeft(_ sender: Any?) { movePaneFocus(dx: -1, dy: 0) }
    @objc func paneRight(_ sender: Any?) { movePaneFocus(dx: 1, dy: 0) }
    @objc func paneUp(_ sender: Any?) { movePaneFocus(dx: 0, dy: -1) }
    @objc func paneDown(_ sender: Any?) { movePaneFocus(dx: 0, dy: 1) }
    @objc func selectTabByTag(_ sender: NSMenuItem) { selectTab(index: sender.tag - 1) }
    @objc func clearBuffer(_ sender: Any?) { focusedPane?.term.clearBuffer() }
    @objc func renameTab(_ sender: Any?) { if let id = current?.id { beginRename(id) } }

    @objc func closePane(_ sender: Any?) {
        guard let pane = focusedPane else { return }
        if pane.term.isRunningCommand {
            confirm(busy: [pane], message: "Close this pane?") { [weak self] in self?.remove(pane: pane) }
        } else {
            remove(pane: pane)
        }
    }

    @objc func biggerFont(_ sender: Any?) { setFontSize(Settings.shared.fontSize + 1) }
    @objc func smallerFont(_ sender: Any?) { setFontSize(Settings.shared.fontSize - 1) }
    @objc func resetFont(_ sender: Any?) { setFontSize(13) }

    private func setFontSize(_ size: CGFloat) {
        Settings.shared.fontSize = size
        showToast("\(Settings.shared.displayFontName) · \(Int(Settings.shared.fontSize))pt", symbol: "textformat.size")
    }
}

// MARK: session save and restore

extension TerminalWindowController {
    func saved() -> SavedWindow? {
        guard let window, !tabs.isEmpty else { return nil }
        let selected = current.flatMap { c in tabs.firstIndex { $0 === c } } ?? 0
        return SavedWindow(frame: NSStringFromRect(window.frame), selected: selected, tabs: tabs.map { tab in
            SavedTab(title: tab.customTitle,
                     focused: tab.focused.flatMap { tab.panes.firstIndex(of: $0) } ?? 0,
                     root: Self.save(tab.container.root))
        })
    }

    private static func save(_ view: NSView?) -> SavedNode {
        if let split = view as? PaneSplitView {
            return .split(vertical: split.isVertical, fractions: split.fractions.map(Double.init),
                          children: split.arrangedSubviews.map(save))
        }
        let pane = view as? PaneView
        return .pane(cwd: pane?.directory, scrollback: pane?.term.savedScrollback())
    }

    fileprivate func restore(_ saved: SavedWindow, marker: String) {
        for s in saved.tabs {
            let tab = TermTab()
            tab.customTitle = s.title
            tab.container.root = build(s.root, marker: marker)
            let panes = tab.panes
            guard !panes.isEmpty else { continue }
            tab.focused = panes.indices.contains(s.focused) ? panes[s.focused] : panes.first
            tabs.append(tab)
        }
        if tabs.isEmpty { return addTab(cwd: nil, animated: false) }
        show(tabs[min(max(saved.selected, 0), tabs.count - 1)], animated: false)
    }

    private func build(_ node: SavedNode, marker: String) -> NSView {
        switch node {
        case .pane(let cwd, let scrollback):
            return makePane(cwd: cwd, scrollback: scrollback.map { $0 + marker })
        case .split(let vertical, let fractions, let children):
            let split = PaneSplitView()
            split.isVertical = vertical
            split.lineColor = Settings.shared.theme.borderColor
            for child in children { split.addArrangedSubview(build(child, marker: marker)) }
            split.pendingFractions = fractions.map { CGFloat($0) }
            return split
        }
    }
}

/// A menu item that runs a closure, with an SF Symbol icon.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
