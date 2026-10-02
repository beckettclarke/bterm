import AppKit
import SwiftTerm

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: alpha)
    }
}

/// A complete visual identity: chrome colors plus the 16-color ANSI palette.
struct Theme {
    let id: String
    let name: String
    let isDark: Bool
    let bg: UInt32          // terminal surface
    let chrome: UInt32      // tab bar / status bar
    let panel: UInt32       // floating surfaces (palette, toasts)
    let border: UInt32
    let fg: UInt32
    let muted: UInt32
    let hover: UInt32
    let accent: UInt32      // tab indicator, focus, highlights
    let cursor: UInt32
    let selection: UInt32
    let success: UInt32
    let ansi: [UInt32]

    var bgColor: NSColor { NSColor(hex: bg) }
    var chromeColor: NSColor { NSColor(hex: chrome) }
    var panelColor: NSColor { NSColor(hex: panel) }
    var borderColor: NSColor { NSColor(hex: border) }
    var fgColor: NSColor { NSColor(hex: fg) }
    var mutedColor: NSColor { NSColor(hex: muted) }
    var hoverColor: NSColor { NSColor(hex: hover) }
    var accentColor: NSColor { NSColor(hex: accent) }
    var successColor: NSColor { NSColor(hex: success) }
    var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }

    var terminalColors: [SwiftTerm.Color] {
        ansi.map {
            SwiftTerm.Color(red: UInt16(($0 >> 16) & 0xff) * 257,
                            green: UInt16(($0 >> 8) & 0xff) * 257,
                            blue: UInt16($0 & 0xff) * 257)
        }
    }

    static let all: [Theme] = [vercel, github, supabase, vercelLight, githubLight]

    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? vercel }

    static let vercel = Theme(
        id: "vercel", name: "Vercel", isDark: true,
        bg: 0x0a0a0a, chrome: 0x000000, panel: 0x111111, border: 0x242424,
        fg: 0xededed, muted: 0x8f8f8f, hover: 0x1a1a1a, accent: 0xededed,
        cursor: 0xededed, selection: 0x1b3b63, success: 0x4ade80,
        ansi: [0x2e2e2e, 0xff6166, 0x62c073, 0xf5b94a, 0x52a8ff, 0xbf7af0, 0x3fc3cf, 0xa1a1a1,
               0x5c5c5c, 0xff8a8e, 0x86d993, 0xffd17a, 0x7cbcff, 0xd4a4ff, 0x76dce6, 0xededed])

    static let github = Theme(
        id: "github", name: "GitHub Dark", isDark: true,
        bg: 0x0d1117, chrome: 0x010409, panel: 0x161b22, border: 0x30363d,
        fg: 0xe6edf3, muted: 0x7d8590, hover: 0x161b22, accent: 0xf78166,
        cursor: 0x2f81f7, selection: 0x1f3a5f, success: 0x3fb950,
        ansi: [0x484f58, 0xff7b72, 0x3fb950, 0xd29922, 0x58a6ff, 0xbc8cff, 0x39c5cf, 0xb1bac4,
               0x6e7681, 0xffa198, 0x56d364, 0xe3b341, 0x79c0ff, 0xd2a8ff, 0x56d4dd, 0xffffff])

    static let supabase = Theme(
        id: "supabase", name: "Supabase", isDark: true,
        bg: 0x171717, chrome: 0x121212, panel: 0x1f1f1f, border: 0x2e2e2e,
        fg: 0xededed, muted: 0x8f8f8f, hover: 0x232323, accent: 0x3ecf8e,
        cursor: 0x3ecf8e, selection: 0x1d4d38, success: 0x3ecf8e,
        ansi: [0x2e2e2e, 0xf06a6a, 0x3ecf8e, 0xf1c35b, 0x6aa8f5, 0xb48cf2, 0x4cc9c0, 0xa0a0a0,
               0x575757, 0xff8f8f, 0x6ee7b0, 0xffd889, 0x93c2ff, 0xcfb0ff, 0x7ee2da, 0xf5f5f5])

    static let vercelLight = Theme(
        id: "vercel-light", name: "Vercel Light", isDark: false,
        bg: 0xffffff, chrome: 0xfafafa, panel: 0xffffff, border: 0xebebeb,
        fg: 0x171717, muted: 0x6b6b6b, hover: 0xf0f0f0, accent: 0x171717,
        cursor: 0x171717, selection: 0xcde3ff, success: 0x16a34a,
        ansi: [0x171717, 0xd8333a, 0x297a3a, 0xa35200, 0x0068d6, 0x7c3aed, 0x0e7c86, 0x8f8f8f,
               0x5c5c5c, 0xe5484d, 0x46a758, 0xc26a00, 0x2e86f0, 0x9b5cf5, 0x199ba6, 0xa8a8a8])

    static let githubLight = Theme(
        id: "github-light", name: "GitHub Light", isDark: false,
        bg: 0xffffff, chrome: 0xf6f8fa, panel: 0xffffff, border: 0xd0d7de,
        fg: 0x1f2328, muted: 0x656d76, hover: 0xeaeef2, accent: 0xfd8c73,
        cursor: 0x0969da, selection: 0xb6e3ff, success: 0x1a7f37,
        ansi: [0x24292f, 0xcf222e, 0x116329, 0x4d2d00, 0x0969da, 0x8250df, 0x1b7c83, 0x6e7781,
               0x57606a, 0xa40e26, 0x1a7f37, 0x633c01, 0x218bff, 0xa475f9, 0x3192aa, 0x8c959f])
}
