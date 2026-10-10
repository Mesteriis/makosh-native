import Foundation
import Combine

public enum TelegramAvatarSize: Hashable, Sendable { case small, large }

public struct TelegramAvatarKey: Hashable, Sendable {
    public let peerID: Int64
    public let size: TelegramAvatarSize
    public init(peerID: Int64, size: TelegramAvatarSize = .small) {
        self.peerID = peerID; self.size = size
    }
}

enum TelegramAvatarEvent: Sendable {
    case resource(String?)
    case data(resourceID: String, url: URL, size: Int64)
    case failed(resourceID: String)
}

@MainActor protocol TelegramAvatarLease: AnyObject { func cancel() }
@MainActor protocol TelegramAvatarProvider: AnyObject {
    func start(key: TelegramAvatarKey, receive: @escaping @MainActor (TelegramAvatarEvent) -> Void) -> any TelegramAvatarLease
}

/// Each visible avatar owns a cancellable observation; native references stay in
/// the account-bound provider. No avatar bytes or cache paths enter a dossier.
@MainActor public final class TelegramAvatarStore: ObservableObject {
    @MainActor private final class Job {
        let key: TelegramAvatarKey
        let continuation: AsyncStream<TelegramImagePreview?>.Continuation
        var resourceID: String?
        var lease: (any TelegramAvatarLease)?
        var decode: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var hasImage = false
        var acceptsData = false
        init(key: TelegramAvatarKey, continuation: AsyncStream<TelegramImagePreview?>.Continuation) {
            self.key = key; self.continuation = continuation
        }
        func stop() {
            decode?.cancel(); deadline?.cancel()
            continuation.finish(); lease?.cancel()
        }
    }
    @Published public private(set) var contextID = UUID()
    private var provider: (any TelegramAvatarProvider)?
    private var jobs: [UUID: Job] = [:]
    public init() {}
    isolated deinit { for job in jobs.values { job.stop() } }

    func bind(_ provider: (any TelegramAvatarProvider)?) {
        let previous = jobs; jobs.removeAll()
        self.provider = provider; contextID = UUID()
        for job in previous.values { job.stop() }
    }

    public func images(for key: TelegramAvatarKey) -> AsyncStream<TelegramImagePreview?> {
        let (stream, continuation) = AsyncStream<TelegramImagePreview?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(nil)
        guard let provider, jobs.count < 128 else { continuation.finish(); return stream }
        let token = UUID(), job = Job(key: key, continuation: continuation)
        jobs[token] = job
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in self?.remove(token) }
        }
        let lease = provider.start(key: key) { [weak self] event in self?.receive(event, token: token) }
        if jobs[token] === job { job.lease = lease } else { lease.cancel() }
        return stream
    }

    private func receive(_ event: TelegramAvatarEvent, token: UUID) {
        guard let job = jobs[token] else { return }
        switch event {
        case .resource(let id):
            job.decode?.cancel(); job.decode = nil
            job.deadline?.cancel(); job.deadline = nil
            job.resourceID = id; job.hasImage = false; job.acceptsData = id != nil; job.continuation.yield(nil)
            guard let id else { return }
            job.deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.timeout(token, resourceID: id)
            }
        case let .data(id, url, size):
            guard id == job.resourceID, job.acceptsData, !job.hasImage, job.decode == nil else { return }
            let sizeClass = job.key.size
            job.decode = Task { [weak self] in
                do {
                    let image = try await TelegramAvatarFileIO.image(source: url, expectedSize: size, size: sizeClass)
                    try Task.checkCancellation()
                    self?.publish(image, token: token, resourceID: id)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.decodeFailed(token, resourceID: id)
                }
            }
        case .failed(let id):
            guard id == job.resourceID, !job.hasImage else { return }
            job.acceptsData = false
            job.decode?.cancel(); job.decode = nil
            job.deadline?.cancel(); job.deadline = nil
            job.continuation.yield(nil)
        }
    }

    private func publish(_ image: TelegramImagePreview, token: UUID, resourceID: String) {
        guard let job = jobs[token], job.resourceID == resourceID else { return }
        job.decode = nil; job.deadline?.cancel(); job.deadline = nil
        job.hasImage = true; job.continuation.yield(image)
    }

    private func decodeFailed(_ token: UUID, resourceID: String) {
        guard let job = jobs[token], job.resourceID == resourceID else { return }
        job.decode = nil; job.acceptsData = false; job.continuation.yield(nil)
    }

    func timeout(_ token: UUID, resourceID: String) {
        guard let job = jobs[token], job.resourceID == resourceID, !job.hasImage else { return }
        // The provider independently bounds pending fetches. Keep observing the
        // peer for a later photo change, rejecting this expired resource's data.
        job.acceptsData = false
        job.decode?.cancel(); job.decode = nil; job.deadline = nil
        job.continuation.yield(nil)
    }

    private func remove(_ token: UUID) {
        guard let job = jobs.removeValue(forKey: token) else { return }
        job.stop()
    }
}
