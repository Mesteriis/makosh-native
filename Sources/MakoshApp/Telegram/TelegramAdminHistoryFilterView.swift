import SwiftUI
import MakoshTelegram

struct TelegramAdminHistoryFilterDraft: Identifiable {
    let id: UUID
    let filter: TelegramAdminHistoryFilter
    let actors: [Int64: String]
}

struct TelegramAdminHistoryFilterView: View {
    @ObservedObject var controller: TelegramGroupMembershipController
    let basis: TelegramAdminHistoryFilterDraft
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TelegramAdminHistoryFilter
    @State private var changed = false
    init(controller: TelegramGroupMembershipController, basis: TelegramAdminHistoryFilterDraft) {
        self.controller = controller; self.basis = basis; _draft = State(initialValue: basis.filter)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Фильтр событий").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Button("Все события") { draft.kinds = nil }.accessibilityIdentifier("telegram.group.history.filter.all")
                    ForEach(TelegramAdminEventKind.allCases, id: \.rawValue) { kind in
                        Toggle(kind.title, isOn: Binding(get: { draft.kinds?.contains(kind) ?? true }, set: { selected in
                            var kinds = draft.kinds ?? Set(TelegramAdminEventKind.allCases)
                            if selected { kinds.insert(kind) } else { kinds.remove(kind) }
                            draft.kinds = kinds.count == TelegramAdminEventKind.allCases.count ? nil : kinds
                        })).accessibilityIdentifier("telegram.group.history.kind.\(kind.rawValue)")
                    }
                    Divider()
                    Text("Авторы загруженных событий").font(.headline)
                    Button("Все авторы") { draft.adminIDs = [] }
                    ForEach(basis.actors.keys.sorted(), id: \.self) { id in
                        Toggle(basis.actors[id] ?? String(id), isOn: Binding(get: { draft.adminIDs.contains(id) }, set: { selected in
                            if selected { draft.adminIDs.insert(id) } else { draft.adminIDs.remove(id) }
                        })).accessibilityIdentifier("telegram.group.history.actor.\(id)")
                    }
                    Text(draft.adminIDs.isEmpty ? "Показаны все авторы." : "Выбрано авторов: \(draft.adminIDs.count). Максимум 100.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(4)
            }
            if changed { Text("Контекст изменился. Откройте фильтр заново.").foregroundStyle(.orange) }
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Применить") {
                    if controller.filterHistory(draft, contextID: basis.id) { dismiss() } else { changed = true }
                }.disabled(!draft.isValid || controller.isBusy || controller.contextID != basis.id)
                    .accessibilityIdentifier("telegram.group.history.filter.apply")
            }
        }.padding(24).frame(width: 430, height: 600)
    }
}

private extension TelegramAdminEventKind {
    var title: String {
        switch self {
        case .join: "Вступления"
        case .leave: "Выходы"
        case .invite: "Добавления участников"
        case .ban: "Ограничения участников"
        case .unban: "Снятие ограничений"
        case .kick: "Исключения участников"
        case .unkick: "Отмена исключений"
        case .promote: "Назначения администраторов"
        case .demote: "Снятие администраторов"
        case .info: "Изменения информации"
        case .settings: "Изменения настроек"
        case .pinnedMessages: "Закреплённые сообщения"
        case .editMessages: "Правки сообщений"
        case .deleteMessages: "Удаления сообщений"
        case .calls: "Звонки"
        case .invites: "Пригласительные ссылки"
        case .sendMessages: "Отправленные сообщения"
        case .forums: "Темы форума"
        }
    }
}
