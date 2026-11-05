import MakoshAI
import MakoshCore
import SwiftUI

/// Access flags for the index: chat and mailbox flags in the encrypted
/// message archive, contact flags in the dossier.
actor AIArchiveAccessProvider: AIAccessProvider {
    private let store: MessageArchiveStore
    private let contacts: ContactWorkspaceWorker?

    init(store: MessageArchiveStore, contacts: ContactWorkspaceWorker?) {
        self.store = store
        self.contacts = contacts
    }

    func snapshot() async throws -> AIAccessSnapshot {
        let scopes = Set(try store.enabledAIScopes())
        var access: [ServiceIdentity: AIContactAccess] = [:]
        if let contacts {
            for contact in try await contacts.snapshot().contacts where contact.aiAccess != .inherit {
                // An identity shared by several cards stays forbidden if any card forbids it.
                for identity in contact.identities where access[identity] != .forbidden { access[identity] = contact.aiAccess }
            }
        }
        return AIAccessSnapshot(enabledScopes: scopes, contactAccess: access)
    }

    func setScope(_ scope: AIAccessScope, enabled: Bool) async throws { try store.setAIAccess(scope, enabled: enabled) }
    func isEnabled(_ scope: AIAccessScope) throws -> Bool { try store.aiAccessEnabled(scope) }
}

private let aiAccessExplanation =
    "Открывает переписку для фонового поиска ИИ: сообщения отсюда могут уходить провайдеру модели. Явно прикреплённый в панели ИИ чат отправляется и без этого флага."

/// «Доступно для ИИ» for one chat or mailbox, as a form toggle.
struct AIAccessToggle: View {
    @EnvironmentObject private var ai: AIHost
    let scope: AIAccessScope
    var title = "Доступно для ИИ"
    @State private var enabled: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: Binding(get: { enabled ?? false }, set: { value in set(value) }))
                .disabled(enabled == nil)
                .accessibilityIdentifier("ai.access.toggle")
            Text(enabled == nil ? "ИИ ещё не подключён в этом окне." : aiAccessExplanation).font(.caption).foregroundStyle(.secondary)
        }
        .task(id: ai.accessRevision) { enabled = await ai.accessEnabled(scope) }
    }

    private func set(_ value: Bool) {
        enabled = value
        Task {
            await ai.setAccess(scope, enabled: value)
            enabled = await ai.accessEnabled(scope)
        }
    }
}

/// The same flag inside a dropdown menu (Telegram chat header, mail actions).
struct AIAccessMenuToggle: View {
    @EnvironmentObject private var ai: AIHost
    let scope: AIAccessScope
    let title: String
    @State private var enabled: Bool?

    var body: some View {
        MakoshDropdownToggle(
            title,
            isOn: Binding(
                get: { enabled ?? false },
                set: { value in
                    enabled = value
                    Task {
                        await ai.setAccess(scope, enabled: value)
                        enabled = await ai.accessEnabled(scope)
                    }
                })
        )
        .disabled(enabled == nil)
        .help(aiAccessExplanation)
        .accessibilityIdentifier("ai.access.menuToggle")
        .task(id: ai.accessRevision) { enabled = await ai.accessEnabled(scope) }
    }
}
