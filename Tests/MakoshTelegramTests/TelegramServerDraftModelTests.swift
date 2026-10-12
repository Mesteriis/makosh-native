#if DEBUG
import XCTest
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramServerDraftModelTests: XCTestCase {
    func testCommonWindowConflictFixtureUsesTheRealModelChoiceLifecycle() throws {
        for keepLocal in [true, false] {
            let model = TelegramModel.syntheticExtendedMessagesPreview(specialConversation: "draft")
            let conflict = try XCTUnwrap(model.serverDraftConflict)
            XCTAssertEqual(model.draft, "Локальный черновик 😀")
            XCTAssertFalse(model.composerCanSend)
            model.resolveServerDraftConflict(id: conflict.id, keepLocal: keepLocal)
            XCTAssertNil(model.serverDraftConflict)
            XCTAssertEqual(model.draft, keepLocal ? "Локальный черновик 😀" : "Черновик с другого устройства 🦊")
            XCTAssertFalse(model.isResolvingServerDraft)
        }
    }
    private final class Repository: TelegramComposerDraftRepository, TelegramServerDraftResolving {
        let accountID: Int64 = -1
        var saved: TelegramComposerDraft?
        var deferLoad = false
        var pendingLoad: (@MainActor (Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError>) -> Void)?
        var resolutions: [(TelegramServerDraftUpdate, TelegramComposerDraft?, TelegramServerDraftChoice,
            @MainActor (Result<TelegramComposerDraft, TelegramComposerDraftPersistenceError>) -> Void)] = []
        func load(chatID: Int64, completion: @escaping @MainActor (Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError>) -> Void) -> Disposable {
            if deferLoad { pendingLoad = completion } else { completion(.success(saved)) }
            return EmptyDisposable
        }
        func save(_ draft: TelegramComposerDraft, completion: @escaping @MainActor (Result<Void, TelegramComposerDraftPersistenceError>) -> Void) {
            saved = draft; completion(.success(()))
        }
        func resolve(update: TelegramServerDraftUpdate, local: TelegramComposerDraft?, choice: TelegramServerDraftChoice,
            completion: @escaping @MainActor (Result<TelegramComposerDraft, TelegramComposerDraftPersistenceError>) -> Void) -> Disposable {
            resolutions.append((update, local, choice, completion)); return EmptyDisposable
        }
    }
    private final class Observer: TelegramServerDraftObserving {
        let accountID: Int64 = -1
        var subscriptions: [(TelegramServerDraftObservationContext, @MainActor (TelegramServerDraftObservationEvent) -> Void)] = []
        func observe(chatID: Int64, context: TelegramServerDraftObservationContext,
            receive: @escaping @MainActor (TelegramServerDraftObservationEvent) -> Void) -> Disposable {
            subscriptions.append((context, receive)); return EmptyDisposable
        }
        func emit(_ update: TelegramServerDraftUpdate, index: Int? = nil) {
            guard let subscription = index.map({ subscriptions[$0] }) ?? subscriptions.last else { return }
            subscription.1(.init(context: subscription.0, result: .success(update)))
        }
    }
    private func fixture() -> (TelegramModel, Repository, Observer, TelegramComposerDraft) {
        let model = TelegramModel.syntheticPreview(), repository = Repository(), observer = Observer()
        let saved = TelegramComposerDraft(accountID: -1, chatID: 10001, text: "saved")
        repository.saved = saved
        model.bindComposerDraftRepository(repository)
        model.selectedChatID = 10001
        model.bindServerDraftObserver(observer)
        return (model, repository, observer, saved)
    }
    private func remote(_ saved: TelegramComposerDraft, basis: UUID?) -> TelegramServerDraftUpdate {
        .init(draft: .init(accountID: saved.accountID, chatID: saved.chatID, text: "remote 😀"),
            nativeFingerprint: Data("exact native".utf8), basisRevision: basis, localRevision: saved.revision)
    }
    func testCleanEditorAppliesRemoteOnlyAfterDurableResolutionAcknowledgement() {
        let (model, repository, observer, saved) = fixture(), update = remote(saved, basis: saved.revision)
        observer.emit(update)
        XCTAssertEqual(repository.resolutions.count, 1)
        XCTAssertEqual(model.draft, "saved")
        XCTAssertTrue(model.isResolvingServerDraft)
        guard let resolution = repository.resolutions.first else { return }
        resolution.3(.success(update.draft))
        XCTAssertEqual(model.draft, "remote 😀")
        XCTAssertFalse(model.isResolvingServerDraft)
        XCTAssertNil(model.serverDraftConflict)
        XCTAssertEqual(repository.saved, saved, "Remote import does not echo through ordinary save")
    }
    func testRemoteCandidateWaitsForLocalDraftRestorationBeforeChoosingConflictOrImport() {
        let model = TelegramModel.syntheticPreview(), repository = Repository(), observer = Observer()
        let saved = TelegramComposerDraft(accountID: -1, chatID: 10001, text: "saved")
        repository.saved = saved; repository.deferLoad = true
        model.bindComposerDraftRepository(repository); model.selectedChatID = 10001; model.bindServerDraftObserver(observer)
        XCTAssertTrue(model.isRestoringComposerDraft)
        let update = remote(saved, basis: saved.revision)
        observer.emit(update)
        XCTAssertNil(model.serverDraftConflict, "The local draft is still loading")
        XCTAssertTrue(repository.resolutions.isEmpty)
        repository.pendingLoad?(.success(saved))
        XCTAssertFalse(model.isRestoringComposerDraft)
        XCTAssertEqual(repository.resolutions.count, 1)
        repository.resolutions.first?.3(.success(update.draft))
        XCTAssertEqual(model.draft, "remote 😀")
        XCTAssertNil(model.serverDraftConflict)
    }
    func testLostResolutionAcknowledgementRetainsInputAndLateCallbackCannotReplaceIt() async throws {
        let (model, repository, observer, saved) = fixture(), update = remote(saved, basis: saved.revision)
        observer.emit(update)
        XCTAssertTrue(model.isResolvingServerDraft)
        try await Task.sleep(for: .milliseconds(30_300))
        XCTAssertFalse(model.isResolvingServerDraft, "A missing Postbox ACK cannot lock the editor forever")
        XCTAssertEqual(model.draft, "saved")
        XCTAssertNotNil(model.serverDraftConflict)
        repository.resolutions.first?.3(.success(update.draft))
        XCTAssertEqual(model.draft, "saved", "An expired callback cannot overwrite the retained input")
    }
    func testIndependentlyEditedInputShowsConflictAndExplicitLocalChoiceUsesCurrentEditor() throws {
        let (model, repository, observer, saved) = fixture()
        model.draft = "local edit"
        observer.emit(remote(saved, basis: saved.revision))
        XCTAssertTrue(repository.resolutions.isEmpty)
        XCTAssertEqual(model.draft, "local edit")
        let conflict = try XCTUnwrap(model.serverDraftConflict)
        XCTAssertEqual(conflict.remoteText, "remote 😀")
        XCTAssertFalse(model.composerCanSend)
        model.draft = "latest local"
        model.resolveServerDraftConflict(id: conflict.id, keepLocal: true)
        XCTAssertEqual(repository.resolutions.count, 1)
        let chosen = try XCTUnwrap(repository.resolutions.first?.1)
        XCTAssertEqual(chosen.text, "latest local")
        XCTAssertTrue(model.isResolvingServerDraft)
        XCTAssertFalse(model.updateComposerInput(.empty, contextID: model.messageActionContextID, chatID: 10001))
        repository.resolutions[0].3(.success(chosen))
        XCTAssertNil(model.serverDraftConflict)
        XCTAssertEqual(model.draft, "latest local")
    }
    func testOldChatOrAccountUpdateAndResolutionCannotReplaceCurrentEditor() {
        let (model, repository, observer, saved) = fixture(), update = remote(saved, basis: saved.revision)
        observer.emit(update)
        model.selectedChatID = 10002
        observer.emit(update, index: observer.subscriptions.isEmpty ? nil : 0)
        repository.resolutions.first?.3(.success(update.draft))
        XCTAssertEqual(model.draft, "")
        XCTAssertNil(model.serverDraftConflict)
        model.disconnect()
        observer.emit(update)
        XCTAssertEqual(model.phase, .configuration)
        XCTAssertEqual(model.draft, "")
    }
}
#endif
