import XCTest
import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramCustomEmojiInlineResolverTests: XCTestCase {
    private final class Lease: TelegramMediaLease { func cancel() {} }
    private final class Provider: TelegramCustomEmojiResourceProvider, TelegramCustomEmojiInlineResolverProvider {
        let accountID: Int64
        var requests: [[Int64]] = []
        let results = ValuePipe<[Int64: TelegramCustomEmojiDescriptor]>()
        init(accountID: Int64 = 1) { self.accountID = accountID }
        func resolveDescriptors(fileIDs: [Int64]) -> Signal<[Int64: TelegramCustomEmojiDescriptor], NoError> {
            requests.append(fileIDs); return results.signal()
        }
        func start(descriptor: TelegramCustomEmojiDescriptor,
            receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease { Lease() }
    }
    // Catches resolving history only through the current picker catalog, and
    // accepting documents outside the requested account-scoped set.
    func testHistoryResolutionIsBoundedToRequestedNativeDocumentIDs() throws {
        let provider = Provider(), context = TelegramCustomEmojiPlaybackContext(accountID: 1, provider: provider)
        let fox = try resolverDescriptor(100), bear = try resolverDescriptor(200), unrelated = try resolverDescriptor(300)
        var observed: [[Int64: TelegramCustomEmojiDescriptor]] = []
        let subscription = context.resolveDescriptors(fileIDs: [200,100,100]).start(next: { value in
            MainActor.assumeIsolated { observed.append(value) }
        })
        defer { subscription.dispose() }
        XCTAssertEqual(provider.requests, [[100,200]])
        provider.results.putNext([100: fox, 200: bear, 300: unrelated])
        XCTAssertEqual(observed.last, [100: fox, 200: bear])
        provider.results.putNext([100: unrelated, 200: bear])
        XCTAssertEqual(observed.last, [200: bear], "A dictionary key cannot change native document identity")
    }
    // Catches an old account's native resolution showing images after account
    // invalidation, and allowing a disposed context to start another fetch.
    func testInvalidationRefusesLateResolvedDocumentsAndNewRequests() throws {
        let provider = Provider(), context = TelegramCustomEmojiPlaybackContext(accountID: 1, provider: provider)
        let fox = try resolverDescriptor(100)
        var observed: [[Int64: TelegramCustomEmojiDescriptor]] = []
        let subscription = context.resolveDescriptors(fileIDs: [100]).start(next: { value in
            MainActor.assumeIsolated { observed.append(value) }
        })
        defer { subscription.dispose() }
        guard provider.requests.count == 1 else { XCTFail("Current history must request native metadata"); return }
        provider.results.putNext([100: fox]); XCTAssertEqual(observed.last, [100: fox])
        context.invalidate(); provider.results.putNext([100: fox])
        XCTAssertEqual(observed.last, [:])
        let next = context.resolveDescriptors(fileIDs: [100]).start(next: { value in XCTAssertTrue(value.isEmpty) })
        next.dispose(); XCTAssertEqual(provider.requests.count, 1)
    }
    // Catches cross-account resolution, oversized ID batches, or zero IDs being
    // forwarded into a native metadata request rather than preserving fallback.
    func testMismatchedAccountOversizedAndInvalidIDsNeverReachProvider() {
        let provider = Provider(), mismatch = TelegramCustomEmojiPlaybackContext(accountID: 2, provider: provider)
        let context = TelegramCustomEmojiPlaybackContext(accountID: 1, provider: provider)
        for signal in [mismatch.resolveDescriptors(fileIDs: [100]),
            context.resolveDescriptors(fileIDs: Array(1...1025).map(Int64.init)),
            context.resolveDescriptors(fileIDs: [0]), context.resolveDescriptors(fileIDs: [])] {
            let disposable = signal.start(next: { value in XCTAssertTrue(value.isEmpty) }); disposable.dispose()
        }
        XCTAssertTrue(provider.requests.isEmpty)
    }
}
private nonisolated func resolverDescriptor(_ id: Int64) throws -> TelegramCustomEmojiDescriptor {
    try TelegramCustomEmojiDescriptor(file: TelegramMediaFile(fileId: .init(namespace: Namespaces.Media.CloudFile, id: id),
        partialReference: nil, resource: CloudDocumentMediaResource(datacenterId: 2, fileId: id, accessHash: 53,
            size: 36, fileReference: Data([1,2]), fileName: "synthetic-emoji.webp"),
        previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "image/webp", size: 36,
        attributes: [.CustomEmoji(isPremium: false, isSingleColor: false, alt: "🦊", packReference: nil)], alternativeRepresentations: []))
}
