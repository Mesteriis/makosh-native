import Foundation

/// Recovery owns canonical items and its optional ZIP as one lifetime.
struct TelegramRecoveredUploadBundle: Sendable {
    let items: [TelegramUploadBatchItem]
    let archive: TelegramUploadArchiveIO.Archive?

    func discard() throws {
        var failure: (any Error)?
        for item in items {
            do { try item.discard() } catch { if failure == nil { failure = error } }
        }
        if let archive {
            do { try TelegramUploadFileIO.discard(archive.file) } catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
    }
}
