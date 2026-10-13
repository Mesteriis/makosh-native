import Foundation
import Postbox
import SwiftSignalKit

/// Own bounded bridge between the native update stream and one Postbox read.
final class TelegramNotificationBatchPump: Disposable {
    private let lock = NSLock()
    private let read: ([MessageId]) -> Signal<[TelegramNotificationEvent], NoError>
    private let next: ([TelegramNotificationEvent]) -> Void
    private let overflow: () -> Void
    private let lease = MetaDisposable()
    private var pending: [MessageId] = [], pendingIDs = Set<MessageId>()
    private var active: UUID?
    private var disposed = false, overflowReported = false
    init(read: @escaping ([MessageId]) -> Signal<[TelegramNotificationEvent], NoError>,
         next: @escaping ([TelegramNotificationEvent]) -> Void, overflow: @escaping () -> Void) {
        self.read = read; self.next = next; self.overflow = overflow
    }
    func offer(_ ids: [MessageId]) {
        lock.lock()
        guard !disposed else { lock.unlock(); return }
        var exceeded = ids.count > 10_000
        if !exceeded {
            for id in ids where !pendingIDs.contains(id) {
                guard pending.count < 1000 else { exceeded = true; continue }
                pending.append(id); pendingIDs.insert(id)
            }
        }
        let report = exceeded && !overflowReported
        if report { overflowReported = true }
        let work = takeWorkLocked()
        lock.unlock()
        if report { overflow() }
        if let work { start(work) }
    }
    private func takeWorkLocked() -> (UUID, [MessageId])? {
        guard !disposed, active == nil, !pending.isEmpty else { return nil }
        let token = UUID(), ids = pending
        active = token; pending = []; pendingIDs = []
        return (token, ids)
    }
    private func start(_ work: (UUID, [MessageId])) {
        // Install the holder first: a synchronous completion may start the next
        // read before this read's start() returns its disposable.
        let holder = MetaDisposable()
        lease.set(holder)
        lock.lock(); let admitted = !disposed && active == work.0; lock.unlock()
        guard admitted else { holder.dispose(); return }
        holder.set(read(work.1).start(next: { [weak self] events in
            guard let self else { return }
            self.lock.lock(); let current = !self.disposed && self.active == work.0; self.lock.unlock()
            if current { self.next(events) }
        }, completed: { [weak self] in self?.complete(work.0) }))
    }
    private func complete(_ token: UUID) {
        lock.lock()
        guard !disposed, active == token else { lock.unlock(); return }
        active = nil
        let work = takeWorkLocked()
        lock.unlock()
        if let work { start(work) }
    }
    func dispose() {
        lock.lock(); disposed = true; active = nil; pending = []; pendingIDs = []; lock.unlock()
        lease.dispose()
    }
}
