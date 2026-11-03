import Foundation
import TelegramApi
import TelegramCore
import Postbox

struct TelegramGroupAdminPresentation {
    let summary: String
    var previous: String? = nil
    var current: String? = nil
    var subjectIDs: [Int64] = []
}
private func groupAdminBool(_ value: Api.Bool) -> String { if case .boolTrue = value { return "Включено" }; return "Выключено" }
private func groupAdminInterval(_ value: Int32) -> String {
    if value == 0 { return "Выключено" }
    if value % 86400 == 0 { return "\(value / 86400) дн." }
    if value % 3600 == 0 { return "\(value / 3600) ч" }
    if value % 60 == 0 { return "\(value / 60) мин" }
    return "\(value) с"
}
private func groupAdminPeerID(_ peer: Api.Peer) -> Int64? {
    let namespace: PeerId.Namespace, id: Int64
    switch peer {
    case let .peerUser(value): namespace = Namespaces.Peer.CloudUser; id = value
    case let .peerChat(value): namespace = Namespaces.Peer.CloudGroup; id = value
    case let .peerChannel(value): namespace = Namespaces.Peer.CloudChannel; id = value
    }
    guard id > 0 else { return nil }
    let value = PeerId(namespace: namespace, id: ._internalFromInt64Value(id)).toInt64()
    return telegramManagementPeerID(value) == PeerId(namespace: namespace, id: ._internalFromInt64Value(id)) ? value : nil
}
private func groupAdminRights(_ flags: Int32, rows: [TelegramPeerRight]) -> String {
    var values = rows.filter { flags & $0.id != 0 }.map(\.title)
    let known = rows.reduce(Int32(0)) { $0 | $1.id }, other = flags & ~known
    if other != 0 { values.append("Другие права: \(UInt32(bitPattern: other))") }
    return values.isEmpty ? "Нет дополнительных прав" : values.joined(separator: "\n")
}
private func groupAdminParticipant(_ participant: Api.ChannelParticipant) -> (id: Int64, text: String)? {
    let peer: Api.Peer, text: String
    switch participant {
    case let .channelParticipant(_, id, _, _), let .channelParticipantSelf(_, id, _, _, _): peer = .peerUser(userId: id); text = "Участник"
    case let .channelParticipantAdmin(_, id, _, _, _, rights, rank), let .channelParticipantCreator(_, id, rights, rank):
        peer = .peerUser(userId: id)
        switch rights { case let .chatAdminRights(flags):
            text = "Администратор\n" + groupAdminRights(flags, rows: TelegramPeerRight.administrators)
                + (rank.flatMap { $0.isEmpty ? nil : "\nДолжность: " + $0 } ?? "")
        }
    case let .channelParticipantBanned(flags, value, _, _, rights):
        peer = value
        switch rights { case let .chatBannedRights(bans, until):
            let duration = until <= 0 || until == Int32.max ? "Без срока" : "До " + Date(timeIntervalSince1970: Double(until)).formatted()
            text = (flags & 1 != 0 ? "Не состоит в чате\n" : "Ограничения\n") + groupAdminRights(bans, rows: TelegramPeerRight.restrictions) + "\n" + duration
        }
    case let .channelParticipantLeft(value): peer = value; text = "Не состоит в чате"
    }
    guard let id = groupAdminPeerID(peer) else { return nil }; return (id, text)
}
private func groupAdminInvite(_ invite: Api.ExportedChatInvite) -> String? {
    guard let row = telegramGroupInviteLink(invite) else { return nil }
    guard let link = row.link else { return "Публичные заявки на вступление" }
    var text = [row.title, link].compactMap { $0 }.joined(separator: "\n")
    if let expiry = row.expireDate { text += "\nДо " + Date(timeIntervalSince1970: Double(expiry)).formatted() }
    if let limit = row.usageLimit { text += "\nЛимит вступлений: \(limit)" }
    if row.requiresApproval { text += "\nС одобрением администратора" }
    if row.revoked { text += "\nОтозвана" }
    return text
}
func telegramGroupAdminPresentation(_ action: Api.ChannelAdminLogEventAction) -> TelegramGroupAdminPresentation? {
    switch action {
    case let .channelAdminLogEventActionChangeTitle(previous, current): return .init(summary: "Изменено название", previous: previous, current: current)
    case let .channelAdminLogEventActionChangeAbout(previous, current): return .init(summary: "Изменено описание", previous: previous, current: current)
    case let .channelAdminLogEventActionChangeUsername(previous, current): return .init(summary: "Изменено имя пользователя", previous: previous, current: current)
    case let .channelAdminLogEventActionChangeUsernames(previous, current): return .init(summary: "Изменены публичные имена", previous: previous.joined(separator: ", "), current: current.joined(separator: ", "))
    case let .channelAdminLogEventActionChangeHistoryTTL(previous, current):
        guard previous >= 0, current >= 0 else { return nil }
        return .init(summary: "Изменено автоудаление сообщений", previous: groupAdminInterval(previous), current: groupAdminInterval(current))
    case let .channelAdminLogEventActionToggleSlowMode(previous, current):
        guard previous >= 0, current >= 0 else { return nil }
        return .init(summary: "Изменен медленный режим", previous: groupAdminInterval(previous), current: groupAdminInterval(current))
    case let .channelAdminLogEventActionToggleInvites(value): return .init(summary: "Изменены приглашения участников", current: groupAdminBool(value))
    case let .channelAdminLogEventActionToggleSignatures(value): return .init(summary: "Изменены подписи сообщений", current: groupAdminBool(value))
    case let .channelAdminLogEventActionToggleSignatureProfiles(value): return .init(summary: "Изменены профили авторов сообщений", current: groupAdminBool(value))
    case let .channelAdminLogEventActionToggleNoForwards(value): return .init(summary: "Изменена защита содержимого", current: groupAdminBool(value))
    case let .channelAdminLogEventActionTogglePreHistoryHidden(value): return .init(summary: "Изменено скрытие предыдущей истории", current: groupAdminBool(value))
    case let .channelAdminLogEventActionToggleForum(value): return .init(summary: "Изменен режим тем", current: groupAdminBool(value))
    case let .channelAdminLogEventActionToggleAntiSpam(value): return .init(summary: "Изменена защита от спама", current: groupAdminBool(value))
    case let .channelAdminLogEventActionToggleAutotranslation(value): return .init(summary: "Изменен автоматический перевод", current: groupAdminBool(value))
    case let .channelAdminLogEventActionToggleGroupCallSetting(value): return .init(summary: "Изменено отключение микрофона новых участников видеочата", current: groupAdminBool(value))
    case .channelAdminLogEventActionChangePhoto: return .init(summary: "Изменена фотография")
    case .channelAdminLogEventActionChangeAvailableReactions: return .init(summary: "Изменены доступные реакции")
    case .channelAdminLogEventActionChangeEmojiStatus: return .init(summary: "Изменен эмодзи-статус")
    case .channelAdminLogEventActionChangeEmojiStickerSet: return .init(summary: "Изменен набор эмодзи")
    case .channelAdminLogEventActionChangeStickerSet: return .init(summary: "Изменен набор стикеров")
    case .channelAdminLogEventActionChangeLinkedChat: return .init(summary: "Изменен связанный диалог")
    case .channelAdminLogEventActionChangeLocation: return .init(summary: "Изменено местоположение")
    case .channelAdminLogEventActionChangePeerColor: return .init(summary: "Изменен цвет имени")
    case .channelAdminLogEventActionChangeProfilePeerColor: return .init(summary: "Изменен цвет профиля")
    case .channelAdminLogEventActionChangeWallpaper: return .init(summary: "Изменены обои")
    case .channelAdminLogEventActionCreateTopic: return .init(summary: "Создана тема")
    case .channelAdminLogEventActionEditTopic: return .init(summary: "Изменена тема")
    case .channelAdminLogEventActionDeleteTopic: return .init(summary: "Удалена тема")
    case .channelAdminLogEventActionPinTopic: return .init(summary: "Изменена закреплённая тема")
    case let .channelAdminLogEventActionDefaultBannedRights(previous, current):
        func rights(_ value: Api.ChatBannedRights) -> String {
            switch value { case let .chatBannedRights(flags, _):
                let selected = TelegramPeerRight.restrictions.filter { flags & $0.id != 0 }.map(\.title)
                return selected.isEmpty ? "Нет ограничений" : selected.joined(separator: "\n")
            }
        }
        return .init(summary: "Изменены разрешения участников", previous: rights(previous), current: rights(current))
    case .channelAdminLogEventActionDeleteMessage: return .init(summary: "Удалено сообщение")
    case .channelAdminLogEventActionEditMessage: return .init(summary: "Отредактировано сообщение")
    case .channelAdminLogEventActionSendMessage: return .init(summary: "Отправлено сообщение")
    case .channelAdminLogEventActionUpdatePinned: return .init(summary: "Изменено закреплённое сообщение")
    case .channelAdminLogEventActionStopPoll: return .init(summary: "Остановлен опрос")
    case .channelAdminLogEventActionStartGroupCall: return .init(summary: "Начат видеочат")
    case .channelAdminLogEventActionDiscardGroupCall: return .init(summary: "Завершён видеочат")
    case .channelAdminLogEventActionParticipantMute: return .init(summary: "Отключён микрофон участника видеочата")
    case .channelAdminLogEventActionParticipantUnmute: return .init(summary: "Включён микрофон участника видеочата")
    case .channelAdminLogEventActionParticipantVolume: return .init(summary: "Изменена громкость участника видеочата")
    case let .channelAdminLogEventActionExportedInviteDelete(invite):
        guard let text = groupAdminInvite(invite) else { return nil }; return .init(summary: "Удалена отозванная пригласительная ссылка", previous: text)
    case let .channelAdminLogEventActionExportedInviteEdit(previous, current):
        guard let first = groupAdminInvite(previous), let second = groupAdminInvite(current) else { return nil }
        return .init(summary: "Изменена пригласительная ссылка", previous: first, current: second)
    case let .channelAdminLogEventActionExportedInviteRevoke(invite):
        guard let text = groupAdminInvite(invite) else { return nil }; return .init(summary: "Отозвана пригласительная ссылка", current: text)
    case let .channelAdminLogEventActionParticipantInvite(participant):
        guard let value = groupAdminParticipant(participant) else { return nil }; return .init(summary: "Приглашён участник", current: value.text, subjectIDs: [value.id])
    case .channelAdminLogEventActionParticipantJoin: return .init(summary: "Участник вступил в чат")
    case .channelAdminLogEventActionParticipantLeave: return .init(summary: "Участник покинул чат")
    case .channelAdminLogEventActionParticipantJoinByInvite: return .init(summary: "Участник вступил по приглашению")
    case .channelAdminLogEventActionParticipantJoinByRequest: return .init(summary: "Одобрена заявка на вступление")
    case let .channelAdminLogEventActionParticipantSubExtend(previous, current),
         let .channelAdminLogEventActionParticipantToggleAdmin(previous, current),
         let .channelAdminLogEventActionParticipantToggleBan(previous, current):
        guard let first = groupAdminParticipant(previous), let second = groupAdminParticipant(current), first.id == second.id else { return nil }
        let summary: String
        switch action {
        case .channelAdminLogEventActionParticipantSubExtend: summary = "Продлена подписка участника"
        case .channelAdminLogEventActionParticipantToggleAdmin: summary = "Изменены права администратора"
        default: summary = "Изменены ограничения участника"
        }
        return .init(summary: summary, previous: first.text, current: second.text, subjectIDs: [first.id])
    }
}
