import Foundation
import Postbox
import TelegramCore

struct TelegramSavedMessagesForwardRecord: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let request: TelegramSavedMessagesForwardRequest
    let acceptedIDs: [TelegramForwardQueueID]?
    init(request: TelegramSavedMessagesForwardRequest, acceptedIDs: [TelegramForwardQueueID]? = nil) {
        schemaVersion = request.origin?.threadID == nil ? 1 : 2; self.request = request; self.acceptedIDs = acceptedIDs
    }
    var isValid: Bool {
        schemaVersion == (request.origin?.threadID == nil ? 1 : 2) && request.isValid && (acceptedIDs.map(request.draft.validForwardQueueIDs) ?? true)
    }
}
private let savedForwardMarker = Data("Makosh.SavedForward.JSON.v1\n".utf8)
nonisolated func telegramSavedForwardKey(accountID: Int64) -> ValueBoxKey {
    let namespace = Data("Makosh.SavedForward.Preference.v1\0".utf8)
    let key = ValueBoxKey(length: namespace.count + 8)
    key.setData(0, value: namespace); key.setInt64(namespace.count, value: accountID)
    return key
}
nonisolated func telegramSavedForwardRead(transaction: Transaction, accountID: Int64) -> Result<TelegramSavedMessagesForwardRecord?, TelegramComposerDraftPersistenceError> {
    guard let entry = transaction.getPreferencesEntry(key: telegramSavedForwardKey(accountID: accountID)) else { return .success(nil) }
    guard entry.data.count <= 512 * 1024, entry.data.starts(with: savedForwardMarker),
          let record = try? JSONDecoder().decode(TelegramSavedMessagesForwardRecord.self, from: entry.data.dropFirst(savedForwardMarker.count)),
          record.isValid, record.request.accountID == accountID else { return .failure(.incompatibleData) }
    return .success(record)
}
private nonisolated func savedForwardEntry(_ record: TelegramSavedMessagesForwardRecord) -> PreferencesEntry? {
    guard record.isValid, let encoded = try? JSONEncoder().encode(record), encoded.count <= 512 * 1024 - savedForwardMarker.count else { return nil }
    return PreferencesEntry(data: savedForwardMarker + encoded)
}
private nonisolated func writeSavedForward(transaction: Transaction, record: TelegramSavedMessagesForwardRecord) -> Bool {
    guard let entry = savedForwardEntry(record) else { return false }
    transaction.setPreferencesEntry(key: telegramSavedForwardKey(accountID: record.request.accountID), value: entry)
    return true
}
private nonisolated func savedForwardOriginRemoval(transaction: Transaction, request: TelegramSavedMessagesForwardRequest) -> (key: ValueBoxKey, entry: PreferencesEntry)? {
    guard let origin = request.origin else { return nil }
    return telegramPreparedForwardRemoval(transaction: transaction, accountID: request.accountID, chatID: origin.chatID,
        threadID: origin.threadID, revision: origin.revision, intentID: origin.intentID, sources: request.sources)
}
nonisolated func telegramSavedForwardOriginIsCurrent(transaction: Transaction, request: TelegramSavedMessagesForwardRequest) -> Bool {
    request.origin == nil || savedForwardOriginRemoval(transaction: transaction, request: request) != nil
}
nonisolated func telegramSavedForwardBegin(transaction: Transaction, accountID: Int64, request: TelegramSavedMessagesForwardRequest) -> Bool {
    guard request.accountID == accountID, request.isValid,
          telegramSavedForwardOriginIsCurrent(transaction: transaction, request: request),
          case let .success(current) = telegramSavedForwardRead(transaction: transaction, accountID: accountID),
          current == nil || (current?.acceptedIDs != nil && current?.request.id != request.id) else { return false }
    return writeSavedForward(transaction: transaction, record: .init(request: request))
}
nonisolated func telegramSavedForwardRecordAcceptance(transaction: Transaction, accountID: Int64,
                                                     request: TelegramSavedMessagesForwardRequest, ids: [TelegramForwardQueueID]) -> Bool {
    guard case let .success(current?) = telegramSavedForwardRead(transaction: transaction, accountID: accountID),
          current.request == request, current.acceptedIDs == nil else { return false }
    guard let entry = savedForwardEntry(.init(request: request, acceptedIDs: ids)) else { return false }
    let originRemoval = savedForwardOriginRemoval(transaction: transaction, request: request)
    guard request.origin == nil || originRemoval != nil else { return false }
    // Prepare every payload before writing either preference. Both mutations
    // are committed by the native enqueue transaction alongside the messages.
    transaction.setPreferencesEntry(key: telegramSavedForwardKey(accountID: accountID), value: entry)
    if let originRemoval { transaction.setPreferencesEntry(key: originRemoval.key, value: originRemoval.entry) }
    return true
}
/// Called only after an explicit zero-queue refusal, never on cancellation/timeout.
nonisolated func telegramSavedForwardReject(transaction: Transaction, accountID: Int64,
                                           request: TelegramSavedMessagesForwardRequest) -> Bool {
    guard case let .success(current?) = telegramSavedForwardRead(transaction: transaction, accountID: accountID),
          current.request == request, current.acceptedIDs == nil else { return false }
    transaction.setPreferencesEntry(key: telegramSavedForwardKey(accountID: accountID), value: nil)
    return true
}
