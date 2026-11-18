import AppKit
import CryptoKit
import Security

/// A downloaded, verified and unpacked update waiting to be swapped in.
public struct PreparedUpdate: Sendable {
    public let release: Release
    /// The new `.app`, in a temporary folder on the same volume as the running app.
    public let appURL: URL
    let workDirectory: URL
}

enum HostApp {
    static var url: URL { Bundle.main.bundleURL }
    static var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    static var name: String {
        info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? ProcessInfo.processInfo.processName
    }
    static var versionString: String { info["CFBundleShortVersionString"] as? String ?? "0" }
    static var version: Version { Version(versionString) }
}

enum Installer {
    // MARK: Prepare

    static func prepare(_ release: Release, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> PreparedUpdate {
        try checkUpdatable()
        let fm = FileManager.default
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: HostApp.url, create: true)
        do {
            let archive = work.appendingPathComponent(release.fileName)
            try await Downloader.download(release.downloadURL, to: archive, progress: progress)
            if let expected = try await expectedChecksum(for: release) {
                let actual = try await Task.detached { try sha256(of: archive) }.value
                guard actual == expected.lowercased() else { throw FlintError.checksumMismatch }
            }
            let app = try await Task.detached { try extractApp(from: archive, into: work) }.value
            try validate(app)
            return PreparedUpdate(release: release, appURL: app, workDirectory: work)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    static func checkUpdatable() throws {
        let url = HostApp.url
        let move = "Move \(HostApp.name) to your Applications folder to enable updates."
        guard url.pathExtension == "app" else { throw FlintError.notUpdatable("\(HostApp.name) isn't running from an app bundle.") }
        if url.path.contains("/AppTranslocation/") { throw FlintError.notUpdatable(move) }
        if (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            throw FlintError.notUpdatable(move)
        }
    }

    private static func expectedChecksum(for release: Release) async throws -> String? {
        if let sha = release.sha256 { return sha }
        guard let url = release.checksumURL else { return nil }
        let (data, _) = try await URLSession.shared.data(from: url)
        let text = String(decoding: data, as: UTF8.self)
        let hex = try NSRegularExpression(pattern: "\\b[A-Fa-f0-9]{64}\\b")
        func hashes(_ s: String) -> [String] {
            hex.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
        }
        // `SHA256SUMS` style: pick the line naming our file. Otherwise the file's only hash.
        if let line = text.split(whereSeparator: \.isNewline).first(where: { $0.contains(release.fileName) }) {
            return hashes(String(line)).first
        }
        let all = hashes(text)
        return all.count == 1 ? all[0] : nil
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func extractApp(from archive: URL, into work: URL) throws -> URL {
        let fm = FileManager.default
        let out = work.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)

        let name = archive.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") {
            try run("/usr/bin/ditto", ["-x", "-k", archive.path, out.path])
        } else if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
            try run("/usr/bin/tar", ["-xzf", archive.path, "-C", out.path])
        } else if name.hasSuffix(".dmg") {
            // "Y" answers the licence prompt some DMGs show, which can precede the plist.
            let output = try run("/usr/bin/hdiutil", ["attach", archive.path, "-plist", "-nobrowse", "-noautoopen", "-readonly"], input: "Y\n")
            let plist = output.range(of: "<?xml").map { String(output[$0.lowerBound...]) } ?? output
            let entities = (try? PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any])?["system-entities"] as? [[String: Any]]
            guard let mountPath = entities?.lazy.compactMap({ $0["mount-point"] as? String }).first else {
                throw FlintError.installFailed("Couldn't mount the disk image.")
            }
            let mount = URL(fileURLWithPath: mountPath, isDirectory: true)
            defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            guard let app = findApp(in: mount) else { throw FlintError.noAppInArchive }
            try run("/usr/bin/ditto", [app.path, out.appendingPathComponent(app.lastPathComponent).path])
        } else {
            throw FlintError.unsupportedArchive(archive.lastPathComponent)
        }
        guard let app = findApp(in: out) else { throw FlintError.noAppInArchive }
        return app
    }

    /// The shallowest `.app` in `folder`, preferring one named like the running app.
    static func findApp(in folder: URL) -> URL? {
        let fm = FileManager.default
        var level = [folder]
        for _ in 0..<3 {
            var apps: [URL] = [], next: [URL] = []
            for dir in level {
                let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
                for item in items where item.lastPathComponent != "__MACOSX" {
                    let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                    if item.pathExtension == "app" { apps.append(item) } else { next.append(item) }
                }
            }
            if !apps.isEmpty {
                return apps.first { $0.lastPathComponent == HostApp.url.lastPathComponent } ?? apps[0]
            }
            level = next
        }
        return nil
    }

    /// Same bundle identifier, and if this app is Developer ID signed, the same team.
    static func validate(_ app: URL) throws {
        guard let bundle = Bundle(url: app), bundle.executableURL != nil else { throw FlintError.noAppInArchive }
        if let mine = Bundle.main.bundleIdentifier, bundle.bundleIdentifier != mine {
            throw FlintError.bundleMismatch(expected: mine, found: bundle.bundleIdentifier ?? app.lastPathComponent)
        }
        if let team = teamIdentifier(of: HostApp.url) {
            guard hasValidSignature(app), teamIdentifier(of: app) == team else { throw FlintError.signatureMismatch }
        }
    }

    private static func staticCode(_ url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        return SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess ? code : nil
    }

    static func teamIdentifier(of url: URL) -> String? {
        guard let code = staticCode(url) else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func hasValidSignature(_ url: URL) -> Bool {
        guard let code = staticCode(url) else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckNestedCode), nil) == errSecSuccess
    }

    // MARK: Install

    /// Swaps the new app into place. The running process keeps going on the old,
    /// already-loaded code until it quits.
    static func install(_ update: PreparedUpdate) throws {
        let fm = FileManager.default
        let target = HostApp.url
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", update.appURL.path])

        if fm.isWritableFile(atPath: target.deletingLastPathComponent().path), fm.isWritableFile(atPath: target.path) {
            let backup = update.workDirectory.appendingPathComponent("previous-\(target.lastPathComponent)")
            try fm.moveItem(at: target, to: backup)
            do {
                try fm.moveItem(at: update.appURL, to: target)
            } catch {
                try? fm.moveItem(at: backup, to: target)
                throw FlintError.installFailed(error.localizedDescription)
            }
        } else {
            try installWithPrivileges(update.appURL, to: target)
        }
        try? fm.removeItem(at: update.workDirectory)
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
        LSRegisterURL(target as CFURL, true)
    }

    /// For apps the user can't write to (e.g. installed by another admin): ask for
    /// a password once, swap with a rollback, and keep the original ownership.
    private static func installWithPrivileges(_ source: URL, to target: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
        let owner = (attributes?[.ownerAccountID] as? NSNumber)?.intValue ?? Int(getuid())
        let group = (attributes?[.groupOwnerAccountID] as? NSNumber)?.intValue ?? 80
        let (src, dst, old) = (quote(source.path), quote(target.path), quote(target.path + ".flint-old"))
        let script = """
        /bin/rm -rf \(old) && /bin/mv \(dst) \(old) && \
        if /usr/bin/ditto \(src) \(dst); then /usr/sbin/chown -R \(owner):\(group) \(dst); /bin/rm -rf \(old); \
        else /bin/rm -rf \(dst); /bin/mv \(old) \(dst); exit 1; fi
        """
        func escaped(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let prompt = "\(HostApp.name) wants to install an update."
        let source = "do shell script \"\(escaped(script))\" with prompt \"\(escaped(prompt))\" with administrator privileges"
        var error: NSDictionary?
        if NSAppleScript(source: source)?.executeAndReturnError(&error) == nil {
            if error?[NSAppleScript.errorNumber] as? Int == -128 { throw FlintError.cancelled }
            throw FlintError.installFailed(error?[NSAppleScript.errorMessage] as? String ?? "Permission denied.")
        }
    }

    /// Opens the app again once this process has exited.
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$0\"", HostApp.url.path]
        try? process.run()
    }

    // MARK: Helpers

    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String], input: String? = nil) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw FlintError.installFailed("\((tool as NSString).lastPathComponent): \(text.isEmpty ? "exit \(process.terminationStatus)" : text)")
        }
        return text
    }
}

/// URLSession download with progress and cancellation.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    // Only touched on the session's serial delegate queue.
    private var failure: Error?
    private var lastReport = Date.distantPast

    private init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await Downloader(destination: destination, progress: progress).run(url)
    }

    private func run(_ url: URL) async throws {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock { self.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.05 else { return }
        lastReport = now
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = FlintError.http(http.statusCode)
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            progress(size, size)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        if let error = error ?? failure {
            continuation?.resume(throwing: (error as? URLError)?.code == .cancelled ? FlintError.cancelled : error)
        } else {
            continuation?.resume()
        }
    }
}
