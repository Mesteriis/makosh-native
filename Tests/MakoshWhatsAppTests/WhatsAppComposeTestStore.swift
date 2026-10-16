import Foundation

@testable import MakoshWhatsApp

/// Test-only replacement for SQL, used by suspended presentation boundary tests.
actor WhatsAppComposeTestStore {
  private struct Key: Hashable {
    let account: UUID
    let chat: Data
  }
  private var values: [Key: WhatsAppComposeDraft] = [:]
  func read(account: UUID, chat: String) -> WhatsAppComposeDraft? {
    values[.init(account: account, chat: Data(chat.utf8))]
  }
  func save(_ input: WhatsAppComposeDraft, expected: UInt64?) throws -> WhatsAppComposeDraft {
    let key = Key(account: input.accountID, chat: Data(input.chat.utf8))
    guard values[key]?.revision == expected, input.revision == (expected ?? 0) else {
      throw WhatsAppFailure.invalid
    }
    var draft = input
    draft.revision += 1
    values[key] = draft
    return draft
  }
}
