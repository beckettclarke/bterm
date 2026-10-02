import AppKit

/// Footer in the style of a deployment dashboard: status dot, process, directory, branch, grid size.
final class StatusBarView: NSView {
    struct Segment {
        var symbol: String?
        var text: String
        var mono = false
    }

    private let dot = CALayer()
    private let topLine = CALayer()
    private var left: [SegmentView] = []
    private var right: [SegmentView] = []
    private var theme = Settings.shared.theme
    private var running = false

    static let height: CGFloat = 26

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(topLine)
        layer?.addSublayer(dot)
        dot.cornerRadius = 3.5
        left = (0..<3).map { _ in SegmentView() }
        right = (0..<2).map { _ in SegmentView() }
        (left + right).forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    func applyTheme(_ t: Theme, glass: Bool) {
        theme = t
        layer?.backgroundColor = t.chromeColor.withAlphaComponent(glass ? 0.7 : 1).cgColor
        topLine.backgroundColor = t.borderColor.cgColor
        (left + right).forEach { $0.theme = t }
        setRunning(running)
    }

    func update(process: String, running: Bool, directory: String?, branch: String?, cols: Int, rows: Int) {
        setRunning(running)
        left[0].set(Segment(symbol: nil, text: process, mono: true))
        left[1].set(directory.map { Segment(symbol: "folder", text: $0) })
        left[2].set(branch.map { Segment(symbol: "arrow.triangle.branch", text: $0) })
        right[0].set(Segment(symbol: nil, text: "\(cols) × \(rows)", mono: true))
        right[1].set(Segment(symbol: nil, text: "UTF-8"))
        needsLayout = true
    }

    private func setRunning(_ r: Bool) {
        let changed = r != running
        running = r
        dot.backgroundColor = (r ? theme.successColor : theme.mutedColor.withAlphaComponent(0.6)).cgColor
        if r && (changed || dot.animation(forKey: "pulse") == nil) {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1; a.toValue = 0.3
            a.duration = 0.9; a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(a, forKey: "pulse")
            // Halo ring that expands once when a command starts.
            if changed { ping() }
        } else if !r {
            dot.removeAnimation(forKey: "pulse")
        }
    }

    private func ping() {
        let ring = CALayer()
        ring.frame = dot.frame
        ring.cornerRadius = dot.cornerRadius
        ring.borderWidth = 1
        ring.borderColor = theme.successColor.cgColor
        layer?.addSublayer(ring)
        let s = CABasicAnimation(keyPath: "transform.scale")
        s.fromValue = 1; s.toValue = 3
        let o = CABasicAnimation(keyPath: "opacity")
        o.fromValue = 0.9; o.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [s, o]
        g.duration = 0.7
        g.timingFunction = easeOutExpo
        g.isRemovedOnCompletion = false
        g.fillMode = .forwards
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(g, forKey: nil)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        topLine.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        dot.frame = NSRect(x: 14, y: (bounds.height - 7) / 2 + 0.5, width: 7, height: 7)
        CATransaction.commit()
        var x: CGFloat = 26
        for s in left where !s.isHidden {
            let w = s.fittingWidth
            s.frame = NSRect(x: x, y: 1, width: w, height: bounds.height - 1)
            x += w + 14
        }
        var rx = bounds.width - 14
        for s in right where !s.isHidden {
            let w = s.fittingWidth
            rx -= w
            s.frame = NSRect(x: rx, y: 1, width: w, height: bounds.height - 1)
            rx -= 14
        }
    }
}

/// Icon + label pair whose text cross-fades when it changes.
final class SegmentView: NSView {
    var theme = Settings.shared.theme { didSet { render() } }
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var segment: StatusBarView.Segment?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.lineBreakMode = .byTruncatingHead
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

    func set(_ s: StatusBarView.Segment?) {
        isHidden = s == nil
        guard let s else { return }
        let changed = segment?.text != s.text && segment != nil
        segment = s
        if changed, let l = label.layer {
            let t = CATransition()
            t.type = .fade
            t.duration = 0.25
            l.add(t, forKey: "text")
        }
        render()
    }

    private func render() {
        guard let s = segment else { return }
        label.font = s.mono ? NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
                            : NSFont.systemFont(ofSize: 11.5, weight: .regular)
        label.textColor = s.mono ? theme.fgColor.withAlphaComponent(0.85) : theme.mutedColor
        label.stringValue = s.text
        label.wantsLayer = true
        if let sym = s.symbol {
            icon.isHidden = false
            icon.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
            icon.contentTintColor = theme.mutedColor
        } else {
            icon.isHidden = true
        }
        needsLayout = true
    }

    var fittingWidth: CGFloat {
        let iconW: CGFloat = icon.isHidden ? 0 : 17
        return min(iconW + ceil(label.intrinsicContentSize.width) + 4, 420)
    }

    override func layout() {
        super.layout()
        let iconW: CGFloat = icon.isHidden ? 0 : 17
        icon.frame = NSRect(x: 0, y: (bounds.height - 14) / 2, width: 13, height: 14)
        let h = label.intrinsicContentSize.height
        label.frame = NSRect(x: iconW, y: (bounds.height - h) / 2, width: bounds.width - iconW, height: h)
    }
}
