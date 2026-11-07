import MakoshTasks
import SwiftUI

/// Frames of the guide's targets in the section's coordinate space.
struct TasksGuideAnchorKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

extension View {
    /// Marks a view as a guide target.
    func tasksGuideAnchor(_ id: String) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: TasksGuideAnchorKey.self, value: [id: geometry.frame(in: .named("tasksSection"))])
            }
        }
    }
}

struct TasksGuideStep {
    let target: String
    let title: String
    let text: String

    static let all: [TasksGuideStep] = [
        TasksGuideStep(
            target: "sidebar", title: "Боковая панель",
            text: "Повестка, статусы, списки, теги, персоны и цепочки. Фильтры сочетаются; клик по активному снимает его."),
        TasksGuideStep(
            target: "search", title: "Поиск",
            text: "⌘E раскрывает поиск по названию, тегу, списку и коду. Раскладка не важна: «ghbdtn» найдёт «привет»."),
        TasksGuideStep(
            target: "create-task", title: "Быстрый ввод",
            text: "Одна строка: Название @список #тег /персона !1 ^завтра *weekly >>цепочка ~код. Токены превращаются в чипы."),
        TasksGuideStep(
            target: "sort-filter", title: "Сортировка и фильтры",
            text: "Чипы сортировки переключаются ↑ → ↓ → выкл. Активные фильтры снимаются крестиком или Esc."),
        TasksGuideStep(
            target: "task-row", title: "Строка задачи",
            text: "Space — сделано, S — статус, 1–4 — приоритет, ⇧P — отложить, Enter — правка, F2 — переименовать, правый клик — меню."),
        TasksGuideStep(
            target: "detail-panel", title: "Детали",
            text: "Календарь и поля задачи: клик по значению открывает правку. Несколько выделенных — сводка."),
    ]
}

/// The reference's onboarding: a dim with a cutout around the target and a tooltip beside it.
struct TasksGuideOverlay: View {
    @ObservedObject var model: TasksWorkspaceModel
    let anchors: [String: CGRect]

    private var steps: [TasksGuideStep] { TasksGuideStep.all }
    private var index: Int { model.guideStep ?? 0 }
    private var step: TasksGuideStep? { steps.indices.contains(index) ? steps[index] : nil }

    var body: some View {
        GeometryReader { geometry in
            if let step, let frame = anchors[step.target] {
                let cutout = frame.insetBy(dx: -8, dy: -8)
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        var dim = Path(CGRect(origin: .zero, size: size))
                        dim.addRoundedRect(in: cutout, cornerSize: CGSize(width: 8, height: 8))
                        context.fill(dim, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
                    }
                    RoundedRectangle(cornerRadius: 8).stroke(TaskStyle.selection.opacity(0.6), lineWidth: 2).frame(
                        width: cutout.width, height: cutout.height
                    )
                    .offset(x: cutout.minX, y: cutout.minY).allowsHitTesting(false)
                    tooltip(step).frame(width: 320).offset(tooltipOffset(for: cutout, in: geometry.size))
                }
                .contentShape(Rectangle())
                .onTapGesture {}
            } else {
                Color.clear.onAppear { advance(from: index) }
            }
        }
        .accessibilityIdentifier("tasks.guide")
    }

    private func tooltip(_ step: TasksGuideStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(index + 1) из \(steps.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Пропустить") { model.finishGuide() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
            Text(step.title).font(.callout.weight(.semibold))
            Text(step.text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Назад") { back(from: index) }.controlSize(.small).disabled(previousIndex(from: index) == nil)
                Spacer()
                Button(nextIndex(from: index) == nil ? "Готово" : "Далее") { advance(from: index) }.controlSize(.small).buttonStyle(
                    .borderedProminent
                )
                .accessibilityIdentifier("tasks.guide.next")
            }
        }
        .padding(14).background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15))).shadow(radius: 12)
    }

    /// Below the target when it fits, else above, right, left, else bottom centre.
    private func tooltipOffset(for cutout: CGRect, in size: CGSize) -> CGSize {
        let width: CGFloat = 320, height: CGFloat = 180, gap: CGFloat = 12
        let clampX = max(8, min(cutout.minX, size.width - width - 8))
        let clampY = max(8, min(cutout.minY, size.height - height - 8))
        if size.height - cutout.maxY >= height + gap { return CGSize(width: clampX, height: cutout.maxY + gap) }
        if cutout.minY >= height + gap { return CGSize(width: clampX, height: cutout.minY - gap - height) }
        if size.width - cutout.maxX >= width + gap { return CGSize(width: cutout.maxX + gap, height: clampY) }
        if cutout.minX >= width + gap { return CGSize(width: cutout.minX - width - gap, height: clampY) }
        return CGSize(width: (size.width - width) / 2, height: max(8, size.height - height - 16))
    }

    private func nextIndex(from current: Int) -> Int? {
        var next = current + 1
        while next < steps.count, anchors[steps[next].target] == nil { next += 1 }
        return next < steps.count ? next : nil
    }
    private func previousIndex(from current: Int) -> Int? {
        var previous = current - 1
        while previous >= 0, anchors[steps[previous].target] == nil { previous -= 1 }
        return previous >= 0 ? previous : nil
    }
    private func advance(from current: Int) {
        if let next = nextIndex(from: current) { model.guideStep = next } else { model.finishGuide() }
    }
    private func back(from current: Int) {
        if let previous = previousIndex(from: current) { model.guideStep = previous }
    }
}
