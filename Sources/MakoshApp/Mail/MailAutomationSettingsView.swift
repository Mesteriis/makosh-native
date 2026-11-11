import SwiftUI
import MakoshMail

/// MMail Settings sections within Makosh's existing native workspace.
struct MailAutomationSettingsView: View {
    @ObservedObject var model: MailWorkspaceModel
    var embedded = false
    var page: Int?
    /// Owned by the page that hosts this view, so switching its tabs keeps unsaved drafts.
    @Binding var draft: MailAutomationDraft
    private let ruleLabelWidth: CGFloat = 80
    private var activeSection: Int { page ?? section }
    @Environment(\.dismiss) private var dismiss
    @State private var section = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !embedded {
                HStack {
                    Text("Настройки почты").font(.title2.bold())
                    Spacer()
                    Button("Закрыть") { dismiss() }
                }
            }
            MakoshPicker("Аккаунт", selection: $draft.accountID) { ForEach(model.accounts) { Text($0.email).tag($0.id) } }
                .frame(maxWidth: 360, alignment: .leading)
            if page == nil {
                WorkspaceSegmentedPicker("Раздел", selection: $section) {
                    Text("Подпись").tag(0)
                    Text("Шаблоны").tag(1)
                    Text("Правила").tag(2)
                }.accessibilityIdentifier("mail.automation.section")
            }
            ScrollView {
                if activeSection == 0 {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Подпись добавляется к новым письмам и ответам.").font(.callout).foregroundStyle(.secondary)
                        TextEditor(text: $draft.signature).workspaceEditorSurface().frame(height: 150).accessibilityIdentifier(
                            "mail.signature")
                        HStack {
                            Spacer()
                            Button("Сохранить подпись") {
                                Task { await model.setSignature(accountID: draft.accountID, text: draft.signature) }
                            }
                            .buttonStyle(WorkspaceButtonStyle(prominent: true))
                            .disabled(draft.accountID.isEmpty || model.busy)
                        }
                    }
                    .padding(WorkspaceStyle.cardInset)
                    .background { WorkspaceSurface(radius: WorkspaceStyle.cardRadius) }
                } else if activeSection == 1 {
                    VStack(alignment: .leading) {
                        if model.automation.templates.isEmpty {
                            Text("Шаблонов пока нет. Создайте первый ниже.").font(.callout).foregroundStyle(.secondary)
                        } else {
                            savedRows(model.automation.templates) { template in
                                HStack {
                                    Button(template.name) {
                                        draft.templateID = template.id
                                        draft.templateName = template.name
                                        draft.templateBody = template.body
                                    }.buttonStyle(.plain)
                                    Spacer()
                                    Button("Удалить", role: .destructive) { Task { await model.deleteTemplate(template.id) } }
                                }
                            }
                        }
                        Text("Название").font(.caption).foregroundStyle(.secondary)
                        TextField("Название шаблона", text: $draft.templateName).accessibilityIdentifier("mail.template.name")
                        Text("Текст шаблона").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $draft.templateBody).workspaceEditorSurface().frame(height: 150).accessibilityIdentifier(
                            "mail.template.body")
                        HStack {
                            Button("Новый") {
                                draft.templateID = UUID()
                                draft.templateName = ""
                                draft.templateBody = ""
                            }
                            Spacer()
                            Button("Сохранить шаблон") {
                                Task {
                                    await model.saveTemplate(
                                        .init(id: draft.templateID, name: draft.templateName, body: draft.templateBody))
                                }
                            }.buttonStyle(WorkspaceButtonStyle(prominent: true)).disabled(
                                draft.templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                        }
                    }.padding(WorkspaceStyle.cardInset)
                        .background { WorkspaceSurface(radius: WorkspaceStyle.cardRadius) }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(
                            "Для новых входящих после начальной синхронизации. Корзина имеет приоритет над архивом. Сохранённая копия остаётся."
                        ).font(.caption).foregroundStyle(.secondary)
                        let rules = model.automation.rules.filter { $0.accountID == draft.accountID }
                        if !rules.isEmpty {
                            savedRows(rules) { rule in
                                HStack {
                                    Toggle(
                                        isOn: Binding(
                                            get: { rule.enabled },
                                            set: { on in
                                                var changed = rule
                                                changed.enabled = on
                                                Task { await model.saveIncomingRule(changed) }
                                            })
                                    ) {
                                        Text(
                                            "\(rule.field == .from ? "Отправитель" : "Тема") содержит «\(rule.value)» → \(actionTitle(rule.action))\(rule.label.map { ": " + $0 } ?? "")"
                                        )
                                    }
                                    Button("Удалить", role: .destructive) { Task { await model.deleteIncomingRule(rule.id) } }
                                }
                            }
                        } else {
                            Text("Правил для этого аккаунта пока нет.").font(.callout).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Условие").frame(width: ruleLabelWidth, alignment: .leading)
                            MakoshPicker("Поле", selection: $draft.field) {
                                Text("Отправитель").tag(MailIncomingRule.Field.from)
                                Text("Тема").tag(MailIncomingRule.Field.subject)
                            }
                            .labelsHidden().fixedSize(horizontal: true, vertical: false)
                            TextField("Содержит", text: $draft.match)
                        }
                        HStack {
                            Text("Действие").frame(width: ruleLabelWidth, alignment: .leading)
                            MakoshPicker("Действие", selection: $draft.action) {
                                ForEach(MailIncomingRule.Action.allCases, id: \.self) { Text(actionTitle($0)).tag($0) }
                            }.labelsHidden().fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 0)
                        }
                        if draft.action == .label { TextField("Локальная метка", text: $draft.label) }
                        Button("Добавить правило") {
                            Task {
                                await model.saveIncomingRule(
                                    .init(
                                        accountID: draft.accountID, field: draft.field, value: draft.match, action: draft.action,
                                        label: draft.action == .label ? draft.label : nil))
                            }
                        }.disabled(
                            draft.accountID.isEmpty || draft.match.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                    }.padding(WorkspaceStyle.cardInset)
                        .background { WorkspaceSurface(radius: WorkspaceStyle.cardRadius) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(.horizontal, 24).padding(.bottom, 24).padding(.top, embedded ? 4 : 24).frame(
            minWidth: 600, maxWidth: embedded ? 760 : 680, minHeight: 500, maxHeight: embedded ? .infinity : 560, alignment: .topLeading
        )
        .onAppear {
            // A later appearance keeps the drafts; only the first one picks the account.
            guard draft.accountID.isEmpty else { return }
            draft.accountID = model.selectedFolder?.accountID ?? model.accounts.first?.id ?? ""
            loadSignature()
        }
        .onChange(of: draft.accountID) { loadSignature() }
    }
    @ViewBuilder private func savedRows<Item: Identifiable, Row: View>(
        _ items: [Item], @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        let rows = LazyVStack(alignment: .leading, spacing: 8) { ForEach(items, content: row) }
        if items.count > 4 {
            ScrollView { rows }.frame(height: 160)
        } else {
            rows
        }
    }
    private func loadSignature() { draft.signature = model.automation.signatures[draft.accountID] ?? "" }
    private func actionTitle(_ value: MailIncomingRule.Action) -> String {
        switch value {
        case .archive: "Архив"
        case .trash: "Корзина"
        case .label: "Метка"
        }
    }
}

/// Unsaved signature, template and rule drafts of the mail settings page.
struct MailAutomationDraft {
    var accountID = ""
    var signature = ""
    var templateID = UUID()
    var templateName = ""
    var templateBody = ""
    var field = MailIncomingRule.Field.from
    var match = ""
    var action = MailIncomingRule.Action.archive
    var label = ""
}
