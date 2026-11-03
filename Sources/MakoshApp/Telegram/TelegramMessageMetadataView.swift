import SwiftUI
import MakoshTelegram

/// Own rendering of the timestamp/status arrangement confirmed in ChatRightView.
struct TelegramMessageMetadataView: View {
    let message: TelegramMessage
    var includesDate = false

    var body: some View {
        HStack(spacing: 4) {
            Text(message.date.formatted(date: includesDate ? .abbreviated : .omitted, time: .shortened))
                .help(message.date.formatted(date: .complete, time: .shortened))
            if let label = statusLabel {
                statusIcon
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label)
                    .accessibilityIdentifier("telegram.delivery.\(message.id)")
                    .help(label)
            }
        }.font(.caption2).foregroundStyle(.secondary)
    }

    @ViewBuilder private var statusIcon: some View {
        switch message.delivery {
        case .queued, .sending:
            Image(systemName: "clock").frame(width: 12, height: 12)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                .frame(width: 12, height: 12)
        case .sent:
            Image(systemName: "checkmark").frame(width: 12, height: 12)
        case .read, .saved, .sentToBot:
            ZStack {
                Image(systemName: "checkmark").offset(x: -3)
                Image(systemName: "checkmark").offset(x: 3)
            }.frame(width: 18, height: 12)
        case .none, .unknown:
            EmptyView()
        }
    }

    private var statusLabel: String? {
        switch message.delivery {
        case .none, .unknown: nil
        case .queued: "В очереди отправки"
        case .sending: "Отправляется"
        case .failed: "Не отправлено"
        case .sent: "Отправлено в Telegram; прочтение не подтверждено"
        case .read: "Прочитано по состоянию Telegram"
        case .saved: "Сохранено в Избранном"
        case .sentToBot: "Отправлено боту"
        }
    }
}
