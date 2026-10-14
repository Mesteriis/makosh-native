import TelegramApi

func telegramCallFullUserFixture(flags: Int32 = 1 << 4, min: Bool = false, duplicate: Bool = false, hash: Int64 = 77) -> Api.users.UserFull {
    let user = Api.User.user(flags: 2 | (1 << 0) | (min ? 1 << 20 : 0), flags2: 0, id: 42, accessHash: hash,
        firstName: "Synthetic Alice", lastName: nil, username: nil, phone: nil, photo: nil, status: nil, botInfoVersion: nil,
        restrictionReason: nil, botInlinePlaceholder: nil, langCode: nil, emojiStatus: nil, usernames: nil, storiesMaxId: nil,
        color: nil, profileColor: nil, botActiveUsers: nil, botVerificationIcon: nil, sendPaidMessagesStars: nil)
    let data = Api.UserFull.userFull(flags: flags, flags2: 0, id: 42, about: nil,
        settings: .peerSettings(flags: 0, geoDistance: nil, requestChatTitle: nil, requestChatDate: nil, businessBotId: nil,
            businessBotManageUrl: nil, chargePaidMessageStars: nil, registrationMonth: nil, phoneCountry: nil, nameChangeDate: nil, photoChangeDate: nil),
        personalPhoto: nil, profilePhoto: nil, fallbackPhoto: nil,
        notifySettings: .peerNotifySettings(flags: 0, showPreviews: nil, silent: nil, muteUntil: nil, iosSound: nil,
            androidSound: nil, otherSound: nil, storiesMuted: nil, storiesHideSender: nil, storiesIosSound: nil,
            storiesAndroidSound: nil, storiesOtherSound: nil), botInfo: nil, pinnedMsgId: nil, commonChatsCount: 0,
        folderId: nil, ttlPeriod: nil, themeEmoticon: nil, privateForwardName: nil, botGroupAdminRights: nil,
        botBroadcastAdminRights: nil, wallpaper: nil, stories: nil, businessWorkHours: nil, businessLocation: nil,
        businessGreetingMessage: nil, businessAwayMessage: nil, businessIntro: nil, birthday: nil, personalChannelId: nil,
        personalChannelMessage: nil, stargiftsCount: nil, starrefProgram: nil, botVerification: nil, sendPaidMessagesStars: nil,
        disallowedGifts: nil, starsRating: nil)
    return .userFull(fullUser: data, chats: [], users: duplicate ? [user, user] : [user])
}
