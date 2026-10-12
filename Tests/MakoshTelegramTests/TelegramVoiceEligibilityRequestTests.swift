import XCTest
import SwiftSignalKit
import TelegramCore
@testable import Postbox
@testable import MakoshTelegram

// Keep native transaction work nonisolated: Postbox invokes it on its own queue.
private func recordingEligibilitySnapshotFixture(_ box: Postbox, ban: TelegramChatBannedRightsFlags,
    kind: TelegramRecordingKind) -> Signal<TelegramVoiceEligibility, NoError> {
    box.transaction { transaction in
        let id = PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(7))
        let peer = TelegramGroup(id: id, title: "Synthetic recording permissions", photo: [], participantCount: 2,
            role: .member, membership: .Member, flags: [],
            defaultBannedRights: TelegramChatBannedRights(flags: ban, untilDate: Int32.max),
            migrationReference: nil, creationDate: 0, version: 1)
        transaction.updatePeersInternal([peer], update: { _, new in new })
        return telegramVoiceEligibilitySnapshot(transaction: transaction, peerID: id, now: 2_000, kind: kind)
    }
}

@MainActor final class TelegramVoiceEligibilityRequestTests: XCTestCase {
    // Catches refusing/ignoring a current native snapshot instead of delivering
    // its actual permission result to the recording state machine.
    func testDeliversCurrentSnapshot() async {
        let request = TelegramVoiceEligibilityRequest()
        let value = await request.check(signal: .single(.allowed))
        XCTAssertEqual(value, .allowed)
    }
    // Catches a permission wait surviving navigation, or replacing a newer
    // request with an old observer's late response.
    func testCancellationResolvesWaitingSnapshotAndNewRequestIsIndependent() async {
        let request = TelegramVoiceEligibilityRequest()
        var result: TelegramVoiceEligibility?
        let waiting = Task { result = await request.check(signal: .never()) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(result)
        request.cancel(); await waiting.value
        XCTAssertEqual(result, .unavailable)
        let next = await request.check(signal: .single(.voicePrivacy))
        XCTAssertEqual(next, .voicePrivacy)
    }

    // Catches dropping recording kind at the actual encrypted Postbox snapshot
    // boundary or replacing its native result while delivering it to the caller.
    func testRoundKindReachesRealPostboxSnapshotAndRequestDelivery() async throws {
        initializeAccountManagement()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 7, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 8, count: 16)))
        let opened = expectation(description: "Synthetic encrypted permission cache")
        var postbox: Postbox?
        let opening = (openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt),
            timestampForAbsoluteTimeBasedOperations: 1, isMainProcess: true, isTemporary: false,
            isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false)
            |> deliverOnMainQueue).start(next: {
                if case let .postbox(box) = $0 { postbox = box; opened.fulfill() }
            })
        defer { opening.dispose() }
        await fulfillment(of: [opened], timeout: 20)
        let box = try XCTUnwrap(postbox)
        let stores = expectation(description: "Synthetic media stores ready")
        stores.expectedFulfillmentCount = 2
        let storage = (box.mediaBox.storageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in stores.fulfill() })
        let cache = (box.mediaBox.cacheStorageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in stores.fulfill() })
        defer { storage.dispose(); cache.dispose() }
        await fulfillment(of: [stores], timeout: 20)
        let request = TelegramVoiceEligibilityRequest()
        let roundDenied = await request.check(signal: recordingEligibilitySnapshotFixture(box, ban: [.banSendInstantVideos], kind: .roundVideo))
        let voiceAllowed = await request.check(signal: recordingEligibilitySnapshotFixture(box, ban: [.banSendInstantVideos], kind: .voice))
        let roundAllowed = await request.check(signal: recordingEligibilitySnapshotFixture(box, ban: [.banSendVoice, .banSendVideos], kind: .roundVideo))
        XCTAssertEqual(roundDenied, .restricted)
        XCTAssertEqual(voiceAllowed, .allowed)
        XCTAssertEqual(roundAllowed, .allowed)
    }

    // A cancelled async caller must release its wait; its cancellation handler
    // must not poison a replacement request.
    func testTaskCancellationLeavesReplacementRequestIndependent() async {
        let request = TelegramVoiceEligibilityRequest()
        let subscribed = expectation(description: "Permission wait subscribed")
        let signal = Signal<TelegramVoiceEligibility, NoError> { _ in
            subscribed.fulfill(); return EmptyDisposable
        }
        let waiting = Task { await request.check(signal: signal) }
        await fulfillment(of: [subscribed], timeout: 2)
        waiting.cancel()
        let cancelled = await waiting.value
        XCTAssertEqual(cancelled, .unavailable)
        let replacement = await request.check(signal: .single(.allowed))
        XCTAssertEqual(replacement, .allowed)
    }
}
