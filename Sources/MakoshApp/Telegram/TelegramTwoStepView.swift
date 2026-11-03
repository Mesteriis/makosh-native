import SwiftUI
import MakoshTelegram

private struct TwoStepConfirmation {
    let proposal: TelegramTwoStepProposal
    let input: TelegramTwoStepInput
    let title: String
    let detail: String
    let destructive: Bool
}
struct TwoStepPasswordRequest: Identifiable {
    let id = UUID()
    let proposal: TelegramTwoStepProposal
}

struct TelegramTwoStepView: View {
    @ObservedObject var controller: TelegramTwoStepController
    let synthetic: Bool
    let close: () -> Void
    @State private var password = ""
    @State private var email = ""
    @State private var code = ""
    @State private var confirmation: TwoStepConfirmation?
    @State private var wizard: TwoStepPasswordRequest?
    @State private var invalidInput = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Двухэтапная аутентификация").font(.headline)
                Spacer()
                Button("Готово", action: close).accessibilityIdentifier("telegram.twoStep.close")
            }.padding(16)
            Divider()
            HStack {
                Text(statusText).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("telegram.twoStep.status")
                Spacer()
                if controller.isWorking { ProgressView().controlSize(.small) }
                Button("Обновить", action: controller.refresh).disabled(controller.isWorking).accessibilityIdentifier("telegram.twoStep.refresh")
            }.padding(16)
            if synthetic { Text("Синтетический аккаунт · операции симулируются").font(.caption).foregroundStyle(.secondary).padding(.horizontal,16) }
            if let state = controller.snapshot {
                Form {
                    Section {
                        Text(state.enabled ? "Пароль включён" : "Пароль не установлен").font(.headline)
                        Text("Дополнительный пароль защищает вход в Telegram на новых устройствах.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let pattern = controller.recoveryPattern {
                        Section("Восстановление пароля") {
                            Text("Код отправлен на \(pattern)")
                            codeField
                            action(.recover, "Восстановить доступ", input: .init(code: code),
                                   detail: "Текущий пароль будет удалён." + secureWarning(state), destructive: true, valid: !code.isEmpty)
                            Button("Назад", action: controller.refresh).disabled(controller.isWorking).accessibilityIdentifier("telegram.twoStep.recoveryBack")
                        }
                    } else {
                        if let pending = state.pendingEmail {
                            Section("Подтверждение почты") {
                                Text("Введите код, отправленный на \(pending)")
                                codeField
                                action(.confirmEmail,"Подтвердить почту",input: .init(code: code),detail: "Адрес будет подтверждён кодом из письма.",valid: !code.isEmpty)
                                action(.resendEmail,"Отправить код ещё раз",detail: "Telegram отправит новое письмо с кодом.")
                                action(.cancelEmail,"Отменить подтверждение",detail: state.enabled ? "Неподтверждённый адрес будет отменён. Ранее подтверждённая почта сохранится." : "Установка пароля с этим адресом будет отменена.",destructive: true)
                            }
                        }
                        if state.enabled {
                            if controller.isUnlocked { management(state) }
                            else {
                                Section("Текущий пароль") {
                                    SecureField("Пароль",text: $password).accessibilityIdentifier("telegram.twoStep.currentPassword")
                                        .disabled(controller.isWorking || controller.isUncertain)
                                        .onSubmit(verify)
                                    if !state.hint.isEmpty { Text("Подсказка: \(state.hint)").font(.caption).foregroundStyle(.secondary) }
                                    Button("Продолжить",action: verify).disabled(password.isEmpty || controller.proposal(.unlock) == nil)
                                        .accessibilityIdentifier("telegram.twoStep.unlock")
                                }
                                Section("Забыли пароль?") {
                                    if state.hasRecoveryEmail {
                                        action(.requestRecovery,"Получить код восстановления",detail: "Telegram отправит код на подтверждённую почту восстановления.")
                                    }
                                    resetActions(state)
                                }
                            }
                        } else if state.pendingEmail == nil {
                            Section {
                                Button("Установить пароль") { openWizard(.setPassword) }.disabled(controller.proposal(.setPassword) == nil)
                                    .accessibilityIdentifier("telegram.twoStep.setPassword")
                            }
                        }
                    }
                }.formStyle(.grouped)
            } else if controller.status == .loading { Spacer(); ProgressView("Загружаем настройки…"); Spacer() }
            else { ContentUnavailableView("Настройки недоступны",systemImage: "lock",description: Text("Повторите загрузку для выбранного аккаунта Telegram.")) }
        }.frame(width: 540,height: 650)
        .onAppear { controller.open() }
        .onDisappear { clearInputs(); controller.close() }
        .onChange(of: controller.contextID) { _, _ in clearInputs(); wizard = nil }
        .sheet(item: $wizard) { request in
            TelegramTwoStepPasswordWizard(controller: controller,proposal: request.proposal,synthetic: synthetic) { wizard = nil }
        }
        .alert(confirmation?.title ?? "Подтвердить действие?",isPresented: Binding(get: { confirmation != nil },set: { if !$0 { confirmation = nil } }),presenting: confirmation) { request in
            Button("Отмена",role: .cancel) { confirmation = nil }
            Button("Подтвердить",role: request.destructive ? .destructive : nil) {
                invalidInput = !controller.perform(request.proposal,input: request.input)
                password = ""; email = ""; code = ""; confirmation = nil
            }
        } message: { request in Text((synthetic ? "Симуляция. " : "") + request.detail) }
    }
    private var statusText: String {
        if invalidInput { return "Проверьте введённые данные и актуальность настроек." }
        if controller.status == .failed || controller.status == .timedOut { return "Не удалось обновить настройки. Повторите загрузку." }
        return controller.feedback.isEmpty ? "Настройки выбранного аккаунта Telegram" : controller.feedback
    }
    private var codeField: some View {
        TextField("Код из письма",text: $code).accessibilityIdentifier("telegram.twoStep.code").disabled(controller.isWorking || controller.isUncertain)
    }
    private func management(_ state: TelegramTwoStepSnapshot) -> some View {
        Section("Пароль подтверждён") {
            if let email = controller.recoveryEmail, !email.isEmpty { Text("Почта восстановления: \(email)") }
            else { Text("Почта восстановления не установлена").foregroundStyle(.secondary) }
            Button("Изменить пароль") { openWizard(.changePassword) }.disabled(controller.proposal(.changePassword) == nil).accessibilityIdentifier("telegram.twoStep.changePassword")
            TextField("Новая почта восстановления",text: $email).accessibilityIdentifier("telegram.twoStep.email")
            action(.changeEmail,"Изменить почту",input: .init(email: email),detail: "На новый адрес будет отправлен код подтверждения.",valid: !email.isEmpty)
            action(.disable,"Отключить пароль",detail: "Дополнительный пароль больше не будет защищать вход в Telegram." + secureWarning(state),destructive: true)
            if state.resetAt != nil { resetActions(state) }
        }
    }
    @ViewBuilder private func resetActions(_ state: TelegramTwoStepSnapshot) -> some View {
        if let date = state.resetAt {
            Text("Сброс доступен после \(Date(timeIntervalSince1970: TimeInterval(date)).formatted(date: .abbreviated,time: .shortened))").font(.caption).foregroundStyle(.secondary)
            action(.declineReset,"Отменить сброс",detail: "Запрос на сброс пароля будет отменён.")
            TimelineView(.periodic(from: .now,by: 1)) { timeline in
                action(.requestReset,"Завершить сброс",detail: "Текущий пароль будет удалён, если назначенное Telegram время ожидания истекло." + secureWarning(state),destructive: true,
                       valid: timeline.date.timeIntervalSince1970 >= TimeInterval(date))
            }
        } else {
            action(.requestReset,"Запросить сброс пароля",detail: "Используйте, если не можете восстановить доступ по почте. Telegram может назначить время ожидания. После сброса текущий пароль будет удалён." + secureWarning(state),destructive: true)
        }
    }
    private func secureWarning(_ state: TelegramTwoStepSnapshot) -> String {
        (state.hasSecureValues ? " Защищённые данные Telegram Passport могут быть потеряны." : "") + " Архив переписки в Макоше сохраняется."
    }
    private func action(_ kind: TelegramTwoStepKind,_ title: String,input: TelegramTwoStepInput = .init(),detail: String,destructive: Bool = false,valid: Bool = true) -> some View {
        Button(title,role: destructive ? .destructive : nil) {
            guard let proposal = controller.proposal(kind) else { invalidInput = true; return }
            invalidInput = false; confirmation = .init(proposal: proposal,input: input,title: title + "?",detail: detail,destructive: destructive)
        }.disabled(!valid || controller.proposal(kind) == nil).accessibilityIdentifier("telegram.twoStep.\(kind.rawValue)")
    }
    private func openWizard(_ kind: TelegramTwoStepKind) {
        guard let proposal = controller.proposal(kind) else { return }
        password = ""; email = ""; code = ""; wizard = .init(proposal: proposal)
    }
    private func verify() {
        guard let proposal = controller.proposal(.unlock) else { return }
        let input = TelegramTwoStepInput(password: password); password = ""
        invalidInput = !controller.perform(proposal,input: input)
    }
    private func clearInputs() { password = ""; email = ""; code = ""; confirmation = nil; invalidInput = false }
}
