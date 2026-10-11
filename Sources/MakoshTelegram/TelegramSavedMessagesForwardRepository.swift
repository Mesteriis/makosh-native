import Foundation
import Postbox
import TelegramCore

struct TelegramSavedMessagesForwardRecord: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let request: TelegramSavedMessagesForwardRequest
    let acceptedIDs: [TelegramForwardQueueID]?
    init(request: TelegramSavedMessagesForwardRequest, acceptedIDs: [TelegramForwardQueueID]? = nil) {
        schemaVersion = 1; self.request = request; self.acceptedIDs = acceptedIDs
    }
    var isValid: Bool {
        schemaVersion == 1 && request.isValid && (acceptedIDs.map(request.draft.validForwardQueueIDs) ?? true)
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
private nonisolated func writeSavedForward(transaction: Transaction, record: TelegramSavedMessagesForwardRecord) -> Bool {
    guard record.isValid, let encoded = try? JSONEncoder().encode(record), encoded.count <= 512 * 1024 - savedForwardMarker.count else { return false }
    transaction.setPreferencesEntry(key: telegramSavedForwardKey(accountID: record.request.accountID), value: PreferencesEntry(data: savedForwardMarker + encoded))
    return true
}
nonisolated func telegramSavedForwardBegin(transaction: Transaction, accountID: Int64, request: TelegramSavedMessagesForwardRequest) -> Bool {
    guard request.accountID == accountID, request.isValid,
          case let .success(current) = telegramSavedForwardRead(transaction: transaction, accountID: accountID),
          current == nil || (current?.acceptedIDs != nil && current?.request.id != request.id) else { return false }
    return writeSavedForward(transaction: transaction, record: .init(request: request))
}
nonisolated func telegramSavedForwardRecordAcceptance(transaction: Transaction, accountID: Int64,
                                                     request: TelegramSavedMessagesForwardRequest, ids: [TelegramForwardQueueID]) -> Bool {
    guard case let .success(current?) = telegramSavedForwardRead(transaction: transaction, accountID: accountID),
          current.request == request, current.acceptedIDs == nil else { return false }
    return writeSavedForward(transaction: transaction, record: .init(request: request, acceptedIDs: ids))
}
/// Called only after an explicit zero-queue refusal, never on cancellation/timeout.
nonisolated func telegramSavedForwardReject(transaction: Transaction, accountID: Int64,
                                           request: TelegramSavedMessagesForwardRequest) -> Bool {
    guard case let .success(current?) = telegramSavedForwardRead(transaction: transaction, accountID: accountID),
          current.request == request, current.acceptedIDs == nil else { return false }
    transaction.setPreferencesEntry(key: telegramSavedForwardKey(accountID: accountID), value: nil)
    return true
}
