import Combine
import Foundation
import MakoshTeams

@MainActor final class TeamsComposerModel: ObservableObject {
    @Published var text = "" { didSet { revision = UUID() } }
    @Published var attachments: [TeamsPreparedFile] = [] { didSet { revision = UUID(); accessPlan = nil } }
    @Published private(set) var accessPlan: TeamsFileAccessPlan?
    @Published private(set) var sending = false
    @Published private(set) var preparing = false
    @Published private(set) var reviewing = false
    @Published private(set) var outbox: [TeamsOutgoing] = []
    @Published private(set) var outboxBusy = false
    @Published private(set) var outboxHasMore = false
    @Published var error: String?
    @Published private(set) var notice: String?
    private let worker: any TeamsServing
    private let synthetic: Bool
    private var scope: TeamsScope?
    private var generation: UInt64 = 0
    private var revision = UUID()
    private struct Draft { var text: String; var files: [TeamsPreparedFile]; var revision: UUID }
    private var drafts: [TeamsScope: Draft] = [:]
    private var pending = Set<TeamsScope>()
    private var outboxCursor: TeamsOutgoingCursor?
    var isSynthetic: Bool { synthetic }
    var canSend: Bool { !sending && !preparing && !reviewing && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) && (attachments.isEmpty || accessPlan != nil) }
    init(worker: any TeamsServing, synthetic: Bool) { self.worker = worker; self.synthetic = synthetic }
    func setContext(_ scope: TeamsScope?) {
        guard scope != self.scope else { return }
        if let previous = self.scope { drafts[previous] = Draft(text: text, files: attachments, revision: revision) }
        generation &+= 1; self.scope = scope
        let saved = scope.flatMap { drafts[$0] }
        text = saved?.text ?? ""; attachments = saved?.files ?? []; revision = saved?.revision ?? UUID(); accessPlan = nil
        sending = scope.map { pending.contains($0) } ?? false; preparing = false; reviewing = false
        outbox = []; outboxCursor = nil; outboxHasMore = false; outboxBusy = false; error = nil; notice = nil
    }
    func attach(_ files: [URL]) async {
        guard let source = scope, !preparing, attachments.count + files.count <= 10, !files.isEmpty else { error = "Можно подготовить до десяти файлов."; return }
        let token = generation; preparing = true
        defer { if token == generation { preparing = false } }
        do {
            let prepared = try await worker.prepareFiles(scope: source, files: files)
            guard generation == token, scope == source else {
                var saved = drafts[source] ?? Draft(text: "", files: [], revision: UUID())
                let known = Set(saved.files.map(\.id)); saved.files += prepared.filter { !known.contains($0.id) }
                saved.revision = UUID(); drafts[source] = saved
                return
            }
            attachments += prepared
        } catch { if generation == token { self.error = teamsFailureMessage(error) } }
    }
    func reviewFiles(destination: TeamsFileDestination) async {
        guard let source = scope, !attachments.isEmpty, !reviewing else { return }
        let token = generation, ids = attachments.map(\.id); reviewing = true; accessPlan = nil
        defer { if token == generation { reviewing = false } }
        do {
            let plan = try await worker.fileAccessPlan(scope: source, fileIDs: ids, destination: destination)
            guard token == generation, scope == source, attachments.map(\.id) == ids else { return }
            accessPlan = plan
        } catch { if generation == token { self.error = teamsFailureMessage(error) } }
    }
    func send() async {
        guard let source = scope, canSend, !pending.contains(source) else { return }
        let content = TeamsDraft(text: text, fileIDs: attachments.map(\.id)), plan = accessPlan
        let token = generation, version = revision
        pending.insert(source); sending = true; error = nil; notice = nil
        defer { pending.remove(source); sending = scope.map { pending.contains($0) } ?? false }
        do {
            let result: TeamsOutgoing
            if let plan { result = try await worker.sendFiles(scope: source, content: content, accessPlan: plan) }
            else { result = try await worker.send(scope: source, content: content) }
            if result.state == .accepted || result.state == .unknown {
                if scope == source, revision == version { text = ""; attachments = []; drafts[source] = nil }
                else if scope != source, drafts[source]?.revision == version { drafts[source] = nil }
            }
            guard token == generation, scope == source else { return }
            accessPlan = nil
            switch result.state {
            case .accepted: notice = synthetic ? "Синтетическая проверка: в Microsoft ничего не отправлялось." : "Сообщение принято сервисом."
            case .notSent: notice = "Не отправлено. Черновик сохранён; причина и попытка доступны в исходящих."
            case .unknown: notice = "Результат неизвестен. Проверьте исходящие перед повторной отправкой."
            case .prepared: notice = "Сообщение подготовлено. Отправка ещё не подтверждена."
            case .dispatching: notice = "Отправка выполняется. Подтверждение ещё не получено."
            }
            await loadOutbox(reset: true)
        } catch { if token == generation { self.error = teamsFailureMessage(error) } }
    }
    func loadOutbox(reset: Bool) async {
        guard let source = scope, !outboxBusy, reset || outboxHasMore else { return }
        let token = generation; outboxBusy = true
        defer { if token == generation { outboxBusy = false } }
        do {
            let page = try await worker.outgoingPage(accountID: source.accountID, before: reset ? nil : outboxCursor)
            guard token == generation, scope == source else { return }
            outbox = reset ? page.values : outbox + page.values; outboxCursor = page.next; outboxHasMore = page.next != nil
        } catch { if token == generation { self.error = teamsFailureMessage(error) } }
    }
    func resolve(_ outgoing: TeamsOutgoing, sent: Bool) async {
        guard let source = scope, outgoing.scope.accountID == source.accountID else { return }
        let token = generation
        do {
            _ = try await worker.resolveOutgoing(accountID: source.accountID, id: outgoing.id, sent: sent)
            guard token == generation else { return }; await loadOutbox(reset: true)
        } catch { if token == generation { self.error = teamsFailureMessage(error) } }
    }
    func resume(_ outgoing: TeamsOutgoing) async {
        guard let source = scope, outgoing.scope.accountID == source.accountID, outgoing.state == .prepared else { return }
        let token = generation
        do {
            _ = try await worker.resumeOutgoing(accountID: source.accountID, id: outgoing.id)
            guard token == generation else { return }; await loadOutbox(reset: true)
        } catch { if token == generation { self.error = teamsFailureMessage(error) } }
    }
    func copy(_ outgoing: TeamsOutgoing) async {
        guard let source = scope, outgoing.scope.accountID == source.accountID, outgoing.state == .notSent, outgoing.fileSubmission == nil else { return }
        let token = generation
        do {
            _ = try await worker.copyOutgoing(accountID: source.accountID, id: outgoing.id)
            guard token == generation else { return }; await loadOutbox(reset: true)
        } catch { if token == generation { self.error = teamsFailureMessage(error) } }
    }
}

func teamsFailureMessage(_ error: any Error) -> String {
    guard let failure = error as? TeamsFailure else { return error is CancellationError ? "Операция отменена." : "Не удалось завершить операцию Teams." }
    switch failure {
    case .forbidden: return "Недостаточно прав. Предоставьте нужное разрешение для этого аккаунта."
    case .signInRequired, .unauthorized: return "Нужно заново войти в этот аккаунт Teams."
    case .invalidConfiguration: return "Проверьте регистрацию приложения Entra и настройку локального хранилища."
    case .principalChanged: return "Microsoft вернул другой аккаунт. Создайте для него отдельное подключение."
    case .uncertainSubmission: return "Результат отправки неизвестен. Проверьте исходящие; повтор автоматически запрещён."
    case .incompleteRoster, .rosterChanged: return "Не удалось подтвердить всех получателей файла. Обновите план доступа."
    case .incompleteGrant: return "Не удалось доказать полный состав доступа. Выберите подходящую личную папку OneDrive."
    case .historicalFileUnavailable: return "Эта версия файла не была сохранена и больше недоступна. Текущий файл не подставлен."
    case .operationBusy: return "Действие уже выполняется в другом окне. Дождитесь завершения."
    case .storage, .keyUnavailable, .credentialStorage: return "Хранилище или ключ недоступны. Существующие данные и сеанс сохранены."
    case .throttled: return "Microsoft ограничил частоту запросов. Сервис выдерживает указанную паузу."
    case .authorizationDenied, .authorizationExpired: return "Вход отклонён или срок подтверждения истёк."
    default: return "Не удалось завершить операцию Teams. Проверьте соединение и разрешения."
    }
}
