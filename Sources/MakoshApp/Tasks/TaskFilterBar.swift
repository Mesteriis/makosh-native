import MakoshTasks
import SwiftUI

/// Sort chips (off → ↑ → ↓ → off), the active filter chips with «×», and the
/// «only actual» / «group by flow» flags, shown by the reference's rules.
struct TaskFilterBar: View {
    @ObservedObject var model: TasksWorkspaceModel

    private var canShowActualOnly: Bool { model.filters.status == nil }
    private var hasFlowTasks: Bool { model.filters.flow == nil && model.visible.contains { $0.flowID != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Сортировка:").font(.caption).foregroundStyle(.secondary)
                ForEach(TasksSort.allCases, id: \.self) { field in
                    let active = model.sortState?.field == field
                    Button {
                        model.sortState = TasksSortState.toggled(model.sortState, field: field)
                    } label: {
                        HStack(spacing: 3) {
                            Text(title(field))
                            if active { Text(model.sortState?.descending == true ? "↓" : "↑").font(.system(size: 9)) }
                        }
                        .font(.caption).padding(.horizontal, 8).padding(.vertical, 2)
                        .background(
                            active ? TaskStyle.selection.opacity(0.15) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(active ? TaskStyle.selection.opacity(0.35) : Color.clear))
                        .foregroundStyle(active ? TaskStyle.selection : .secondary)
                    }.buttonStyle(.plain).accessibilityIdentifier("tasks.sort.\(field.rawValue)")
                }
                Spacer()
            }
            if model.filters.isFiltering || canShowActualOnly || hasFlowTasks {
                HStack(spacing: 6) {
                    if !model.filters.chips.isEmpty { Text("Фильтр:").font(.caption).foregroundStyle(.secondary) }
                    ForEach(model.filters.chips) { chip in
                        HStack(spacing: 4) {
                            Text(chip.title)
                            Button {
                                model.filters.clear(chip.kind)
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.caption).padding(.horizontal, 8).padding(.vertical, 2)
                        .background(
                            (chip.kind == .day ? TaskStyle.due : TaskStyle.selection).opacity(0.2), in: RoundedRectangle(cornerRadius: 4)
                        )
                        .foregroundStyle(chip.kind == .day ? TaskStyle.due : TaskStyle.selection)
                        .accessibilityIdentifier("tasks.filterChip.\(chip.id)")
                    }
                    Spacer()
                    if canShowActualOnly {
                        Toggle("Только актуальные", isOn: $model.filters.actualOnly).toggleStyle(WorkspaceToggleStyle(checkbox: true)).font(
                            .caption
                        )
                        .accessibilityIdentifier("tasks.actualOnly")
                    }
                    if hasFlowTasks {
                        Toggle("Группировать по цепочкам", isOn: $model.filters.groupByFlow).toggleStyle(
                            WorkspaceToggleStyle(checkbox: true)
                        ).font(.caption)
                            .accessibilityIdentifier("tasks.groupByFlow")
                    }
                }
            }
        }
    }

    private func title(_ field: TasksSort) -> String {
        switch field {
        case .priority: "Приоритет"
        case .status: "Статус"
        case .due: "Срок"
        case .created: "Создание"
        }
    }
}
