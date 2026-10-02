import AppKit
import SwiftTerm

extension Notification.Name {
    static let btermSettingsChanged = Notification.Name("btermSettingsChanged")
}

enum CursorShape: String, CaseIterable {
    case bar, block, underline

    var style: CursorStyle {
        switch self {
        case .bar: return .blinkBar
        case .block: return .blinkBlock
        case .underline: return .blinkUnderline
        }
    }
}

/// User preferences, persisted in UserDefaults. Every change posts `.btermSettingsChanged`.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    /// Set while the palette previews a theme so the preview is not persisted.
    var previewThemeID: String? { didSet { notify() } }

    var themeID: String {
        get { d.string(forKey: "theme") ?? "vercel" }
        set { d.set(newValue, forKey: "theme"); notify() }
    }
    var theme: Theme { Theme.named(previewThemeID ?? themeID) }

    var fontSize: CGFloat {
        get { let v = d.double(forKey: "fontSize"); return v > 0 ? v : 13 }
        set { d.set(min(max(newValue, 8), 36), forKey: "fontSize"); notify() }
    }
    var fontName: String {
        get { d.string(forKey: "fontName") ?? "" }
        set { d.set(newValue, forKey: "fontName"); notify() }
    }
    var cursor: CursorShape {
        get { CursorShape(rawValue: d.string(forKey: "cursor") ?? "") ?? .bar }
        set { d.set(newValue.rawValue, forKey: "cursor"); notify() }
    }
    var glass: Bool { get { bool("glass", false) } set { set("glass", newValue) } }
    var smoothScroll: Bool { get { bool("smoothScroll", true) } set { set("smoothScroll", newValue) } }
    var cursorGlide: Bool { get { bool("cursorGlide", true) } set { set("cursorGlide", newValue) } }
    var optionAsMeta: Bool { get { bool("optionAsMeta", true) } set { set("optionAsMeta", newValue) } }
    var gpu: Bool { get { bool("gpu", false) } set { set("gpu", newValue) } }

    /// Monospaced families offered in the palette; only installed ones are listed.
    static let fontCandidates = ["SF Mono", "Geist Mono", "JetBrains Mono", "Berkeley Mono",
                                 "Fira Code", "Cascadia Code", "IBM Plex Mono", "Menlo", "Monaco"]

    static var installedFonts: [String] {
        let families = Set(NSFontManager.shared.availableFontFamilies)
        return fontCandidates.filter { $0 == "SF Mono" || families.contains($0) }
    }

    var font: NSFont {
        let name = fontName
        if !name.isEmpty, name != "SF Mono",
           let f = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: fontSize) {
            return f
        }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    var displayFontName: String { fontName.isEmpty ? "SF Mono" : fontName }

    func resetAll() {
        for k in ["theme", "fontSize", "fontName", "cursor", "glass", "smoothScroll", "cursorGlide", "optionAsMeta", "gpu"] {
            d.removeObject(forKey: k)
        }
        notify()
    }

    private func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
    private func set(_ k: String, _ v: Bool) { d.set(v, forKey: k); notify() }
    private func notify() { NotificationCenter.default.post(name: .btermSettingsChanged, object: nil) }
}
