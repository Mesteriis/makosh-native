import XCTest
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private nonisolated func serverDraftSeed(_ box: Postbox, text: String?, quote: EngineMessageReplyQuote? = nil) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        let input = text.map { SynchronizeableChatInputState(replySubject: quote.map {
            EngineMessageReplySubject(messageId: MessageId(peerId: PeerId(42), namespace: 0, id: 7), quote: $0, todoItemId: nil)
        }, text: $0,
            entities: [MessageTextEntity(range: 0..<$0.utf16.count, type: .Bold)], timestamp: 100,
            textSelection: nil, messageEffectId: nil, suggestedPost: nil) }
        _internal_updateChatInputState(transaction: transaction, peerId: PeerId(42), threadId: nil, inputState: input)
        return true
    }
}
private nonisolated func serverDraftInspect(_ box: Postbox) -> Signal<(SynchronizeableChatInputState?, [SynchronizeChatInputStateOperation]), NoError> {
    box.transaction { transaction in
        var operations: [SynchronizeChatInputStateOperation] = []
        transaction.operationLogEnumerateEntries(peerId: PeerId(42), tag: OperationLogTags.SynchronizeChatInputStates) {
            if let value = $0.contents as? SynchronizeChatInputStateOperation { operations.append(value) }
            return true
        }
        let input = transaction.getPeerChatInterfaceState(PeerId(42)).flatMap {
            _internal_decodeStoredChatInterfaceState(state: $0)?.synchronizeableInputState
        }
        return (input, operations)
    }
}

private nonisolated func serverDraftCandidate(_ box: Postbox) -> Signal<TelegramServerDraftUpdate?, NoError> {
    box.transaction { try? telegramServerDraftUpdate(transaction: $0, accountID: 1, chatID: 42) }
}
private nonisolated func serverDraftChoose(_ box: Postbox, update: TelegramServerDraftUpdate,
    local: TelegramComposerDraft?, choice: TelegramServerDraftChoice) -> Signal<Result<TelegramComposerDraft, TelegramComposerDraftPersistenceError>, NoError> {
    box.transaction {
        do { return .success(try telegramServerDraftResolve(transaction: $0, update: update, local: local, choice: choice)) }
        catch let error as TelegramComposerDraftPersistenceError { return .failure(error) }
        catch { return .failure(.incompatibleData) }
    }
}

@MainActor final class TelegramServerDraftTests: TelegramSourceFactsIntegrationTestCase {
    func testExplicitLocalChoiceAtomicallyKeepsCurrentEditorAndExportsNewNativeBasis() async throws {
        let box = try await box(), repository = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 1)
        let saved = TelegramComposerDraft(accountID: 1, chatID: 42, text: "saved local")
        try await save(saved, repository)
        _ = try await sourceFactsValue(serverDraftSeed(box, text: "remote"))
        let candidate = try await sourceFactsValue(serverDraftCandidate(box))
        let update = try XCTUnwrap(candidate)
        XCTAssertEqual(update.localRevision, saved.revision)
        let typed = TelegramComposerDraft(accountID: 1, chatID: 42, text: "current 😀 editor")
        let result = try await sourceFactsValue(serverDraftChoose(box, update: update, local: typed, choice: .local))
        guard case let .success(chosen) = result else { return XCTFail("Explicit local resolution must succeed atomically") }
        XCTAssertEqual(chosen.input, typed.input)
        XCTAssertNotEqual(chosen.revision, saved.revision)
        let native = try await sourceFactsValue(serverDraftInspect(box))
        XCTAssertEqual(native.0?.text, typed.text)
        let loaded = try await load(repository)
        XCTAssertEqual(loaded, chosen)
        let echoed = try await sourceFactsValue(serverDraftCandidate(box))
        XCTAssertNil(echoed)
    }
    func testRemoteChoiceRetainsEmptyTombstoneAndCannotOverwriteNewerNativeChange() async throws {
        let box = try await box(), repository = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 1)
        let saved = TelegramComposerDraft(accountID: 1, chatID: 42, text: "saved local")
        try await save(saved, repository)
        _ = try await sourceFactsValue(serverDraftSeed(box, text: nil))
        let first = try await sourceFactsValue(serverDraftCandidate(box))
        let update = try XCTUnwrap(first)
        _ = try await sourceFactsValue(serverDraftSeed(box, text: "newer remote"))
        let stale = try await sourceFactsValue(serverDraftChoose(box, update: update, local: saved, choice: .remote))
        XCTAssertEqual(try? stale.get().text, nil)
        if case let .failure(error) = stale { XCTAssertEqual(error, .serverConflict) } else { XCTFail("Stale remote choice must refuse") }
        let untouched = try await sourceFactsValue(serverDraftInspect(box))
        XCTAssertEqual(untouched.0?.text, "newer remote")
        _ = try await sourceFactsValue(serverDraftSeed(box, text: nil))
        let latest = try await sourceFactsValue(serverDraftCandidate(box))
        let resolved = try await sourceFactsValue(serverDraftChoose(box, update: XCTUnwrap(latest), local: saved, choice: .remote))
        guard case let .success(chosen) = resolved else { return XCTFail("Current remote clear must become durable tombstone") }
        XCTAssertTrue(chosen.text.isEmpty)
        let loaded = try await load(repository)
        XCTAssertEqual(loaded, chosen)
    }
    func testQuoteExportsAndRemoteQuoteImportsBeforeOriginalMessageIsCached() async throws {
        let box = try await box(), repository = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 1)
        let source = try TelegramFormattedText(text: "prefix selected", entities: [.init(offset: 7, length: 8, kind: .italic)])
        let quote = try XCTUnwrap(TelegramReplyQuote(source: source, selection: .init(location: 7, length: 8)))
        let draft = TelegramComposerDraft(accountID: 1, chatID: 42, text: "answer",
            replyTarget: .init(peerID: 42, namespace: 0, messageID: 7, quote: quote))
        try await save(draft, repository)
        let exported = try await sourceFactsValue(serverDraftInspect(box))
        XCTAssertEqual(exported.0?.replySubject?.quote?.text, "selected")
        XCTAssertEqual(exported.0?.replySubject?.quote?.entities, [MessageTextEntity(range: 0..<8, type: .Italic)])
        let remoteQuote = EngineMessageReplyQuote(text: "remote fragment", offset: nil,
            entities: [MessageTextEntity(range: 0..<15, type: .Bold)], media: nil)
        _ = try await sourceFactsValue(serverDraftSeed(box, text: "remote answer", quote: remoteQuote))
        do {
            let imported = try await load(repository)
            XCTAssertEqual(imported?.replyTarget?.quote?.formattedText.text, "remote fragment")
            XCTAssertEqual(imported?.schemaVersion, 5)
        } catch { XCTFail("An uncached reply must retain its server quote: \(error)") }
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
    private func load(_ repository: TelegramPostboxComposerDraftRepository) async throws -> TelegramComposerDraft? {
        let done = expectation(description: "Server draft reconciliation")
        var result: Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError> = .failure(.unavailable)
        let disposable = repository.load(chatID: 42) { result = $0; done.fulfill() }
        defer { disposable.dispose() }
        await fulfillment(of: [done], timeout: 20)
        return try result.get()
    }
    func testInitialRemoteDraftImportsWithoutEchoOperationAndKeepsExactUnicode() async throws {
        let box = try await box(), repository = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 1)
        _ = try await sourceFactsValue(serverDraftSeed(box, text: "😀 e\u{301}"))
        let loaded = try await load(repository)
        let draft = try XCTUnwrap(loaded)
        XCTAssertEqual(Array(draft.text.utf8), Array("😀 e\u{301}".utf8))
        XCTAssertEqual(draft.input.formattedText.entities, [.init(offset: 0, length: 5, kind: .bold)])
        XCTAssertEqual(draft.input.selection, .init(location: 5, length: 0))
        let state = try await sourceFactsValue(serverDraftInspect(box))
        XCTAssertEqual(state.0?.timestamp, 100); XCTAssertTrue(state.1.isEmpty)
    }
    func testNewRemoteInputStopsLateSaveThenImportsAsNewRevision() async throws {
        let box = try await box(), repository = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 1)
        let original = TelegramComposerDraft(accountID: 1, chatID: 42, text: "local")
        try await save(original, repository)
        _ = try await sourceFactsValue(serverDraftSeed(box, text: "remote"))
        do {
            try await save(.init(accountID: 1, chatID: 42, text: "late typing"), repository)
            XCTFail("A late UI save must not overwrite another device")
        } catch { XCTAssertEqual(error as? TelegramComposerDraftPersistenceError, .serverConflict) }
        let state = try await sourceFactsValue(serverDraftInspect(box))
        XCTAssertEqual(state.0?.text, "remote")
        let loaded = try await load(repository)
        let imported = try XCTUnwrap(loaded)
        XCTAssertEqual(imported.text, "remote"); XCTAssertNotEqual(imported.revision, original.revision)
    }
    func testRemoteClearCreatesTombstoneAndCursorOnlySaveKeepsOneOperation() async throws {
        let box = try await box(), repository = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 1)
        let formatted = try TelegramFormattedText(text: "abc")
        let original = TelegramComposerDraft(accountID: 1, chatID: 42, input: try .init(formattedText: formatted))
        try await save(original, repository)
        let initial = try await sourceFactsValue(serverDraftInspect(box))
        try await save(.init(accountID: 1, chatID: 42, input: try .init(formattedText: formatted,
            selection: .init(location: 1, length: 0))), repository)
        let moved = try await sourceFactsValue(serverDraftInspect(box))
        XCTAssertEqual(moved.0?.timestamp, initial.0?.timestamp); XCTAssertEqual(moved.1.count, 1)
        XCTAssertNil(moved.1.first?.previousState)
        _ = try await sourceFactsValue(serverDraftSeed(box, text: nil))
        let loaded = try await load(repository)
        let cleared = try XCTUnwrap(loaded)
        XCTAssertTrue(cleared.text.isEmpty)
        let reopened = try await load(repository)
        XCTAssertEqual(reopened, cleared)
    }
}
