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
        view.requestCancel = model.voiceRecording.requestCancel
        view.move = model.voiceRecording.move
        view.release = model.voiceRecording.release
        view.send = model.voiceRecording.send
        view.toggle = {
            guard model.voiceInputContextID == inputContext, model.canStartVoiceRecording else { return }
            model.voiceRecording.toggleKind()
        }
        view.canBegin = canBegin
        view.locked = phase == .locked
        view.updateRecordingPresentation(phase: phase,
            roundVideo: model.voiceRecording.selectedKind == .roundVideo,
            level: model.voiceRecording.level, canUseOneTime: model.voiceRecording.canUseOneTime,
            isOneTime: model.voiceRecording.isOneTime,
            toggleOneTime: { model.voiceRecording.setOneTime(!model.voiceRecording.isOneTime) })
        view.isEnabled = view.canBegin || phase == .recording || phase == .locked || phase == .authorizing
        let round = model.voiceRecording.selectedKind == .roundVideo
        let floating = phase == .authorizing || phase == .recording || phase == .locked
        view.image = floating ? nil : NSImage(systemSymbolName: round ? "video.fill" : "mic.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
        view.contentTintColor = .controlAccentColor
        view.layer?.backgroundColor = nil
        view.setAccessibilityLabel(view.locked ? "Отправить запись" : round ? "Записать круглое видео" : "Записать голосовое сообщение")
        view.toolTip = view.locked ? "Отправить запись" : "Клик — сменить тип записи. Удерживайте для записи, потяните вверх, чтобы закрепить; отпустите вне кнопки для отмены."
        view.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Переключить тип записи") { [weak view] in
                guard let view, view.canBegin else { return false }
                view.toggle(); return true
            }
        ])
    }
    static func dismantleNSView(_ view: VoiceButton, coordinator: ()) {
        view.invalidateHold(); view.cancelCapture()
    }
    @MainActor final class VoiceButton: NSButton {
        var begin: () -> Void = {}
        var move: (Double) -> Void = { _ in }
        var release: (Bool) -> Void = { _ in }
        var send: () -> Void = {}
        var toggle: () -> Void = {}
        var cancelCapture: () -> Void = {}
        var requestCancel: () -> Void = {}
        var canBegin = false, locked = false
        private var hold: Task<Void, Never>?
        private var startPoint: NSPoint?
        private var latestPoint: NSPoint?
        private var began = false
        private var voiceHoldContext: UUID?
        private var overlay: TelegramRecorderOverlay?
        private var monitor: Any?
        func updateContext(_ id: UUID) {
            if voiceHoldContext != id { invalidateHold(); voiceHoldContext = id }
        }
        func invalidateHold() {
            hold?.cancel(); hold = nil; startPoint = nil; latestPoint = nil; began = false
            hideOverlay(animated: false)
        }
        func updateRecordingPresentation(phase: TelegramVoiceRecordingPhase, roundVideo: Bool,
            level: Float, canUseOneTime: Bool, isOneTime: Bool, toggleOneTime: @escaping () -> Void) {
            if phase == .authorizing || phase == .recording || phase == .locked {
                showOverlay()
                overlay?.primaryAction = { [weak self] in
                    guard let self else { return }
                    if self.locked { self.send() } else { self.move(101) }
                }
                overlay?.toggleOneTime = toggleOneTime
                overlay?.update(roundVideo: roundVideo, locked: phase == .locked, level: level,
                    canUseOneTime: canUseOneTime, isOneTime: isOneTime)
            } else { hideOverlay() }
        }
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
        isolated deinit { hold?.cancel(); hideOverlay(animated: false) }
        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            if locked {
                if overlay?.contains(screenPoint(event)) ?? bounds.contains(convert(event.locationInWindow, from: nil)) { send() }
                else { requestCancel() }
                return
            }
            guard canBegin else { return }
            startPoint = screenPoint(event); latestPoint = startPoint; began = false
            hold?.cancel()
            let begin = self.begin
            hold = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                guard let self, let start = self.startPoint, let latest = self.latestPoint,
                      self.canBegin, abs(latest.x - start.x) <= 2, abs(latest.y - start.y) <= 2,
                      let window = self.window,
                      self.bounds.contains(self.convert(window.convertPoint(fromScreen: latest), from: nil)) else { return }
                self.began = true; self.showOverlay(); begin()
            }
        }
        override func mouseDragged(with event: NSEvent) {
            let pointer = screenPoint(event)
            latestPoint = pointer
            guard began, let startPoint else { return }
            let upward = pointer.y - startPoint.y
            move(upward)
            overlay?.move(upward: upward, pointer: pointer)
        }
        override func mouseUp(with event: NSEvent) {
            let hadPress = startPoint != nil
            hold?.cancel(); hold = nil; startPoint = nil; latestPoint = nil
            let inside = overlay?.contains(screenPoint(event)) ?? bounds.contains(convert(event.locationInWindow, from: nil))
            if began {
                began = false
                if !locked { hideOverlay() }
                release(inside)
            }
            else if hadPress, inside, canBegin { toggle() }
        }
        @objc private func accessibleAction() {
            guard isEnabled else { return }
            if locked { send() }
            else if canBegin { showOverlay(); begin(); move(101) }
        }
        override func accessibilityPerformPress() -> Bool {
            guard isEnabled else { return false }
            accessibleAction(); return true
        }
        private func screenPoint(_ event: NSEvent) -> NSPoint {
            (event.window ?? window)?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        }
        private func showOverlay() {
            guard overlay == nil, window != nil else { return }
            overlay = TelegramRecorderOverlay(anchor: self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .leftMouseDown, .mouseMoved]) { [weak self] event in
                guard let self, let overlay = self.overlay, overlay.owns(event.window) else { return event }
                switch event.type {
                case .leftMouseDragged:
                    self.mouseDragged(with: event); return nil
                case .leftMouseUp where self.startPoint != nil:
                    self.mouseUp(with: event); return nil
                case .leftMouseDown where self.locked:
                    let pointer = self.screenPoint(event)
                    if overlay.isOneTimeControl(pointer) { return event }
                    self.mouseDown(with: event)
                    return nil
                case .mouseMoved:
                    overlay.updatePointer(self.screenPoint(event)); return event
                default: return event
                }
            }
        }
        private func hideOverlay(animated: Bool = true) {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            overlay?.hide(animated: animated); overlay = nil
        }
    }
}
