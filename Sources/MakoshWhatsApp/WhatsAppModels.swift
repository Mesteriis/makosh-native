import CryptoKit
import Foundation

public enum WhatsAppFailure: Error, LocalizedError, Equatable, Sendable {
  case storage, key, owned, protocolFailure, unavailable, invalid, closed, notAdmitted
  public var errorDescription: String? {
    switch self {
    case .storage: "Не удалось открыть или сохранить данные WhatsApp. История и сеанс сохранены."
    case .key: "Ключ WhatsApp недоступен. Существующий сеанс не заменён."
    case .owned:
      "Этот аккаунт уже открыт в другом окне или процессе. Отключите его там и повторите."
    case .protocolFailure:
      "Ядро WhatsApp не ответило корректно. Сеанс сохранён; подключитесь повторно."
    case .unavailable: "Ядро WhatsApp недоступно в этой сборке."
    case .invalid: "Недопустимые данные WhatsApp."
    case .closed: "Соединение WhatsApp закрыто."
    case .notAdmitted: "Ядро не приняло команду. Отправка не началась."
    }
  }
}
public struct WhatsAppAccount: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var name: String
  public init(id: UUID = UUID(), name: String) {
    self.id = id
    self.name = name
  }
}
public struct WhatsAppChat: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var timestamp: Int64
  public var unread: Int64
  public var archived: Bool
  public var pinned: Bool
  public var group: Bool
  public var preview: String?
  public var mutedUntil: Int64?
  public init(
    id: String, name: String, timestamp: Int64 = 0, unread: Int64 = 0, archived: Bool = false,
    pinned: Bool = false, group: Bool = false
  ) {
    self.id = id
    self.name = name
    self.timestamp = timestamp
    self.unread = unread
    self.archived = archived
    self.pinned = pinned
    self.group = group
  }
}
public struct WhatsAppCursor: Codable, Equatable, Sendable {
  public let timestamp: Int64
  public let id: String
  public init(timestamp: Int64, id: String) {
    self.timestamp = timestamp
    self.id = id
  }
}
public struct WhatsAppMessage: Codable, Equatable, Identifiable, Sendable {
  public var chat: String, id: String, stanza: String, sender: String
  public var timestamp: Int64
  public var outgoing: Bool
  public var text: String, kind: String
  public var edited: Bool, deleted: Bool
  public var pageToken: String?
  public var versionTimestamp: Int64?
  public var delivery: Int64?
  public var details: WhatsAppMessageDetails?
  var versionOrder: (Int64, Int) {
    let (scaled, overflow) = timestamp.multipliedReportingOverflow(by: 1000)
    let fallback = overflow ? (timestamp >= 0 ? Int64.max : Int64.min) : scaled
    return (
      versionTimestamp.flatMap { $0 > 0 ? $0 : nil } ?? fallback, deleted ? 2 : edited ? 1 : 0
    )
  }
  public var cursor: WhatsAppCursor { .init(timestamp: timestamp, id: pageToken ?? id) }
  public init(
    chat: String, id: String, stanza: String, sender: String, timestamp: Int64, outgoing: Bool,
    text: String, kind: String, edited: Bool, deleted: Bool
  ) {
    self.chat = chat
    self.id = id
    self.stanza = stanza
    self.sender = sender
    self.timestamp = timestamp
    self.outgoing = outgoing
    self.text = text
    self.kind = kind
    self.edited = edited
    self.deleted = deleted
  }
}
public struct WhatsAppMessageDetails: Codable, Equatable, Sendable {
  public var resourceID: String?
  public var rejection: WhatsAppServerRejection?
  public var protected: Bool?
  public var name: String?, mime: String?, size: UInt64?, width: UInt32?, height: UInt32?,
    seconds: UInt32?
  public var latitude: Double?, longitude: Double?
  public var quotedId: String?, quotedText: String?, quotedSender: String?
  public var contactName: String?, contactVcard: String?, pollName: String?
  public var pollOptions: [String] = []
  public var pollVotes: [WhatsAppPollVote]?
  public var pollCreator: String?
  public var receipts: [WhatsAppReceipt] = []
  public var starred: Bool?, pinned: Bool?
  public var reactions: [WhatsAppReaction]?
  public init() {}
}
public struct WhatsAppReceipt: Codable, Equatable, Sendable {
  public var sender: String, level: Int64, timestamp: Int64
  public init(sender: String, level: Int64, timestamp: Int64) {
    self.sender = sender
    self.level = level
    self.timestamp = timestamp
  }
}
public struct WhatsAppJournalEntry: Codable, Equatable, Sendable {
  public var sequence: Int64
  public var message: WhatsAppMessage
  public var history: Bool
  public var observed: Int64
  public var notify: Bool?
  public init(sequence: Int64, message: WhatsAppMessage, history: Bool, observed: Int64) {
    self.sequence = sequence
    self.message = message
    self.history = history
    self.observed = observed
  }
  func observationID(accountID: UUID) -> UUID {
    let hash = Array(
      SHA256.hash(data: Data((accountID.uuidString.lowercased() + "|" + String(sequence)).utf8)))
    return UUID(
      uuid: (
        hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], (hash[6] & 0x0f) | 0x50, hash[7],
        (hash[8] & 0x3f) | 0x80, hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]
      ))
  }
}
public struct WhatsAppConnectionStatus: Codable, Equatable, Sendable {
  public var state: String = "offline"
  public var qr: String = ""
  public var expires: Int64 = 0
  public var revision: UInt64 = 0
  public var error: String?
  public var call: WhatsAppCallSnapshot?
  public var avatarRevisions: [String: UInt64]?
  public var avatarEpoch: UInt64?
  public init() {}
  public var linked: Bool { state == "connected" }
  public var label: String {
    switch state {
    case "connected": "Подключено"
    case "connecting": "Подключение…"
    case "qr": "Отсканируйте QR-код"
    case "expired": "QR-код истёк"
    case "reconnecting": "Восстановление соединения…"
    case "stopping": "Отключение…"
    case "logged_out": "Связь с телефоном отозвана"
    case "failed": "Ошибка подключения"
    default: "Офлайн · сохранённая история"
    }
  }
}

public struct WhatsAppReaction: Codable, Equatable, Sendable {
  public var sender: String, text: String
  public var timestamp: Int64
}

public struct WhatsAppPollVote: Codable, Equatable, Sendable {
  public var sender: String, options: [String], timestamp: Int64
}

public struct WhatsAppServerRejection: Codable, Equatable, Sendable {
  public var code: String
  public var timestamp: Int64
}
