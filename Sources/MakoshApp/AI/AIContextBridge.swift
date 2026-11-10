import Foundation
import MakoshAI
import MakoshCore
import MakoshFiles
import MakoshMail
import MakoshTelegram
import MakoshWhatsApp

/// Reads attached cards from the services and applies the access rules.
/// History is read on each service's executor; only finished material leaves.
final class AIContextBridge: AIContextProvider, @unchecked Sendable {
    private let telegram: @MainActor () -> (any TelegramAIContextReading)?
    private let whatsapp: @MainActor () -> (any WhatsAppServing)?
    private let mail: MailRepository?
    private let contacts: PersonWorkspaceWorker?
    private let access: any AIAccessProvider
    /// WhatsApp pages are read until the period is covered, at most this many messages.
    static let whatsappLimit = 5_000
    private var files: FilesHost?
    private var extractor: FileTextExtractor?
    private var progress: (@Sendable (String, AIExtractionProgress?) -> Void)?
    /// Extracted text and its fallback per card and page range, for the session.
    private let fileCache = FileMaterialCache()

    /// A removed card's text leaves the session cache.
    func forget(cardID: String) async { await fileCache.forget(cardID: cardID) }

    /// File cards need the Files host (archive, Paperless, staging) and the extractor.
    func attachFiles(
        _ files: FilesHost?, extractor: FileTextExtractor, progress: @escaping @Sendable (String, AIExtractionProgress?) -> Void
    ) {
        self.files = files
        self.extractor = extractor
        self.progress = progress
    }

    init(
        telegram: @escaping @MainActor () -> (any TelegramAIContextReading)?, whatsapp: @escaping @MainActor () -> (any WhatsAppServing)?,
        mail: MailRepository?, contacts: PersonWorkspaceWorker?, access: any AIAccessProvider
    ) {
        self.telegram = telegram
        self.whatsapp = whatsapp
        self.mail = mail
        self.contacts = contacts
        self.access = access
    }

    func material(for card: AIContextCard) async throws -> AIContextMaterial {
        do { return try await read(card) } catch let failure as AIFailure { throw failure } catch is CancellationError {
            throw AIFailure.cancelled
        } catch {
            // A service's own error must not reach the conversation as an unknown failure.
            throw AIFailure.contextUnavailable("Не удалось прочитать «\(card.title)».")
        }
    }

    private func read(_ card: AIContextCard) async throws -> AIContextMaterial {
        let snapshot = try await access.snapshot()
        switch card {
        case .chat("telegram", let accountID, let chatID, _, let range):
            return try await telegramMaterial(card, accountID: accountID, chatID: chatID, range: range, snapshot: snapshot)
        case .chat("whatsapp", let accountID, let chatID, _, let range):
            return try await whatsappMaterial(card, accountID: accountID, chatID: chatID, range: range, snapshot: snapshot)
        case .chat(let service, _, _, _, _):
            throw AIFailure.contextUnavailable("Чаты \(service) пока нельзя прикрепить.")
        case .letter(let id, _):
            return try await letterMaterial(card, id: id, snapshot: snapshot)
        case .contact(let id, _):
            return try await contactMaterial(card, id: id, snapshot: snapshot)
        case .file(let source, _, let pages):
            return try await fileMaterial(card, source: source, pages: pages, snapshot: snapshot)
        }
    }

    /// Bytes come from the archive, Paperless or the staged copy into a private
    /// directory; text is read on the Mac, Paperless OCR only as a fallback.
    /// A cached read is reused without downloading anything again.
    private func fileMaterial(
        _ card: AIContextCard, source: AIFileSource, pages: ClosedRange<Int>?, snapshot: AIAccessSnapshot
    ) async throws
        -> AIContextMaterial
    {
        guard let files, let extractor else { throw AIFailure.contextUnavailable("Файлы ещё не готовы.") }
        let cardID = card.id, report = progress
        let key = "\(cardID)|\(pages.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "all")"
        let kind: String
        switch source {
        case .archive: kind = "archive"
        case .paperless: kind = "paperless"
        case .staged: kind = "staged"
        }
        if case .archive(let recordID) = source {
            guard let item = await files.record(id: recordID) else { throw AIFailure.contextUnavailable("Файл больше не в архиве.") }
            if let authorID = item.authorID {
                try AIContextAccess.requireOpen(
                    ServiceIdentity(service: item.identity.service, accountID: item.identity.accountID, externalID: authorID),
                    snapshot: snapshot,
                    what: "файл")
            }
        }
        if let cached = await fileCache.value(for: key) {
            let result = try AIContextDocument.assemble(
                pages: cached.text.pages, pageCount: cached.text.pageCount, paginated: cached.text.paginated,
                recognizedPages: cached.text.recognizedPages, truncatedOCR: cached.text.truncatedOCR, selected: pages,
                fallback: cached.fallback,
                source: kind)
            return AIContextMaterial.document(card, result.document)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "makosh-ai-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let name: String, file: URL
        var fallback: (() async throws -> String?)? = nil
        switch source {
        case .archive(let recordID):
            guard let item = await files.record(id: recordID) else { throw AIFailure.contextUnavailable("Файл больше не в архиве.") }
            name = item.name
            file = directory.appendingPathComponent(FileHandoff(name: name) { _ in }.stagingBasename)
            try await files.handoff(item).produce(file)
        case .paperless(let connectionID, let documentID):
            let title = card.title
            name = (title as NSString).pathExtension.isEmpty ? title + ".pdf" : title
            file = directory.appendingPathComponent(FileHandoff(name: name) { _ in }.stagingBasename)
            try await files.downloadPaperless(connectionID: connectionID, documentID: documentID, to: file)
            fallback = { try await files.paperlessDetail(connectionID: connectionID, documentID: documentID).content }
        case .staged(let id):
            guard let staged = await files.stage.url(id: id) else {
                throw AIFailure.contextUnavailable("Копия недоступна — прикрепите файл заново.")
            }
            name = card.title
            file = staged
        }
        let extracted: ExtractedText
        do {
            extracted = try await extractor.extract(file, name: name, pages: pages) { value in
                report?(cardID, AIExtractionProgress(done: value.done, total: value.total))
            }
        } catch let failure as FilesFailure {
            report?(cardID, nil)
            throw AIFailure.contextUnavailable(failure.errorDescription ?? "Не удалось прочитать файл.")
        } catch {
            report?(cardID, nil)
            throw error
        }
        report?(cardID, nil)
        // Paperless OCR text is fetched only when the local read is thin.
        var fallbackText: String?
        let characters = extracted.pages.reduce(0) { $0 + $1.trimmingCharacters(in: .whitespacesAndNewlines).count }
        if let fallback, characters < AIContextDocument.fallbackThreshold * max(extracted.pages.count, 1) {
            fallbackText = try await fallback()
        }
        await fileCache.store(FileMaterialCache.Entry(text: extracted, fallback: fallbackText), for: key)
        let result = try AIContextDocument.assemble(
            pages: extracted.pages, pageCount: extracted.pageCount, paginated: extracted.paginated,
            recognizedPages: extracted.recognizedPages,
            truncatedOCR: extracted.truncatedOCR, selected: pages, fallback: fallbackText, source: kind)
        return AIContextMaterial.document(card, result.document)
    }

    private static func requested(_ range: AIContextRange) -> Int? {
        if case .latest(let count) = range { return count }
        return nil
    }

    /// The reader lives on the main actor; its Postbox transaction does not.
    @MainActor private static func readTelegram(
        _ reader: @MainActor () -> (any TelegramAIContextReading)?, accountID: String, chatID: Int64, range: AIContextRange
    ) async throws -> TelegramAIContextPage {
        guard let reader = reader(), String(reader.accountID) == accountID else {
            throw AIFailure.contextUnavailable("Подключите этот аккаунт Telegram, чтобы прикрепить чат.")
        }
        return try await reader.page(chatID: chatID, range: range)
    }

    private func telegramMaterial(
        _ card: AIContextCard, accountID: String, chatID: String, range: AIContextRange, snapshot: AIAccessSnapshot
    ) async throws -> AIContextMaterial {
        guard let chat = Int64(chatID) else { throw AIFailure.contextUnavailable("Чат не найден.") }
        let page = try await Self.readTelegram(telegram, accountID: accountID, chatID: chat, range: range)
        guard !page.isSecret else { throw AIFailure.contextUnavailable("Секретный чат нельзя прикрепить.") }
        let identity = { (id: Int64) in ServiceIdentity(service: "telegram", accountID: accountID, externalID: String(id)) }
        let candidates = page.messages.map { message in
            AIContextCandidate(
                author: message.isOutgoing ? nil : identity(message.authorID),
                line: AIContextLine(author: message.authorName, isOutgoing: message.isOutgoing, date: message.date, text: message.text),
                isProtected: message.isProtected)
        }
        let result = try AIContextAccess.apply(candidates, privatePeer: page.isPrivate ? identity(page.peerID) : nil, snapshot: snapshot)
        return AIContextMaterial(
            card: card, lines: result.lines, hiddenForbidden: result.hiddenForbidden, hiddenProtected: result.hiddenProtected,
            available: page.available, requested: Self.requested(range), truncated: page.truncated)
    }

    private func whatsappMaterial(
        _ card: AIContextCard, accountID: String, chatID: String, range: AIContextRange, snapshot: AIAccessSnapshot
    ) async throws -> AIContextMaterial {
        guard let account = UUID(uuidString: accountID), let service = await MainActor.run(body: { whatsapp() }) else {
            throw AIFailure.contextUnavailable("WhatsApp ещё не открыт.")
        }
        let now = Date()
        let start: Date? =
            switch range {
            case .latest: nil
            case .lastDays(let days): now.addingTimeInterval(-TimeInterval(days) * 86_400)
            case .between(let from, _): from
            }
        var read: [WhatsAppMessage] = []
        var cursor: WhatsAppCursor?
        var covered = false
        while read.count < Self.whatsappLimit {
            let page = try await service.messages(accountID: account, chat: chatID, before: cursor)
            read += page.filter { !$0.deleted }
            guard let last = page.last else {
                covered = true
                break
            }
            if case .latest(let count) = range, read.count >= count {
                covered = true
                break
            }
            if let start, Date(timeIntervalSince1970: TimeInterval(last.timestamp)) < start {
                covered = true
                break
            }
            cursor = last.cursor
        }
        let group = chatID.hasSuffix("@g.us")
        var candidates = read.map { Self.whatsappCandidate($0, accountID: accountID) }.sorted { $0.line.date < $1.line.date }
        switch range {
        case .latest(let count): candidates = Array(candidates.suffix(count))
        case .lastDays: candidates = candidates.filter { $0.line.date >= start! }
        case .between(let from, let to): candidates = candidates.filter { $0.line.date >= from && $0.line.date <= to }
        }
        let peer = group ? nil : ServiceIdentity(service: "whatsapp", accountID: accountID, externalID: chatID)
        let result = try AIContextAccess.apply(candidates, privatePeer: peer, snapshot: snapshot)
        return AIContextMaterial(
            card: card, lines: result.lines, hiddenForbidden: result.hiddenForbidden, hiddenProtected: result.hiddenProtected,
            available: read.count, requested: Self.requested(range), truncated: !covered)
    }

    /// One WhatsApp message before the access rules. A protected (view-once)
    /// message is hidden like Telegram's copy-protected ones; notifications
    /// and file actions already honour the same flag.
    static func whatsappCandidate(_ message: WhatsAppMessage, accountID: String) -> AIContextCandidate {
        AIContextCandidate(
            author: message.outgoing ? nil : ServiceIdentity(service: "whatsapp", accountID: accountID, externalID: message.sender),
            line: AIContextLine(
                author: message.sender, isOutgoing: message.outgoing, date: Date(timeIntervalSince1970: TimeInterval(message.timestamp)),
                text: message.text.isEmpty ? "[вложение]" : message.text), isProtected: message.details?.protected == true)
    }

    private func letterMaterial(_ card: AIContextCard, id: String, snapshot: AIAccessSnapshot) async throws -> AIContextMaterial {
        guard let mail, let letter = try await mail.letter(id) else { throw AIFailure.contextUnavailable("Письмо не найдено.") }
        // Like a private chat: a letter from or to a forbidden contact is not sent.
        let addresses = [letter.sender] + Self.addresses([letter.recipient, letter.cc ?? "", letter.bcc ?? ""].joined(separator: ","))
        for address in addresses {
            try AIContextAccess.requireOpen(
                ServiceIdentity(service: "mail", accountID: letter.key.accountID, externalID: address.lowercased()), snapshot: snapshot,
                what: "письмо")
        }
        let author = letter.senderName.isEmpty ? letter.sender : "\(letter.senderName) <\(letter.sender)>"
        let line = AIContextLine(
            author: author, isOutgoing: false, date: letter.date,
            text: "Тема: \(letter.subject)\nКому: \(letter.recipient)\n\n\(letter.plainBody)")
        return AIContextMaterial(card: card, lines: [line], hiddenForbidden: 0, hiddenProtected: 0, available: 1, requested: nil)
    }

    /// Bare addresses from header text such as "Иван <ivan@example.test>, b@example.test".
    static func addresses(_ header: String) -> [String] {
        header.split(whereSeparator: { ",;".contains($0) }).compactMap { part in
            let text = part.trimmingCharacters(in: .whitespaces)
            if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
                return String(text[text.index(after: open)..<close])
            }
            return text.contains("@") ? text : nil
        }
    }

    private func contactMaterial(_ card: AIContextCard, id: UUID, snapshot: AIAccessSnapshot) async throws -> AIContextMaterial {
        guard let contacts, let contact = try await contacts.person(id: id) else {
            throw AIFailure.contextUnavailable("Персона не найдена.")
        }
        guard contact.aiAccess != .forbidden else {
            throw AIFailure.contextUnavailable("Персона закрыта для ИИ в досье — её нельзя прикрепить.")
        }
        for identity in contact.identities { try AIContextAccess.requireOpen(identity, snapshot: snapshot, what: "досье") }
        var text = [contact.displayName, contact.organization, contact.jobTitle].filter { !$0.isEmpty }.joined(separator: ", ")
        if !contact.phones.isEmpty { text += "\nТелефоны: " + contact.phones.joined(separator: ", ") }
        if !contact.emails.isEmpty { text += "\nПочта: " + contact.emails.joined(separator: ", ") }
        if !contact.tags.isEmpty { text += "\nМетки: " + contact.tags.joined(separator: ", ") }
        for note in contact.notes { text += "\nЗаметка: " + note.text }
        let line = AIContextLine(author: "Досье", isOutgoing: false, date: Date(), text: text)
        return AIContextMaterial(card: card, lines: [line], hiddenForbidden: 0, hiddenProtected: 0, available: 1, requested: nil)
    }
}
