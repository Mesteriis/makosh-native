import SwiftUI
import MakoshTelegram

struct TelegramSidebarView: View {
    @ObservedObject var model: TelegramModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Telegram", systemImage: "paperplane").font(.title2.bold())
                Text(model.connectionDescription).font(.caption).foregroundStyle(.secondary)
                Text("Неофициальный канал Макош").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            if model.chats.isEmpty {
                ContentUnavailableView("Нет загруженных диалогов", systemImage: "bubble.left.and.bubble.right", description: Text("Диалоги появятся после подключения вашего отдельного сеанса.")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedChatID) {
                    ForEach(model.chats) { chat in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "bubble.left").foregroundStyle(.secondary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(chat.title).font(.headline).lineLimit(1); Spacer(); if chat.unreadCount > 0 { Text("\(chat.unreadCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) } }
                                Text(chat.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }.padding(.vertical, 7).tag(chat.id).accessibilityIdentifier("telegram.chat.\(chat.id)")
                    }
                }.listStyle(.inset).accessibilityIdentifier("telegram.chats")
            }
            Divider()
            Button("Остановить подключение") { model.disconnect() }
                .help("Останавливает локальное подключение и сохраняет кэш. Не завершает сеанс на серверах Telegram.")
                .accessibilityIdentifier("telegram.disconnect").padding(16)
        }.frame(maxHeight: .infinity, alignment: .top)
    }
}

struct TelegramDetailView: View {
    @ObservedObject var model: TelegramModel
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
            if let error = model.error {
                HStack(alignment: .top) { Image(systemName: "exclamationmark.circle"); Text(error).textSelection(.enabled); Spacer(); Button { model.error = nil } label: { Image(systemName: "xmark") }.help("Закрыть сообщение") }
                    .font(.callout).padding(16).background(.red.opacity(0.08)).accessibilityIdentifier("telegram.error")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
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
        if let chatID = model.selectedChatID, let chat = model.chats.first(where: { $0.id == chatID }) {
            VStack(spacing: 0) {
                HStack { VStack(alignment: .leading, spacing: 4) { Text(chat.title).font(.title2.bold()); Text(model.connectionDescription).font(.caption).foregroundStyle(.secondary) }; Spacer() }.padding(20)
                Divider()
                if model.messages.isEmpty {
                    ContentUnavailableView("Сообщений пока нет", systemImage: "text.bubble", description: Text("История этого диалога ещё не загружена или пуста.")).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(model.messages) { item in
                                HStack(alignment: .top) {
                                    if item.isOutgoing { Spacer(minLength: 44) }
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(item.author).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        Text(item.text.isEmpty ? "Вложение или служебное сообщение" : item.text).textSelection(.enabled)
                                        Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                                        if !item.delivery.isEmpty { Text(item.delivery).font(.caption).foregroundStyle(.secondary) }
                                    }.padding(14).background(item.isOutgoing ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                    if !item.isOutgoing { Spacer(minLength: 44) }
                                }.accessibilityIdentifier("telegram.message.\(item.id)")
                            }
                        }.padding(22)
                    }.accessibilityIdentifier("telegram.messages")
                }
                Divider()
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("Сообщение в Telegram", text: $model.draft, axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder).accessibilityIdentifier("telegram.composer")
                    Button("Отправить") { _ = model.sendMessage(model.draft) }.buttonStyle(.borderedProminent).disabled(model.isBusy || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("telegram.send")
                }.padding(16)
                Text("Кнопка отправляет сообщение в выбранный диалог Telegram.").font(.caption).foregroundStyle(.secondary).padding(.bottom, 12)
            }
        } else {
            ContentUnavailableView("Выберите диалог", systemImage: "bubble.left.and.bubble.right", description: Text("Здесь будет история выбранного диалога Telegram.")).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
