import XCTest
import TelegramCore
import SwiftSignalKit
@testable import Postbox

@MainActor func telegramDataValue<T>(_ signal: Signal<T, NoError>, test: XCTestCase) async throws -> T {
    let done = test.expectation(description: "Synthetic data operation")
    var result: T?
    let disposable = (signal |> take(1) |> deliverOnMainQueue).start(next: { result = $0; done.fulfill() })
    defer { disposable.dispose() }
    await test.fulfillment(of: [done], timeout: 20)
    return try XCTUnwrap(result)
}
@MainActor func telegramDataPostbox(test: XCTestCase) async throws -> Postbox {
    initializeAccountManagement()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-data-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    test.addTeardownBlock { try FileManager.default.removeItem(at: root) }
    let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 51, count: 32)))
    let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 52, count: 16)))
    let done = test.expectation(description: "Encrypted synthetic data cache")
    var result: Postbox?
    let disposable = (openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration,
        encryptionParameters: .init(forceEncryptionIfNoSet: true, key: key, salt: salt), timestampForAbsoluteTimeBasedOperations: 1,
        isMainProcess: true, isTemporary: false, isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false)
        |> deliverOnMainQueue).start(next: { if case let .postbox(box) = $0 { result = box; done.fulfill() } })
    defer { disposable.dispose() }
    await test.fulfillment(of: [done], timeout: 20)
    let box = try XCTUnwrap(result)
    _ = try await telegramDataValue(box.mediaBox.storageBox.all(), test: test)
    _ = try await telegramDataValue(box.mediaBox.cacheStorageBox.all(), test: test)
    return box
}
