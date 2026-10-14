import XCTest
import TelegramCore
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
        let model = try modelFixture()
        defer { model.disconnect() }
        model.observeUnauthorized(account, token: UUID())
        let active = try await keepsConnection(account)
        XCTAssertTrue(active)
    }

    func testDisconnectStopsTheNativeUnauthorizedConnection() async throws {
        let account = try await fixture().account
        let model = try modelFixture()
        model.observeUnauthorized(account, token: UUID())
        let active = try await keepsConnection(account)
        XCTAssertTrue(active)
        model.disconnect()
        let stopped = try await keepsConnection(account)
        XCTAssertFalse(stopped)
    }

    func testReplacingLoginStopsOldNetworkAndResumesNewNetwork() async throws {
        let old = try await fixture().account, next = try await fixture().account
        let model = try modelFixture()
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
        var model: TelegramModel? = try modelFixture()
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
        XCTAssertEqual(account.peerId.toInt64(), 123)
        let persisted = try await telegramDataValue(account.postbox.stateView(), test: self)
        XCTAssertTrue(persisted.state is AuthorizedAccountState)
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

    private func modelFixture() throws -> TelegramModel {
        let store = TelegramProxyTestStore()
        let proxy = TelegramProxyController(vault: store.vault())
        let name = "makosh-auth-network-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let model = TelegramModel(proxy: proxy, autoDownloadDefaults: defaults)
        _ = try proxy.settingsForConnection(clientID: model.proxyClientID)
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
        let auxiliary = AccountAuxiliaryMethods(fetchResource: { _, _, _, _ in nil },
            fetchResourceMediaReferenceHash: { _ in .single(nil) }, prepareSecretThumbnailData: { _ in nil },
            backgroundUpload: { _, _, _ in .single(nil) })
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
