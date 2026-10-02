import AppKit

struct Command {
    let title: String
    let group: String
    let symbol: String
    var shortcut: String? = nil
    var checked = false
    var preview: (() -> Void)? = nil
    let run: () -> Void
}

/// Subsequence match with bonuses for word starts and consecutive runs.
func fuzzyMatch(_ query: String, _ text: String) -> (score: Int, indices: [Int])? {
    let q = Array(query.lowercased().filter { !$0.isWhitespace })
    if q.isEmpty { return (0, []) }
    let s = Array(text.lowercased())
    var qi = 0, score = 0, last = -2
    var indices: [Int] = []
    for (i, c) in s.enumerated() where qi < q.count && c == q[qi] {
        var bonus = 1
        if i == 0 || " ·:-/".contains(s[i - 1]) { bonus += 8 }
        if last == i - 1 { bonus += 5 }
        score += bonus
        indices.append(i)
        last = i
        qi += 1
    }
    return qi == q.count ? (score * 10 - s.count, indices) : nil
}

/// ⌘P command menu: backdrop, floating panel, search field, animated selection.
final class CommandPalette: NSView, NSTextFieldDelegate {
    var onClose: ((_ ranCommand: Bool) -> Void)?
    /// Called when the selection leaves a previewable command, so the preview can be reverted.
    var onEndPreview: (() -> Void)?

    private let backdrop = NSView()
    private let panel = NSView()
    private let field = NSTextField()
    private let searchIcon = NSImageView()
    private let separator = NSView()
    private let list = PaletteList()
    private let footer = PaletteFooter()
    private var commands: [Command] = []
    private var theme: Theme
    private(set) var closing = false

    static let width: CGFloat = 600

    init(commands: [Command], theme: Theme, query: String) {
        self.commands = commands
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true

        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(theme.isDark ? 0.45 : 0.14).cgColor
        addSubview(backdrop)

        panel.wantsLayer = true
        if let l = panel.layer {
            l.backgroundColor = theme.panelColor.cgColor
            l.cornerRadius = 12
            l.borderWidth = 1
            l.borderColor = theme.borderColor.cgColor
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = theme.isDark ? 0.5 : 0.16
            l.shadowRadius = 30
            l.shadowOffset = CGSize(width: 0, height: -12)
        }
        addSubview(panel)

        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        searchIcon.contentTintColor = theme.mutedColor
        panel.addSubview(searchIcon)

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.textColor = theme.fgColor
        field.placeholderAttributedString = NSAttributedString(string: "Type a command or search…", attributes: [
            .foregroundColor: theme.mutedColor, .font: NSFont.systemFont(ofSize: 15)])
        field.stringValue = query
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        panel.addSubview(field)

        separator.wantsLayer = true
        separator.layer?.backgroundColor = theme.borderColor.cgColor
        panel.addSubview(separator)

        list.theme = theme
        list.onRun = { [weak self] i in self?.run(i) }
        list.onHover = { [weak self] _ in self?.previewSelection() }
        panel.addSubview(list)

        footer.theme = theme
        panel.addSubview(footer)
        filter()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    // MARK: presentation

    func present(in host: NSView) {
        frame = host.bounds
        autoresizingMask = [.width, .height]
        host.addSubview(self)
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertionPointColor = theme.accentColor
            editor.selectedTextAttributes = [.backgroundColor: NSColor(hex: theme.selection)]
        }

        backdrop.layer?.add(fade(from: 0, to: 1, duration: 0.2), forKey: nil)
        guard let l = panel.layer else { return }
        let g = CAAnimationGroup()
        g.animations = [fade(from: 0, to: 1, duration: 0.16), transform(from: 0.965, dy: -10)]
        g.duration = 0.32
        g.timingFunction = easeOutExpo
        l.add(g, forKey: nil)
    }

    func dismiss(ran: Bool) {
        guard !closing else { return }
        closing = true
        onClose?(ran)
        let g = CAAnimationGroup()
        g.animations = [fade(from: 1, to: 0, duration: 0.14), transform(to: 0.98, dy: -4)]
        g.duration = 0.14
        g.timingFunction = CAMediaTimingFunction(name: .easeIn)
        g.fillMode = .forwards
        g.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperview() }
        panel.layer?.add(g, forKey: nil)
        let b = fade(from: 1, to: 0, duration: 0.16)
        b.fillMode = .forwards
        b.isRemovedOnCompletion = false
        backdrop.layer?.add(b, forKey: nil)
        CATransaction.commit()
    }

    private func fade(from: Float, to: Float, duration: CFTimeInterval) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        return a
    }

    /// Scale around the panel's center (layer-backed views anchor at the origin).
    private func centeredScale(_ s: CGFloat, dy: CGFloat) -> CATransform3D {
        let w = panel.bounds.width, h = panel.bounds.height
        var t = CATransform3DMakeTranslation(w / 2, h / 2 + dy, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -w / 2, -h / 2, 0)
    }

    private func transform(from s: CGFloat, dy: CGFloat) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = NSValue(caTransform3D: centeredScale(s, dy: dy))
        a.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        return a
    }

    private func transform(to s: CGFloat, dy: CGFloat) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        a.toValue = NSValue(caTransform3D: centeredScale(s, dy: dy))
        return a
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        let w = min(CommandPalette.width, bounds.width - 32)
        let rows = CGFloat(min(max(list.rows.count, 1), PaletteList.maxRows))
        let listH = rows * PaletteList.rowH + 12
        let h = 52 + 1 + listH + 36
        let y = max(16, min(bounds.height * 0.13, bounds.height - h - 16))
        let newFrame = NSRect(x: (bounds.width - w) / 2, y: y, width: w, height: h)
        // The panel grows/shrinks smoothly as results change.
        if panel.frame.width > 0 && panel.frame.height != h && !closing {
            animate(0.18) { panel.animator().frame = newFrame }
        } else {
            panel.frame = newFrame
        }
        layoutPanel(width: w, height: h, listH: listH)
    }

    private func layoutPanel(width w: CGFloat, height h: CGFloat, listH: CGFloat) {
        // panel is not flipped: lay out from the top down.
        searchIcon.frame = NSRect(x: 18, y: h - 52 + 17, width: 18, height: 18)
        field.frame = NSRect(x: 46, y: h - 52 + 15, width: w - 64, height: 22)
        separator.frame = NSRect(x: 0, y: h - 53, width: w, height: 1)
        list.frame = NSRect(x: 0, y: 36, width: w, height: listH)
        footer.frame = NSRect(x: 0, y: 0, width: w, height: 36)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !panel.frame.contains(p) { dismiss(ran: false) }
    }

    // MARK: filtering & running

    private func filter() {
        let q = field.stringValue
        var scored: [(Command, Int, [Int])] = []
        for c in commands {
            if let m = fuzzyMatch(q, c.title) {
                scored.append((c, m.score + 5, m.indices))
            } else if let m = fuzzyMatch(q, c.group + " " + c.title) {
                scored.append((c, m.score, []))
            }
        }
        if !q.isEmpty { scored.sort { $0.1 > $1.1 } }
        list.rows = scored.map { PaletteList.Row(command: $0.0, matches: Set($0.2)) }
        list.select(0, animated: false)
        needsLayout = true
        // Typing never previews: only an explicit arrow/hover onto a theme does.
        onEndPreview?()
    }

    private func previewSelection() {
        guard list.rows.indices.contains(list.selected),
              let preview = list.rows[list.selected].command.preview else {
            onEndPreview?()
            return
        }
        preview()
    }

    private func run(_ i: Int) {
        guard list.rows.indices.contains(i) else { return }
        let cmd = list.rows[i].command
        dismiss(ran: true)
        DispatchQueue.main.async { cmd.run() }
    }

    func controlTextDidChange(_ obj: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(moveUp(_:)), #selector(insertBacktab(_:)):
            list.move(-1); previewSelection(); return true
        case #selector(moveDown(_:)), #selector(insertTab(_:)):
            list.move(1); previewSelection(); return true
        case #selector(insertNewline(_:)):
            run(list.selected); return true
        case #selector(cancelOperation(_:)):
            dismiss(ran: false); return true
        default:
            return false
        }
    }
}

/// Rows drawn by hand; a single highlight layer slides between them.
final class PaletteList: NSView {
    struct Row {
        let command: Command
        let matches: Set<Int>
    }

    static let rowH: CGFloat = 38
    static let maxRows = 9

    var theme = Settings.shared.theme { didSet { highlight.backgroundColor = theme.hoverColor.cgColor } }
    var rows: [Row] = [] { didSet { top = 0; canvas.needsDisplay = true } }
    private(set) var selected = 0
    var onRun: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?
    private var top = 0
    private let highlightView = PassthroughView()
    private var highlight: CALayer { highlightView.layer! }
    private let accentBar = CALayer()
    private let canvas = PaletteCanvas()
    private var tracking: NSTrackingArea?
    private var lastMouse: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Rows are drawn by a canvas subview above the highlight; a layer's own
        // drawing would otherwise sit underneath its sublayers.
        highlightView.wantsLayer = true
        addSubview(highlightView)
        canvas.list = self
        addSubview(canvas)
        highlight.cornerRadius = 8
        highlight.backgroundColor = theme.hoverColor.cgColor
        highlight.addSublayer(accentBar)
        accentBar.cornerRadius = 1
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

    func move(_ d: Int) {
        guard !rows.isEmpty else { return }
        select((selected + d + rows.count) % rows.count, animated: true)
    }

    func select(_ i: Int, animated: Bool) {
        guard !rows.isEmpty else { highlight.opacity = 0; return }
        selected = max(0, min(i, rows.count - 1))
        let visible = min(rows.count, PaletteList.maxRows)
        let oldTop = top
        if selected < top { top = selected }
        if selected >= top + visible { top = selected - visible + 1 }
        if top != oldTop { canvas.needsDisplay = true }
        placeHighlight(animated: animated && top == oldTop)
    }

    private func rowRect(_ i: Int) -> NSRect {
        NSRect(x: 8, y: 6 + CGFloat(i - top) * PaletteList.rowH, width: bounds.width - 16, height: PaletteList.rowH)
    }

    private func placeHighlight(animated: Bool) {
        let r = rowRect(selected)
        highlight.opacity = 1
        if animated {
            animate(0.18) { highlightView.animator().frame = r }
        } else {
            highlightView.frame = r
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        accentBar.backgroundColor = theme.accentColor.cgColor
        accentBar.frame = NSRect(x: 0, y: 10, width: 2, height: PaletteList.rowH - 20)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        canvas.frame = bounds
        placeHighlight(animated: false)
    }

    func drawRows() {
        if rows.isEmpty {
            let s = NSAttributedString(string: "No results", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: theme.mutedColor])
            s.draw(at: NSPoint(x: (bounds.width - s.size().width) / 2, y: 16))
            return
        }
        let end = min(rows.count, top + PaletteList.maxRows)
        for i in top..<end {
            let r = rowRect(i)
            let c = rows[i].command
            let iconCfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(.init(paletteColors: [theme.mutedColor]))
            if let img = NSImage(systemSymbolName: c.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(iconCfg) {
                let s = img.size
                img.draw(in: NSRect(x: r.minX + 12 + (18 - s.width) / 2, y: r.midY - s.height / 2,
                                    width: s.width, height: s.height))
            }
            let title = NSMutableAttributedString(string: c.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13.5, weight: .regular),
                .foregroundColor: theme.fgColor.withAlphaComponent(0.88)])
            let ns = c.title as NSString
            for idx in rows[i].matches where idx < ns.length {
                title.addAttributes([.foregroundColor: theme.fgColor,
                                     .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold)],
                                    range: NSRange(location: idx, length: 1))
            }
            let ts = title.size()
            title.draw(at: NSPoint(x: r.minX + 42, y: r.midY - ts.height / 2))

            var right = r.maxX - 10
            if c.checked {
                let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                    .applying(.init(paletteColors: [theme.accentColor]))
                if let img = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                    .withSymbolConfiguration(cfg) {
                    img.draw(in: NSRect(x: right - img.size.width, y: r.midY - img.size.height / 2,
                                        width: img.size.width, height: img.size.height))
                    right -= img.size.width + 10
                }
            }
            if let k = c.shortcut {
                right -= drawKbd(k, rightEdge: right, theme: theme, in: r) + 10
            }
            let group = NSAttributedString(string: c.group, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: theme.mutedColor])
            let gs = group.size()
            if r.minX + 42 + ts.width + 16 < right - gs.width {
                group.draw(at: NSPoint(x: right - gs.width, y: r.midY - gs.height / 2))
            }
        }
    }

    private func index(at p: NSPoint) -> Int? {
        let i = Int((p.y - 6) / PaletteList.rowH) + top
        return rows.indices.contains(i) && p.y >= 6 ? i : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Ignore synthetic moves caused by the list re-rendering under a still cursor.
        if let last = lastMouse, hypot(last.x - p.x, last.y - p.y) < 1 { return }
        lastMouse = p
        if let i = index(at: p), i != selected {
            select(i, animated: true)
            onHover?(i)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)) { onRun?(i) }
    }

    override func scrollWheel(with event: NSEvent) {
        let visible = min(rows.count, PaletteList.maxRows)
        let maxTop = max(0, rows.count - visible)
        let step = event.scrollingDeltaY > 0 ? -1 : (event.scrollingDeltaY < 0 ? 1 : 0)
        let nt = max(0, min(maxTop, top + step))
        guard nt != top else { return }
        top = nt
        selected = max(top, min(selected, top + visible - 1))
        placeHighlight(animated: false)
        canvas.needsDisplay = true
    }
}

final class PaletteCanvas: NSView {
    weak var list: PaletteList?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { list?.drawRows() }
}

final class PaletteFooter: NSView {
    var theme = Settings.shared.theme

    override func draw(_ dirtyRect: NSRect) {
        theme.borderColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        let brand = NSAttributedString(string: "bterm", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: theme.mutedColor])
        brand.draw(at: NSPoint(x: 18, y: (bounds.height - brand.size().height) / 2))
        var right = bounds.width - 14
        for (k, label) in [("esc", "Close"), ("↵", "Run"), ("↑↓", "Navigate")] {
            let l = NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: theme.mutedColor])
            let ls = l.size()
            l.draw(at: NSPoint(x: right - ls.width, y: (bounds.height - ls.height) / 2))
            right -= ls.width + 6
            right -= drawKbd(k, rightEdge: right, theme: theme, in: bounds) + 16
        }
    }
}
