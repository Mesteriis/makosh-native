import SwiftUI
import AppKit
import MakoshTelegram

struct TelegramDetailView: View {
    @AppStorage(TelegramLocalTheme.preferenceKey) private var telegramTheme = TelegramLocalTheme.system.rawValue
    @ObservedObject var model: TelegramModel
    @ObservedObject private var search: TelegramSearchModel
    @ObservedObject private var media: TelegramMediaController
    @ObservedObject private var upload: TelegramUploadController
    @ObservedObject private var playback: TelegramPlaybackController
    @ObservedObject private var messageActions: TelegramMessageActionsController
    @ObservedObject private var peerStatus: TelegramPeerStatusController
    @ObservedObject private var messageSelection: TelegramMessageSelectionController
    @ObservedObject private var selectedDelete: TelegramSelectedMessagesDeleteController
    @ObservedObject private var forumTopics: TelegramForumTopicsController
    @ObservedObject private var sendApproval: TelegramSendApprovalController
    @State private var displayedApprovalID: UUID?
    @State private var secretVerificationPresented = false
    @State private var secretTimerPresented = false
    @StateObject private var attachmentActions = TelegramAttachmentActions()
    @State private var messageActionRequest: TelegramMessageActionRequest?
    @State private var profilePresented = false
    @State private var messageSearchPresented = false
    @State private var messageSearchFocusRequest = UUID()
    private let dossier: WorkspaceModel?
    private let openDossier: (UUID) -> Void
    init(model: TelegramModel, dossier: WorkspaceModel? = nil, openDossier: @escaping (UUID) -> Void = { _ in }) {
        self.model = model; self.search = model.search; self.media = model.media; self.upload = model.upload
        self.playback = model.playback; self.messageActions = model.messageActions
        self.peerStatus = model.peerStatus
        self.messageSelection = model.messageSelection
        self.selectedDelete = model.selectedMessagesDelete
        self.forumTopics = model.forumTopics; self.sendApproval = model.sendApproval
        self.dossier = dossier; self.openDossier = openDossier
    }
    @State private var apiID = ""
    @State private var apiHash = ""
    @State private var phone = ""
    @State private var code = ""
    @State private var password = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.phase {
            case .configuration: setup
            case .connecting:
                VStack(spacing: 16) { ProgressView(); Text("Подключение к Telegram…"); Text(model.connectionDescription).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .phone: phoneForm
            case .code: codeForm
            case .password(let hint): passwordForm(hint: hint)
            case .ready: conversation
            case .unsupported(let explanation):
                ContentUnavailableView("Нужен дополнительный шаг входа", systemImage: "person.crop.circle.badge.exclamationmark", description: Text(explanation)).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            #if DEBUG
            if model.isSyntheticPreview && model.calls.accountID == 101 {
                HStack {
                    Button("Синтетический входящий звонок") { model.syntheticIncomingCall(video: false) }.accessibilityIdentifier("telegram.call.qa.incomingAudio")
                    Button("Синтетический входящий видеозвонок") { model.syntheticIncomingCall(video: true) }.accessibilityIdentifier("telegram.call.qa.incomingVideo")
                }.font(.caption).padding(6)
            }
            #endif
            TelegramPlaybackView(playback: playback)
            TelegramUploadView(model: model)
            TelegramMessageActionsStatus(controller: messageActions, synthetic: model.isSyntheticPreview)
            TelegramSavedMessagesForwardStatus(controller: model.savedMessagesForward, synthetic: model.isSyntheticPreview)
            if let error = model.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle"); Text(error).textSelection(.enabled)
                    if model.canRetryComposerDraftPersistence {
                        Button("Повторить сохранение", action: model.retryComposerDraftPersistence)
                            .accessibilityIdentifier("telegram.draft.retry")
                    }
                    Spacer(); Button { model.error = nil } label: { Image(systemName: "xmark") }.help("Закрыть сообщение")
                }
                    .font(.callout).padding(16).background(.red.opacity(0.08)).accessibilityIdentifier("telegram.error")
            }
            if attachmentActions.isBusy {
                HStack { ProgressView().controlSize(.small); Text("Обработка вложения…"); Spacer(); Button("Отменить", action: attachmentActions.cancel) }
                    .font(.callout).padding(12).accessibilityIdentifier("telegram.media.processing")
            }
            if let error = attachmentActions.error {
                HStack { Text(error); Spacer(); Button("Закрыть") { attachmentActions.error = nil } }
                    .font(.callout).padding(12).background(.red.opacity(0.08)).accessibilityIdentifier("telegram.media.error")
            }
            if attachmentActions.saved {
                Text("Вложение сохранено в выбранный файл.").font(.caption).foregroundStyle(.secondary).padding(12)
                    .accessibilityIdentifier("telegram.media.saved")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(TelegramLocalTheme(preference: telegramTheme).chatBackground)
            .modifier(TelegramUploadDropModifier(model: model))
            .overlay {
                TelegramRoundVideoRecorderView(recording: model.voiceRecording, upload: upload,
                    selectedChatID: model.selectedChatID, synthetic: model.isSyntheticPreview)
                    .allowsHitTesting(false)
            }
            .onChange(of: model.selectedChatID) { _, _ in
                attachmentActions.cancel(); profilePresented = false
                closeMessageSearch()
            }
            .onChange(of: model.messageActionContextID) { _, _ in secretVerificationPresented = false; secretTimerPresented = false; messageActionRequest = nil; profilePresented = false; closeMessageSearch() }
            .onChange(of: model.phase) { _, _ in attachmentActions.cancel() }
            .onChange(of: model.historyWindowID) { _, _ in attachmentActions.cancel() }
            .onChange(of: search.messageQuery) { _, _ in
                attachmentActions.cancel(); playback.stop()
                if search.hasMessageQuery { closeMessageSelection(); messageSearchPresented = true }
            }
            .onAppear { peerStatus.setVisible(true) }
            .onDisappear {
                model.cancelVoiceRecording()
                attachmentActions.cancel(); model.cancelMediaLoads()
                profilePresented = false; model.cancelContactProfile()
                peerStatus.setVisible(false)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in model.cancelVoiceRecording() }
            .onReceive(model.notifications.$activationRequest.dropFirst()) { _ in
                profilePresented = false; secretVerificationPresented = false; closeMessageSearch()
            }
            .sheet(item: Binding(get: { sendApproval.pendingPrompt }, set: { value in
                if value == nil, let id = displayedApprovalID { sendApproval.cancel(promptID: id) }
            })) { prompt in
                TelegramPaidSendApprovalView(controller: sendApproval)
                    .onAppear { displayedApprovalID = prompt.id }
                    .onDisappear { sendApproval.cancel(promptID: prompt.id) }
            }
            .sheet(isPresented: $secretVerificationPresented) {
                if let secret = model.conversationCapabilities?.secret {
                    TelegramSecretVerificationView(secret: secret)
                }
            }
            .sheet(item: $messageActionRequest) { request in TelegramMessageActionSheet(model: model, request: request) }
            .sheet(isPresented: $secretTimerPresented) {
                TelegramSecretTimerView(controller: model.secretChats, synthetic: model.isSyntheticPreview)
            }
            .sheet(isPresented: $profilePresented, onDismiss: model.cancelContactProfile) {
                TelegramContactProfileView(model: model, dossier: dossier,
                    contextID: model.contactProfileContextID, openDossier: openDossier)
            }
            .sheet(isPresented: Binding(get: { attachmentActions.preview != nil }, set: { if !$0 { attachmentActions.preview = nil } })) {
                VStack(spacing: 16) {
                    if let preview = attachmentActions.preview {
                        Image(decorative: preview.image, scale: 1).resizable().scaledToFit()
                            .frame(maxWidth: 900, maxHeight: 650).accessibilityIdentifier("telegram.media.previewImage")
                    }
                    Button("Закрыть предпросмотр") { attachmentActions.preview = nil }
                        .keyboardShortcut(.cancelAction).accessibilityIdentifier("telegram.media.closePreview")
                }.padding(24).frame(minWidth: 440, minHeight: 280)
            }
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Telegram в Макош", systemImage: "paperplane").font(.largeTitle.weight(.semibold))
            Text("Неофициальный клиент на основе TelegramCore").font(.title3)
            Text("Используйте собственные API ID и API hash. Макош создаёт отдельный локальный сеанс и не читает данные установленного Telegram. Подключение начнётся только после нажатия кнопки.").foregroundStyle(.secondary)
            Button("Подключить с локальными API-данными") { model.connectUsingSavedAPIConfiguration() }
                .buttonStyle(.borderedProminent).disabled(model.isBusy).accessibilityIdentifier("telegram.connect.saved")
            Text("Использует сохранённый локальный файл telegram-api.json. Значения не отображаются.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Link("Получить API ID и API hash", destination: URL(string: "https://my.telegram.org/apps")!)
            TextField("API ID", text: $apiID).textFieldStyle(.roundedBorder).accessibilityIdentifier("telegram.apiID")
            SecureField("API hash", text: $apiHash).textFieldStyle(.roundedBorder).accessibilityIdentifier("telegram.apiHash")
            Button("Подключить Telegram") {
                model.connect(apiID: apiID, apiHash: apiHash)
                apiHash = ""
            }.buttonStyle(.borderedProminent).disabled(model.isBusy || apiID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiHash.isEmpty).accessibilityIdentifier("telegram.connect")
            Text("Можно использовать локальные API-данные или вводить их вручную. Остановка подключения сохраняет локальный кэш и не выполняет удалённый выход из аккаунта.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(32).frame(maxWidth: 650, alignment: .leading).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var phoneForm: some View {
        authForm(title: "Ваш номер телефона", detail: "Введите номер с кодом страны. Код входа отправит Telegram.") {
            TextField("+34 …", text: $phone).textFieldStyle(.roundedBorder).accessibilityIdentifier("telegram.phone")
            Button("Запросить код") { model.submitPhone(phone) }.buttonStyle(.borderedProminent).disabled(model.isBusy || phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("telegram.phone.submit")
        }
    }
    private var codeForm: some View {
        authForm(title: "Код входа", detail: model.codeExplanation) {
            SecureField("Код", text: $code).textFieldStyle(.roundedBorder).accessibilityIdentifier("telegram.code")
            Button("Продолжить") { model.submitCode(code); code = "" }.buttonStyle(.borderedProminent).disabled(model.isBusy || code.isEmpty).accessibilityIdentifier("telegram.code.submit")
        }
    }
    private func passwordForm(hint: String) -> some View {
        authForm(title: "Двухэтапная проверка", detail: hint.isEmpty ? "Введите облачный пароль Telegram." : "Подсказка Telegram: \(hint)") {
            SecureField("Пароль", text: $password).textFieldStyle(.roundedBorder).accessibilityIdentifier("telegram.password")
            Button("Войти") { model.submitPassword(password); password = "" }.buttonStyle(.borderedProminent).disabled(model.isBusy || password.isEmpty).accessibilityIdentifier("telegram.password.submit")
        }
    }
    private func authForm<Content: View>(title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 20) { Text(title).font(.title.bold()); Text(detail).foregroundStyle(.secondary); content(); if model.isBusy { ProgressView().controlSize(.small) }; Spacer() }
            .padding(32).frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    @ViewBuilder private var conversation: some View {
        if let chat = model.selectedChat {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button {
                        model.loadContactProfile(); profilePresented = true
                    } label: {
                        HStack(spacing: 10) {
                            TelegramChatAvatar(title: chat.title, peerID: chat.id, store: model.avatars, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.selectedForumTopic?.title ?? model.selectedThreadID.map { "Тема \($0)" } ?? chat.title).font(.headline).lineLimit(1)
                                if model.selectedThreadID != nil { Text(chat.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                if let status = peerStatus.status, status.peerID == chat.id, !status.isSelf {
                                    TelegramPeerStatusView(status: status, identifier: "telegram.peerStatus.header")
                                }
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Открыть карточку собеседника")
                        .accessibilityIdentifier("telegram.profile.open")
                    Spacer()
                    if forumTopics.snapshot?.chatID == chat.id {
                        Button { model.isForumTopicsListPresented = true } label: { Image(systemName: "list.bullet") }
                            .buttonStyle(.plain).help("Открыть темы").accessibilityLabel("Открыть темы")
                            .accessibilityIdentifier("telegram.forum.open")
                    }
                    TelegramCallButtons(controller: model.calls, hasTarget: model.callPeerID != nil)
                    TelegramConversationFilePolicyMenu(files: model.archive.files, chatID: chat.id)
                    Button {
                        if messageSearchPresented { closeMessageSearch() }
                        else { openMessageSearch() }
                    } label: {
                        Image(systemName: "magnifyingglass").frame(width: 28, height: 28)
                    }.buttonStyle(.plain).foregroundStyle(messageSearchPresented ? Color.accentColor : Color.secondary)
                        .help("Поиск сообщений (⌘F)").accessibilityLabel("Поиск сообщений в диалоге")
                        .accessibilityIdentifier("telegram.messageSearch.toggle")
                }.padding(.horizontal, 16).frame(height: 50)
                if let capabilities = model.conversationCapabilities {
                    TelegramConversationCapabilityBanner(capabilities: capabilities) { secretVerificationPresented = true }
                    if capabilities.secret != nil {
                        if model.composerSecretSession?.canSetTTL == true && !model.secretComposerFormattingSupported {
                            Text("Это форматирование не поддерживается протоколом данного секретного чата.")
                                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                                .accessibilityIdentifier("telegram.secret.formattingUnsupported")
                        }
                        HStack {
                            Button("Таймер сообщений") { secretTimerPresented = true }
                                .accessibilityIdentifier("telegram.secret.timer.open")
                            Spacer()
                        }.font(.caption).padding(.horizontal, 12).padding(.bottom, 8)
                    }
                }
                Divider()
                if messageSearchPresented {
                    TelegramMessageSearchHeader(search: search, initialDate: model.messages.last?.date ?? Date(), focusRequest: messageSearchFocusRequest, close: closeMessageSearch)
                    Divider()
                }
                if search.hasMessageQuery && search.showsResults {
                    messageSearchResults
                } else {
                    TelegramPaginationBar(page: model.historyPage, prefix: "telegram.historyPage",
                        previous: model.loadOlderMessages, next: model.loadNewerMessages,
                        latest: model.showLatestMessages, retry: model.retryHistoryPage).padding(12)
                    if model.messages.isEmpty {
                        if model.historyPage.isLoading {
                            ProgressView("Загрузка истории…").frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ContentUnavailableView("Нет загруженных сообщений", systemImage: "text.bubble", description: Text(model.historyPage.timedOut ? "Telegram пока не завершил загрузку. Можно повторить запрос этой страницы." : "В этом окне истории пока нет сообщений.")).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                // The engine supplies a bounded 50-message window. Eager
                                // layout keeps quote heights and AX scrolling consistent.
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(model.historyItems) { historyItem in
                                        if historyItem.isAlbum {
                                            TelegramAlbumHistoryRow(item: historyItem, model: model, selection: messageSelection,
                                                media: media, actions: attachmentActions, playback: playback,
                                                nativeActions: nativeMessageActions, quoteSelection: { message, quote, context in
                                                    _ = model.beginReply(to: message, contextID: context, quote: quote)
                                                }) { message in
                                                messageActionItems(message)
                                            }
                                        } else if let item = historyItem.messages.first {
                                        let contextID = model.messageActionContextID
                                        let windowID = model.historyWindowID
                                        let selectionID = messageSelection.session?.id
                                        TelegramSelectableHistoryRow(selection: messageSelection, message: item, source: model.actionSource(for: item)) {
                                            if let windowID, let selectionID {
                                                _ = model.toggleMessageSelection(messageID: item.id, sessionID: selectionID,
                                                    contextID: contextID, windowID: windowID,
                                                    extendingRange: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
                                            }
                                        } content: {
                                        HStack(alignment: .top) {
                                            if item.isOutgoing { Spacer(minLength: 44) }
                                            Grid(alignment: .leading, verticalSpacing: 7) {
                                                GridRow {
                                                    Text(item.author).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                                }
                                                if item.captionAboveMedia, !item.text.isEmpty {
                                                    GridRow { messageCaption(item) }
                                                }
                                                ForEach(item.attachments) { attachment in
                                                    GridRow {
                                                        TelegramAttachmentRow(attachment: attachment, contextID: model.messageActionContextID,
                                                            hasCaption: !item.text.isEmpty, media: media, actions: attachmentActions, playback: playback) {
                                                                messageActionItems(item)
                                                            }
                                                    }
                                                }
                                                if !item.captionAboveMedia, !item.text.isEmpty {
                                                    GridRow { messageCaption(item) }
                                                }
                                                GridRow {
                                                    TelegramMessageMetadataView(message: item)
                                                        .gridCellAnchor(.trailing)
                                                }
                                            }.padding(11).background(item.isOutgoing ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                            if !item.isOutgoing { Spacer(minLength: 44) }
                                        }.accessibilityElement(children: .contain)
                                            .accessibilityIdentifier("telegram.message.\(item.id)")
                                            .contextMenu { messageActionItems(item) }
                                            .background(TelegramHistoryReadRow(id: item.id, context: model.historyReadContext))
                                        }.id(item.id)
                                        }
                                    }
                                }.padding(.horizontal, 16).padding(.vertical, 12)
                            }.id(model.historyWindowID).defaultScrollAnchor(model.historyPage.isAtLatest ? .bottom : .top)
                                .accessibilityIdentifier("telegram.messages")
                                .modifier(TelegramHistoryReadViewport(model: model, context: model.historyReadContext))
                                .onChange(of: model.readyHistoryFocusID, initial: true) { _, focusID in
                                    if let id = focusID {
                                        proxy.scrollTo(id, anchor: .center)
                                        model.clearHistoryFocus()
                                    }
                                }
                        }
                    }
                }
                Divider()
                if messageSelection.session != nil {
                    TelegramMessageSelectionPanel(model: model, copyCommand: selectedCopyCommand, forward: { session in
                        guard let source = session.sources.first else { return }
                        messageActionRequest = TelegramMessageActionRequest(source: source, author: "", contextID: session.contextID,
                            mode: .forward, selection: session)
                    }, delete: { session in
                        guard let source = session.sources.first else { return }
                        messageActionRequest = TelegramMessageActionRequest(source: source, author: "", contextID: session.contextID,
                            mode: .delete, selection: session)
                    })
                } else if let session = model.messageEditSession {
                    TelegramInlineEditView(model: model, session: session)
                        .id(session.id)
                } else {
                    TelegramComposerView(model: model)
                }
                TelegramSelectedMessagesDeleteStatus(controller: selectedDelete, synthetic: model.isSyntheticPreview)
                if model.isSyntheticPreview {
                    Text("Синтетическая проверка: действия имитируются, отправки в Telegram нет.")
                        .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
                    #if DEBUG
                    Text("Чтение окна: \(model.syntheticHistoryReadWindowActive ? "активно" : "приостановлено"); локальных отметок: \(model.syntheticHistoryReadCount); граница: \(model.syntheticHistoryReadLastMessage.map(String.init) ?? "нет")")
                        .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
                        .accessibilityIdentifier("telegram.synthetic.historyRead")
                    #endif
                }
            }.focusedSceneValue(\.findTelegramMessage, openMessageSearch)
        } else {
            ContentUnavailableView("Выберите диалог", systemImage: "bubble.left.and.bubble.right", description: Text("Здесь будет история выбранного диалога Telegram.")).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedCopyCommand: (() -> Void)? {
        guard messageActionRequest == nil, !profilePresented, attachmentActions.preview == nil,
              let session = messageSelection.session else { return nil }
        return {
            // A native text selection or attached sheet keeps standard Copy behavior.
            if NSApp.keyWindow?.attachedSheet != nil {
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                return
            }
            if let text = NSApp.keyWindow?.firstResponder as? NSTextView,
               text.isEditable || text.selectedRange().length > 0 {
                text.copy(nil)
                return
            }
            _ = model.copySelectedMessages(sessionID: session.id, contextID: session.contextID, expectedRevision: session.revision) { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    private var messageSearchResults: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Найдено: \(search.totalMessages). Показано: \(search.messages.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 16).padding(.top, 12)
            if let reason = search.unavailableReason {
                Text(reason).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16)
            } else {
                TelegramSearchStatusView(status: search.messageStatus, retry: search.retryMessages).padding(.horizontal, 16)
            }
            if search.messages.isEmpty {
                ContentUnavailableView(search.messageStatus == .ready ? "Сообщения не найдены" : "Поиск сообщений", systemImage: "magnifyingglass", description: Text(search.messageStatus == .ready ? "Попробуйте другой запрос." : "Ожидаем результат запроса Telegram.")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(search.messages) { item in
                            HStack(alignment: .top, spacing: 16) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(item.author).font(.caption.weight(.semibold))
                                        Spacer()
                                        TelegramMessageMetadataView(message: item, includesDate: true)
                                    }
                                    if item.captionAboveMedia { messageCaption(item, lineLimit: 4) }
                                    ForEach(item.attachments) { attachment in
                                        TelegramAttachmentRow(attachment: attachment, contextID: model.messageActionContextID,
                                            hasCaption: !item.text.isEmpty, media: media, actions: attachmentActions, playback: playback) {
                                                messageActionItems(item)
                                            }
                                    }
                                    if !item.captionAboveMedia { messageCaption(item, lineLimit: 4) }
                                }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                                let context = search.resultContextID
                                Button("В истории") { model.openSearchMessage(id: item.id, contextID: context) }
                                    .buttonStyle(.bordered).controlSize(.small)
                                    .accessibilityIdentifier("telegram.searchResult.\(item.id)")
                            }.accessibilityElement(children: .contain)
                                .contextMenu { messageActionItems(item) }
                            Divider()
                        }
                    }.padding(16)
                }.accessibilityIdentifier("telegram.searchResults")
            }
            if search.canLoadMoreMessages {
                Button("Ещё результаты", action: search.loadMoreMessages).padding(.horizontal, 16).padding(.bottom, 12)
                    .accessibilityIdentifier("telegram.messageSearch.more")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func messageCaption(_ item: TelegramMessage, lineLimit: Int? = nil) -> some View {
        let context = model.messageActionContextID
        return TelegramMessageTextView(value: item.formattedTextForDisplay,
            identity: context.uuidString + item.id,
            canCopy: item.actionMetadata?.canCopy == true, lineLimit: lineLimit,
            nativeActions: nativeMessageActions(item), quoteSelection: { quote in
                _ = model.beginReply(to: item, contextID: context, quote: quote)
            }, maximumQuoteLength: model.conversationReplyQuoteMaximum,
            customEmojiDescriptors: model.customEmojiDescriptors,
            customEmojiContext: model.customEmojiPlaybackContext) {
                messageActionItems(item)
            }
    }

    private func openMessageSearch() {
        closeMessageSelection()
        messageSearchPresented = true
        messageSearchFocusRequest = UUID()
    }

    private func closeMessageSearch() {
        messageSearchPresented = false
        search.clearMessageSearch()
    }

    private func closeMessageSelection() {
        if let session = messageSelection.session {
            model.cancelMessageSelection(sessionID: session.id, contextID: session.contextID)
        }
    }

    @ViewBuilder private func messageActionItems(_ item: TelegramMessage) -> some View {
        if let source = model.actionSource(for: item) {
            let contextID = model.messageActionContextID
            let windowID = model.historyWindowID
            let disabled = model.isBusy || model.isRestoringComposerDraft || model.composerDraftRecoveryError != nil || model.isForwardComposerLocked || upload.phase != .idle || messageActions.isBusy || messageActions.phase == .uncertain
            TelegramMessageActionsItems(source: source, disabled: disabled) { mode in
                let request = TelegramMessageActionRequest(source: source, author: item.author, contextID: contextID, mode: mode)
                switch mode {
                case .reply:
                    _ = model.beginReply(to: item, contextID: request.contextID)
                case .edit:
                    _ = model.beginMessageEdit(source: source, author: item.author, contextID: request.contextID)
                case .forward, .delete: messageActionRequest = request
                }
            }
            Divider()
            Button("Выбрать", systemImage: "checkmark.circle") {
                if let windowID {
                    _ = model.beginMessageSelection(messageID: item.id, contextID: contextID, windowID: windowID,
                        extendingRange: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
                }
            }.disabled(disabled || windowID == nil || search.hasMessageQuery || !TelegramComposerForwardSource(source: source).isValid)
                .accessibilityIdentifier("telegram.selection.begin.\(item.id)")
        }
    }

    private func nativeMessageActions(_ item: TelegramMessage) -> [TelegramReadingMenuAction] {
        guard let source = model.actionSource(for: item) else { return [] }
        let context = model.messageActionContextID, window = model.historyWindowID
        let enabled = !model.isBusy && !model.isRestoringComposerDraft && model.composerDraftRecoveryError == nil &&
            !model.isForwardComposerLocked && upload.phase == .idle && !messageActions.isBusy && messageActions.phase != .uncertain
        func choose(_ mode: TelegramMessageActionRequest.Mode) {
            guard model.messageActionContextID == context else { return }
            switch mode {
            case .reply: _ = model.beginReply(to: item, contextID: context)
            case .edit: _ = model.beginMessageEdit(source: source, author: item.author, contextID: context)
            case .forward, .delete: messageActionRequest = .init(source: source, author: item.author, contextID: context, mode: mode)
            }
        }
        return [
            .init(title: "Ответить", enabled: enabled && source.canReply, perform: { choose(.reply) }),
            .init(title: "Изменить", enabled: enabled && source.canEdit, perform: { choose(.edit) }),
            .init(title: "Переслать…", enabled: enabled && source.canForward, perform: { choose(.forward) }),
            .init(title: "Удалить…", enabled: enabled && (source.canDeleteLocally || source.canDeleteForEveryone), perform: { choose(.delete) }),
            .init(title: "Выбрать", enabled: enabled && window != nil && !search.hasMessageQuery && TelegramComposerForwardSource(source: source).isValid, perform: {
                if let window { _ = model.beginMessageSelection(messageID: item.id, contextID: context, windowID: window,
                    extendingRange: NSApp.currentEvent?.modifierFlags.contains(.shift) == true) }
            })]
    }
}

#if DEBUG
struct TelegramSyntheticPreviewView: View {
    @StateObject private var model: TelegramModel
    private let persistentDrafts: Bool
    init(model: TelegramModel = .syntheticPreview(), persistentDrafts: Bool = false) {
        _model = StateObject(wrappedValue: model); self.persistentDrafts = persistentDrafts
    }
    var body: some View {
        VStack(spacing: 0) {
            Text(persistentDrafts
                ? "СИНТЕТИЧЕСКАЯ ПРОВЕРКА • отдельный Postbox черновиков • личные аккаунты, PostgreSQL, сеть и отправка не используются"
                : "СИНТЕТИЧЕСКАЯ ПРОВЕРКА • личные аккаунты, база данных, сеть и отправка не используются")
                .font(.caption.bold()).padding(10).frame(maxWidth: .infinity).background(.yellow.opacity(0.15))
            Button("QA: ошибка следующего поискового запроса", action: model.search.failNextSyntheticMessageSearch)
                .controlSize(.small).padding(6).accessibilityIdentifier("telegram.qa.failSearch")
            HStack(spacing: 0) {
                TelegramSidebarView(model: model).frame(width: 320)
                Divider()
                TelegramDetailView(model: model)
            }
        }.modifier(TelegramNotificationHost(controller: model.notifications))
    }
}

struct TelegramDraftsSyntheticPreviewView: View {
    @State private var model: TelegramModel?
    @State private var failure: String?
    var body: some View {
        Group {
            if let model {
                WorkspaceView(syntheticTelegram: model)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Label("СИНТЕТИЧЕСКАЯ ПРОВЕРКА ЧЕРНОВИКОВ", systemImage: "testtube.2")
                                .font(.caption.bold())
                                .help("Отдельные Postbox и схема PostgreSQL; личные аккаунты и сеть Telegram не используются")
                        }
                    }
            }
            else if let failure { Text(failure).padding(24) }
            else { ProgressView("Открытие отдельного синтетического Postbox…") }
        }.task {
            guard model == nil, failure == nil else { return }
            do {
                let arguments = CommandLine.arguments
                guard let index = arguments.firstIndex(of: "--telegram-drafts-synthetic-preview"), arguments.indices.contains(index + 1) else {
                    throw CocoaError(.fileReadUnknown)
                }
                let preview = try await TelegramModel.syntheticDraftPreview(directory: URL(fileURLWithPath: arguments[index + 1]),
                    albums: arguments.contains("--telegram-albums-qa"),
                    extendedMessages: arguments.contains("--telegram-extended-messages-synthetic-preview"))
                if arguments.contains("--telegram-round-video-qa") { preview.voiceRecording.toggleKind() }
                model = preview
            } catch { failure = "Не удалось открыть отдельное синтетическое хранилище черновиков." }
        }
    }
}
#endif

struct TelegramSearchStatusView: View {
    let status: TelegramSearchStatus
    let retry: () -> Void
    var body: some View {
        if status == .loading {
            HStack { ProgressView().controlSize(.mini); Text("Поиск…").font(.caption).foregroundStyle(.secondary) }
        } else if status == .failed || status == .timedOut {
            HStack {
                Text(status == .failed ? "Не удалось выполнить поиск. Показанные результаты сохранены." : "Поиск занимает больше времени. Можно повторить запрос.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Повторить", action: retry).controlSize(.small).accessibilityIdentifier("telegram.search.retry")
            }
        }
    }
}

struct TelegramPaginationBar: View {
    let page: TelegramPageNavigation
    let prefix: String
    let previous: () -> Void
    let next: () -> Void
    let latest: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: previous) { Label("Старее", systemImage: "chevron.left") }
                    .disabled(!page.canLoadPrevious).accessibilityIdentifier(prefix + ".older")
                Button(action: next) { Label("Новее", systemImage: "chevron.right") }
                    .disabled(!page.canLoadNext).accessibilityIdentifier(prefix + ".newer")
                Spacer(minLength: 4)
                Button("Последние", action: latest).disabled(page.isLoading || page.isAtLatest)
                    .accessibilityIdentifier(prefix + ".latest")
            }.controlSize(.small)
            if page.isLoading {
                HStack { ProgressView().controlSize(.mini); Text("Загрузка из Telegram…").font(.caption).foregroundStyle(.secondary) }
            }
            if page.timedOut {
                HStack(alignment: .top) {
                    Text("Загрузка занимает больше времени. Показанные данные сохранены.").font(.caption).foregroundStyle(.secondary)
                    Button("Повторить", action: retry).controlSize(.small).accessibilityIdentifier(prefix + ".retry")
                }
            }
        }
    }
}
