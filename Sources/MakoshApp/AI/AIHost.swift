import Foundation
import MakoshAI
import MakoshCore
import MakoshMail
import MakoshTeams

/// One AI worker per process, shared by the workspace window and the
/// settings scene. The workspace hands over the database configuration once
/// its own load has resolved it.
@MainActor final class AIHost: ObservableObject {
    let worker: AIWorker
    let workspace: AIWorkspaceModel
    let settings: AISettingsModel
    @Published private(set) var configuration: ContactWorkspaceConfiguration?
    @Published private(set) var indexStatus = AIIndexStatus()
    @Published private(set) var enabledScopes: [AIAccessScope] = []
    /// Bumped after any access change so toggles reload their state.
    @Published private(set) var accessRevision = 0
    let isSynthetic: Bool
    private var access: AIArchiveAccessProvider?
    private var indexer: AIIndexer?

    init(worker: AIWorker, synthetic: Bool = false) {
        self.worker = worker
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

    /// Opens the conversation store, then the index: the archive and mail
    /// sources, the access flags and the vector store, all off the main actor.
    func start(
        configuration: ContactWorkspaceConfiguration, contacts: ContactWorkspaceWorker?,
        keyProvider: @escaping @Sendable (UUID, Bool) throws -> Data = MessageArchiveKeychain.open, mail: Bool = true
    ) async {
        guard self.configuration == nil else { return }
        self.configuration = configuration
        await workspace.start(configuration: configuration)
        await settings.start(configuration: configuration)
        do {
            let archiveSchema = configuration.archiveSchema ?? configuration.schema
            let opened = try await BackgroundWork.run {
                let store = try MessageArchiveStore(
                    connectionString: configuration.connectionString, schema: archiveSchema, keyProvider: keyProvider)
                var sources: [any AIIndexSource] = [
                    try MessageArchiveIndexSource(
                        connectionString: configuration.connectionString, schema: archiveSchema, keyProvider: keyProvider,
                        authorKeys: ["teams": TeamsPerson.archiveAuthorKey])
                ]
                // MailRepository connects in its initializer; keep it off the main actor.
                if mail {
                    sources.append(MailAIIndexSource(repository: MailRepository(configuration: configuration, keyProvider: keyProvider)))
                }
                return (AIArchiveAccessProvider(store: store, contacts: contacts), sources)
            }
            let sources = opened.1
            let vectors = AIVectorStore(keyProvider: keyProvider)
            try await vectors.open(configuration: configuration)
            await worker.attachRetrieval(vectors: vectors, access: opened.0)
            let indexer = AIIndexer(worker: worker, vectors: vectors, sources: sources, access: opened.0)
            access = opened.0
            self.indexer = indexer
            await indexer.start()
            await refreshIndex()
        } catch {
            indexStatus.failure = error as? AIFailure ?? .storage
        }
    }

    func accessEnabled(_ scope: AIAccessScope) async -> Bool? {
        guard let access else { return nil }
        return try? await access.isEnabled(scope)
    }

    func setAccess(_ scope: AIAccessScope, enabled: Bool) async {
        guard let access else { return }
        do {
            try await access.setScope(scope, enabled: enabled)
            accessRevision += 1
            await indexer?.accessChanged()
            await refreshIndex()
        } catch { indexStatus.failure = error as? AIFailure ?? .storage }
    }

    /// Contact flags live in the dossier; the index only needs to re-check.
    func contactAccessChanged() async {
        accessRevision += 1
        await indexer?.accessChanged()
    }

    func refreshIndex() async {
        if let indexer { indexStatus = await indexer.status() }
        if let access { enabledScopes = (try? await access.snapshot().enabledScopes.sorted { "\($0)" < "\($1)" }) ?? [] }
    }

    func pauseIndex(_ paused: Bool) async {
        await indexer?.pause(paused)
        if !paused { await indexer?.accessChanged() }
        await refreshIndex()
    }

    /// The QA preview indexes synchronously so the seeded conversation is searchable at once.
    func indexNow() async {
        _ = try? await indexer?.runOnce()
        await refreshIndex()
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
        case .rejected(let status, let reason):
            reason.isEmpty ? "Провайдер отклонил запрос (\(status))." : "Провайдер отклонил запрос (\(status)): \(reason)"
        case .network: "Соединение с провайдером прервалось."
        case .malformedResponse: "Провайдер вернул ответ в неожиданном формате."
        case .cancelled: "Запрос остановлен."
        case .busy: "Дождитесь окончания текущего ответа или остановите его."
        case .vectorUnavailable: "Поиск по данным недоступен: в PostgreSQL нет расширения pgvector."
        case .dimensionsTooLarge: "Модель эмбеддингов даёт векторы длиннее 2000 — выберите другую модель поиска."
        case .contextTooLarge(let characters, let limit):
            "Слишком много контекста: \(characters) символов при лимите \(limit). Сузьте период или уберите карточку."
        case .contextUnavailable(let reason): reason
        }
    }
}
