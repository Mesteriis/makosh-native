import SwiftUI
import MakoshMail

/// MMail Settings sections within Makosh's existing native workspace.
struct MailAutomationSettingsView: View {
    @ObservedObject var model: MailWorkspaceModel
    var embedded = false
    var page: Int?
    private let ruleLabelWidth: CGFloat = 80
    private var activeSection: Int { page ?? section }
    @Environment(\.dismiss) private var dismiss
    @State private var accountID = ""
    @State private var section = 0
    @State private var signature = ""
    @State private var templateID = UUID()
    @State private var templateName = ""
    @State private var templateBody = ""
    @State private var field = MailIncomingRule.Field.from
    @State private var match = ""
    @State private var action = MailIncomingRule.Action.archive
    @State private var label = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !embedded {
                HStack {
                    Text("Настройки почты").font(.title2.bold())
                    Spacer()
                    Button("Закрыть") { dismiss() }
                }
            }
            MakoshPicker("Аккаунт", selection: $accountID) { ForEach(model.accounts) { Text($0.email).tag($0.id) } }
                .fixedSize(horizontal: true, vertical: false)
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
                        TextEditor(text: $signature).workspaceEditorSurface().frame(height: 150).accessibilityIdentifier(
                            "mail.signature")
                        HStack {
                            Spacer()
                            Button("Сохранить подпись") { Task { await model.setSignature(accountID: accountID, text: signature) } }
                                .buttonStyle(WorkspaceButtonStyle(prominent: true))
                                .disabled(accountID.isEmpty || model.busy)
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
                                        templateID = template.id
                                        templateName = template.name
                                        templateBody = template.body
                                    }.buttonStyle(.plain)
                                    Spacer()
                                    Button("Удалить", role: .destructive) { Task { await model.deleteTemplate(template.id) } }
                                }
                            }
                        }
                        Text("Название").font(.caption).foregroundStyle(.secondary)
                        TextField("Название шаблона", text: $templateName).accessibilityIdentifier("mail.template.name")
                        Text("Текст шаблона").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $templateBody).workspaceEditorSurface().frame(height: 150).accessibilityIdentifier(
                            "mail.template.body")
                        HStack {
                            Button("Новый") {
                                templateID = UUID()
                                templateName = ""
                                templateBody = ""
                            }
                            Spacer()
                            Button("Сохранить шаблон") {
                                Task { await model.saveTemplate(.init(id: templateID, name: templateName, body: templateBody)) }
                            }.buttonStyle(WorkspaceButtonStyle(prominent: true)).disabled(
                                templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                        }
                    }.padding(WorkspaceStyle.cardInset)
                        .background { WorkspaceSurface(radius: WorkspaceStyle.cardRadius) }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(
                            "Для новых входящих после начальной синхронизации. Корзина имеет приоритет над архивом. Сохранённая копия остаётся."
                        ).font(.caption).foregroundStyle(.secondary)
                        let rules = model.automation.rules.filter { $0.accountID == accountID }
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
                            MakoshPicker("Поле", selection: $field) {
                                Text("Отправитель").tag(MailIncomingRule.Field.from)
                                Text("Тема").tag(MailIncomingRule.Field.subject)
                            }
                            .labelsHidden().fixedSize(horizontal: true, vertical: false)
                            TextField("Содержит", text: $match)
                        }
                        HStack {
                            Text("Действие").frame(width: ruleLabelWidth, alignment: .leading)
                            MakoshPicker("Действие", selection: $action) {
                                ForEach(MailIncomingRule.Action.allCases, id: \.self) { Text(actionTitle($0)).tag($0) }
                            }.labelsHidden().fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 0)
                        }
                        if action == .label { TextField("Локальная метка", text: $label) }
                        Button("Добавить правило") {
                            Task {
                                await model.saveIncomingRule(
                                    .init(
                                        accountID: accountID, field: field, value: match, action: action,
                                        label: action == .label ? label : nil))
                            }
                        }.disabled(accountID.isEmpty || match.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                    }.padding(WorkspaceStyle.cardInset)
                        .background { WorkspaceSurface(radius: WorkspaceStyle.cardRadius) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(.horizontal, 24).padding(.bottom, 24).padding(.top, embedded ? 4 : 24).frame(
            minWidth: 600, maxWidth: embedded ? 760 : 680, minHeight: 500, maxHeight: embedded ? .infinity : 560, alignment: .topLeading
        )
        .onAppear {
            accountID = model.selectedFolder?.accountID ?? model.accounts.first?.id ?? ""
            loadSignature()
        }
        .onChange(of: accountID) { loadSignature() }
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
    private func loadSignature() { signature = model.automation.signatures[accountID] ?? "" }
    private func actionTitle(_ value: MailIncomingRule.Action) -> String {
        switch value {
        case .archive: "Архив"
        case .trash: "Корзина"
        case .label: "Метка"
        }
    }
}
