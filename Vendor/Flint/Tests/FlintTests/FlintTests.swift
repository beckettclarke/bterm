@testable import Flint
import XCTest

final class VersionTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(Version("v1.2.3").description, "1.2.3")
        XCTAssertEqual(Version("myapp-v3.1").description, "3.1")
        XCTAssertEqual(Version("2.0.0-beta.2+build.7").description, "2.0.0-beta.2")
        XCTAssertEqual(Version("1.0b3").description, "1.0-b3")
        XCTAssertEqual(Version("1.4 (52)").description, "1.4")
    }

    func testOrdering() {
        let ordered = ["0.9", "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0", "1.0.1", "1.2", "1.10"]
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(Version(a), Version(b), "\(a) < \(b)")
        }
        XCTAssertEqual(Version("1.0"), Version("v1.0.0"))
        XCTAssertEqual(Set([Version("1.0"), Version("1.0.0")]).count, 1)
    }
}

final class AssetTests: XCTestCase {
    func testPicksMacArchive() {
        let names = ["MyApp-linux-x86_64.tar.gz", "MyApp-windows.zip", "MyApp.dmg", "MyApp-macos.zip", "MyApp.dSYM.zip", "checksums.txt"]
        XCTAssertEqual(GitHubSource.pickAsset(names, pattern: nil).map { names[$0] }, "MyApp-macos.zip")
    }

    func testPrefersNativeArchitecture() {
        let names = ["App-x86_64.zip", "App-arm64.zip"]
        #if arch(arm64)
        XCTAssertEqual(GitHubSource.pickAsset(names, pattern: nil).map { names[$0] }, "App-arm64.zip")
        #else
        XCTAssertEqual(GitHubSource.pickAsset(names, pattern: nil).map { names[$0] }, "App-x86_64.zip")
        #endif
    }

    func testPattern() {
        let names = ["App.zip", "App-Pro-2.0.dmg"]
        XCTAssertEqual(GitHubSource.pickAsset(names, pattern: "app-pro-*.dmg"), 1)
        XCTAssertNil(GitHubSource.pickAsset(["source.tar.gz", "notes.txt"], pattern: nil))
    }
}

final class MarkdownTests: XCTestCase {
    func testBlocks() {
        let html = Markdown.html("""
        ## What's new
        - **Faster** sync
        - Fixed `a < b` bug, see [#12](https://x.y/12)

        Thanks _everyone_.
        """)
        XCTAssertTrue(html.contains("<h2>What&#39;s new</h2>") || html.contains("<h2>What's new</h2>"))
        XCTAssertTrue(html.contains("<li><strong>Faster</strong> sync</li>"))
        XCTAssertTrue(html.contains("<code>a &lt; b</code>"))
        XCTAssertTrue(html.contains(#"<a href="https://x.y/12">#12</a>"#))
        XCTAssertTrue(html.contains("<p>Thanks <em>everyone</em>.</p>"))
        XCTAssertTrue(html.contains("</ul>"))
    }

    func testSnakeCaseIsNotItalic() {
        XCTAssertEqual(Markdown.html("use some_var_name here"), "<p>use some_var_name here</p>\n")
    }
}

final class ChannelTests: XCTestCase {
    private let channels = Channel.normalized([.beta, .nightly])

    private func release(_ version: String, channel: String? = nil, prerelease: Bool? = nil) -> Release {
        Release(version: Version(version), downloadURL: URL(string: "https://x.y/\(version).zip")!, isPrerelease: prerelease, channel: channel)
    }

    private func index(_ r: Release) -> Int? { Channel.index(ofLabel: r.channelLabel, in: channels) }

    func testLabels() {
        XCTAssertEqual(index(release("1.4.0")), 0)
        XCTAssertEqual(index(release("1.4.0-beta.2")), 1)
        XCTAssertEqual(index(release("1.4.0-beta2")), 1)
        XCTAssertEqual(index(release("1.4.0-rc.1")), 1, "alias")
        XCTAssertEqual(index(release("1.4.0-nightly.20261118")), 2)
        XCTAssertNil(index(release("1.4.0-weird.1")), "unknown labels are ignored")
        XCTAssertEqual(index(release("1.4.0", prerelease: true)), 1, "flagged pre-release without a label")
        XCTAssertNil(Channel.index(ofLabel: "nightly", in: Channel.defaults), "undeclared channel")
        XCTAssertEqual(index(release("1.4.0", channel: "Beta")), 1, "explicit channel wins")
        XCTAssertNil(Channel.index(ofLabel: "beta", in: [.stable]), "never offered when only stable exists")
    }

    func testNewestFollowsMoreStableChannels() {
        let all = [release("1.3.0"), release("1.4.0-beta.1"), release("1.4.0-nightly.20261118"), release("1.3.1")]
        func newest(_ current: String, _ channel: Channel) -> String? {
            Channel.newest(all, newerThan: Version(current), on: channel, in: channels)?.version.description
        }
        XCTAssertEqual(newest("1.3.0", .stable), "1.3.1")
        XCTAssertEqual(newest("1.3.0", .beta), "1.4.0-beta.1")
        XCTAssertEqual(newest("1.3.0", .nightly), "1.4.0-nightly.20261118")
        XCTAssertNil(newest("1.4.0-beta.1", .stable), "no downgrade when leaving beta")
        let shipped = all + [release("1.4.0")]
        XCTAssertEqual(Channel.newest(shipped, newerThan: Version("1.4.0-beta.1"), on: .beta, in: channels)?.version.description, "1.4.0",
                       "beta testers get the final release")
    }

    func testInfoPlistList() {
        let list = Channel.list(fromInfoPlist: ["beta", ["name": "nightly", "aliases": ["dev"], "title": "Nightly Builds"]])!
        XCTAssertEqual(list.map(\.name), ["beta", "nightly"])
        XCTAssertEqual(list[1].title, "Nightly Builds")
        XCTAssertTrue(list[1].matches("dev"))
        XCTAssertTrue(list[0].matches("rc"), "plain names pick up the built-in aliases")
        XCTAssertEqual(Channel.normalized(["stable", "beta"]).map(\.name), ["stable", "beta"])
    }
}
