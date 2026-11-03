import SwiftUI
import MakoshTelegram

struct TelegramSavedMessagesForwardStatus: View {
    @ObservedObject var controller: TelegramSavedMessagesForwardController
    let synthetic: Bool
    var body: some View {
        if controller.phase != .idle {
            HStack(alignment: .top) {
                if controller.isBusy { ProgressView().controlSize(.small) }
                Text((synthetic ? "Симуляция: " : "") + (controller.error ?? status)).font(.caption)
                Spacer()
                if controller.isBusy { Button("Прекратить ожидание", action: controller.cancel).controlSize(.small) }
            }.padding(12).accessibilityIdentifier("telegram.savedForward.status")
        }
    }
    private var status: String {
        switch controller.phase {
        case .idle: ""
        case .validating: "Проверяем пересылку в Избранное…"
        case .committing: "Пересылаем в Избранное…"
        case .queued: "Пересылка в Избранное принята локальной очередью. Доставка на сервере ещё не подтверждена."
        case .rejected: "Пересылка в Избранное отклонена: сообщения изменились или сейчас недоступны."
        case .uncertain, .applied: "Результат пересылки в Избранное неизвестен. Автоматический повтор отключён."
        }
    }
}
