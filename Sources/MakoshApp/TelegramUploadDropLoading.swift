import AppKit
import UniformTypeIdentifiers

@MainActor enum TelegramUploadDropLoading {
    static func urls(_ providers: [NSItemProvider], timeout: Duration = .seconds(30)) async throws -> [URL] {
        guard !providers.isEmpty, timeout > .zero else { throw CocoaError(.fileReadUnknown) }
        var urls: [URL] = []
        for provider in providers {
            try Task.checkCancellation()
            let boundary = DropProviderLoad()
            let data: Data = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    guard boundary.attach(continuation) else { return }
                    boundary.setDeadline(Task {
                        do { try await Task.sleep(for: timeout) } catch { return }
                        boundary.finish(.failure(CocoaError(.fileReadUnknown)))
                    })
                    boundary.setProgress(provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                        if let data, error == nil { boundary.finish(.success(data)) }
                        else { boundary.finish(.failure(error ?? CocoaError(.fileReadUnknown))) }
                    })
                }
            } onCancel: { boundary.finish(.failure(CancellationError())) }
            try Task.checkCancellation()
            guard data.count <= 65_536, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost" else { throw CocoaError(.fileReadUnknown) }
            urls.append(url)
        }
        return urls
    }
}

/// Item-provider callbacks can race cancellation, timeout and synchronous completion.
/// The lock owns a single completion, including cancellation before attach.
private final class DropProviderLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, any Error>?
    private var continuation: CheckedContinuation<Data, any Error>?
    private var progress: Progress?
    private var deadline: Task<Void, Never>?

    func attach(_ continuation: CheckedContinuation<Data, any Error>) -> Bool {
        let completed = lock.withLock { () -> Result<Data, any Error>? in
            if let result { return result }
            self.continuation = continuation; return nil
        }
        if let completed { continuation.resume(with: completed); return false }
        return true
    }
    func setProgress(_ progress: Progress?) {
        let finished = lock.withLock { if result != nil { return true }; self.progress = progress; return false }
        if finished { progress?.cancel() }
    }
    func setDeadline(_ task: Task<Void, Never>) {
        let finished = lock.withLock { if result != nil { return true }; deadline = task; return false }
        if finished { task.cancel() }
    }
    func finish(_ value: Result<Data, any Error>) {
        let pending = lock.withLock { () -> (CheckedContinuation<Data, any Error>?, Progress?, Task<Void, Never>?)? in
            guard result == nil else { return nil }
            result = value
            let pending = (continuation, progress, deadline)
            continuation = nil; progress = nil; deadline = nil
            return pending
        }
        guard let pending else { return }
        pending.2?.cancel(); pending.1?.cancel(); pending.0?.resume(with: value)
    }
}
