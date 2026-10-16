import Foundation
import CoreImage
import CoreVideo

/// The queue owns rendering; the lock owns admission. At most one render and
/// one latest input survive, including while MainActor is busy publishing.
final class TelegramCallFrameRenderer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Makosh.call.presentation.render", qos: .userInteractive)
    private let lock = NSLock()
    private var latest: (UUID, CVPixelBuffer)?
    private var revision: UUID?
    private var active = false, closed = false
    private let render: (@Sendable (CVPixelBuffer) -> CGImage?)?
    private var context: CIContext? // Only the rendering queue touches this.
    private let publish: @Sendable (UUID, CGImage?) -> Void

    init(render: (@Sendable (CVPixelBuffer) -> CGImage?)? = nil,
         publish: @escaping @Sendable (UUID, CGImage?) -> Void) {
        self.render = render
        self.publish = publish
    }
    func submit(_ frame: CVPixelBuffer) {
        let schedule = lock.withLock {
            guard !closed else { return false }
            let token = UUID(); latest = (token, frame)
            guard !active else { return false }; active = true; return true
        }
        if schedule { queue.async { [self] in drain() } }
    }
    func isCurrent(_ token: UUID) -> Bool { lock.withLock { !closed && revision == token } }
    /// Publication acknowledges the completed render even when it was stale.
    func acknowledge() {
        let schedule = lock.withLock {
            guard !closed, latest != nil else { active = false; return false }
            return true
        }
        if schedule { queue.async { [self] in drain() } }
    }
    func close() {
        lock.withLock { closed = true; latest = nil; revision = nil }
        // Retire the native rendering context on its owner queue, after any
        // in-flight conversion, without making UI teardown wait for it.
        queue.async { [self] in context = nil }
    }
    private func drain() {
        let input = lock.withLock { () -> (UUID, CVPixelBuffer)? in
            guard !closed else { active = false; return nil }
            let value = latest; latest = nil; return value
        }
        guard let (token, frame) = input else { return }
        let image = autoreleasepool {
            if let render { return render(frame) }
            let context = self.context ?? CIContext(options: [.cacheIntermediates: false])
            self.context = context
            let image = CIImage(cvPixelBuffer: frame)
            return context.createCGImage(image, from: image.extent)
        }
        // Pending input supersedes only pending input. A busy producer must
        // never invalidate every completed frame before UI can display one.
        lock.withLock { if !closed { revision = token } }
        publish(token, image)
    }
}
