import MakoshWhatsApp
// Layout adapted from WhatsApp Zen MainView.swift / Components.swift (MIT).
// See LICENSES/WhatsApp-Zen-MIT.txt and docs/reference-interface.md.
import SwiftUI

private enum WhatsAppFilter: String, CaseIterable {
  case all = "Все"
  case unread = "Непрочитанные"
  case groups = "Группы"
  case archived = "Архив"
}
struct WhatsAppSidebarView: View {
  @ObservedObject var model: WhatsAppWorkspaceModel
  @State private var search = ""
  @State private var filter = WhatsAppFilter.all
  @State private var adding = false
  @State private var statuses = false
  @State private var accountSettings = false
  @State private var newChat = false
  @State private var name = ""
  private var chats: [WhatsAppChat] {
    model.chats.filter { chat in
      (filter == .archived ? chat.archived : !chat.archived)
        && (filter != .unread || chat.unread > 0) && (filter != .groups || chat.group)
        && (search.isEmpty || chat.name.localizedCaseInsensitiveContains(search))
    }
  }
  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("WhatsApp").font(.title2.bold())
          Spacer()
          Menu {
            Button("Новый чат или группа") { newChat = true }.disabled(
              model.selectedAccountID == nil)
            Button("Настройки WhatsApp") { accountSettings = true }
            Button("Статусы") { statuses = true }.disabled(model.selectedAccountID == nil)
            Button("Лицензия ядра") {
              if let url = Bundle.main.resourceURL?.appendingPathComponent(
                "Licenses/WhatsApp-Worker-AGPL-3.0.txt")
              {
                NSWorkspace.shared.activateFileViewerSelecting([url])
              }
            }
            Button("Исходники ядра") {
              if let url = Bundle.main.url(
                forResource: "MakoshWhatsAppWorker-Source", withExtension: "tar.gz")
              {
                NSWorkspace.shared.activateFileViewerSelecting([url])
              }
            }
          } label: {
            Image(systemName: "info.circle")
          }.menuStyle(.borderlessButton).frame(width: 22).help("Лицензия и исходники ядра WhatsApp")
          Button {
            adding = true
          } label: {
            Image(systemName: "plus")
          }.help("Добавить аккаунт").disabled(model.isSynthetic).accessibilityIdentifier(
            "whatsapp.account.add")
        }
        if !model.accounts.isEmpty {
          Picker(
            "Аккаунт",
            selection: Binding(
              get: { model.selectedAccountID },
              set: { id in if let id { Task { await model.selectAccount(id) } } })
          ) {
            ForEach(model.accounts) { Text($0.name).tag(Optional($0.id)) }
          }.labelsHidden().accessibilityIdentifier("whatsapp.account.selector")
        }
        Label(
          model.isSynthetic ? "Синтетическая проверка · без сети" : model.status.label,
          systemImage: model.status.linked ? "checkmark.circle.fill" : "circle.dashed"
        ).font(.caption).foregroundStyle(.secondary)
        if model.isSynthetic {
          #if DEBUG
            Button("Тестовое окно звонка") { model.calls.preview() }.accessibilityIdentifier(
              "whatsapp.qa.call")
            Button("Показать тестовый QR") { Task { await model.previewPairing() } }
              .accessibilityIdentifier("whatsapp.qa.qr")
          #endif
        } else if model.selectedAccountID != nil {
          HStack {
            if model.status.state != "logged_out" {
              Button(model.status.linked ? "Подключено" : "Подключить") { model.connect() }
                .disabled(model.busy || model.status.linked).accessibilityIdentifier(
                  "whatsapp.connect")
            }
            if model.busy || model.status.state != "offline" {
              Button("Отключить") { Task { await model.disconnect() } }.accessibilityIdentifier(
                "whatsapp.disconnect")
            }
          }
        }
        if let error = model.notificationError {
          Text(error).font(.caption).foregroundStyle(.orange)
        }
        if let error = model.archiveError { Text(error).font(.caption).foregroundStyle(.orange) }
        TextField("Поиск чатов", text: $search).textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("whatsapp.search")
        ScrollView(.horizontal) {
          HStack(spacing: 6) {
            ForEach(WhatsAppFilter.allCases, id: \.self) { item in
              Button(item.rawValue) { filter = item }.tint(filter == item ? .green : .secondary)
                .buttonStyle(.bordered).accessibilityIdentifier("whatsapp.filter.\(item)")
            }
          }
        }.scrollIndicators(.hidden)
      }.padding(16)
      Divider()
      if chats.isEmpty {
        ContentUnavailableView(
          model.accounts.isEmpty ? "Подключите WhatsApp" : "Чатов пока нет",
          systemImage: "bubble.left.and.bubble.right",
          description: Text(
            model.accounts.isEmpty
              ? "Добавьте аккаунт и свяжите его с телефоном по QR-коду."
              : "Сохранённая история появится здесь после синхронизации. Проверьте выбранный аккаунт и фильтр."
          )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(
          selection: Binding(
            get: { model.selectedChatID }, set: { id in Task { await model.selectChat(id) } })
        ) {
          ForEach(chats) { chat in
            WhatsAppChatRow(chat: chat, model: model).padding(.vertical, 5).fixedSize(
              horizontal: false, vertical: true
            )
            .tag(chat.id).accessibilityIdentifier("whatsapp.chat.\(chat.id)")
          }
        }.listStyle(.plain)
      }
    }.tint(.green)
      .sheet(isPresented: $newChat) {
        if let account = model.selectedAccountID {
          WhatsAppNewChatView(model: model, accountID: account)
        }
      }
      .sheet(isPresented: $accountSettings) {
        VStack {
          HStack {
            Spacer()
            Button("Закрыть") { accountSettings = false }
          }.padding()
          WhatsAppSettingsView(model: model)
        }.frame(width: 700, height: 600)
      }
      .sheet(isPresented: $statuses) {
        if let account = model.selectedAccountID {
          WhatsAppStatusView(worker: model.notificationWorker, accountID: account)
        }
      }
      .sheet(isPresented: $adding) {
        VStack(alignment: .leading, spacing: 18) {
          Text("Добавить WhatsApp").font(.title2.bold())
          TextField("Название аккаунта", text: $name).textFieldStyle(.roundedBorder)
          Text("После добавления отсканируйте QR-код в WhatsApp на телефоне.").foregroundStyle(
            .secondary)
          HStack {
            Button("Отмена") { adding = false }
            Spacer()
            Button("Добавить и подключить") {
              Task {
                if await model.addAccount(name) {
                  adding = false
                  name = ""
                }
              }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
              .keyboardShortcut(.defaultAction)
          }
        }.padding(24).frame(width: 420)
      }
      .alert(
        "WhatsApp",
        isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
      ) {
        Button("Понятно") { model.error = nil }
      } message: {
        Text(model.error ?? "")
      }
  }
}
private struct WhatsAppChatRow: View {
  let chat: WhatsAppChat
  @ObservedObject var model: WhatsAppWorkspaceModel
  var body: some View {
    HStack(spacing: 11) {
      WhatsAppAvatarView(name: chat.name, group: chat.group,
        scope: model.selectedAccountID.map { .init(accountID: $0, jid: chat.id) },
        revision: model.status.avatarRevisions?[chat.id] ?? 0, epoch: model.status.avatarEpoch ?? 0,
        worker: model.notificationWorker, cache: model.avatarCache)
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline) {
          Text(chat.name).font(.body.weight(chat.unread > 0 ? .semibold : .medium)).lineLimit(1)
          Spacer(minLength: 4)
          if chat.pinned {
            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
          }
          Text(Date(timeIntervalSince1970: TimeInterval(chat.timestamp)), style: .time).font(
            .caption
          ).foregroundStyle(.secondary)
        }
        HStack {
          Text(chat.preview ?? (chat.group ? "Групповой чат" : "Личная переписка")).font(.callout)
            .foregroundStyle(.secondary).lineLimit(2)
          Spacer(minLength: 4)
          if chat.unread > 0 {
            Text("\(chat.unread)").font(.caption.bold()).foregroundStyle(.white).padding(
              .horizontal, 6
            ).padding(.vertical, 3).background(.green, in: Capsule())
          }
        }
      }
    }.tint(.green)
  }
}
struct WhatsAppAvatar: View {
  let name: String, group: Bool
  var body: some View {
    ZStack {
      Circle().fill(.green.opacity(0.22))
      if group {
        Image(systemName: "person.2.fill").foregroundStyle(.green)
      } else {
        Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
          .font(.headline).foregroundStyle(.green)
      }
    }.frame(width: 44, height: 44).accessibilityHidden(true)
  }
}
struct WhatsAppDetailView: View {
  @ObservedObject var model: WhatsAppWorkspaceModel
  var dossier: () -> Void = {}
  private let sourceAccount: UUID?
  private let sourceChat: String?
  init(model: WhatsAppWorkspaceModel, dossier: @escaping () -> Void = {}) {
    self.model = model
    self.dossier = dossier
    sourceAccount = model.selectedAccountID
    sourceChat = model.selectedChatID
    _history = StateObject(
      wrappedValue: .init(
        worker: model.notificationWorker, accountID: model.selectedAccountID ?? UUID(),
        chat: model.selectedChatID ?? ""))
  }
  @State private var richCompose = false
  @State private var callDevices = false
  @State private var settings = false
  @StateObject private var history: WhatsAppHistoryModel
  @State private var archive = false
  @State private var archivedMessage: String?
  @State private var actionMessage: WhatsAppMessage?
  @State private var actionKind = ""
  @State private var actionText = ""
  private struct GroupRequest:Identifiable {let id=UUID();let account:UUID,chat:String,video:Bool}
  @State private var groupRequest:GroupRequest?
  @State private var preview: WhatsAppFileLease?
  var body: some View {
    Group {
      if ["qr", "connecting", "expired"].contains(model.status.state) {
        WhatsAppPairingView(model: model)
      } else if let chat = model.selectedChat {
        VStack(spacing: 0) {
          HStack(spacing: 12) {
            WhatsAppAvatarView(name: chat.name, group: chat.group,
              scope: model.selectedAccountID.map { .init(accountID: $0, jid: chat.id) },
              revision: model.status.avatarRevisions?[chat.id] ?? 0, epoch: model.status.avatarEpoch ?? 0,
              worker: model.notificationWorker, cache: model.avatarCache)
            VStack(alignment: .leading) {
              Text(chat.name).font(.title3.bold())
              Text(model.status.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
              startCall(video: false, chat: chat)
            } label: {
              Image(systemName: "phone")
            }.help("Аудиозвонок").disabled(
              model.isSynthetic || !model.status.linked || model.calls.call != nil)
            Button {
              startCall(video: true, chat: chat)
            } label: {
              Image(systemName: "video")
            }.help("Видеозвонок").disabled(
              model.isSynthetic || !model.status.linked || model.calls.call != nil)
            Button {
              callDevices = true
            } label: {
              Image(systemName: "headphones")
            }.help("Устройства следующего звонка")
            Button {
              settings = true
            } label: {
              Image(systemName: "info.circle")
            }.help("Информация и настройки чата").accessibilityIdentifier("whatsapp.chat.settings")
            Menu {
              Button("Постоянный архив и экспорт") {
                archivedMessage = nil
                archive = true
              }
              Button(chat.archived ? "Вернуть из архива" : "Архивировать") {
                command(.init(.archive, on: !chat.archived))
              }
              Button(chat.pinned ? "Открепить чат" : "Закрепить чат") {
                command(.init(.pinChat, on: !chat.pinned))
              }
              Button("Прочитано") { command(.init(.read)) }
              Button("Отключить звук") { command(.init(.mute, duration: -1)) }
              Button("Включить звук") { command(.init(.mute, duration: 0)) }
            } label: {
              Image(systemName: "ellipsis")
            }.menuStyle(.borderlessButton).accessibilityLabel("Действия чата").accessibilityIdentifier("whatsapp.chat.actions")
            Button("Ранее") { Task { await model.loadOlder() } }.disabled(
              !model.hasOlder || model.historyBusy
            ).accessibilityIdentifier("whatsapp.history.older")
            Button {
              Task { await model.selectChat(chat.id) }
            } label: {
              Image(systemName: "arrow.clockwise")
            }.help("Обновить историю")
          }.padding(16).background(.bar)
          Divider()
          WhatsAppSearchBar(history: history)
          if displayed.isEmpty {
            ContentUnavailableView(
              "В этом чате пока нет сообщений", systemImage: "bubble.left",
              description: Text("Полученная история сохраняется и доступна офлайн.")
            ).frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            ScrollView {
              LazyVStack(spacing: 8) {
                ForEach(displayed.reversed()) { message in
                  WhatsAppMessageRow(
                    message: message,
                    open: {
                      Task {
                        if let sourceAccount,
                          let lease = await model.actions.download(
                            message, expectedAccount: sourceAccount)
                        {
                          preview?.remove()
                          preview = lease
                        }
                      }
                    },
                    vote: { option in
                      var a = WhatsAppAction(.vote, target: message.id)
                      a.options = [option]
                      command(a)
                    }
                  )
                  .contextMenu {
                    Button("Ответить") {
                      if let sourceAccount {
                        model.composer.quote(message, expectedAccount: sourceAccount)
                      }
                    }
                    Button("Версии сообщения") {
                      archivedMessage = message.id
                      archive = true
                    }
                    Button("Копировать") {
                      NSPasteboard.general.clearContents()
                      NSPasteboard.general.setString(message.text, forType: .string)
                    }
                    Menu("Реакция") {
                      ForEach(["👍", "❤️", "😂", "😮", "😢", "🙏", ""], id: \.self) { emoji in
                        Button(emoji.isEmpty ? "Убрать реакцию" : emoji) {
                          command(.init(.react, text: emoji, target: message.id))
                        }
                      }
                    }
                    Button(
                      message.details?.starred == true ? "Убрать из избранного" : "В избранное"
                    ) {
                      command(
                        .init(.star, target: message.id, on: message.details?.starred != true))
                    }
                    Button(message.details?.pinned == true ? "Открепить" : "Закрепить") {
                      command(.init(.pin, target: message.id, on: message.details?.pinned != true))
                    }
                    if !message.deleted {
                      Button("Переслать…") {
                        actionMessage = message
                        actionKind = "forward"
                        actionText = ""
                      }
                    }
                    if message.outgoing && !message.deleted {
                      Button("Изменить…") {
                        actionMessage = message
                        actionKind = "edit"
                        actionText = message.text
                      }
                      Button("Удалить в WhatsApp…", role: .destructive) {
                        actionMessage = message
                        actionKind = "revoke"
                        actionText = ""
                      }
                    }
                  }
                }
              }.padding(20)
            }.defaultScrollAnchor(.bottom).accessibilityIdentifier("whatsapp.history")
          }
          if history.active, history.hasMore {
            Button("Продолжить поиск") { Task { await history.loadMore() } }.disabled(history.busy)
          }
          Divider()
          WhatsAppComposeView(
            model: model.composer, accountID: sourceAccount, chatID: sourceChat,
            rich: { richCompose = true })
        }.background(.green.opacity(0.035))
      } else {
        ContentUnavailableView(
          "Выберите чат", systemImage: "bubble.left.and.bubble.right",
          description: Text("Переписка выбранного аккаунта откроется здесь."))
      }
    }.tint(.green)
      .sheet(isPresented: $richCompose) {
        if let sourceAccount, let sourceChat {
          WhatsAppRichComposeView(model: model, accountID: sourceAccount, chatID: sourceChat)
        }
      }
      .sheet(isPresented: $archive) {
        if let sourceAccount, let sourceChat {
          WhatsAppArchiveView(
            worker: model.notificationWorker, accountID: sourceAccount, chat: sourceChat,
            messageID: archivedMessage)
        }
      }
      .sheet(item:$groupRequest) {request in
        WhatsAppGroupCallPicker(worker:model.notificationWorker,accountID:request.account,groupJID:request.chat,video:request.video) {targets in
          guard model.selectedAccountID==request.account,model.selectedChatID==request.chat,model.actions.contextMatches(account:request.account,chat:request.chat) else {return}
          model.calls.startGroup(accountID:request.account,groupJID:request.chat,participants:targets,video:request.video)
        }
      }
      .onChange(of:model.selectedAccountID) {_,_ in groupRequest=nil}
      .onChange(of:model.selectedChatID) {_,_ in groupRequest=nil}
      .sheet(isPresented: $callDevices) { WhatsAppCallDevicesView(model: model.calls) }
      .sheet(isPresented: $settings) {
        if let chat = model.selectedChat, let sourceAccount {
          WhatsAppChatSettingsView(
            model: model.actions, chat: chat, accountID: sourceAccount,
            synthetic: model.isSynthetic, worker: model.notificationWorker, avatarCache: model.avatarCache,
            avatarRevision: model.status.avatarRevisions?[chat.id] ?? 0, avatarEpoch: model.status.avatarEpoch ?? 0,
            dossier: dossier)
        }
      }
      .sheet(
        isPresented: Binding(get: { actionMessage != nil }, set: { if !$0 { actionMessage = nil } })
      ) {
        VStack(alignment: .leading, spacing: 14) {
          Text(
            actionKind == "revoke"
              ? "Удалить в WhatsApp?"
              : actionKind == "edit" ? "Изменить сообщение" : "Переслать сообщение"
          ).font(.title2.bold())
          if actionKind == "revoke" {
            Text("Архив Макоша сохранит сообщение и все его версии.")
          } else {
            TextField(actionKind == "forward" ? "JID получателя" : "Текст", text: $actionText)
              .textFieldStyle(.roundedBorder)
          }
          HStack {
            Button("Отмена") { actionMessage = nil }
            Spacer()
            Button("Выполнить") {
              if let m = actionMessage {
                command(
                  .init(
                    actionKind == "edit" ? .edit : actionKind == "forward" ? .forward : .revoke,
                    text: actionKind == "edit" ? actionText : "", target: m.id,
                    to: actionKind == "forward" ? actionText : ""))
                actionMessage = nil
              }
            }
          }
        }.padding(24).frame(width: 460)
      }
      .sheet(
        isPresented: Binding(
          get: { preview != nil },
          set: {
            if !$0 {
              preview?.remove()
              preview = nil
            }
          })
      ) { if let preview { WhatsAppFilePreview(lease: preview) } }
      .onDisappear {
        preview?.remove()
        preview = nil
      }
  }
  private func startCall(video: Bool, chat: WhatsAppChat) {
    guard let sourceAccount, sourceChat?.utf8.elementsEqual(chat.id.utf8) == true,
      model.actions.contextMatches(account: sourceAccount, chat: chat.id)
    else { return }
    if chat.group {groupRequest = .init(account:sourceAccount,chat:chat.id,video:video)}else {model.calls.start(accountID: sourceAccount, peer: chat.id, video: video)}
  }
  private var displayed: [WhatsAppMessage] { history.active ? history.messages : model.messages }
  private func command(_ action: WhatsAppAction) {
    guard let sourceAccount, let sourceChat else { return }
    Task {
      await model.actions.perform(action, expectedAccount: sourceAccount, expectedChat: sourceChat)
      await model.composer.refreshOutbox()
      await model.refresh()
    }
  }
}
struct WhatsAppMessageRow: View {
  @Environment(\.colorScheme) private var scheme
  @State private var renderedMessage: WhatsAppMessage?
  @State private var rendered: WhatsAppMessagePresentation?
  let message: WhatsAppMessage
  var open: () -> Void = {}
  var vote: (String) -> Void = { _ in }
  private var presentation: WhatsAppMessagePresentation? {
    renderedMessage == message ? rendered : nil
  }
  private var bodyText: String? {
    if message.kind == "contact" || message.kind == "poll" { return presentation?.bodyText }
    return message.text.isEmpty ? nil : message.text
  }
  private func color(_ hex: UInt32) -> Color {
    Color(
      red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
      blue: Double(hex & 255) / 255)
  }
  var body: some View {
    HStack {
      if message.outgoing { Spacer(minLength: 50) }
      WhatsAppCappedWidth(max: 520) {
        WhatsAppBubbleStack(spacing: 5) {
          if let quote = message.details?.quotedText {
            Label(quote, systemImage: "arrowshape.turn.up.left").font(.caption).lineLimit(3)
              .padding(7).background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
          }
          if ["image", "video", "audio", "sticker", "document"].contains(message.kind) {
            Button(action: open) {
              Label(
                message.details?.name ?? mediaName(message.kind),
                systemImage: message.kind == "audio" ? "play.circle" : "paperclip")
            }.buttonStyle(.bordered)
          }
          if message.kind == "location", let lat = message.details?.latitude,
            let lon = message.details?.longitude,
            let url = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)")
          {
            Link(destination: url) {
              Label("Геопозиция · \(lat), \(lon)", systemImage: "mappin.and.ellipse")
            }
          }
          if message.kind == "contact" {
            if let contact = presentation?.contact {
              WhatsAppContactCard(contact: contact, rawSource: message.details?.contactVcard)
            } else { ProgressView().controlSize(.small) }
          }
          if message.kind == "poll" {
            Text(message.details?.pollName ?? "Опрос").font(.headline)
            ForEach(presentation?.pollOptions ?? []) { option in
              Button(
                "\(option.label) · \(message.details?.pollVotes?.filter{$0.options.contains(option.label)}.count ?? 0)"
              ) { vote(option.label) }.buttonStyle(.bordered)
            }
          }
          if let reactions = message.details?.reactions, !reactions.isEmpty {
            Text(reactions.map(\.text).joined(separator: " ")).font(.callout)
          }
          if let bodyText {
            Text(bodyText).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          }
          HStack {
            if message.deleted {
              Label("Удалено в WhatsApp · сохранено", systemImage: "archivebox")
            } else if message.edited {
              Text("изменено")
            }
            Spacer(minLength: 12)
            if message.details?.starred == true { Image(systemName: "star.fill") }
            if message.details?.pinned == true { Image(systemName: "pin.fill") }
            if let rejection = message.details?.rejection {
              Text("Отклонено сервером · \(rejection.code)").foregroundStyle(.red)
            } else if message.outgoing {
              Text(
                (message.delivery ?? 0) >= 3
                  ? "✓✓" : message.delivery == 2 ? "✓✓" : message.delivery == 1 ? "✓" : "◷"
              ).foregroundStyle(
                (message.delivery ?? 0) >= 3 ? Color.cyan : Color.white.opacity(0.78)
              ).help(
                (message.delivery ?? 0) >= 3
                  ? "Прочитано"
                  : message.delivery == 2
                    ? "Доставлено" : message.delivery == 1 ? "Принято сервером" : "Передано ядру")
            }
            Text(Date(timeIntervalSince1970: TimeInterval(message.timestamp)), style: .time)
          }.font(.caption2).foregroundStyle(
            message.outgoing ? Color.white.opacity(0.78) : Color.secondary)
        }.padding(.horizontal, 11).padding(.vertical, 7)
          .foregroundStyle(message.outgoing ? Color.white : Color.primary)
          .background(
            message.outgoing
              ? color(scheme == .dark ? 0x1B8A50 : 0x1A9F5A)
              : color(scheme == .dark ? 0x2B2B2F : 0xECECEF),
            in: UnevenRoundedRectangle(
              topLeadingRadius: 18, bottomLeadingRadius: message.outgoing ? 18 : 5,
              bottomTrailingRadius: message.outgoing ? 5 : 18, topTrailingRadius: 18))
      }
      if !message.outgoing { Spacer(minLength: 50) }
    }.accessibilityIdentifier("whatsapp.message.\(message.stanza)")
      .task(id: message) {
        guard message.kind == "contact" || message.kind == "poll" else { return }
        guard let value = try? await WhatsAppMessagePresentation.load(message), !Task.isCancelled else { return }
        rendered = value
        renderedMessage = message
      }
  }
}
private func mediaName(_ kind: String) -> String {
  switch kind {
  case "image": "Фото"
  case "video": "Видео"
  case "audio": "Аудио"
  case "sticker": "Стикер"
  default: "Документ"
  }
}
// Adapted from Zen CappedWidth and BubbleStack. Cap intrinsic width rather than
// expanding the bubble; timestamps must not stretch short messages to a card.
private struct WhatsAppCappedWidth: Layout {
  let max: CGFloat
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    subviews.first?.sizeThatFits(
      .init(width: min(proposal.width ?? max, max), height: proposal.height)) ?? .zero
  }
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    subviews.first?.place(
      at: bounds.origin, proposal: .init(width: bounds.width, height: bounds.height))
  }
}
private struct WhatsAppBubbleStack: Layout {
  var spacing: CGFloat = 5
  private func width(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
    let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    return min(ideal, proposal.width ?? ideal)
  }
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let w = width(proposal, subviews)
    return .init(
      width: w,
      height: subviews.map { $0.sizeThatFits(.init(width: w, height: nil)).height }.reduce(0, +)
        + spacing * CGFloat(max(0, subviews.count - 1)))
  }
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for view in subviews {
      let fit = ProposedViewSize(width: bounds.width, height: nil)
      view.place(at: .init(x: bounds.minX, y: y), anchor: .topLeading, proposal: fit)
      y += view.sizeThatFits(fit).height + spacing
    }
  }
}
private struct WhatsAppPairingView: View {
  @ObservedObject var model: WhatsAppWorkspaceModel
  private var steps: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Связать с WhatsApp").font(.largeTitle.bold())
      step(1, "Откройте WhatsApp на телефоне")
      step(2, "Настройки → Связанные устройства → Привязка устройства")
      step(3, "Наведите телефон на QR-код")
      if model.isSynthetic {
        Text("Тестовый QR · не привязывает аккаунт").font(.callout).foregroundStyle(.secondary)
      }
      if model.status.state == "expired" {
        Text("Код истёк. Подключитесь снова, чтобы получить новый.").foregroundStyle(.secondary)
      }
      Button("Отменить привязку") { Task { await model.disconnect() } }.accessibilityIdentifier(
        "whatsapp.pair.cancel")
    }.frame(maxWidth: 340, alignment: .leading)
  }
  private var code: some View {
    Group {
      if let data = model.qrImage, let image = NSImage(data: data) {
        Image(nsImage: image).interpolation(.none).resizable().scaledToFit().padding(14).background(
          .white, in: RoundedRectangle(cornerRadius: 22))
      } else if model.status.state == "expired" {
        Image(systemName: "qrcode").font(.system(size: 90)).foregroundStyle(.secondary)
      } else {
        ProgressView().controlSize(.large)
      }
    }.frame(width: 250, height: 250).padding(14).glassEffect(
      .regular, in: RoundedRectangle(cornerRadius: 34)
    ).accessibilityLabel(model.isSynthetic ? "Тестовый QR-код" : "QR-код привязки WhatsApp")
  }
  var body: some View {
    GeometryReader { size in
      ScrollView {
        Group {
          if size.size.width >= 700 {
            HStack(spacing: 44) {
              steps
              code
            }
          } else {
            VStack(alignment: .leading, spacing: 24) {
              steps
              code
            }
          }
        }.padding(32).frame(maxWidth: .infinity, minHeight: size.size.height)
      }
    }.background(
      LinearGradient(
        colors: [.green.opacity(0.18), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
  }
  private func step(_ number: Int, _ title: String) -> some View {
    HStack(spacing: 10) {
      Text("\(number)").font(.callout.bold()).foregroundStyle(.white).frame(width: 24, height: 24)
        .background(.green, in: Circle())
      Text(title).font(.title3)
    }
  }
}
