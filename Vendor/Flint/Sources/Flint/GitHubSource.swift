import Foundation

/// Finds updates in a public GitHub repository's Releases.
///
/// Drafts are ignored, the release tag is the version (`v1.2.3` works), and the
/// first macOS-looking `.zip`, `.dmg` or `.tar.gz` asset is downloaded. GitHub's
/// asset digests (or a `.sha256` / `SHA256SUMS` asset) are verified when present.
/// Tag pre-releases with their channel, like `v1.4.0-beta.2`; see `Channel`.
public struct GitHubSource: UpdateSource {
    /// `owner/name`
    public var repository: String
    /// Optional glob for picking the asset, e.g. `MyApp-*.zip`.
    public var assetPattern: String?
    public var apiURL = URL(string: "https://api.github.com")!

    public init(_ repository: String, assetPattern: String? = nil) {
        self.repository = repository
        self.assetPattern = assetPattern
    }

    public func releases() async throws -> [Release] {
        let url = apiURL.appendingPathComponent("repos/\(repository)/releases")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "per_page", value: "100")]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github.full+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if [403, 429].contains(http.statusCode), http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
                let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init)
                throw FlintError.rateLimited(resetsAt: reset.map(Date.init(timeIntervalSince1970:)))
            }
            throw FlintError.http(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GHRelease].self, from: data)
            .filter { !$0.draft }
            .compactMap(release(from:))
    }

    private func release(from gh: GHRelease) -> Release? {
        guard let index = Self.pickAsset(gh.assets.map(\.name), pattern: assetPattern),
              let downloadURL = URL(string: gh.assets[index].browserDownloadUrl) else { return nil }
        let asset = gh.assets[index]

        var sha256: String?
        if let digest = asset.digest, digest.hasPrefix("sha256:") { sha256 = String(digest.dropFirst(7)) }
        let sumNames = ["\(asset.name).sha256", "sha256sums", "sha256sums.txt", "checksums.txt"].map { $0.lowercased() }
        let sums = gh.assets.first { sumNames.contains($0.name.lowercased()) }

        let notes = gh.bodyHtml ?? gh.body.map(Markdown.html)
        return Release(
            version: Version(gh.tagName),
            title: gh.name,
            notesHTML: notes?.isEmpty == false ? notes : nil,
            date: gh.publishedAt,
            downloadURL: downloadURL,
            fileName: asset.name,
            size: asset.size,
            sha256: sha256,
            checksumURL: sums.flatMap { URL(string: $0.browserDownloadUrl) },
            pageURL: URL(string: gh.htmlUrl),
            isPrerelease: gh.prerelease
        )
    }

    /// Index of the asset most likely to be this Mac's app, or nil.
    static func pickAsset(_ names: [String], pattern: String?) -> Int? {
        if let pattern {
            return names.firstIndex { fnmatch(pattern, $0, FNM_CASEFOLD) == 0 }
        }
        return names.indices
            .compactMap { i in score(names[i]).map { (i, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    private static func score(_ name: String) -> Int? {
        let n = name.lowercased()
        let kinds: [(String, Int)] = [(".zip", 3), (".dmg", 2), (".tar.gz", 1), (".tgz", 1)]
        guard let kind = kinds.first(where: { n.hasSuffix($0.0) }) else { return nil }
        let foreign = ["linux", "windows", "win32", "win64", "dsym", "symbols", "source", "src"]
        if foreign.contains(where: n.contains) { return nil }

        let arm = ["arm64", "aarch64", "apple-silicon", "applesilicon"]
        let intel = ["x86_64", "x86-64", "x64", "amd64", "intel"]
        #if arch(arm64)
        let (native, other) = (arm, intel)
        #else
        let (native, other) = (intel, arm)
        #endif

        var score = kind.1
        if ["mac", "darwin", "osx", "universal"].contains(where: n.contains) { score += 4 }
        if native.contains(where: n.contains) { score += 8 }
        if other.contains(where: n.contains) { score -= 20 }
        return score
    }
}

private struct GHRelease: Decodable {
    var tagName: String
    var name: String?
    var body: String?
    var bodyHtml: String?
    var draft: Bool
    var prerelease: Bool
    var publishedAt: Date?
    var htmlUrl: String
    var assets: [GHAsset]
}

private struct GHAsset: Decodable {
    var name: String
    var browserDownloadUrl: String
    var size: Int64?
    var digest: String?
}
