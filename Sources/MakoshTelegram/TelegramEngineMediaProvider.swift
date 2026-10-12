import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

/// Sources are account-bound protocol references, never persisted in dossiers.
@MainActor
final class TelegramEngineMediaProvider: TelegramMediaProvider {
    var sources: [String: TelegramAttachmentSource] = [:]
    private let mediaBox: MediaBox

    init(account: Account) { mediaBox = account.postbox.mediaBox }

    func start(attachmentID: String, purpose: TelegramMediaPurpose,
               receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
        let lease = EngineMediaLease(receive: receive)
        guard let source = sources[attachmentID],
              let reference = purpose == .full ? source.full : source.preview else {
            receive(.failed)
            return lease
        }
        let resource = reference.resource
        // Keep the cache entry alive through ready-state use, not just fetching.
        lease.keep.set(mediaBox.keepResource(id: resource.id).start())
        lease.status.set((mediaBox.resourceStatus(resource) |> deliverOnMainQueue).start(next: { [weak lease] status in
            guard let lease, !lease.finished else { return }
            switch status {
            case let .Remote(progress), let .Fetching(_, progress), let .Paused(progress):
                lease.receive(.progress(Double(progress)))
            case .Local: break // Only complete data proves a usable whole file.
            }
        }))
        lease.data.set((mediaBox.resourceData(resource, pathExtension: nil,
            option: .complete(waitUntilFetchStatus: false)) |> deliverOnMainQueue).start(next: { [weak lease] data in
                guard let lease, !lease.finished else { return }
                lease.receive(.data(URL(fileURLWithPath: data.path), offset: data.offset,
                                    size: data.size, complete: data.complete))
                if data.complete && data.offset == 0 && data.size >= 0 {
                    lease.finishTransfer()
                }
            }))
        if !lease.finished {
            lease.fetch.set((fetchedMediaResource(mediaBox: mediaBox, userLocation: source.location,
                userContentType: purpose == .preview ? .image : source.contentType, reference: reference, continueInBackground: false)
                |> deliverOnMainQueue).start(error: { [weak lease] _ in
                    guard let lease, !lease.finished else { return }
                    lease.receive(.failed)
                    lease.cancel()
                }, completed: { [weak lease] in
                    guard let lease, !lease.finished else { return }
                    lease.receive(.fetchCompleted)
                }))
        }
        return lease
    }
}

@MainActor
private final class EngineMediaLease: TelegramMediaLease {
    let keep = MetaDisposable()
    let status = MetaDisposable()
    let data = MetaDisposable()
    let fetch = MetaDisposable()
    let receive: @MainActor (TelegramMediaEvent) -> Void
    private(set) var finished = false
    private var cancelled = false

    init(receive: @escaping @MainActor (TelegramMediaEvent) -> Void) { self.receive = receive }

    func finishTransfer() {
        guard !finished else { return }
        finished = true
        // Permanent disposal also handles synchronous emissions before set().
        status.dispose(); data.dispose(); fetch.dispose()
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true; finished = true
        keep.dispose(); status.dispose(); data.dispose(); fetch.dispose()
    }

    isolated deinit { keep.dispose(); status.dispose(); data.dispose(); fetch.dispose() }
}
