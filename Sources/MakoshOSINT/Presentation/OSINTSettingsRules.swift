import Foundation

/// Pure rules behind the «OSINT-модуль (flowsint)» settings section.
public enum OSINTSettingsRules {
    /// One line under the connection fields.
    public static func status(_ settings: OSINTSettings, connected: Bool) -> String {
        let host = settings.host.trimmingCharacters(in: .whitespaces)
        let login = settings.login.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !login.isEmpty else { return "Сервер не настроен: укажите хост, логин и пароль SSH." }
        guard settings.hostKeyFingerprint != nil else { return "Проверьте соединение и подтвердите отпечаток ключа сервера." }
        guard let tag = settings.installedTag, settings.installedSHA != nil else {
            return "Соединение проверено, модуль не установлен."
        }
        return connected ? "Установлен \(tag)." : "Установлен \(tag), сервер не отвечает."
    }

    /// The module is on, the host key is trusted and the connection fields are filled.
    public static func canInstall(_ settings: OSINTSettings) -> Bool {
        settings.enabled && settings.hostKeyFingerprint != nil
            && !settings.host.trimmingCharacters(in: .whitespaces).isEmpty
            && !settings.login.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public static func installButtonTitle(_ settings: OSINTSettings, pin: FlowsintPin) -> String {
        guard let sha = settings.installedSHA else { return "Развернуть модуль" }
        return sha == pin.sha ? "Переустановить \(pin.tag)" : "Обновить до \(pin.tag)"
    }

    public static func keyState(name: String, serverKeyNames: Set<String>) -> String {
        serverKeyNames.contains(name) ? "задан" : "не задан"
    }
}
