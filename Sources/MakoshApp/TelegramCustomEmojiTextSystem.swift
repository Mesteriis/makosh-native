import AppKit
import Combine
import MakoshTelegram

struct TelegramCustomEmojiLayoutFrame {
    let range: NSRange
    let frame: TelegramCustomEmojiFrame
    let isSingleColor: Bool
}
@MainActor enum TelegramCustomEmojiTextSystem {
    static func install(in textView: NSTextView) {
        guard let container = textView.textContainer,
              !(textView.layoutManager is TelegramCustomEmojiLayoutManager) else { return }
        // AppKit transfers the existing native storage/container graph. The
        // view owns that graph; the overlay never retains its text storage.
        container.replaceLayoutManager(TelegramCustomEmojiLayoutManager())
    }
}
@MainActor final class TelegramCustomEmojiLayoutManager: NSLayoutManager {
    private var source = Data()
    private var frames: [TelegramCustomEmojiLayoutFrame] = []
    func install(source: String, frames: [TelegramCustomEmojiLayoutFrame]) {
        self.source = Data(source.utf8)
        let length = source.utf16.count
        var end = 0
        self.frames = frames.sorted { $0.range.location < $1.range.location }.filter { entry in
            guard entry.range.location >= end, entry.range.length > 0,
                  entry.range.location <= length, entry.range.length <= length - entry.range.location,
                  (1...512).contains(entry.frame.width), (1...512).contains(entry.frame.height),
                  entry.frame.pixels.count == entry.frame.width * entry.frame.height * 4,
                  let range = Range(entry.range, in: source), source[range].count == 1 else { return false }
            end = NSMaxRange(entry.range); return true
        }
        invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0))
    }
    nonisolated override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        // NSLayoutManager's drawing primitive is unannotated in AppKit. This
        // manager belongs only to a native main-thread text view; the bridge is
        // synchronous and never dispatches or shares its mutable layout state.
        precondition(Thread.isMainThread)
        let reference = TelegramCustomEmojiMainThreadLayoutReference(layout: self)
        MainActor.assumeIsolated { reference.layout.drawReadyGlyphs(forGlyphRange: glyphsToShow, at: origin) }
    }
    private func drawReadyGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, Data(storage.string.utf8) == source, !frames.isEmpty else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin); return
        }
        var ready: [(NSRange, NSRect, NSImage)] = []
        for entry in frames {
            var actual = NSRange(location: NSNotFound, length: 0)
            let glyphs = glyphRange(forCharacterRange: entry.range, actualCharacterRange: &actual)
            guard actual == entry.range, glyphs.length > 0,
                  NSIntersectionRange(glyphs, glyphsToShow).length > 0,
                  let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) else { continue }
            let bounds = boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
            let tint = entry.isSingleColor ? (storage.attribute(.foregroundColor, at: entry.range.location,
                effectiveRange: nil) as? NSColor ?? .textColor) : nil
            guard bounds.width > 0, bounds.height > 0, let image = image(entry.frame, tint: tint) else { continue }
            ready.append((glyphs, bounds, image))
        }
        ready.sort { $0.0.location < $1.0.location }
        var cursor = glyphsToShow.location
        for (range, _, _) in ready {
            let overlap = NSIntersectionRange(range, glyphsToShow)
            if overlap.location > cursor {
                super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: overlap.location - cursor), at: origin)
            }
            cursor = NSMaxRange(overlap)
        }
        if cursor < NSMaxRange(glyphsToShow) {
            super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: NSMaxRange(glyphsToShow) - cursor), at: origin)
        }
        for (_, bounds, image) in ready {
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let width = image.size.width * scale, height = image.size.height * scale
            let rect = NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
    private func image(_ frame: TelegramCustomEmojiFrame, tint: NSColor?) -> NSImage? {
        var pixels = frame.pixels
        if let tint, let color = tint.usingColorSpace(.deviceRGB) {
            func unit(_ component: CGFloat) -> Double {
                let value = Double(component)
                return value.isFinite ? min(1, max(0, value)) : 0
            }
            let red = unit(color.redComponent), green = unit(color.greenComponent), blue = unit(color.blueComponent)
            let opacity = unit(color.alphaComponent)
            pixels.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                for offset in stride(from: 0, to: buffer.count, by: 4) {
                    let alpha = (Double(buffer[offset + 3]) * opacity).rounded()
                    buffer[offset] = UInt8((alpha * blue).rounded())
                    buffer[offset + 1] = UInt8((alpha * green).rounded())
                    buffer[offset + 2] = UInt8((alpha * red).rounded())
                    buffer[offset + 3] = UInt8(alpha)
                }
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: frame.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: frame.width, height: frame.height))
    }
}
private struct TelegramCustomEmojiMainThreadLayoutReference: @unchecked Sendable {
    let layout: TelegramCustomEmojiLayoutManager
}
@MainActor final class TelegramCustomEmojiTextOverlay {
    @MainActor private final class Entry {
        let descriptor: TelegramCustomEmojiDescriptor
        let playback = TelegramCustomEmojiPlaybackController()
        var subscription: AnyCancellable?
        init(descriptor: TelegramCustomEmojiDescriptor) { self.descriptor = descriptor }
        func stop() { subscription = nil; playback.stop() }
    }
    private weak var textView: NSTextView?
    private var value: TelegramFormattedText?
    private var descriptors: [Int64: TelegramCustomEmojiDescriptor] = [:]
    private var context: TelegramCustomEmojiPlaybackContext?
    private var concealed: [NSRange] = []
    private var presentation = Data()
    private var entries: [NSRange: Entry] = [:]
    private var layingOut = false
    private var clipIDs: [ObjectIdentifier] = []
    private var clipObservers: [NSObjectProtocol] = []

    isolated deinit {
        for entry in entries.values { entry.stop() }
        for observer in clipObservers { NotificationCenter.default.removeObserver(observer) }
    }
    func update(textView: NSTextView, value: TelegramFormattedText,
        descriptors: [Int64: TelegramCustomEmojiDescriptor], context: TelegramCustomEmojiPlaybackContext?,
        concealedRanges: [NSRange]) {
        if self.textView !== textView || self.value != value || self.descriptors != descriptors ||
           self.context !== context || concealed != concealedRanges || presentation != Data(textView.string.utf8) {
            detach()
            self.textView = textView; self.value = value; self.descriptors = descriptors; self.context = context
            self.concealed = concealedRanges; presentation = Data(textView.string.utf8)
        }
        layout()
    }
    func layout() {
        guard !layingOut, let textView, let layout = textView.layoutManager as? TelegramCustomEmojiLayoutManager,
              let container = textView.textContainer else { return }
        observeClipping(of: textView)
        layingOut = true
        defer { layingOut = false; redraw() }
        guard let value, context != nil, presentation == Data(textView.string.utf8),
              textView.string.utf16.count == value.text.utf16.count else {
            for entry in entries.values { entry.stop() }; entries.removeAll(); return
        }
        layout.ensureLayout(for: container)
        let actual = textView.string as NSString, raw = value.text as NSString
        var boundaries: Set<Int> = [0], count = 0
        for character in value.text { count += String(character).utf16.count; boundaries.insert(count) }
        var visible: [NSRange: (TelegramCustomEmojiDescriptor, Int, Int)] = [:]
        for entity in value.entities {
            guard case let .customEmoji(_, fileID) = entity.kind, let descriptor = descriptors[fileID],
                  descriptor.fileID == fileID, entity.offset >= 0, entity.length > 0,
                  entity.offset <= raw.length, entity.length <= raw.length - entity.offset,
                  boundaries.contains(entity.offset), boundaries.contains(entity.offset + entity.length) else { continue }
            let range = NSRange(location: entity.offset, length: entity.length)
            guard !concealed.contains(where: { NSIntersectionRange($0, range).length > 0 }),
                  actual.substring(with: range).utf8.elementsEqual(raw.substring(with: range).utf8),
                  raw.substring(with: range).count == 1 else { continue }
            var characterRange = NSRange(location: NSNotFound, length: 0)
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: &characterRange)
            guard characterRange == range, glyphs.length > 0 else { continue }
            let bounds = layout.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            guard !bounds.isEmpty, bounds.intersects(textView.visibleRect.intersection(textView.bounds)) else { continue }
            let scale = textView.window?.backingScaleFactor ?? 2
            let width = min(512, max(1, Int(ceil(bounds.width * scale))))
            let height = min(512, max(1, Int(ceil(bounds.height * scale))))
            visible[range] = (descriptor, width, height)
        }
        for range in Array(entries.keys) where visible[range] == nil {
            entries.removeValue(forKey: range)?.stop()
        }
        for (range, (descriptor, width, height)) in visible {
            let entry: Entry
            if let previous = entries[range], previous.descriptor == descriptor { entry = previous }
            else {
                entries.removeValue(forKey: range)?.stop()
                entry = Entry(descriptor: descriptor); entries[range] = entry
                entry.subscription = entry.playback.$frame.sink { [weak self] _ in
                    self?.redraw()
                }
            }
            entry.playback.bind(context: context)
            entry.playback.play(descriptor: descriptor, width: width, height: height)
        }
    }
    private func observeClipping(of text: NSTextView) {
        var clips: [NSClipView] = [], ancestor = text.superview
        while let view = ancestor {
            if let clip = view as? NSClipView { clips.append(clip) }
            ancestor = view.superview
        }
        let ids = clips.map(ObjectIdentifier.init)
        guard ids != clipIDs else { return }
        for observer in clipObservers { NotificationCenter.default.removeObserver(observer) }
        clipObservers = []; clipIDs = ids
        for clip in clips {
            clip.postsBoundsChangedNotifications = true
            clipObservers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.layout() }
                })
        }
    }
    func detach() {
        for observer in clipObservers { NotificationCenter.default.removeObserver(observer) }
        clipObservers = []; clipIDs = []
        for entry in entries.values { entry.stop() }; entries.removeAll()
        if let textView, let layout = textView.layoutManager as? TelegramCustomEmojiLayoutManager {
            layout.install(source: textView.string, frames: []); textView.needsDisplay = true
        }
        textView = nil; value = nil; descriptors = [:]; context = nil; concealed = []; presentation = Data()
    }
    private func redraw() {
        guard !layingOut, let textView, let layout = textView.layoutManager as? TelegramCustomEmojiLayoutManager else { return }
        let source = textView.string
        let frames: [TelegramCustomEmojiLayoutFrame]
        if presentation == Data(source.utf8) {
            frames = entries.compactMap { range, entry in
                entry.playback.frame.map { .init(range: range, frame: $0, isSingleColor: entry.descriptor.isSingleColor) }
            }
        } else { frames = [] }
        layout.install(source: source, frames: frames); textView.needsDisplay = true
    }
}
