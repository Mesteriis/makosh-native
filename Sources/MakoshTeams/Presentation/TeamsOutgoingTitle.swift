import Foundation

package func teamsOutgoingTitle(_ outgoing: TeamsOutgoing, synthetic: Bool) -> String {
    if outgoing.receipt?.userResolved == true {
        return outgoing.state == .accepted ? "Отмечено вами как отправленное" : "Отмечено вами как неотправленное"
    }
    if synthetic, outgoing.state == .accepted { return "QA · синтетическое подтверждение" }
    return switch outgoing.state {
    case .prepared: "Подготовлено"
    case .dispatching: "Попытка выполняется"
    case .accepted: "Принято сервисом"
    case .notSent: "Не отправлено"
    case .unknown: "Результат неизвестен"
    }
}
