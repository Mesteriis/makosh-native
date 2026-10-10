import AppKit
import Carbon
import Combine
import SwiftUI
import MakoshTelegram

struct TelegramProfilePhotosPresentation: Identifiable {
    let id = UUID()
    let title: String
}

/// SwiftUI owns the request; AppKit owns only the borderless, screen-sized window.
struct TelegramProfilePhotosPresenter: NSViewRepresentable {
    let presentation: TelegramProfilePhotosPresentation?
    let gallery: TelegramProfilePhotosController
    let dismissed: @MainActor (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.moved = { [weak coordinator = context.coordinator] in coordinator?.reconcile() }
        context.coordinator.anchor = view
        return view
    }
    func updateNSView(_ view: Anchor, context: Context) {
        context.coordinator.request = presentation
        context.coordinator.gallery = gallery
        context.coordinator.dismissed = dismissed
        context.coordinator.reconcile()
    }
    static func dismantleNSView(_ view: Anchor, coordinator: Coordinator) {
        view.moved = nil
        coordinator.close(restoreFocus: false)
    }

    @MainActor final class Anchor: NSView {
        var moved: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); moved?() }
    }

    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        weak var anchor: Anchor?
        var request: TelegramProfilePhotosPresentation?
        var gallery: TelegramProfilePhotosController?
        var dismissed: (@MainActor (UUID) -> Void)?
        private var activeID: UUID?
        private weak var parent: NSWindow?
        private var window: GalleryWindow?
        private var activeGallery: TelegramProfilePhotosController?
        private var state: AnyCancellable?
        private var parentClosing: AnyCancellable?

        func reconcile() {
            guard let request, let gallery, let parent = anchor?.window else {
                close(restoreFocus: false); return
            }
            guard activeID != request.id else { return }
            close(restoreFocus: false, cancelGallery: activeGallery !== gallery)
            guard gallery.state != .idle, let screen = parent.screen ?? NSScreen.main else { return }
            let window = GalleryWindow(contentRect: screen.frame, styleMask: .borderless,
                backing: .buffered, defer: false, screen: screen)
            window.setFrame(screen.frame, display: false)
            window.title = request.title
            window.identifier = NSUserInterfaceItemIdentifier("telegram.profilePhotos.window")
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .popUpMenu
            window.hidesOnDeactivate = true
            window.collectionBehavior = [.fullScreenAuxiliary]
            window.delegate = self
            window.closeRequested = { [weak self] in self?.close(restoreFocus: true) }
            window.contentViewController = NSHostingController(rootView:
                TelegramProfilePhotosView(gallery: gallery, title: request.title,
                    close: { [weak self] in self?.close(restoreFocus: true) })
                    .padding(.top, screen.safeAreaInsets.top)
                    .frame(width: screen.frame.width, height: screen.frame.height)
                    .background(Color.black.opacity(0.9))
            )
            // Hosting's initial fitting size must not replace the screen frame.
            window.setFrame(screen.frame, display: false)
            self.parent = parent; self.window = window; activeGallery = gallery; activeID = request.id
            let id = request.id
            state = gallery.$state.sink { [weak self] value in
                guard value == .idle else { return }
                Task { @MainActor [weak self] in
                    guard self?.activeID == id, self?.activeGallery?.state == .idle else { return }
                    self?.close(restoreFocus: true)
                }
            }
            parentClosing = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: parent)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard self?.activeID == id else { return }
                        self?.close(restoreFocus: false)
                    }
                }
            parent.addChildWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }

        func close(restoreFocus: Bool, cancelGallery: Bool = true) {
            guard let id = activeID else { return }
            activeID = nil
            state = nil; parentClosing = nil
            let previous = window, parent = parent, callback = dismissed, previousGallery = activeGallery
            window = nil; self.parent = nil; activeGallery = nil
            previous?.delegate = nil
            previous?.closeRequested = nil
            previous?.commandHandler = nil
            if let previous { parent?.removeChildWindow(previous); previous.close() }
            previous?.contentViewController = nil
            if cancelGallery { previousGallery?.close() }
            if restoreFocus, NSApp.isActive, let parent, parent.isVisible, !parent.isMiniaturized {
                parent.makeKeyAndOrderFront(nil)
            }
            // Dismantling/reconciliation can run during a SwiftUI update.
            Task { @MainActor in callback?(id) }
        }

        func windowWillClose(_ notification: Notification) { close(restoreFocus: true) }
        isolated deinit { close(restoreFocus: false) }
    }

    @MainActor final class GalleryWindow: NSWindow {
        enum Command { case previous, next, zoomIn, zoomOut, rotate, save }
        var closeRequested: (() -> Void)?
        var commandHandler: ((Command) -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func performClose(_ sender: Any?) { closeRequested?() }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            handle(event) || super.performKeyEquivalent(with: event)
        }
        override func keyDown(with event: NSEvent) {
            if !handle(event) { super.keyDown(with: event) }
        }
        // This hosting controller is outside the main SwiftUI scene. Route only
        // this key window's commands, leaving an attached save panel in control.
        private func handle(_ event: NSEvent) -> Bool {
            guard isKeyWindow, attachedSheet == nil else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // Reference commands use physical keys, including with a Cyrillic
            // input source. Text characters would turn Cmd-R into Cmd-К.
            let key = Int(event.keyCode)
            if modifiers == .command {
                switch key {
                case kVK_ANSI_R: commandHandler?(.rotate)
                case kVK_ANSI_S: commandHandler?(.save)
                case kVK_ANSI_W: closeRequested?()
                default: return false
                }
            } else if modifiers.isEmpty {
                switch key {
                case kVK_LeftArrow: commandHandler?(.previous)
                case kVK_RightArrow: commandHandler?(.next)
                case kVK_ANSI_Equal: commandHandler?(.zoomIn)
                case kVK_ANSI_Minus: commandHandler?(.zoomOut)
                case kVK_Escape, kVK_Space: closeRequested?()
                default: return false
                }
            } else if modifiers == .shift, key == kVK_ANSI_Equal {
                commandHandler?(.zoomIn)
            } else { return false }
            return true
        }
    }
}
