import XCTest
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private nonisolated func observationSeed(_ box: Postbox, chatID: Int64 = 42,
    text: String?, timestamp: Int32 = 100, effect: Int64? = nil) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        let native = text.map { SynchronizeableChatInputState(replySubject: nil, text: $0,
            entities: [MessageTextEntity(range: 0..<$0.utf16.count, type: .Bold)], timestamp: timestamp,
            textSelection: nil, messageEffectId: effect, suggestedPost: nil) }
        _internal_updateChatInputState(transaction: transaction, peerId: PeerId(chatID), threadId: nil, inputState: native)
        return true
    }
}

private nonisolated func observationMetadata(_ box: Postbox, chatID: Int64 = 42,
    timestamp: Int32) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        guard let previous = transaction.getPeerChatInterfaceState(PeerId(chatID)) else { return false }
        transaction.setPeerChatInterfaceState(PeerId(chatID), state: StoredPeerChatInterfaceState(
            overrideChatTimestamp: timestamp, historyScrollMessageIndex: previous.historyScrollMessageIndex,
            associatedMessageIds: previous.associatedMessageIds, data: previous.data))
        return true
    }
}

private nonisolated func observationFacts(_ box: Postbox) -> Signal<(TelegramComposerDraft?, Data?, Int), NoError> {
    box.transaction { transaction in
        var operations = 0
        transaction.operationLogEnumerateEntries(peerId: PeerId(42), tag: OperationLogTags.SynchronizeChatInputStates) {
            if $0.contents is SynchronizeChatInputStateOperation { operations += 1 }
            return true
        }
        let local = try? telegramComposerDraftRead(transaction: transaction, accountID: 1, chatID: 42).get()
        let basis = transaction.getPreferencesEntry(key: telegramServerDraftBasisKey(accountID: 1, chatID: 42))?.data
        return (local, basis, operations)
    }
}

private nonisolated func observationBasisOnlyWrite(_ box: Postbox) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        let key = telegramServerDraftBasisKey(accountID: 1, chatID: 42)
        guard let entry = transaction.getPreferencesEntry(key: key) else { return false }
        // JSON trailing whitespace changes only this preference's bytes.
        transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: entry.data + Data("\n".utf8)))
        return true
    }
}

private nonisolated func observationOversizedNative(_ box: Postbox) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        transaction.setPeerChatInterfaceState(PeerId(42), state: StoredPeerChatInterfaceState(
            overrideChatTimestamp: 100, historyScrollMessageIndex: nil, associatedMessageIds: [],
            data: Data(repeating: 0, count: 512 * 1024 + 1)))
        return true
    }
}

@MainActor final class TelegramServerDraftObservationTests: TelegramSourceFactsIntegrationTestCase {
    // A view that never observes native changes leaves the active editor stale.
    func testActiveNativeChangeEmitsExactCandidateWithoutPersistingOrEchoOperation() async throws {
        let box = try await box(), repository = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 1)
        let original = TelegramComposerDraft(accountID: 1, chatID: 42, text: "local")
        try await save(original, repository)
        let before = try await sourceFactsValue(observationFacts(box))
        let observer = TelegramPostboxServerDraftObserver(postbox: box, accountID: 1), context = context()
        let changed = expectation(description: "Active server draft candidate")
        var events: [TelegramServerDraftObservationEvent] = []
        let lease = observer.observe(chatID: 42, context: context) { events.append($0); changed.fulfill() }
        defer { lease.dispose() }
        _ = try await sourceFactsValue(observationSeed(box, text: "😀 e\u{301}"))
        await fulfillment(of: [changed], timeout: 2)
        guard let event = events.first else { return }
        let update = try event.result.get()
        XCTAssertEqual(event.context, context)
        XCTAssertEqual(update.draft.accountID, 1); XCTAssertEqual(update.draft.chatID, 42)
        XCTAssertEqual(Array(update.draft.text.utf8), [240,159,152,128,32,101,204,129])
        XCTAssertEqual(update.draft.input.formattedText.entities, [.init(offset: 0, length: 5, kind: .bold)])
        XCTAssertEqual(update.basisRevision, original.revision)
        XCTAssertFalse(update.nativeFingerprint.isEmpty)
        let after = try await sourceFactsValue(observationFacts(box))
        XCTAssertEqual(after.0, original); XCTAssertEqual(after.1, before.1)
        XCTAssertEqual(after.2, before.2)
    }

    // Local atomic native+basis writes and basis-only preferences must not echo.
    func testLocalSaveAndBasisOnlyWriteDoNotEmitRemoteUpdate() async throws {
        let box = try await box(), repository = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 1)
        let observer = TelegramPostboxServerDraftObserver(postbox: box, accountID: 1)
        let silent = expectation(description: "No local echo"); silent.isInverted = true
        let lease = observer.observe(chatID: 42, context: context()) { _ in silent.fulfill() }
        defer { lease.dispose() }
        let draft = TelegramComposerDraft(accountID: 1, chatID: 42, text: "local")
        try await save(draft, repository)
        let wroteBasis = try await sourceFactsValue(observationBasisOnlyWrite(box))
        XCTAssertTrue(wroteBasis)
        await fulfillment(of: [silent], timeout: 0.25)
        let facts = try await sourceFactsValue(observationFacts(box))
        XCTAssertEqual(facts.0, draft); XCTAssertEqual(facts.2, 1)
    }

    // Clearing on another device must surface a candidate empty tombstone.
    func testRemoteClearEmitsEmptyCandidateWithoutClearingLocalDraft() async throws {
        let box = try await box(), repository = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 1)
        let original = TelegramComposerDraft(accountID: 1, chatID: 42, text: "retained local")
        try await save(original, repository)
        let observer = TelegramPostboxServerDraftObserver(postbox: box, accountID: 1)
        let cleared = expectation(description: "Remote clear candidate")
        var updates: [TelegramServerDraftUpdate] = []
        let lease = observer.observe(chatID: 42, context: context()) {
            if case let .success(update) = $0.result { updates.append(update); cleared.fulfill() }
        }
        defer { lease.dispose() }
        _ = try await sourceFactsValue(observationSeed(box, text: nil))
        await fulfillment(of: [cleared], timeout: 2)
        guard let update = updates.first else { return }
        XCTAssertEqual(update.draft.text, ""); XCTAssertNil(update.draft.replyTarget)
        XCTAssertEqual(update.basisRevision, original.revision)
        let facts = try await sourceFactsValue(observationFacts(box))
        XCTAssertEqual(facts.0, original)
    }

    // Second-resolution timestamps must not hide a different native text value.
    func testSameTimestampNativeChangeStillEmitsSecondCandidate() async throws {
        let box = try await box(), observer = TelegramPostboxServerDraftObserver(postbox: box, accountID: 1)
        let first = expectation(description: "First native value"), second = expectation(description: "Same timestamp new value")
        var texts: [String] = []
        let lease = observer.observe(chatID: 42, context: context()) {
            if case let .success(update) = $0.result {
                texts.append(update.draft.text)
                if update.draft.text == "first" { first.fulfill() }
                if update.draft.text == "second" { second.fulfill() }
            }
        }
        defer { lease.dispose() }
        _ = try await sourceFactsValue(observationSeed(box, text: "first", timestamp: 100))
        await fulfillment(of: [first], timeout: 2)
        _ = try await sourceFactsValue(observationSeed(box, text: "second", timestamp: 100))
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(texts, ["first", "second"])
    }

    // Rebinding must dispose the old peer and keep the new context generation.
    func testRebindingUsesOnlyNewChatAndCapturedGeneration() async throws {
        let box = try await box(), observer = TelegramPostboxServerDraftObserver(postbox: box, accountID: 1)
        let old = context(), current = context(chatID: 43)
        let changed = expectation(description: "New active chat update")
        var events: [TelegramServerDraftObservationEvent] = []
        let first = observer.observe(chatID: 42, context: old) { events.append($0) }
        let second = observer.observe(chatID: 43, context: current) { events.append($0); changed.fulfill() }
        first.dispose()
        defer { first.dispose(); second.dispose() }
        _ = try await sourceFactsValue(observationSeed(box, text: "old chat"))
        _ = try await sourceFactsValue(observationSeed(box, chatID: 43, text: "current chat"))
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.context, current)
        if let event = events.first { XCTAssertEqual(try event.result.get().draft.chatID, 43) }
    }

    // A caller's disposal must prevent subsequent delivery even while retained.
    func testDisposedObserverCannotDeliverSubsequentNativeChange() async throws {
        let box = try await box(), observer = TelegramPostboxServerDraftObserver(postbox: box, accountID: 1)
        let silent = expectation(description: "Disposed view silent"); silent.isInverted = true
        let lease = observer.observe(chatID: 42, context: context()) { _ in silent.fulfill() }
        lease.dispose()
        _ = try await sourceFactsValue(observationSeed(box, text: "after disposal"))
        await fulfillment(of: [silent], timeout: 0.25)
    }

    // Rejecting a foreign context must also stop the previously active observer.
    func testMismatchedAccountOrChatContextRejectsAndStopsPreviousObservation() async throws {
        for foreign in [context(accountID: 2), context(chatID: 43)] {
            let box = try await box(), observer = TelegramPostboxServerDraftObserver(postbox: box, accountID: 1)
            let silent = expectation(description: "Foreign context rejected"); silent.isInverted = true
            let previous = observer.observe(chatID: 42, context: context()) { _ in silent.fulfill() }
            let rejected = observer.observe(chatID: 42, context: foreign) { _ in silent.fulfill() }
            defer { previous.dispose(); rejected.dispose() }
            _ = try await sourceFactsValue(observationSeed(box, text: "must not deliver"))
            await fulfillment(of: [silent], timeout: 0.25)
        }
    }

    // Irrelevant native metadata changes must not synthesize fresh UUID updates.
    func testIdenticalNativeInputDoesNotRepeatCandidateOnMetadataChange() async throws {
        let box = try await box(), observer = TelegramPostboxServerDraftObserver(postbox: box, accountID: 1)
        let changed = expectation(description: "One native candidate")
        let repeated = expectation(description: "No duplicate native candidate"); repeated.isInverted = true
        var count = 0
        let lease = observer.observe(chatID: 42, context: context()) { _ in
            count += 1
            if count == 1 { changed.fulfill() } else { repeated.fulfill() }
        }
        defer { lease.dispose() }
        _ = try await sourceFactsValue(observationSeed(box, text: "same native"))
        await fulfillment(of: [changed], timeout: 2)
        let wroteMetadata = try await sourceFactsValue(observationMetadata(box, timestamp: 101))
        XCTAssertTrue(wroteMetadata)
        await fulfillment(of: [repeated], timeout: 0.25)
        XCTAssertEqual(count, 1)
    }

    // Oversized native bytes must fail before the legacy decoder, without spam.
    func testOversizedNativeFailsClosedAndRepeatedMetadataDoesNotSpam() async throws {
        let box = try await box(), observer = TelegramPostboxServerDraftObserver(postbox: box, accountID: 1)
        let failed = expectation(description: "Native input rejected")
        let repeated = expectation(description: "No repeated invalid-native error"); repeated.isInverted = true
        var errors: [TelegramComposerDraftPersistenceError] = []
        let lease = observer.observe(chatID: 42, context: context()) {
            if case let .failure(error) = $0.result {
                errors.append(error)
                if errors.count == 1 { failed.fulfill() } else { repeated.fulfill() }
            }
        }
        defer { lease.dispose() }
        _ = try await sourceFactsValue(observationOversizedNative(box))
        await fulfillment(of: [failed], timeout: 2)
        let wroteMetadata = try await sourceFactsValue(observationMetadata(box, timestamp: 101))
        XCTAssertTrue(wroteMetadata)
        await fulfillment(of: [repeated], timeout: 0.25)
        XCTAssertEqual(errors, [.incompatibleData])
        let facts = try await sourceFactsValue(observationFacts(box))
        XCTAssertNil(facts.0); XCTAssertNil(facts.1); XCTAssertEqual(facts.2, 0)
    }

    // Unsupported native semantics stay intact instead of becoming lossy text.
    func testUnsupportedMessageEffectEmitsFailureWithoutLocalImport() async throws {
        let box = try await box(), observer = TelegramPostboxServerDraftObserver(postbox: box, accountID: 1)
        let failed = expectation(description: "Unsupported semantics rejected")
        var errors: [TelegramComposerDraftPersistenceError] = []
        let lease = observer.observe(chatID: 42, context: context()) {
            if case let .failure(error) = $0.result { errors.append(error); failed.fulfill() }
        }
        defer { lease.dispose() }
        _ = try await sourceFactsValue(observationSeed(box, text: "native effect", effect: 99))
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(errors, [.incompatibleData])
        let facts = try await sourceFactsValue(observationFacts(box))
        XCTAssertNil(facts.0); XCTAssertNil(facts.1); XCTAssertEqual(facts.2, 0)
    }

    // Secret-chat state is local-only and must never surface as a cloud draft.
    func testSecretChatNativeStateDoesNotEmitCloudDraftUpdate() async throws {
        let box = try await box(), observer = TelegramPostboxServerDraftObserver(postbox: box, accountID: 1)
        let secret = PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(7)).toInt64()
        let silent = expectation(description: "No secret cloud draft"); silent.isInverted = true
        let lease = observer.observe(chatID: secret, context: context(chatID: secret)) { _ in silent.fulfill() }
        defer { lease.dispose() }
        _ = try await sourceFactsValue(observationSeed(box, chatID: secret, text: "local secret input"))
        await fulfillment(of: [silent], timeout: 0.25)
    }

    private func context(accountID: Int64 = 1, chatID: Int64 = 42) -> TelegramServerDraftObservationContext {
        .init(accountID: accountID, chatID: chatID, generation: UUID())
    }

    private func box() async throws -> Postbox {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return try await sourceFactsOpen(root.appendingPathComponent("postbox"))
    }

    private func save(_ draft: TelegramComposerDraft, _ repository: TelegramPostboxComposerDraftRepository) async throws {
        try await withCheckedThrowingContinuation { continuation in
            repository.save(draft) { continuation.resume(with: $0) }
        }
    }
}
