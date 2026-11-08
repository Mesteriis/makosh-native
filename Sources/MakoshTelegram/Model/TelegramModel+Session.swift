import Foundation
import MakoshBuildConfiguration
import MakoshCore
import TelegramCore
import Postbox
import SwiftSignalKit

/// Connection, authorization (phone/code/password/QR) and account lifecycle.
extension TelegramModel {
    public var hasEmbeddedAPIConfiguration: Bool {
        MakoshBuildConfiguration.telegramAPIID != nil && MakoshBuildConfiguration.telegramAPIHash != nil
    }

    public func connect() {
        guard !isSyntheticPreview, !isBusy, phase == .configuration else { return }
        guard let id = MakoshBuildConfiguration.telegramAPIID,
            let hash = MakoshBuildConfiguration.telegramAPIHash
        else {
            error = "Telegram не настроен в этой сборке."
            return
        }
        connect(apiID: String(id), apiHash: hash)
    }

    public func connect(apiID: String, apiHash: String) {
        guard !isSyntheticPreview, !isBusy, phase == .configuration else { return }
        do { beginConnection(try TelegramAPIConfiguration(id: apiID, hash: apiHash)) } catch {
            self.error = TelegramSetupError.invalidAPI.localizedDescription
        }
    }

    func beginConnection(_ configuration: TelegramAPIConfiguration) {
        self.configuration = configuration
        phase = .connecting
        isBusy = true
        error = nil
        connectionDescription = "Открытие отдельного сеанса"
        let token = generation, clientID = proxyClientID, proxy = proxy, worker = sessionWorker
        openingTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            guard let self, self.generation == token, self.phase == .connecting else { return }
            self.disconnect()
            self.phase = .unsupported(
                "Локальный сеанс не открылся за 45 секунд. Соединение остановлено; локальные данные сохранены. Проверьте кэш перед новой попыткой."
            )
        }
        sessionOpeningTask = Task { [weak self] in
            do {
                let proxySettings = try await proxy.settingsForConnection(clientID: clientID)
                let prepared = try await worker.prepare()
                try Task.checkCancellation()
                guard let self, self.generation == token, self.phase == .connecting else {
                    proxy.unregister(clientID: clientID)
                    return
                }
                self.startNativeConnection(
                    configuration: configuration, proxySettings: proxySettings,
                    directory: prepared.directory, encryption: try prepared.encryption, token: token)
            } catch {
                proxy.unregister(clientID: clientID)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.openingTimeout?.cancel()
                self.openingTimeout = nil
                self.error =
                    error is TelegramProxyError
                    ? "Не удалось проверить сохранённый прокси. Откройте «Данные и память» и проверьте настройки."
                    : (error as? TelegramSetupError)?.localizedDescription ?? TelegramSetupError.filesystem.localizedDescription
                self.isBusy = false
                self.phase = .configuration
            }
        }
    }

    func startNativeConnection(
        configuration: TelegramAPIConfiguration, proxySettings: Signal<ProxySettings, NoError>,
        directory: URL, encryption: ValueBoxEncryptionParameters, token: UUID
    ) {
        TelegramRuntime.configureLogging(directory: directory)
        initializeAccountManagement()
        let arguments = TelegramRuntime.networkArguments(configuration: configuration, proxySettings: proxySettings)
        let auxiliary = TelegramRuntime.accountAuxiliaryMethods()
        session.set(
            (AccountManager<TelegramAccountManagerTypes>.makoshOpen(basePath: directory.appendingPathComponent("accounts-metadata").path)
                |> deliverOnMainQueue
                |> mapToSignal { [weak self] manager -> Signal<AccountResult?, NoError> in
                    guard let self, self.generation == token, let manager else { return .single(nil) }
                    self.manager = manager
                    return currentAccount(
                        allocateIfNotExists: true, networkArguments: arguments, supplementary: false,
                        manager: manager, rootPath: directory.path, auxiliaryMethods: auxiliary, encryptionParameters: encryption)
                }
                |> deliverOnMainQueue).start(next: { [weak self] result in
                    guard let self, self.generation == token else { return }
                    switch result {
                    case .unauthorized(let account): self.observeUnauthorized(account, token: token)
                    case .authorized(let account): self.observeAuthorized(account, token: token)
                    case .upgrading: self.connectionDescription = "Открытие или обновление локального кэша"
                    case nil:
                        self.disconnect()
                        self.phase = .unsupported(
                            "Не удалось получить состояние отдельного сеанса. Соединение остановлено; локальные данные сохранены.")
                    }
                }))
    }

    public func beginQRLogin() {
        #if DEBUG
        let synthetic = isSyntheticPreview
        #else
        let synthetic = false
        #endif
        guard !isBusy, phase == .phone, unauthorized != nil || synthetic else { return }
        qrMigrationCount = 0
        error = nil
        qrLogin.start()
    }

    public func cancelQRLogin() { qrLogin.cancel() }

    public func submitPhone(_ phone: String) {
        guard !isBusy, phase == .phone, !qrLogin.isActive, let configuration, let manager, let unauthorized else { return }
        let number = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard number.hasPrefix("+"), (8...16).contains(number.count), number.dropFirst().utf8.allSatisfy({ (48...57).contains($0) }) else {
            error = "Введите номер в международном формате: + и цифры без пробелов."
            return
        }
        isBusy = true
        error = nil
        let token = generation
        let authToken = authorizationGeneration
        action.set(
            (sendAuthorizationCode(
                accountManager: manager, account: unauthorized, phoneNumber: number,
                apiId: configuration.id, apiHash: configuration.hash, pushNotificationConfiguration: nil,
                firebaseSecretStream: .single([:]), syncContacts: false, disableAuthTokens: true,
                forcedPasswordSetupNotice: TelegramRuntime.forcedPasswordSetupNotice)
                |> timeout(30, queue: .mainQueue(), alternate: .fail(.timeout))
                |> deliverOnMainQueue).start(
                    next: { [weak self] result in
                        guard let self, self.generation == token, self.authorizationGeneration == authToken else { return }
                        self.isBusy = false
                        if case let .sentCode(account) = result { self.observeUnauthorized(account, token: token) }
                    },
                    error: { [weak self] failure in
                        guard let self, self.generation == token, self.authorizationGeneration == authToken else { return }
                        self.isBusy = false
                        switch failure {
                        case .invalidPhoneNumber: self.error = "Telegram не принял номер телефона."
                        case .limitExceeded, .phoneLimitExceeded: self.error = "Telegram ограничил попытки. Подождите перед новым запросом."
                        case .phoneBanned: self.error = "Этот номер заблокирован Telegram."
                        case .timeout: self.error = "Нет ответа Telegram. Код мог быть запрошен; не повторяйте запрос сразу."
                        case .appOutdated: self.error = "Telegram требует обновлённый способ входа. Эта версия ядра его не поддерживает."
                        case .generic:
                            self.error =
                                "Telegram не завершил запрос кода. Проверьте соединение. Если ошибка повторяется, сообщите о проблеме этой сборки."
                        }
                    }))
    }

    public func submitCode(_ code: String) {
        guard !isBusy, phase == .code, !code.isEmpty, let manager, let unauthorized,
            let authorizationCode = challenge.authorizationCode(code)
        else { return }
        isBusy = true
        error = nil
        let token = generation
        let authToken = authorizationGeneration
        action.set(
            (authorizeWithCode(
                accountManager: manager, account: unauthorized, code: authorizationCode, termsOfService: nil,
                forcedPasswordSetupNotice: TelegramRuntime.forcedPasswordSetupNotice)
                |> timeout(30, queue: .mainQueue(), alternate: .fail(.generic))
                |> deliverOnMainQueue).start(
                    next: { [weak self] result in
                        guard let self, self.generation == token, self.authorizationGeneration == authToken else { return }
                        self.isBusy = false
                        if case .signUp = result {
                            self.phase = .unsupported(
                                "Создание нового аккаунта здесь не реализовано. Используйте уже зарегистрированный аккаунт.")
                        }
                    },
                    error: { [weak self] _ in
                        guard let self, self.generation == token, self.authorizationGeneration == authToken else { return }
                        self.isBusy = false
                        self.error =
                            "Telegram не завершил проверку кода. Проверьте код, сеть и текущее состояние входа перед повторной попыткой."
                    }))
    }

    public func submitPassword(_ password: String) {
        guard !isBusy, case .password = phase, !password.isEmpty, let manager, let unauthorized else { return }
        isBusy = true
        error = nil
        let token = generation
        let authToken = authorizationGeneration
        action.set(
            (authorizeWithPassword(accountManager: manager, account: unauthorized, password: password, syncContacts: false)
                |> timeout(30, queue: .mainQueue(), alternate: .fail(.generic))
                |> deliverOnMainQueue).start(
                    error: { [weak self] _ in
                        guard let self, self.generation == token, self.authorizationGeneration == authToken else { return }
                        self.isBusy = false
                        self.error = "Telegram не завершил проверку пароля. Проверьте пароль, сеть и ограничения попыток."
                    },
                    completed: { [weak self] in
                        guard let self, self.generation == token, self.authorizationGeneration == authToken else { return }
                        self.isBusy = false
                    }))
    }

    /// Reconnects the local session at launch when the user left it connected.
    public func connectIfRemembered() {
        guard !isSyntheticPreview, autoConnect.remembered("telegram").contains("session") else { return }
        connect()
    }

    /// The user's explicit stop: the session stays, but it no longer reconnects at launch.
    public func stopConnection() {
        autoConnect.forget("telegram", account: "session")
        disconnect()
    }

    public func disconnect() {
        unauthorized?.shouldBeServiceTaskMaster.set(.single(.never))
        proxy.unregister(clientID: proxyClientID)
        proxyClientID = UUID()
        sessionOpeningTask?.cancel()
        sessionOpeningTask = nil
        #if DEBUG
        preview = nil
        #endif
        generation = UUID()
        openingTimeout?.cancel()
        openingTimeout = nil
        stopAuthorizedAccount()
        for disposable in [session, authState, action, chatList, history, connection, outgoing] { disposable.set(nil) }
        selectedChatID = nil
        qrLogin.bind(nil)
        account = nil
        unauthorized = nil
        manager = nil
        configuration = nil
        chats = []
        messages = []
        draft = ""
        isBusy = false
        phase = .configuration
        error = nil
        connectionDescription = "Подключение остановлено; локальный сеанс сохранён"
    }

    func registerProxy(network: Network) {
        proxy.register(
            TelegramEngineProxyTarget(network: network) { [weak self] in
                self?.disconnect()
                self?.error = "Соединение остановлено: результат изменения прокси не подтверждён. Проверьте «Данные и память»."
            }, clientID: proxyClientID)
    }

    func observeUnauthorized(_ account: UnauthorizedAccount, token: UUID, continuingQR: Bool = false) {
        openingTimeout?.cancel()
        openingTimeout = nil
        stopAuthorizedAccount()
        if unauthorized !== account { unauthorized?.shouldBeServiceTaskMaster.set(.single(.never)) }
        authorizationGeneration = UUID()
        let authToken = authorizationGeneration
        self.unauthorized = account
        self.account = nil
        registerProxy(network: account.network)
        guard self.unauthorized === account else { return }
        account.shouldBeServiceTaskMaster.set(.single(.now))
        self.isBusy = false
        self.connectionDescription = "Вход в отдельный сеанс Макоша"
        if let manager {
            qrLogin.bind(
                TelegramEngineQRLoginProvider(
                    account: account, manager: manager,
                    replace: { [weak self] next, retry in
                        guard let self, self.generation == token, self.unauthorized === account else { return }
                        if retry {
                            self.qrMigrationCount += 1
                            guard self.qrMigrationCount <= 3 else {
                                self.qrLogin.cancel()
                                self.error = "Не удалось завершить переход QR-входа. Повторите вход."
                                return
                            }
                        }
                        self.observeUnauthorized(next, token: token, continuingQR: retry)
                    }))
            if continuingQR { qrLogin.start() }
        } else {
            qrLogin.bind(nil)
        }
        authState.set(
            (account.postbox.stateView() |> deliverOnMainQueue).start(next: { [weak self] view in
                guard let self, self.generation == token, self.authorizationGeneration == authToken else { return }
                self.applyUnauthorizedState(view.state)
            }))
    }

    func applyUnauthorizedState(_ observedState: PostboxCoding?) {
        // A newly opened native Postbox has no account state yet. Present the
        // existing phone form without persisting or replacing protocol state.
        if observedState == nil {
            self.phase = .phone
            return
        }
        guard let state = observedState as? UnauthorizedAccountState else { return }
        switch state.contents {
        case .empty, .phoneEntry: self.phase = .phone
        case let .confirmationCodeEntry(_, type, _, _, _, _, _, _):
            self.challenge = TelegramAuthorizationChallenge(type: type)
            self.codeExplanation = self.challenge.explanation
            self.phase = self.challenge.phase
        case .passwordEntry(let hint, _, _, _, _):
            self.qrLogin.cancel()
            self.phase = .password(hint: hint)
        case .signUp: self.phase = .unsupported("Регистрация нового аккаунта не реализована.")
        case .passwordRecovery, .awaitingAccountReset:
            self.phase = .unsupported("Восстановление и сброс аккаунта выполняйте в официальном клиенте Telegram.")
        case .payment: self.phase = .unsupported("Telegram запросил платный способ входа. Макош не выполняет оплату.")
        }
    }

    func observeAuthorized(_ account: Account, token: UUID) {
        openingTimeout?.cancel()
        openingTimeout = nil
        guard self.account !== account else { return }
        stopAuthorizedAccount()
        unauthorized?.shouldBeServiceTaskMaster.set(.single(.never))
        authorizationGeneration = UUID()
        action.set(nil)
        qrLogin.bind(nil)
        self.unauthorized = nil
        self.account = account
        bindWorkspaceFolders(account)
        registerProxy(network: account.network)
        // Queue TelegramCore's initial getState/getDifference before providers
        // can submit update groups. A newly authorized cache has no cursor yet.
        account.resetStateManagement()
        sendApproval.bind(account: account)
        customEmojiPlaybackContext = TelegramCustomEmojiPlaybackContext(account: account)
        customEmojiCatalog.bind(account: account)
        refreshConversationCapabilities()
        bindMessageSelectionRangeProvider(
            TelegramPostboxSelectionRangeProvider(postbox: account.postbox, accountID: account.peerId.toInt64()))
        let replyProvider = TelegramPostboxComposerReplyProvider(postbox: account.postbox, accountID: account.peerId.toInt64())
        composerReply.bind(replyProvider)
        composerForward.bind(TelegramEngineForwardProvider(account: account, approval: sendApproval))
        let recovery = TelegramPendingUploadSession(
            repository: TelegramPostboxPendingUploadRepository(postbox: account.postbox, accountID: account.peerId.toInt64()),
            files: { [weak self] in
                guard let self else { throw TelegramUploadFileError.unavailable }
                return try self.archive.files.pendingUploadFiles()
            })
        pendingRecoveryStore = recovery
        pendingReplyProvider = replyProvider
        refreshComposerReply()
        bindComposerDraftRepository(TelegramPostboxComposerDraftRepository(postbox: account.postbox, accountID: account.peerId.toInt64()))
        bindServerDraftObserver(TelegramPostboxServerDraftObserver(postbox: account.postbox, accountID: account.peerId.toInt64()))
        // Installs TelegramCore's built-in cloud/secret resource fetcher on this
        // account's MediaBox. Auxiliary nil alone does not install the fallback.
        setupAccount(account)
        autoDownloadSettings.bind(accountID: account.peerId.toInt64())
        cache.bind(TelegramEngineCacheProvider(account: account))
        cacheMaintenance.bind(provider: TelegramEngineCacheProvider(account: account))
        avatars.bind(TelegramEngineAvatarProvider(account: account))
        peerStatus.bind(account: account)
        forumTopics.bind(account: account)
        forumTopics.selectChat(selectedChatID)
        profilePhotos.bind(TelegramEngineProfilePhotoProvider(account: account))
        avatarEditing.bind(TelegramEngineAvatarEditingProvider(account: account))
        groupMembership.bind(TelegramEngineGroupMembershipProvider(account: account))
        secretChats.bind(TelegramEngineSecretChatProvider(account: account))
        let callProxy = proxy
        calls.bind(
            TelegramEngineCallProvider(
                engine: TelegramAccountCallEngine(account: account), proxy: { try await callProxy.currentCallProxy() },
                media: TelegramNativeCallMediaFactory(),
                audioSelection: { try .decode(UserDefaults.standard.string(forKey: TelegramCallAudioSelection.preferenceKey) ?? "") }))
        callSelectionAccount = nil
        callSelectionPeer = nil
        refreshCallSelection()
        groupMemberSearch.bind(TelegramEngineRemotePeerProvider(account: account))
        peerManagement.bind(TelegramEnginePeerManagementProvider(account: account))
        accountSessions.bind(TelegramEngineSessionsProvider(account: account))
        webSessions.bind(TelegramEngineWebSessionsProvider(account: account))
        appearanceCatalog.bind(TelegramEngineAppearanceCatalogProvider(account: account))
        accountPrivacy.bind(TelegramEnginePrivacyProvider(account: account))
        accountBlockedUsers.bind(TelegramEngineBlockedUsersProvider(account: account))
        contactsProviderValue = TelegramEngineContactsProvider(account: account)
        accountTwoStep.bind(TelegramEngineTwoStepProvider(account: account))
        notifications.bind(account: account)
        archive.bind(journal: TelegramEngineArchiveJournal(account: account))
        let mediaProvider = TelegramEngineMediaProvider(account: account)
        self.mediaProvider = mediaProvider
        media.bind(provider: mediaProvider)
        let downloadAccountID = account.peerId.toInt64()
        backgroundDownloads = TelegramEngineDownloadJournal(
            postbox: account.postbox, accountID: downloadAccountID, media: media, provider: mediaProvider,
            reserveFile: { [files = archive.files] record, attachment in
                let identity = MessageArchiveIdentity(
                    service: "telegram", accountID: String(downloadAccountID), conversationID: String(record.peerID),
                    messageID: "\(record.namespace):\(record.messageID)")
                let descriptor = MessageArchiveAttachment(
                    id: attachment.id, kind: attachment.kind == .photo ? "photo" : "file", name: attachment.name, size: attachment.byteCount
                )
                return files.reserveManualDownload(identity: identity, attachment: descriptor)
            },
            completedFile: { [files = archive.files] record, attachment, url, size in
                let identity = MessageArchiveIdentity(
                    service: "telegram", accountID: String(downloadAccountID), conversationID: String(record.peerID),
                    messageID: "\(record.namespace):\(record.messageID)")
                let descriptor = MessageArchiveAttachment(
                    id: attachment.id, kind: attachment.kind == .photo ? "photo" : "file", name: attachment.name, size: attachment.byteCount
                )
                files.accept(file: url, byteCount: size, identity: identity, attachment: descriptor)
            })
        upload.bind(
            provider: TelegramEngineUploadProvider(account: account, approval: sendApproval), recoveryStore: recovery,
            requiresRecovery: true)
        restorePendingUpload()
        messageActions.bind(provider: TelegramEngineMessageActionsProvider(account: account, approval: sendApproval))
        selectedMessagesCopy.bind(
            provider: TelegramPostboxSelectedMessagesCopyProvider(postbox: account.postbox, accountID: account.peerId.toInt64()))
        selectedMessagesDelete.bind(provider: TelegramEngineSelectedMessagesDeleteProvider(account: account))
        savedMessagesForward.bind(TelegramEngineSavedMessagesForwardProvider(account: account, approval: sendApproval))
        historyRead.bind(TelegramEngineHistoryReadProvider(account: account))
        search.bind(account: account)
        globalSearch.bind(account: account)
        sharedMedia.bind(account: account)
        search.setFolder(chatFolder)
        let accountToken = accountGeneration
        uploadCaptionLimit.set(
            (telegramUploadCaptionLimit(postbox: account.postbox, accountID: account.peerId.toInt64())
                |> deliverOnMainQueue).start(next: { [weak self] limit in
                    guard let self, self.generation == token, self.accountGeneration == accountToken else { return }
                    self.uploadCaptionMaximumUTF16Count = limit
                }))
        replyQuoteLimitObservation.set(
            (telegramReplyQuoteLimitSignal(postbox: account.postbox)
                |> deliverOnMainQueue).start(next: { [weak self] limit in
                    guard let self, self.generation == token, self.accountGeneration == accountToken else { return }
                    self.replyQuoteMaximumUTF16Count = limit
                }))
        self.authState.set(nil)
        self.isBusy = false
        self.phase = .ready
        self.autoConnect.remember("telegram", account: "session")
        self.refreshCallSelection()
        account.shouldBeServiceTaskMaster.set(.single(.always))
        account.shouldKeepOnlinePresence.set(.single(false))
        account.network.shouldKeepConnection.set(.single(true))
        connection.set(
            (account.networkState |> deliverOnMainQueue).start(next: { [weak self] state in
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

    func stopAuthorizedAccount() {
        bindWorkspaceFolders(nil)
        automaticDownloads.setPaused(false)
        automaticDownloadsPaused = false
        cancelAutomaticDownloads()
        autoDownloadSettings.bind(accountID: nil)
        cache.bind(nil)
        cacheMaintenance.bind(provider: nil)
        notifications.bind(accountID: nil)
        sendApproval.dispose()
        capabilityObservation.set(nil)
        conversationCapabilities = nil
        pendingEmojiInsertion = nil
        customEmojiInsertion = nil
        customEmojiCatalog.bind(account: nil)
        customEmojiPlaybackContext?.invalidate()
        customEmojiPlaybackContext = nil
        customEmojiDescriptors = [:]
        emojiResolutionID = UUID()
        emojiRequested = []
        emojiResolution.set(nil)
        bindServerDraftObserver(nil)
        forumTopics.bind(account: nil)
        uploadCaptionLimit.set(nil)
        uploadCaptionMaximumUTF16Count = 1024
        replyQuoteLimitObservation.set(nil)
        replyQuoteMaximumUTF16Count = 1024
        cancelVoiceRecording()
        bindMessageSelectionRangeProvider(nil)
        cancelContactProfile()
        avatars.bind(nil)
        peerStatus.bind(account: nil)
        profilePhotos.bind(nil)
        avatarEditing.bind(nil)
        peerManagement.bind(nil)
        groupMembership.bind(nil)
        groupMemberSearch.bind(nil)
        calls.bind(nil)
        callSelectionAccount = nil
        callSelectionPeer = nil
        secretChats.bind(nil)
        appearanceCatalog.bind(nil)
        webSessions.bind(nil)
        accountSessions.bind(nil)
        accountPrivacy.bind(nil)
        accountBlockedUsers.bind(nil)
        accountTwoStep.bind(nil)
        historyRead.bind(nil)
        historyReadIndexes = [:]
        archive.bind(journal: nil)
        playback.stop()
        bindPendingUploadRecovery(nil, replyProvider: nil)
        upload.bind(provider: nil)
        uploadComposerPreparationID = nil
        uploadComposerTransfer = nil
        uploadComposerSubmission = nil
        messageActions.bind(provider: nil)
        selectedMessagesCopy.bind(provider: nil)
        selectedMessagesDelete.bind(provider: nil)
        savedMessagesForward.bind(nil)
        savedForwardSelection = nil
        selectedDeleteEditSession = nil
        composerReply.bind(nil)
        composerForward.bind(nil)
        messageSelection.cancel()
        pendingForwardStage = nil
        mediaProvider = nil
        historyMediaSources = []
        media.bind(provider: nil)
        backgroundDownloads = nil
        search.bind(account: nil)
        globalSearch.bind(account: nil)
        sharedMedia.bind(account: nil)
        accountGeneration = UUID()
        conversationGeneration = UUID()
        messageEditSessions = [:]
        messageEditSession = nil
        submittedEditSession = nil
        editDrafts = [:]
        account?.shouldBeServiceTaskMaster.set(.single(.never))
        account?.shouldKeepOnlinePresence.set(.single(false))
        account?.network.shouldKeepConnection.set(.single(false))
        for disposable in [chatList, history, connection, outgoing] { disposable.set(nil) }
        chatPageTimeout?.cancel()
        chatPageTimeout = nil
        historyPageTimeout?.cancel()
        historyPageTimeout = nil
        chatPages.reset()
        historyPages.reset()
        chatPage = .idle
        historyPage = .idle
        selectedChatID = nil
        bindComposerDraftRepository(nil)
        replyComposerSubmission = nil
        uploadComposerSubmission = nil
        account = nil
        knownChats = [:]
        chats = []
        messages = []
        draft = ""
        refreshMediaSources()
    }
}
