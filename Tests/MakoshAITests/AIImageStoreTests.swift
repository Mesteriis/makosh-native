import MakoshCore
import XCTest
@testable import MakoshAI

final class AIImageStoreTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testEachImageHasItsOwnRandomKey() async throws {
        let store = AIImageStore(s3: nil, localDirectory: directory()), conversation = UUID()
        let first = try await store.store(Data("A".utf8), conversationID: conversation, toS3: false)
        let second = try await store.store(Data("A".utf8), conversationID: conversation, toS3: false)
        XCTAssertEqual(first.key.count, 32)
        XCTAssertNotEqual(first.key, second.key)
        let loaded = try await store.load(first, conversationID: conversation)
        XCTAssertEqual(loaded, Data("A".utf8))
    }

    /// The development bucket denies DeleteObject (docs/object-storage.md);
    /// forgetting the per-image key is what makes the object unreadable.
    func testS3ImageIsForgottenWithoutDeleteObject() async throws {
        guard let path = ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"] else {
            throw XCTSkip("Set MAKOSH_TEST_S3_CONFIG for an explicitly configured synthetic S3 integration test")
        }
        let configuration = try JSONDecoder().decode(S3ObjectStoreConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let store = AIImageStore(s3: try S3ObjectStore(configuration: configuration), localDirectory: directory())
        let conversation = UUID()
        let reference = try await store.store(Data("PNG".utf8), conversationID: conversation, toS3: true)
        XCTAssertTrue(reference.inS3)
        let loaded = try await store.load(reference, conversationID: conversation)
        XCTAssertEqual(loaded, Data("PNG".utf8))
        try await store.delete(reference, conversationID: conversation)
        let forgotten = AIImageReference(
            objectID: reference.objectID, byteCount: reference.byteCount, sha256: reference.sha256,
            plaintextByteCount: reference.plaintextByteCount, key: Data(repeating: 0, count: 32), inS3: true)
        do {
            _ = try await store.load(forgotten, conversationID: conversation)
            XCTFail("object readable without its key")
        } catch { XCTAssertEqual(error as? AIFailure, .storage) }
    }
}
