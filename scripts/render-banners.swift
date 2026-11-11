// Renders the README banners in .github/readme/src to PNGs at 2x, using WebKit.
// Usage: swift scripts/render-banners.swift   (from the repo root, needs a network
// connection for the Satoshi and IBM Plex Mono webfonts)
import AppKit
import WebKit
setvbuf(stdout, nil, _IONBF, 0)

struct Job { let page: String; let out: String; let width: CGFloat; let height: CGFloat }

let section = { (n: String, title: String, text: String, tags: String) -> String in
    let hash = [n, title, text, tags].joined(separator: "|")
        .addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)!
    return "section.html#\(hash)"
}

let jobs: [Job] = [
    Job(page: "hero.html", out: "hero.png", width: 1200, height: 628),
    Job(page: section("01", "Install", "One universal build for Apple silicon and Intel, on macOS 13 or later.",
                      "dmg · Homebrew · source"), out: "sec-install.png", width: 1200, height: 170),
    Job(page: section("02", "Features", "Everything you'd expect from a terminal, and a few small things on top.",
                      "Tabs · Splits · Palette"), out: "sec-features.png", width: 1200, height: 170),
    Job(page: section("03", "Themes", "Five built in, previewed live from the palette or Settings.",
                      "Dark · Light"), out: "sec-themes.png", width: 1200, height: 170),
    Job(page: section("04", "Shortcuts", "The ones you know from Terminal and iTerm, plus a palette for the rest.",
                      "Keyboard first"), out: "sec-shortcuts.png", width: 1200, height: 170),
    Job(page: section("05", "Development", "Build it, poke at it with the dev hooks, and cut a release.",
                      "Swift · AppKit · SwiftTerm"), out: "sec-dev.png", width: 1200, height: 170),
    Job(page: "themes.html", out: "themes.png", width: 1200, height: 560),
    Job(page: "footer.html", out: "footer.png", width: 1200, height: 340),
]

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let src = root.appendingPathComponent(".github/readme/src")
let outDir = root.appendingPathComponent(".github/readme")

final class Renderer: NSObject, WKNavigationDelegate {
    var queue: [Job]
    let web: WKWebView
    var current: Job?

    init(jobs: [Job]) {
        queue = jobs
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 628))
        super.init()
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
    }

    func next() {
        guard !queue.isEmpty else { exit(0) }
        let job = queue.removeFirst()
        current = job
        web.setFrameSize(NSSize(width: job.width, height: job.height))
        // Pages that differ only by #hash would be a same-document navigation with no
        // didFinish, so go through a blank page first.
        blanking = true
        web.loadHTMLString("", baseURL: nil)
    }

    var blanking = false

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if blanking, let job = current {
            blanking = false
            let url = URL(string: job.page, relativeTo: src.appendingPathComponent("x"))!
            web.loadFileURL(url, allowingReadAccessTo: root)
            return
        }
        // Wait for the webfonts and images, then a beat for layout.
        webView.callAsyncJavaScript(
            "await document.fonts.ready; await Promise.all([...document.images].map(i => i.decode().catch(() => {}))); return 1",
            arguments: [:], in: nil, in: .page
        ) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.snap() }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("failed: \(error)"); exit(1)
    }

    func snap() {
        guard let job = current else { return }
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: job.width, height: job.height)
        config.snapshotWidth = NSNumber(value: Double(job.width * 2) / Double(NSScreen.main?.backingScaleFactor ?? 2))
        web.takeSnapshot(with: config) { image, error in
            guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                print("snapshot failed: \(String(describing: error))"); exit(1)
            }
            let out = outDir.appendingPathComponent(job.out)
            try! png.write(to: out)
            print("› \(job.out) \(rep.pixelsWide)×\(rep.pixelsHigh)")
            self.next()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1200, height: 700),
                      styleMask: [.borderless], backing: .buffered, defer: false)
let renderer = Renderer(jobs: jobs)
window.contentView = renderer.web
window.orderFrontRegardless()
renderer.next()
app.run()
