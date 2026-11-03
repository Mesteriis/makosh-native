import SwiftUI
import AppKit
import MakoshTelegram

struct TelegramSearchStatusView: View {
    let status: TelegramSearchStatus
    let retry: () -> Void
    var body: some View {
        if status == .loading {
            HStack {
                ProgressView().controlSize(.mini)
                Text("Поиск…").font(.caption).foregroundStyle(.secondary)
            }
        } else if status == .failed || status == .timedOut {
            HStack {
                Text(
                    status == .failed
                        ? "Не удалось выполнить поиск. Показанные результаты сохранены."
                        : "Поиск занимает больше времени. Можно повторить запрос."
                )
                .font(.caption).foregroundStyle(.secondary)
                Button("Повторить", action: retry).controlSize(.small).accessibilityIdentifier("telegram.search.retry")
            }
        }
    }
}

struct TelegramPaginationBar: View {
    let page: TelegramPageNavigation
    let prefix: String
    let previous: () -> Void
    let next: () -> Void
    let latest: () -> Void
    let retry: () -> Void

    var body: some View {
        if page.canLoadPrevious || page.canLoadNext || !page.isAtLatest || page.isLoading || page.timedOut {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: previous) { Label("Старее", systemImage: "chevron.left") }
                        .disabled(!page.canLoadPrevious).accessibilityIdentifier(prefix + ".older")
                    Button(action: next) { Label("Новее", systemImage: "chevron.right") }
                        .disabled(!page.canLoadNext).accessibilityIdentifier(prefix + ".newer")
                    Spacer(minLength: 4)
                    Button("Последние", action: latest).disabled(page.isLoading || page.isAtLatest)
                        .accessibilityIdentifier(prefix + ".latest")
                }.controlSize(.small)
                if page.isLoading {
                    HStack {
                        ProgressView().controlSize(.mini)
                        Text("Загрузка из Telegram…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if page.timedOut {
                    HStack(alignment: .top) {
                        Text("Загрузка занимает больше времени. Показанные данные сохранены.").font(.caption).foregroundStyle(.secondary)
                        Button("Повторить", action: retry).controlSize(.small).accessibilityIdentifier(prefix + ".retry")
                    }
                }
            }
        }
    }
}
