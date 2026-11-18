import SwiftUI

struct UpdateView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        switch updater.phase {
        case .idle:
            Color.clear.frame(width: 360, height: 1)
        case .checking:
            StatusView(title: "Checking for Updates…", message: "Looking for a newer version of \(HostApp.name).", busy: true) {
                Button { updater.closeWindow() } label: { wide("Cancel") }
                    .keyboardShortcut(.cancelAction)
            }
        case .upToDate:
            StatusView(badge: .ok, title: "You're Up to Date", message: "\(HostApp.name) \(HostApp.versionString) is the latest version.") {
                Button { updater.closeWindow() } label: { wide("OK") }
                    .keyboardShortcut(.defaultAction)
            }
        case .failed(let title, let message):
            StatusView(badge: .warning, title: title, message: message) {
                Button { updater.closeWindow() } label: { wide("Close") }
                    .keyboardShortcut(.cancelAction)
                Button { updater.retry() } label: { wide("Try Again") }
                    .keyboardShortcut(.defaultAction)
            }
        case .available(let release), .downloading(let release, _, _), .ready(let release), .installing(let release):
            ReleaseView(updater: updater, release: release)
        }
    }
}

private func bytes(_ count: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false
    return formatter.string(fromByteCount: count)
}

private func wide(_ title: String) -> some View {
    Text(title).frame(maxWidth: .infinity)
}

// MARK: - Small dialogs

private struct StatusView<Actions: View>: View {
    enum Badge { case ok, warning }

    var badge: Badge?
    var title: String
    var message: String
    var busy = false
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            AppIcon(size: 76)
                .overlay(alignment: .bottomTrailing) { badgeView.offset(x: 6, y: 4) }
                .padding(.bottom, 16)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
            if busy {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .padding(.top, 16)
            }
            HStack(spacing: 10) { actions }
                .controlSize(.large)
                .padding(.top, 22)
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 22)
        .frame(width: 360)
    }

    @ViewBuilder private var badgeView: some View {
        switch badge {
        case .ok:
            symbol("checkmark.circle.fill", .green)
        case .warning:
            symbol("exclamationmark.triangle.fill", .orange)
        case nil:
            EmptyView()
        }
    }

    private func symbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, color)
            .font(.system(size: 26, weight: .semibold))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }
}

// MARK: - Update available

private struct ReleaseView: View {
    @ObservedObject var updater: Updater
    let release: Release

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 18)
            notes
            footer
                .frame(height: 64, alignment: .bottom)
                .padding(.top, 14)
                .animation(.easeInOut(duration: 0.18), value: updater.phase)
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 20)
        .frame(width: 580)
    }

    private var isReady: Bool {
        if case .ready = updater.phase { return true }
        if case .installing = updater.phase { return true }
        return false
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            AppIcon(size: 68)
            VStack(alignment: .leading, spacing: 4) {
                Text(isReady ? "\(HostApp.name) \(release.version.description) Is Ready to Install" : "A new version of \(HostApp.name) is available")
                    .font(.system(size: 17, weight: .semibold))
                Text("\(HostApp.name) \(release.version.description) is now available — you have \(HostApp.versionString).")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Pill(text: release.version.description, tint: .accentColor)
                    if let channel = updater.channel(of: release), channel != .stable {
                        Pill(text: channel.title, tint: updater.channels.last == channel && updater.channels.count > 2 ? .purple : .orange)
                    }
                    if !details.isEmpty {
                        Text(details)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private var details: String {
        var parts: [String] = []
        if let date = release.date { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        if let size = release.size, size > 0 { parts.append(bytes(size)) }
        return parts.joined(separator: "  ·  ")
    }

    private var notes: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Group {
            if let html = release.notesHTML {
                ReleaseNotesView(html: html)
                    .padding(1)
            } else {
                Text("No release notes were provided.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 270)
        .background(shape.fill(Color(nsColor: .textBackgroundColor).opacity(0.55)))
        .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        .clipShape(shape)
    }

    @ViewBuilder private var footer: some View {
        switch updater.phase {
        case .downloading(_, let received, let total):
            VStack(alignment: .leading, spacing: 10) {
                if total > 0, received < total {
                    ProgressView(value: Double(received), total: Double(total))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack {
                    Text(downloadStatus(received, total))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button("Cancel") { updater.cancelDownload() }
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)
                }
            }
        case .ready:
            HStack(spacing: 10) {
                Label {
                    Text("Downloaded and verified")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                Spacer()
                Button("Install on Quit") { updater.installLater() }
                    .keyboardShortcut(.cancelAction)
                Button("Restart Now") { updater.restartNow() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        case .installing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Installing…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(height: 28)
        default:
            VStack(spacing: 14) {
                HStack {
                    Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                    Spacer()
                    if let page = release.pageURL {
                        Link(destination: page) {
                            HStack(spacing: 3) {
                                Text("Release Page")
                                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                            }
                        }
                        .font(.system(size: 12))
                    }
                }
                HStack(spacing: 10) {
                    Button("Skip This Version") { updater.skip(release) }
                    Spacer()
                    Button("Remind Me Later") { updater.closeWindow() }
                        .keyboardShortcut(.cancelAction)
                    Button("Install Update") { updater.download(release) }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            }
        }
    }

    private func downloadStatus(_ received: Int64, _ total: Int64) -> String {
        if total > 0, received >= total { return "Verifying and preparing update…" }
        let got = bytes(received)
        guard total > 0 else { return "Downloading… \(got)" }
        return "Downloading… \(got) of \(bytes(total))"
    }
}

private struct Pill: View {
    var text: String
    var tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

private struct AppIcon: View {
    var size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}
