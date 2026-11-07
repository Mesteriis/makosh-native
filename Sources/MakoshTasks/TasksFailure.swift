import Foundation

/// What the section tells the user; codes only, never Jira's text.
public enum TasksFailure: Error, LocalizedError, Equatable, Sendable {
    case invalidToken
    case invalidConnection(String)
    case unauthorized
    case unavailable
    case storage(String)
    case blocked([String])
    case cycle
    case staleRevision
    case attemptInFlight
    case descriptionNotEditable
    case unsupportedFields([String])
    case timerRunning(UUID)
    case entryLocked
    case keyUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidToken: "Токен содержит перевод строки или управляющие символы — вставьте его одной строкой."
        case .invalidConnection(let reason): "Недопустимые параметры подключения: \(reason)."
        case .unauthorized: "Jira не приняла почту и токен. Проверьте их в настройках подключения."
        case .unavailable: "Jira недоступна."
        case .storage(let code): "Хранилище задач недоступно (\(code))."
        case .blocked(let names): "Ждёт: " + names.joined(separator: ", ")
        case .cycle: "Так задачи зависели бы друг от друга по кругу."
        case .staleRevision: "Задача изменилась — обновите список."
        case .attemptInFlight: "Такое действие по этой задаче уже выполняется."
        case .descriptionNotEditable: "Описание с таблицами или вложениями правится только в Jira."
        case .unsupportedFields(let keys): "Переход требует поля, которые заполняются только в Jira: " + keys.joined(separator: ", ")
        case .timerRunning: "Уже идёт таймер по другой задаче — сначала остановите его."
        case .entryLocked: "Время уже списано в Jira — исправьте его там."
        case .keyUnavailable: "Связка ключей недоступна."
        }
    }
}
