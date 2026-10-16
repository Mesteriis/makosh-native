import SwiftUI
import MakoshMail

/// MMail Settings sections within Makosh's existing native workspace.
struct MailAutomationSettingsView: View {
    @ObservedObject var model: MailWorkspaceModel
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
            HStack { Text("Настройки почты").font(.title2.bold()); Spacer(); Button("Закрыть") { dismiss() } }
            Picker("Аккаунт", selection: $accountID) { ForEach(model.accounts) { Text($0.email).tag($0.id) } }
            Picker("Раздел", selection: $section) {
                Text("Подпись").tag(0); Text("Шаблоны").tag(1); Text("Правила").tag(2)
            }.pickerStyle(.segmented).accessibilityIdentifier("mail.automation.section")
            Group {
                if section == 0 { Form {
                    Text("Подпись добавляется один раз при создании нового письма или ответа.").foregroundStyle(.secondary)
                    TextEditor(text: $signature).frame(minHeight: 180).accessibilityIdentifier("mail.signature")
                    Button("Сохранить подпись") { Task { await model.setSignature(accountID: accountID, text: signature) } }.disabled(accountID.isEmpty || model.busy)
                }.padding() } else if section == 1 {
                VStack(alignment: .leading) {
                    List(model.automation.templates) { template in
                        HStack {
                            Button(template.name) { templateID = template.id; templateName = template.name; templateBody = template.body }.buttonStyle(.plain)
                            Spacer(); Button("Удалить", role: .destructive) { Task { await model.deleteTemplate(template.id) } }
                        }
                    }.frame(minHeight: 100)
                    TextField("Название шаблона", text: $templateName).accessibilityIdentifier("mail.template.name")
                    TextEditor(text: $templateBody).frame(minHeight: 100).accessibilityIdentifier("mail.template.body")
                    HStack {
                        Button("Новый") { templateID = UUID(); templateName = ""; templateBody = "" }
                        Button("Сохранить шаблон") { Task { await model.saveTemplate(.init(id: templateID, name: templateName, body: templateBody)) } }.disabled(templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                    }
                }.padding() } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Для новых входящих после начальной синхронизации. Корзина имеет приоритет над архивом. Сохранённая копия остаётся.").font(.caption).foregroundStyle(.secondary)
                    List(model.automation.rules.filter { $0.accountID == accountID }) { rule in
                        HStack {
                            Toggle(isOn: Binding(get: { rule.enabled }, set: { on in var changed = rule; changed.enabled = on; Task { await model.saveIncomingRule(changed) } })) { Text("\(rule.field == .from ? "Отправитель" : "Тема") содержит «\(rule.value)» → \(actionTitle(rule.action))\(rule.label.map { ": " + $0 } ?? "")") }
                            Button("Удалить", role: .destructive) { Task { await model.deleteIncomingRule(rule.id) } }
                        }
                    }
                    HStack { Picker("Поле", selection: $field) { Text("Отправитель").tag(MailIncomingRule.Field.from); Text("Тема").tag(MailIncomingRule.Field.subject) }; TextField("Содержит", text: $match) }
                    Picker("Действие", selection: $action) { ForEach(MailIncomingRule.Action.allCases, id: \.self) { Text(actionTitle($0)).tag($0) } }
                    if action == .label { TextField("Локальная метка", text: $label) }
                    Button("Добавить правило") { Task { await model.saveIncomingRule(.init(accountID: accountID, field: field, value: match, action: action, label: action == .label ? label : nil)) } }.disabled(accountID.isEmpty || match.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                }.padding() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(24).frame(width: 680, height: 560)
            .onAppear { accountID = model.selectedFolder?.accountID ?? model.accounts.first?.id ?? ""; loadSignature() }
            .onChange(of: accountID) { loadSignature() }
    }
    private func loadSignature() { signature = model.automation.signatures[accountID] ?? "" }
    private func actionTitle(_ value: MailIncomingRule.Action) -> String { switch value { case .archive: "Архив"; case .trash: "Корзина"; case .label: "Метка" } }
}
