import SwiftUI
import AppKit
import MakoshTelegram

private struct HistoryReadFrame: Equatable, Sendable {
    let id: String?
    let context: TelegramHistoryReadContext
    let rect: CGRect
}
private struct HistoryReadFrames: PreferenceKey {
    static let defaultValue: [HistoryReadFrame] = []
    static func reduce(value: inout [HistoryReadFrame], nextValue: () -> [HistoryReadFrame]) {
        value.append(contentsOf: nextValue())
    }
}

struct TelegramHistoryReadRow: View {
    let id: String
    let context: TelegramHistoryReadContext?
    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: HistoryReadFrames.self, value: context.map {
                [HistoryReadFrame(id: id, context: $0, rect: geometry.frame(in: .global))]
            } ?? [])
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct TelegramHistoryReadViewport: ViewModifier {
    @ObservedObject var model: TelegramModel
    let context: TelegramHistoryReadContext?
    @State private var frames: [HistoryReadFrame] = []
    @State private var eligibility: (@MainActor () -> Bool)?
    @State private var mounted = false
    @State private var generation = UUID()
    @State private var evaluation: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geometry in
                Color.clear.preference(key: HistoryReadFrames.self, value: context.map {
                    [HistoryReadFrame(id: nil, context: $0, rect: geometry.frame(in: .global))]
                } ?? [])
            }.allowsHitTesting(false).accessibilityHidden(true)
        }.background {
            HistoryReadWindowGate(publicationID: generation) { check in
                guard mounted else { eligibility = nil; return }
                eligibility = check; schedule()
            }
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .onPreferenceChange(HistoryReadFrames.self) { frames = $0; schedule() }
        .onChange(of: context) { _, _ in model.cancelAutomaticDownloads(); generation = UUID(); schedule() }
        .onAppear { generation = UUID(); mounted = true; schedule() }
        .onDisappear {
            mounted = false; eligibility = nil; generation = UUID(); frames = []
            evaluation?.cancel(); evaluation = nil
            if let context { _ = model.markVisibleHistoryRead(messageIDs: [], context: context, windowIsActive: false) }
            if let context { model.setVisibleAutomaticDownloads(messageIDs: [], context: context, windowIsActive: false, eligibility: { false }) }
        }
    }
    private func schedule() {
        evaluation?.cancel()
        let token = generation
        evaluation = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, token == generation, mounted, let context else { return }
            let matching = frames.filter { $0.context == context }
            let viewport = matching.first { $0.id == nil }?.rect
            let ids: Set<String>
            if let viewport {
                ids = Set(matching.compactMap { frame in
                    guard let id = frame.id,
                          TelegramHistoryReadVisibility.isVisible(row: frame.rect, viewport: viewport) else { return nil }
                    return id
                })
            } else { ids = [] }
            // Notifications trigger reevaluation; only the current native state
            // authorizes it. No await may separate this check and the model call.
            let active = eligibility?() == true
            model.setVisibleAutomaticDownloads(messageIDs: ids, context: context, windowIsActive: active, eligibility: eligibility ?? { false })
            _ = model.markVisibleHistoryRead(messageIDs: active ? ids : [], context: context, windowIsActive: active)
        }
    }
}

private struct HistoryReadWindowGate: NSViewRepresentable {
    let publicationID: UUID
    let changed: @MainActor (@escaping @MainActor () -> Bool) -> Void
    func makeNSView(context: Context) -> GateView { GateView() }
    func updateNSView(_ view: GateView, context: Context) {
        view.changed = changed
        view.setPublicationID(publicationID)
        view.schedule()
    }
    static func dismantleNSView(_ view: GateView, coordinator: ()) { view.stop() }

    @MainActor final class GateView: NSView {
        var changed: (@MainActor (@escaping @MainActor () -> Bool) -> Void)?
        private var publicationID: UUID?
        private var stopped = false
        private var observers: [NSObjectProtocol] = []
        private var generation = UUID()
        private var lastValue: Bool?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObservers(); generation = UUID(); lastValue = nil
            if window != nil {
                let names: [Notification.Name] = [
                    NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                    NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                    NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                    NSWindow.didChangeOcclusionStateNotification, NSWindow.willBeginSheetNotification,
                    NSWindow.didEndSheetNotification, NSWindow.willCloseNotification
                ]
                observers = names.map { name in
                    NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        Task { @MainActor [weak self] in self?.schedule() }
                    }
                }
            }
            schedule()
        }
        override func viewDidHide() { super.viewDidHide(); schedule() }
        override func viewDidUnhide() { super.viewDidUnhide(); schedule() }
        override func layout() { super.layout(); schedule() }
        func schedule() {
            let token = generation
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, token == self.generation else { return }
                let value = self.isEligible()
                guard self.lastValue != value else { return }
                self.lastValue = value; self.publishEligibility()
            }
        }
        private func isEligible() -> Bool {
            guard !stopped, let window else { return false }
            return NSApp.isActive && window.isKeyWindow && window.isVisible && !window.isMiniaturized &&
                window.occlusionState.contains(.visible) && window.attachedSheet == nil && NSApp.modalWindow == nil &&
                !isHiddenOrHasHiddenAncestor && visibleRect.width > 0 && visibleRect.height > 0
        }
        func setPublicationID(_ id: UUID) {
            guard publicationID != id else { return }
            publicationID = id
            publishEligibility()
        }
        func publishEligibility() {
            let token = generation, publication = publicationID
            Task { @MainActor [weak self] in
                guard let self, !self.stopped, token == self.generation, publication == self.publicationID else { return }
                self.changed?({ [weak self] in
                    guard let self, token == self.generation, publication == self.publicationID else { return false }
                    return self.isEligible()
                })
            }
        }
        private func stopObservers() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
        }
        func stop() { stopped = true; generation = UUID(); stopObservers(); changed = nil; publicationID = nil; lastValue = nil }
        isolated deinit { stopObservers() }
    }
}
