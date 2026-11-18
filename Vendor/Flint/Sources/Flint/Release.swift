import Foundation

/// A downloadable version of the app, as reported by an `UpdateSource`.
public struct Release: Hashable, Sendable {
    public var version: Version
    public var title: String?
    /// Release notes as HTML. Markdown from feeds is converted for you.
    public var notesHTML: String?
    public var date: Date?
    public var downloadURL: URL
    /// File name of the archive (`.zip`, `.dmg`, `.tar.gz` or `.tgz`).
    public var fileName: String
    public var size: Int64?
    /// Expected SHA-256 of the archive, hex encoded. Verified when present.
    public var sha256: String?
    /// A `.sha256` / `SHA256SUMS` file to read the expected hash from.
    public var checksumURL: URL?
    /// A web page for the release, shown as a link in the update window.
    public var pageURL: URL?
    public var isPrerelease: Bool
    /// An explicit channel name. When nil, the version's label decides
    /// (`1.4.0-beta.2` is on `beta`); see `Channel`.
    public var channel: String?

    public init(
        version: Version, title: String? = nil, notesHTML: String? = nil, date: Date? = nil,
        downloadURL: URL, fileName: String? = nil, size: Int64? = nil, sha256: String? = nil,
        checksumURL: URL? = nil, pageURL: URL? = nil, isPrerelease: Bool? = nil, channel: String? = nil
    ) {
        self.version = version
        self.title = title
        self.notesHTML = notesHTML
        self.date = date
        self.downloadURL = downloadURL
        self.fileName = fileName ?? downloadURL.lastPathComponent
        self.size = size
        self.sha256 = sha256
        self.checksumURL = checksumURL
        self.pageURL = pageURL
        self.isPrerelease = isPrerelease ?? version.isPrerelease
        self.channel = channel
    }
}

/// Somewhere Flint can ask for releases.
public protocol UpdateSource: Sendable {
    /// Every release on offer, on every channel. Flint picks the newest one on
    /// the user's channel.
    func releases() async throws -> [Release]
}

public enum FlintError: LocalizedError, Equatable {
    case http(Int)
    case rateLimited(resetsAt: Date?)
    case noReleases
    case unsupportedArchive(String)
    case noAppInArchive
    case checksumMismatch
    case bundleMismatch(expected: String, found: String)
    case signatureMismatch
    case notUpdatable(String)
    case installFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .http(404): return "The update server couldn't find any releases (HTTP 404)."
        case .http(let code): return "The update server responded with HTTP \(code)."
        case .rateLimited(let date):
            guard let date else { return "GitHub's rate limit was reached. Try again later." }
            let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
            return "GitHub's rate limit was reached. Try again after \(time)."
        case .noReleases: return "No compatible release was found."
        case .unsupportedArchive(let name): return "“\(name)” isn't a .zip, .dmg or .tar.gz archive."
        case .noAppInArchive: return "The download doesn't contain an app."
        case .checksumMismatch: return "The download was damaged or tampered with (checksum mismatch)."
        case .bundleMismatch(let expected, let found):
            return "The download contains a different app (\(found)) instead of \(expected)."
        case .signatureMismatch: return "The update isn't signed by the same developer as this app."
        case .notUpdatable(let reason): return reason
        case .installFailed(let reason): return "The update couldn't be installed: \(reason)"
        case .cancelled: return "The update was cancelled."
        }
    }
}
