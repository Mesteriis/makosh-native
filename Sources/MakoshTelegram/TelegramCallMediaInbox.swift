import Foundation
import CoreVideo

enum TelegramCallMediaDelivery: @unchecked Sendable {
    case state(Int32), remoteVideo(Bool), frame(CVPixelBuffer), localFrame(CVPixelBuffer), signaling(Data), failed, released
}
/// One scheduled drain, two retained latest frames, bounded ordered signaling.
/// The owner delivers on its actor and checks its current call context again.
final class TelegramCallMediaInbox: @unchecked Sendable {
    private let lock = NSLock()
    private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let deliver: @Sendable (TelegramCallMediaDelivery) -> Void
    private var ordered: [TelegramCallMediaDelivery] = []
    private var remote: CVPixelBuffer?, local: CVPixelBuffer?
    private var bytes = 0, controls = 0, signals = 0
    private var scheduled = false, revoked = false, failed = false, released = false, releaseDelivered = false
    init(schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         deliver: @escaping @Sendable (TelegramCallMediaDelivery) -> Void) {
        self.schedule = schedule; self.deliver = deliver
    }
    @discardableResult func enqueue(_ value: TelegramCallMediaDelivery) -> Bool {
        let decision = lock.withLock { () -> (Bool, Bool) in
            guard !revoked, !failed, !released else { return (false, false) }
            var valid = true
            switch value {
            case let .frame(frame): valid = telegramCallFrameAdmitted(frame); if valid { remote = frame }
            case let .localFrame(frame): valid = telegramCallFrameAdmitted(frame); if valid { local = frame }
            case let .signaling(data):
                valid = !data.isEmpty && data.count <= 65536 && signals < 256 && bytes + data.count <= 1024 * 1024
                if valid { ordered.append(value); bytes += data.count; signals += 1 }
            case let .state(state):
                valid = (0...3).contains(state) && controls < 32
                if valid { ordered.append(value); controls += 1 }
            case .remoteVideo:
                valid = controls < 32
                if valid { ordered.append(value); controls += 1 }
            case .failed, .released: valid = false
            }
            if !valid { failed = true; clearLocked() }
            let needsSchedule = !scheduled; scheduled = true
            return (valid, needsSchedule)
        }
        if decision.1 { scheduleDrain() }; return decision.0
    }
    func revoke() { lock.withLock { revoked = true; failed = false; clearLocked() } }
    func release() {
        let needsSchedule = lock.withLock { () -> Bool in
            guard !released else { return false }
            released = true; revoked = true; failed = false; clearLocked()
            let needsSchedule = !scheduled; scheduled = true; return needsSchedule
        }
        if needsSchedule { scheduleDrain() }
    }
    private func clearLocked() { ordered = []; remote = nil; local = nil; bytes = 0; controls = 0; signals = 0 }
    private func scheduleDrain() { schedule { [self] in drain() } }
    private func drain() {
        let values = lock.withLock { () -> [TelegramCallMediaDelivery] in
            scheduled = false
            if released && !releaseDelivered { releaseDelivered = true; return [.released] }
            guard !revoked else { return [] }
            if failed { failed = false; revoked = true; return [.failed] }
            var values = ordered
            if let remote { values.append(.frame(remote)) }; if let local { values.append(.localFrame(local)) }
            clearLocked(); return values
        }
        for value in values { deliver(value) }
    }
}
func telegramCallFrameAdmitted(_ frame: CVPixelBuffer) -> Bool {
    let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame), format = CVPixelBufferGetPixelFormatType(frame)
    return width >= 2 && height >= 2 && width <= 1920 && height <= 1920 && width * height <= 1920 * 1080 &&
        width % 2 == 0 && height % 2 == 0 && CVPixelBufferGetPlaneCount(frame) == 2 &&
        [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange].contains(format)
}
