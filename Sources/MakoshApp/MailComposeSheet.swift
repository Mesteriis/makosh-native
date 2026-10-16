import SwiftUI
import AppKit
import MakoshMail

struct MailComposeSheet: View {
    @ObservedObject var model: MailWorkspaceModel
    @State var draft: MailDraft
    @StateObject private var editor: MailRichTextController
    private let originalEditor: NSAttributedString
    @State private var attachments: [URL]=[]
    @State private var showCopies=false
    @State private var scheduleOpen = false
    @State private var sendAt = Date().addingTimeInterval(3600)
    @State private var applyingTemplate: MailReplyTemplate?
    @Environment(\.dismiss) private var dismiss
    init(model: MailWorkspaceModel, draft: MailDraft) {
        self.model = model; _draft = State(initialValue: draft)
        let initial: NSAttributedString
        if let data = draft.bodyRTF, let rich = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) { initial = rich }
        else { initial = NSAttributedString(string: draft.body, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]) }
        originalEditor = initial
        _editor = StateObject(wrappedValue: MailRichTextController(initial: initial))
    }
    private func currentDraft() throws -> MailDraft {
        try Self.capture(draft: draft, originalEditor: originalEditor, current: editor.currentAttributed())
    }
    static func capture(draft: MailDraft, originalEditor: NSAttributedString, current rich: NSAttributedString) throws -> MailDraft {
        var value = draft; value.body = rich.string
        let range = NSRange(location: 0, length: rich.length)
        var hasAttachment = false
        rich.enumerateAttribute(.attachment, in: range) { value, _, stop in if value != nil { hasAttachment = true; stop.pointee = true } }
        guard !hasAttachment else { throw MailFailure.invalidInput }
        // Opening remote HTML never invokes the network-capable AppKit HTML importer.
        // An unchanged editor preserves the original MIME rather than flattening it.
        if draft.bodyRTF == nil, draft.bodyHTML != nil, rich.isEqual(to: originalEditor) { return value }
        value.bodyRTF = try rich.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        value.bodyHTML = String(data: try rich.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue]), encoding: .utf8)
        return value
    }
    private func saveDraft() {
        do { let value = try currentDraft(); Task { await model.save(value, files: attachments) } }
        catch { model.error = "Не удалось подготовить форматированный текст письма." }
    }
    private func sendDraft() {
        do { let value = try currentDraft(); Task { _ = await model.send(value, files: attachments) } }
        catch { model.error = "Не удалось подготовить форматированный текст письма." }
    }
    private var submissionBlocked: Bool { model.submissions.contains { $0.draftID==draft.id && $0.state != .rejected && $0.state != .userConfirmedNotSent } }
    var body: some View {
        VStack(spacing:0) {
            HStack { Text("Новое письмо").font(.title2.bold());Spacer();Button("Сохранить черновик", action: saveDraft).disabled(model.busy) }.padding(20)
            Divider()
            Grid(alignment:.leading,horizontalSpacing:12,verticalSpacing:12) {
                GridRow { Text("От").foregroundStyle(.secondary);Picker("Аккаунт",selection:$draft.accountID) { ForEach(model.accounts) { account in Text(account.email).tag(account.id) } }.labelsHidden().disabled(!draft.files.isEmpty || draft.remoteSave != nil) }
                GridRow { Text("Кому").foregroundStyle(.secondary);TextField("Адреса через запятую",text:$draft.to).textFieldStyle(.plain).accessibilityIdentifier("mail.compose.to") }
                if showCopies {
                    GridRow { Text("Копия").foregroundStyle(.secondary);TextField("Cc",text:$draft.cc).textFieldStyle(.plain) }
                    GridRow { Text("Скрытая").foregroundStyle(.secondary);TextField("Bcc",text:$draft.bcc).textFieldStyle(.plain) }
                }
                GridRow { Text("Тема").foregroundStyle(.secondary);TextField("Тема письма",text:$draft.subject).textFieldStyle(.plain).accessibilityIdentifier("mail.compose.subject") }
            }.padding(20)
            Divider()
            HStack {
                Button { editor.apply(.bold) } label: { Image(systemName: "bold") }.help("Полужирный")
                Button { editor.apply(.italic) } label: { Image(systemName: "italic") }.help("Курсив")
                Button { editor.apply(.underline) } label: { Image(systemName: "underline") }.help("Подчёркнутый")
                Button { editor.apply(.bullet) } label: { Image(systemName: "list.bullet") }.help("Список")
                Button { editor.apply(.numbered) } label: { Image(systemName: "list.number") }.help("Нумерованный список")
                Spacer()
                Menu("Шаблоны") { ForEach(model.automation.templates) { template in Button(template.name) { applyingTemplate = template } } }.disabled(model.automation.templates.isEmpty)
            }.buttonStyle(.borderless).padding(.horizontal, 20).padding(.top, 10)
            MailRichTextEditor(controller: editor).padding(12).accessibilityIdentifier("mail.compose.body")
            if !attachments.isEmpty {
                ScrollView(.horizontal) { HStack { ForEach(attachments,id:\.self) { file in HStack { Image(systemName:"paperclip");Text(file.lastPathComponent);Button { attachments.removeAll { $0==file } } label:{ Image(systemName:"xmark") }.buttonStyle(.plain) }.padding(8).background(.quaternary,in:Capsule()) } }.padding(12) }
                Text("При сохранении вложения архивируются в S3 либо в зашифрованную локальную подготовку, если для папки запрещены копии в S3.").font(.caption).foregroundStyle(.secondary).padding(.horizontal,20)
            }
            if !draft.files.isEmpty { HStack { ForEach(draft.files) { file in Label(file.filename, systemImage: "paperclip").font(.caption) }; Spacer() }.padding(.horizontal, 20) }
            if draft.remoteSave?.unresolved == true { Label("Исход сохранения на сервере неизвестен. Проверьте папку Черновики и исходящие операции.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).padding(8) }
            if submissionBlocked { Label("Эта отправка уже принята или её исход неизвестен. Повтор заблокирован.",systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange).padding(12) }
            if let error=model.error { Text(error).font(.caption).foregroundStyle(.red).padding(12) }
            Divider()
            HStack {
                Button { chooseFiles() } label:{ Image(systemName:"paperclip") }.help("Добавить файлы")
                Toggle("Cc / Bcc",isOn:$showCopies).toggleStyle(.button)
                Spacer()
                Button("Закрыть") { dismiss() }.disabled(model.busy)
                Button { scheduleOpen = true } label: { Image(systemName: "clock") }.help("Отложить отправку").accessibilityLabel("Отложить отправку").disabled(model.busy || submissionBlocked || draft.to.isEmpty)
                    .popover(isPresented: $scheduleOpen) {
                        VStack(alignment: .leading, spacing: 12) {
                            DatePicker("Отправить", selection: $sendAt, in: Date()...)
                            Text("Макош должен быть открыт, аккаунт подключён. После сна просроченная отправка выполнится при подключении. Неизвестный исход блокирует повтор.").font(.caption).frame(width: 320)
                            Button("Запланировать") {
                                do { let value = try currentDraft(); Task { await model.schedule(value, files: attachments, at: sendAt) } }
                                catch { model.error = "Не удалось подготовить письмо." }
                            }.disabled(model.busy || submissionBlocked)
                        }.padding(20)
                    }
                Button(action: sendDraft) { Label("Отправить",systemImage:"paperplane.fill") }.buttonStyle(.borderedProminent).keyboardShortcut(.return,modifiers:.command).disabled(model.busy || model.synthetic || submissionBlocked || draft.to.isEmpty).accessibilityIdentifier("mail.compose.send")
            }.padding(20)
        }.frame(width:740,height:660).interactiveDismissDisabled(model.busy)
            .onChange(of: draft.accountID) {
                let signature = model.automation.signatures[draft.accountID] ?? ""
                let replaced = editor.replaceSignature(previous: draft.insertedSignature ?? "", with: signature)
                draft.insertedSignature = replaced && !signature.isEmpty ? signature : nil
                draft.body = editor.currentString()
            }
            .confirmationDialog("Заменить текст письма выбранным шаблоном? Адресаты и вложения сохранятся.", isPresented: Binding(get: { applyingTemplate != nil }, set: { if !$0 { applyingTemplate = nil } }), titleVisibility: .visible) {
                if let template = applyingTemplate { Button("Применить шаблон") { draft = MailComposition.applying(template, to: draft); editor.replaceAll(draft.body); applyingTemplate = nil } }
            }
    }
    private func chooseFiles() {
        guard let window=NSApp.keyWindow else { return }
        let panel=NSOpenPanel();panel.canChooseFiles=true;panel.canChooseDirectories=false;panel.allowsMultipleSelection=true
        panel.beginSheetModal(for:window) { response in if response == .OK { attachments.append(contentsOf:panel.urls.filter { !attachments.contains($0) }) } }
    }
}
