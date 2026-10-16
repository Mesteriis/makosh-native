import MakoshCore
import XCTest

@testable import MakoshWhatsApp

final class WhatsAppOutgoingFilesTests: XCTestCase {
  func testClaimBindsOriginalPreparationsBeforeProtocolDispatchAndReopen() async throws {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else {
      throw XCTSkip("PG required")
    }
    let schema =
      "qa_whatsapp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let config = ContactWorkspaceConfiguration(connectionString: connection, schema: schema)
    let keys: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x78, count: 32) }
    let repo = WhatsAppRepository(configuration: config, keyProvider: keys)
    let account = WhatsAppAccount(name: "Files")
    let file = UUID()
    try await repo.saveAccount(account)
    let draft = try await repo.prepareOutgoing(
      accountID: account.id, chat: "peer@lid", content: .init(text: "caption", files: [file]))
    let claimed = try await repo.claimOutgoing(id: draft.id, accountID: account.id)
    let attempt = try XCTUnwrap(claimed.attemptID)
    let stanza = "MK" + attempt.uuidString.replacingOccurrences(of: "-", with: "").uppercased()
    let reopened = WhatsAppRepository(configuration: config, keyProvider: keys)
    let values = try await reopened.outgoingFileIDs(
      accountID: account.id, chat: "peer@lid", stanza: stanza)
    XCTAssertEqual(values, [file])
    let other = try await reopened.outgoingFileIDs(
      accountID: account.id, chat: "another@lid", stanza: stanza)
    XCTAssertTrue(other.isEmpty)
    try await repo.settleOutgoing(
      id: draft.id, accountID: account.id, attemptID: attempt, outcome: .unknown)
    let retained = try await reopened.outgoingFileIDs(
      accountID: account.id, chat: "peer@lid", stanza: stanza)
    XCTAssertEqual(retained, [file])
  }
}
