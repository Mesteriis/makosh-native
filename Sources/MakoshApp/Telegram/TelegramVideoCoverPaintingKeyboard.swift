import AppKit
import SwiftUI

/// Bare tool keys need an AppKit first responder in nested SwiftUI sheets.
/// This view owns no event monitor and only handles keys while attached.
struct TelegramVideoCoverPaintingKeyboard: NSViewRepresentable {
    let selectTool: (UInt16) -> Bool
    func makeNSView(context: Context) -> KeyView {
        let view = KeyView(); view.selectTool = selectTool
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: KeyView, context: Context) { view.selectTool = selectTool }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) {
        view.selectTool = nil
        if view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
    }
    final class KeyView: NSView {
        var selectTool: ((UInt16) -> Bool)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
        private func handle(_ event: NSEvent) -> Bool {
            guard window?.isKeyWindow == true,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
            return selectTool?(event.keyCode) ?? false
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            handle(event) || super.performKeyEquivalent(with: event)
        }
        override func keyDown(with event: NSEvent) {
            if !handle(event) { super.keyDown(with: event) }
        }
    }
}
