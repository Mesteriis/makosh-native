#if DEBUG
import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

/// Owned UI fixtures. There is no Account, server, S3 client or personal cache.
@MainActor struct TelegramCustomEmojiSyntheticState {
    let catalogProvider: any TelegramCustomEmojiCatalogProvider
    let playbackContext: TelegramCustomEmojiPlaybackContext
    let descriptors: [Int64: TelegramCustomEmojiDescriptor]
    static func make(accountID: Int64 = -1) throws -> Self {
        let provider = try TelegramCustomEmojiSyntheticProvider(accountID: accountID)
        return .init(catalogProvider: provider,
            playbackContext: .init(accountID: accountID, provider: provider), descriptors: provider.descriptors)
    }
}
@MainActor private final class TelegramCustomEmojiSyntheticProvider: TelegramCustomEmojiResourceProvider,
    TelegramCustomEmojiInlineResolverProvider, TelegramCustomEmojiCatalogProvider {
    let accountID: Int64
    let descriptors: [Int64: TelegramCustomEmojiDescriptor]
    private let bytes: [Int64: Data]
    private let snapshots: ValuePromise<TelegramCustomEmojiCatalogSnapshot>
    private var installed = false
    private var pack: TelegramCustomEmojiPack {
        .init(id: 77, reference: .id(id: 77, accessHash: 79), title: "Синтетические эмодзи",
            shortName: "synthetic_custom_emoji", itemCount: descriptors.count, installed: installed,
            items: descriptors.values.sorted { $0.fileID < $1.fileID }, itemsComplete: true)
    }
    init(accountID: Int64) throws {
        self.accountID = accountID
        let fixtures: [(Int64, String, String, Data)] = [
            (901, "🦊", "image/webp", Data(base64Encoded: "UklGRhwAAABXRUJQVlA4TA8AAAAvE0ACAAcQ/Y/+ByKi/wEA")!),
            (902, "🐻", "application/x-tgsticker", Data(base64Encoded: "H4sIAAAAAAAC/3VRy26EMAz8FeSztSKoq0r8Ro+rHNwQCl1IUJJuhRD/XsfQqmy7ivIae8bjZIEb1HA+nU/PgNAGqCuEfoK6RPCT3D6hfkLo5OxGzn6ZXeps6k1hPmLyY2FH/94zvWkaIVKMNkWoLxphoNmGfF5+wr3jXSGkWZRFs6OhLQy5G0UWikESrsxbwOeFhHlluCxXhHDAMjIdkEuJPDTj9ACPR5xlcZ96zTQvodjRZDf32S0Ek9sUc3cCFVb6rw2FSv9rV5oO1iRyb4OFFfcC7cAFzJ6uNhEObWZEMHegtHyIEtq3G+5N/Y7lwg/eTu0GyPUjJdsUxg8+wKrv/z5ulV/H7FqvX8E8WuouAgAA")!),
            (903, "🐯", "video/webm", Data(base64Encoded: "GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQJChYECGFOAZwEAAAAAAAKVEU2bdLpNu4tTq4QVSalmU6yBoU27i1OrhBZUrmtTrIHWTbuMU6uEElTDZ1OsggE2TbuMU6uEHFO7a1OsggJ/7AEAAAAAAABZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAVSalmsCrXsYMPQkBNgIxMYXZmNjMuMS4xMDJXQYxMYXZmNjMuMS4xMDJEiYhAj0AAAAAAABZUrmvbrgEAAAAAAABS14EBc8WILZqr+Z+uSE2cgQAitZyDdW5kiIEAhoVWX1ZQOYOBASPjg4QdzWUA4JSwgQS6gQKagQJTwIEBVbCEVbmBAVXugQHsAQAAAAAAAAIAABJUw2f2c3OfY8CAZ8iZRaOHRU5DT0RFUkSHjExhdmY2My4xLjEwMnNz0WPAi2PFiC2aq/mfrkhNZ8icRaOHRU5DT0RFUkSHj0xhdmMgbGlidnB4LXZwOWfIoUWjiERVUkFUSU9ORIeTMDA6MDA6MDEuMDAwMDAwMDAwAB9DtnVAyOeBAKDjobqBAAAAgkmDQgAAMAAWADgkHBgAAAAgAAAgy////D97/TDCU///NXRZudL+9/////BlPxMmbgWvBjgAdaGkpqLugQGlnYJJg0IAADAAFgA4JBwYAAAAIAAAIMuaP/91FOAAoN6htoEB9ACGAECS8AEAAAAIAAABs3///rCH+slDT////3RvfqaS+dI36mWf////2CA7/pdR7eodAHWhn6ad7oEBpZiGAECS8AEAAAAIAAABs3///23z/37uAAD7gv4MHFO7a5G7j7OBALeK94EB8YIBsfCBAw==")!)
        ]
        var values: [Int64: TelegramCustomEmojiDescriptor] = [:], content: [Int64: Data] = [:]
        for (id, alt, mime, data) in fixtures {
            let file = TelegramMediaFile(fileId: .init(namespace: Namespaces.Media.CloudFile, id: id), partialReference: nil,
                resource: CloudDocumentMediaResource(datacenterId: 2, fileId: id, accessHash: 1,
                    size: Int64(data.count), fileReference: Data([1]), fileName: "synthetic-emoji"),
                previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: mime,
                size: Int64(data.count), attributes: [.CustomEmoji(isPremium: false, isSingleColor: false,
                    alt: alt, packReference: .id(id: 77, accessHash: 79))], alternativeRepresentations: [])
            values[id] = try TelegramCustomEmojiDescriptor(file: file); content[id] = data
        }
        descriptors = values; bytes = content
        snapshots = ValuePromise(.init(accountID: accountID, entitlement: .standard, recent: [], installed: [], featured: []),
            ignoreRepeated: true)
        publish()
    }
    private func publish() {
        snapshots.set(.init(accountID: accountID, entitlement: .standard,
            recent: descriptors.values.sorted { $0.fileID < $1.fileID }, installed: installed ? [pack] : [],
            featured: installed ? [] : [pack]))
    }
    func catalog() -> Signal<TelegramCustomEmojiCatalogSnapshot, NoError> { snapshots.get() }
    func search(query: String) -> Signal<TelegramCustomEmojiSearchResult, NoError> {
        let query = query.lowercased()
        let found = descriptors.values.filter { $0.fallbackText.contains(query) ||
            ["emoji", "synthetic", "эмодзи", "синтетический"].contains(where: { $0.contains(query) }) }
        return .single(.init(items: found.sorted { $0.fileID < $1.fileID }, isFinal: true))
    }
    func loadPack(reference: TelegramStickerPackReference) -> Signal<TelegramCustomEmojiPackResult, NoError> {
        reference == pack.reference ? .single(.ready(pack)) : .single(.unavailable)
    }
    func setInstalled(pack: TelegramCustomEmojiPack, installed: Bool) -> Signal<Bool, NoError> {
        guard pack.id == self.pack.id, pack.reference == self.pack.reference, pack.items == self.pack.items else { return .single(false) }
        self.installed = installed; publish(); return .single(true)
    }
    func resolveDescriptors(fileIDs: [Int64]) -> Signal<[Int64: TelegramCustomEmojiDescriptor], NoError> {
        let requested = Set(fileIDs); return .single(descriptors.filter { requested.contains($0.key) })
    }
    func start(descriptor: TelegramCustomEmojiDescriptor,
        receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
        let lease = TelegramCustomEmojiSyntheticLease()
        guard descriptors[descriptor.fileID] == descriptor, let data = bytes[descriptor.fileID] else {
            receive(.failed); return lease
        }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-synthetic-emoji-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            lease.folder = folder
            let file = folder.appendingPathComponent("fixture")
            try data.write(to: file, options: .atomic)
            receive(.data(file, offset: 0, size: Int64(data.count), complete: true))
        } catch { lease.cancel(); receive(.failed) }
        return lease
    }
}
@MainActor private final class TelegramCustomEmojiSyntheticLease: TelegramMediaLease {
    var folder: URL?
    func cancel() { if let folder { try? FileManager.default.removeItem(at: folder) }; folder = nil }
    isolated deinit { if let folder { try? FileManager.default.removeItem(at: folder) } }
}
#endif
