import Foundation
import SwiftSignalKit

public struct TelegramServerDraftConflict: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let localText: String
    public let remoteText: String
    let update: TelegramServerDraftUpdate
    let context: TelegramServerDraftObservationContext
}

@MainActor protocol TelegramServerDraftResolving: AnyObject {
    var accountID: Int64 { get }
    func resolve(update: TelegramServerDraftUpdate, local: TelegramComposerDraft?, choice: TelegramServerDraftChoice,
        completion: @escaping @MainActor (Result<TelegramComposerDraft, TelegramComposerDraftPersistenceError>) -> Void) -> Disposable
}
