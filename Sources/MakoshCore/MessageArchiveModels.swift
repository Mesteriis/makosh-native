import Foundation

/// Source identifiers are opaque UTF-8 values. Telegram constructs these from
/// typed engine IDs; archive values are never parsed as mutation targets.
public struct MessageArchiveIdentity: Codable, Equatable, Hashable, Sendable {
    public let service: String
    public let accountID: String
    public let conversationID: String
    public let messageID: String
    public init(service: String, accountID: String, conversationID: String, messageID: String) {
        self.service = service; self.accountID = accountID
        self.conversationID = conversationID; self.messageID = messageID
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.service.utf8.elementsEqual(rhs.service.utf8) && lhs.accountID.utf8.elementsEqual(rhs.accountID.utf8)
            && lhs.conversationID.utf8.elementsEqual(rhs.conversationID.utf8) && lhs.messageID.utf8.elementsEqual(rhs.messageID.utf8)
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(Data(service.utf8)); hasher.combine(Data(accountID.utf8))
        hasher.combine(Data(conversationID.utf8)); hasher.combine(Data(messageID.utf8))
    }
}

public struct MessageArchiveAttachment: Codable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let name: String
    public let size: Int64?
    public init(id: String, kind: String, name: String, size: Int64?) {
        self.id = id; self.kind = kind; self.name = name; self.size = size
    }
}

public struct MessageArchiveContent: Codable, Equatable, Sendable {
    public let date: Date
    public let editedAt: Date?
    public let text: String
    public let author: String
    public let authorID: String?
    public let isOutgoing: Bool
    public let attachments: [MessageArchiveAttachment]
    public init(date: Date, editedAt: Date? = nil, text: String, author: String, authorID: String? = nil,
                isOutgoing: Bool, attachments: [MessageArchiveAttachment] = []) {
        self.date = date; self.editedAt = editedAt; self.text = text; self.author = author
        self.authorID = authorID; self.isOutgoing = isOutgoing; self.attachments = attachments
    }
}

public enum MessageArchiveEvent: Codable, Equatable, Sendable {
    case message(MessageArchiveContent)
    /// Only an authoritative deletion event may create this marker. A missing
    /// item in a history/search window is never evidence of server deletion.
    case deleted
    /// A physical source-cache removal is durable evidence of disappearance,
    /// but does not identify whether a peer, this client or cache validation caused it.
    case removedFromSource
}

public enum MessageArchiveSource: String, Codable, Sendable {
    case history, search, update, outgoing, synthetic
}

public struct MessageArchiveObservation: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let identity: MessageArchiveIdentity
    public let observedAt: Date
    public let source: MessageArchiveSource
    public let event: MessageArchiveEvent
    /// Optional service-owned version metadata, encrypted with this observation.
    /// Contains protocol metadata only; attachment payload bytes stay in S3.
    public let sourcePayload: Data?
    public init(id: UUID = UUID(), identity: MessageArchiveIdentity, observedAt: Date = Date(),
                source: MessageArchiveSource, event: MessageArchiveEvent, sourcePayload: Data? = nil) {
        self.id = id; self.identity = identity; self.observedAt = observedAt; self.source = source; self.event = event; self.sourcePayload = sourcePayload
    }
}

public struct MessageArchiveRecord: Equatable, Sendable, Identifiable {
    public let sequence: Int64
    public let observation: MessageArchiveObservation
    public var id: UUID { observation.id }
    public init(sequence: Int64, observation: MessageArchiveObservation) {
        self.sequence = sequence; self.observation = observation
    }
}

public enum MessageArchiveError: LocalizedError {
    case invalid, database, unsupportedSchema, keyUnavailable, integrity
    public var errorDescription: String? {
        switch self {
        case .invalid: "Недопустимые данные локального архива."
        case .database: "Не удалось записать или открыть локальный архив в PostgreSQL."
        case .unsupportedSchema: "Версия локального архива не поддерживается. Данные не изменены."
        case .keyUnavailable: "Ключ локального архива недоступен. Существующий ключ и данные не заменены."
        case .integrity: "Не удалось проверить целостность локального архива. Данные не изменены."
        }
    }
}
