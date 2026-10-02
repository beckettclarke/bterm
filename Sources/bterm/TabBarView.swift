import AppKit

enum TabState: Equatable { case idle, running, activity }

struct TabInfo: Equatable {
    let id: UUID
    var title: String
    var state: TabState
}

let easeOutExpo = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

func animate(_ duration: TimeInterval = 0.28, _ changes: () -> Void, completion: (() -> Void)? = nil) {
    NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = duration
        ctx.timingFunction = easeOutExpo
        ctx.allowsImplicitAnimation = true
        changes()
    }, completionHandler: completion)
}

/// A single tab, built from layers so hover, state and position changes animate for free.
final class TabItemView: NSView {
    let id: UUID
    var info: TabInfo { didSet { refresh() } }
    var selected = false { didSet { refresh() } }
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onDrag: ((NSEvent, CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?

    private let pill = CALayer()
    private let dot = CALayer()
    private let label = CATextLayer()
    private let closeBg = CALayer()
    private let closeX = CAShapeLayer()
    private var hovering = false
    private var closeHover = false
    private var tracking: NSTrackingArea?
    private var dragStartX: CGFloat?
    private var dragging = false
    private var theme = Settings.shared.theme

    static let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)

    init(info: TabInfo) {
        id = info.id
        self.info = info
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        for l in [pill, dot, label, closeBg, closeX] as [CALayer] { layer?.addSublayer(l) }
        pill.cornerRadius = 7
        dot.cornerRadius = 3
        closeBg.cornerRadius = 4
        label.font = TabItemView.font
        label.fontSize = TabItemView.font.pointSize
        label.truncationMode = .end
        label.alignmentMode = .left
        closeX.lineWidth = 1.4
        closeX.lineCap = .round
        closeX.fillColor = nil
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { false }

    static func idealWidth(for title: String) -> CGFloat {
        let w = (title as NSString).size(withAttributes: [.font: font]).width
        return min(max(ceil(w) + 58, 104), 220)
    }

    func applyTheme(_ t: Theme) {
        theme = t
        refresh()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        for l in [pill, dot, label, closeBg, closeX] as [CALayer] { l.contentsScale = s }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let h = bounds.height
        pill.frame = bounds.insetBy(dx: 2, dy: 0)
        dot.frame = NSRect(x: 14, y: (h - 6) / 2, width: 6, height: 6)
        let textH = ceil(TabItemView.font.ascender - TabItemView.font.descender) + 1
        label.frame = NSRect(x: 28, y: (h - textH) / 2 - 1, width: max(0, bounds.width - 28 - 30), height: textH)
        closeBg.frame = closeRect
        let c = closeRect.insetBy(dx: 5.5, dy: 5.5)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.minX, y: c.minY)); p.addLine(to: CGPoint(x: c.maxX, y: c.maxY))
        p.move(to: CGPoint(x: c.minX, y: c.maxY)); p.addLine(to: CGPoint(x: c.maxX, y: c.minY))
        closeX.path = p
        CATransaction.commit()
    }

    private var closeRect: NSRect {
        NSRect(x: bounds.width - 26, y: (bounds.height - 18) / 2, width: 18, height: 18)
    }

    private func refresh() {
        let fg = selected || hovering ? theme.fgColor : theme.mutedColor
        label.string = info.title
        label.foregroundColor = fg.cgColor
        pill.backgroundColor = (hovering || dragging ? theme.hoverColor : .clear).cgColor
        let showClose = hovering || selected
        closeX.strokeColor = (closeHover ? theme.fgColor : theme.mutedColor).cgColor
        closeX.opacity = showClose ? 1 : 0
        closeBg.backgroundColor = (closeHover ? theme.borderColor : .clear).cgColor

        switch info.state {
        case .idle:
            dot.backgroundColor = theme.mutedColor.withAlphaComponent(selected ? 0.9 : 0.5).cgColor
            dot.removeAnimation(forKey: "pulse")
        case .running:
            dot.backgroundColor = theme.successColor.cgColor
            if dot.animation(forKey: "pulse") == nil {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 1
                a.toValue = 0.35
                a.duration = 0.9
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                dot.add(a, forKey: "pulse")
            }
        case .activity:
            dot.backgroundColor = NSColor(hex: theme.ansi[12]).cgColor
            dot.removeAnimation(forKey: "pulse")
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; closeHover = false; refresh() }
    override func mouseMoved(with event: NSEvent) {
        let inside = closeRect.contains(convert(event.locationInWindow, from: nil))
        if inside != closeHover { closeHover = inside; refresh() }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if closeRect.contains(p) && (hovering || selected) {
            onClose?()
            return
        }
        if event.clickCount == 1 { onSelect?() }
        dragStartX = event.locationInWindow.x
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartX else { return }
        let dx = event.locationInWindow.x - start
        if !dragging && abs(dx) < 4 { return }
        if !dragging { dragging = true; refresh() }
        onDrag?(event, dx)
    }

    override func mouseUp(with event: NSEvent) {
        if dragging { dragging = false; refresh(); onDragEnd?() }
        dragStartX = nil
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() }   // middle-click closes
    }
}

/// Small icon button used in the chrome (new tab, etc).
final class ChromeButton: NSView {
    var onClick: (() -> Void)?
    private let bg = CALayer()
    private let icon = CALayer()
    private var symbol: String
    private var hovering = false
    private var theme = Settings.shared.theme
    private var tracking: NSTrackingArea?

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        wantsLayer = true
        bg.cornerRadius = 7
        layer?.addSublayer(bg)
        layer?.addSublayer(icon)
        icon.contentsGravity = .center
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var mouseDownCanMoveWindow: Bool { false }

    func applyTheme(_ t: Theme) { theme = t; refresh() }

    private func refresh() {
        bg.backgroundColor = (hovering ? theme.hoverColor : .clear).cgColor
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            .applying(.init(paletteColors: [hovering ? theme.fgColor : theme.mutedColor]))
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        icon.contents = img
        icon.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidChangeBackingProperties() { refresh() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bg.frame = bounds
        icon.frame = bounds
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }
    override func mouseDown(with event: NSEvent) {
        bg.opacity = 0.6
    }
    override func mouseUp(with event: NSEvent) {
        bg.opacity = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// Vercel-style search trigger: "Search commands…  ⌘P".
final class PaletteTrigger: NSView {
    var onClick: (() -> Void)?
    private var theme = Settings.shared.theme
    private var hovering = false
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func applyTheme(_ t: Theme) { theme = t; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        (hovering ? theme.hoverColor : theme.bgColor).setFill()
        path.fill()
        theme.borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(.init(paletteColors: [theme.mutedColor]))
        if let img = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            img.draw(in: NSRect(x: 10, y: (bounds.height - img.size.height) / 2,
                                width: img.size.width, height: img.size.height))
        }
        let text = NSAttributedString(string: "Commands", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: hovering ? theme.fgColor : theme.mutedColor])
        let ts = text.size()
        text.draw(at: NSPoint(x: 28, y: (bounds.height - ts.height) / 2))
        drawKbd("⌘P", rightEdge: bounds.width - 6, theme: theme, in: bounds)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseUp(with event: NSEvent) { onClick?() }
}

/// Draws a keyboard shortcut chip right-aligned at `rightEdge`, vertically centered; returns its width.
@discardableResult
func drawKbd(_ keys: String, rightEdge: CGFloat, theme: Theme, in rect: NSRect, y: CGFloat? = nil) -> CGFloat {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
        .foregroundColor: theme.mutedColor]
    let s = NSAttributedString(string: keys, attributes: attrs)
    let size = s.size()
    let w = ceil(size.width) + 10, h: CGFloat = 18
    let chip = NSRect(x: rightEdge - w, y: y ?? (rect.midY - h / 2), width: w, height: h)
    let p = NSBezierPath(roundedRect: chip.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
    theme.hoverColor.setFill()
    p.fill()
    theme.borderColor.setStroke()
    p.lineWidth = 1
    p.stroke()
    s.draw(at: NSPoint(x: chip.minX + 5, y: chip.midY - size.height / 2))
    return w
}

/// The window's top bar: traffic-light gutter, tabs with a sliding indicator, new-tab and palette buttons.
final class TabBarView: NSView {
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onNew: (() -> Void)?
    var onPalette: (() -> Void)?
    var onReorder: (([UUID]) -> Void)?

    var leadingInset: CGFloat = 84 { didSet { needsLayout = true } }
    private(set) var items: [TabItemView] = []
    private var selectedID: UUID?
    private let indicator = CALayer()
    private let bottomLine = CALayer()
    private let addButton = ChromeButton(symbol: "plus")
    private let trigger = PaletteTrigger()
    private var theme = Settings.shared.theme
    private var dragOrigin: CGFloat = 0
    private var dragItem: TabItemView?

    static let height: CGFloat = 40

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(bottomLine)
        addSubview(addButton)
        addSubview(trigger)
        layer?.addSublayer(indicator)
        indicator.cornerRadius = 1
        indicator.zPosition = 10
        addButton.onClick = { [weak self] in self?.onNew?() }
        trigger.onClick = { [weak self] in self?.onPalette?() }
        addButton.toolTip = "New Tab (⌘T)"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    func applyTheme(_ t: Theme, glass: Bool) {
        theme = t
        layer?.backgroundColor = t.chromeColor.withAlphaComponent(glass ? 0.7 : 1).cgColor
        bottomLine.backgroundColor = t.borderColor.cgColor
        indicator.backgroundColor = t.accentColor.cgColor
        items.forEach { $0.applyTheme(t) }
        addButton.applyTheme(t)
        trigger.applyTheme(t)
    }

    func update(tabs: [TabInfo], selected: UUID?, animated: Bool) {
        let ids = Set(tabs.map(\.id))
        // Removed tabs collapse and fade.
        for item in items where !ids.contains(item.id) {
            animate(0.2, {
                item.animator().alphaValue = 0
                var f = item.frame
                f.size.width = 0
                item.animator().frame = f
            }, completion: { item.removeFromSuperview() })
        }
        var next: [TabItemView] = []
        for info in tabs {
            if let existing = items.first(where: { $0.id == info.id }) {
                if existing.info != info { existing.info = info }
                next.append(existing)
            } else {
                let item = TabItemView(info: info)
                item.applyTheme(theme)
                item.onSelect = { [weak self] in self?.onSelect?(info.id) }
                item.onClose = { [weak self] in self?.onClose?(info.id) }
                item.onDrag = { [weak self, weak item] e, dx in if let item { self?.drag(item, dx: dx) } }
                item.onDragEnd = { [weak self] in self?.endDrag() }
                addSubview(item, positioned: .below, relativeTo: addButton)
                if animated {
                    // Grow in from the position where it will land.
                    item.alphaValue = 0
                    item.frame = NSRect(x: insertionX(for: info.id, in: tabs), y: 6, width: 0, height: TabBarView.height - 12)
                }
                next.append(item)
            }
        }
        items = next
        selectedID = selected
        for item in items { item.selected = item.id == selected }
        relayout(animated: animated)
    }

    private func insertionX(for id: UUID, in tabs: [TabInfo]) -> CGFloat {
        guard let i = tabs.firstIndex(where: { $0.id == id }), i > 0,
              let prev = items.first(where: { $0.id == tabs[i - 1].id }) else { return leadingInset }
        return prev.frame.maxX
    }

    private func widths() -> [CGFloat] {
        let available = bounds.width - leadingInset - 36 - 160
        var ws = items.map { TabItemView.idealWidth(for: $0.info.title) }
        let total = ws.reduce(0, +)
        if total > available, total > 0 {
            let scale = max(available, 0) / total
            ws = ws.map { max(64, floor($0 * scale)) }
        }
        return ws
    }

    private func frames() -> [NSRect] {
        var x = leadingInset
        return widths().map { w in
            defer { x += w }
            return NSRect(x: x, y: 6, width: w, height: TabBarView.height - 12)
        }
    }

    func relayout(animated: Bool) {
        let fs = frames()
        let addX = (fs.last?.maxX ?? leadingInset) + 4
        let change = {
            for (item, f) in zip(self.items, fs) where item !== self.dragItem {
                (animated ? item.animator() : item).frame = f
                if animated { item.animator().alphaValue = 1 } else { item.alphaValue = 1 }
            }
            (animated ? self.addButton.animator() : self.addButton).frame =
                NSRect(x: addX, y: 8, width: 24, height: 24)
        }
        if animated { animate(0.3, change) } else { change() }
        moveIndicator(animated: animated)
    }

    private func moveIndicator(animated: Bool) {
        guard let sel = items.firstIndex(where: { $0.id == selectedID }) else {
            indicator.opacity = 0
            return
        }
        let f = dragItem?.id == selectedID ? items[sel].frame : frames()[sel]
        let target = NSRect(x: f.minX + 12, y: TabBarView.height - 2, width: max(0, f.width - 24), height: 2)
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.38)
            CATransaction.setAnimationTimingFunction(easeOutExpo)
        } else {
            CATransaction.setDisableActions(true)
        }
        indicator.frame = target
        indicator.opacity = 1
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bottomLine.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        CATransaction.commit()
        trigger.frame = NSRect(x: bounds.width - 152, y: 8, width: 140, height: 24)
        relayout(animated: false)
    }

    // MARK: drag to reorder

    private func drag(_ item: TabItemView, dx: CGFloat) {
        if dragItem == nil {
            dragItem = item
            dragOrigin = item.frame.minX
            item.layer?.zPosition = 5
        }
        var f = item.frame
        f.origin.x = max(leadingInset, dragOrigin + dx)
        item.frame = f
        moveIndicator(animated: false)
        // Swap with neighbours once the dragged tab's center crosses theirs.
        guard let i = items.firstIndex(where: { $0 === item }) else { return }
        let fs = frames()
        if i + 1 < items.count, f.maxX > fs[i + 1].midX {
            items.swapAt(i, i + 1)
            relayout(animated: true)
        } else if i > 0, f.minX < fs[i - 1].midX {
            items.swapAt(i, i - 1)
            relayout(animated: true)
        }
    }

    private func endDrag() {
        dragItem?.layer?.zPosition = 0
        dragItem = nil
        relayout(animated: true)
        onReorder?(items.map(\.id))
    }

    // MARK: window dragging on empty space

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window?.performMiniaturize(nil) }
            else if action != "None" { window?.performZoom(nil) }
            return
        }
        window?.performDrag(with: event)
    }
}
