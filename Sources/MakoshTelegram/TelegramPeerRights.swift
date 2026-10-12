import Foundation
import TelegramCore

public struct TelegramPeerRight: Identifiable, Sendable {
    public let id: Int32
    public let title: String
    public static var administrators: [Self] {
        let rows: [(TelegramChatAdminRightsFlags, String)] = [
            (.canChangeInfo, "Изменять информацию"), (.canPostMessages, "Публиковать сообщения"),
            (.canEditMessages, "Редактировать сообщения"), (.canDeleteMessages, "Удалять сообщения"),
            (.canBanUsers, "Блокировать участников"), (.canInviteUsers, "Приглашать участников"),
            (.canPinMessages, "Закреплять сообщения"), (.canAddAdmins, "Добавлять администраторов"),
            (.canBeAnonymous, "Оставаться анонимным"), (.canManageCalls, "Управлять видеочатами"),
            (.canManageTopics, "Управлять темами"), (.canPostStories, "Публиковать истории"),
            (.canEditStories, "Изменять истории"), (.canDeleteStories, "Удалять истории"),
            (.canManageDirect, "Управлять личными сообщениями канала")
        ]
        return rows.map { .init(id: $0.0.rawValue, title: $0.1) }
    }
    /// Toggles describe prohibitions, matching native banned-rights polarity.
    public static var restrictions: [Self] {
        let rows: [(TelegramChatBannedRightsFlags, String)] = [
            (.banReadMessages, "Исключить из чата"), (.banSendText, "Запретить текстовые сообщения"),
            (.banSendPhotos, "Запретить фотографии"),
            (.banSendVideos, "Запретить видео"), (.banSendInstantVideos, "Запретить видеосообщения"),
            (.banSendMusic, "Запретить музыку"), (.banSendVoice, "Запретить голосовые сообщения"),
            (.banSendFiles, "Запретить файлы"), (.banSendStickers, "Запретить стикеры"),
            (.banSendGifs, "Запретить GIF"), (.banSendGames, "Запретить игры"),
            (.banSendInline, "Запретить inline-ботов"), (.banEmbedLinks, "Запретить предпросмотр ссылок"),
            (.banSendPolls, "Запретить опросы"), (.banChangeInfo, "Запретить изменение информации"),
            (.banAddMembers, "Запретить приглашения"), (.banPinMessages, "Запретить закрепление"),
            (.banManageTopics, "Запретить управление темами")
        ]
        return rows.map { .init(id: $0.0.rawValue, title: $0.1) }
    }
}
