import AppKit

// MARK: - small AppKit helpers

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Retains a closure as an AppKit control's target.
private final class ControlAction: NSObject {
    let handler: (NSControl) -> Void
    init(_ handler: @escaping (NSControl) -> Void) { self.handler = handler }
    @objc func fire(_ sender: NSControl) { handler(sender) }
}

private var controlActionKey: UInt8 = 0

extension NSControl {
    func onAction(_ handler: @escaping (NSControl) -> Void) {
        let a = ControlAction(handler)
        objc_setAssociatedObject(self, &controlActionKey, a, .OBJC_ASSOCIATION_RETAIN)
        target = a
        action = #selector(ControlAction.fire(_:))
    }
}

private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    return l
}

// MARK: - window controller

/// Standalone preferences window (⌘,). Every control writes straight to `Settings`,
/// so terminals update live; the window re-themes itself when the theme changes.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private enum Page: Int, CaseIterable {
        case appearance, text, motion, advanced, about

        var title: String {
            ["Appearance", "Text", "Cursor & Motion", "Advanced", "About"][rawValue]
        }
        var subtitle: String {
            ["Theme and window material.",
             "Typeface and size used in every terminal.",
             "Caret shape and the animations around it.",
             "Keyboard behaviour and rendering.",
             "Version and credits."][rawValue]
        }
        var symbol: String {
            ["paintpalette", "textformat", "cursorarrow.motionlines", "keyboard", "info.circle"][rawValue]
        }
    }

    private let root = FlippedView()
    private let sidebar = SettingsSidebar()
    private let divider = NSView()
    private let content = FlippedView()
    private var pageView: NSView?
    private var page: Page = .appearance
    private var refreshers: [() -> Void] = []
    private var appearanceKey = ""
    private var observer: NSObjectProtocol?

    static let size = NSSize(width: 800, height: 580)
    static let sidebarWidth: CGFloat = 210

    private init() {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsWindowController.size),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Settings"
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.contentView = root
        super.init(window: w)
        w.delegate = self

        root.wantsLayer = true
        content.wantsLayer = true
        divider.wantsLayer = true
        [sidebar, divider, content].forEach(root.addSubview)
        sidebar.items = Page.allCases.map { ($0.symbol, $0.title) }
        sidebar.onSelect = { [weak self] i in self?.show(page: Page(rawValue: i) ?? .appearance, animated: true) }

        layout()
        applyTheme()
        let initial = ProcessInfo.processInfo.environment["BTERM_SETTINGS_PAGE"].flatMap(Int.init).flatMap(Page.init(rawValue:))
        show(page: initial ?? .appearance, animated: false)

        observer = NotificationCenter.default.addObserver(forName: .btermSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.settingsChanged()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        guard let w = window else { return }
        if !w.isVisible {
            w.center()
            w.alphaValue = 0
            w.makeKeyAndOrderFront(nil)
            animate(0.2) { w.animator().alphaValue = 1 }
        } else {
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func layout() {
        let s = SettingsWindowController.size
        let sw = SettingsWindowController.sidebarWidth
        root.frame = NSRect(origin: .zero, size: s)
        sidebar.frame = NSRect(x: 0, y: 0, width: sw, height: s.height)
        divider.frame = NSRect(x: sw, y: 0, width: 1, height: s.height)
        content.frame = NSRect(x: sw + 1, y: 0, width: s.width - sw - 1, height: s.height)
    }

    private func applyTheme() {
        let t = Settings.shared.theme
        window?.appearance = t.appearance
        window?.backgroundColor = t.bgColor
        root.layer?.backgroundColor = t.bgColor.cgColor
        content.layer?.backgroundColor = t.bgColor.cgColor
        divider.layer?.backgroundColor = t.borderColor.cgColor
        sidebar.theme = t
        appearanceKey = t.id
    }

    private func settingsChanged() {
        if Settings.shared.theme.id != appearanceKey {
            // Re-skin: cross-fade the whole window into the new palette.
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.3
            root.layer?.add(fade, forKey: "theme")
            applyTheme()
            show(page: page, animated: false)
        } else {
            refreshers.forEach { $0() }
        }
    }

    private func show(page p: Page, animated: Bool) {
        let direction: CGFloat = p.rawValue >= page.rawValue ? 1 : -1
        page = p
        sidebar.select(p.rawValue, animated: animated)
        refreshers.removeAll()

        let v = build(p)
        v.frame = content.bounds
        let old = pageView
        pageView = v
        content.addSubview(v)

        if animated, let l = v.layer {
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = 10 * direction
            slide.toValue = 0
            slide.isAdditive = true
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let g = CAAnimationGroup()
            g.animations = [slide, fade]
            g.duration = 0.32
            g.timingFunction = easeOutExpo
            l.add(g, forKey: "in")
            if let old {
                animate(0.12, { old.animator().alphaValue = 0 }, completion: { old.removeFromSuperview() })
            }
        } else {
            old?.removeFromSuperview()
        }
    }

    // MARK: pages

    private func build(_ p: Page) -> NSView {
        let t = Settings.shared.theme
        let page = SettingsPage(theme: t, title: p.title, subtitle: p.subtitle,
                                width: content.bounds.width)
        switch p {
        case .appearance: buildAppearance(page)
        case .text: buildText(page)
        case .motion: buildMotion(page)
        case .advanced: buildAdvanced(page)
        case .about: buildAbout(page)
        }
        return page
    }

    private func buildAppearance(_ page: SettingsPage) {
        let t = page.theme
        page.section("Theme")
        let grid = ThemeGrid(current: t)
        page.add(grid, height: grid.height(for: page.contentWidth))
        page.section("Window")
        let card = SettingsCard(theme: t)
        card.addRow(title: "Glass background",
                    detail: "Blur the desktop behind the window.",
                    control: toggle(\.glass))
        page.add(card, height: card.height)
    }

    private func buildText(_ page: SettingsPage) {
        let t = page.theme
        let s = Settings.shared
        let card = SettingsCard(theme: t)

        let fonts = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 190, height: 26), pullsDown: false)
        for f in Settings.installedFonts {
            fonts.addItem(withTitle: f)
            let font = f == "SF Mono" ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                : (NSFont(name: f, size: 13) ?? NSFontManager.shared.font(withFamily: f, traits: [], weight: 5, size: 13))
            if let font {
                fonts.lastItem?.attributedTitle = NSAttributedString(string: f, attributes: [.font: font])
            }
        }
        fonts.selectItem(withTitle: s.displayFontName)
        fonts.onAction { c in
            guard let title = (c as? NSPopUpButton)?.titleOfSelectedItem else { return }
            Settings.shared.fontName = title == "SF Mono" ? "" : title
        }
        refreshers.append { [weak fonts] in fonts?.selectItem(withTitle: Settings.shared.displayFontName) }
        card.addRow(title: "Font", detail: "Installed monospaced families.", control: fonts)

        let size = SizeControl(theme: t)
        refreshers.append { [weak size] in size?.refresh() }
        card.addRow(title: "Size", detail: "Or ⌘+ / ⌘− in any window.", control: size)
        page.add(card, height: card.height)

        page.section("Preview")
        let preview = FontPreview(theme: t)
        refreshers.append { [weak preview] in preview?.needsDisplay = true }
        page.add(preview, height: 168)
    }

    private func buildMotion(_ page: SettingsPage) {
        let t = page.theme
        let card = SettingsCard(theme: t)
        let shapes = CursorShape.allCases
        let seg = NSSegmentedControl(labels: shapes.map { $0.rawValue.capitalized },
                                     trackingMode: .selectOne, target: nil, action: nil)
        seg.selectedSegment = shapes.firstIndex(of: Settings.shared.cursor) ?? 0
        seg.onAction { c in
            let i = (c as? NSSegmentedControl)?.selectedSegment ?? 0
            Settings.shared.cursor = shapes[max(0, i)]
        }
        refreshers.append { [weak seg] in seg?.selectedSegment = shapes.firstIndex(of: Settings.shared.cursor) ?? 0 }
        card.addRow(title: "Cursor shape", detail: "Programs like vim can still change it.", control: seg)
        card.addRow(title: "Cursor glide", detail: "The caret slides between cells instead of jumping.",
                    control: toggle(\.cursorGlide))
        card.addRow(title: "Smooth scrolling", detail: "New lines slide in. Skipped for floods and full-screen apps.",
                    control: toggle(\.smoothScroll))
        page.add(card, height: card.height)
    }

    private func buildAdvanced(_ page: SettingsPage) {
        let t = page.theme
        let card = SettingsCard(theme: t)
        card.addRow(title: "Option as Meta", detail: "Send Esc-prefixed keys; turn off to type ⌥ characters.",
                    control: toggle(\.optionAsMeta))
        card.addRow(title: "GPU renderer", detail: "Metal rendering for heavy output. Disables cursor glide.",
                    control: toggle(\.gpu))
        page.add(card, height: card.height)

        page.section("Reset")
        let reset = SettingsCard(theme: t)
        let button = NSButton(title: "Reset…", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.onAction { [weak self] _ in self?.confirmReset() }
        reset.addRow(title: "Restore defaults", detail: "Theme, font, cursor and all toggles.", control: button)
        page.add(reset, height: reset.height)
    }

    private func buildAbout(_ page: SettingsPage) {
        page.add(AboutView(theme: page.theme), height: 260)
    }

    private func toggle(_ kp: ReferenceWritableKeyPath<Settings, Bool>) -> NSView {
        let sw = NSSwitch()
        sw.controlSize = .small
        sw.state = Settings.shared[keyPath: kp] ? .on : .off
        sw.onAction { c in Settings.shared[keyPath: kp] = (c as? NSSwitch)?.state == .on }
        refreshers.append { [weak sw] in sw?.state = Settings.shared[keyPath: kp] ? .on : .off }
        return sw
    }

    private func confirmReset() {
        guard let window else { return }
        let a = NSAlert()
        a.messageText = "Restore default settings?"
        a.informativeText = "Your terminals keep running; only preferences change."
        a.addButton(withTitle: "Reset")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { r in
            if r == .alertFirstButtonReturn { Settings.shared.resetAll() }
        }
    }
}

// MARK: - sidebar

final class SettingsSidebar: FlippedView {
    var items: [(symbol: String, title: String)] = [] { didSet { rebuild() } }
    var onSelect: ((Int) -> Void)?
    var theme = Settings.shared.theme { didSet { rebuild() } }

    private var rows: [SidebarRow] = []
    private let highlight = PassthroughView()
    private let brand = NSTextField(labelWithString: "")
    private var selected = 0

    static let rowH: CGFloat = 32
    static let top: CGFloat = 56

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 7
        addSubview(highlight)
        addSubview(brand)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func rebuild() {
        layer?.backgroundColor = theme.chromeColor.cgColor
        highlight.layer?.backgroundColor = theme.hoverColor.cgColor
        highlight.layer?.borderWidth = 1
        highlight.layer?.borderColor = theme.borderColor.cgColor
        rows.forEach { $0.removeFromSuperview() }
        rows = items.enumerated().map { i, item in
            let r = SidebarRow(symbol: item.symbol, title: item.title, theme: theme)
            r.onClick = { [weak self] in
                guard let self, self.selected != i else { return }
                self.onSelect?(i)
            }
            addSubview(r)
            return r
        }
        brand.stringValue = "bterm \(AppInfo.version)"
        brand.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        brand.textColor = theme.mutedColor
        needsLayout = true
        select(selected, animated: false)
    }

    private func rowFrame(_ i: Int) -> NSRect {
        NSRect(x: 10, y: SettingsSidebar.top + CGFloat(i) * (SettingsSidebar.rowH + 2),
               width: bounds.width - 20, height: SettingsSidebar.rowH)
    }

    override func layout() {
        super.layout()
        for (i, r) in rows.enumerated() { r.frame = rowFrame(i) }
        brand.sizeToFit()
        brand.frame.origin = NSPoint(x: 20, y: bounds.height - 34)
        highlight.frame = rowFrame(selected)
    }

    func select(_ i: Int, animated: Bool) {
        selected = i
        for (j, r) in rows.enumerated() { r.active = j == i }
        let f = rowFrame(i)
        if animated { animate(0.3) { highlight.animator().frame = f } } else { highlight.frame = f }
    }
}

final class SidebarRow: FlippedView {
    var onClick: (() -> Void)?
    var active = false { didSet { refresh() } }
    private let icon = NSImageView()
    private let text: NSTextField
    private let theme: Theme
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(symbol: String, title: String, theme: Theme) {
        self.theme = theme
        text = label(title, size: 13, weight: .medium, color: theme.mutedColor)
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        addSubview(icon)
        addSubview(text)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var mouseDownCanMoveWindow: Bool { false }

    private func refresh() {
        let c = active || hovering ? theme.fgColor : theme.mutedColor
        text.textColor = c
        icon.contentTintColor = active ? theme.accentColor : c
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: (bounds.height - 18) / 2, width: 18, height: 18)
        let h = text.intrinsicContentSize.height
        text.frame = NSRect(x: 36, y: (bounds.height - h) / 2, width: bounds.width - 44, height: h)
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
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - page building blocks

/// A page: big title, subtitle, then stacked blocks (section labels, cards, custom views).
final class SettingsPage: FlippedView {
    let theme: Theme
    let contentWidth: CGFloat
    private var y: CGFloat
    static let inset: CGFloat = 40

    init(theme: Theme, title: String, subtitle: String, width: CGFloat) {
        self.theme = theme
        contentWidth = width - SettingsPage.inset * 2
        y = 44
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: SettingsWindowController.size.height))
        wantsLayer = true
        let t = label(title, size: 22, weight: .semibold, color: theme.fgColor)
        let s = label(subtitle, size: 13, color: theme.mutedColor)
        add(t, height: 28, spacing: 0)
        add(s, height: 18, spacing: 4)
        y += 14
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func add(_ v: NSView, height: CGFloat, spacing: CGFloat = 12) {
        y += spacing
        v.frame = NSRect(x: SettingsPage.inset, y: y, width: contentWidth, height: height)
        v.autoresizingMask = [.width]
        addSubview(v)
        y += height
    }

    func section(_ title: String) {
        let l = label(title.uppercased(), size: 11, weight: .semibold, color: theme.mutedColor)
        add(l, height: 14, spacing: 18)
    }
}

/// Vercel-style bordered card holding rows of title + description + control.
final class SettingsCard: FlippedView {
    private let theme: Theme
    private var rows: [(view: NSView, height: CGFloat)] = []
    private var lines: [NSView] = []

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = theme.borderColor.cgColor
        layer?.backgroundColor = theme.panelColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var height: CGFloat { rows.reduce(0) { $0 + $1.height } }

    func addRow(title: String, detail: String?, control: NSView, height: CGFloat = 64) {
        if !rows.isEmpty {
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = theme.borderColor.cgColor
            addSubview(line)
            lines.append(line)
        }
        let row = SettingsRow(theme: theme, title: title, detail: detail, control: control)
        addSubview(row)
        rows.append((row, height))
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for (i, r) in rows.enumerated() {
            r.view.frame = NSRect(x: 0, y: y, width: bounds.width, height: r.height)
            if i > 0 { lines[i - 1].frame = NSRect(x: 16, y: y, width: bounds.width - 32, height: 1) }
            y += r.height
        }
    }
}

final class SettingsRow: FlippedView {
    private let title: NSTextField
    private let detail: NSTextField?
    private let control: NSView

    init(theme: Theme, title: String, detail: String?, control: NSView) {
        self.title = label(title, size: 13, weight: .medium, color: theme.fgColor)
        self.detail = detail.map { label($0, size: 12, color: theme.mutedColor) }
        self.control = control
        super.init(frame: .zero)
        addSubview(self.title)
        if let d = self.detail { addSubview(d) }
        addSubview(control)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        var cs = control.fittingSize
        if cs.width < 1 { cs = control.frame.size }
        control.frame = NSRect(x: bounds.width - 18 - cs.width, y: (bounds.height - cs.height) / 2,
                               width: cs.width, height: cs.height)
        let textW = control.frame.minX - 18 - 24
        let th = title.intrinsicContentSize.height
        if let d = detail {
            let dh = d.intrinsicContentSize.height
            let top = (bounds.height - th - dh - 3) / 2
            title.frame = NSRect(x: 18, y: top, width: textW, height: th)
            d.frame = NSRect(x: 18, y: top + th + 3, width: textW, height: dh)
        } else {
            title.frame = NSRect(x: 18, y: (bounds.height - th) / 2, width: textW, height: th)
        }
    }
}

/// Slider + live "13 pt" readout.
final class SizeControl: FlippedView {
    private let slider = NSSlider(value: 13, minValue: 9, maxValue: 24, target: nil, action: nil)
    private let value: NSTextField

    init(theme: Theme) {
        value = label("", size: 12, weight: .medium, color: theme.fgColor)
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        value.alignment = .right
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 24))
        slider.numberOfTickMarks = 16
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.controlSize = .small
        slider.onAction { [weak self] c in
            let v = (c as? NSSlider)?.doubleValue.rounded() ?? 13
            if CGFloat(v) != Settings.shared.fontSize { Settings.shared.fontSize = CGFloat(v) }
            self?.refresh()
        }
        addSubview(slider)
        addSubview(value)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var fittingSize: NSSize { NSSize(width: 230, height: 24) }

    func refresh() {
        slider.doubleValue = Double(Settings.shared.fontSize)
        value.stringValue = "\(Int(Settings.shared.fontSize)) pt"
    }

    override func layout() {
        super.layout()
        slider.frame = NSRect(x: 0, y: 2, width: 176, height: 20)
        value.frame = NSRect(x: 180, y: 4, width: 50, height: 16)
    }
}

/// Sample prompt rendered in the chosen font and palette.
final class FontPreview: FlippedView {
    private let theme: Theme

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = theme.borderColor.cgColor
        layer?.backgroundColor = theme.bgColor.cgColor
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let font = Settings.shared.font
        let c = { (i: Int) in NSColor(hex: self.theme.ansi[i]) }
        let fg = theme.fgColor, muted = theme.mutedColor
        let lines: [[(String, NSColor)]] = [
            [("~/dev/bterm", c(4)), (" on ", muted), ("main", c(5)), (" ❯ ", c(2)), ("git status --short", fg)],
            [(" M ", c(3)), ("Sources/bterm/BTermView.swift", fg)],
            [("?? ", c(1)), ("Sources/bterm/SettingsWindow.swift", fg)],
            [("~/dev/bterm", c(4)), (" ❯ ", c(2)), ("echo ", fg), ("\"0O1lI {}[]() => != ≥\"", c(3))],
            [("0O1lI {}[]() => != ≥", fg)],
        ]
        let lineH = ceil(font.ascender - font.descender + font.leading) + 3
        var y: CGFloat = 16
        for line in lines {
            let s = NSMutableAttributedString()
            for (text, color) in line {
                s.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
            }
            s.draw(at: NSPoint(x: 18, y: y))
            y += lineH
            if y > bounds.height - lineH { break }
        }
    }
}

// MARK: - theme picker

final class ThemeGrid: FlippedView {
    private var cards: [ThemeCard] = []
    static let columns = 3
    static let gap: CGFloat = 14
    static let cardH: CGFloat = 122

    init(current: Theme) {
        super.init(frame: .zero)
        cards = Theme.all.map { ThemeCard(theme: $0, chrome: current, selected: $0.id == Settings.shared.themeID) }
        cards.forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func height(for width: CGFloat) -> CGFloat {
        let rows = (Theme.all.count + ThemeGrid.columns - 1) / ThemeGrid.columns
        return CGFloat(rows) * ThemeGrid.cardH + CGFloat(rows - 1) * ThemeGrid.gap
    }

    override func layout() {
        super.layout()
        let cols = CGFloat(ThemeGrid.columns)
        let w = (bounds.width - ThemeGrid.gap * (cols - 1)) / cols
        for (i, c) in cards.enumerated() {
            let col = CGFloat(i % ThemeGrid.columns), row = CGFloat(i / ThemeGrid.columns)
            c.frame = NSRect(x: col * (w + ThemeGrid.gap), y: row * (ThemeGrid.cardH + ThemeGrid.gap),
                             width: w, height: ThemeGrid.cardH)
        }
    }
}

/// Miniature terminal drawn in a theme's own colors; hover previews it live, click applies it.
final class ThemeCard: FlippedView {
    private let theme: Theme
    private let chrome: Theme
    private let selected: Bool
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(theme: Theme, chrome: Theme, selected: Bool) {
        self.theme = theme
        self.chrome = chrome
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let preview = NSRect(x: 3, y: 3, width: bounds.width - 6, height: bounds.height - 34)
        if selected || hovering {
            let ring = NSBezierPath(roundedRect: preview.insetBy(dx: -2.5, dy: -2.5), xRadius: 10, yRadius: 10)
            ring.lineWidth = selected ? 2 : 1
            (selected ? chrome.accentColor : chrome.mutedColor).setStroke()
            ring.stroke()
        }
        let body = NSBezierPath(roundedRect: preview, xRadius: 8, yRadius: 8)
        theme.bgColor.setFill()
        body.fill()

        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        theme.chromeColor.setFill()
        NSRect(x: preview.minX, y: preview.minY, width: preview.width, height: 16).fill()
        for (i, hex) in [0xff5f57, 0xfebc2e, 0x28c840].enumerated() {
            NSColor(hex: UInt32(hex)).setFill()
            NSBezierPath(ovalIn: NSRect(x: preview.minX + 8 + CGFloat(i) * 9, y: preview.minY + 5, width: 6, height: 6)).fill()
        }
        // Underline indicator on the "active tab".
        theme.accentColor.setFill()
        NSRect(x: preview.minX + 40, y: preview.minY + 14, width: 22, height: 2).fill()

        func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ color: NSColor) {
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: preview.minX + x, y: preview.minY + y, width: w, height: 5),
                         xRadius: 2.5, yRadius: 2.5).fill()
        }
        let a = { (i: Int) in NSColor(hex: self.theme.ansi[i]) }
        bar(10, 26, 26, a(4)); bar(40, 26, 10, a(2)); bar(54, 26, 40, theme.fgColor)
        bar(10, 37, 18, a(3)); bar(32, 37, 54, theme.fgColor.withAlphaComponent(0.7))
        bar(10, 48, 18, a(1)); bar(32, 48, 38, theme.fgColor.withAlphaComponent(0.7))
        bar(10, 59, 26, a(4)); bar(40, 59, 10, a(2))
        NSColor(hex: theme.cursor).setFill()
        NSRect(x: preview.minX + 54, y: preview.minY + 57, width: 2, height: 9).fill()
        NSGraphicsContext.restoreGraphicsState()

        theme.borderColor.withAlphaComponent(0.9).setStroke()
        body.lineWidth = 1
        body.stroke()

        let name = NSAttributedString(string: theme.name, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: selected ? .semibold : .medium),
            .foregroundColor: selected || hovering ? chrome.fgColor : chrome.mutedColor])
        name.draw(at: NSPoint(x: 4, y: bounds.height - 22))
        if selected {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
                .applying(.init(paletteColors: [chrome.bgColor, chrome.accentColor]))
            if let img = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) {
                img.draw(in: NSRect(x: bounds.width - img.size.width - 4, y: bounds.height - 20,
                                    width: img.size.width, height: img.size.height))
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
        lift(-3)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
        lift(0)
    }

    private func lift(_ dy: CGFloat) {
        guard let l = layer else { return }
        let a = CABasicAnimation(keyPath: "transform.translation.y")
        a.fromValue = l.presentation()?.value(forKeyPath: "transform.translation.y") ?? 0
        a.toValue = dy
        a.duration = 0.22
        a.timingFunction = easeOutExpo
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        l.add(a, forKey: "lift")
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)), !selected else { return }
        Settings.shared.previewThemeID = nil
        Settings.shared.themeID = theme.id
    }
}

// MARK: - about

final class AboutView: FlippedView {
    init(theme: Theme) {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.frame = NSRect(x: 0, y: 0, width: 88, height: 88)
        addSubview(icon)
        let name = label("bterm", size: 26, weight: .bold, color: theme.fgColor)
        name.frame = NSRect(x: 104, y: 14, width: 300, height: 32)
        addSubview(name)
        let ver = label("Version \(AppInfo.version)", size: 13, color: theme.mutedColor)
        ver.frame = NSRect(x: 104, y: 50, width: 300, height: 18)
        addSubview(ver)

        let card = SettingsCard(theme: theme)
        let size = Bundle.main.executableURL
            .flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—"
        card.addRow(title: "Native", detail: "AppKit + Core Animation, no web view.",
                    control: label(size, size: 12, weight: .medium, color: theme.mutedColor), height: 54)
        card.addRow(title: "Emulation", detail: "xterm-256color, truecolor, Kitty & Sixel graphics.",
                    control: label("SwiftTerm", size: 12, weight: .medium, color: theme.mutedColor), height: 54)
        card.frame = NSRect(x: 0, y: 116, width: 520, height: card.height)
        card.autoresizingMask = [.width]
        addSubview(card)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        if let card = subviews.last { card.frame.size.width = bounds.width }
    }
}
