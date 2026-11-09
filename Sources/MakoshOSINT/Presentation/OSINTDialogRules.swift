import Foundation
import MakoshCore

/// Pure rules behind «Обогатить (OSINT)…» in the person card.
public enum OSINTDialogRules {
    /// Why the button is disabled; nil when a run may start.
    public static func disabledReason(settings: OSINTSettings, person: Person) -> String? {
        if !settings.enabled { return "Включите модуль в Настройках → Персоны" }
        if settings.hostKeyFingerprint == nil { return "Проверьте соединение в Настройках → Персоны" }
        if settings.installedSHA == nil { return "Модуль не установлен" }
        if !person.isActive { return "Персона удалена или скрыта" }
        return nil
    }

    /// The selected enrichers that match at least one input type, in declaration order;
    /// one that needs a key the server lacks is shown but cannot be chosen.
    public static func availableEnrichers(
        selected: Set<OSINTEnricher>, inputs: [OSINTInput], serverKeyNames: Set<String>
    ) -> [(enricher: OSINTEnricher, enabled: Bool, note: String?)] {
        let types = Set(inputs.map(\.type))
        return OSINTEnricher.allCases.filter { selected.contains($0) && types.contains($0.inputType) }.map { enricher in
            if let key = enricher.requiredKey, !serverKeyNames.contains(key) {
                return (enricher, false, "нужен ключ \(key)")
            }
            return (enricher, true, nil)
        }
    }

    /// At least one value and one enricher that consumes one of the chosen values.
    public static func canLaunch(inputs: Set<OSINTInput>, enrichers: Set<OSINTEnricher>) -> Bool {
        let types = Set(inputs.map(\.type))
        return !inputs.isEmpty && enrichers.contains { types.contains($0.inputType) }
    }

    /// Shown with every launch and in the settings: the third parties act on the user's request, under their terms.
    public static let responsibility =
        "Ответственность за законность запросов к сторонним сервисам и соблюдение их условий лежит на вас."

    /// What leaves the Mac: the values go to the user's server, and from there to the named third parties.
    public static func disclosure(host: String, enrichers: Set<OSINTEnricher>) -> String {
        var services: [String] = []
        for enricher in OSINTEnricher.allCases where enrichers.contains(enricher) {
            switch enricher {
            case .emailToGravatar: services.append("Gravatar")
            case .emailToHudsonRock: services.append("HudsonRock")
            case .emailToBreaches: services.append("Have I Been Pwned")
            case .phoneToInfos: services.append("открытые справочники номеров")
            case .phoneToCarrier: services.append("Veriphone")
            case .usernameToMaigret: services.append("сайты, которые проверяет Maigret")
            case .individualToUsernameCandidates: break
            case .orgToDomains: services.append("Whoxy")
            }
        }
        var text = "Выбранные значения уйдут на ваш сервер \(host)"
        if services.isEmpty {
            text += " и останутся на нём."
        } else {
            text += ", а с него — в сторонние сервисы: " + services.joined(separator: ", ") + "."
        }
        return text + " Находки появятся в карточке как предложения, пока вы их не примете. " + responsibility
    }
}
