import CPostgres
import Foundation
import MakoshCore

/// The synthetic Files preview runs only with its own flag, an explicit
/// absolute database configuration and `qa_files_` schemas on loopback PostgreSQL.
public enum FilesQAIsolation {
    public static let flag = "--files-synthetic-preview"
    public static let schemaPrefix = "qa_files_"
    public enum Failure: Error, Equatable { case invalidConfiguration }

    public static func validate(configuration: ContactWorkspaceConfiguration, arguments: [String]) throws {
        let flags = [flag, "--database-config"]
        guard flags.allSatisfy({ flag in arguments.filter { $0 == flag }.count == 1 }),
            arguments.filter({ $0.hasPrefix("--") }).allSatisfy({ flags.contains($0) }),
            let index = arguments.firstIndex(of: "--database-config"), arguments.indices.contains(index + 1),
            arguments[index + 1].hasPrefix("/"), !arguments[index + 1].utf8.contains(0)
        else { throw Failure.invalidConfiguration }
        let schemas = [configuration.schema, configuration.archiveSchema ?? configuration.schema]
        guard
            schemas.allSatisfy({ schema in
                schema.hasPrefix(schemaPrefix) && schema.utf8.count > schemaPrefix.utf8.count && schema.utf8.count <= 63
                    && schema.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
            }), !configuration.connectionString.utf8.contains(0)
        else { throw Failure.invalidConfiguration }
        var error: UnsafeMutablePointer<CChar>?
        guard let parsed = PQconninfoParse(configuration.connectionString, &error) else {
            if let error { PQfreemem(error) }
            throw Failure.invalidConfiguration
        }
        defer {
            PQconninfoFree(parsed)
            if let error { PQfreemem(error) }
        }
        var values: [String: String] = [:]
        var position = 0
        while let keyword = parsed[position].keyword {
            if let value = parsed[position].val { values[String(cString: keyword)] = String(cString: value) }
            position += 1
        }
        let allowed: Set<String> = [
            "host", "hostaddr", "port", "dbname", "user", "password", "sslmode", "connect_timeout", "application_name",
        ]
        guard Set(values.keys).isSubset(of: allowed), ["127.0.0.1", "::1", "localhost"].contains(values["host"] ?? ""),
            ["127.0.0.1", "::1"].contains(values["hostaddr"] ?? "")
        else { throw Failure.invalidConfiguration }
        if let port = values["port"], Int(port).map({ (1...65535).contains($0) }) != true { throw Failure.invalidConfiguration }
    }
}

/// Six retained files from four services with their messages, written once:
/// fixed identifiers and dates make a second seeding a no-op.
public enum FilesSyntheticSeed {
    static let files:
        [(
            service: String, account: String, chat: String, message: String, attachment: String, name: String, kind: String, author: String,
            text: String
        )] = [
            (
                "mail", "qa-mail", "SU5CT1g=", "1:101", "0", "Счёт за ноябрь.pdf", "document", "ООО «Свет»",
                "Тема: Счёт № 1187\nКому: вы\n\nСчёт во вложении."
            ),
            (
                "mail", "qa-mail", "SU5CT1g=", "1:102", "0", "Заметки к встрече.txt", "document", "Мария",
                "Тема: Заметки\nКому: вы\n\nКак договаривались."
            ),
            ("telegram", "qa-tg", "777000", "0:11", "doc-11", "Договор аренды.docx", "file", "Иван", "Договор, посмотри."),
            ("telegram", "qa-tg", "777000", "0:12", "zip-12", "Архив проекта.zip", "file", "Иван", "Материалы по проекту."),
            ("whatsapp", "qa-wa", "34600000000@s.whatsapp.net", "wa-21", "img-21", "IMG_2031.jpg", "image", "Мария", "Фото со встречи."),
            ("teams", "qa-teams", "qa-teams-chat", "teams-31", "pptx-31", "Презентация.pptx", "file", "Коллега", "Слайды к созвону."),
        ]

    public static func seed(_ store: MessageArchiveStore) throws {
        let vault = try store.fileVault()
        let hash = String(repeating: "cd", count: 32)
        for (index, file) in files.enumerated() {
            let identity = MessageArchiveIdentity(
                service: file.service, accountID: file.account, conversationID: file.chat, messageID: file.message)
            let date = Date(timeIntervalSince1970: 1_800_100_000 + Double(index) * 3_600)
            _ = try store.append([
                MessageArchiveObservation(
                    id: UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", index + 1))!, identity: identity,
                    observedAt: date, source: .synthetic,
                    event: .message(
                        MessageArchiveContent(
                            date: date, text: file.text, author: file.author, authorID: "qa-\(index)", isOutgoing: false,
                            attachments: [.init(id: file.attachment, kind: file.kind, name: file.name, size: 1024)])))
            ])
            let id = UUID(uuidString: String(format: "00000000-0000-4000-a000-%012d", index + 1))!
            let receipt = ArchiveFileEnvelopeReceipt(byteCount: 2048, sha256: hash, plaintextByteCount: 1024, plaintextSHA256: hash)
            let record = ArchiveFileRecord(
                id: id, identity: identity, attachment: .init(id: file.attachment, kind: file.kind, name: file.name, size: 1024),
                objectKey: "vaults/\(vault.id.uuidString.lowercased())/files/\(id.uuidString.lowercased())", storageID: hash,
                receipt: receipt, capturedAt: date.addingTimeInterval(5), state: .stored, purpose: .conversation(defaultEnabled: true))
            _ = try store.appendFile(record)
        }
    }
}

/// An in-memory Keychain for the synthetic preview.
extension FileStorageKeychainAccess {
    public static func memory() -> FileStorageKeychainAccess {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var items: [UUID: Data] = [:]
        }
        let box = Box()
        return FileStorageKeychainAccess(
            read: { id in box.lock.withLock { box.items[id].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil) } },
            write: { id, data in
                box.lock.withLock { box.items[id] = data }
                return errSecSuccess
            },
            remove: { id in box.lock.withLock { box.items.removeValue(forKey: id) == nil ? errSecItemNotFound : errSecSuccess } })
    }
}

/// A Paperless that lives in memory: three documents, every upload accepted as #7.
public final class PaperlessSyntheticService: PaperlessServing, @unchecked Sendable {
    public static let documents = [
        PaperlessDocument(
            id: 1, title: "Паспорт", created: Date(timeIntervalSince1970: 1_700_000_000), documentType: 1, tags: [3],
            originalFileName: "passport.pdf"),
        PaperlessDocument(
            id: 2, title: "Счёт за октябрь", created: Date(timeIntervalSince1970: 1_790_000_000), documentType: 2, tags: [1, 2],
            originalFileName: "invoice-10.pdf"),
        PaperlessDocument(
            id: 3, title: "Договор аренды", created: Date(timeIntervalSince1970: 1_795_000_000), documentType: 2, tags: [3],
            originalFileName: "lease.pdf"),
    ]
    private let lock = NSLock()
    private var polls = 0
    public init() {}
    public func status() async throws -> PaperlessStatus { PaperlessStatus(documentCount: Self.documents.count, version: "synthetic") }
    public func tags() async throws -> [PaperlessNamed] {
        [.init(id: 1, name: "Входящие"), .init(id: 2, name: "Требует проверки"), .init(id: 3, name: "Проверено")]
    }
    public func documentTypes() async throws -> [PaperlessNamed] {
        [.init(id: 1, name: "Личные документы"), .init(id: 2, name: "Финансы")]
    }
    public func documents(query: String, page: Int) async throws -> PaperlessPage<PaperlessDocument> {
        let needle = query.lowercased()
        let items = Self.documents.filter { needle.isEmpty || $0.title.lowercased().contains(needle) }
        return PaperlessPage(items: page == 1 ? items : [], hasMore: false)
    }
    public func download(id: Int, original: Bool, to destination: URL) async throws {
        try Data("%PDF-1.7\n% synthetic document \(id)\n".utf8).write(to: destination, options: .withoutOverwriting)
    }
    public func document(id: Int) async throws -> PaperlessDocumentDetail {
        guard let document = Self.documents.first(where: { $0.id == id }) else { throw FilesFailure.unexpectedResponse }
        return PaperlessDocumentDetail(
            id: id, title: document.title, content: "Синтетический текст документа «\(document.title)».",
            originalFileName: document.originalFileName, pageCount: 1)
    }
    public func upload(file: URL, name: String, options: PaperlessUpload) async throws -> String {
        lock.withLock { polls = 0 }
        return "qa-task-\(UUID().uuidString)"
    }
    public func task(id: String) async throws -> PaperlessTaskState {
        let count = lock.withLock { () -> Int in
            polls += 1
            return polls
        }
        return count < 2 ? .started : .success(documentID: 7)
    }
    public func documentURL(id: Int) -> URL { URL(string: "https://paperless.synthetic/documents/\(id)/details")! }
}
