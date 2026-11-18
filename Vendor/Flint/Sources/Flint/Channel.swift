import Foundation

/// A release track such as beta or nightly.
///
/// Channels are ordered from most to least stable, and someone following a
/// channel is offered the newest release on it *or any more stable channel*.
/// Beta testers therefore move onto the final release when it ships.
///
/// A release's channel comes from its version's pre-release label
/// (`1.4.0-beta.2` → `beta`, `1.4.0-nightly.20261118` → `nightly`), or from an
/// explicit `channel` in a JSON feed. Versions without a label are stable.
/// Releases whose label matches no channel (by name or alias) are never offered.
public struct Channel: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    /// The label releases use, lowercased: `beta` matches `1.4.0-beta.2`.
    public let name: String
    /// Other labels that belong here, such as `rc` or `preview` for beta.
    public let aliases: [String]
    /// What users see in a channel picker.
    public let title: String

    public static let stable = Channel("stable", title: "Stable")
    public static let beta = Channel("beta", aliases: ["alpha", "rc", "pre", "preview"])
    public static let nightly = Channel("nightly", aliases: ["dev", "canary", "snapshot"])

    /// Used when neither code nor Info.plist (`FlintChannels`) lists channels.
    public static let defaults: [Channel] = [.stable, .beta]

    public init(_ name: String, aliases: [String] = [], title: String? = nil) {
        self.name = name.lowercased()
        self.aliases = aliases.map { $0.lowercased() }
        self.title = title ?? name.prefix(1).uppercased() + name.dropFirst()
    }

    /// `"beta"` and `"nightly"` get the built-in aliases; other names get none.
    public init(stringLiteral name: String) { self = Channel.named(name) }

    static func named(_ name: String) -> Channel {
        [Channel.stable, .beta, .nightly].first { $0.name == name.lowercased() } ?? Channel(name)
    }

    public var description: String { name }

    public static func == (a: Channel, b: Channel) -> Bool { a.name == b.name }
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }

    func matches(_ label: String) -> Bool { label == name || aliases.contains(label) }

    /// Stable first, then the given channels in order, without duplicates.
    static func normalized(_ channels: [Channel]) -> [Channel] {
        var result: [Channel] = [.stable]
        for channel in channels where !result.contains(channel) { result.append(channel) }
        return result
    }

    /// Reads `FlintChannels`: an array of names, or of dictionaries with
    /// `name`, optional `aliases` and optional `title`.
    static func list(fromInfoPlist value: Any?) -> [Channel]? {
        guard let items = value as? [Any] else { return nil }
        return items.compactMap { item in
            if let name = item as? String { return Channel.named(name) }
            guard let dict = item as? [String: Any], let name = dict["name"] as? String else { return nil }
            return Channel(name, aliases: dict["aliases"] as? [String] ?? [], title: dict["title"] as? String)
        }
    }

    /// Where a release with this label sits in `channels`: nil means stable, ""
    /// (a pre-release with no label) the first channel after stable. Labels no
    /// channel claims give nil, so those releases are ignored.
    static func index(ofLabel label: String?, in channels: [Channel]) -> Int? {
        guard let label else { return 0 }
        if label.isEmpty { return channels.count > 1 ? 1 : nil }
        return channels.firstIndex { $0.matches(label) }
    }

    /// The newest release newer than `current` on `channel` or a more stable one.
    static func newest(_ releases: [Release], newerThan current: Version, on channel: Channel, in channels: [Channel]) -> Release? {
        let limit = channels.firstIndex(of: channel) ?? 0
        return releases
            .filter { release in index(ofLabel: release.channelLabel, in: channels).map { $0 <= limit } ?? false }
            .filter { $0.version > current }
            .max { $0.version < $1.version }
    }
}

extension Version {
    /// `beta` for `1.4.0-beta.2` or `1.4.0-beta2`; nil for a final release.
    var channelLabel: String? {
        guard let first = prerelease.first else { return nil }
        return first.prefix(while: \.isLetter).lowercased()
    }
}

extension Release {
    /// The explicit channel, else the version's label. A release flagged as a
    /// pre-release without a label gets "", which lands on the first channel after stable.
    var channelLabel: String? {
        if let channel { return channel.lowercased() }
        return version.channelLabel ?? (isPrerelease ? "" : nil)
    }
}
