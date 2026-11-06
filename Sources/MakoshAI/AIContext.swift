import Foundation
import MakoshCore

/// A source the user attached to a conversation. Attaching it is consent to
/// send its content to the chat provider with each question; nothing else
/// leaves. A chat card carries its period; letters and contacts go whole.
public enum AIContextCard: Codable, Hashable, Sendable, Identifiable {
    case chat(service: String, accountID: String, chatID: String, title: String, range: AIContextRange)
    case letter(id: String, title: String)
    case contact(id: UUID, title: String)
    /// A file: its pages (1-based, inclusive) or everything when nil.
    case file(source: AIFileSource, title: String, pages: ClosedRange<Int>?)

    /// The source, independent of the chosen period or pages.
    public var id: String {
        switch self {
        case .chat(let service, let accountID, let chatID, _, _): "chat:\(service):\(accountID):\(chatID)"
        case .letter(let id, _): "letter:\(id)"
        case .contact(let id, _): "contact:\(id.uuidString)"
        case .file(let source, _, _): "file:" + source.id
        }
    }

    public var title: String {
        switch self {
        case .chat(_, _, _, let title, _), .letter(_, let title), .contact(_, let title), .file(_, let title, _): title
        }
    }
}

/// Where a file card's bytes come from. A staged copy lives in the private
/// hand-off directory until the app quits.
public enum AIFileSource: Codable, Hashable, Sendable {
    case archive(recordID: UUID)
    case paperless(connectionID: UUID, documentID: Int)
    case staged(id: UUID)

    public var id: String {
        switch self {
        case .archive(let id): "archive:\(id.uuidString.lowercased())"
        case .paperless(let connection, let document): "paperless:\(connection.uuidString.lowercased()):\(document)"
        case .staged(let id): "staged:\(id.uuidString.lowercased())"
        }
    }
}

/// The text of an attached file, page by page, as it goes to the provider.
public struct AIContextDocument: Sendable, Equatable {
    public static let ocrPageLimit = 200
    /// Only the selected pages, in order.
    public let pages: [String]
    public let pageCount: Int
    public let selected: ClosedRange<Int>
    /// False for text split into parts (Word, plain text, images).
    public let paginated: Bool
    /// At least one page came from OCR.
    public let recognized: Bool
    /// OCR stopped at `ocrPageLimit`.
    public let truncatedOCR: Bool
    /// "archive", "paperless", "paperless-content" or "staged".
    public let source: String
    public init(
        pages: [String], pageCount: Int, selected: ClosedRange<Int>, paginated: Bool, recognized: Bool, truncatedOCR: Bool, source: String
    ) {
        self.pages = pages
        self.pageCount = pageCount
        self.selected = selected
        self.paginated = paginated
        self.recognized = recognized
        self.truncatedOCR = truncatedOCR
        self.source = source
    }
}

/// One message or letter of an attached source, ready for the provider.
public struct AIContextLine: Sendable, Equatable {
    public let author: String
    public let isOutgoing: Bool
    public let date: Date
    public let text: String
    public init(author: String, isOutgoing: Bool, date: Date, text: String) {
        self.author = author
        self.isOutgoing = isOutgoing
        self.date = date
        self.text = text
    }
}

/// What an attached card contributes, after access rules removed what may
/// not leave; the counts are shown on the card.
public struct AIContextMaterial: Sendable, Equatable {
    public let card: AIContextCard
    public let lines: [AIContextLine]
    public let hiddenForbidden: Int
    public let hiddenProtected: Int
    /// Messages available locally for the card's period.
    public let available: Int
    /// The `latest(n)` count asked for, if any.
    public let requested: Int?
    /// The local read stopped at its cap before covering the period.
    public let truncated: Bool
    /// A file card's text; `lines` is empty then and `available` is the page count.
    public let document: AIContextDocument?
    public init(
        card: AIContextCard, lines: [AIContextLine], hiddenForbidden: Int, hiddenProtected: Int, available: Int, requested: Int?,
        truncated: Bool = false, document: AIContextDocument? = nil
    ) {
        self.card = card
        self.lines = lines
        self.hiddenForbidden = hiddenForbidden
        self.hiddenProtected = hiddenProtected
        self.available = available
        self.requested = requested
        self.truncated = truncated
        self.document = document
    }

    public static func document(_ card: AIContextCard, _ document: AIContextDocument) -> AIContextMaterial {
        AIContextMaterial(
            card: card, lines: [], hiddenForbidden: 0, hiddenProtected: 0, available: document.pageCount, requested: nil, document: document
        )
    }
}

/// Pages finished so far of a file card's text extraction.
public struct AIExtractionProgress: Sendable, Equatable {
    public let done: Int
    public let total: Int
    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

extension AIContextDocument {
    /// Fewer characters than this per page means the local read found nothing worth sending.
    public static let fallbackThreshold = 50

    /// The document for a card: the local pages, or the fallback text (Paperless
    /// OCR) split into parts when the local read is thin. `selected` is 1-based.
    public static func assemble(
        pages: [String], pageCount: Int, paginated: Bool, recognizedPages: Set<Int>, truncatedOCR: Bool, selected: ClosedRange<Int>?,
        fallback: String?, source: String
    ) throws -> (document: AIContextDocument, usedFallback: Bool) {
        let characters = pages.reduce(0) { $0 + $1.trimmingCharacters(in: .whitespacesAndNewlines).count }
        let thin = pages.isEmpty || characters < fallbackThreshold * pages.count
        if thin, let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parts = AIContextDocument.parts(fallback)
            let range = try selection(selected, count: parts.count)
            return (
                AIContextDocument(
                    pages: Array(parts[(range.lowerBound - 1)..<range.upperBound]), pageCount: parts.count, selected: range,
                    paginated: false,
                    recognized: false, truncatedOCR: false, source: source + "-content"), true
            )
        }
        let range = try selection(selected, count: pageCount)
        guard pages.count == range.count else {
            throw AIFailure.contextUnavailable("Прочитано не то число страниц — прикрепите файл заново.")
        }
        return (
            AIContextDocument(
                pages: pages, pageCount: pageCount, selected: range, paginated: paginated, recognized: !recognizedPages.isEmpty,
                truncatedOCR: truncatedOCR, source: source), false
        )
    }

    private static func selection(_ selected: ClosedRange<Int>?, count: Int) throws -> ClosedRange<Int> {
        let count = max(count, 1)
        guard let selected else { return 1...count }
        guard selected.lowerBound >= 1, selected.upperBound <= count else {
            throw AIFailure.contextUnavailable("В файле \(count) страниц — выберите страницы в этих пределах.")
        }
        return selected
    }

    /// Paragraphs packed to about 3 000 characters; an unbroken text is cut hard.
    static func parts(_ text: String, size: Int = 3_000) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var result: [String] = [], current = ""
        func flush() {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result.append(value) }
            current = ""
        }
        for paragraph in trimmed.components(separatedBy: "\n\n") {
            let paragraph = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paragraph.isEmpty else { continue }
            if paragraph.count > size {
                flush()
                var rest = Substring(paragraph)
                while !rest.isEmpty {
                    result.append(String(rest.prefix(size)))
                    rest = rest.dropFirst(size)
                }
                continue
            }
            if current.isEmpty {
                current = paragraph
            } else if current.count + 2 + paragraph.count <= size {
                current += "\n\n" + paragraph
            } else {
                flush()
                current = paragraph
            }
        }
        flush()
        return result
    }
}

/// Reads an attached source. Throws `AIFailure.contextUnavailable` for a
/// source that may never be sent (secret chat, forbidden contact) or is gone.
public protocol AIContextProvider: Sendable {
    func material(for card: AIContextCard) async throws -> AIContextMaterial
}

/// The system turn carrying attached sources.
public enum AIContextBuilder {
    /// Nil without cards. Over the budget it throws instead of cutting anything.
    public static func turn(_ materials: [AIContextMaterial], history: [AIChatTurn], budgetTokens: Int) throws -> AIChatTurn? {
        guard !materials.isEmpty else { return nil }
        var text = """
            Ниже — переписка, письма и файлы, которые пользователь сам прикрепил к беседе. \
            Отвечай по ним; если ответа в них нет, так и скажи. \
            Реплики пользователя помечены «пользователь».
            """
        for material in materials {
            if let document = material.document {
                text += "\n\n=== \(heading(material.card, document)) ==="
                if document.truncatedOCR { text += "\n(распознаны первые \(AIContextDocument.ocrPageLimit) страниц)" }
                let unit = document.paginated ? "стр." : "часть"
                for (offset, page) in document.pages.enumerated() {
                    text += "\n--- \(unit) \(document.selected.lowerBound + offset) ---\n\(page)"
                }
                continue
            }
            text += "\n\n=== \(heading(material.card)) ==="
            for line in material.lines {
                let date = line.date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                let author = line.isOutgoing ? "пользователь" : line.author
                text += "\n[\(date)] \(author): \(line.text)"
            }
        }
        let total = history.reduce(0) { $0 + AITokenEstimate.tokens(in: $1.text) } + AITokenEstimate.tokens(in: text)
        guard total <= budgetTokens else { throw AIFailure.contextTooLarge(tokens: total, budget: budgetTokens) }
        return AIChatTurn(author: .system, text: text)
    }

    private static func heading(_ card: AIContextCard) -> String {
        switch card {
        case .chat(let service, _, _, let title, let range): "Чат «\(title)» (\(service), \(describe(range)))"
        case .letter(_, let title): "Письмо «\(title)»"
        case .contact(_, let title): "Контакт «\(title)»"
        case .file(_, let title, _): "Файл «\(title)»"
        }
    }

    private static func heading(_ card: AIContextCard, _ document: AIContextDocument) -> String {
        let unit = document.paginated ? "страницы" : "части"
        var details = "\(unit) \(document.selected.lowerBound)–\(document.selected.upperBound) из \(document.pageCount)"
        if document.recognized { details += ", распознано со скана" }
        return "Файл «\(card.title)» (\(details))"
    }

    private static func describe(_ range: AIContextRange) -> String {
        switch range {
        case .latest(let count): "последние \(count) сообщений"
        case .lastDays(let days): "за \(days) дн."
        case .between(let from, let to):
            "с \(from.formatted(.iso8601.year().month().day())) по \(to.formatted(.iso8601.year().month().day()))"
        }
    }
}

/// The "@word" typed at the end of a draft.
public enum AIMention {
    /// Nil unless the draft ends in "@" plus a word with no spaces, and the
    /// "@" starts a word (so an e-mail address is not a mention).
    public static func query(in draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at != draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let word = draft[draft.index(after: at)...]
        return word.contains(where: \.isWhitespace) ? nil : String(word)
    }
    public static func removing(from draft: String) -> String {
        guard let at = draft.lastIndex(of: "@") else { return draft }
        return String(draft[..<at])
    }
}
