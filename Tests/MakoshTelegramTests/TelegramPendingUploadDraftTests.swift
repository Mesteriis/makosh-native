import XCTest
import Foundation
import MakoshCore
@testable import MakoshTelegram

// Real envelope receipt, synthetic bytes only; no S3 or account access.
func pendingUploadFixture(accountID: Int64 = 1, chatID: Int64 = 42, id: UUID = UUID(), revision: UUID = UUID(),
                          disposition: TelegramPendingUploadDisposition = .prepared) throws -> TelegramPendingUploadDraft {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source")
    try Data("Synthetic 😀".utf8).write(to: source)
    let objectID = UUID()
    let capture = try ArchiveFileCapture(file: source, byteCount: Int64(Data("Synthetic 😀".utf8).count))
    let receipt = try capture.seal(to: directory.appendingPathComponent("sealed"), key: Data(repeating: 7, count: 32), objectID: objectID)
    let record = ArchiveFileRecord(id: objectID,
        identity: TelegramPendingUploadDraft.archiveIdentity(accountID: accountID, chatID: chatID, preparationID: id),
        attachment: .init(id: "prepared", kind: "file", name: "synthetic.txt", size: receipt.plaintextByteCount),
        objectKey: "vaults/synthetic/files/" + objectID.uuidString.lowercased(), storageID: String(repeating: "a", count: 64),
        receipt: receipt, capturedAt: Date(timeIntervalSince1970: 100), state: .stored)
    let input = try TelegramComposerInput(formattedText: TelegramFormattedText(text: " e\u{301} 😀\n", entities: [.init(offset: 1, length: 2, kind: .bold)]),
        selection: .init(location: 4, length: 2))
    return TelegramPendingUploadDraft(id: id, revision: revision, accountID: accountID, chatID: chatID,
        title: "Synthetic", captionInput: input,
        originalDraft: .init(accountID: accountID, chatID: chatID, input: input), replyTarget: nil,
        file: record, disposition: disposition)
}
func pendingUploadMutating(_ value: TelegramPendingUploadDraft, _ mutate: (inout [String: Any]) -> Void) throws -> TelegramPendingUploadDraft {
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    mutate(&json)
    return try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: json))
}

final class TelegramPendingUploadDraftTests: XCTestCase {
    func testExactRoundtripAndOwnedIdentityNotNativeMessageIdentity() throws {
        let draft = try pendingUploadFixture()
        XCTAssertTrue(draft.isValid)
        XCTAssertEqual(try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONEncoder().encode(draft)), draft)
        XCTAssertEqual(draft.file.identity.messageID, "pending-upload:" + draft.id.uuidString.lowercased())
        XCTAssertEqual(draft.file.identity.service, "telegram")
        XCTAssertEqual(draft.file.attachment.id, "prepared")
        let noOriginal = TelegramPendingUploadDraft(id: draft.id, accountID: 1, chatID: 42, title: draft.title,
            captionInput: draft.captionInput, originalDraft: nil, replyTarget: nil, file: draft.file)
        XCTAssertTrue(noOriginal.isValid)
    }
    func testUnknownSchemaForeignScopeUnstoredAndUnsafeMetadataFailClosed() throws {
        let draft = try pendingUploadFixture()
        for mutation: (inout [String: Any]) -> Void in [
            { $0["schemaVersion"] = 4 }, { $0["accountID"] = 99 }, { $0["chatID"] = 99 },
            { $0["title"] = String(repeating: "x", count: 4097) },
            { var file = $0["file"] as! [String: Any]; file["state"] = "pending"; $0["file"] = file },
            { var file = $0["file"] as! [String: Any]; file["sha256"] = "invalid"; $0["file"] = file },
            { var file = $0["file"] as! [String: Any]; var attachment = file["attachment"] as! [String: Any]; attachment["name"] = "../secret"; file["attachment"] = attachment; $0["file"] = file }
        ] { XCTAssertFalse(try pendingUploadMutating(draft, mutation).isValid) }
        let accepted = try pendingUploadFixture(disposition: .accepted(localMessageID: "synthetic-local:1"))
        XCTAssertTrue(accepted.isValid)
        XCTAssertFalse(try pendingUploadFixture(disposition: .accepted(localMessageID: "")).isValid)
    }
    func testPendingAttachmentCannotConsumeAnUnsentForwardDraft() throws {
        let pending = try pendingUploadFixture()
        let intent = TelegramComposerForwardIntent(sources: [.init(chatID: 7, peerID: 7, namespace: 0, messageID: 1, fingerprint: "source")])
        let original = TelegramComposerDraft(accountID: pending.accountID, chatID: pending.chatID, input: pending.captionInput, forwardIntent: intent)
        XCTAssertTrue(original.isValid)
        let combined = TelegramPendingUploadDraft(id: pending.id, accountID: pending.accountID, chatID: pending.chatID,
            title: pending.title, captionInput: pending.captionInput, originalDraft: original,
            replyTarget: nil, file: pending.file)
        XCTAssertFalse(combined.isValid, "An upload-only ACK must never discard a staged forward")
    }
}
