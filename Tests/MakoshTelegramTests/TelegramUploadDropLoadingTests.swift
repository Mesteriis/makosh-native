import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import MakoshApp

@MainActor final class TelegramUploadDropLoadingTests: XCTestCase {
    // Catches a cancelled drag keeping the model alive forever when a provider never completes.
    func testCancellationFinishesWithoutWaitingForTheProviderAndIgnoresLateCompletion() async throws {
        let started = expectation(description: "Provider started"), finished = expectation(description: "Cancelled load completed")
        let callbacks = DropProviderCallbacks(), provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            callbacks.store(completion); started.fulfill()
            return Progress(totalUnitCount: 1)
        }
        let task = Task {
            do { _ = try await TelegramUploadDropLoading.urls([provider]); XCTFail("Cancelled provider cannot succeed") }
            catch { XCTAssertTrue(error is CancellationError) }
            finished.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [finished], timeout: 1)
        callbacks.finish(URL(fileURLWithPath: "/synthetic/late").dataRepresentation, nil)
        _ = await task.result
    }

    // Catches unbounded waiting for a broken external drag provider.
    func testTimeoutReleasesTheLoadAndIgnoresTheLateCallback() async throws {
        let callbacks = DropProviderCallbacks(), provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            callbacks.store(completion); return Progress(totalUnitCount: 1)
        }
        let finished = expectation(description: "Timed out provider completed")
        let task = Task {
            do { _ = try await TelegramUploadDropLoading.urls([provider], timeout: .milliseconds(20)); XCTFail("Broken provider cannot succeed") }
            catch { XCTAssertFalse(error is CancellationError) }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 1)
        callbacks.finish(nil, CocoaError(.fileReadUnknown)); _ = await task.result
    }

    // Catches accepting a partially valid set or reordering independent provider callbacks.
    func testWholeListValidationPreservesOrderAndRejectsRemoteOrOversizedURLData() async throws {
        let first = URL(fileURLWithPath: "/synthetic/a.png"), second = URL(fileURLWithPath: "/synthetic/b.txt")
        func item(_ data: Data) -> NSItemProvider {
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
                completion(data, nil); return nil
            }
            return provider
        }
        let urls = try await TelegramUploadDropLoading.urls([item(first.dataRepresentation), item(second.dataRepresentation)])
        XCTAssertEqual(urls, [first, second])
        for invalid in [Data("https://example.invalid/file.png".utf8),
                        URL(string: "file://remote/path.png")!.dataRepresentation,
                        Data(repeating: 65, count: 65537)] {
            do { _ = try await TelegramUploadDropLoading.urls([item(first.dataRepresentation), item(invalid)]); XCTFail("Invalid set cannot produce partial files") }
            catch { }
        }
    }
}

private final class DropProviderCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Data?, (any Error)?) -> Void)?
    func store(_ value: @escaping @Sendable (Data?, (any Error)?) -> Void) { lock.withLock { callback = value } }
    func finish(_ data: Data?, _ error: (any Error)?) {
        let value = lock.withLock { let value = callback; callback = nil; return value }
        value?(data, error)
    }
}
