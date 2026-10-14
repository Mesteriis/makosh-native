import Foundation
import XCTest
@testable import MakoshTelegram

#if DEBUG
@MainActor
final class TelegramMediaIntegrationTests: XCTestCase {
    private enum WaitFailure: Error { case deadline }

    private final class Lease: TelegramMediaLease {
        var cancellations = 0
        func cancel() { cancellations += 1 }
    }

    private final class SpyProvider: TelegramMediaProvider {
        struct Request {
            let id: String
            let purpose: TelegramMediaPurpose
            let receive: @MainActor (TelegramMediaEvent) -> Void
            let lease: Lease
        }
        var requests: [Request] = []
        func start(attachmentID: String, purpose: TelegramMediaPurpose,
                   receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
            let lease = Lease()
            requests.append(Request(id: attachmentID, purpose: purpose, receive: receive, lease: lease))
            return lease
        }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Synthetic operation did not finish within two seconds")
                throw WaitFailure.deadline
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func selectedModel() throws -> TelegramModel {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = try XCTUnwrap(model.chats.first).id
        return model
    }

    private func attachment(_ number: Int, in messages: [TelegramMessage]) throws -> TelegramAttachment {
        let message = try XCTUnwrap(messages.first { $0.id.hasSuffix(":\(number)") })
        return try XCTUnwrap(message.attachments.first)
    }

    private func refresh(_ model: TelegramModel, messages: [TelegramMessage]) throws {
        model.receiveMessages(messages, requestID: try XCTUnwrap(model.historyWindowID),
            previous: nil, next: nil, isLoading: false)
    }

    func testProjectionDoesNotFetchAndReplacementKeepsManualOriginalWhileInvalidatingPreview() throws {
        let model = try selectedModel()
        let provider = SpyProvider()
        model.media.bind(provider: provider)
        try refresh(model, messages: model.messages)
        XCTAssertTrue(provider.requests.isEmpty)
        let original = try attachment(130, in: model.messages)
        let oldKey = TelegramMediaKey(attachmentID: original.id, purpose: .full)
        let previewKey = TelegramMediaKey(attachmentID:original.id,purpose:.preview)
        model.media.start(original,purpose:.preview)
        model.media.start(original, purpose: .full)
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertEqual(provider.requests.map(\.id),[original.id,original.id])

        var changed = model.messages
        let index = try XCTUnwrap(changed.firstIndex { $0.id.hasSuffix(":130") })
        let replacement = TelegramAttachment(id: original.id + ":new-resource", kind: original.kind,
            name: original.name, byteCount: original.byteCount, mimeType: original.mimeType,
            hasPreview: original.hasPreview, canDownload: original.canDownload)
        changed[index].attachments = [replacement]
        try refresh(model, messages: changed)
        XCTAssertEqual(provider.requests.map { $0.lease.cancellations },[1,0])
        XCTAssertEqual(model.media.phase(for:previewKey),.idle)
        XCTAssertEqual(model.media.phase(for: oldKey), .downloading(nil))
        XCTAssertEqual(provider.requests.count, 2, "Replacement projection must not auto-fetch")
        provider.requests[0].receive(.data(URL(fileURLWithPath: "/synthetic/obsolete"), offset: 0, size: 1, complete: true))
        XCTAssertNil(model.media.downloadedFile(for:previewKey))
        provider.requests[1].receive(.data(URL(fileURLWithPath:"/synthetic/manual-original"),offset:0,size:1,complete:true))
        XCTAssertEqual(model.media.downloadedFile(for:oldKey)?.lastPathComponent,"manual-original")
        XCTAssertEqual(model.media.phase(for: oldKey), .ready)

        let newKey = TelegramMediaKey(attachmentID: replacement.id, purpose: .full)
        model.media.start(replacement, purpose: .full)
        XCTAssertEqual(provider.requests.count, 3)
        provider.requests[0].receive(.failed)
        provider.requests[1].receive(.failed)
        XCTAssertEqual(model.media.phase(for: newKey), .downloading(nil))
        provider.requests[2].receive(.data(URL(fileURLWithPath: "/synthetic/current"), offset: 0, size: 1, complete: true))
        XCTAssertEqual(model.media.phase(for: newKey), .ready)
        model.media.bind(provider:nil)
        XCTAssertEqual(provider.requests.map { $0.lease.cancellations },[1,1,1])
        provider.requests[1].receive(.data(URL(fileURLWithPath:"/synthetic/stale-account"),offset:0,size:1,complete:true))
        XCTAssertEqual(model.media.phase(for:oldKey),.idle)
        XCTAssertEqual(model.media.phase(for:newKey),.idle)
    }

    func testSearchRetainsReadyAttachmentAcrossHistoryPageAndFailedSearchPage() async throws {
        let model = try selectedModel()
        let provider = SpyProvider()
        model.media.bind(provider: provider)
        // Search's actual completion refreshes retain without replacing history's paging cursor.
        model.search.messageQuery = "Тестовое сообщение"
        try await eventually { model.search.messageStatus == .ready }
        XCTAssertTrue(provider.requests.isEmpty)
        let originalResults = model.search.messages
        XCTAssertEqual(originalResults.count, 50)
        let item = try attachment(130, in: originalResults)
        let key = TelegramMediaKey(attachmentID: item.id, purpose: .full)
        let local = URL(fileURLWithPath: "/synthetic/search-retained")
        model.media.start(item, purpose: .full)
        provider.requests[0].receive(.data(local, offset: 0, size: 4, complete: true))
        model.loadOlderMessages()
        XCTAssertFalse(model.messages.flatMap(\.attachments).contains { $0.id == item.id })
        XCTAssertTrue(model.search.messages.flatMap(\.attachments).contains { $0.id == item.id })
        XCTAssertEqual(model.media.phase(for: key), .ready)
        XCTAssertEqual(provider.requests[0].lease.cancellations, 0)

        model.search.failNextSyntheticMessageSearch()
        model.search.loadMoreMessages()
        try await eventually { model.search.messageStatus == .failed }
        XCTAssertEqual(model.search.messages, originalResults)
        XCTAssertEqual(model.search.totalMessages, 130)
        XCTAssertTrue(model.search.canRetryMessages)
        XCTAssertEqual(model.media.downloadedFile(for: key), local)
        XCTAssertEqual(provider.requests[0].lease.cancellations, 0)
        model.search.retryMessages()
        try await eventually { model.search.messageStatus == .ready }
        // Exactly 100 demonstrates retry used the last successful cursor, not failed offset 100.
        XCTAssertEqual(model.search.messages.count, 100)
        XCTAssertEqual(Array(model.search.messages.prefix(50)), originalResults)
        XCTAssertEqual(model.media.phase(for: key), .ready)
        XCTAssertEqual(provider.requests.count, 1)
    }

    func testDifferentAttachmentsCancelIndependentlyAndAccountDisconnectRejectsLateCallbacks() throws {
        let model = try selectedModel()
        let provider = SpyProvider()
        model.media.bind(provider: provider)
        try refresh(model, messages: model.messages)
        let first = try attachment(129, in: model.messages)
        let second = try attachment(130, in: model.messages)
        let firstKey = TelegramMediaKey(attachmentID: first.id, purpose: .full)
        let secondKey = TelegramMediaKey(attachmentID: second.id, purpose: .full)
        model.media.start(first, purpose: .full)
        model.media.start(second, purpose: .full)
        XCTAssertEqual(provider.requests.map(\.id), [first.id, second.id])
        model.media.cancel(firstKey)
        XCTAssertEqual(provider.requests.map { $0.lease.cancellations }, [1, 0])
        provider.requests[0].receive(.data(URL(fileURLWithPath: "/synthetic/cancelled"), offset: 0, size: 1, complete: true))
        XCTAssertEqual(model.media.phase(for: firstKey), .cancelled)
        XCTAssertEqual(model.media.phase(for: secondKey), .downloading(nil))
        let nextChat = try XCTUnwrap(model.chats.first { $0.id != model.selectedChatID })
        model.selectedChatID = nextChat.id
        XCTAssertEqual(provider.requests.map { $0.lease.cancellations }, [1, 0])
        provider.requests[1].receive(.data(URL(fileURLWithPath: "/synthetic/previous-chat"), offset: 0, size: 1, complete: true))
        provider.requests[0].receive(.progress(1))
        XCTAssertEqual(model.media.phase(for:firstKey),.cancelled)
        XCTAssertEqual(model.media.phase(for:secondKey),.ready)
        XCTAssertEqual(model.media.downloadedFile(for:secondKey)?.lastPathComponent,"previous-chat")
        XCTAssertEqual(provider.requests.count, 2, "Chat projection must not auto-fetch")
        model.disconnect()
        XCTAssertEqual(provider.requests.map { $0.lease.cancellations },[1,1])
        provider.requests[1].receive(.data(URL(fileURLWithPath:"/synthetic/stale-account"),offset:0,size:1,complete:true))
        XCTAssertEqual(model.media.phase(for: firstKey), .idle)
        XCTAssertEqual(model.media.phase(for: secondKey), .idle)
        XCTAssertNil(model.media.downloadedFile(for: secondKey))
        XCTAssertEqual(provider.requests.count, 2, "Disconnect must not auto-fetch")
    }
}
#endif
