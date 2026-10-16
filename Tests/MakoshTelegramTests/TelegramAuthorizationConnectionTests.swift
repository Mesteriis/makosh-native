import XCTest
@testable import TelegramCore
import Postbox
import SwiftSignalKit
import OpenSSLEncryption
@testable import MakoshTelegram

@MainActor final class TelegramAuthorizationConnectionTests: XCTestCase {
    func testRejectedProxyAdmissionNeverResumesLoginNetwork() async throws {
        let account = try await fixture().account
        let store = TelegramProxyTestStore()
        let model = TelegramModel(proxy: TelegramProxyController(vault: store.vault()))
        model.observeUnauthorized(account, token: UUID())
        let active = try await keepsConnection(account)
        XCTAssertFalse(active)
        XCTAssertEqual(model.phase, .configuration)
        XCTAssertEqual(model.qrLogin.phase, .idle)
    }

    func testOpeningLoginResumesTheNativeUnauthorizedConnection() async throws {
        let account = try await fixture().account
        let model = try await modelFixture()
        defer { model.disconnect() }
        model.observeUnauthorized(account, token: UUID())
        let active = try await keepsConnection(account)
        XCTAssertTrue(active)
    }

    func testDisconnectStopsTheNativeUnauthorizedConnection() async throws {
        let account = try await fixture().account
        let model = try await modelFixture()
        model.observeUnauthorized(account, token: UUID())
        let active = try await keepsConnection(account)
        XCTAssertTrue(active)
        model.disconnect()
        let stopped = try await keepsConnection(account)
        XCTAssertFalse(stopped)
    }

    func testReplacingLoginStopsOldNetworkAndResumesNewNetwork() async throws {
        let old = try await fixture().account, next = try await fixture().account
        let model = try await modelFixture()
        defer { model.disconnect() }
        model.observeUnauthorized(old, token: UUID())
        let oldActive = try await keepsConnection(old)
        XCTAssertTrue(oldActive)
        // Native datacenter migration initially inherits the old mode source.
        next.shouldBeServiceTaskMaster.set(old.shouldBeServiceTaskMaster.get())
        model.observeUnauthorized(next, token: UUID())
        let oldStopped = try await keepsConnection(old)
        XCTAssertFalse(oldStopped)
        let nextActive = try await keepsConnection(next)
        XCTAssertTrue(nextActive)
    }

    func testModelReleaseStopsTheNativeUnauthorizedConnection() async throws {
        let account = try await fixture().account
        var model: TelegramModel? = try await modelFixture()
        model?.observeUnauthorized(account, token: UUID())
        let active = try await keepsConnection(account)
        XCTAssertTrue(active)
        weak let released = model
        model = nil
        XCTAssertNil(released)
        let stopped = try await keepsConnection(account)
        XCTAssertFalse(stopped)
    }

    private func keepsConnection(_ account: UnauthorizedAccount) async throws -> Bool {
        try await telegramDataValue(account.network.shouldKeepConnection.get()
            |> timeout(1, queue: .mainQueue(), alternate: .single(false)), test: self)
    }

    func testAuthorizationTransitionReopensOnlyAfterTheStateTransactionCommits() async throws {
        let account = try await authorizedFixture()
        XCTAssertEqual(account.peerId.toInt64(), 123)
        let persisted = try await telegramDataValue(account.postbox.stateView(), test: self)
        XCTAssertTrue(persisted.state is AuthorizedAccountState)
    }

    func testAuthorizedStartupOrdersNativeStateOperationsAfterInitialSync() async throws {
        let account = try await authorizedFixture(), model = try await modelFixture()
        defer { model.disconnect() }
        model.observeAuthorized(account, token: model.generation)
        let premature = expectation(description: "State operation must wait for initial server cursor")
        premature.isInverted = true
        let operation = (Self.nativeStateBarrier(account) |> deliverOnMainQueue).start(next: { _ in premature.fulfill() })
        defer { operation.dispose() }
        await fulfillment(of: [premature], timeout: 0.5)
        let stored = try await telegramDataValue(account.postbox.stateView(), test: self)
        XCTAssertNil((stored.state as? AuthorizedAccountState)?.state)
        XCTAssertEqual(model.phase, .ready)
    }

    func testAuthorizedStartupQueuesUpdateGroupsBeforeInitialCursor() async throws {
        let account = try await authorizedFixture(), model = try await modelFixture()
        defer { model.disconnect() }
        model.observeAuthorized(account, token: model.generation)
        Self.injectInitialUpdateGroup(account)
        let premature = expectation(description: "Queued updates must wait for initial server cursor")
        premature.isInverted = true
        let operation = (Self.nativeStateBarrier(account) |> deliverOnMainQueue).start(next: { _ in premature.fulfill() })
        defer { operation.dispose() }
        await fulfillment(of: [premature], timeout: 0.5)
        let stored = try await telegramDataValue(account.postbox.stateView(), test: self)
        XCTAssertNil((stored.state as? AuthorizedAccountState)?.state)
    }

    nonisolated private static func nativeStateBarrier(_ account: Account) -> Signal<Bool, NoError> {
        account.stateManager.addCustomOperation(.single(true))
    }

    nonisolated private static func injectInitialUpdateGroup(_ account: Account) {
        account.stateManager.addUpdateGroups([.reset])
    }

    func testNativeIncomingCallObservationAcceptsTheBackgroundInitialSnapshot() async throws {
        let account = try await authorizedFixture()
        let engine = TelegramAccountCallEngine(account: account)
        let received = expectation(description: "Native empty incoming-call snapshot")
        let subscription = (engine.incoming() |> take(1) |> deliverOnMainQueue).start(next: { calls in
            XCTAssertTrue(calls.isEmpty); received.fulfill()
        }, error: { _ in XCTFail("Native empty incoming-call observation failed"); received.fulfill() })
        defer { subscription.dispose() }
        await fulfillment(of: [received], timeout: 10)
    }

    func testNativeMissingCallPeerFailsWithoutActorViolationOrNetworkRequest() async throws {
        let account = try await authorizedFixture()
        let engine = TelegramAccountCallEngine(account: account)
        let refused = expectation(description: "Missing synthetic call peer")
        let subscription = (engine.peer(777) |> deliverOnMainQueue).start(next: { _ in
            XCTFail("Missing peer unexpectedly admitted"); refused.fulfill()
        }, error: { error in XCTAssertEqual(error, .unavailable); refused.fulfill() })
        defer { subscription.dispose() }
        await fulfillment(of: [refused], timeout: 10)
    }

    func testNativeNotificationBindingReceivesBackgroundUnreadCounters() async throws {
        let account = try await authorizedFixture()
        let name = "makosh-native-notifications-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = TelegramNotificationController(defaults: defaults)
        controller.bind(account: account)
        defer { controller.bind(account: nil) }
        let received = expectation(description: "Native initial unread counters")
        let observation = controller.$badgeCount.dropFirst().prefix(1).sink { count in
            XCTAssertEqual(count, 0); received.fulfill()
        }
        defer { observation.cancel() }
        await fulfillment(of: [received], timeout: 10)
        XCTAssertNil(controller.delivery)
        XCTAssertEqual(controller.accountID, 123)
    }

    func testNativeMediaBoxFetchFallsBackToTheLocalResourceFetcher() async throws {
        let account = try await authorizedFixture()
        setupAccount(account)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-native-fetch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.bin")
        let bytes = Data("Synthetic native resource fallback".utf8)
        try bytes.write(to: file)
        let resource = LocalFileReferenceMediaResource(localFilePath: file.path, randomId: 777, size: Int64(bytes.count))
        let subscription = (account.postbox.mediaBox.fetchedResource(resource, parameters: nil, implNext: true)
            |> deliverOnMainQueue).start(error: { _ in XCTFail("Native local fetch failed") })
        defer { subscription.dispose() }
        let cached = try await telegramDataValue(account.postbox.mediaBox.resourceData(resource,
            pathExtension: nil, option: .complete(waitUntilFetchStatus: false))
            |> deliverOnMainQueue |> filter { $0.complete }, test: self)
        XCTAssertTrue(cached.complete)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: cached.path)), bytes)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testOtherNativeAuxiliaryCallbacksRunOnTheEngineQueue() async throws {
        let account = try await authorizedFixture()
        let returned = expectation(description: "Native auxiliary callbacks")
        returned.expectedFulfillmentCount = 3
        Self.probeAuxiliary(account: account, returned: returned)
        await fulfillment(of: [returned], timeout: 10)
    }

    func testNetworkVerificationAndForcedNoticeCallbacksRunOffMain() async throws {
        let config = try TelegramAPIConfiguration(id: "1", hash: String(repeating: "0", count: 32))
        let arguments = TelegramRuntime.networkArguments(configuration: config, proxySettings: .single(.defaultSettings))
        let returned = expectation(description: "Native verification callbacks")
        returned.expectedFulfillmentCount = 2
        Self.probeVerification(arguments: arguments, returned: returned)
        await fulfillment(of: [returned], timeout: 10)
    }

    nonisolated private static func probeAuxiliary(account: Account, returned: XCTestExpectation) {
        Queue.concurrentDefaultQueue().async {
            let methods = account.auxiliaryMethods
            XCTAssertNil(methods.prepareSecretThumbnailData(MediaResourceData(path: "/synthetic-unused", offset: 0, size: 0, complete: false)))
            returned.fulfill()
            _ = methods.fetchResourceMediaReferenceHash(EmptyMediaResource()).start(next: { hash in
                XCTAssertNil(hash); returned.fulfill()
            })
            _ = methods.backgroundUpload(account.postbox, account.network, EmptyMediaResource()).start(next: { value in
                XCTAssertNil(value); returned.fulfill()
            })
        }
    }

    nonisolated private static func probeVerification(arguments: NetworkInitializationArguments, returned: XCTestExpectation) {
        Queue.concurrentDefaultQueue().async {
            XCTAssertNil(TelegramRuntime.forcedPasswordSetupNotice(7)); returned.fulfill()
            _ = arguments.externalRecaptchaRequestVerification("synthetic", "synthetic").start(next: { _ in
                XCTFail("Unsupported verification unexpectedly produced a token")
            }, completed: { returned.fulfill() })
        }
    }

    func testNativeAuthorizedModelStartupObservesEmptyCacheAndDisconnects() async throws {
        let account = try await authorizedFixture()
        let model = try await modelFixture()
        defer { model.disconnect() }
        model.observeAuthorized(account, token: model.generation)
        XCTAssertEqual(model.phase, .ready)
        // The empty native cache still contains a server-history hole. Wait
        // for its first view; completing remote synchronization is unrelated
        // to startup and deliberately unavailable through the closed proxy.
        let loaded = expectation(description: "Native synthetic chat cache view")
        let observation = model.$chatPage.dropFirst().prefix(1).sink { _ in loaded.fulfill() }
        defer { observation.cancel() }
        await fulfillment(of: [loaded], timeout: 10)
        XCTAssertTrue(model.chats.isEmpty)
        model.disconnect()
        XCTAssertEqual(model.phase, .configuration)
        let active = try await telegramDataValue(account.network.shouldKeepConnection.get(), test: self)
        XCTAssertFalse(active)
    }

    private func authorizedFixture() async throws -> Account {
        let fixture = try await fixture()
        let opened = expectation(description: "Synthetic unauthorized account")
        let transitioned = expectation(description: "Synthetic authorized account")
        var original: UnauthorizedAccount?, authorized: Account?
        let subscription = (fixture.current |> deliverOnMainQueue).start(next: { result in
            switch result {
            case let .unauthorized(account): original = account; opened.fulfill()
            case let .authorized(account): authorized = account; transitioned.fulfill()
            default: break
            }
        })
        defer {
            subscription.dispose()
            authorized?.shouldBeServiceTaskMaster.set(.single(.never))
            original?.shouldBeServiceTaskMaster.set(.single(.never))
        }
        await fulfillment(of: [opened], timeout: 10)
        let postbox = try XCTUnwrap(original).postbox
        _ = try await telegramDataValue(postbox.transaction(Self.authorizeFixture), test: self)
        await fulfillment(of: [transitioned], timeout: 10)
        let account = try XCTUnwrap(authorized)
        XCTAssertEqual(account.id, fixture.account.id)
        // Authorization opens a new Postbox/MediaBox. Account.init queues the
        // notification-key file write before exposing the account. Finish that
        // transaction and lazy storage initialization before fast tests can
        // remove their fixture directory.
        _ = try await telegramDataValue(telegramCallbackInitializationBarrier(account.postbox), test: self)
        _ = try await telegramDataValue(account.postbox.mediaBox.storageBox.all(), test: self)
        _ = try await telegramDataValue(account.postbox.mediaBox.cacheStorageBox.all(), test: self)
        return account
    }

    nonisolated private static func authorizeFixture(_ transaction: Transaction) {
        transaction.setState(AuthorizedAccountState(isTestingEnvironment: true, masterDatacenterId: 2,
            peerId: PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(123)),
            state: nil, invalidatedChannels: []))
    }

    private struct Fixture {
        let account: UnauthorizedAccount
        let current: Signal<AccountResult?, NoError>
    }

    private func modelFixture() async throws -> TelegramModel {
        let store = TelegramProxyTestStore()
        let proxy = TelegramProxyController(vault: store.vault())
        let name = "makosh-auth-network-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let model = TelegramModel(proxy: proxy, autoDownloadDefaults: defaults)
        _ = try await proxy.settingsForConnection(clientID: model.proxyClientID)
        return model
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-auth-network-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        TelegramRuntime.configureLogging(directory: root)
        initializeAccountManagement()
        let opened = try await telegramDataValue(AccountManager<TelegramAccountManagerTypes>.makoshOpen(
            basePath: root.appendingPathComponent("accounts-metadata").path), test: self)
        let manager = try XCTUnwrap(opened)
        _ = try await telegramDataValue(manager.mediaBox.storageBox.all(), test: self)
        _ = try await telegramDataValue(manager.mediaBox.cacheStorageBox.all(), test: self)
        let record = try await telegramDataValue(manager.currentAccountRecord(allocateIfNotExists: true), test: self)
        let id = try XCTUnwrap(record).0
        let server = ProxyServerSettings(host: "127.0.0.1", port: 1, connection: .socks5(username: nil, password: nil))
        let proxy = ProxySettings(enabled: true, servers: [server], activeServer: server, useForCalls: false)
        // Synthetic API values and a closed loopback proxy: no real login request.
        let arguments = NetworkInitializationArguments(apiId: 1, apiHash: String(repeating: "0", count: 32),
            languagesCategory: "macos", appVersion: "Makosh test", voipMaxLayer: 92, voipVersions: [],
            appData: .single(nil), externalRequestVerificationStream: .single([:]),
            externalRecaptchaRequestVerification: { _, _ in .complete() }, autolockDeadine: .single(nil),
            encryptionProvider: OpenSSLEncryptionProvider(), deviceModelName: "Synthetic Mac",
            useBetaFeatures: false, isICloudEnabled: false, makoshProxySettings: .single(proxy))
        let auxiliary = TelegramRuntime.accountAuxiliaryMethods()
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 61, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 62, count: 16)))
        let encryption = ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt)
        let result = try await telegramDataValue(accountWithId(accountManager: manager, networkArguments: arguments,
            id: id, encryptionParameters: encryption,
            supplementary: false, isSupportUser: false, rootPath: root.path, beginWithTestingEnvironment: true,
            backupData: nil, auxiliaryMethods: auxiliary) |> deliverOnMainQueue
            |> filter { if case .unauthorized = $0 { return true }; return false }, test: self)
        let account = try XCTUnwrap({ if case let .unauthorized(account) = result { return account }; return nil }())
        // Finish lazy storage initialization before the fixture directory is removed.
        _ = try await telegramDataValue(account.postbox.mediaBox.storageBox.all(), test: self)
        _ = try await telegramDataValue(account.postbox.mediaBox.cacheStorageBox.all(), test: self)
        return Fixture(account: account, current: currentAccount(allocateIfNotExists: false, networkArguments: arguments,
            supplementary: false, manager: manager, rootPath: root.path, auxiliaryMethods: auxiliary, encryptionParameters: encryption))
    }
}
