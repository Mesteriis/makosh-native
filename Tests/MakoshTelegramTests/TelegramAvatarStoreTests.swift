import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import MakoshTelegram

@MainActor final class TelegramAvatarStoreTests: XCTestCase {
    private final class Lease: TelegramAvatarLease {
        var cancellations = 0
        var onCancel: (() -> Void)?
        func cancel() { cancellations += 1; onCancel?() }
    }
    private final class Provider: TelegramAvatarProvider {
        var callbacks: [@MainActor (TelegramAvatarEvent) -> Void] = []
        var leases: [Lease] = []
        var synchronous: [TelegramAvatarEvent] = []
        func start(key: TelegramAvatarKey, receive: @escaping @MainActor (TelegramAvatarEvent) -> Void) -> any TelegramAvatarLease {
            callbacks.append(receive); let lease = Lease(); leases.append(lease)
            for event in synchronous { receive(event) }
            return lease
        }
    }
    private func png(width: Int = 640, height: Int = 640) throws -> (URL, Int64) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("photo")
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        context.setFillColor(gray: 0.5, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil); XCTAssertTrue(CGImageDestinationFinalize(output))
        return (url, Int64(try Data(contentsOf: url).count))
    }
    func testSynchronousResourceAndDataDecodeThenConsumerCancellationReleasesLease() async throws {
        let (url, bytes) = try png()
        let store = TelegramAvatarStore(), provider = Provider()
        provider.synchronous = [.resource("photo"), .data(resourceID: "photo", url: url, size: bytes)]
        store.bind(provider)
        let stream = store.images(for: TelegramAvatarKey(peerID: 42))
        let ready = expectation(description: "Bounded thumbnail decoded")
        let consumer = Task {
            for await image in stream {
                if let image { XCTAssertEqual(image.image.width, 128); ready.fulfill() }
            }
        }
        await fulfillment(of: [ready], timeout: 5)
        let released = expectation(description: "Consumer cancellation releases native observation")
        provider.leases[0].onCancel = { released.fulfill() }
        consumer.cancel()
        await fulfillment(of: [released], timeout: 5)
        XCTAssertEqual(provider.leases[0].cancellations, 1)
    }
    func testPhotoReplacementRejectsOldDataAndInFlightDecode() async throws {
        let old = try png(), current = try png(width: 40, height: 40)
        let store = TelegramAvatarStore(), provider = Provider(); store.bind(provider)
        let stream = store.images(for: TelegramAvatarKey(peerID: 42))
        let ready = expectation(description: "Only replacement photo published")
        let consumer = Task {
            for await image in stream {
                if let image { XCTAssertEqual(image.image.width, 40); ready.fulfill() }
            }
        }
        defer { consumer.cancel() }
        let callback = provider.callbacks[0]
        callback(.resource("old")); callback(.data(resourceID: "old", url: old.0, size: old.1))
        callback(.resource("new")); callback(.data(resourceID: "old", url: old.0, size: old.1))
        callback(.data(resourceID: "new", url: current.0, size: current.1))
        await fulfillment(of: [ready], timeout: 5)
        store.bind(nil)
    }
    func testAccountRebindFinishesOldStreamAndRejectsLateEventsForSamePeer() async throws {
        let old = try png(), current = try png(width: 40, height: 40)
        let store = TelegramAvatarStore(), first = Provider(), second = Provider(); store.bind(first)
        let oldContext = store.contextID
        let stream = store.images(for: TelegramAvatarKey(peerID: 42))
        let stopped = expectation(description: "Old account stream finishes")
        let oldConsumer = Task { for await image in stream { XCTAssertNil(image) }; stopped.fulfill() }
        first.callbacks[0](.resource("old")); first.callbacks[0](.data(resourceID: "old", url: old.0, size: old.1))
        store.bind(second); XCTAssertNotEqual(store.contextID, oldContext)
        await fulfillment(of: [stopped], timeout: 5); oldConsumer.cancel()
        XCTAssertEqual(first.leases[0].cancellations, 1)
        let newStream = store.images(for: TelegramAvatarKey(peerID: 42))
        let ready = expectation(description: "New account image only")
        let consumer = Task { for await image in newStream { if let image { XCTAssertEqual(image.image.width, 40); ready.fulfill() } } }
        defer { consumer.cancel(); store.bind(nil) }
        first.callbacks[0](.resource("old")); first.callbacks[0](.data(resourceID: "old", url: old.0, size: old.1))
        second.callbacks[0](.resource("new")); second.callbacks[0](.data(resourceID: "new", url: current.0, size: current.1))
        await fulfillment(of: [ready], timeout: 5)
    }
    func testFailureRejectsLateDataAndNewPhotoRecovers() async throws {
        let old = try png(), current = try png(width: 40, height: 40)
        let store = TelegramAvatarStore(), provider = Provider(); store.bind(provider)
        let stream = store.images(for: TelegramAvatarKey(peerID: 42))
        let ready = expectation(description: "Recovered photo only")
        let consumer = Task { for await image in stream { if let image { XCTAssertEqual(image.image.width, 40); ready.fulfill() } } }
        defer { consumer.cancel(); store.bind(nil) }
        let callback = provider.callbacks[0]
        callback(.resource("old")); callback(.failed(resourceID: "old"))
        callback(.data(resourceID: "old", url: old.0, size: old.1))
        callback(.resource("new")); callback(.data(resourceID: "new", url: current.0, size: current.1))
        await fulfillment(of: [ready], timeout: 5)
    }
    func testAvatarDecoderBoundsBytesPixelsAndRejectsSymlinksCorruptDataAndCancellation() async throws {
        let (url, bytes) = try png()
        let decoded = try await TelegramAvatarFileIO.image(source: url, expectedSize: bytes, size: .large)
        XCTAssertEqual(decoded.image.width, 512)
        for (path, size) in [(url, Int64(2 * 1_024 * 1_024 + 1)), (url, bytes + 1)] {
            do { _ = try await TelegramAvatarFileIO.image(source: path, expectedSize: size, size: .small); XCTFail("Invalid size accepted") } catch { }
        }
        let link = url.deletingLastPathComponent().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        do { _ = try await TelegramAvatarFileIO.image(source: link, expectedSize: bytes, size: .small); XCTFail("Symlink accepted") } catch { }
        let corrupt = url.deletingLastPathComponent().appendingPathComponent("corrupt")
        try Data([1, 2, 3]).write(to: corrupt)
        do { _ = try await TelegramAvatarFileIO.image(source: corrupt, expectedSize: 3, size: .small); XCTFail("Corrupt image accepted") } catch { }
        let large = try png(width: 4_097, height: 1)
        do { _ = try await TelegramAvatarFileIO.image(source: large.0, expectedSize: large.1, size: .small); XCTFail("Pixel limit ignored") } catch { }
        let operation = Task { try await TelegramAvatarFileIO.image(source: url, expectedSize: bytes, size: .small) }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled decode accepted") } catch is CancellationError { }
    }
}
