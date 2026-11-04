import Foundation
import MakoshAI
import MakoshCore

/// One AI worker per process, shared by the workspace window and the
/// settings scene. The workspace hands over the database configuration once
/// its own load has resolved it.
@MainActor final class AIHost: ObservableObject {
    let workspace: AIWorkspaceModel
    let settings: AISettingsModel
    @Published private(set) var configuration: ContactWorkspaceConfiguration?
    let isSynthetic: Bool

    init(worker: AIWorker, synthetic: Bool = false) {
        workspace = AIWorkspaceModel(worker: worker)
        settings = AISettingsModel(worker: worker)
        isSynthetic = synthetic
        workspace.follow(settings)
    }

    convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Makosh", isDirectory: true)
        let args = CommandLine.arguments
        let storage =
            args.firstIndex(of: "--storage-config").flatMap {
                args.indices.contains($0 + 1) && !args[$0 + 1].hasPrefix("--") ? URL(fileURLWithPath: args[$0 + 1]) : nil
            } ?? support.appendingPathComponent("s3.json")
        self.init(
            worker: AIWorker(
                images: AIImageStore(s3ConfigurationFile: storage, localDirectory: support.appendingPathComponent("AI", isDirectory: true)))
        )
    }

    func start(configuration: ContactWorkspaceConfiguration) async {
        guard self.configuration == nil else { return }
        self.configuration = configuration
        await workspace.start(configuration: configuration)
        await settings.start(configuration: configuration)
    }
}

extension AIRole {
    var title: String {
        switch self {
        case .chat: "Беседа"
        case .embeddings: "Поиск (эмбеддинги)"
        case .images: "Изображения"
        case .transcription: "Распознавание речи"
        case .speech: "Синтез речи"
        }
    }
}

extension AIFailure {
    var message: String {
        switch self {
        case .invalidConnection: "Проверьте название и адрес подключения: нужен HTTPS или локальный HTTP-сервер."
        case .invalidConfiguration: "Действие недоступно в текущем состоянии."
        case .storage: "Не удалось прочитать или сохранить данные ИИ."
        case .keyUnavailable: "Ключ хранилища или токен недоступен в связке ключей."
        case .roleUnassigned(let role): "Назначьте модель для роли «\(role.title)» в Настройки → ИИ."
        case .unauthorized: "Провайдер отклонил токен. Проверьте подключение."
        case .rateLimited: "Провайдер ограничил частоту запросов. Попробуйте позже."
        case .server(let status): "Провайдер вернул ошибку \(status)."
        case .network: "Соединение с провайдером прервалось."
        case .malformedResponse: "Провайдер вернул ответ в неожиданном формате."
        case .cancelled: "Запрос остановлен."
        case .busy: "Дождитесь окончания текущего ответа или остановите его."
        }
    }
}
