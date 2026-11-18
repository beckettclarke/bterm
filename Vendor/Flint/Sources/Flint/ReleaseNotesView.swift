import SwiftUI
import WebKit

/// Release notes HTML in a transparent, script-free web view that follows the
/// system appearance. Links open in the default browser.
struct ReleaseNotesView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        web.autoresizingMask = [.width, .height]
        context.coordinator.web = web

        // SwiftUI's clipShape doesn't reach into AppKit views, so clip with a layer.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 9
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.addSubview(web)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let web = context.coordinator.web, context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        web.loadHTMLString(Self.page(html), baseURL: URL(string: "https://github.com/"))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?
        var web: WKWebView?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }

    private static func page(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; }
        html, body { background: transparent; margin: 0; }
        body { font: 13px/1.55 -apple-system, system-ui; color: -apple-system-label; padding: 14px 18px 18px;
               -webkit-font-smoothing: antialiased; overflow-wrap: anywhere; }
        body > :first-child { margin-top: 0; }
        h1, h2, h3, h4, h5, h6 { font-weight: 600; line-height: 1.25; margin: 1.1em 0 .45em; }
        h1 { font-size: 1.3em; } h2 { font-size: 1.16em; } h3 { font-size: 1.04em; } h4, h5, h6 { font-size: 1em; }
        p { margin: .5em 0; }
        ul, ol { padding-left: 1.35em; margin: .4em 0; }
        li { margin: .22em 0; } li::marker { color: -apple-system-secondary-label; }
        a { color: -apple-system-control-accent; text-decoration: none; } a:hover { text-decoration: underline; }
        code { font: 11.5px ui-monospace, Menlo, monospace; background: -apple-system-quaternary-label;
               padding: .12em .38em; border-radius: 4px; }
        pre { background: -apple-system-quaternary-label; padding: 10px 12px; border-radius: 7px; overflow: auto; }
        pre code { background: none; padding: 0; }
        img { max-width: 100%; height: auto; border-radius: 6px; }
        hr { border: 0; border-top: 1px solid -apple-system-separator; margin: 1.1em 0; }
        blockquote { margin: .6em 0; padding: 0 0 0 12px; border-left: 3px solid -apple-system-separator;
                     color: -apple-system-secondary-label; }
        table { border-collapse: collapse; margin: .6em 0; }
        th, td { border: 1px solid -apple-system-separator; padding: 4px 9px; text-align: left; }
        .markdown-alert { padding: 2px 12px; border-left: 3px solid -apple-system-control-accent; margin: .6em 0; }
        .markdown-alert-title { font-weight: 600; }
        .octicon { display: none; }
        </style></head><body>\(body)</body></html>
        """
    }
}
