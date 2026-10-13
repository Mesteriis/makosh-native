import Foundation
import Combine

public enum TelegramMediaPurpose: Hashable, Sendable { case preview, full }

public struct TelegramMediaKey: Hashable, Sendable {
    public let attachmentID: String
    public let purpose: TelegramMediaPurpose
    public init(attachmentID: String, purpose: TelegramMediaPurpose) {
        self.attachmentID = attachmentID
        self.purpose = purpose
    }
}

public enum TelegramMediaPhase: Equatable, Sendable {
    case idle, downloading(Double?), ready, failed, cancelled, timedOut
}

@MainActor
protocol TelegramMediaLease: AnyObject { func cancel() }

@MainActor protocol TelegramMediaArchiveReservation: AnyObject {
    func capture(file: URL, byteCount: Int64) -> Bool
    func cancel()
}

@MainActor
protocol TelegramMediaProvider: AnyObject {
    func start(attachmentID: String, purpose: TelegramMediaPurpose,
               receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease
    func startAutomatically(attachmentID: String, preferences: TelegramAutoDownloadPreferences,
        isCurrent: @escaping @MainActor () -> Bool,
        receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease
}

private final class RefusedAutomaticMediaLease: TelegramMediaLease { func cancel() {} }
extension TelegramMediaProvider {
    func startAutomatically(attachmentID: String, preferences: TelegramAutoDownloadPreferences,
        isCurrent: @escaping @MainActor () -> Bool,
        receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
        receive(.failed); return RefusedAutomaticMediaLease()
    }
}

enum TelegramMediaEvent {
    case progress(Double?)
    case data(URL, offset: Int64, size: Int64, complete: Bool)
    case failed
    case fetchCompleted
}

/// Owns each provider lease until cancellation or removal, including completed files.
/// File content and export validation belong to the provider/export boundary.
@MainActor
public final class TelegramMediaController: ObservableObject {
    @MainActor
    private final class LeaseHolder {
        var lease: (any TelegramMediaLease)?
        var borrows = 0
        var releasePending = false
        var archiveReservation: (any TelegramMediaArchiveReservation)?
        func release() {
            archiveReservation?.cancel(); archiveReservation = nil
            releasePending = true
            if borrows == 0 { let old = lease; lease = nil; old?.cancel() }
        }
        func endBorrow() { borrows -= 1; if releasePending { release() } }
    }
    @MainActor
    private struct Job {
        let token: UUID
        var phase: TelegramMediaPhase
        var file: URL?
        var size: Int64 = 0
        var holder = LeaseHolder()
        var deadline: Task<Void, Never>?
        var completedFile: (@MainActor (String,URL,Int64) -> Void)?
        var automatic = false
        var automaticIsCurrent: (@MainActor () -> Bool)?
    }
    @Published private var revision = 0
    private var provider: (any TelegramMediaProvider)?
    private var attachments: [String: TelegramAttachment] = [:]
    private var jobs: [TelegramMediaKey: Job] = [:]
    var completedFullFile: (@MainActor (String,URL,Int64) -> Void)?
    var reserveAutomaticFile: (@MainActor (String) -> (any TelegramMediaArchiveReservation)?)?

    public init() {}

    isolated deinit {
        for job in jobs.values { job.deadline?.cancel(); job.holder.release() }
    }

    public func phase(for key: TelegramMediaKey) -> TelegramMediaPhase { jobs[key]?.phase ?? .idle }

    public func downloadedFile(for key: TelegramMediaKey) -> URL? {
        guard jobs[key]?.phase == .ready else { return nil }
        return jobs[key]?.file
    }

    public func withDownloadedFile(for key: TelegramMediaKey,
                                   operation: @MainActor (URL, Int64) async throws -> Void) async throws -> Bool {
        guard let job = jobs[key], job.phase == .ready, let url = job.file else { return false }
        job.holder.borrows += 1
        defer { job.holder.endBorrow() }
        try await operation(url, job.size)
        return true
    }

    func bind(provider: (any TelegramMediaProvider)?) {
        reset()
        self.provider = provider
    }

    public func reset() {
        let previous = jobs
        jobs.removeAll()
        attachments.removeAll()
        provider = nil
        completedFullFile = nil
        reserveAutomaticFile = nil
        revision &+= 1
        for job in previous.values { job.deadline?.cancel(); job.holder.release() }
    }

    func retain(attachments: [TelegramAttachment]) {
        let next = Dictionary(attachments.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let removed = jobs.keys.filter { key in
            guard let old = self.attachments[key.attachmentID], let new = next[key.attachmentID] else { return true }
            return old != new
        }
        for key in removed { remove(key) }
        self.attachments = next
    }

    public func start(_ attachment: TelegramAttachment, purpose: TelegramMediaPurpose) {
        _ = start(attachment, purpose: purpose, automatic: nil)
    }

    @discardableResult func startAutomatically(_ attachment: TelegramAttachment, preferences: TelegramAutoDownloadPreferences,
        isCurrent: @escaping @MainActor () -> Bool) -> Bool {
        start(attachment, purpose: .full, automatic: preferences, isCurrent: isCurrent)
    }
    var automaticInFlightCount: Int {
        jobs.values.filter { job in if case .downloading = job.phase { return job.automatic }; return false }.count
    }
    func cancelAutomaticDownloads(except retained: Set<String>) {
        for key in jobs.keys.filter({ jobs[$0]?.automatic == true && !retained.contains($0.attachmentID) }) { remove(key) }
    }
    @discardableResult private func start(_ attachment: TelegramAttachment, purpose: TelegramMediaPurpose,
        automatic: TelegramAutoDownloadPreferences?, isCurrent: (@MainActor () -> Bool)? = nil) -> Bool {
        guard let provider, attachments[attachment.id] == attachment,
              purpose == .preview ? attachment.hasPreview : attachment.canDownload else { return false }
        guard automatic == nil || isCurrent?() == true else { return false }
        let key = TelegramMediaKey(attachmentID: attachment.id, purpose: purpose)
        if let phase = jobs[key]?.phase {
            if phase == .ready {
                if automatic == nil { jobs[key]?.automatic = false }
                return false
            }
            if case .downloading = phase {
                if automatic != nil || jobs[key]?.automatic != true { return false }
                // A manual action owns a new lease, independent of automatic admission.
            }
        }
        let reservation: (any TelegramMediaArchiveReservation)?
        if automatic != nil, let reserveAutomaticFile {
            guard let granted = reserveAutomaticFile(attachment.id) else { return false }; reservation = granted
        } else { reservation = nil }
        remove(key)
        let token = UUID()
        jobs[key] = Job(token: token, phase: .downloading(nil), completedFile: completedFullFile,
            automatic: automatic != nil, automaticIsCurrent: isCurrent)
        jobs[key]?.holder.archiveReservation = reservation
        jobs[key]?.deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            self?.timeout(key, token: token)
        }
        revision &+= 1
        let receive: @MainActor (TelegramMediaEvent) -> Void = { [weak self] event in
            self?.receive(event, key: key, token: token)
        }
        let lease = automatic.map { provider.startAutomatically(attachmentID: attachment.id, preferences: $0,
            isCurrent: isCurrent ?? { false }, receive: receive) }
            ?? provider.start(attachmentID: attachment.id, purpose: purpose, receive: receive)
        // A provider may emit completion, failure or cancellation synchronously.
        guard let current = jobs[key], current.token == token else { lease.cancel(); return true }
        switch current.phase {
        case .downloading, .ready:
            current.holder.lease = lease
            if current.holder.releasePending { current.holder.release() }
        default: lease.cancel()
        }
        return true
    }

    public func cancel(_ key: TelegramMediaKey) { finish(key, phase: .cancelled) }

    /// Deterministic deadline seam for tests; real timers also check their token.
    func timeout(_ key: TelegramMediaKey) {
        guard let token = jobs[key]?.token else { return }
        timeout(key, token: token)
    }

    private func timeout(_ key: TelegramMediaKey, token: UUID) {
        guard let job = jobs[key], job.token == token, case .downloading = job.phase else { return }
        finish(key, phase: .timedOut)
    }

    private func receive(_ event: TelegramMediaEvent, key: TelegramMediaKey, token: UUID) {
        guard let job = jobs[key], job.token == token, case .downloading = job.phase else { return }
        if job.automatic, job.automaticIsCurrent?() != true { finish(key, phase: .cancelled); return }
        switch event {
        case .progress(let value):
            jobs[key]?.phase = .downloading(value.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil })
        case let .data(url, offset, size, complete):
            guard complete, offset == 0, size >= 0, url.isFileURL else { return }
            let reservedCapture = job.holder.archiveReservation != nil
            if let reservation = job.holder.archiveReservation {
                let captured = reservation.capture(file: url, byteCount: size)
                guard jobs[key]?.token == token else { return }
                guard captured else { finish(key, phase: .failed); return }
                job.holder.archiveReservation = nil
            }
            guard jobs[key]?.token == token else { return }
            jobs[key]?.phase = .ready
            jobs[key]?.file = url
            jobs[key]?.size = size
            jobs[key]?.deadline?.cancel()
            jobs[key]?.deadline = nil
            // Freeze the descriptor before any asynchronous archive work. An open
            // FD survives Telegram's force-unlink even when its cache lease cannot.
            if !reservedCapture && key.purpose == .full { job.completedFile?(key.attachmentID,url,size) }
        case .failed:
            finish(key, phase: .failed)
            return
        case .fetchCompleted:
            // Fetch termination is not proof of a complete readable resource.
            return
        }
        revision &+= 1
    }

    private func finish(_ key: TelegramMediaKey, phase: TelegramMediaPhase) {
        guard let old = jobs[key] else { return }
        // Invalidate before invoking provider cancellation, which may emit events.
        jobs[key] = Job(token: UUID(), phase: phase)
        revision &+= 1
        old.deadline?.cancel()
        old.holder.release()
    }

    private func remove(_ key: TelegramMediaKey) {
        guard let old = jobs.removeValue(forKey: key) else { return }
        revision &+= 1
        old.deadline?.cancel(); old.holder.release()
    }
}
