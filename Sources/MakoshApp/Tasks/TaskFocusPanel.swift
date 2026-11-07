import AppKit
import Combine
import MakoshTasks
import SwiftUI

/// The focus panel: a borderless, non-activating panel along the top edge of
/// the main window's screen, the macOS stand-in for the reference's AppBar.
@MainActor final class TaskFocusPanelController {
    private var panel: NSPanel?
    private var model: TasksWorkspaceModel?
    private var observation: AnyCancellable?
    private var screenObservation: AnyCancellable?
    private var shown = false

    func attach(_ model: TasksWorkspaceModel) {
        self.model = model
        observation = model.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.sync() }
        screenObservation = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reposition() }
        sync()
    }

    private func sync() {
        guard let model else { return }
        if model.focusEnabled, !shown { show() } else if !model.focusEnabled, shown { hide() }
        if shown { reposition() }
    }

    private func show() {
        guard let model else { return }
        if panel == nil {
            let created = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 26), styleMask: [.nonactivatingPanel, .borderless, .utilityWindow],
                backing: .buffered, defer: false)
            created.level = .statusBar
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            created.isFloatingPanel = true
            created.hidesOnDeactivate = false
            created.isMovableByWindowBackground = false
            created.hasShadow = true
            created.backgroundColor = .clear
            created.isOpaque = false
            created.contentView = NSHostingView(rootView: TaskFocusBarView(model: model))
            created.identifier = NSUserInterfaceItemIdentifier("tasks.focusPanel")
            panel = created
        }
        reposition()
        panel?.orderFrontRegardless()
        shown = true
    }

    private func hide() {
        panel?.orderOut(nil)
        shown = false
    }

    /// Full width of the main window's screen, just under the menu bar.
    private func reposition() {
        guard let panel, let model else { return }
        let screen = NSApp.mainWindow?.screen ?? NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let height: CGFloat = model.focusConfig.compact ? 26 : max(26, min(52, (screen.frame.height / 33).rounded()))
        let frame = NSRect(x: screen.frame.minX, y: screen.visibleFrame.maxY - height, width: screen.frame.width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}

/// Three zones: state and presets; the current task with the countdown and
/// controls; waiting tasks, counter, next slot, clock and the close button.
struct TaskFocusBarView: View {
    @ObservedObject var model: TasksWorkspaceModel
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var state: TaskFocusState { model.focusState }
    private var config: TaskFocusConfig { model.focusConfig }
    private var running: Bool { state.pomodoro.phase != .idle }
    private var paused: Bool { state.pomodoro.pausedAt != nil }
    private var remaining: TimeInterval { state.remaining(now: now) }
    private var progress: Double {
        guard running, state.pomodoro.plannedMinutes > 0 else { return 0 }
        return min(1, 1 - remaining / Double(state.pomodoro.plannedMinutes * 60))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HStack(spacing: 8) {
                leftZone.frame(maxWidth: .infinity, alignment: .leading)
                centerZone
                rightZone.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 10).frame(maxHeight: .infinity)
            if running {
                GeometryReader { geometry in
                    Rectangle().fill(state.pomodoro.phase == .break ? Color.green : Color.red).frame(
                        width: geometry.size.width * progress, height: 2)
                }.frame(height: 2)
            }
        }
        .font(.system(size: 11))
        .background(WorkspaceStyle.base.opacity(0.96))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1) }
        .onReceive(ticker) { now = $0 }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("tasks.focusBar")
    }

    private func title(of taskID: UUID) -> String { model.task(id: taskID)?.title ?? "…" }

    private var leftZone: some View {
        HStack(spacing: 6) {
            Circle().fill(state.pomodoro.phase == .work ? Color.red : state.pomodoro.phase == .break ? Color.green : Color.gray).frame(
                width: 10, height: 10)
            if config.modules.contains(.presets) {
                ForEach(config.presets, id: \.self) { minutes in
                    barButton(minutes >= 60 && minutes % 60 == 0 ? "\(minutes / 60)ч" : "\(minutes)′") {
                        _Concurrency.Task { await model.pomodoro(.start(minutes: minutes)) }
                    }
                }
                if let slot = model.currentSlot(now: now) {
                    barButton("до \(TaskPlanSlot.time(slot.end))") {
                        let minutes = max(1, slot.end - model.minutesOfDayPublic(now))
                        _Concurrency.Task { await model.pomodoro(.start(minutes: minutes)) }
                    }.help("До конца слота планера")
                }
            }
        }
    }

    @ViewBuilder private var centerZone: some View {
        HStack(spacing: 6) {
            if state.pomodoro.phase == .break {
                Text("Перерыв").font(.system(size: 13, weight: .medium)).foregroundStyle(.green)
                if config.modules.contains(.timer) { Text(clock(remaining)).font(.system(size: 13)).monospacedDigit() }
                barButton(systemImage: "forward.end") { _Concurrency.Task { await model.pomodoro(.stop) } }.help("Пропустить перерыв")
                if let active = state.active { Text(title(of: active.taskID)).foregroundStyle(.secondary).lineLimit(1) }
            } else if let active = state.active {
                Button(title(of: active.taskID)) { openTask(active.taskID) }.buttonStyle(.plain).font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 420)
                if config.modules.contains(.timer) {
                    Text(running ? clock(remaining) : TaskStyle.clock(state.workSeconds(of: active.taskID, now: now))).font(
                        .system(size: 13)
                    ).monospacedDigit()
                        .opacity(paused ? 0.5 : 1)
                }
                if config.modules.contains(.controls) {
                    if running {
                        barButton(systemImage: paused ? "play.fill" : "pause.fill") {
                            _Concurrency.Task { await model.pomodoro(paused ? .resume : .pause) }
                        }
                        barButton(systemImage: "stop.fill") { _Concurrency.Task { await model.pomodoro(.stop) } }
                    }
                    barButton(systemImage: "checkmark", tint: .green) { _Concurrency.Task { await model.focusDone(id: active.taskID) } }
                        .help("Сделано")
                    barButton(systemImage: "hourglass") { _Concurrency.Task { await model.park() } }.help("Отложить в ждущие")
                }
            } else {
                Button("Выберите задачу") { openMain() }.buttonStyle(.plain).italic().foregroundStyle(.secondary)
                if let slot = model.currentSlot(now: now), let taskID = slot.taskID {
                    chip(systemImage: "play.fill", tint: TaskStyle.selection, text: title(of: taskID), help: "Из расписания") {
                        _Concurrency.Task { await model.focus(id: taskID) }
                    }
                }
            }
        }
    }

    private var rightZone: some View {
        HStack(spacing: 6) {
            if config.modules.contains(.waiting) {
                ForEach(state.waiting.prefix(3), id: \.taskID) { session in
                    HStack(spacing: 4) {
                        Image(systemName: "hourglass").font(.system(size: 9)).foregroundStyle(.orange)
                        Text(title(of: session.taskID)).lineLimit(1).frame(maxWidth: 140)
                        Text("\(state.waitingSeconds(of: session.taskID, now: now) / 60)м").foregroundStyle(.secondary).monospacedDigit()
                        Button {
                            _Concurrency.Task { await model.removeFromFocus(id: session.taskID) }
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8))
                        }
                        .buttonStyle(.plain).opacity(0.5)
                    }
                    .padding(.horizontal, 6).frame(height: 18).background(Color.white.opacity(0.08), in: Capsule())
                    .contentShape(Capsule()).onTapGesture { _Concurrency.Task { await model.focus(id: session.taskID) } }
                }
                if state.waiting.count > 3 { Text("+\(state.waiting.count - 3)").foregroundStyle(.secondary) }
            }
            if config.modules.contains(.counter) { Text("🍅×\(state.todayCount(now: now, calendar: model.calendar))").monospacedDigit() }
            if config.modules.contains(.nextSlot), let next = model.nextSlot(now: now) {
                Text("Далее \(TaskPlanSlot.time(next.start)) · \(next.taskID.map(title(of:)) ?? next.title ?? "")").foregroundStyle(
                    .secondary
                ).lineLimit(1)
                    .frame(maxWidth: 220)
            }
            if config.modules.contains(.clock) {
                Text(now.formatted(date: .omitted, time: .shortened)).monospacedDigit().foregroundStyle(.secondary)
            }
            barButton(systemImage: "xmark") { _Concurrency.Task { await model.setFocusEnabled(false) } }.help("Скрыть панель")
        }
    }

    private func barButton(_ text: String, action: @escaping () -> Void) -> some View {
        Button(text, action: action).buttonStyle(.plain).padding(.horizontal, 4).opacity(0.75)
    }
    private func barButton(systemImage: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: systemImage).font(.system(size: 10)) }.buttonStyle(.plain).padding(.horizontal, 3)
            .foregroundStyle(tint).opacity(0.85)
    }
    private func chip(systemImage: String, tint: Color, text: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 9)).foregroundStyle(tint)
                Text(text).lineLimit(1).frame(maxWidth: 180)
            }.padding(.horizontal, 6).frame(height: 18).background(Color.white.opacity(0.08), in: Capsule())
        }.buttonStyle(.plain).help(help)
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private func openTask(_ id: UUID) {
        model.selected = id
        openMain()
    }

    private func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        (NSApp.windows.first { $0.identifier?.rawValue != "tasks.focusPanel" && $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }
}

extension TasksWorkspaceModel {
    /// Minutes since midnight of `date`, for the panel's «until the slot ends».
    public func minutesOfDayPublic(_ date: Date) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
