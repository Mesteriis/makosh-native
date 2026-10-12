import XCTest
import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import AVFoundation
import AppKit
import SwiftUI
@testable import MakoshTelegram
@testable import MakoshApp

@MainActor final class TelegramUploadDocumentPreviewTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func stage(_ data: Data, name: String, metadata: TelegramUploadMetadata? = nil) async throws -> TelegramUploadFile {
        let source = try directory().appendingPathComponent(name)
        try data.write(to: source)
        let raw = try await TelegramUploadFileIO.stage(source, mode: .file)
        addTeardownBlock { try TelegramUploadFileIO.discard(raw) }
        try FileManager.default.removeItem(at: source)
        return TelegramUploadFile(id: raw.id, name: raw.name, size: raw.size, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: raw.url, directory: raw.directory, metadata: metadata)
    }

    private func png(_ width: Int, _ height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func music(tagged: Bool = false) async throws -> TelegramUploadFile {
        let url = try directory().appendingPathComponent(tagged ? "wrong.m4a" : "track.wav")
        if tagged { try await writeUploadTaggedAudioFixture(url, title: "Synthetic Title", performer: "Synthetic Artist") }
        else { try writeUploadAudioFixture(url) }
        let bytes = try Data(contentsOf: url)
        return try await stage(bytes, name: url.lastPathComponent, metadata: .audio(.init(duration: 1,
            title: tagged ? "Synthetic Title" : "", performer: tagged ? "Synthetic Artist" : "")))
    }

    private func pdf(_ width: Double = 64, _ height: Double = 80, pages: Int = 1) throws -> Data {
        let data = NSMutableData(), consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)); context.fill(box)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    // Catches using generic document rows for real graphic files, decoding unbounded bitmaps or rewriting originals.
    func testOwnedGraphicDocumentProducesBoundedThumbnailAndPreservesOriginal() async throws {
        let bytes = try png(640, 320), file = try await stage(bytes, name: "graphic.png")
        let preview = try await TelegramUploadDocumentPreviewIO.preview(file)
        XCTAssertEqual(preview.kind, .graphic); XCTAssertEqual(preview.title, "graphic.png")
        guard let image = preview.image else { return XCTFail("Graphic file must provide decoded thumbnail") }
        XCTAssertEqual(image.image.width, 320); XCTAssertEqual(image.image.height, 160)
        XCTAssertEqual(image.originalSHA256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
    }

    // Catches trusting filename tags or replacing the reference title/performer and duration presentation.
    func testVerifiedMusicUsesTagsDurationAndFilenameFallback() async throws {
        for tagged in [false, true] {
            let file = try await music(tagged: tagged)
            let preview = try await TelegramUploadDocumentPreviewIO.preview(file)
            XCTAssertEqual(preview.kind, .music)
            XCTAssertEqual(preview.title, tagged ? "Synthetic Title - Synthetic Artist" : "track.wav")
            XCTAssertEqual(preview.subtitle, "0:01"); XCTAssertNil(preview.image)
        }
    }

    // Catches sniffing WebP bytes into sticker UI after an ordinary selected JPEG is shown as a File.
    func testSelectedJPEGWithWebPBytesKeepsGraphicFileRowWhileTypedWebPRemainsSticker() async throws {
        _ = NSApplication.shared
        let bytes = UploadWebPFixture.staticLossless.data
        let raw = try await stage(bytes, name: "photo.jpg")
        let typed = try await stage(bytes, name: "sticker.webp", metadata: .webP(.init(width: 320, height: 160)))
        let cases: [(TelegramUploadFile, TelegramUploadDocumentPreviewSnapshot.Kind, Double)] = [
            (raw, .graphic, 70), (typed, .sticker, 104)
        ]
        for (file, kind, height) in cases {
            let preview = try await TelegramUploadDocumentPreviewIO.preview(file)
            XCTAssertEqual(preview.kind, kind, file.name)
            XCTAssertEqual(preview.title, file.name)
            XCTAssertEqual(preview.subtitle, ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
            XCTAssertNotNil(preview.image)
            let view = NSHostingView(rootView: TelegramUploadDocumentPreviewContent(preview: preview,
                isPlaying: false, playEnabled: false, onPlay: {}).frame(width: 320))
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.fittingSize.height, height, accuracy: 0.5, file.name)
            XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        }
    }

    // Catches JPEG flattening transparent sticker bytes or treating an animation as a static sticker.
    func testStaticWebPPreviewPreservesTransparencyAndAnimationUsesGraphicRow() async throws {
        for fixture in [UploadWebPFixture.staticLossless, .animated] {
            let file = try await stage(fixture.data, name: "sticker.webp", metadata: .webP(.init(width: 320, height: 160)))
            let preview = try await TelegramUploadDocumentPreviewIO.preview(file)
            XCTAssertEqual(preview.kind, fixture == .staticLossless ? .sticker : .graphic)
            guard let image = preview.image?.image else { XCTFail("Verified WebP must have a bounded preview"); continue }
            XCTAssertEqual(image.width, 320); XCTAssertEqual(image.height, 160)
            if fixture == .staticLossless {
                var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
                try pixels.withUnsafeMutableBytes { buffer in
                    let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                XCTAssertEqual(pixels[(80 * 320 + 160) * 4 + 3], 0)
            }
            XCTAssertEqual(try Data(contentsOf: file.url), fixture.data)
        }
    }

    // Catches sniffing opaque names into graphic rows or sending corrupt/oversized data to unrestricted decoders.
    func testOpaqueCorruptAndOversizedGraphicFilesKeepGenericPreview() async throws {
        for (bytes, name) in [(try png(64, 64), "opaque.bin"), (Data("not an image".utf8), "fake.png"),
                              (try png(8193, 1), "huge.png"), (Data("ordinary document".utf8), "document.txt")] {
            let file = try await stage(bytes, name: name)
            let preview = try await TelegramUploadDocumentPreviewIO.preview(file)
            XCTAssertEqual(preview.kind, .file, name); XCTAssertNil(preview.image, name)
            XCTAssertEqual(preview.title, name)
        }
    }

    // Catches validating only a small partial WebP frame while an oversized container canvas reaches ImageIO.
    func testOversizedPartialWebPCanvasKeepsGenericPreview() async throws {
        var bytes = UploadWebPFixture.partialCanvas.data
        XCTAssertEqual(bytes[12..<16], Data("VP8X".utf8))
        bytes[24] = 0; bytes[25] = 32; bytes[26] = 0 // little-endian canvas width minus one:8192.
        let file = try await stage(bytes, name: "oversized.webp")
        let preview = try await TelegramUploadDocumentPreviewIO.preview(file)
        XCTAssertEqual(preview.kind, .file); XCTAssertNil(preview.image)
    }

    // Catches dropping the PDF first-page preview or passing corrupt/unbounded PDF inputs to thumbnail rendering.
    func testPDFUsesFirstPageThumbnailAndRejectsCorruptDimensionsPageCountAndByteOverbounds() async throws {
        let bytes = try pdf(), file = try await stage(bytes, name: "document.pdf")
        let preview = try await TelegramUploadDocumentPreviewIO.preview(file)
        XCTAssertEqual(preview.kind, .graphic)
        if let image = preview.image {
            XCTAssertEqual(image.image.width, 64); XCTAssertEqual(image.image.height, 80)
            XCTAssertEqual(image.originalSHA256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        } else { XCTFail("Actual PDF first-page thumbnail missing") }
        var oversized = bytes
        oversized.append(Data(repeating: 0, count: 20 * 1024 * 1024 + 1 - oversized.count))
        for data in [Data("%PDF-1.7 corrupt".utf8), try pdf(8193, 1), try pdf(pages: 257), oversized] {
            let raw = try await stage(data, name: "unavailable.pdf")
            let fallback = try await TelegramUploadDocumentPreviewIO.preview(raw)
            XCTAssertEqual(fallback.kind, .file); XCTAssertNil(fallback.image)
            XCTAssertEqual(try Data(contentsOf: raw.url), data)
        }
    }

    // Catches treating forged canonical metadata, missing ownership and cancellation as a successful file preview.
    func testUnownedRemovedForgedAndCancelledFilesCannotPublishPreview() async throws {
        let raw = try await music()
        let forged = TelegramUploadFile(id: raw.id, name: raw.name, size: raw.size, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: raw.url, directory: raw.directory,
            metadata: .audio(.init(duration: 2, title: "", performer: "")))
        do { _ = try await TelegramUploadDocumentPreviewIO.preview(forged); XCTFail("Forged audio metadata must fail") } catch {}
        let outside = try directory().appendingPathComponent("outside.png"); try png(40, 40).write(to: outside)
        let unowned = TelegramUploadFile(id: UUID(), name: "outside.png", size: Int64(try Data(contentsOf: outside).count),
            mode: .file, pixelWidth: nil, pixelHeight: nil, url: outside, directory: outside.deletingLastPathComponent())
        do { _ = try await TelegramUploadDocumentPreviewIO.preview(unowned); XCTFail("Unowned picker path must fail") } catch {}
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TelegramUploadDocumentPreviewIO.preview(raw)
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled preview must throw") } catch is CancellationError {}
        let removed = try await stage(png(40, 40), name: "removed.png")
        try TelegramUploadFileIO.discard(removed)
        do { _ = try await TelegramUploadDocumentPreviewIO.preview(removed); XCTFail("Retired owned stage must fail") } catch {}
    }

    // Catches autoplay, reading the upload stage after release, public external playback and unlink-before-detach.
    func testMusicPlaybackOwnsIndependentLocalCopyAndRequiresExplicitPlay() async throws {
        let file = try await music(), expected = try Data(contentsOf: file.url)
        let playback = TelegramUploadDocumentAudioPlaybackController()
        await playback.load(file)
        XCTAssertEqual(playback.phase, .ready); XCTAssertNil(playback.error)
        guard let player = playback.player, let asset = player.currentItem?.asset as? AVURLAsset else {
            return XCTFail("Verified local music must prepare an actual native player")
        }
        XCTAssertNotEqual(asset.url, file.url); XCTAssertEqual(player.rate, 0)
        XCTAssertFalse(player.allowsExternalPlayback)
        let copy = asset.url
        XCTAssertEqual(try Data(contentsOf: copy), expected)
        try TelegramUploadFileIO.discard(file)
        XCTAssertEqual(try Data(contentsOf: copy), expected)
        player.isMuted = true
        playback.toggle(); XCTAssertEqual(playback.phase, .playing); XCTAssertEqual(player.rate, 1)
        playback.toggle(); XCTAssertEqual(playback.phase, .paused); XCTAssertEqual(player.rate, 0)
        playback.stop()
        XCTAssertEqual(playback.phase, .idle); XCTAssertNil(player.currentItem); XCTAssertNil(playback.player)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }

    // Catches leaving a stale/failed player live, or admitting an ordinary file without canonical audio intent.
    func testMusicPlaybackRejectsMissingIntentAndCancellationAndDetachesReplacement() async throws {
        let file = try await music(), plain = TelegramUploadFile(id: file.id, name: file.name, size: file.size,
            mode: .file, pixelWidth: nil, pixelHeight: nil, url: file.url, directory: file.directory)
        let playback = TelegramUploadDocumentAudioPlaybackController()
        await playback.load(plain); XCTAssertEqual(playback.phase, .failed); XCTAssertNil(playback.player)
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; await playback.load(file) }
        await cancelled.value
        XCTAssertNil(playback.player)
        await playback.load(file)
        guard let old = playback.player, let oldURL = (old.currentItem?.asset as? AVURLAsset)?.url else {
            return XCTFail("Actual audio player missing")
        }
        await playback.load(file)
        XCTAssertNil(old.currentItem); XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        playback.stop(); XCTAssertNil(playback.player)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    // Catches stop invalidating publication while an owned local copy keeps preparing without cancellation.
    func testStoppingMusicPlaybackCancelsInFlightPreparationAndReleasesOwnedCopy() async throws {
        try await assertCancelsMusicPreparation(expire: false)
    }

    // Catches the loading deadline stopping only a future player instead of the active preparation task.
    func testMusicPlaybackDeadlineCancelsInFlightPreparationAndReleasesOwnedCopy() async throws {
        try await assertCancelsMusicPreparation(expire: true)
    }

    private func assertCancelsMusicPreparation(expire: Bool) async throws {
        let file = try await music()
        let started = expectation(description: "Owned audio copy prepared before suspension")
        let cancelled = expectation(description: "In-flight audio preparation cancelled")
        var copied: TelegramPlaybackFile?
        let playback = TelegramUploadDocumentAudioPlaybackController(prepare: { file in
            let copy = try await TelegramPlaybackFileIO.prepare(source: file.url, expectedSize: file.size)
            copied = copy
            var handedOff = false
            defer { if !handedOff { try? TelegramPlaybackFileIO.discard(copy) } }
            started.fulfill()
            do { try await Task.sleep(for: .seconds(60)) }
            catch is CancellationError { cancelled.fulfill(); throw CancellationError() }
            handedOff = true
            return copy
        })
        let load = Task { await playback.load(file) }
        defer { load.cancel() }
        await fulfillment(of: [started], timeout: 2)
        let copy = try XCTUnwrap(copied)
        XCTAssertEqual(try Data(contentsOf: copy.url), try Data(contentsOf: file.url))
        if expire { playback.expireLoading() } else { playback.stop() }
        XCTAssertEqual(playback.phase, expire ? .timedOut : .idle)
        XCTAssertEqual(playback.error != nil, expire)
        XCTAssertNil(playback.player)
        await fulfillment(of: [cancelled], timeout: 1)
        // Cleanup also finishes the deliberately suspended RED implementation.
        load.cancel(); await load.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.directory.path))
        XCTAssertEqual(playback.phase, expire ? .timedOut : .idle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    // Catches generic row sizing, square WebP boxes and missing graphic/music reference geometry in actual SwiftUI layout.
    func testRenderedDocumentRowsFollowReferenceHeightsAndStickerAspectFit() async throws {
        _ = NSApplication.shared
        let files = [try await music(), try await stage(png(640, 320), name: "graphic.png"),
                     try await stage(UploadWebPFixture.staticLossless.data, name: "sticker.webp",
                        metadata: .webP(.init(width: 320, height: 160))),
                     try await stage(Data("ordinary".utf8), name: "document.txt")]
        for (file, height) in zip(files, [40.0, 70.0, 104.0, 40.0]) {
            let preview = try await TelegramUploadDocumentPreviewIO.preview(file)
            let view = NSHostingView(rootView: TelegramUploadDocumentPreviewContent(preview: preview,
                isPlaying: false, playEnabled: false, onPlay: {}).frame(width: 320))
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.fittingSize.height, height, accuracy: 0.5, file.name)
        }
    }
}
