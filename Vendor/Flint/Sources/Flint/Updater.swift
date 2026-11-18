import AppKit
import SwiftUI

/// Checks for, downloads and installs updates.
///
/// ```swift
/// // Info.plist: FlintGitHubRepository = "you/your-app"
/// Updater.shared.start()                // background checks, once a day
/// Updater.shared.checkForUpdates()      // from a "Check for Updates…" menu item
/// ```
@MainActor
public final class Updater: NSObject, ObservableObject {
    public enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release, received: Int64, total: Int64)
        case ready(Release)
        case installing(Release)
        case failed(title: String, message: String)
    }

    /// Reads `FlintGitHubRepository` (and optional `FlintAssetPattern`) or `FlintFeedURL`
    /// from Info.plist, plus the optional `FlintChannels` and `FlintDefaultChannel`.
    public static let shared = Updater()

    public let source: UpdateSource
    @Published public private(set) var phase: Phase = .idle
    @Published public var automaticallyChecksForUpdates: Bool {
        didSet { defaults.set(automaticallyChecksForUpdates, forKey: Keys.automatic) }
    }
    /// Release channels, most stable first. Always starts with `.stable`.
    public let channels: [Channel]
    /// The channel this user follows; they're offered releases from it and from
    /// every more stable channel. Saved across launches. Until the user picks one,
    /// it's the channel this build belongs to.
    @Published public var channel: Channel {
        didSet {
            guard channel != oldValue else { return }
            defaults.set(channel.name, forKey: Keys.channel)
            // Look for an update on the new channel right away.
            lastCheckDate = nil
            if timer != nil { checkIfDue() }
        }
    }
    /// Minimum time between background checks. Defaults to a day.
    public var checkInterval: TimeInterval = 60 * 60 * 24
    public private(set) var lastCheckDate: Date? {
        get { defaults.object(forKey: Keys.lastCheck) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastCheck) }
    }

    private let defaults = UserDefaults.standard
    private var window: UpdateWindow?
    private var work: Task<Void, Never>?
    private var timer: Timer?
    private var interactive = false
    private var pending: PreparedUpdate?
    private var installOnQuit = false

    private enum Keys {
        static let automatic = "FlintAutomaticallyChecks"
        static let lastCheck = "FlintLastCheckDate"
        static let skipped = "FlintSkippedVersion"
        static let channel = "FlintChannel"
    }

    /// - Parameters:
    ///   - channels: Channels besides stable, most stable first. Defaults to beta.
    ///   - defaultChannel: The channel to follow until the user picks one. Defaults
    ///     to the running build's own channel, e.g. `beta` for `1.4.0-beta.2`.
    public init(source: UpdateSource, channels: [Channel] = Channel.defaults, defaultChannel: String? = nil) {
        self.source = source
        let all = Channel.normalized(channels)
        let label = UserDefaults.standard.string(forKey: Keys.channel) ?? defaultChannel ?? HostApp.version.channelLabel
        self.channels = all
        channel = Channel.index(ofLabel: label, in: all).map { all[$0] } ?? .stable
        automaticallyChecksForUpdates = UserDefaults.standard.object(forKey: Keys.automatic) as? Bool ?? true
        super.init()
    }

    public convenience init(bundle: Bundle = .main) {
        let info = bundle.infoDictionary ?? [:]
        let source: UpdateSource
        if let repo = info["FlintGitHubRepository"] as? String {
            source = GitHubSource(repo, assetPattern: info["FlintAssetPattern"] as? String)
        } else if let feed = (info["FlintFeedURL"] as? String).flatMap(URL.init(string:)) {
            source = FeedSource(feed)
        } else {
            fatalError("Flint: set FlintGitHubRepository (\"owner/repo\") or FlintFeedURL in Info.plist, or use Updater(source:).")
        }
        self.init(source: source,
                  channels: Channel.list(fromInfoPlist: info["FlintChannels"]) ?? Channel.defaults,
                  defaultChannel: info["FlintDefaultChannel"] as? String)
    }

    // MARK: Scheduling

    /// Starts background checks: shortly after launch, then every `checkInterval`.
    /// A downloaded update the user postponed is installed when the app quits.
    public func start() {
        guard timer == nil else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(appWillTerminate),
                                               name: NSApplication.willTerminateNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.checkIfDue()
        }
    }

    private func checkIfDue() {
        guard automaticallyChecksForUpdates, phase == .idle, pending == nil else { return }
        if let last = lastCheckDate, Date().timeIntervalSince(last) < checkInterval { return }
        interactive = false
        beginCheck()
    }

    // MARK: Actions

    /// Checks now and always shows a window with the result. Hook this up to a
    /// "Check for Updates…" menu item.
    @objc public func checkForUpdates(_ sender: Any? = nil) {
        interactive = true
        switch phase {
        case .idle, .upToDate, .failed:
            if let pending {
                phase = .ready(pending.release)
            } else {
                beginCheck()
            }
        default:
            break
        }
        showWindow(activate: true)
    }

    /// A ready-made "Check for Updates…" menu item.
    public func makeMenuItem(title: String = "Check for Updates…") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        item.target = self
        return item
    }

    private func beginCheck() {
        work?.cancel()
        phase = .checking
        work = Task {
            do {
                let release = try await findUpdate()
                lastCheckDate = Date()
                guard !Task.isCancelled else { return }
                if let release, interactive || release.version.description != defaults.string(forKey: Keys.skipped) {
                    phase = .available(release)
                    showWindow(activate: interactive)
                } else if interactive {
                    phase = .upToDate
                } else {
                    phase = .idle
                }
            } catch {
                guard !Task.isCancelled else { return }
                if interactive {
                    phase = .failed(title: "Couldn't Check for Updates", message: error.localizedDescription)
                } else {
                    phase = .idle
                }
            }
        }
    }

    func download(_ release: Release) {
        interactive = true
        phase = .downloading(release, received: 0, total: release.size ?? 0)
        work = Task {
            do {
                let prepared = try await prepare(release) { received, total in
                    Task { @MainActor in
                        guard case .downloading(let r, _, _) = self.phase, r == release else { return }
                        self.phase = .downloading(release, received: received, total: total)
                    }
                }
                guard !Task.isCancelled else { try? FileManager.default.removeItem(at: prepared.workDirectory); return }
                pending = prepared
                phase = .ready(release)
            } catch {
                guard !Task.isCancelled, error as? FlintError != .cancelled else { return }
                phase = .failed(title: "Update Failed", message: error.localizedDescription)
            }
        }
    }

    func cancelDownload() {
        guard case .downloading(let release, _, _) = phase else { return }
        work?.cancel()
        phase = .available(release)
    }

    func skip(_ release: Release) {
        defaults.set(release.version.description, forKey: Keys.skipped)
        closeWindow()
    }

    func restartNow() {
        guard let pending else { return }
        phase = .installing(pending.release)
        Task {
            await Task.yield() // let the "Installing…" state draw before a possible password prompt
            do {
                try install(pending, relaunch: true)
            } catch FlintError.cancelled {
                phase = .ready(pending.release)
            } catch {
                self.pending = nil
                phase = .failed(title: "Update Failed", message: error.localizedDescription)
            }
        }
    }

    func installLater() {
        installOnQuit = true
        closeWindow()
    }

    func retry() {
        interactive = true
        beginCheck()
    }

    func closeWindow() {
        window?.close()
    }

    func windowDidClose() {
        switch phase {
        case .checking, .downloading: work?.cancel()
        case .ready: installOnQuit = true
        case .installing: return
        default: break
        }
        phase = .idle
        interactive = false
    }

    @objc private func appWillTerminate() {
        guard installOnQuit, let pending else { return }
        try? Installer.install(pending)
    }

    private func showWindow(activate: Bool) {
        if window == nil { window = UpdateWindow(updater: self) }
        window?.show(activate: activate)
    }

    // MARK: Headless API, for custom UI or command-line tools

    /// The newest release on the user's channel (or a more stable one) if it's
    /// newer than the running app.
    public func findUpdate() async throws -> Release? {
        Channel.newest(try await source.releases(), newerThan: HostApp.version, on: channel, in: channels)
    }

    /// The channel a release belongs to, or nil if it's on none of `channels`.
    public func channel(of release: Release) -> Channel? {
        Channel.index(ofLabel: release.channelLabel, in: channels).map { channels[$0] }
    }

    /// Downloads, verifies and unpacks a release, ready for `install`.
    public func prepare(_ release: Release, progress: (@Sendable (_ received: Int64, _ total: Int64) -> Void)? = nil) async throws -> PreparedUpdate {
        try await Installer.prepare(release, progress: progress ?? { _, _ in })
    }

    /// Replaces the running app with the update. With `relaunch`, the app quits
    /// and reopens; otherwise the new version runs next time it's opened.
    public func install(_ update: PreparedUpdate, relaunch: Bool = true) throws {
        try Installer.install(update)
        pending = nil
        installOnQuit = false
        if relaunch {
            Installer.relaunch()
            NSApp.terminate(nil)
        }
    }
}

/// A SwiftUI picker for the update channel, for your settings window. Shows
/// nothing when stable is the only channel.
public struct ChannelPicker: View {
    @ObservedObject private var updater: Updater
    private let title: String

    public init(_ title: String = "Update channel", updater: Updater) {
        self.title = title
        self.updater = updater
    }

    public var body: some View {
        if updater.channels.count > 1 {
            Picker(title, selection: $updater.channel) {
                ForEach(updater.channels, id: \.self) { Text($0.title).tag($0) }
            }
        }
    }
}

/// A SwiftUI "Check for Updates…" button, for `.commands { CommandGroup(after: .appInfo) { … } }`.
public struct CheckForUpdatesButton: View {
    private let updater: Updater
    private let title: String

    public init(_ title: String = "Check for Updates…", updater: Updater) {
        self.title = title
        self.updater = updater
    }

    public var body: some View {
        Button(title) { updater.checkForUpdates() }
    }
}
