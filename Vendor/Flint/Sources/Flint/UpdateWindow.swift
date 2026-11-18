import AppKit
import SwiftUI

/// The one window Flint shows. It sizes itself to the current view and stays
/// anchored at its top edge as it grows or shrinks between states.
@MainActor
final class UpdateWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private weak var updater: Updater?
    private var anchor: NSPoint?

    init(updater: Updater) {
        self.updater = updater
        let host = NSHostingController(rootView: UpdateView(updater: updater))
        host.sizingOptions = .preferredContentSize
        window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Software Update"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init()
        window.delegate = self
    }

    func show(activate: Bool) {
        if !window.isVisible {
            window.layoutIfNeeded()
            window.center()
            anchor = NSPoint(x: window.frame.midX, y: window.frame.maxY)
        }
        if activate {
            if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    func close() { window.close() }

    func windowDidResize(_ notification: Notification) {
        guard let anchor, window.isVisible else { return }
        let frame = window.frame
        window.setFrameOrigin(NSPoint(x: (anchor.x - frame.width / 2).rounded(), y: anchor.y - frame.height))
    }

    func windowDidMove(_ notification: Notification) {
        anchor = NSPoint(x: window.frame.midX, y: window.frame.maxY)
    }

    func windowWillClose(_ notification: Notification) {
        updater?.windowDidClose()
    }
}
