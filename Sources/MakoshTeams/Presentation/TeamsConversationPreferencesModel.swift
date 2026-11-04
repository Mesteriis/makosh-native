import Combine
import Foundation

@MainActor package final class TeamsConversationPreferencesModel: ObservableObject {
    @Published package var rule = TeamsNotificationRule()
    @Published package var savingFiles = false
    @Published package private(set) var rulesLoaded = false
    @Published package private(set) var filesLoaded = false
    @Published package private(set) var busy = false
    @Published package private(set) var notice: String?
    private let worker: any TeamsServing
    private var scope: TeamsScope?
    private var generation: UInt64 = 0
    package var canSave: Bool { rulesLoaded && filesLoaded && !busy }
    package init(worker: any TeamsServing) { self.worker = worker }
    package func reset(_ scope: TeamsScope) {
        generation &+= 1; self.scope = scope
        rule = .init(); savingFiles = false; rulesLoaded = false; filesLoaded = false; busy = false; notice = nil
    }
    package func load(expectedScope: TeamsScope) async {
        guard scope == expectedScope else { return }
        let token = generation; busy = true
        defer { if token == generation { busy = false } }
        do {
            let rule = try await worker.savedNotificationRule(scope: .conversation(expectedScope))
            guard generation == token, !Task.isCancelled else { return }
            self.rule = rule; rulesLoaded = true
            let saving = try await worker.savingFiles(scope: expectedScope)
            guard generation == token, !Task.isCancelled else { return }
            savingFiles = saving; filesLoaded = true
        } catch { if generation == token { notice = "Не удалось загрузить все настройки этой беседы." } }
    }
    package func save(expectedScope: TeamsScope) async {
        guard scope == expectedScope, canSave else { return }
        let token = generation, capturedRule = rule, saving = savingFiles
        busy = true; defer { if generation == token { busy = false } }
        do {
            try await worker.setNotificationRule(capturedRule, scope: .conversation(expectedScope))
            guard generation == token, !Task.isCancelled else { return }
            try await worker.setSavingFiles(scope: expectedScope, enabled: saving)
            guard generation == token, !Task.isCancelled else { return }
            notice = "Настройки сохранены"
        } catch { if generation == token { notice = "Не все настройки сохранены. Проверьте уведомления и S3 перед повторным сохранением." } }
    }
}
