import SwiftUI
import AppKit
import MakoshTelegram

#if DEBUG
struct TelegramSyntheticPreviewView: View {
    @StateObject private var model: TelegramModel
    private let persistentDrafts: Bool
    init(model: TelegramModel = .syntheticPreview(), persistentDrafts: Bool = false) {
        _model = StateObject(wrappedValue: model)
        self.persistentDrafts = persistentDrafts
    }
    var body: some View {
        SyntheticWorkspaceFrame(service: .telegram) {
            VStack(spacing: 0) {
                Text(
                    persistentDrafts
                        ? "СИНТЕТИЧЕСКАЯ ПРОВЕРКА • отдельный Postbox черновиков • личные аккаунты, PostgreSQL, сеть и отправка не используются"
                        : "СИНТЕТИЧЕСКАЯ ПРОВЕРКА • личные аккаунты, база данных, сеть и отправка не используются"
                )
                .font(.caption.bold()).padding(10).frame(maxWidth: .infinity).background(.yellow.opacity(0.15))
                Button("QA: ошибка следующего поискового запроса", action: model.search.failNextSyntheticMessageSearch)
                    .controlSize(.small).padding(6).accessibilityIdentifier("telegram.qa.failSearch")
                HStack(spacing: 0) {
                    TelegramSidebarView(model: model).frame(width: 320)
                    Divider()
                    TelegramDetailView(model: model)
                }
            }
        } settings: {
            TelegramWorkspaceSettings(model: model, embedded: true, close: {})
        }
        .modifier(TelegramNotificationHost(controller: model.notifications))
    }
}

struct TelegramDraftsSyntheticPreviewView: View {
    @State private var model: TelegramModel?
    @State private var failure: String?
    var body: some View {
        Group {
            if let model {
                WorkspaceView(syntheticTelegram: model)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Label("СИНТЕТИЧЕСКАЯ ПРОВЕРКА ЧЕРНОВИКОВ", systemImage: "testtube.2")
                                .font(.caption.bold())
                                .help("Отдельные Postbox и схема PostgreSQL; личные аккаунты и сеть Telegram не используются")
                        }
                    }
            } else if let failure {
                Text(failure).padding(24)
            } else {
                ProgressView("Открытие отдельного синтетического Postbox…")
            }
        }.task {
            guard model == nil, failure == nil else { return }
            do {
                let arguments = CommandLine.arguments
                guard let index = arguments.firstIndex(of: "--telegram-drafts-synthetic-preview"), arguments.indices.contains(index + 1)
                else {
                    throw CocoaError(.fileReadUnknown)
                }
                let preview = try await TelegramModel.syntheticDraftPreview(
                    directory: URL(fileURLWithPath: arguments[index + 1]),
                    albums: arguments.contains("--telegram-albums-qa"),
                    extendedMessages: arguments.contains("--telegram-extended-messages-synthetic-preview"))
                if arguments.contains("--telegram-round-video-qa") { preview.voiceRecording.toggleKind() }
                model = preview
            } catch { failure = "Не удалось открыть отдельное синтетическое хранилище черновиков." }
        }
    }
}
#endif
