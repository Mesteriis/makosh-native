import AVFoundation
import AppKit
import MakoshAI
import MakoshCore
import SwiftUI

struct AIConversationListView: View {
    @ObservedObject var model: AIWorkspaceModel
    var synthetic = false
    /// Opens the chat a conversation belongs to.
    var openChat: (AIContextCard) -> Void = { _ in }
    @State private var pendingDeletion: AIConversation?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("ИИ").font(.title2.bold())
                Spacer()
                Button {
                    Task { await model.newConversation() }
                } label: {
                    Image(systemName: "square.and.pencil")
                }.help("Новая беседа").disabled(!model.ready).accessibilityIdentifier("ai.newConversation")
            }
            Picker("Беседы", selection: $model.filter) {
                Text("Все").tag(AIConversationFilter.all)
                Text("Без привязки").tag(AIConversationFilter.unanchored)
                Text("По чатам").tag(AIConversationFilter.anchored)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).accessibilityIdentifier("ai.conversations.filter")
            List(selection: Binding(get: { model.selectedConversationID }, set: { id in Task { await model.select(id) } })) {
                ForEach(model.visibleConversations) { conversation in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(conversation.title.isEmpty ? "Новая беседа" : conversation.title).lineLimit(1)
                        HStack(spacing: 6) {
                            if let anchor = conversation.anchor {
                                Button {
                                    openChat(anchor)
                                } label: {
                                    Label(anchor.title, systemImage: "bubble.left.and.bubble.right").lineLimit(1)
                                }
                                .buttonStyle(.borderless).help("Открыть чат")
                                .accessibilityIdentifier("ai.conversation.anchor.\(conversation.id.uuidString)")
                            }
                            Text(conversation.updatedAt, style: .relative)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(conversation.id)
                    .contextMenu { Button("Удалить беседу…", role: .destructive) { pendingDeletion = conversation } }
                    .accessibilityIdentifier("ai.conversation.\(conversation.id.uuidString)")
                }
            }.listStyle(.plain)
            if synthetic { Text("СИНТЕТИЧЕСКАЯ ПРОВЕРКА · провайдер не подключён").font(.caption2.bold()).foregroundStyle(.orange) }
        }
        .padding(16)
        .confirmationDialog(
            "Удалить беседу?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { conversation in
            Button("Удалить", role: .destructive) { Task { await model.delete(conversation.id) } }
        } message: { _ in
            Text("Беседа и её изображения будут удалены. Архив переписки не затрагивается.")
        }
    }
}

struct AIConversationView: View {
    @ObservedObject var model: AIWorkspaceModel
    /// In a chat's panel: sources for "+" and "@", and where a card opens.
    var contextSearch: AIContextSearch?
    var openCard: (AIContextCard) -> Void = { _ in }
    /// Opens a cited Makosh message in its own section.
    var openSource: (MessageArchiveIdentity) -> Void = { _ in }
    @StateObject private var voice = AIVoiceInput()
    @State private var draft = ""
    @State private var editing: UUID?
    @State private var player: AVAudioPlayer?
    @State private var adding = false

    /// The "@word" being typed at the end of the draft.
    private var mention: String? {
        guard contextSearch != nil, let at = draft.lastIndex(of: "@") else { return nil }
        if at != draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let query = draft[draft.index(after: at)...]
        return query.contains(where: \.isNewline) ? nil : String(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.selectedConversationID == nil {
                ContentUnavailableView(
                    "Выберите беседу", systemImage: "sparkles", description: Text("Создайте новую беседу, чтобы спросить модель."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(model.path) { message in
                                AIMessageRow(
                                    message: message, model: model, canSpeak: model.roles[.speech] != nil,
                                    edit: { text in
                                        editing = message.id
                                        draft = text
                                    }, speak: { speak(message.id) }, openSource: openSource, openCard: openCard
                                ).id(message.id)
                            }
                        }.padding(20)
                    }
                    .onChange(of: model.path.last?.current?.text) { _, _ in
                        if let last = model.path.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                if let failure = model.failure {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                        Text(failure.message)
                        Spacer()
                        Button("Закрыть") { model.dismissFailure() }
                    }
                    .padding(10).background(.orange.opacity(0.15)).accessibilityIdentifier("ai.failure")
                }
                Divider()
                composer
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let contextSearch {
                AIContextCardsView(model: model, open: openCard).padding(.horizontal, -12)
                if mention != nil {
                    AIContextSuggestionsList(search: contextSearch) { suggestion in attachMention(suggestion) }
                        .background(WorkspaceStyle.surface, in: .rect(cornerRadius: 8))
                }
            }
            if editing != nil {
                HStack {
                    Label("Изменение сообщения", systemImage: "pencil").font(.caption)
                    Spacer()
                    Button("Отменить") {
                        editing = nil
                        draft = ""
                    }.font(.caption)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                if let contextSearch {
                    Button {
                        adding = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Добавить в контекст чат, письмо или контакт").accessibilityIdentifier("ai.context.add")
                    .popover(isPresented: $adding) {
                        AIContextAddPopover(search: contextSearch) { suggestion in
                            adding = false
                            Task { await model.add(suggestion.card) }
                        }
                    }
                }
                TextField(
                    contextSearch == nil ? "Спросите модель…" : "Спросите о переписке… (@ — добавить источник)", text: $draft,
                    axis: .vertical
                )
                .textFieldStyle(.plain).lineLimit(1...8).onSubmit(send)
                .onChange(of: draft) { _, _ in if let mention { contextSearch?.update(query: mention) } }
                .accessibilityIdentifier("ai.composer")
                Button {
                    toggleDictation()
                } label: {
                    Image(systemName: voice.isRecording ? "stop.circle.fill" : "mic")
                }
                .help(model.roles[.transcription] == nil ? "Назначьте модель распознавания речи в Настройки → ИИ" : "Диктовка")
                .disabled(model.roles[.transcription] == nil || model.isStreaming)
                .accessibilityIdentifier("ai.dictation")
                Button {
                    let prompt = draft
                    draft = ""
                    Task { await model.generateImage(prompt) }
                } label: {
                    Image(systemName: "photo")
                }
                .help(model.roles[.images] == nil ? "Назначьте модель изображений в Настройки → ИИ" : "Сгенерировать изображение по тексту")
                .disabled(model.roles[.images] == nil || model.isStreaming || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("ai.image")
                if model.isStreaming {
                    Button {
                        model.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                    }.help("Остановить").accessibilityIdentifier("ai.stop")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .help(model.roles[.chat] == nil ? "Назначьте модель беседы в Настройки → ИИ" : "Отправить")
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("ai.send")
                }
            }
            if voice.denied {
                Text("Нет доступа к микрофону: разрешите его в Системных настройках.").font(.caption).foregroundStyle(.secondary)
            }
            if contextSearch == nil {
                Toggle(
                    "Искать в моих данных",
                    isOn: Binding(get: { model.searchMyData }, set: { value in Task { await model.setSearchMyData(value) } })
                )
                .toggleStyle(.switch).controlSize(.mini).font(.caption)
                .help("Подмешивать в вопрос фрагменты чатов, ящиков и контактов, открытых для ИИ")
                .disabled(model.roles[.embeddings] == nil)
                .accessibilityIdentifier("ai.searchMyData")
            }
        }
        .padding(12)
    }

    /// Replaces the typed "@word" with the chosen source as a card.
    private func attachMention(_ suggestion: AIContextSuggestion) {
        if let at = draft.lastIndex(of: "@") { draft = String(draft[..<at]) }
        Task { await model.add(suggestion.card) }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.isStreaming else { return }
        draft = ""
        let target = editing
        editing = nil
        Task {
            if let target { await model.edit(target, text: text) } else { await model.send(text) }
        }
    }

    private func toggleDictation() {
        if voice.isRecording {
            guard let file = voice.stop() else { return }
            Task {
                defer { try? FileManager.default.removeItem(at: file) }
                if let text = await model.transcribe(file) { draft += (draft.isEmpty ? "" : " ") + text }
            }
        } else {
            Task { await voice.start() }
        }
    }

    private func speak(_ id: UUID) {
        Task {
            guard let audio = await model.speak(id) else { return }
            player = try? AVAudioPlayer(data: audio)
            player?.play()
        }
    }
}

private struct AIMessageRow: View {
    let message: AIMessage
    @ObservedObject var model: AIWorkspaceModel
    let canSpeak: Bool
    let edit: (String) -> Void
    let speak: () -> Void
    let openSource: (MessageArchiveIdentity) -> Void
    let openCard: (AIContextCard) -> Void
    @State private var image: NSImage?

    var body: some View {
        let version = message.current
        VStack(alignment: message.author == .user ? .trailing : .leading, spacing: 6) {
            if let reference = version?.image {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 420, maxHeight: 420)
                    } else {
                        ProgressView()
                    }
                }.task(id: reference.objectID) { image = await model.image(reference).flatMap(NSImage.init(data:)) }
            }
            if let text = version?.text, !text.isEmpty {
                Text(text).textSelection(.enabled).padding(10)
                    .background(message.author == .user ? WorkspaceStyle.outgoing : WorkspaceStyle.surface, in: .rect(cornerRadius: 10))
            } else if version?.state == .streaming {
                ProgressView().controlSize(.small)
            }
            HStack(spacing: 10) {
                if version?.state == .interrupted { Label("прервано", systemImage: "pause.circle").foregroundStyle(.secondary) }
                if version?.state == .failed { Label("ошибка", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                if message.versions.count > 1 {
                    Button {
                        Task { await model.selectVersion(message.selectedVersion - 1, of: message.id) }
                    } label: {
                        Image(systemName: "chevron.left")
                    }.disabled(message.selectedVersion == 0 || model.isStreaming)
                    Text("\(message.selectedVersion + 1)/\(message.versions.count)").monospacedDigit()
                    Button {
                        Task { await model.selectVersion(message.selectedVersion + 1, of: message.id) }
                    } label: {
                        Image(systemName: "chevron.right")
                    }.disabled(message.selectedVersion == message.versions.count - 1 || model.isStreaming)
                }
                if message.author == .assistant, version?.image == nil {
                    Button("Перегенерировать") { Task { await model.regenerate(message.id) } }.disabled(model.isStreaming)
                    if canSpeak { Button("Озвучить", action: speak).disabled(version?.text.isEmpty != false) }
                }
                if message.author == .user { Button("Изменить") { edit(version?.text ?? "") }.disabled(model.isStreaming) }
            }
            .buttonStyle(.borderless).font(.caption)
            if message.author == .assistant, let context = version?.context, !context.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("По источникам").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(context) { card in
                        Button(card.title) { openCard(card) }.buttonStyle(.link).font(.caption).lineLimit(1)
                            .accessibilityIdentifier("ai.contextSource.\(card.id)")
                    }
                }
            }
            if let sources = version?.sources, !sources.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Источники").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                        Button {
                            openSource(source.identity)
                        } label: {
                            Text("[\(index + 1)] \(AISourceLabel.text(source))").lineLimit(1)
                        }
                        .buttonStyle(.link).font(.caption)
                        .accessibilityIdentifier("ai.source.\(index + 1)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.author == .user ? .trailing : .leading)
        .accessibilityIdentifier("ai.message.\(message.id.uuidString)")
    }
}

enum AISourceLabel {
    static func text(_ source: AISourceReference) -> String {
        let service =
            switch source.identity.service {
            case "telegram": "Telegram"
            case "whatsapp": "WhatsApp"
            case "teams": "Teams"
            case "mail": "Почта"
            default: source.identity.service
            }
        let title = source.title.isEmpty ? "переписка" : source.title
        return "\(service) · \(title) · \(source.date.formatted(date: .abbreviated, time: .omitted))"
    }
}
