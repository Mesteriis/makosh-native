import XCTest
import Combine
import TelegramCore
@testable import Postbox
import MtProtoKit
import OpenSSLEncryption
import SwiftSignalKit
@testable import MakoshTelegram

/// The real native queues emit these callbacks. Every account/cache is synthetic,
/// encrypted, disposable and routed through a closed loopback proxy.
@MainActor final class TelegramNativeCallbackActorTests: XCTestCase {
    func testNativeSearchSenderMembershipReturnsFromPostbox() async throws {
        let account = try await telegramCallbackAccount(test: self)
        let groupID = try await telegramDataValue(telegramCallbackSeedGroup(account.postbox), test: self)
        let senders = TelegramSearchSenders()
        let received = expectation(description: "Native membership result")
        let observation = senders.$available.filter { $0 }.prefix(1).sink { _ in received.fulfill() }
        defer { observation.cancel(); senders.bind(account: nil, chatID: nil, threadID: nil) }
        senders.bind(account: account, chatID: groupID, threadID: nil)
        await fulfillment(of: [received], timeout: 10)
        XCTAssertTrue(senders.available)
    }

    func testNativeLocalChatSearchHandlesBackgroundEmptyResult() async throws {
        let account = try await telegramCallbackAccount(test: self)
        let search = TelegramSearchModel()
        search.bind(account: account)
        let ready = expectation(description: "Native local search result")
        let observation = search.$chatStatus.filter { $0 == .ready }.prefix(1).sink { _ in ready.fulfill() }
        defer { observation.cancel(); search.bind(account: nil) }
        search.chatQuery = "Synthetic missing peer"
        await fulfillment(of: [ready], timeout: 10)
        XCTAssertTrue(search.chats.isEmpty)
    }

    func testNativeMessageActionValidationRejectsMissingSourceOnMain() async throws {
        let account = try await telegramCallbackAccount(test: self)
        let provider = TelegramEngineMessageActionsProvider(account: account, approval: TelegramSendApprovalController())
        let source = TelegramMessageActionSource(accountID: 123, chatID: 777, peerID: 777,
            namespace: Namespaces.Message.Cloud, messageID: 1, fingerprint: "synthetic-missing", text: "before",
            canReply: true, canEdit: true, canForward: true, canDeleteLocally: true, canDeleteForEveryone: true)
        for action in [TelegramMessageAction.reply("after"), .edit("after"), .delete(forEveryone: false)] {
            let rejected = expectation(description: "Missing native source rejected")
            let lease = provider.start(action: action, source: source) { event in
                guard case .rejected = event else { return XCTFail("Missing source produced an actionable event") }
                XCTAssertTrue(Thread.isMainThread); rejected.fulfill()
            }
            await fulfillment(of: [rejected], timeout: 10)
            lease.cancel()
        }
    }

    func testNativeSecretObservationRejectsMissingSessionOnMain() async throws {
        let account = try await telegramCallbackAccount(test: self)
        let provider = TelegramEngineSecretChatProvider(account: account)
        let received = expectation(description: "Native missing secret session")
        let id = PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(44)).toInt64()
        let request = provider.observeSession(chatID: id) { result in
            guard case .failure(.unavailable) = result else { return XCTFail("Missing secret session was accepted") }
            XCTAssertTrue(Thread.isMainThread); received.fulfill()
        }
        defer { request.cancel() }
        await fulfillment(of: [received], timeout: 10)
    }

    func testNativeProxyTargetAppliesOnActualMTContextQueue() async throws {
        let account = try await telegramCallbackAccount(test: self)
        let target = TelegramEngineProxyTarget(network: account.network, stopped: {})
        var draft = TelegramProxyDraft(); draft.host = "127.0.0.1"; draft.port = "2"
        let server = try TelegramProxyServer(draft: draft)
        var configuration = TelegramProxyConfiguration()
        configuration.servers = [server]; configuration.selected = server.id; configuration.enabled = true
        let applied = expectation(description: "Actual MTContext acknowledgement")
        let request = target.apply(configuration) { value in
            XCTAssertTrue(Thread.isMainThread); XCTAssertTrue(value); applied.fulfill()
        }
        defer { request.cancel() }
        await fulfillment(of: [applied], timeout: 10)
        XCTAssertEqual(account.network.context.apiEnvironment.socksProxySettings?.port, 2)
    }
}

@MainActor func telegramCallbackAccount(test: XCTestCase) async throws -> Account {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-callback-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    test.addTeardownBlock { try FileManager.default.removeItem(at: root) }
    TelegramRuntime.configureLogging(directory: root)
    initializeAccountManagement()
    let opened = try await telegramDataValue(AccountManager<TelegramAccountManagerTypes>.makoshOpen(
        basePath: root.appendingPathComponent("accounts-metadata").path), test: test)
    let manager = try XCTUnwrap(opened)
    _ = try await telegramDataValue(manager.mediaBox.storageBox.all(), test: test)
    _ = try await telegramDataValue(manager.mediaBox.cacheStorageBox.all(), test: test)
    let record = try await telegramDataValue(manager.currentAccountRecord(allocateIfNotExists: true), test: test)
    let id = try XCTUnwrap(record).0
    let arguments = telegramCallbackNetworkArguments()
    let auxiliary = TelegramRuntime.accountAuxiliaryMethods()
    let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 71, count: 32)))
    let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 72, count: 16)))
    let encryption = ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt)
    let unauthorizedResult = try await telegramDataValue(accountWithId(accountManager: manager, networkArguments: arguments,
        id: id, encryptionParameters: encryption, supplementary: false, isSupportUser: false,
        rootPath: root.path, beginWithTestingEnvironment: true, backupData: nil, auxiliaryMethods: auxiliary)
        |> deliverOnMainQueue |> filter { if case .unauthorized = $0 { return true }; return false }, test: test)
    let unauthorized = try XCTUnwrap({ if case let .unauthorized(account) = unauthorizedResult { return account }; return nil }())
    _ = try await telegramDataValue(unauthorized.postbox.mediaBox.storageBox.all(), test: test)
    _ = try await telegramDataValue(unauthorized.postbox.mediaBox.cacheStorageBox.all(), test: test)
    let transitioned = test.expectation(description: "Synthetic authorized callback account")
    var authorized: Account?
    let subscription = (currentAccount(allocateIfNotExists: false, networkArguments: arguments,
        supplementary: false, manager: manager, rootPath: root.path, auxiliaryMethods: auxiliary,
        encryptionParameters: encryption) |> deliverOnMainQueue).start(next: { result in
            if case let .authorized(account) = result { authorized = account; transitioned.fulfill() }
        })
    defer { subscription.dispose(); unauthorized.shouldBeServiceTaskMaster.set(.single(.never)) }
    _ = try await telegramDataValue(telegramCallbackAuthorize(unauthorized.postbox), test: test)
    await test.fulfillment(of: [transitioned], timeout: 10)
    let account = try XCTUnwrap(authorized)
    account.shouldBeServiceTaskMaster.set(.single(.never))
    _ = try await telegramDataValue(telegramCallbackInitializationBarrier(account.postbox), test: test)
    _ = try await telegramDataValue(account.postbox.mediaBox.storageBox.all(), test: test)
    _ = try await telegramDataValue(account.postbox.mediaBox.cacheStorageBox.all(), test: test)
    return account
}

nonisolated func telegramCallbackInitializationBarrier(_ box: Postbox) -> Signal<Bool, NoError> {
    box.transaction { _ in true }
}

private nonisolated func telegramCallbackNetworkArguments() -> NetworkInitializationArguments {
    let server = ProxyServerSettings(host: "127.0.0.1", port: 1, connection: .socks5(username: nil, password: nil))
    let proxy = ProxySettings(enabled: true, servers: [server], activeServer: server, useForCalls: false)
    return NetworkInitializationArguments(apiId: 1, apiHash: String(repeating: "0", count: 32),
        languagesCategory: "macos", appVersion: "Makosh test", voipMaxLayer: 92, voipVersions: [],
        appData: .single(nil), externalRequestVerificationStream: .single([:]),
        externalRecaptchaRequestVerification: { _, _ in .complete() }, autolockDeadine: .single(nil),
        encryptionProvider: OpenSSLEncryptionProvider(), deviceModelName: "Synthetic Mac",
        useBetaFeatures: false, isICloudEnabled: false, makoshProxySettings: .single(proxy))
}

private nonisolated func telegramCallbackAuthorize(_ box: Postbox) -> Signal<Void, NoError> {
    box.transaction { transaction in
        transaction.setState(AuthorizedAccountState(isTestingEnvironment: true, masterDatacenterId: 2,
            peerId: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(123)),
            state: nil, invalidatedChannels: []))
    }
}

private nonisolated func telegramCallbackSeedGroup(_ box: Postbox) -> Signal<Int64, NoError> {
    box.transaction { transaction in
        let id = PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(10))
        let group = TelegramGroup(id: id, title: "Synthetic", photo: [], participantCount: 2,
            role: .creator(rank: nil), membership: .Member, flags: [], defaultBannedRights: nil,
            migrationReference: nil, creationDate: 0, version: 1)
        transaction.updatePeersInternal([group], update: { _, value in value })
        return id.toInt64()
    }
}
