import Foundation
import MakoshCore

public enum FileCategory: String, CaseIterable, Sendable {
    case document, image, video, audio, archive, other

    private static let extensions: [FileCategory: Set<String>] = [
        .document: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "rtf", "csv", "odt", "ods", "pages", "numbers"],
        .image: ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg"],
        .video: ["mp4", "mov", "mkv", "avi", "webm", "m4v"],
        .audio: ["mp3", "m4a", "ogg", "oga", "opus", "wav", "flac", "aac"],
        .archive: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"],
    ]
    private static let kinds: [String: FileCategory] = [
        "photo": .image, "image": .image, "video": .video, "audio": .audio, "voice": .audio, "music": .audio,
    ]

    /// The extension decides; a service's media kind decides for names without one.
    public static func classify(name: String, kind: String) -> FileCategory {
        let suffix = (name as NSString).pathExtension.lowercased()
        if let category = extensions.first(where: { $0.value.contains(suffix) })?.key { return category }
        return kinds[kind.lowercased()] ?? .other
    }

    public var title: String {
        switch self {
        case .document: "Документы"
        case .image: "Изображения"
        case .video: "Видео"
        case .audio: "Аудио"
        case .archive: "Архивы"
        case .other: "Остальное"
        }
    }
}

/// One retained file as the catalogue shows it; only metadata, never bytes.
public struct FileCatalogueItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let record: ArchiveFileRecord
    public let messageDate: Date?
    public let author: String?
    public var sourceTitle: String?

    public init(record: ArchiveFileRecord, messageDate: Date?, author: String?, sourceTitle: String? = nil) {
        id = record.id
        self.record = record
        self.messageDate = messageDate
        self.author = author
        self.sourceTitle = sourceTitle
    }
    public var name: String { record.attachment.name }
    public var byteCount: Int64 { record.plaintextByteCount }
    public var service: String { record.identity.service }
    public var identity: MessageArchiveIdentity { record.identity }
    /// The message date when the archive has it, else when the copy was captured.
    public var date: Date { messageDate ?? record.capturedAt }
    public var category: FileCategory { FileCategory.classify(name: name, kind: record.attachment.kind) }
}

/// Titles of chats and letters, supplied by the services that know them.
public protocol FileSourceResolving: Sendable {
    func sourceTitle(for identity: MessageArchiveIdentity) async -> String?
}

/// Reads stored file receipts by cursor and keeps the newest receipt per
/// attachment. Whole copies of letters (`rfc822-source`) are not files to a person.
public actor FileCatalogue {
    public static let pageSize = 200
    static let rawLetterAttachment = "rfc822-source"
    private let connectionString: String
    private let schema: String
    private let keyProvider: @Sendable (UUID, Bool) throws -> Data
    private var store: MessageArchiveStore?
    private var cursor: Int64 = 0
    private var latest: [String: FileCatalogueItem] = [:]
    private var titles: [MessageArchiveIdentity: String?] = [:]
    public private(set) var items: [FileCatalogueItem] = []

    public init(
        connectionString: String, schema: String,
        keyProvider: @escaping @Sendable (UUID, Bool) throws -> Data = MessageArchiveKeychain.open
    ) {
        self.connectionString = connectionString
        self.schema = schema
        self.keyProvider = keyProvider
    }

    /// Reads every receipt after the cursor, then returns the whole list newest first.
    public func refresh(resolver: (any FileSourceResolving)?) async throws -> [FileCatalogueItem] {
        let store = try open()
        var changed: [MessageArchiveIdentity] = []
        do {
            while true {
                let page = try store.fileEvents(after: cursor, limit: Self.pageSize)
                for event in page {
                    let record = event.record
                    if record.attachment.id != Self.rawLetterAttachment {
                        // The message row is read before the cursor moves: a damaged
                        // row keeps failing visibly instead of dropping the file.
                        let message = try store.latestRecord(identity: record.identity)
                        var date: Date?, author: String?
                        if case .message(let content)? = message?.observation.event {
                            date = content.date
                            author = content.author
                        }
                        latest[Self.key(record)] = FileCatalogueItem(record: record, messageDate: date, author: author)
                        changed.append(record.identity)
                    }
                    cursor = event.sequence
                }
                if page.count < Self.pageSize { break }
            }
        } catch let error as MessageArchiveError {
            throw Self.failure(error)
        }
        if let resolver {
            // Unknown titles are asked again: a service may have loaded its chats since.
            let pending = Set(changed + titles.compactMap { $0.value == nil ? $0.key : nil })
            for identity in pending where (titles[identity] ?? nil) == nil {
                titles[identity] = .some(await resolver.sourceTitle(for: identity))
            }
        }
        items = latest.values.map { item in
            var item = item
            item.sourceTitle = titles[item.identity] ?? nil
            return item
        }.sorted { ($0.date, $0.record.capturedAt, $0.id.uuidString) > ($1.date, $1.record.capturedAt, $1.id.uuidString) }
        return items
    }

    private func open() throws -> MessageArchiveStore {
        if let store { return store }
        do {
            let value = try MessageArchiveStore(connectionString: connectionString, schema: schema, keyProvider: keyProvider)
            store = value
            return value
        } catch let error as MessageArchiveError { throw Self.failure(error) }
    }

    private static func key(_ record: ArchiveFileRecord) -> String {
        let i = record.identity
        return [i.service, i.accountID, i.conversationID, i.messageID, record.attachment.id].map { "\($0.utf8.count):\($0)" }.joined()
    }

    private static func failure(_ error: MessageArchiveError) -> FilesFailure {
        switch error {
        case .integrity: .integrity
        case .keyUnavailable: .keyUnavailable
        case .invalid, .database, .unsupportedSchema: .archiveUnavailable
        }
    }
}
