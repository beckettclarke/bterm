import AppKit

/// Floating pill used for transient feedback (font size, copied, theme) and the resize HUD.
final class ToastView: NSView {
    enum Placement { case bottom, center }

    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let placement: Placement
    private var hideWork: DispatchWorkItem?
    private(set) var dismissed = false

    init(placement: Placement) {
        self.placement = placement
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(text: String, symbol: String?, theme: Theme, mono: Bool = false) {
        layer?.backgroundColor = theme.panelColor.cgColor
        layer?.borderColor = theme.borderColor.cgColor
        layer?.shadowOpacity = theme.isDark ? 0.45 : 0.14
        label.font = mono ? .monospacedSystemFont(ofSize: 12.5, weight: .medium) : .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = theme.fgColor
        label.stringValue = text
        icon.isHidden = symbol == nil
        if let symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            icon.contentTintColor = theme.accentColor
        }
        needsLayout = true
        superview?.needsLayout = true
    }

    var idealSize: NSSize {
        let iconW: CGFloat = icon.isHidden ? 0 : 22
        return NSSize(width: ceil(label.intrinsicContentSize.width) + iconW + 28, height: 34)
    }

    func place(in host: NSRect) {
        let s = idealSize
        let y: CGFloat = placement == .center ? host.midY - s.height / 2 : host.minY + 18
        frame = NSRect(x: host.midX - s.width / 2, y: y, width: s.width, height: s.height).integral
    }

    override func layout() {
        super.layout()
        let iconW: CGFloat = icon.isHidden ? 0 : 22
        icon.frame = NSRect(x: 13, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let h = label.intrinsicContentSize.height
        label.frame = NSRect(x: 14 + iconW, y: (bounds.height - h) / 2, width: bounds.width - 28 - iconW, height: h)
    }

    func show(for seconds: TimeInterval, animated: Bool = true) {
        if animated, let l = layer {
            let o = CABasicAnimation(keyPath: "opacity")
            o.fromValue = 0; o.toValue = 1
            let y = CABasicAnimation(keyPath: "transform.translation.y")
            y.fromValue = placement == .bottom ? -10 : 0
            y.toValue = 0
            y.isAdditive = true
            let g = CAAnimationGroup()
            g.animations = [o, y]
            g.duration = 0.3
            g.timingFunction = easeOutExpo
            l.add(g, forKey: "in")
        }
        scheduleHide(after: seconds)
    }

    func scheduleHide(after seconds: TimeInterval) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func hide() {
        guard !dismissed else { return }
        dismissed = true
        hideWork?.cancel()
        let o = CABasicAnimation(keyPath: "opacity")
        o.fromValue = layer?.presentation()?.opacity ?? 1
        o.toValue = 0
        o.duration = 0.22
        o.fillMode = .forwards
        o.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperview() }
        layer?.add(o, forKey: "out")
        CATransaction.commit()
    }
}
