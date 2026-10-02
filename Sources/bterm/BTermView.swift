import AppKit
import SwiftTerm

/// SwiftTerm's AppKit terminal with bterm's motion layer on top:
/// smooth line scrolling, a gliding caret, file drops and activity hooks.
final class BTermView: LocalProcessTerminalView {
    var onFocus: ((BTermView) -> Void)?
    var onActivity: ((BTermView) -> Void)?
    var onBell: ((BTermView) -> Void)?
    var onDropHighlight: ((Bool) -> Void)?
    var onScroll: ((BTermView) -> Void)?

    var smoothScroll = true
    var cursorGlide = true

    private var pendingScrollLines = 0
    private var scrollFrames: [CFTimeInterval] = []
    private weak var caret: NSView?
    private var caretOrigin: NSPoint?
    private var caretObserver: NSObjectProtocol?

    init(font: NSFont) {
        var options = TerminalOptions.default
        options.scrollback = 10_000
        options.cursorStyle = Settings.shared.cursor.style
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500), font: font, options: options)
        registerForDraggedTypes([.fileURL, .string])
        linkHighlightMode = .hoverWithModifier
        // The pane draws its own minimal scroll indicator; drop the AppKit scroller and its reserved gutter.
        for case let scroller as NSScroller in subviews { scroller.isHidden = true }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let caretObserver { NotificationCenter.default.removeObserver(caretObserver) }
    }

    // MARK: appearance

    func apply(theme: Theme, glass: Bool) {
        nativeForegroundColor = theme.fgColor
        // In glass mode the pane paints the translucent tint; default-background cells stay clear
        // (reverse video is still forced opaque by SwiftTerm, so highlights stay readable).
        nativeBackgroundColor = theme.bgColor.withAlphaComponent(glass ? 0 : 1)
        installColors(theme.terminalColors)
        caretColor = NSColor(hex: theme.cursor)
        caretTextColor = theme.bgColor
        selectedTextBackgroundColor = NSColor(hex: theme.selection)
        selectedTextForegroundColor = theme.fgColor
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    var cellHeight: CGFloat {
        if let h = caret?.frame.height, h > 0 { return h }
        let f = font
        return ceil(CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f))
    }

    // MARK: process introspection

    var foregroundPid: pid_t {
        guard process.running, process.childfd >= 0 else { return 0 }
        let pg = tcgetpgrp(process.childfd)
        return pg > 0 ? pg : process.shellPid
    }

    var foregroundName: String? { ProcInfo.name(of: foregroundPid) }
    var currentDirectory: String? { ProcInfo.cwd(of: foregroundPid) ?? ProcInfo.cwd(of: process.shellPid) }
    var isRunningCommand: Bool {
        let fg = foregroundPid
        return fg > 0 && fg != process.shellPid
    }

    // MARK: smooth scrolling

    override func scrolled(source terminal: Terminal, yDisp: Int) {
        super.scrolled(source: terminal, yDisp: yDisp)
        guard smoothScroll, !isUsingMetalRenderer, !terminal.isCurrentBufferAlternate else { return }
        let b = terminal.buffer
        // Only full-screen scrolls of the live view; TUIs with scroll regions are left alone.
        guard b.scrollTop == 0, b.scrollBottom == terminal.rows - 1, !canScroll || scrollPosition >= 1 else { return }
        pendingScrollLines += 1
    }

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        onScroll?(self)
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        let lines = pendingScrollLines
        pendingScrollLines = 0
        guard lines > 0, let layer, window?.isVisible == true else { return }

        // Flood guard: sustained output (`cat`, builds, `yes`) renders instantly.
        let now = CACurrentMediaTime()
        scrollFrames.append(now)
        scrollFrames.removeAll { now - $0 > 0.45 }
        if scrollFrames.count > 10 { return }

        let offset = CGFloat(min(lines, 3)) * cellHeight
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = -offset
        slide.toValue = 0
        slide.isAdditive = true
        slide.duration = 0.2
        slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        layer.add(slide, forKey: nil)
    }

    // MARK: caret glide

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard caret == nil, String(describing: type(of: subview)) == "CaretView" else { return }
        caret = subview
        caretOrigin = subview.frame.origin
        subview.postsFrameChangedNotifications = true
        caretObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: subview, queue: nil
        ) { [weak self] _ in self?.caretMoved() }
    }

    private func caretMoved() {
        guard let caret else { return }
        let new = caret.frame.origin
        defer { caretOrigin = new }
        guard cursorGlide, let old = caretOrigin, old != new, caret.superview != nil,
              let layer = caret.layer, window?.isVisible == true else { return }
        let dx = old.x - new.x, dy = old.y - new.y
        // A glide across the whole screen reads as lag; keep long jumps short.
        let far = abs(dy) > cellHeight * 4
        let glide = CABasicAnimation(keyPath: "transform.translation")
        glide.fromValue = NSValue(size: NSSize(width: dx, height: dy))
        glide.toValue = NSValue(size: .zero)
        glide.isAdditive = true
        glide.duration = far ? 0.12 : 0.085
        glide.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        layer.add(glide, forKey: nil)
    }

    // MARK: hooks

    override var hasFocus: Bool {
        didSet { if hasFocus { onFocus?(self) } }
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onActivity?(self)
    }

    override func bell(source: Terminal) {
        onBell?(self)
    }

    func clearBuffer() {
        guard !terminal.isCurrentBufferAlternate else { return }
        clearScrollback()
        // At a prompt, ^L clears the screen and redraws the prompt at the top.
        if !isRunningCommand { send([0x0c]) }
    }

    // MARK: drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDropHighlight?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropHighlight?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDropHighlight?(false)
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            send(txt: urls.map { ProcInfo.shellEscape($0.path) }.joined(separator: " ") + " ")
            return true
        }
        if let s = pb.string(forType: .string) {
            send(txt: s)
            return true
        }
        return false
    }
}
