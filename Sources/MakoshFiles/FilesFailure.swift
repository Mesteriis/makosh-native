import Foundation

/// Every user-facing failure of the Files section. Reasons never carry tokens.
public enum FilesFailure: LocalizedError, Equatable, Sendable {
    case archiveUnavailable
    case integrity
    case keyUnavailable
    case storageMissing
    case invalidConnection
    case unauthorized
    case unreachable(String)
    case rejected(status: Int, reason: String)
    case tooLarge
    case duplicate(existingID: Int?)
    case unexpectedResponse

    public var errorDescription: String? {
        switch self {
        case .archiveUnavailable: "Архив файлов недоступен: не удалось открыть локальный архив в PostgreSQL."
        case .integrity: "Не удалось проверить целостность архива файлов. Данные не изменены."
        case .keyUnavailable: "Ключ локального архива недоступен. Существующий ключ и данные не заменены."
        case .storageMissing: "Подключение удалено. Файл не отправлен."
        case .invalidConnection: "Недопустимые параметры подключения: нужен HTTPS-адрес без учётных данных и название до 80 символов."
        case .unauthorized: "Paperless не принял токен. Проверьте токен в настройках подключения."
        case .unreachable(let code): "Paperless недоступен (\(code))."
        case .rejected(let status, let reason):
            reason.isEmpty ? "Paperless отклонил запрос (\(status))." : "Paperless отклонил запрос (\(status)): \(reason)"
        case .tooLarge: "Сервер не принимает файл такого размера."
        case .duplicate(let id): id.map { "Такой документ уже есть в Paperless (#\($0))." } ?? "Такой документ уже есть в Paperless."
        case .unexpectedResponse: "Paperless ответил не так, как ожидалось. Проверьте адрес подключения."
        }
    }
}
