import Foundation
import Combine
import Security
import TelegramCore
import Postbox
import SwiftSignalKit
import OpenSSLEncryption

public enum TelegramPhase: Equatable {
    case configuration, connecting, phone, code, password(hint: String), ready, unsupported(String)
}

public struct TelegramChat: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let title: String
    public let preview: String
    public let unreadCount: Int
}

public struct TelegramMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let text: String
    public let author: String
    public let isOutgoing: Bool
    public let delivery: String
    public var attachments: [TelegramAttachment] = []
}

public struct TelegramAPIConfiguration: Equatable {
    public let id: Int32
    public let hash: String
    public init(id: String, hash: String) throws {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHash = hash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, trimmedID.utf8.allSatisfy({ (48...57).contains($0) }),
              let parsed = Int32(trimmedID), parsed > 0,
              trimmedHash.utf8.count == 32,
              trimmedHash.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw TelegramSetupError.invalidAPI
        }
        self.id = parsed
        self.hash = trimmedHash
    }
}

enum TelegramSetupError: LocalizedError {
    case invalidAPI, keychain, missingSessionKey, filesystem
    var errorDescription: String? {
        switch self {
        case .invalidAPI: "Укажите положительный API ID и API hash из 32 шестнадцатеричных символов, полученные для вашего приложения."
        case .keychain: "Не удалось открыть ключ сеанса в Связке ключей. Данные сеанса не изменены."
        case .missingSessionKey: "Ключ существующего сеанса недоступен. Восстановите Связку ключей; Макош не создаёт новый ключ поверх старых данных."
        case .filesystem: "Не удалось открыть отдельный каталог сеанса Макоша. Проверьте доступ к Application Support."
        }
    }
}

/// Own integration over the exact TelegramSwift engine gitlink. Initialization
/// performs no account, Keychain, filesystem or network access until Connect.
@MainActor
public final class TelegramModel: ObservableObject {
    public let search = TelegramSearchModel()
    public let media = TelegramMediaController()
    public let playback = TelegramPlaybackController()
    public let upload = TelegramUploadController()
    public var uploadContextID: UUID { accountGeneration }
    @Published public private(set) var phase: TelegramPhase = .configuration
    @Published public private(set) var isBusy = false
    @Published public var error: String?
    @Published public private(set) var chats: [TelegramChat] = []
    @Published public private(set) var messages: [TelegramMessage] = []
    @Published public private(set) var chatPage: TelegramPageNavigation = .idle
    @Published public private(set) var historyPage: TelegramPageNavigation = .idle
    @Published public var chatFolder: TelegramChatFolder = .inbox {
        didSet { if oldValue != chatFolder { loadChatList(clear: true); search.setFolder(chatFolder) } }
    }
    public var selectedChat: TelegramChat? { selectedChatID.flatMap { knownChats[$0] } }
    public var uploadTarget: TelegramUploadTarget? {
        guard phase == .ready, !isBusy, let chat = selectedChat, let accountID = draftAccountID else { return nil }
        if !isSyntheticPreview {
            guard [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel]
                .contains(PeerId(chat.id).namespace) else { return nil }
        }
        return TelegramUploadTarget(accountID: accountID, chatID: chat.id, title: chat.title)
    }
    public var historyWindowID: UUID? { historyPages.requestID }
    @Published public private(set) var historyFocusID: String?
    public var readyHistoryFocusID: String? {
        guard !historyPage.isLoading, !historyPage.timedOut,
              let id = historyFocusID, messages.contains(where: { $0.id == id }) else { return nil }
        return id
    }
    var chatWindowID: UUID? { chatPages.requestID }
    @Published public var selectedChatID: Int64? {
        didSet {
            guard oldValue != selectedChatID else { return }
            playback.stop()
            if let id = selectedChatID, let found = search.chats.first(where: { $0.id == id }) { knownChats[id] = found }
            if let accountID = draftAccountID {
                if let oldValue { drafts.save(draft, accountID: accountID, chatID: oldValue) }
                draft = selectedChatID.map { drafts.draft(accountID: accountID, chatID: $0) } ?? ""
            } else { draft = "" }
            search.selectChat(selectedChatID)
            loadHistory()
        }
    }
    @Published public var draft = ""
    @Published public private(set) var codeExplanation = "Введите код, полученный от Telegram."
    @Published public private(set) var connectionDescription = "Не подключено"
    public private(set) var isSyntheticPreview = false
    private var configuration: TelegramAPIConfiguration?
    private var manager: AccountManager<TelegramAccountManagerTypes>?
    private var unauthorized: UnauthorizedAccount?
    private var challenge: TelegramAuthorizationChallenge = .phoneCode
    private var account: Account?
    private var generation = UUID()
    private var accountGeneration = UUID()
    private var authorizationGeneration = UUID()
    private var drafts = TelegramDraftStore()
    private var knownChats: [Int64: TelegramChat] = [:]
    private var mediaProvider: TelegramEngineMediaProvider?
    private var historyMediaSources: [TelegramAttachmentSource] = []
    private var chatPages = TelegramPageTracker<ChatListIndex>()
    private var historyPages = TelegramPageTracker<MessageIndex>()
    private var openingTimeout: Task<Void, Never>?
    private var chatPageTimeout: Task<Void, Never>?
    private var historyPageTimeout: Task<Void, Never>?
    #if DEBUG
    private var preview: TelegramSyntheticPages?
    #endif
    private var draftAccountID: Int64? {
        if isSyntheticPreview { return -1 }
        return account?.peerId.toInt64()
    }
    private let session = MetaDisposable()
    private let authState = MetaDisposable()
    private let action = MetaDisposable()
    private let chatList = MetaDisposable()
    private let history = MetaDisposable()
    private let connection = MetaDisposable()
    private let outgoing = MetaDisposable()

    public init() {
        search.mediaSourcesDidChange = { [weak self] in self?.refreshMediaSources() }
        upload.didQueue = { [weak self] target, caption in self?.acknowledgeUpload(target: target, caption: caption) }
    }

    public func prepareUpload(source: URL, mode: TelegramUploadMode, target: TelegramUploadTarget, caption: String, contextID: UUID) {
        guard contextID == accountGeneration, phase == .ready,
              target.accountID == draftAccountID, knownChats[target.chatID] != nil else { return }
        if selectedChatID == target.chatID { drafts.save(draft, accountID: target.accountID, chatID: target.chatID) }
        upload.prepare(source: source, mode: mode, target: target, caption: caption)
    }

    func acknowledgeUpload(target: TelegramUploadTarget, caption: String) {
        guard target.accountID == draftAccountID else { return }
        drafts.acknowledge(sentText: caption, accountID: target.accountID, chatID: target.chatID)
        if selectedChatID == target.chatID, draft.utf8.elementsEqual(caption.utf8) { draft = "" }
    }

    public func connectUsingSavedAPIConfiguration() {
        guard !isSyntheticPreview else { return }
        guard !isBusy, phase == .configuration else { return }
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let configuration = try TelegramAPIFile.load(from: support.appendingPathComponent("Makosh/telegram-api.json"))
            connect(apiID: String(configuration.id), apiHash: configuration.hash)
        } catch {
            self.error = "Не удалось открыть локальные API-данные. Проверьте файл telegram-api.json и права 0600 или введите API ID и API hash вручную."
        }
    }

    isolated deinit {
        playback.stop()
        openingTimeout?.cancel()
        chatPageTimeout?.cancel()
        historyPageTimeout?.cancel()
        account?.shouldBeServiceTaskMaster.set(.single(.never))
        account?.shouldKeepOnlinePresence.set(.single(false))
        account?.network.shouldKeepConnection.set(.single(false))
        for disposable in [session, authState, action, chatList, history, connection, outgoing] { disposable.dispose() }
    }

    public func connect(apiID: String, apiHash: String) {
        guard !isSyntheticPreview else { return }
        guard !isBusy, phase == .configuration else { return }
        do {
            let configuration = try TelegramAPIConfiguration(id: apiID, hash: apiHash)
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent("Makosh/Telegram", isDirectory: true)
            let encryption = try TelegramSessionKey.open(directory: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            TelegramRuntime.configureLogging(directory: directory)
            initializeAccountManagement()
            let manager = AccountManager<TelegramAccountManagerTypes>(basePath: directory.appendingPathComponent("accounts-metadata").path, isTemporary: false, isReadOnly: false, useCaches: true, removeDatabaseOnError: false)
            self.configuration = configuration
            self.manager = manager
            self.phase = .connecting
            self.isBusy = true
            self.error = nil
            self.connectionDescription = "Открытие отдельного сеанса"
            let token = generation
            openingTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(45)) } catch { return }
                guard let self, self.generation == token, self.phase == .connecting else { return }
                self.isBusy = false
                self.phase = .unsupported("Локальный сеанс не открылся за 45 секунд. Остановите подключение и проверьте кэш; Макош не удаляет его автоматически.")
            }
            let arguments = NetworkInitializationArguments(apiId: configuration.id, apiHash: configuration.hash,
                languagesCategory: "macos", appVersion: "Makosh 0.2", voipMaxLayer: 0, voipVersions: [],
                appData: .single(nil), externalRequestVerificationStream: .single([:]),
                externalRecaptchaRequestVerification: { _, _ in .complete() }, autolockDeadine: .single(nil),
                encryptionProvider: OpenSSLEncryptionProvider(), deviceModelName: "Mac", useBetaFeatures: false, isICloudEnabled: false)
            let auxiliary = AccountAuxiliaryMethods(fetchResource: { _, _, _, _ in nil },
                fetchResourceMediaReferenceHash: { _ in .single(nil) }, prepareSecretThumbnailData: { _ in nil }, backgroundUpload: { _, _, _ in .single(nil) })
            session.set((currentAccount(allocateIfNotExists: true, networkArguments: arguments, supplementary: false,
                manager: manager, rootPath: directory.path, auxiliaryMethods: auxiliary, encryptionParameters: encryption)
                |> deliverOnMainQueue).start(next: { [weak self] result in
                    guard let self, self.generation == token else { return }
                    switch result {
                    case .unauthorized(let account): self.observeUnauthorized(account, token: token)
                    case .authorized(let account): self.observeAuthorized(account, token: token)
                    case .upgrading: self.connectionDescription = "Открытие или обновление локального кэша"
                    case nil:
                        self.openingTimeout?.cancel()
                        self.isBusy = false
                        self.phase = .unsupported("Не удалось получить состояние отдельного сеанса. Данные не удалены. Остановите подключение перед следующей попыткой.")
                    }
                }))
        } catch {
            self.error = (error as? TelegramSetupError)?.localizedDescription ?? TelegramSetupError.filesystem.localizedDescription
            self.isBusy = false
            self.phase = .configuration
        }
    }

    public func submitPhone(_ phone: String) {
        guard !isBusy, phase == .phone, let configuration, let manager, let unauthorized else { return }
        let number = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard number.hasPrefix("+"), (8...16).contains(number.count), number.dropFirst().utf8.allSatisfy({ (48...57).contains($0) }) else {
            error = "Введите номер в международном формате: + и цифры без пробелов."; return
        }
        isBusy = true; error = nil
        let token = generation
        let authToken = authorizationGeneration
        action.set((sendAuthorizationCode(accountManager: manager, account: unauthorized, phoneNumber: number,
            apiId: configuration.id, apiHash: configuration.hash, pushNotificationConfiguration: nil,
            firebaseSecretStream: .single([:]), syncContacts: false, disableAuthTokens: true, forcedPasswordSetupNotice: { _ in nil })
            |> timeout(30, queue: .mainQueue(), alternate: .fail(.timeout))
            |> deliverOnMainQueue).start(next: { [weak self] result in
                guard let self, self.generation == token, self.authorizationGeneration == authToken else { return }
                self.isBusy = false
                if case let .sentCode(account) = result { self.observeUnauthorized(account, token: token) }
            }, error: { [weak self] failure in
                guard let self, self.generation == token, self.authorizationGeneration == authToken else { return }
                self.isBusy = false
                switch failure {
                case .invalidPhoneNumber: self.error = "Telegram не принял номер телефона."
                case .limitExceeded, .phoneLimitExceeded: self.error = "Telegram ограничил попытки. Подождите перед новым запросом."
                case .phoneBanned: self.error = "Этот номер заблокирован Telegram."
                case .timeout: self.error = "Нет ответа Telegram. Код мог быть запрошен; не повторяйте запрос сразу."
                case .appOutdated: self.error = "Telegram требует обновлённый способ входа. Эта версия ядра его не поддерживает."
                case .generic: self.error = "Telegram не завершил запрос кода. Проверьте сеть и собственные API-данные."
                }
            }))
    }

    public func submitCode(_ code: String) {
        guard !isBusy, phase == .code, !code.isEmpty, let manager, let unauthorized,
              let authorizationCode = challenge.authorizationCode(code) else { return }
        isBusy = true; error = nil
        let token = generation
        let authToken = authorizationGeneration
        action.set((authorizeWithCode(accountManager: manager, account: unauthorized, code: authorizationCode, termsOfService: nil, forcedPasswordSetupNotice: { _ in nil })
            |> timeout(30, queue: .mainQueue(), alternate: .fail(.generic))
            |> deliverOnMainQueue).start(next: { [weak self] result in
                guard let self, self.generation == token, self.authorizationGeneration == authToken else { return }
                self.isBusy = false
                if case .signUp = result { self.phase = .unsupported("Создание нового аккаунта здесь не реализовано. Используйте уже зарегистрированный аккаунт.") }
            }, error: { [weak self] _ in
                guard let self, self.generation == token, self.authorizationGeneration == authToken else { return }
                self.isBusy = false; self.error = "Telegram не завершил проверку кода. Проверьте код, сеть и текущее состояние входа перед повторной попыткой."
            }))
    }

    public func submitPassword(_ password: String) {
        guard !isBusy, case .password = phase, !password.isEmpty, let manager, let unauthorized else { return }
        isBusy = true; error = nil
        let token = generation
        let authToken = authorizationGeneration
        action.set((authorizeWithPassword(accountManager: manager, account: unauthorized, password: password, syncContacts: false)
            |> timeout(30, queue: .mainQueue(), alternate: .fail(.generic))
            |> deliverOnMainQueue).start(error: { [weak self] _ in
                guard let self, self.generation == token, self.authorizationGeneration == authToken else { return }
                self.isBusy = false; self.error = "Telegram не завершил проверку пароля. Проверьте пароль, сеть и ограничения попыток."
            }, completed: { [weak self] in
                guard let self, self.generation == token, self.authorizationGeneration == authToken else { return }; self.isBusy = false
            }))
    }

    public func disconnect() {
        #if DEBUG
        preview = nil
        #endif
        generation = UUID()
        openingTimeout?.cancel(); openingTimeout = nil
        stopAuthorizedAccount()
        for disposable in [session, authState, action, chatList, history, connection, outgoing] { disposable.set(nil) }
        selectedChatID = nil
        account = nil; unauthorized = nil; manager = nil; configuration = nil
        chats = []; messages = []; draft = ""
        isBusy = false; phase = .configuration; error = nil; connectionDescription = "Подключение остановлено; локальный сеанс сохранён"
    }

    public func sendMessage(_ text: String) -> Bool {
        guard !isSyntheticPreview else { error = "Синтетическая проверка: отправка отключена."; return false }
        guard !isBusy, phase == .ready, let account, let selectedChatID,
              knownChats[selectedChatID] != nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard text.utf16.count <= 4096 else { error = "Текст превышает 4096 символов. Разделите сообщение."; return false }
        let token = generation
        let accountToken = accountGeneration
        let chat = selectedChatID
        let accountID = account.peerId.toInt64()
        drafts.save(text, accountID: accountID, chatID: chat)
        isBusy = true; error = nil
        let message = EnqueueMessage.message(text: text, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
        outgoing.set((enqueueMessages(account: account, peerId: PeerId(chat), messages: [message]) |> deliverOnMainQueue).start(next: { [weak self] ids in
            guard let self, self.generation == token, self.accountGeneration == accountToken else { return }
            self.isBusy = false
            if ids.contains(where: { $0 != nil }) {
                self.drafts.acknowledge(sentText: text, accountID: accountID, chatID: chat)
                if self.selectedChatID == chat, self.draft.utf8.elementsEqual(text.utf8) { self.draft = "" }
            } else { self.error = "Сообщение не поставлено в очередь. Текст сохранён в поле ввода." }
        }))
        return true // Accepted for enqueue; only its acknowledgement clears the draft.
    }

    private func observeUnauthorized(_ account: UnauthorizedAccount, token: UUID) {
        openingTimeout?.cancel(); openingTimeout = nil
        stopAuthorizedAccount()
        authorizationGeneration = UUID()
        let authToken = authorizationGeneration
        self.unauthorized = account
        self.account = nil
        self.isBusy = false
        self.connectionDescription = "Вход в отдельный сеанс Макоша"
        authState.set((account.postbox.stateView() |> deliverOnMainQueue).start(next: { [weak self] view in
            guard let self, self.generation == token, self.authorizationGeneration == authToken, let state = view.state as? UnauthorizedAccountState else { return }
            switch state.contents {
            case .empty, .phoneEntry: self.phase = .phone
            case let .confirmationCodeEntry(_, type, _, _, _, _, _, _):
                self.challenge = TelegramAuthorizationChallenge(type: type)
                self.codeExplanation = self.challenge.explanation
                self.phase = self.challenge.phase
            case .passwordEntry(let hint, _, _, _, _): self.phase = .password(hint: hint)
            case .signUp: self.phase = .unsupported("Регистрация нового аккаунта не реализована.")
            case .passwordRecovery, .awaitingAccountReset: self.phase = .unsupported("Восстановление и сброс аккаунта выполняйте в официальном клиенте Telegram.")
            case .payment: self.phase = .unsupported("Telegram запросил платный способ входа. Макош не выполняет оплату.")
            }
        }))
    }

    private func observeAuthorized(_ account: Account, token: UUID) {
        openingTimeout?.cancel(); openingTimeout = nil
        guard self.account !== account else { return }
        stopAuthorizedAccount()
        authorizationGeneration = UUID()
        action.set(nil)
        self.unauthorized = nil; self.account = account
        // Installs TelegramCore's built-in cloud/secret resource fetcher on this
        // account's MediaBox. Auxiliary nil alone does not install the fallback.
        setupAccount(account)
        let mediaProvider = TelegramEngineMediaProvider(account: account)
        self.mediaProvider = mediaProvider
        media.bind(provider: mediaProvider)
        upload.bind(provider: TelegramEngineUploadProvider(account: account))
        search.bind(account: account)
        search.setFolder(chatFolder)
        let accountToken = accountGeneration
        self.authState.set(nil); self.isBusy = false; self.phase = .ready
        account.shouldBeServiceTaskMaster.set(.single(.always))
        account.shouldKeepOnlinePresence.set(.single(false))
        account.network.shouldKeepConnection.set(.single(true))
        connection.set((account.networkState |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let self, self.generation == token, self.accountGeneration == accountToken else { return }
            switch state {
            case .waitingForNetwork: self.connectionDescription = "Ожидание сети"
            case .connecting: self.connectionDescription = "Соединение с Telegram"
            case .updating: self.connectionDescription = "Синхронизация"
            case .online: self.connectionDescription = "Подключено к Telegram"
            }
        }))
        loadChatList(clear: true)
        loadHistory()
    }

    private func stopAuthorizedAccount() {
        playback.stop()
        upload.bind(provider: nil)
        mediaProvider = nil; historyMediaSources = []
        media.bind(provider: nil)
        search.bind(account: nil)
        accountGeneration = UUID()
        account?.shouldBeServiceTaskMaster.set(.single(.never))
        account?.shouldKeepOnlinePresence.set(.single(false))
        account?.network.shouldKeepConnection.set(.single(false))
        for disposable in [chatList, history, connection, outgoing] { disposable.set(nil) }
        chatPageTimeout?.cancel(); chatPageTimeout = nil
        historyPageTimeout?.cancel(); historyPageTimeout = nil
        chatPages.reset(); historyPages.reset()
        chatPage = .idle; historyPage = .idle
        selectedChatID = nil // Saves the draft while its account identity is available.
        account = nil
        knownChats = [:]; chats = []; messages = []; draft = ""
        refreshMediaSources()
    }

    public func loadOlderChats() {
        guard chatPages.canLoadPrevious, let cursor = chatPages.previousCursor else { return }
        loadChatList(anchor: cursor)
    }

    public func loadNewerChats() {
        guard chatPages.canLoadNext, let cursor = chatPages.nextCursor else { return }
        loadChatList(anchor: cursor)
    }

    public func showLatestChats() { loadChatList() }
    public func retryChatPage() { loadChatList(anchor: chatPages.anchor) }

    public func loadOlderMessages() {
        guard historyPages.canLoadPrevious, let cursor = historyPages.previousCursor else { return }
        loadHistory(anchor: cursor, clear: false)
    }

    public func loadNewerMessages() {
        guard historyPages.canLoadNext, let cursor = historyPages.nextCursor else { return }
        loadHistory(anchor: cursor, clear: false)
    }

    public func showLatestMessages() { loadHistory(clear: false) }
    public func retryHistoryPage() { loadHistory(anchor: historyPages.anchor, clear: false) }

    public func openSearchMessage(id: String) {
        // Migrated-group matches have the old peer ID. Postbox includes that
        // associated history; validate the search's selected chat, not the index peer.
        guard let index = search.messageIndex(id: id, inChat: selectedChatID) else { return }
        search.messageQuery = ""
        loadHistory(anchor: index, clear: false, focusID: id)
    }

    public func clearHistoryFocus() { historyFocusID = nil }

    public func cancelMediaLoads() {
        playback.stop()
        #if DEBUG
        if isSyntheticPreview {
            media.bind(provider: TelegramSyntheticMediaProvider())
            refreshMediaSources()
            return
        }
        #endif
        media.bind(provider: mediaProvider)
        refreshMediaSources()
    }

    private func refreshMediaSources() {
        let sources = historyMediaSources + Array(search.mediaSources.values)
        mediaProvider?.sources = Dictionary(sources.map { ($0.attachment.id, $0) }, uniquingKeysWith: { _, last in last })
        let attachments = (messages + search.messages).flatMap(\.attachments)
        playback.retain(attachments: attachments)
        media.retain(attachments: attachments)
    }

    private func loadChatList(anchor: ChatListIndex? = nil, clear: Bool = false) {
        chatList.set(nil)
        chatPageTimeout?.cancel(); chatPageTimeout = nil
        if clear { chats = [] }
        #if DEBUG
        if let preview {
            let requestID = chatPages.begin(anchor: anchor)
            let page = preview.chats(folder: chatFolder, anchor: anchor)
            receiveChats(page.items, requestID: requestID, previous: page.previous, next: page.next, isLoading: false)
            return
        }
        #endif
        guard let account else { chatPages.reset(); chatPage = .idle; return }
        let token = generation
        let accountToken = accountGeneration
        let folder = chatFolder
        let requestID = chatPages.begin(anchor: anchor)
        chatPage = chatPages.navigation
        updateChatDeadline(requestID: requestID)
        let group: PeerGroupId = folder == .inbox ? .root : Namespaces.PeerGroup.archive
        let signal: Signal<(ChatListView, ViewUpdateType), NoError>
        if let anchor { signal = account.viewTracker.aroundChatListView(groupId: group, index: anchor, count: 50) }
        else { signal = account.viewTracker.tailChatListView(groupId: group, count: 50) }
        chatList.set((signal |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self, self.generation == token, self.accountGeneration == accountToken,
                  self.chatFolder == folder else { return }
            let view = value.0
            let hasHole = view.entries.contains { if case .HoleEntry = $0 { return true }; return false }
            let chats = view.entries.reversed().compactMap { entry -> TelegramChat? in
                guard case let .MessageEntry(data) = entry, let peer = data.renderedPeer.peer else { return nil }
                return TelegramChat(id: peer.id.toInt64(), title: telegramPeerTitle(peer), preview: data.messages.last?.text ?? "", unreadCount: Int(data.readState?.state.count ?? 0))
            }
            self.receiveChats(chats, requestID: requestID, previous: view.earlierIndex,
                next: view.laterIndex, isLoading: hasHole)
        }))
    }

    private func loadHistory(anchor: MessageIndex? = nil, clear: Bool = true, focusID: String? = nil) {
        playback.stop()
        historyFocusID = focusID
        history.set(nil)
        historyPageTimeout?.cancel(); historyPageTimeout = nil
        if clear { messages = []; historyMediaSources = []; refreshMediaSources() }
        #if DEBUG
        if let preview, let selectedChatID, knownChats[selectedChatID] != nil {
            let requestID = historyPages.begin(anchor: anchor)
            let page = preview.messages(chatID: selectedChatID, anchor: anchor)
            receiveMessages(page.items, requestID: requestID, previous: page.previous, next: page.next, isLoading: false)
            return
        }
        #endif
        guard let account, let selectedChatID, knownChats[selectedChatID] != nil else {
            historyPages.reset(); historyPage = .idle; return
        }
        let token = generation
        let accountToken = accountGeneration
        let chat = selectedChatID
        let requestID = historyPages.begin(anchor: anchor)
        historyPage = historyPages.navigation
        updateHistoryDeadline(requestID: requestID)
        let index: MessageHistoryAnchorIndex = anchor.map { .message($0) } ?? .upperBound
        history.set((account.viewTracker.aroundMessageHistoryViewForLocation(.peer(peerId: PeerId(chat), threadId: nil),
                index: index, anchorIndex: index, count: 50, fixedCombinedReadStates: nil)
            |> deliverOnMainQueue).start(next: { [weak self] value in
                guard let self, self.generation == token, self.accountGeneration == accountToken,
                      self.selectedChatID == chat, self.historyPages.requestID == requestID else { return }
                let view = value.0
                let waiting = view.isLoading || view.isLoadingEarlier ||
                    (view.earlierId == nil && view.holeEarlier) || (view.laterId == nil && view.holeLater)
                let messages = view.entries.map { TelegramMessage($0.message) }
                if !messages.isEmpty || !waiting {
                    self.historyMediaSources = view.entries.flatMap { telegramAttachments($0.message) }
                }
                self.receiveMessages(messages, requestID: requestID, previous: view.earlierId,
                    next: view.laterId, isLoading: waiting, hasPreviousGap: view.holeEarlier, hasNextGap: view.holeLater)
            }))
    }

    func receiveChats(_ items: [TelegramChat], requestID: UUID, previous: ChatListIndex?,
                      next: ChatListIndex?, isLoading: Bool) {
        guard chatPages.update(requestID: requestID, previous: previous, next: next,
            isLoading: isLoading, hasPreviousGap: isLoading) else { return }
        chatPage = chatPages.navigation
        updateChatDeadline(requestID: requestID)
        for chat in items { knownChats[chat.id] = chat }
        // Keep the previous window while an empty loading snapshot fills holes.
        // A stable empty snapshot still clears deleted/empty contents.
        if !items.isEmpty || !isLoading { chats = items }
    }

    func receiveMessages(_ items: [TelegramMessage], requestID: UUID, previous: MessageIndex?,
                         next: MessageIndex?, isLoading: Bool, hasPreviousGap: Bool = false,
                         hasNextGap: Bool = false) {
        guard historyPages.update(requestID: requestID, previous: previous, next: next,
            isLoading: isLoading, hasPreviousGap: hasPreviousGap, hasNextGap: hasNextGap) else { return }
        historyPage = historyPages.navigation
        updateHistoryDeadline(requestID: requestID)
        if !items.isEmpty || !isLoading { messages = items }
        refreshMediaSources()
    }

    private func updateChatDeadline(requestID: UUID) {
        guard chatPage.isLoading else { chatPageTimeout?.cancel(); chatPageTimeout = nil; return }
        guard chatPageTimeout == nil else { return }
        chatPageTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.chatPages.timeout(requestID: requestID) else { return }
            self.chatPageTimeout = nil
            self.chatPage = self.chatPages.navigation
        }
    }

    private func updateHistoryDeadline(requestID: UUID) {
        guard historyPage.isLoading else { historyPageTimeout?.cancel(); historyPageTimeout = nil; return }
        guard historyPageTimeout == nil else { return }
        historyPageTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.historyPages.timeout(requestID: requestID) else { return }
            self.historyPageTimeout = nil
            self.historyPage = self.historyPages.navigation
        }
    }

    #if DEBUG
    /// Explicit, in-memory UI fixture. Does not open accounts, files or Keychain.
    public static func syntheticPreview() -> TelegramModel {
        let model = TelegramModel()
        model.preview = TelegramSyntheticPages()
        model.search.useSyntheticPreview()
        model.media.bind(provider: TelegramSyntheticMediaProvider())
        model.upload.bind(provider: TelegramSyntheticUploadProvider())
        model.isSyntheticPreview = true
        model.phase = .ready
        model.connectionDescription = "Синтетическая UI-проверка • сеть и отправка отключены"
        model.loadChatList(clear: true)
        return model
    }
    #endif

}

private enum TelegramSessionKey {
    static func open(directory: URL) throws -> ValueBoxEncryptionParameters {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.makosh.telegram", kSecAttrAccount as String: "session-encryption-v1"]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        let bytes: Data
        if status == errSecSuccess {
            guard let data = result as? Data, data.count == 48 else { throw TelegramSetupError.keychain }
            bytes = data
        } else if status == errSecItemNotFound {
            if FileManager.default.fileExists(atPath: directory.path),
               !(try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty { throw TelegramSetupError.missingSessionKey }
            var generated = Data(count: 48)
            guard generated.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 48, $0.baseAddress!) }) == errSecSuccess else { throw TelegramSetupError.keychain }
            var item = query
            item[kSecValueData as String] = generated
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw TelegramSetupError.keychain }
            bytes = generated
        } else { throw TelegramSetupError.keychain }
        guard let key = ValueBoxEncryptionParameters.Key(data: bytes.prefix(32)),
              let salt = ValueBoxEncryptionParameters.Salt(data: bytes.suffix(16)) else { throw TelegramSetupError.keychain }
        return ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt)
    }
}
