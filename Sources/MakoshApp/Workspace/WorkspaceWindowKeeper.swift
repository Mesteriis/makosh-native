import AppKit
import SwiftUI

/// Keeps the workspace window alive when it is closed: closing only hides it, so every
/// service model the window owns (Telegram, mail, WhatsApp, Teams, Telemost) keeps
/// running in the background, and the Dock or a second launch shows the same window.
@MainActor final class WorkspaceWindowKeeper {
    private(set) weak var window: NSWindow?
    private(set) var proxy: WindowCloseProxy?

    func keep(_ window: NSWindow) {
        if self.window === window, window.delegate === proxy { return }
        self.window = window
        let proxy = WindowCloseProxy(original: window.delegate)
        self.proxy = proxy
        window.delegate = proxy
    }

    /// Shows the kept window; false when there is none and the system should open one.
    @discardableResult func reopen() -> Bool {
        guard let window else { return false }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

/// Forwards everything to SwiftUI's own window delegate except the close, which hides the window.
final class WindowCloseProxy: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?

    init(original: NSWindowDelegate?) {
        self.original = original
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}

/// Hands the workspace window to the keeper once SwiftUI has created it.
struct WorkspaceWindowAccessor: NSViewRepresentable {
    let keeper: WorkspaceWindowKeeper

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { keeper.keep(window) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let window = view.window { keeper.keep(window) } }
    }
}
