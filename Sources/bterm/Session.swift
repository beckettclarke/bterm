import AppKit
import SwiftTerm

/// Windows, tabs, splits and scrollback saved at quit and reopened at launch.
struct SavedSession: Codable {
    var savedAt = Date()
    var windows: [SavedWindow]

    /// A dim line under restored scrollback, so old output reads as old.
    var marker: String {
        let when = DateFormatter.localizedString(from: savedAt, dateStyle: .medium, timeStyle: .short)
        return "\u{1b}[2mRestored session · \(when)\u{1b}[0m\r\n\r\n"
    }
}

struct SavedWindow: Codable {
    var frame: String
    var selected: Int
    var tabs: [SavedTab]
}

struct SavedTab: Codable {
    var title: String?
    var focused: Int
    var root: SavedNode
}

indirect enum SavedNode: Codable {
    case pane(cwd: String?, scrollback: String?)
    case split(vertical: Bool, fractions: [Double], children: [SavedNode])
}

enum Session {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bterm", isDirectory: true)
        return dir.appendingPathComponent("session.json")
    }

    static func save() {
        guard Settings.shared.restoreSession else { return clear() }
        let session = SavedSession(windows: TerminalWindowController.all.compactMap { $0.saved() })
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The last session, removed from disk so a crash while restoring doesn't loop.
    static func take() -> SavedSession? {
        defer { clear() }
        guard Settings.shared.restoreSession, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedSession.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

extension BTermView {
    /// The scrollback and screen up to the prompt, with colors and styles as SGR sequences,
    /// ready to `feed` into a fresh terminal. Nil while a full-screen app has the alternate screen.
    func savedScrollback() -> String? {
        let t = terminal!
        guard !t.isCurrentBufferAlternate else { return nil }
        var count = 0
        while t.bufferLine(atRow: count) != nil { count += 1 }
        // Everything above the cursor; the prompt line itself is redrawn by the new shell.
        let end = min(count, count - t.rows + t.getCursorLocation().y)
        var out = ""
        var attr = Attribute.empty
        var lastText = out.endIndex
        for row in 0..<max(0, end) {
            guard let line = t.bufferLine(atRow: row) else { break }
            let len = line.getTrimmedLength()
            // Skip blank lines before the first output.
            if out.isEmpty && len == 0 { continue }
            if !out.isEmpty, !line.isWrapped { out += "\u{1b}[0m\r\n"; attr = .empty }
            var col = 0
            while col < len {
                let cell = line[col]
                if cell.attribute != attr {
                    out += sgr(cell.attribute)
                    attr = cell.attribute
                }
                let ch = t.getCharacter(for: cell)
                out.append(ch == "\0" ? " " : ch)
                col += max(1, Int(cell.width))
            }
            if len > 0 { lastText = out.endIndex }
        }
        // Drop blank lines between the last output and the prompt.
        let trimmed = out[..<lastText]
        return trimmed.isEmpty ? nil : trimmed + "\u{1b}[0m\r\n"
    }

    private func sgr(_ a: Attribute) -> String {
        var codes = ["0"]
        let s = a.style
        if s.contains(.bold) { codes.append("1") }
        if s.contains(.dim) { codes.append("2") }
        if s.contains(.italic) { codes.append("3") }
        if s.contains(.underline) || a.underlineStyle != .none { codes.append("4") }
        if s.contains(.blink) { codes.append("5") }
        if s.contains(.inverse) { codes.append("7") }
        if s.contains(.invisible) { codes.append("8") }
        if s.contains(.crossedOut) { codes.append("9") }
        if let fg = color(a.fg, base: 30) { codes.append(fg) }
        if let bg = color(a.bg, base: 40) { codes.append(bg) }
        return "\u{1b}[" + codes.joined(separator: ";") + "m"
    }

    private func color(_ c: Attribute.Color, base: Int) -> String? {
        switch c {
        case .ansi256(let code) where code < 8: return "\(base + Int(code))"
        case .ansi256(let code) where code < 16: return "\(base + 60 + Int(code) - 8)"
        case .ansi256(let code): return "\(base + 8);5;\(code)"
        case .trueColor(let r, let g, let b): return "\(base + 8);2;\(r);\(g);\(b)"
        case .defaultColor, .defaultInvertedColor: return nil
        }
    }
}
