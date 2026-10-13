import XCTest
import Postbox
import TelegramCore
@testable import MakoshTelegram

@MainActor final class TelegramSecretChatLifecycleTests: XCTestCase {
    private let secretID: Int64 = 12_884_901_932
    private var peer: TelegramSecretCreationBasis {
        .init(accountID: 101, peerID: 42, title: "Synthetic Alice", username: "alice", canCreate: true,
            premiumRequired: false, revision: String(repeating: "a", count: 64))
    }
    private func session(state: TelegramSecretConversation.State = .active, ttl: Int32? = nil, revision: String? = nil) -> TelegramSecretSessionSnapshot {
        .init(accountID: 101, chatID: secretID, regularPeerID: 42, title: "Synthetic Alice", state: state,
            verification: state == .active ? .init(sha1: Data(0..<20), sha256: Data(32..<64)) : nil,
            layer: state == .active ? 144 : nil, ttl: ttl, keyAvailable: state == .active,
            revision: revision ?? String(repeating: "b", count: 64))
    }
    private func openCreation(_ controller: TelegramSecretChatController, _ provider: SecretLifecycleProvider) {
        controller.bind(provider); controller.openCreation(peerID: 42); provider.creationReads[0](.success(peer))
    }
    private func openSession(_ controller: TelegramSecretChatController, _ provider: SecretLifecycleProvider) {
        controller.bind(provider); controller.selectSession(chatID: secretID); provider.observations[0](.success(session()))
    }
    func testCreationRequiresCurrentExactUserAndConfirmationContext() {
        let provider = SecretLifecycleProvider(), controller = TelegramSecretChatController(); openCreation(controller, provider)
        XCTAssertFalse(controller.create(basis: peer, contextID: UUID()))
        XCTAssertTrue(controller.create(basis: peer, contextID: controller.creationContextID))
        XCTAssertEqual(controller.creationPhase, .validating)
        XCTAssertFalse(controller.create(basis: peer, contextID: controller.creationContextID))
    }
    func testClosingCreationBeforeCommitRejectsLateNativeRequest() {
        let provider = SecretLifecycleProvider(), controller = TelegramSecretChatController(); openCreation(controller, provider)
        XCTAssertTrue(controller.create(basis: peer, contextID: controller.creationContextID))
        controller.closeCreation(); XCTAssertFalse(provider.creations[0](.committing))
        XCTAssertNil(controller.createdSession)
    }
    func testWrongParticipantReceiptCannotNavigateToASecretConversation() {
        let provider = SecretLifecycleProvider(), controller = TelegramSecretChatController(); openCreation(controller, provider)
        XCTAssertTrue(controller.create(basis: peer, contextID: controller.creationContextID)); XCTAssertTrue(provider.creations[0](.committing))
        let wrong = TelegramSecretSessionSnapshot(accountID: 101, chatID: secretID, regularPeerID: 43, title: "Other synthetic user", state: .handshake,
            verification: nil, layer: nil, ttl: nil, keyAvailable: false, revision: String(repeating: "b", count: 64))
        XCTAssertTrue(provider.creations[0](.created(wrong)))
        XCTAssertEqual(controller.creationPhase, .uncertain); XCTAssertNil(controller.createdSession)
    }
    func testCreationHandshakeIsObservedRatherThanReportedAsActive() {
        let provider = SecretLifecycleProvider(), controller = TelegramSecretChatController(); openCreation(controller, provider)
        XCTAssertTrue(controller.create(basis: peer, contextID: controller.creationContextID)); XCTAssertTrue(provider.creations[0](.committing))
        XCTAssertTrue(provider.creations[0](.created(session(state: .handshake))))
        XCTAssertEqual(controller.createdSession?.state, .handshake)
        XCTAssertEqual(controller.creationPhase, .created)
    }
    func testUnknownCreationSurvivesReopeningAndNeedsExplicitRefresh() {
        let provider = SecretLifecycleProvider(), controller = TelegramSecretChatController(); openCreation(controller, provider)
        XCTAssertTrue(controller.create(basis: peer, contextID: controller.creationContextID)); XCTAssertTrue(provider.creations[0](.committing))
        controller.timeoutCreation(); controller.closeCreation(); controller.openCreation(peerID: 42)
        provider.creationReads[1](.success(peer)); XCTAssertEqual(controller.creationPhase, .uncertain)
        XCTAssertFalse(controller.create(basis: peer, contextID: controller.creationContextID))
        controller.refreshCreation(); provider.creationReads[2](.success(peer)); XCTAssertEqual(controller.creationPhase, .idle)
    }
    func testTTLRequiresActiveVerifiedSessionAndAChangedValue() {
        let provider = SecretLifecycleProvider(), controller = TelegramSecretChatController(); openSession(controller, provider)
        XCTAssertFalse(controller.setTTL(nil, basis: session(), contextID: controller.sessionContextID))
        XCTAssertFalse(controller.setTTL(-1, basis: session(), contextID: controller.sessionContextID))
        XCTAssertFalse(controller.setTTL(60, basis: session(), contextID: UUID()))
        XCTAssertTrue(controller.setTTL(60, basis: session(), contextID: controller.sessionContextID))
        XCTAssertEqual(controller.ttlPhase, .validating)
    }
    func testUnknownTTLWriteSurvivesSessionReopenAndCannotReplayAutomatically() {
        let provider = SecretLifecycleProvider(), controller = TelegramSecretChatController(); openSession(controller, provider)
        XCTAssertTrue(controller.setTTL(60, basis: session(), contextID: controller.sessionContextID)); XCTAssertTrue(provider.ttls[0](.committing))
        controller.timeoutTTL(); controller.selectSession(chatID: nil); controller.selectSession(chatID: secretID)
        provider.observations[1](.success(session())); XCTAssertEqual(controller.ttlPhase, .uncertain)
        XCTAssertFalse(controller.setTTL(60, basis: session(), contextID: controller.sessionContextID))
        controller.refreshSession(); provider.observations[2](.success(session())); XCTAssertEqual(controller.ttlPhase, .idle)
    }
    func testOwnTTLObservationCanAdvanceBeforeItsExactLocalQueueReceipt() {
        let provider = SecretLifecycleProvider(), controller = TelegramSecretChatController(); openSession(controller, provider)
        let basis = session()
        XCTAssertTrue(controller.setTTL(60, basis: basis, contextID: controller.sessionContextID)); XCTAssertTrue(provider.ttls[0](.committing))
        provider.observations[0](.success(session(ttl: 60, revision: String(repeating: "c", count: 64))))
        XCTAssertTrue(provider.ttls[0](.queued(.init(accountID: 101, chatID: secretID, previousTTL: nil, timeout: 60,
            sessionRevision: basis.revision, namespace: Namespaces.Message.Local, messageID: 1))))
        XCTAssertEqual(controller.ttlPhase, .queued); XCTAssertEqual(controller.session?.ttl, 60)
    }
    func testWrongTTLReceiptNeverClaimsQueueAdmission() {
        let provider = SecretLifecycleProvider(), controller = TelegramSecretChatController(); openSession(controller, provider)
        XCTAssertTrue(controller.setTTL(60, basis: session(), contextID: controller.sessionContextID)); XCTAssertTrue(provider.ttls[0](.committing))
        XCTAssertTrue(provider.ttls[0](.queued(.init(accountID: 101, chatID: secretID, previousTTL: nil, timeout: 10,
            sessionRevision: session().revision, namespace: Namespaces.Message.Local, messageID: 1))))
        XCTAssertEqual(controller.ttlPhase, .uncertain)
    }
    func testClosingSessionRejectsLateTTLCommitAndOtherAccountObservation() {
        let provider = SecretLifecycleProvider(), controller = TelegramSecretChatController(); openSession(controller, provider)
        XCTAssertTrue(controller.setTTL(60, basis: session(), contextID: controller.sessionContextID))
        controller.selectSession(chatID: nil); XCTAssertFalse(provider.ttls[0](.committing))
        provider.observations[0](.success(session())); XCTAssertNil(controller.session)
        controller.bind(SecretLifecycleProvider(accountID: 102)); provider.observations[0](.success(session())); XCTAssertNil(controller.session)
    }
    func testRefreshReconciliationAuthorityIsConsumedByItsFirstSnapshot() {
        let provider = SecretLifecycleProvider(), controller = TelegramSecretChatController(); openSession(controller, provider)
        controller.refreshSession(); provider.observations[1](.success(session()))
        XCTAssertTrue(controller.setTTL(60, basis: session(), contextID: controller.sessionContextID)); XCTAssertTrue(provider.ttls[0](.committing))
        controller.timeoutTTL(); XCTAssertEqual(controller.ttlPhase, .uncertain)
        provider.observations[1](.success(session(revision: String(repeating: "c", count: 64))))
        XCTAssertEqual(controller.ttlPhase, .uncertain)
        XCTAssertFalse(controller.canSetTTL(60))
    }
    func testExplicitFreshReconciliationReleasesAnObsoleteQueuedTimerReceipt() {
        let provider = SecretLifecycleProvider(), controller = TelegramSecretChatController(); openSession(controller, provider)
        XCTAssertTrue(controller.setTTL(60, basis: session(), contextID: controller.sessionContextID))
        XCTAssertTrue(provider.ttls[0](.committing))
        XCTAssertTrue(provider.ttls[0](.queued(.init(accountID: 101, chatID: secretID, previousTTL: nil, timeout: 60,
            sessionRevision: session().revision, namespace: Namespaces.Message.Local, messageID: 1))))
        XCTAssertFalse(controller.canSetTTL(120), "An unobserved queue result must not be replayed")
        controller.refreshSession()
        provider.observations[1](.success(session(ttl: 30, revision: String(repeating: "d", count: 64))))
        XCTAssertTrue(controller.canSetTTL(120), "Explicit fresh reconciliation may observe a later participant timer change")
    }
}
@MainActor private final class SecretLifecycleRequest: TelegramSecretChatRequest { func cancel() {} }
@MainActor private final class SecretLifecycleProvider: TelegramSecretChatProvider {
    let accountID: Int64
    var creationReads: [@MainActor (Result<TelegramSecretCreationBasis, TelegramSecretChatError>) -> Void] = []
    var creations: [@MainActor (TelegramSecretCreationEvent) -> Bool] = []
    var observations: [@MainActor (Result<TelegramSecretSessionSnapshot, TelegramSecretChatError>) -> Void] = []
    var ttls: [@MainActor (TelegramSecretTTLEvent) -> Bool] = []
    init(accountID: Int64 = 101) { self.accountID = accountID }
    func loadCreation(peerID: Int64, receive: @escaping @MainActor (Result<TelegramSecretCreationBasis, TelegramSecretChatError>) -> Void) -> any TelegramSecretChatRequest { creationReads.append(receive); return SecretLifecycleRequest() }
    func create(basis: TelegramSecretCreationBasis, receive: @escaping @MainActor (TelegramSecretCreationEvent) -> Bool) -> any TelegramSecretChatRequest { creations.append(receive); return SecretLifecycleRequest() }
    func observeSession(chatID: Int64, receive: @escaping @MainActor (Result<TelegramSecretSessionSnapshot, TelegramSecretChatError>) -> Void) -> any TelegramSecretChatRequest { observations.append(receive); return SecretLifecycleRequest() }
    func setTTL(basis: TelegramSecretSessionSnapshot, timeout: Int32?, receive: @escaping @MainActor (TelegramSecretTTLEvent) -> Bool) -> any TelegramSecretChatRequest { ttls.append(receive); return SecretLifecycleRequest() }
}
