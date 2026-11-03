import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

@MainActor final class TelegramCustomEmojiEngineResourceProvider: TelegramCustomEmojiResourceProvider {
    let accountID: Int64
    let engine: TelegramEngine
    private let mediaBox: MediaBox
    init(account: Account) {
        self.accountID = account.peerId.toInt64(); self.engine = TelegramEngine(account: account)
        self.mediaBox = account.postbox.mediaBox
    }
    func start(descriptor: TelegramCustomEmojiDescriptor,
        receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
        let lease = TelegramCustomEmojiEngineResourceLease(receive: receive)
        lease.resolve.set((engine.stickers.resolveInlineStickers(fileIds: [descriptor.fileID])
            |> deliverOnMainQueue).start(next: { [weak self, weak lease] files in
                MainActor.assumeIsolated {
                    guard let self, let lease, !lease.finished,
                          let file = files[descriptor.fileID],
                          (try? TelegramCustomEmojiDescriptor(file: file)) == descriptor,
                          file.size.map({ $0 > 0 && $0 <= 8 * 1024 * 1024 }) ?? true else {
                        lease?.reject(); return
                    }
                    lease.resolve.dispose()
                    let reference = FileMediaReference.standalone(media: file).resourceReference(file.resource)
                    lease.keep.set(self.mediaBox.keepResource(id: file.resource.id).start())
                    lease.data.set((self.mediaBox.resourceData(file.resource, pathExtension: nil,
                        option: .complete(waitUntilFetchStatus: false)) |> deliverOnMainQueue).start(next: { [weak lease] data in
                            MainActor.assumeIsolated {
                                guard let lease, !lease.finished else { return }
                                lease.receive(.data(URL(fileURLWithPath: data.path), offset: data.offset,
                                    size: data.size, complete: data.complete))
                                if data.complete && data.offset == 0 && data.size > 0 { lease.finishTransfer() }
                            }
                        }))
                    if !lease.finished {
                        lease.fetch.set((fetchedMediaResource(mediaBox: self.mediaBox, userLocation: .other,
                            userContentType: .sticker, reference: reference, continueInBackground: false)
                            |> deliverOnMainQueue).start(error: { [weak lease] _ in
                                MainActor.assumeIsolated { lease?.reject() }
                            }, completed: { [weak lease] in
                                MainActor.assumeIsolated {
                                    guard let lease, !lease.finished else { return }; lease.receive(.fetchCompleted)
                                }
                            }))
                    }
                }
            }))
        return lease
    }
}
@MainActor private final class TelegramCustomEmojiEngineResourceLease: TelegramMediaLease {
    let resolve = MetaDisposable(), keep = MetaDisposable(), data = MetaDisposable(), fetch = MetaDisposable()
    let receive: @MainActor (TelegramMediaEvent) -> Void
    private(set) var finished = false
    private var cancelled = false
    init(receive: @escaping @MainActor (TelegramMediaEvent) -> Void) { self.receive = receive }
    func finishTransfer() {
        guard !finished else { return }; finished = true
        resolve.dispose(); data.dispose(); fetch.dispose()
    }
    func reject() { guard !finished else { return }; receive(.failed); cancel() }
    func cancel() {
        guard !cancelled else { return }; cancelled = true; finished = true
        resolve.dispose(); data.dispose(); fetch.dispose(); keep.dispose()
    }
    isolated deinit { resolve.dispose(); data.dispose(); fetch.dispose(); keep.dispose() }
}
