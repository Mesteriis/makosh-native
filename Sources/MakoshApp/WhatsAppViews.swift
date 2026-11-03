import MakoshWhatsApp
// Layout adapted from WhatsApp Zen MainView.swift / Components.swift (MIT).
// See LICENSES/WhatsApp-Zen-MIT.txt and docs/reference-interface.md.
import SwiftUI

enum WhatsAppFilter: String, CaseIterable {
  case all = "Все", unread = "Непрочитанные", groups = "Группы", archived = "Архив"
}
@MainActor final class WhatsAppWorkspaceNavigationState: ObservableObject {
  @Published var search = ""
  @Published var filter = WhatsAppFilter.all
  func matches(_ chat: WhatsAppChat, search: Bool = true) -> Bool {
    (filter == .archived ? chat.archived : !chat.archived)
      && (filter != .unread || chat.unread > 0) && (filter != .groups || chat.group)
      && (!search || self.search.isEmpty || chat.name.localizedCaseInsensitiveContains(self.search))
  }
}
struct WhatsAppWorkspaceNavigation: View {
  @ObservedObject var model: WhatsAppWorkspaceModel
  @ObservedObject var navigation: WhatsAppWorkspaceNavigationState
  @State private var adding = false
  @State private var statuses = false
  @State private var accountSettings = false
  @State private var newChat = false
  @State private var name = ""
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        MakoshMenu {
          Text(model.isSynthetic ? "Синтетическая проверка · без сети" : model.status.label)
            .font(.caption).foregroundStyle(.secondary)
          ForEach(model.accounts) { account in
            MakoshMenuItem(account.name) { Task { await model.selectAccount(account.id) } }
          }
          Divider()
          MakoshMenuItem("Добавить аккаунт") { adding = true }.disabled(model.isSynthetic)
          MakoshMenuItem("Настройки WhatsApp") { accountSettings = true }
          if !model.isSynthetic, model.selectedAccountID != nil {
            if model.status.state != "logged_out" {
              MakoshMenuItem(model.status.linked ? "Подключено" : "Подключить") { model.connect() }
                .disabled(model.busy || model.status.linked)
            }
            if model.busy || model.status.state != "offline" {
              MakoshMenuItem("Отключить") { Task { await model.disconnect() } }
            }
          }
          #if DEBUG
          if model.isSynthetic {
            MakoshMenuItem("Тестовое окно звонка") { model.calls.preview() }
            MakoshMenuItem("Показать тестовый QR") { Task { await model.previewPairing() } }
          }
          #endif
          Divider()
          MakoshMenuItem("Лицензия ядра") {
            if let url = Bundle.main.resourceURL?.appendingPathComponent("Licenses/WhatsApp-Worker-AGPL-3.0.txt") {
              NSWorkspace.shared.activateFileViewerSelecting([url])
            }
          }
          MakoshMenuItem("Исходники ядра") {
            if let url = Bundle.main.url(forResource: "MakoshWhatsAppWorker-Source", withExtension: "tar.gz") {
              NSWorkspace.shared.activateFileViewerSelecting([url])
            }
          }
        } label: {
          Label(model.accounts.first { $0.id == model.selectedAccountID }?.name ?? "Аккаунт WhatsApp", systemImage: "person.crop.circle")
            .lineLimit(1)
        }.makoshMenuStyle(.bordered).makoshMenuIndicator(.visible)
          .accessibilityIdentifier("whatsapp.account.selector")
        MakoshPicker("Раздел", selection: $navigation.filter) {
          ForEach(WhatsAppFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.labelsHidden().fixedSize().accessibilityIdentifier("whatsapp.workspace.filter")
        HStack(spacing: 10) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField("Поиск чатов", text: $navigation.search).textFieldStyle(.plain)
            .accessibilityIdentifier("whatsapp.search")
          if !navigation.search.isEmpty {
            Button { navigation.search = "" } label: { Image(systemName: "xmark.circle.fill") }
              .buttonStyle(.plain).accessibilityLabel("Очистить поиск чатов")
          }
        }.padding(11).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
          .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)) }
        Button { statuses = true } label: { Image(systemName: "circle.dashed") }
          .buttonStyle(.plain).accessibilityLabel("Статусы WhatsApp").disabled(model.selectedAccountID == nil)
        Button { newChat = true } label: { Label("Новый чат", systemImage: "square.and.pencil") }
          .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.selectedAccountID == nil)
          .accessibilityIdentifier("whatsapp.workspace.newChat")
      }.padding(.horizontal, 20).frame(height: 64)
      if let error = model.notificationError { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal) }
      if let error = model.archiveError { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal) }
    }.background { WorkspaceBackdrop(intensity: 0.5) }.tint(WorkspaceStyle.accent)
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
struct WhatsAppSidebarView: View {
  @ObservedObject var model: WhatsAppWorkspaceModel
  @ObservedObject var navigation: WhatsAppWorkspaceNavigationState
  private var chats: [WhatsAppChat] { model.chats.filter { navigation.matches($0) } }
  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(navigation.filter == .all ? "Чаты" : navigation.filter.rawValue).font(.title2.bold())
        Text("\(chats.count)").font(.callout).foregroundStyle(.secondary)
        Spacer()
      }.padding(.horizontal, 20).frame(height: WorkspaceStyle.mailPaneHeaderHeight)
      Divider()
      if chats.isEmpty {
        ContentUnavailableView(model.accounts.isEmpty ? "Подключите WhatsApp" : "Нет чатов",
          systemImage: "bubble.left.and.bubble.right",
          description: Text(model.accounts.isEmpty ? "Добавьте аккаунт через меню в верхней панели." : "Проверьте выбранный аккаунт, раздел и поиск."))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 4) {
            ForEach(chats) { chat in
              Button { Task { await model.selectChat(chat.id) } } label: {
                WhatsAppChatRow(chat: chat, model: model).padding(12)
                  .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                  .background(model.selectedChatID == chat.id ? WorkspaceStyle.accent.opacity(0.19) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
              }.buttonStyle(.plain).accessibilityIdentifier("whatsapp.chat.\(chat.id)")
                .accessibilityValue(model.selectedChatID == chat.id ? "Выбрано" : "")
            }
          }.padding(10)
        }
      }
      Button { navigation.filter = navigation.filter == .archived ? .all : .archived } label: {
        HStack { Image(systemName: "archivebox"); Text(navigation.filter == .archived ? "Все чаты" : "Архив"); Spacer();
          Text("\(model.chats.filter(\.archived).count)").foregroundStyle(.secondary)
        }.padding(16).contentShape(Rectangle())
      }.buttonStyle(.plain).foregroundStyle(WorkspaceStyle.accent).accessibilityIdentifier("whatsapp.workspace.archive")
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
            ).padding(.vertical, 3).background(WorkspaceStyle.accent, in: Capsule())
          }
        }
      }
    }.tint(WorkspaceStyle.accent)
  }
}
struct WhatsAppAvatar: View {
  let name: String, group: Bool
  var body: some View {
    ZStack {
      Circle().fill(WorkspaceStyle.accent.opacity(0.22))
      if group {
        Image(systemName: "person.2.fill").foregroundStyle(WorkspaceStyle.accent)
      } else {
        Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
          .font(.headline).foregroundStyle(WorkspaceStyle.accent)
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
  @State private var showInfo = true
  @State private var showSearch = false
  @State private var historyFilter = WhatsAppHistoryFilter.all
  @State private var peerInfo: WhatsAppPeerInfo?
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
        HStack(spacing: 0) {
        VStack(spacing: 0) {
          HStack(spacing: 12) {
            WhatsAppAvatarView(name: chat.name, group: chat.group,
              scope: model.selectedAccountID.map { .init(accountID: $0, jid: chat.id) },
              revision: model.status.avatarRevisions?[chat.id] ?? 0, epoch: model.status.avatarEpoch ?? 0,
              worker: model.notificationWorker, cache: model.avatarCache)
            VStack(alignment: .leading) {
              Text(chat.name).font(.title3.bold())
              Text(chat.group ? (peerInfo?.members.map { "\($0.count) участников" } ?? "Групповой чат") : model.status.label)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
              if showSearch || history.active { showSearch = false; history.clear(); historyFilter = .all }
              else { showSearch = true }
            } label: { Image(systemName: "magnifyingglass") }
              .help("Поиск в переписке").accessibilityLabel("Поиск в переписке")
              .accessibilityIdentifier("whatsapp.history.searchToggle")
            Button { showInfo.toggle() } label: { Image(systemName: "sidebar.right") }
              .help("Сведения о чате").accessibilityLabel("Сведения о чате")
              .accessibilityIdentifier("whatsapp.chat.infoToggle")
            MakoshMenu {
              MakoshMenuItem("Настройки чата") { settings = true }
              MakoshMenuItem("Обновить историю") { Task { await model.selectChat(chat.id) } }
              MakoshMenuItem("Загрузить более ранние сообщения") { Task { await model.loadOlder() } }
                .disabled(!model.hasOlder || model.historyBusy)
              Divider()
              MakoshMenuItem("Постоянный архив и экспорт") {
                archivedMessage = nil
                archive = true
              }
              MakoshMenuItem(chat.archived ? "Вернуть из архива" : "Архивировать") {
                command(.init(.archive, on: !chat.archived))
              }
              MakoshMenuItem(chat.pinned ? "Открепить чат" : "Закрепить чат") {
                command(.init(.pinChat, on: !chat.pinned))
              }
              MakoshMenuItem("Прочитано") { command(.init(.read)) }
              MakoshMenuItem("Отключить звук") { command(.init(.mute, duration: -1)) }
              MakoshMenuItem("Включить звук") { command(.init(.mute, duration: 0)) }
            } label: {
              Image(systemName: "ellipsis")
            }.makoshMenuStyle(.plain).accessibilityLabel("Действия чата").accessibilityIdentifier("whatsapp.chat.actions")
          }.buttonStyle(.plain).padding(.horizontal, 16).frame(height: WorkspaceStyle.mailPaneHeaderHeight)
          Divider()
          if showSearch || history.active { WhatsAppSearchBar(history: history, filter: $historyFilter) }
          if displayed.isEmpty {
            ContentUnavailableView(
              history.active ? "Ничего не найдено" : "В этом чате пока нет сообщений", systemImage: "bubble.left",
              description: Text(history.active ? "Измените запрос или фильтр поиска." : "Полученная история сохраняется и доступна офлайн.")
            ).frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            ScrollView {
              let chronological = Array(displayed.reversed())
              LazyVStack(spacing: 8) {
                ForEach(Array(chronological.enumerated()), id: \.element.id) { index, message in
                  if index == 0 || !Calendar.current.isDate(
                    Date(timeIntervalSince1970: TimeInterval(message.timestamp)),
                    inSameDayAs: Date(timeIntervalSince1970: TimeInterval(chronological[index - 1].timestamp))) {
                    Text(Date(timeIntervalSince1970: TimeInterval(message.timestamp)), style: .date)
                      .font(.caption2).foregroundStyle(.secondary).padding(.vertical, 12)
                  }
                  WhatsAppMessageRow(
                    message: message,
                    senderTitle: chat.group && !message.outgoing && !message.sender.isEmpty
                      ? (model.chats.first { $0.id.utf8.elementsEqual(message.sender.utf8) }?.name ?? message.sender) : nil,
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
                    MakoshMenu("Реакция") {
                      ForEach(["👍", "❤️", "😂", "😮", "😢", "🙏", ""], id: \.self) { emoji in
                        MakoshMenuItem(emoji.isEmpty ? "Убрать реакцию" : emoji) {
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
            }.defaultScrollAnchor(.bottom).defaultScrollAnchor(.top, for: .alignment).accessibilityIdentifier("whatsapp.history")
          }
          if history.active, history.hasMore {
            Button("Продолжить поиск") { Task { await history.loadMore() } }.disabled(history.busy)
          }
          WhatsAppComposeView(
            model: model.composer, accountID: sourceAccount, chatID: sourceChat,
            rich: { richCompose = true })
        }.frame(minWidth: 380, maxWidth: .infinity).background { WorkspaceBackdrop(intensity: 0.3) }
        if showInfo, let sourceAccount {
          WhatsAppWorkspaceInfo(model: model, accountID: sourceAccount, chat: chat,
            info: $peerInfo, close: { showInfo = false }, settings: { settings = true }, dossier: dossier,
            media: { showSearch = true; historyFilter = .media })
            .frame(width: 264).background { WorkspaceBackdrop(intensity: 0.55) }
        }
        }
      } else {
        ContentUnavailableView(
          "Выберите чат", systemImage: "bubble.left.and.bubble.right",
          description: Text("Переписка выбранного аккаунта откроется здесь."))
      }
    }.tint(WorkspaceStyle.accent)
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
  var senderTitle: String? = nil
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
          if let senderTitle {
            Text(senderTitle).font(.caption.weight(.semibold)).foregroundStyle(WorkspaceStyle.accent)
              .lineLimit(1).truncationMode(.middle)
          }
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
              ? WorkspaceStyle.outgoing
              : WorkspaceStyle.surface,
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
        colors: [WorkspaceStyle.accent.opacity(0.18), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
  }
  private func step(_ number: Int, _ title: String) -> some View {
    HStack(spacing: 10) {
      Text("\(number)").font(.callout.bold()).foregroundStyle(.white).frame(width: 24, height: 24)
        .background(WorkspaceStyle.accent, in: Circle())
      Text(title).font(.title3)
    }
  }
}
