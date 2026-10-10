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

public struct TelegramChat: Identifiable, Equatable {
    public let id: Int64
    public let title: String
    public let preview: String
    public let unreadCount: Int
}

public struct TelegramMessage: Identifiable, Equatable {
    public let id: String
    public let date: Date
    public let text: String
    public let author: String
    public let isOutgoing: Bool
    public let delivery: String
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
    @Published public private(set) var phase: TelegramPhase = .configuration
    @Published public private(set) var isBusy = false
    @Published public var error: String?
    @Published public private(set) var chats: [TelegramChat] = []
    @Published public private(set) var messages: [TelegramMessage] = []
    @Published public var selectedChatID: Int64? {
        didSet {
            guard oldValue != selectedChatID else { return }
            if let accountID = account?.peerId.toInt64() {
                if let oldValue { drafts.save(draft, accountID: accountID, chatID: oldValue) }
                draft = selectedChatID.map { drafts.draft(accountID: accountID, chatID: $0) } ?? ""
            } else { draft = "" }
            loadHistory()
        }
    }
    @Published public var draft = ""
    @Published public private(set) var codeExplanation = "Введите код, полученный от Telegram."
    @Published public private(set) var connectionDescription = "Не подключено"
    private var configuration: TelegramAPIConfiguration?
    private var manager: AccountManager<TelegramAccountManagerTypes>?
    private var unauthorized: UnauthorizedAccount?
    private var challenge: TelegramAuthorizationChallenge = .phoneCode
    private var account: Account?
    private var generation = UUID()
    private var accountGeneration = UUID()
    private var authorizationGeneration = UUID()
    private var drafts = TelegramDraftStore()
    private var openingTimeout: Task<Void, Never>?
    private let session = MetaDisposable()
    private let authState = MetaDisposable()
    private let action = MetaDisposable()
    private let chatList = MetaDisposable()
    private let history = MetaDisposable()
    private let connection = MetaDisposable()
    private let outgoing = MetaDisposable()

    public init() {}

    public func connectUsingSavedAPIConfiguration() {
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
        openingTimeout?.cancel()
        account?.shouldBeServiceTaskMaster.set(.single(.never))
        account?.shouldKeepOnlinePresence.set(.single(false))
        account?.network.shouldKeepConnection.set(.single(false))
        for disposable in [session, authState, action, chatList, history, connection, outgoing] { disposable.dispose() }
    }

    public func connect(apiID: String, apiHash: String) {
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
        guard !isBusy, phase == .ready, let account, let selectedChatID,
              chats.contains(where: { $0.id == selectedChatID }), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
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
        chatList.set((account.viewTracker.tailChatListView(groupId: .root, count: 50) |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self, self.generation == token, self.accountGeneration == accountToken else { return }
            self.chats = value.0.entries.reversed().compactMap { entry in
                guard case let .MessageEntry(data) = entry, let peer = data.renderedPeer.peer else { return nil }
                return TelegramChat(id: peer.id.toInt64(), title: Self.title(peer), preview: data.messages.last?.text ?? "", unreadCount: Int(data.readState?.state.count ?? 0))
            }
            if let selected = self.selectedChatID, !self.chats.contains(where: { $0.id == selected }) { self.selectedChatID = nil }
        }))
        loadHistory()
    }

    private func stopAuthorizedAccount() {
        accountGeneration = UUID()
        account?.shouldBeServiceTaskMaster.set(.single(.never))
        account?.shouldKeepOnlinePresence.set(.single(false))
        account?.network.shouldKeepConnection.set(.single(false))
        for disposable in [chatList, history, connection, outgoing] { disposable.set(nil) }
        selectedChatID = nil // Saves the draft while its account identity is available.
        account = nil
        chats = []; messages = []; draft = ""
    }

    private func loadHistory() {
        history.set(nil); messages = []
        guard let account, let selectedChatID, chats.contains(where: { $0.id == selectedChatID }) else { return }
        let token = generation
        let accountToken = accountGeneration
        let chat = selectedChatID
        history.set((account.viewTracker.aroundMessageOfInterestHistoryViewForLocation(.peer(peerId: PeerId(chat), threadId: nil), count: 50)
            |> deliverOnMainQueue).start(next: { [weak self] value in
                guard let self, self.generation == token, self.accountGeneration == accountToken, self.selectedChatID == chat else { return }
                self.messages = value.0.entries.map { entry in
                    let message = entry.message
                    let delivery = message.flags.contains(.Failed) ? "Не отправлено" : message.flags.contains(.Unsent) ? "В очереди отправки" : ""
                    return TelegramMessage(id: "\(message.id.peerId.toInt64()):\(message.id.namespace):\(message.id.id)",
                        date: Date(timeIntervalSince1970: TimeInterval(message.timestamp)), text: message.text,
                        author: message.author.map(Self.title) ?? "Telegram", isOutgoing: !message.flags.contains(.Incoming), delivery: delivery)
                }
            }))
    }

    private static func title(_ peer: Peer) -> String {
        if let user = peer as? TelegramUser { return [user.firstName, user.lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") }
        if let group = peer as? TelegramGroup { return group.title }
        if let channel = peer as? TelegramChannel { return channel.title }
        return "Диалог \(peer.id.toInt64())"
    }
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
