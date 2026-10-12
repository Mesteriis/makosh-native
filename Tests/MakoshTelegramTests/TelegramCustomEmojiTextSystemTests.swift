import XCTest
import AppKit
import TelegramCore
import Postbox
@testable import MakoshApp
@testable import MakoshTelegram

@MainActor final class TelegramCustomEmojiTextSystemTests: XCTestCase {
    private final class Lease: TelegramMediaLease {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    private final class Provider: TelegramCustomEmojiResourceProvider {
        let accountID: Int64 = 1
        var requests: [TelegramCustomEmojiDescriptor] = []
        var leases: [Lease] = []
        func start(descriptor: TelegramCustomEmojiDescriptor,
            receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
            requests.append(descriptor); let lease = Lease(); leases.append(lease); return lease
        }
    }
    private func nativeText(_ source: String, height: CGFloat = 80) -> NSTextView {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: height))
        TelegramCustomEmojiTextSystem.install(in: text)
        text.isEditable = true; text.isSelectable = true; text.drawsBackground = false
        text.isVerticallyResizable = false
        text.textContainerInset = .zero; text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.containerSize = NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude)
        text.textStorage?.setAttributedString(NSAttributedString(string: source,
            attributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black]))
        return text
    }
    private func render(_ text: NSTextView) throws -> NSBitmapImageRep {
        let layout = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
        layout.ensureLayout(for: container)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 800, bitsPerPixel: 32))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        graphics.cgContext.clear(CGRect(x: 0, y: 0, width: 200, height: 80))
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: .zero)
        return bitmap
    }
    private func colors(_ bitmap: NSBitmapImageRep) -> [NSColor] {
        (0..<bitmap.pixelsHigh).flatMap { y in (0..<bitmap.pixelsWide).compactMap { x in
            bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
        }}.filter { $0.alphaComponent > 0.01 }
    }
    // Catches the former container → storage → layout-manager ownership cycle.
    // A detached NSTextView has SDK-owned lifetime behavior; this regression
    // isolates the network owned by our layout bridge from that native baseline.
    func testOwnedLayoutGraphIsReleasedWithItsStorage() {
        weak var storage: NSTextStorage?
        weak var layout: NSLayoutManager?
        weak var container: NSTextContainer?
        autoreleasepool {
            let owner = NSTextStorage(string: "🦊")
            let manager = TelegramCustomEmojiLayoutManager()
            let box = NSTextContainer(size: .init(width: 200, height: 80))
            owner.addLayoutManager(manager); manager.addTextContainer(box)
            storage = owner; layout = manager; container = box
            XCTAssertNotNil(storage); XCTAssertNotNil(layout); XCTAssertNotNil(container)
        }
        XCTAssertNil(storage); XCTAssertNil(layout); XCTAssertNil(container)
    }

    // Catches removing source characters/attributes/selection to hide the glyph,
    // or painting the animated overlay on top of the ordinary emoji glyph.
    func testReadyTransparentPixelsSuppressOnlyGlyphAndPreserveNativeSource() throws {
        let text = nativeText("🦊"), layout = try XCTUnwrap(text.layoutManager as? TelegramCustomEmojiLayoutManager)
        text.setSelectedRange(NSRange(location: 0, length: 2))
        let source = text.attributedString(), selection = text.selectedRange()
        XCTAssertFalse(colors(try render(text)).isEmpty, "The real fallback glyph must exist")
        layout.install(source: "🦊", frames: [.init(range: NSRange(location: 0, length: 2),
            frame: .init(width: 2, height: 2, pixels: Data(repeating: 0, count: 16)), isSingleColor: false)])
        XCTAssertTrue(colors(try render(text)).isEmpty, "Ready transparent pixels must suppress the fallback glyph")
        XCTAssertEqual(text.attributedString(), source); XCTAssertEqual(text.selectedRange(), selection)
    }
    // Catches incorrectly drawing only the Unicode fallback despite ready real
    // pixels, and ignoring the native single-color emoji flag.
    func testReadyFrameDrawsRealPixelsAndSingleColorUsesSourceTextColor() throws {
        let text = nativeText("🦊"), layout = try XCTUnwrap(text.layoutManager as? TelegramCustomEmojiLayoutManager)
        let frame = TelegramCustomEmojiFrame(width: 2, height: 2,
            pixels: Data([0,0,255,255,0,0,255,255,0,0,255,255,0,0,255,255]))
        let range = NSRange(location: 0, length: 2)
        layout.install(source: "🦊", frames: [.init(range: range, frame: frame, isSingleColor: false)])
        let red = colors(try render(text))
        XCTAssertFalse(red.isEmpty); XCTAssertTrue(red.allSatisfy { $0.redComponent > 0.95 && $0.greenComponent < 0.05 && $0.blueComponent < 0.05 })
        text.textStorage?.addAttribute(.foregroundColor, value: NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1), range: range)
        layout.install(source: "🦊", frames: [.init(range: range, frame: frame, isSingleColor: true)])
        let green = colors(try render(text))
        XCTAssertFalse(green.isEmpty); XCTAssertTrue(green.allSatisfy { $0.redComponent < 0.05 && $0.greenComponent > 0.95 && $0.blueComponent < 0.05 })
    }
    // Catches an old image suppressing or replacing newly edited source text
    // while an asynchronous callback for the previous input is still in flight.
    func testChangedSourceInvalidatesReadyGlyphBinding() throws {
        let text = nativeText("🦊"), layout = try XCTUnwrap(text.layoutManager as? TelegramCustomEmojiLayoutManager)
        layout.install(source: "🦊", frames: [.init(range: NSRange(location: 0, length: 2),
            frame: .init(width: 2, height: 2, pixels: Data(repeating: 0, count: 16)), isSingleColor: false)])
        XCTAssertTrue(colors(try render(text)).isEmpty)
        text.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 2), with: "🐻")
        XCTAssertFalse(colors(try render(text)).isEmpty); XCTAssertEqual(text.string, "🐻")
    }
    // Catches fetching/rendering a concealed spoiler, retaining its lease after
    // concealment, or detaching only pixels while leaving native fetch active.
    func testConcealedEmojiNeverFetchesAndRevealingThenHidingCancelsLease() throws {
        let descriptor = try textEmojiDescriptor(), provider = Provider()
        let context = TelegramCustomEmojiPlaybackContext(accountID: 1, provider: provider)
        let value = try TelegramFormattedText(text: "🦊", entities: [.init(offset: 0, length: 2,
            kind: .customEmoji(stickerPack: nil, fileID: descriptor.fileID))])
        let text = nativeText(value.text), overlay = TelegramCustomEmojiTextOverlay()
        overlay.update(textView: text, value: value, descriptors: [descriptor.fileID: descriptor], context: context,
            concealedRanges: [NSRange(location: 0, length: 2)])
        XCTAssertTrue(provider.requests.isEmpty)
        overlay.update(textView: text, value: value, descriptors: [descriptor.fileID: descriptor], context: context, concealedRanges: [])
        guard provider.requests.count == 1 else { XCTFail("Visible revealed emoji must request its native resource"); return }
        overlay.update(textView: text, value: value, descriptors: [descriptor.fileID: descriptor], context: context,
            concealedRanges: [NSRange(location: 0, length: 2)])
        XCTAssertTrue(provider.leases[0].cancelled)
        overlay.update(textView: text, value: value, descriptors: [descriptor.fileID: descriptor], context: context, concealedRanges: [])
        guard provider.requests.count == 2 else { XCTFail("An explicit reveal may acquire a new lease"); return }
        overlay.detach(); XCTAssertTrue(provider.leases[1].cancelled)
    }
    // Catches offscreen message content holding a decoder budget slot, and
    // failing to acquire one after scrolling the same native text into view.
    func testOffscreenEmojiWaitsForLayoutVisibilityBeforeFetching() throws {
        let descriptor = try textEmojiDescriptor(), provider = Provider()
        let context = TelegramCustomEmojiPlaybackContext(accountID: 1, provider: provider)
        let value = try TelegramFormattedText(text: "a\nb\n🦊", entities: [.init(offset: 4, length: 2,
            kind: .customEmoji(stickerPack: nil, fileID: descriptor.fileID))])
        let text = nativeText(value.text, height: 20), overlay = TelegramCustomEmojiTextOverlay()
        overlay.update(textView: text, value: value, descriptors: [descriptor.fileID: descriptor], context: context, concealedRanges: [])
        XCTAssertTrue(provider.requests.isEmpty)
        text.setFrameSize(NSSize(width: 200, height: 80)); overlay.layout()
        XCTAssertEqual(provider.requests, [descriptor]); overlay.detach()
    }
}
private nonisolated func textEmojiDescriptor() throws -> TelegramCustomEmojiDescriptor {
    let file = TelegramMediaFile(fileId: .init(namespace: Namespaces.Media.CloudFile, id: 100), partialReference: nil,
        resource: CloudDocumentMediaResource(datacenterId: 2, fileId: 100, accessHash: 53,
            size: 36, fileReference: Data([1,2]), fileName: "synthetic-emoji.webp"),
        previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "image/webp", size: 36,
        attributes: [.CustomEmoji(isPremium: false, isSingleColor: false, alt: "🦊", packReference: nil)], alternativeRepresentations: [])
    return try TelegramCustomEmojiDescriptor(file: file)
}
