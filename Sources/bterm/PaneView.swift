import AppKit
import SwiftTerm

/// A view that never takes mouse events; used for decorative overlays.
class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var wantsUpdateLayer: Bool { true }
}

/// One shell session: a padded terminal plus focus, bell and drop overlays.
final class PaneView: NSView, LocalProcessTerminalViewDelegate {
    let term: BTermView
    var onExit: ((PaneView) -> Void)?
    var onFocus: ((PaneView) -> Void)?
    var onChange: ((PaneView) -> Void)?
    var onResize: ((PaneView, Int, Int) -> Void)?
    var onActivity: ((PaneView) -> Void)?

    private(set) var oscTitle = ""
    private(set) var exited = false
    private let dim = PassthroughView()
    private let ring = PassthroughView()
    private let thumb = PassthroughView()
    private var thumbHide: DispatchWorkItem?
    private var theme = Settings.shared.theme
    private var appliedCursor: CursorShape?

    static let inset = NSEdgeInsets(top: 10, left: 14, bottom: 4, right: 4)

    init(cwd: String?) {
        term = BTermView(font: Settings.shared.font)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(term)
        for v in [dim, ring] {
            v.wantsLayer = true
            v.layer?.opacity = 0
            addSubview(v)
        }
        ring.layer?.borderWidth = 1.5
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 2
        thumb.layer?.opacity = 0
        addSubview(thumb)
        term.processDelegate = self
        term.onFocus = { [weak self] _ in self.map { $0.onFocus?($0) } }
        term.onActivity = { [weak self] _ in self.map { $0.onActivity?($0) } }
        term.onBell = { [weak self] _ in self?.flash() }
        term.onScroll = { [weak self] _ in self?.updateThumb() }
        term.onDropHighlight = { [weak self] on in self?.setRing(visible: on, color: self?.theme.accentColor) }
        applySettings()
        start(cwd: cwd)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func start(cwd: String?) {
        let shell = ProcInfo.loginShell
        var env = ProcessInfo.processInfo.environment
        for k in ["PWD", "OLDPWD", "SHLVL", "TERM_SESSION_ID", "ITERM_SESSION_ID", "__CFBundleIdentifier"] {
            env.removeValue(forKey: k)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "bterm"
        env["TERM_PROGRAM_VERSION"] = AppInfo.version
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        let dir = cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? NSHomeDirectory()
        term.startProcess(executable: shell, args: [],
                          environment: env.map { "\($0.key)=\($0.value)" },
                          execName: "-" + (shell as NSString).lastPathComponent,
                          currentDirectory: dir)
    }

    func applySettings() {
        let s = Settings.shared
        theme = s.theme
        layer?.backgroundColor = theme.bgColor.withAlphaComponent(s.glass ? (theme.isDark ? 0.74 : 0.8) : 1).cgColor
        dim.layer?.backgroundColor = (theme.isDark ? NSColor.black : NSColor.white).withAlphaComponent(0.45).cgColor
        ring.layer?.borderColor = theme.accentColor.cgColor
        thumb.layer?.backgroundColor = theme.mutedColor.withAlphaComponent(0.55).cgColor
        term.apply(theme: theme, glass: s.glass)
        if term.font.fontName != s.font.fontName || term.font.pointSize != s.font.pointSize {
            term.font = s.font
        }
        term.optionAsMetaKey = s.optionAsMeta
        term.smoothScroll = s.smoothScroll
        term.cursorGlide = s.cursorGlide
        if term.window != nil { try? term.setUseMetal(s.gpu) }
        // Only push the cursor preference when it changes, so app-set shapes (vim modes) survive.
        if appliedCursor != s.cursor {
            appliedCursor = s.cursor
            term.terminal!.setCursorStyle(s.cursor.style)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, Settings.shared.gpu { try? term.setUseMetal(true) }
    }

    override func layout() {
        super.layout()
        let i = PaneView.inset
        term.frame = NSRect(x: i.left, y: i.bottom,
                            width: max(0, bounds.width - i.left - i.right),
                            height: max(0, bounds.height - i.top - i.bottom))
        dim.frame = bounds
        ring.frame = bounds
        placeThumb()
    }

    /// Thin overlay scroll indicator: visible while browsing history, fades out at the bottom.
    private func updateThumb() {
        placeThumb()
        let inHistory = term.canScroll && term.scrollPosition < 1
        thumbHide?.cancel()
        if inHistory {
            if (thumb.layer?.opacity ?? 0) < 1 { fade(thumb.layer, to: 1, duration: 0.15) }
        } else if (thumb.layer?.opacity ?? 0) > 0 {
            let w = DispatchWorkItem { [weak self] in self.map { $0.fade($0.thumb.layer, to: 0, duration: 0.4) } }
            thumbHide = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
        }
    }

    private func placeThumb() {
        let track = bounds.insetBy(dx: 0, dy: 6)
        let size = max(track.height * term.scrollThumbsize, 24)
        // Position 1 is the bottom of the buffer; the view's y axis points up.
        let y = track.minY + (track.height - size) * (1 - CGFloat(term.scrollPosition))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        thumb.frame = NSRect(x: bounds.width - 7, y: y, width: 4, height: size)
        CATransaction.commit()
    }

    // MARK: state overlays

    func setDimmed(_ dimmed: Bool, animated: Bool = true) {
        fade(dim.layer, to: dimmed ? 1 : 0, duration: animated ? 0.22 : 0)
    }

    private func setRing(visible: Bool, color: NSColor?) {
        if let color { ring.layer?.borderColor = color.cgColor }
        fade(ring.layer, to: visible ? 1 : 0, duration: 0.15)
    }

    func flash() {
        guard let l = ring.layer else { return }
        l.borderColor = theme.accentColor.cgColor
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [0, 1, 0]
        a.keyTimes = [0, 0.15, 1]
        a.duration = 0.6
        l.add(a, forKey: "bell")
    }

    func appear() {
        guard let l = layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -8
        rise.toValue = 0
        rise.isAdditive = true
        let g = CAAnimationGroup()
        g.animations = [fade, rise]
        g.duration = 0.32
        g.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        l.add(g, forKey: "appear")
    }

    private func fade(_ l: CALayer?, to value: Float, duration: CFTimeInterval) {
        guard let l else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = l.presentation()?.opacity ?? l.opacity
        a.toValue = value
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.opacity = value
        if duration > 0 { l.add(a, forKey: "fade") }
    }

    // MARK: labels

    var directory: String? { term.currentDirectory }

    private var lastBusy: (name: String, at: CFTimeInterval)?

    /// Running state with a short grace period, so loops of quick commands
    /// (`for …; do sleep 1; done`) don't flicker between busy and idle.
    var isBusy: Bool { busyName != nil }

    private var busyName: String? {
        let now = CACurrentMediaTime()
        if term.isRunningCommand {
            let n = term.foregroundName ?? "running"
            lastBusy = (n, now)
            return n
        }
        if let b = lastBusy, now - b.at < 1.6 { return b.name }
        lastBusy = nil
        return nil
    }

    var processLabel: String {
        busyName ?? term.foregroundName ?? (ProcInfo.loginShell as NSString).lastPathComponent
    }

    /// Short label for tabs: the running program, or the directory name at a prompt.
    var shortTitle: String {
        if let n = busyName { return n }
        if let d = directory {
            let a = ProcInfo.abbreviate(d)
            return a == "~" ? "~" : (a as NSString).lastPathComponent
        }
        return oscTitle.isEmpty ? "shell" : oscTitle
    }

    func terminate() {
        exited = true
        term.terminate()
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        onResize?(self, newCols, newRows)
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        oscTitle = title
        onChange?(self)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        onChange?(self)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !exited else { return }
        exited = true
        onExit?(self)
    }
}

/// Split container with hairline dividers in the theme's border color.
final class PaneSplitView: NSSplitView {
    var lineColor: NSColor = .separatorColor { didSet { needsDisplay = true } }
    override var dividerThickness: CGFloat { 1 }
    override var dividerColor: NSColor { lineColor }

    func equalize() {
        layoutSubtreeIfNeeded()
        let views = arrangedSubviews
        guard views.count > 1 else { return }
        let total = isVertical ? bounds.width : bounds.height
        let share = (total - CGFloat(views.count - 1) * dividerThickness) / CGFloat(views.count)
        for i in 0..<(views.count - 1) {
            setPosition(share * CGFloat(i + 1) + dividerThickness * CGFloat(i), ofDividerAt: i)
        }
    }
}
