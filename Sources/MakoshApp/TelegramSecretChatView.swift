import SwiftUI
import MakoshTelegram

struct TelegramSecretCreationView: View {
    @ObservedObject var controller: TelegramSecretChatController
    let synthetic: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Начать секретный чат").font(.title2.weight(.semibold))
            if let basis = controller.creationBasis {
                Text("Создать секретный чат с \(basis.title)?").font(.headline)
                    .accessibilityIdentifier("telegram.secret.create.destination")
                Text("Этот чат будет доступен на устройствах, где создан его сеанс. Дождитесь подключения собеседника и сравните ключ шифрования.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if basis.existingSecretID != nil {
                    Text("С этим собеседником уже есть секретный чат. Продолжение создаст отдельный новый сеанс.").font(.callout)
                }
                if basis.premiumRequired { Text("Для начала чата с этим собеседником требуется Telegram Premium.") }
                Button("Начать") { _ = controller.create(basis: basis, contextID: controller.creationContextID) }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.creationStatus != .ready || !basis.canCreate || controller.isCreating || controller.creationPhase == .uncertain)
                    .accessibilityIdentifier("telegram.secret.create.confirm")
            }
            if controller.creationStatus == .loading || controller.isCreating { ProgressView("Подготовка секретного чата…") }
            if controller.creationPhase == .validating {
                Button("Отменить подготовку", action: controller.cancelCreationValidation)
                    .accessibilityIdentifier("telegram.secret.create.cancelValidation")
            }
            if let status = creationStatus {
                Text(status).foregroundStyle(.secondary).accessibilityIdentifier("telegram.secret.create.status")
            }
            Button("Обновить", action: controller.refreshCreation).disabled(controller.isCreating)
                .accessibilityIdentifier("telegram.secret.create.refresh")
            if synthetic { Text("Синтетическая проверка. Запрос в Telegram не отправляется.").font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var creationStatus: String? {
        switch controller.creationPhase {
        case .uncertain: return "Результат создания неизвестен. Обновите состояние и проверьте список чатов перед новой попыткой."
        case .changed: return "Сведения о собеседнике изменились. Обновите карточку."
        case .failed: return "Не удалось создать секретный чат."
        case .limitExceeded: return "Telegram временно ограничил создание секретных чатов."
        case .premiumRequired: return "Telegram требует Premium для этого собеседника."
        case .created: return "Секретный чат создан. Ожидание подключения собеседника."
        default: return controller.creationStatus == .failed || controller.creationStatus == .timedOut ? "Сведения о собеседнике недоступны. Повторите обновление." : nil
        }
    }
}

struct TelegramSecretTimerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: TelegramSecretChatController
    let synthetic: Bool
    @State private var selected: Int32 = 0
    @State private var custom = ""
    @State private var confirmation: Confirmation?
    private struct Confirmation: Identifiable {
        let id = UUID()
        let basis: TelegramSecretSessionSnapshot
        let context: UUID
        let timeout: Int32?
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Таймер секретного чата").font(.headline); Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("telegram.secret.timer.close")
            }
            if let session = controller.session {
                Text(session.title).font(.title2)
                LabeledContent("Текущий таймер", value: timerName(session.ttl))
                    .accessibilityIdentifier("telegram.secret.timer.current")
                Picker("Удалять после прочтения", selection: $selected) {
                    ForEach([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 30, 60, 3600, 86400, 604800], id: \.self) { value in
                        Text(timerName(value == 0 ? nil : Int32(value))).tag(Int32(value))
                    }
                    Text("Другое значение…").tag(Int32(-1))
                }.accessibilityIdentifier("telegram.secret.timer.selection")
                    .disabled(!session.canSetTTL || controller.isSettingTTL)
                if selected == -1 {
                    TextField("Секунды", text: $custom).accessibilityIdentifier("telegram.secret.timer.custom")
                        .disabled(controller.isSettingTTL)
                }
                Text("Telegram удаляет сообщения по этому таймеру. Уже наблюдавшиеся сообщения и версии сохраняются в архиве Макоша; копирование файлов в S3 зависит от флага чата.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Изменить таймер") {
                    confirmation = .init(basis: session, context: controller.sessionContextID, timeout: timeout)
                }.buttonStyle(.borderedProminent).disabled(!validChoice || !controller.canSetTTL(timeout))
                    .accessibilityIdentifier("telegram.secret.timer.apply")
            }
            if controller.isSettingTTL || controller.sessionStatus == .loading { ProgressView("Проверка состояния…") }
            if controller.ttlPhase == .validating {
                Button("Отменить подготовку", action: controller.cancelTTLValidation)
            }
            if let status = status {
                Text(status).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("telegram.secret.timer.status")
            }
            Button("Обновить", action: controller.refreshSession).disabled(controller.isSettingTTL)
                .accessibilityIdentifier("telegram.secret.timer.refresh")
            if synthetic { Text("Синтетическая проверка. Сообщение в Telegram не отправляется.").font(.caption).foregroundStyle(.secondary) }
        }.padding(24).frame(width: 470)
            .onAppear {
                let current = controller.session?.ttl ?? 0
                if [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 30, 60, 3600, 86400, 604800].contains(current) { selected = current }
                else { selected = -1; custom = String(current) }
            }
            .confirmationDialog("Изменить таймер?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), presenting: confirmation) { value in
                Button("Подтвердить") { _ = controller.setTTL(value.timeout, basis: value.basis, contextID: value.context); confirmation = nil }
                Button("Отмена", role: .cancel) { confirmation = nil }
            } message: { value in Text("\(value.basis.title): \(timerName(value.basis.ttl)) → \(timerName(value.timeout))") }
    }
    private var timeout: Int32? { selected == 0 ? nil : selected == -1 ? Int32(custom) : selected }
    private var validChoice: Bool { selected == 0 || (timeout.map { $0 > 0 } ?? false) }
    private func timerName(_ value: Int32?) -> String { value.map { "\($0) с" } ?? "Выключен" }
    private var status: String? {
        switch controller.ttlPhase {
        case .queued: return "Изменение таймера поставлено в очередь. Доставка собеседнику ещё не подтверждена."
        case .uncertain: return "Результат неизвестен. Обновите состояние; повторная отправка автоматически не выполняется."
        case .changed: return "Состояние чата изменилось. Обновите таймер перед новой попыткой."
        case .failed: return "Изменить таймер не удалось."
        default: return controller.sessionStatus == .failed || controller.sessionStatus == .timedOut ? "Состояние секретного чата недоступно." : nil
        }
    }
}
