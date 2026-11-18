import Foundation

/// Finds updates in a small JSON file you host anywhere (S3, Pages, a gist…).
///
/// The file is a single object or an array of them:
///
/// ```json
/// {
///   "version": "1.3.0",
///   "url": "https://example.com/MyApp-1.3.0.zip",
///   "notes": "## What's new\n- Faster everything",
///   "date": "2026-11-12",
///   "sha256": "9f86d08…",
///   "minimumSystemVersion": "13.0"
/// }
/// ```
///
/// Only `version` and `url` are required. `notes` may be Markdown or HTML.
/// `channel` (e.g. `"beta"`) overrides the channel implied by the version.
public struct FeedSource: UpdateSource {
    public var url: URL

    public init(_ url: URL) { self.url = url }

    public func releases() async throws -> [Release] {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FlintError.http(http.statusCode)
        }

        let decoder = JSONDecoder()
        let entries = try (try? decoder.decode([Entry].self, from: data))
            ?? [decoder.decode(Entry.self, from: data)]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = Version("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")

        return entries
            .filter { $0.minimumSystemVersion.map { Version($0) <= osVersion } ?? true }
            .map(\.release)
    }

    private struct Entry: Decodable {
        var version: String
        var url: URL
        var title: String?
        var notes: String?
        var date: String?
        var sha256: String?
        var size: Int64?
        var page: URL?
        var prerelease: Bool?
        var channel: String?
        var minimumSystemVersion: String?

        var release: Release {
            let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Release(
                version: Version(version),
                title: title,
                notesHTML: trimmed.isEmpty ? nil : trimmed.hasPrefix("<") ? trimmed : Markdown.html(trimmed),
                date: date.flatMap(Self.parseDate),
                downloadURL: url,
                size: size,
                sha256: sha256,
                pageURL: page,
                isPrerelease: prerelease,
                channel: channel
            )
        }

        static func parseDate(_ s: String) -> Date? {
            if let date = ISO8601DateFormatter().date(from: s) { return date }
            let day = ISO8601DateFormatter()
            day.formatOptions = [.withFullDate]
            day.timeZone = .current
            return day.date(from: s)
        }
    }
}
