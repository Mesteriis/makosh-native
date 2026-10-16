import Foundation

public enum TelemostFailure: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration, invalidResponse, invalidURL, bodyTooLarge, redirectRejected, transport
    case storage, keyUnavailable, busy, expired, forbidden, unauthorized, scopeDenied, unknown, conflict, missing, incomplete
    case provider(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Проверьте настройки Телемоста."
        case .invalidURL: "Укажите ссылку https://telemost.yandex.ru/j/…"
        case .invalidResponse: "Сервис вернул неподтверждённый ответ."
        case .bodyTooLarge: "Ответ сервиса превышает допустимый размер."
        case .redirectRejected: "Перенаправление API отклонено."
        case .transport: "Не удалось получить ответ сервиса."
        case .storage: "Хранилище недоступно. Сохранённые данные не сброшены."
        case .keyUnavailable: "Ключ хранилища недоступен. Данные сохранены."
        case .busy: "Операция уже выполняется в другом окне. Повторите позже."
        case .expired: "Срок доступа истёк. Войдите повторно."
        case .forbidden, .scopeDenied: "Для действия нет разрешения."
        case .unauthorized: "Нужен повторный вход в аккаунт."
        case .unknown: "Исход операции неизвестен. Автоматического повтора не будет."
        case .conflict: "Данные изменились. Обновите состояние перед действием."
        case .missing: "Запись не найдена; ранее сохранённая история остаётся."
        case .incomplete: "Список соорганизаторов загружен частично. Продолжите обновление."
        case .provider(let status): "Сервис отклонил запрос (HTTP \(status))."
        }
    }
}

public struct TelemostScope: Codable, Hashable, Sendable {
    public let accountID: UUID
    public let conferenceID: String
    public init(accountID: UUID, conferenceID: String) { self.accountID = accountID; self.conferenceID = conferenceID }
    public var storageKey: String { telemostIdentityKey([accountID.uuidString, conferenceID]) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.accountID == rhs.accountID && lhs.conferenceID.utf8.elementsEqual(rhs.conferenceID.utf8) }
    public func hash(into hasher: inout Hasher) { hasher.combine(storageKey) }
}

func telemostIdentityKey(_ fields: [String]) -> String {
    fields.map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
}

public struct TelemostPrincipal: Codable, Equatable, Sendable {
    public let userID: String
    public let clientID: String
    public let login: String
    public init(userID: String, clientID: String, login: String) { self.userID = userID; self.clientID = clientID; self.login = login }
    public func sameSource(as other: Self) -> Bool { userID.utf8.elementsEqual(other.userID.utf8) && clientID.utf8.elementsEqual(other.clientID.utf8) }
}
public enum TelemostCapability: String, Codable, Hashable, CaseIterable, Sendable {
    case read, create, update
    public var scope: String { "telemost-api:conferences." + rawValue }
}
public enum TelemostWaitingRoom: String, Codable, CaseIterable, Sendable {
    case publicAccess = "PUBLIC", organization = "ORGANIZATION", admins = "ADMINS"
    public var title: String {
        switch self { case .publicAccess: "Без ожидания"; case .organization: "Ожидание для внешних"; case .admins: "Ожидание для всех" }
    }
}
public struct TelemostAccount: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let clientID: String
    public let callbackURL: URL
    public var principal: TelemostPrincipal?
    public var capabilities: Set<TelemostCapability>
    public init(id: UUID = UUID(), name: String, clientID: String, callbackURL: URL,
                principal: TelemostPrincipal? = nil, capabilities: Set<TelemostCapability> = [.read]) {
        self.id = id; self.name = name; self.clientID = clientID; self.callbackURL = callbackURL
        self.principal = principal; self.capabilities = capabilities
    }
}
public struct TelemostCreateRequest: Codable, Equatable, Sendable {
    public let waitingRoom: TelemostWaitingRoom
    public init(waitingRoom: TelemostWaitingRoom) { self.waitingRoom = waitingRoom }
}
public struct TelemostMeetingPatch: Codable, Equatable, Sendable {
    public let waitingRoom: TelemostWaitingRoom
    public init(waitingRoom: TelemostWaitingRoom) { self.waitingRoom = waitingRoom }
}
public struct TelemostConference: Codable, Equatable, Sendable {
    public let scope: TelemostScope
    public let joinURL: TelemostMeetingURL
    public let waitingRoomRaw: String
    public let observedAt: Date
    public let retainedJSON: Data
    public var waitingRoom: TelemostWaitingRoom? { .init(rawValue: waitingRoomRaw) }
    public init(scope: TelemostScope, joinURL: TelemostMeetingURL, waitingRoomRaw: String, observedAt: Date = Date(), retainedJSON: Data) {
        self.scope = scope; self.joinURL = joinURL; self.waitingRoomRaw = waitingRoomRaw; self.observedAt = observedAt; self.retainedJSON = retainedJSON
    }
}
public struct TelemostCohostPage: Codable, Equatable, Sendable {
    public let scope: TelemostScope
    public let offset: Int
    public let limit: Int
    public let emails: [String]
    public let complete: Bool
}
