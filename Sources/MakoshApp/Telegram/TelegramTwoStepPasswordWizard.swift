import SwiftUI
import MakoshTelegram

struct TelegramTwoStepPasswordWizard: View {
    @ObservedObject var controller: TelegramTwoStepController
    let proposal: TelegramTwoStepProposal
    let synthetic: Bool
    let close: () -> Void
    @State private var draft: TelegramTwoStepPasswordDraft
    @State private var validation = ""
    @State private var skipConfirmation = false
    @State private var saveInput: TelegramTwoStepInput?
    @FocusState private var focus: TelegramTwoStepPasswordDraft.Stage?
    init(controller: TelegramTwoStepController,proposal: TelegramTwoStepProposal,synthetic: Bool,close: @escaping () -> Void) {
        self.controller = controller; self.proposal = proposal; self.synthetic = synthetic; self.close = close
        _draft = State(initialValue: .init(kind: proposal.kind))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if draft.stage != .password { Button("Назад") { draft.back(); validation = "" }.accessibilityIdentifier("telegram.twoStep.wizard.back") }
                Spacer(); Text(proposal.kind == .setPassword ? "Установка пароля" : "Изменение пароля").font(.headline); Spacer()
                Button("Отмена") { clear(); close() }.accessibilityIdentifier("telegram.twoStep.wizard.cancel")
            }.padding(16)
            Divider()
            if synthetic { Text("Синтетический аккаунт · операции симулируются").font(.caption).foregroundStyle(.secondary).padding(12) }
            Form {
                Section {
                    switch draft.stage {
                    case .password:
                        Text("Придумайте дополнительный пароль для входа в Telegram.")
                        SecureField("Новый пароль",text: $draft.password).focused($focus,equals: .password).onSubmit(advance).accessibilityIdentifier("telegram.twoStep.wizard.password")
                    case .confirmation:
                        Text("Введите пароль ещё раз.")
                        SecureField("Повторите пароль",text: $draft.confirmation).focused($focus,equals: .confirmation).onSubmit(advance).accessibilityIdentifier("telegram.twoStep.wizard.confirmation")
                    case .hint:
                        Text("Добавьте подсказку, которая поможет вспомнить пароль.")
                        TextField("Подсказка (необязательно)",text: $draft.hint).focused($focus,equals: .hint).onSubmit(advance).accessibilityIdentifier("telegram.twoStep.wizard.hint")
                    case .email:
                        Text("Добавьте почту, чтобы восстановить доступ, если забудете пароль.")
                        TextField("Почта восстановления",text: $draft.email).focused($focus,equals: .email).onSubmit(advance).accessibilityIdentifier("telegram.twoStep.wizard.email")
                        Button("Пропустить почту") { skipConfirmation = true }.disabled(!draft.email.isEmpty).accessibilityIdentifier("telegram.twoStep.wizard.skipEmail")
                    case .review:
                        Text("Пароль введён и подтверждён")
                        if !draft.hint.isEmpty { Text("Подсказка: \(draft.hint)") }
                        if proposal.kind == .changePassword { Text("Почта восстановления сохранится.") }
                        else { Text(draft.email.isEmpty ? "Почта восстановления не указана" : "Почта: \(draft.email)") }
                    }
                    if !validation.isEmpty { Text(validation).foregroundStyle(.red).font(.caption).accessibilityIdentifier("telegram.twoStep.wizard.validation") }
                }
                Section {
                    if draft.stage == .review {
                        Button("Сохранить") { saveInput = draft.input }.disabled(draft.input == nil || controller.proposal(proposal.kind) != proposal).accessibilityIdentifier("telegram.twoStep.wizard.save")
                    } else {
                        Button("Далее",action: advance).keyboardShortcut(.defaultAction).accessibilityIdentifier("telegram.twoStep.wizard.next")
                    }
                }
            }.formStyle(.grouped)
        }.frame(width: 500,height: 440)
        .task(id: draft.stage) {
            // Focus after the replacement field has entered the native view tree.
            await Task.yield()
            guard !Task.isCancelled else { return }
            focus = draft.stage
        }
        .onChange(of: controller.contextID) { _, _ in clear(); close() }
        .onDisappear(perform: clear)
        .alert("Продолжить без почты?",isPresented: $skipConfirmation) {
            Button("Отмена",role: .cancel) {}
            Button("Пропустить") { if !draft.advance(skipEmail: true) { validation = "Проверьте введённые данные." } }
        } message: { Text("Без почты восстановление забытого пароля может потребовать ожидания сброса в Telegram.") }
        .alert("Сохранить пароль?",isPresented: Binding(get: { saveInput != nil },set: { if !$0 { saveInput = nil } }),presenting: saveInput) { input in
            Button("Отмена",role: .cancel) { saveInput = nil }
            Button("Сохранить") {
                let accepted = controller.perform(proposal,input: input)
                clear()
                if accepted { close() } else { validation = "Настройки изменились. Откройте форму заново." }
            }
        } message: { _ in Text((synthetic ? "Симуляция. " : "") + (proposal.kind == .changePassword ? "Telegram получит новый пароль. Подтверждённая почта сохранится." : "Telegram получит новый пароль. Если указана почта, её потребуется подтвердить кодом из письма.")) }
    }
    private func advance() {
        let stage = draft.stage
        if draft.advance() { validation = "" }
        else {
            switch stage {
            case .password: validation = "Введите пароль длиной не более 1024 байт."
            case .confirmation: validation = "Пароли не совпадают."
            case .hint: validation = "Подсказка не должна повторять пароль и должна быть не длиннее 256 байт."
            case .email: validation = "Введите корректную почту или явно пропустите этот шаг."
            case .review: break
            }
        }
    }
    private func clear() { draft.clear(); saveInput = nil; skipConfirmation = false; focus = nil; validation = "" }
}
