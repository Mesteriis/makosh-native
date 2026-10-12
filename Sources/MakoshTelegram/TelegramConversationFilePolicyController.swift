import Foundation
import Combine
import MakoshCore
import Postbox
import TelegramCore

@MainActor public final class TelegramConversationFilePolicyController: ObservableObject {
    public struct Context: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let accountID: Int64
        public let chatID: Int64
        var identity: MessageArchiveIdentity {
            .init(service: "telegram", accountID: String(accountID), conversationID: String(chatID), messageID: "file-policy")
        }
    }
    @Published public private(set) var context: Context?
    @Published public private(set) var enabled: Bool?
    @Published public private(set) var isBusy = false
    @Published public private(set) var error: String?
    private let repository: () throws -> ArchiveFileRepository
    init(repository: @escaping () throws -> ArchiveFileRepository) { self.repository = repository }
    public func select(accountID: Int64?, chatID: Int64?) {
        context = accountID.flatMap { account in chatID.map { Context(id: UUID(), accountID: account, chatID: $0) } }
        enabled = nil; error = nil; isBusy = context != nil
        guard let captured = context else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await self.repository().conversationFileSavingEnabled(identity: captured.identity,
                    defaultEnabled: Self.defaultEnabled(identity: captured.identity))
                guard self.context == captured else { return }
                self.enabled = value; self.isBusy = false
            } catch {
                guard self.context == captured else { return }
                self.isBusy = false; self.error = "Не удалось прочитать настройку сохранения файлов. Повторите загрузку настройки."
            }
        }
    }
    public func reload(contextID: UUID) {
        guard let context, context.id == contextID, !isBusy else { return }
        select(accountID: context.accountID, chatID: context.chatID)
    }
    public func setEnabled(_ enabled: Bool, contextID: UUID) async -> Bool {
        guard let captured = context, captured.id == contextID, !isBusy, self.enabled != nil else { return false }
        if self.enabled == enabled { return true }
        isBusy = true; error = nil
        do {
            let repository = try repository()
            try await repository.setConversationFileSavingEnabled(identity: captured.identity, enabled: enabled)
            let confirmed = try await repository.conversationFileSavingEnabled(identity: captured.identity,
                defaultEnabled: Self.defaultEnabled(identity: captured.identity))
            guard confirmed == enabled else { throw MessageArchiveError.integrity }
            if context == captured { self.enabled = confirmed; isBusy = false }
            return true
        } catch {
            if context == captured {
                self.enabled = nil; isBusy = false
                self.error = "Не удалось подтвердить настройку. Загрузите её повторно перед изменением."
            }
            return false
        }
    }
    nonisolated static func defaultEnabled(identity: MessageArchiveIdentity) -> Bool {
        guard identity.service == "telegram", let peerID = Int64(identity.conversationID), peerID > 0 else { return false }
        return PeerId(peerID).namespace == Namespaces.Peer.CloudUser
    }
    nonisolated static func legacyDefault(identity: MessageArchiveIdentity) -> Bool? {
        // Untagged receipts, including old preparations, follow the chat policy.
        // A preparation-shaped message ID grants no exemption.
        guard identity.service == "telegram", Int64(identity.conversationID) != nil else { return nil }
        return defaultEnabled(identity: identity)
    }
}
