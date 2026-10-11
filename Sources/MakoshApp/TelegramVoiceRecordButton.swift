import SwiftUI
import AppKit
import MakoshTelegram

/// The same native control survives composer state changes during a held drag.
struct TelegramVoiceRecordButton: NSViewRepresentable {
    let model: TelegramModel
    let phase: TelegramVoiceRecordingPhase
    let inputContextID: UUID
    let canBegin: Bool
    init(model: TelegramModel, phase: TelegramVoiceRecordingPhase) {
        self.model = model; self.phase = phase
        inputContextID = model.voiceInputContextID
        canBegin = model.canStartVoiceRecording
    }
    func makeNSView(context: Context) -> VoiceButton { VoiceButton(frame: .zero) }
    func updateNSView(_ view: VoiceButton, context: Context) {
        let inputContext = inputContextID
        view.updateContext(inputContext)
        view.begin = { model.beginVoiceRecording(contextID: inputContext) }
        view.cancelCapture = model.cancelVoiceRecording
        view.move = model.voiceRecording.move
        view.release = model.voiceRecording.release
        view.send = model.voiceRecording.send
        view.canBegin = canBegin
        view.locked = phase == .locked
        view.isEnabled = view.canBegin || phase == .recording || phase == .locked || phase == .authorizing
        view.image = NSImage(systemSymbolName: view.locked ? "paperplane.fill" : "mic.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
        view.contentTintColor = phase == .recording || view.locked ? .white : .controlAccentColor
        view.layer?.backgroundColor = phase == .recording || view.locked ? NSColor.controlAccentColor.cgColor : nil
        view.setAccessibilityLabel(view.locked ? "Отправить запись" : "Записать голосовое сообщение")
        view.toolTip = view.locked ? "Отправить запись" : "Удерживайте для записи. Потяните вверх, чтобы закрепить; отпустите вне кнопки для отмены."
    }
    static func dismantleNSView(_ view: VoiceButton, coordinator: ()) {
        view.invalidateHold(); view.cancelCapture()
    }
    @MainActor final class VoiceButton: NSButton {
        var begin: () -> Void = {}
        var move: (Double) -> Void = { _ in }
        var release: (Bool) -> Void = { _ in }
        var send: () -> Void = {}
        var cancelCapture: () -> Void = {}
        var canBegin = false, locked = false
        private var hold: Task<Void, Never>?
        private var startPoint: NSPoint?
        private var began = false
        private var voiceHoldContext: UUID?
        func updateContext(_ id: UUID) {
            if voiceHoldContext != id { invalidateHold(); voiceHoldContext = id }
        }
        func invalidateHold() { hold?.cancel(); hold = nil; startPoint = nil; began = false }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, window != nil { invalidateHold(); cancelCapture() }
            super.viewWillMove(toWindow: newWindow)
        }
        override init(frame: NSRect) {
            super.init(frame: frame)
            title = ""; isBordered = false; imagePosition = .imageOnly
            wantsLayer = true; layer?.cornerRadius = 16
            target = self; action = #selector(accessibleAction)
            setAccessibilityIdentifier("telegram.voice.record")
        }
        required init?(coder: NSCoder) { return nil }
        isolated deinit { hold?.cancel() }
        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            if locked { send(); return }
            guard canBegin else { return }
            startPoint = event.locationInWindow; began = false
            hold?.cancel()
            let begin = self.begin
            hold = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                guard let self, self.startPoint != nil, self.canBegin else { return }
                self.began = true; begin()
            }
        }
        override func mouseDragged(with event: NSEvent) {
            guard began, let startPoint else { return }
            move(event.locationInWindow.y - startPoint.y)
        }
        override func mouseUp(with event: NSEvent) {
            hold?.cancel(); hold = nil; startPoint = nil
            if began { began = false; release(bounds.contains(convert(event.locationInWindow, from: nil))) }
        }
        @objc private func accessibleAction() {
            guard isEnabled else { return }
            if locked { send() }
            else if canBegin { begin(); move(101) }
        }
        override func accessibilityPerformPress() -> Bool {
            guard isEnabled else { return false }
            accessibleAction(); return true
        }
    }
}
