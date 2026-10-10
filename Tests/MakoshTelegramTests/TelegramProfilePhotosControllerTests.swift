import XCTest
import Combine
import CoreGraphics
import ImageIO
@testable import MakoshTelegram

@MainActor final class TelegramProfilePhotosControllerTests: XCTestCase {
    private final class Lease: TelegramAvatarLease {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    private final class Session: TelegramProfilePhotoSession {
        var cancelled = false
        var callbacks: [@MainActor (TelegramProfilePhotoImageEvent) -> Void] = []
        var leases: [Lease] = []
        var imageIDs: [String] = []
        func image(photoID: String, receive: @escaping @MainActor (TelegramProfilePhotoImageEvent) -> Void) -> any TelegramAvatarLease {
            imageIDs.append(photoID); callbacks.append(receive)
            let lease = Lease(); leases.append(lease); return lease
        }
        var thumbnailCallbacks: [String: @MainActor (TelegramProfilePhotoImageEvent) -> Void] = [:]
        var thumbnailLeases: [String: Lease] = [:]
        func thumbnail(photoID: String, receive: @escaping @MainActor (TelegramProfilePhotoImageEvent) -> Void) -> any TelegramAvatarLease {
            let lease = Lease(); thumbnailCallbacks[photoID] = receive; thumbnailLeases[photoID] = lease; return lease
        }
        func cancel() { cancelled = true; for lease in leases { lease.cancel() }; for lease in thumbnailLeases.values { lease.cancel() } }
    }
    private final class Provider: TelegramProfilePhotoProvider {
        var callbacks: [@MainActor ([TelegramProfilePhoto]) -> Void] = []
        var sessions: [Session] = []
        var synchronous: [TelegramProfilePhoto]?
        func load(peerID: Int64, receive: @escaping @MainActor ([TelegramProfilePhoto]) -> Void) -> any TelegramProfilePhotoSession {
            let session = Session(); sessions.append(session); callbacks.append(receive)
            if let synchronous { receive(synchronous) }
            return session
        }
    }
    private func photos() -> [TelegramProfilePhoto] {
        [TelegramProfilePhoto(id: "first", date: 100, totalCount: 5, hasVideo: false),
         TelegramProfilePhoto(id: "second", date: 200, totalCount: 5, hasVideo: true)]
    }
    private func png(width: Int = 40) throws -> (URL, Int64) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("image")
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: 40, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        context.setFillColor(gray: 0.5, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: 40))
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(output, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        return (url, Int64(try Data(contentsOf: url).count))
    }
    private func waitForImage(_ controller: TelegramProfilePhotosController, width: Int,
                              action: () -> Void) async {
        let ready = expectation(description: "Selected gallery image decoded")
        let sink = controller.$image.compactMap { $0 }.sink { image in
            XCTAssertEqual(image.image.width, width); ready.fulfill()
        }
        action(); await fulfillment(of: [ready], timeout: 5); sink.cancel()
    }
    func testSynchronousListStartsImageAfterSessionReturnsAndNavigationBoundsHold() async throws {
        let controller = TelegramProfilePhotosController(), provider = Provider()
        provider.synchronous = photos(); controller.bind(provider); controller.open(peerID: 42)
        let session = provider.sessions[0]
        XCTAssertEqual(controller.state, .ready); XCTAssertEqual(session.imageIDs, ["first"])
        XCTAssertFalse(controller.canGoBack); XCTAssertTrue(controller.canGoForward)
        controller.move(by: -1); controller.move(by: Int.max); XCTAssertEqual(session.imageIDs, ["first"])
        let file = try png()
        await waitForImage(controller, width: 40) { session.callbacks[0](.data(url: file.0, size: file.1)) }
        controller.move(by: 1)
        XCTAssertNil(controller.image); XCTAssertTrue(session.leases[0].cancelled)
        XCTAssertEqual(controller.selectedPhoto?.id, "second"); XCTAssertTrue(controller.selectedPhoto?.hasVideo == true)
        controller.move(by: 1); XCTAssertEqual(session.imageIDs, ["first", "second"])
        controller.close(); XCTAssertTrue(session.cancelled); XCTAssertEqual(controller.state, .idle)
    }
    func testOldSelectedImageDataAndDecodeCannotReplaceNewSelection() async throws {
        let controller = TelegramProfilePhotosController(), provider = Provider()
        provider.synchronous = photos(); controller.bind(provider); controller.open(peerID: 42)
        let session = provider.sessions[0], old = try png(width: 100), current = try png()
        session.callbacks[0](.data(url: old.0, size: old.1)); controller.move(by: 1)
        await waitForImage(controller, width: 40) {
            session.callbacks[0](.data(url: old.0, size: old.1))
            session.callbacks[0](.failed)
            session.callbacks[1](.data(url: current.0, size: current.1))
        }
        session.callbacks[1](.failed); XCTAssertNotNil(controller.image)
        controller.close()
    }
    func testRebindSamePeerCancelsOldSessionAndRejectsLateListsAndImageEvents() async throws {
        let controller = TelegramProfilePhotosController(), old = Provider(), current = Provider()
        controller.bind(old); controller.open(peerID: 42); old.callbacks[0](photos())
        controller.bind(current); XCTAssertTrue(old.sessions[0].cancelled)
        controller.open(peerID: 42)
        old.callbacks[0](photos()); old.sessions[0].callbacks[0](.failed)
        XCTAssertEqual(controller.state, .loading); XCTAssertNil(controller.imageError)
        current.callbacks[0](photos()); XCTAssertEqual(controller.state, .ready)
        controller.close(); current.callbacks[0](photos()); XCTAssertEqual(controller.state, .idle)
    }
    func testEmptyAndInvalidListsRemainUnavailableAndRetryOwnsNewSession() {
        let controller = TelegramProfilePhotosController(), provider = Provider()
        controller.bind(provider); controller.open(peerID: 42); provider.callbacks[0]([])
        XCTAssertEqual(controller.state, .unavailable); XCTAssertTrue(provider.sessions[0].cancelled)
        controller.retry(); XCTAssertEqual(controller.state, .loading)
        provider.callbacks[0](photos()); XCTAssertEqual(controller.state, .loading)
        provider.callbacks[1]([photos()[0], photos()[0]])
        XCTAssertEqual(controller.state, .unavailable); XCTAssertTrue(provider.sessions[1].cancelled)
        controller.retry(); provider.callbacks[2](photos()); XCTAssertEqual(controller.state, .ready)
        controller.close()
    }
    func testCorruptImageFailsAndRetryRecoversWithoutChangingSelectedPhoto() async throws {
        let controller = TelegramProfilePhotosController(), provider = Provider()
        provider.synchronous = photos(); controller.bind(provider); controller.open(peerID: 42)
        let session = provider.sessions[0], file = try png()
        let corrupt = file.0.deletingLastPathComponent().appendingPathComponent("corrupt")
        try Data([1, 2, 3]).write(to: corrupt)
        let failed = expectation(description: "Corrupt gallery image rejected")
        let sink = controller.$imageError.compactMap { $0 }.sink { _ in failed.fulfill() }
        session.callbacks[0](.data(url: corrupt, size: 3))
        await fulfillment(of: [failed], timeout: 5); sink.cancel()
        XCTAssertFalse(controller.imageLoading); XCTAssertNil(controller.image)
        XCTAssertTrue(session.leases[0].cancelled)
        controller.retryImage(); XCTAssertEqual(controller.selectedPhoto?.id, "first")
        await waitForImage(controller, width: 40) { session.callbacks[1](.data(url: file.0, size: file.1)) }
        XCTAssertNil(controller.imageError); controller.close()
    }
    func testModelGalleryOpeningRequiresExactCurrentProfileAndClosesOnChatChange() throws {
        let model = TelegramModel.syntheticPeerAppearancePreview()
        model.selectedChatID = 10_001; model.loadContactProfile()
        guard case let .ready(profile) = model.contactProfileState else { return XCTFail("Synthetic profile unavailable") }
        XCTAssertFalse(model.openProfilePhotos(profile, contextID: UUID()))
        XCTAssertTrue(model.openProfilePhotos(profile, contextID: model.contactProfileContextID))
        XCTAssertEqual(model.profilePhotos.state, .ready)
        model.selectedChatID = 10_002
        XCTAssertEqual(model.profilePhotos.state, .idle)
        XCTAssertFalse(model.openProfilePhotos(profile, contextID: model.contactProfileContextID))
    }
    func testThumbnailsIndependentSelectionAndExactOriginalSave() async throws {
        let controller = TelegramProfilePhotosController(), provider = Provider()
        provider.synchronous = photos(); controller.bind(provider); controller.open(peerID: 42)
        let session = provider.sessions[0], file = try png(width: 90)
        controller.requestThumbnail(photoID: "second")
        XCTAssertFalse(session.leases[0].cancelled)
        let thumbnail = expectation(description: "Independent thumbnail")
        let sink = controller.$thumbnails.sink { if $0["second"] != nil { thumbnail.fulfill() } }
        session.thumbnailCallbacks["second"]?(.data(url: file.0, size: file.1))
        await fulfillment(of: [thumbnail], timeout: 5); sink.cancel()
        await waitForImage(controller, width: 90) { session.callbacks[0](.data(url: file.0, size: file.1)) }
        XCTAssertEqual(controller.suggestedFileName, "photo.png")
        let destination = file.0.deletingLastPathComponent().appendingPathComponent("saved.png")
        try await controller.save(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: file.0))
        controller.releaseThumbnail(photoID: "second")
        XCTAssertTrue(session.thumbnailLeases["second"]!.cancelled)
        XCTAssertNil(controller.thumbnails["second"])
        controller.select(photoID: "second"); XCTAssertEqual(controller.selectedPhoto?.id, "second")
        controller.close()
        session.thumbnailCallbacks["second"]?(.data(url: file.0, size: file.1))
        XCTAssertTrue(controller.thumbnails.isEmpty); XCTAssertNil(controller.image)
    }

    func testReleasedAndReboundThumbnailsRejectLateEvents() async throws {
        let controller = TelegramProfilePhotosController(), provider = Provider()
        provider.synchronous = photos(); controller.bind(provider); controller.open(peerID: 42)
        let session = provider.sessions[0], file = try png()
        controller.requestThumbnail(photoID: "second")
        let stale = try XCTUnwrap(session.thumbnailCallbacks["second"])
        controller.releaseThumbnail(photoID: "second")
        stale(.data(url: file.0, size: file.1))
        controller.requestThumbnail(photoID: "second")
        controller.bind(Provider())
        session.thumbnailCallbacks["second"]?(.data(url: file.0, size: file.1))
        await Task.yield()
        XCTAssertTrue(controller.thumbnails.isEmpty)
        XCTAssertTrue(session.cancelled)
    }
    func testSaveRejectsSameSizeCacheMutationAndPreservesDestination() async throws {
        let controller = TelegramProfilePhotosController(), provider = Provider()
        provider.synchronous = photos(); controller.bind(provider); controller.open(peerID: 42)
        let file = try png(), session = provider.sessions[0]
        await waitForImage(controller, width: 40) { session.callbacks[0](.data(url: file.0, size: file.1)) }
        let destination = file.0.deletingLastPathComponent().appendingPathComponent("existing")
        let sentinel = Data("existing destination".utf8); try sentinel.write(to: destination)
        var changed = try Data(contentsOf: file.0); changed[changed.count - 1] ^= 1
        try changed.write(to: file.0)
        do { try await controller.save(to: destination); XCTFail("Changed cache must not export") } catch { }
        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
        XCTAssertFalse(controller.isSaving)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
            .contains(where: { $0.hasPrefix(".makosh-export-") }))
    }

    func testListReplacementAndInvalidationClearReadyThumbnailsAndLeases() async throws {
        for invalid in [false, true] {
            let controller = TelegramProfilePhotosController(), provider = Provider()
            provider.synchronous = photos(); controller.bind(provider); controller.open(peerID: 42)
            let session = provider.sessions[0], file = try png()
            controller.requestThumbnail(photoID: "second")
            let ready = expectation(description: "Thumbnail ready before list changes")
            let sink = controller.$thumbnails.sink { if $0["second"] != nil { ready.fulfill() } }
            session.thumbnailCallbacks["second"]?(.data(url: file.0, size: file.1))
            await fulfillment(of: [ready], timeout: 5); sink.cancel()
            // A delayed error cannot discard an already decoded thumbnail.
            session.thumbnailCallbacks["second"]?(.failed)
            XCTAssertNotNil(controller.thumbnails["second"])
            let oldLease = try XCTUnwrap(session.thumbnailLeases["second"])
            provider.callbacks[0](invalid ? [] : [TelegramProfilePhoto(id: "replacement", date: 0, totalCount: 1, hasVideo: false)])
            XCTAssertTrue(oldLease.cancelled); XCTAssertTrue(controller.thumbnails.isEmpty)
            XCTAssertEqual(controller.state, invalid ? .unavailable : .ready)
            session.thumbnailCallbacks["second"]?(.data(url: file.0, size: file.1))
            XCTAssertTrue(controller.thumbnails.isEmpty)
            controller.close()
        }
    }

}
