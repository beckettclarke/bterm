import Foundation

/// A forgiving semantic version. Understands `1.2.3`, `v1.4`, `2.0.0-beta.2`,
/// `1.0b3` and prefixed tags like `myapp-v3.1`. Anything before the first digit
/// and any `+build` metadata is ignored.
public struct Version: Comparable, Hashable, Sendable, CustomStringConvertible {
    /// The cleaned-up version string, e.g. `1.2.3-beta.2` for the tag `v1.2.3-beta.2`.
    public let description: String
    let components: [Int]
    let prerelease: [String]

    public init(_ raw: String) {
        var s = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if let i = s.firstIndex(where: \.isNumber) { s = s[i...] }
        s = s.prefix { !$0.isWhitespace && $0 != "+" }

        let core = s.prefix { $0.isNumber || $0 == "." }
        let rest = s[core.endIndex...].drop { $0 == "-" || $0 == "." }
        let trimmedCore = core.hasSuffix(".") ? core.dropLast() : core

        components = trimmedCore.split(separator: ".").compactMap { Int($0) }
        prerelease = rest.split(separator: ".").map(String.init)
        description = rest.isEmpty ? String(trimmedCore) : "\(trimmedCore)-\(rest)"
    }

    /// True for versions with a pre-release suffix such as `-beta.1`.
    public var isPrerelease: Bool { !prerelease.isEmpty }

    public static func < (a: Version, b: Version) -> Bool { compare(a, b) < 0 }
    public static func == (a: Version, b: Version) -> Bool { compare(a, b) == 0 }

    public func hash(into hasher: inout Hasher) {
        var numbers = components
        while numbers.last == 0 { numbers.removeLast() }
        hasher.combine(numbers)
        hasher.combine(prerelease.map { $0.lowercased() })
    }

    static func compare(_ a: Version, _ b: Version) -> Int {
        for i in 0..<max(a.components.count, b.components.count) {
            let x = i < a.components.count ? a.components[i] : 0
            let y = i < b.components.count ? b.components[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true): return 0
        case (true, false): return 1
        case (false, true): return -1
        case (false, false): break
        }
        for (x, y) in zip(a.prerelease, b.prerelease) {
            switch (Int(x), Int(y)) {
            case let (i?, j?) where i != j: return i < j ? -1 : 1
            case (_?, nil): return -1
            case (nil, _?): return 1
            case (nil, nil):
                let (lx, ly) = (x.lowercased(), y.lowercased())
                if lx != ly { return lx < ly ? -1 : 1 }
            default: continue
            }
        }
        if a.prerelease.count == b.prerelease.count { return 0 }
        return a.prerelease.count < b.prerelease.count ? -1 : 1
    }
}
