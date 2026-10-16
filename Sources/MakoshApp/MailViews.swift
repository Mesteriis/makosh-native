import SwiftUI
import AppKit
import MakoshMail
import MakoshCore

struct MailFoldersView: View {
    @ObservedObject var model: MailWorkspaceModel
    @State private var collapsedAccounts: Set<String> = []
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack { Text("ПОЧТОВЫЕ ЯЩИКИ").font(.caption.weight(.semibold)).foregroundStyle(.secondary);Spacer();Button { model.editingAccount=nil;model.accountSheet=true } label: { Image(systemName:"plus") }.buttonStyle(.plain).help("Добавить почтовый аккаунт").accessibilityIdentifier("mail.addAccount") }.padding(.horizontal,16)
            ScrollView {
                VStack(alignment:.leading,spacing:5) {
                    Button { model.outboxSheet=true } label: { Label("Исходящие операции", systemImage: "paperplane.circle").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).padding(8)
                    Button { model.notificationSettingsScope = .global } label: { Label("Уведомления", systemImage: "bell").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).padding(8).accessibilityIdentifier("mail.notifications.global")
                    Button { model.automationSettings = true } label: { Label("Подписи, шаблоны и правила", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).padding(8).accessibilityIdentifier("mail.automation.settings")
                    Button { model.selectArchive() } label: { Label("Сохранённая переписка",systemImage:"archivebox").frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.plain).padding(8).background(model.showArchive ? .purple.opacity(0.18) : .clear,in:RoundedRectangle(cornerRadius:8))
                    ForEach(model.accounts) { account in accountFolders(account) }
                }.padding(.horizontal,12)
            }
            if model.synthetic { Label("Синтетическая почта",systemImage:"testtube.2").font(.caption).foregroundStyle(.secondary).padding(.horizontal,16) }
            #if DEBUG
            if model.synthetic { Button("Тестовое входящее") { Task { await model.simulateIncoming() } }.accessibilityIdentifier("mail.notifications.syntheticIncoming").padding(.horizontal,16) }
            #endif
        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            .onChange(of: model.selectedFolder?.accountID) { _, accountID in
                if let accountID { collapsedAccounts.remove(accountID) }
            }
    }
    private func accountFolders(_ account: MailAccount) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { !collapsedAccounts.contains(account.id) },
            set: { expanded in
                if expanded { collapsedAccounts.remove(account.id) }
                else { collapsedAccounts.insert(account.id) }
            }
        )) {
            ForEach(model.folders.filter { $0.accountID == account.id }) { folder in
                Button { model.selectFolder(folder) } label: {
                    HStack {
                        Label(folder.title, systemImage: folder.kind.symbol)
                        Spacer()
                        let count = model.letters.filter { $0.key.accountID == account.id && $0.key.folder == folder.path && !$0.seen }.count
                        if count > 0 { Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .buttonStyle(.plain)
                .background(!model.showArchive && model.selectedFolder?.id == folder.id ? .purple.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("mail.folder.\(account.id).\(folder.path)")
                .contextMenu { Button("Уведомления папки…") { model.notificationSettingsScope = .folder(accountID: account.id, path: folder.path) } }
            }
        } label: {
            HStack(spacing: 8) {
                MailSenderAvatar(name: account.displayName, address: account.email, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(account.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Настройки аккаунта…") { model.editingAccount = account; model.accountSheet = true }
                    Button("Уведомления аккаунта…") { model.notificationSettingsScope = .account(account.id) }
                    if model.connected.contains(account.id) { Button("Отключить") { Task { await model.disconnect(account) } } }
                    else { Button("Подключить") { Task { await model.connect(account) } }.disabled(model.synthetic) }
                } label: { Image(systemName: model.connected.contains(account.id) ? "network" : "circle.dashed") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Действия аккаунта \(account.displayName)")
            }.accessibilityIdentifier("mail.account.\(account.id)")
        }.padding(.top, 12)
    }
}
struct MailMessageListView: View {
    @ObservedObject var model: MailWorkspaceModel
    var body: some View {
        VStack(spacing:0) {
            VStack(alignment:.leading,spacing:10) {
                HStack { Text(model.showArchive ? "Сохранённая переписка" : model.selectedFolder?.title ?? "Почта").font(.title2.bold());Spacer();if model.busy { ProgressView().controlSize(.small) };Button { model.compose() } label: { Image(systemName:"square.and.pencil") }.help("Новое письмо").accessibilityIdentifier("mail.compose") }
                Text("\(model.displayed.count) писем · \(model.displayed.filter { !$0.seen }.count) непрочитанных").font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Toggle("Непрочитанные",isOn:$model.unreadOnly).toggleStyle(.button).controlSize(.small)
                    Toggle(isOn:$model.starredOnly) { Image(systemName:"star") }.toggleStyle(.button).controlSize(.small).help("Отмеченные письма")
                    Spacer()
                    Button { Task { await model.refresh() } } label: { Image(systemName:"arrow.clockwise") }.disabled(model.busy || model.synthetic || !model.connected.contains(model.selectedFolder?.accountID ?? "")).help("Обновить папку").accessibilityIdentifier("mail.refresh")
                }
                TextField("Поиск в письмах",text:$model.search).textFieldStyle(.roundedBorder).onSubmit { Task { await model.refresh(serverSearch:true) } }.accessibilityIdentifier("mail.search")
            }.padding(16)
            Divider()
            if !model.ready { ContentUnavailableView("Почта ожидает PostgreSQL",systemImage:"externaldrive.badge.exclamationmark").frame(maxHeight:.infinity) }
            else if model.accounts.isEmpty {
                ContentUnavailableView { Label("Подключите почту",systemImage:"envelope.badge") } description: { Text("Добавьте IMAP/SMTP-аккаунт. Пароли хранятся в Связке ключей.") } actions: { Button("Добавить аккаунт") { model.accountSheet=true }.buttonStyle(.borderedProminent).accessibilityIdentifier("mail.connect.empty") }.frame(maxHeight:.infinity)
            } else if model.displayed.isEmpty {
                ContentUnavailableView("Нет писем",systemImage:"tray",description:Text("Выберите папку или измените поиск. Для синхронизации подключите аккаунт.")).frame(maxHeight:.infinity)
                Button("Загрузить ещё сохранённые письма") { Task { await model.refresh(older: true) } }.disabled(model.busy).padding(10)
            } else {
                List(selection:Binding(get:{ model.selectedID },set:{ model.select($0) })) {
                    ForEach(model.displayed) { letter in
                        HStack(alignment:.top,spacing:10) {
                            MailSenderAvatar(name: letter.senderName, address: letter.sender, size: 34)
                            VStack(alignment:.leading,spacing:2) {
                                HStack {
                                    Text(letter.senderName.isEmpty ? letter.sender : letter.senderName).font(.subheadline.weight(letter.seen ? .regular : .semibold)).lineLimit(1)
                                    Spacer(minLength: 4)
                                    if letter.flagged { Image(systemName:"star.fill").font(.caption2).foregroundStyle(.yellow) }
                                    Text(compactDate(letter.date)).font(.caption).foregroundStyle(.secondary).fixedSize().help(letter.date.formatted(date: .complete, time: .shortened))
                                }
                                Text(letter.subject.isEmpty ? "Без темы" : letter.subject).font(.callout.weight(letter.seen ? .regular : .medium)).lineLimit(1)
                                HStack(spacing: 4) {
                                    if !letter.attachments.isEmpty { Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary) }
                                    Text(String((letter.text ?? letter.sender).prefix(160))).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                if let labels = model.automation.labelsByLetter[letter.id], !labels.isEmpty { Text(labels.joined(separator: " · ")).font(.caption2).foregroundStyle(.purple) }
                            }
                            if !letter.seen { Circle().fill(.purple).frame(width:7,height:7).padding(.top,6) }
                        }
                        .padding(.vertical,4)
                        // Newly inserted native List rows must measure all text lines,
                        // rather than accepting the table's one-line height proposal.
                        .fixedSize(horizontal: false, vertical: true)
                        .tag(letter.id).listRowBackground(model.selectedID==letter.id ? .purple.opacity(0.16) : Color.clear).accessibilityIdentifier("mail.letter.\(letter.id)")
                            .contextMenu {
                                Button("Сохранённые версии…") { model.historyLetter = letter }
                                Button("Уведомления отправителя…") { model.notificationSettingsScope = .sender(accountID: letter.key.accountID, address: letter.sender) }
                            }
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden).disabled(model.busy)
                Button("Загрузить ещё") { Task { await model.refresh(older:true) } }.disabled(model.busy).padding(10)
            }
            if !model.drafts.isEmpty {
                Divider()
                Menu("Черновики · \(model.drafts.count)") { ForEach(model.drafts) { draft in Button(draft.subject.isEmpty ? "Без темы" : draft.subject) { model.composer=draft } } }.padding(12)
            }
            if let pending=model.submissions.last(where: { $0.state == .unknown || $0.state == .submitting }) {
                Label("Отправка \(pending.date.formatted(date:.abbreviated,time:.shortened)): исход неизвестен. Автоповтор запрещён.",systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange).padding(12)
            }
        }.background { WorkspaceBackdrop(intensity:0.6) }
    }
    private func compactDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}
struct MailReadingView: View {
    @ObservedObject var model: MailWorkspaceModel
    @ObservedObject var dossier: WorkspaceModel
    @State private var details=false
    @State private var html=false
    let showContact: (UUID) -> Void
    var body: some View {
        Group {
            if let letter=model.selected {
                VStack(spacing:0) {
                    header(letter).padding(20)
                    Divider()
                    if !letter.attachments.isEmpty { attachments(letter); Divider() }
                    if html,let content=letter.html { MailHTMLView(html:content).frame(maxWidth:.infinity,maxHeight:.infinity).modifier(MailPaperSheet()) }
                    else {
                        ScrollView {
                            MailTextBody(text: letter.text ?? "Содержимое ещё не загружено. Подключите аккаунт и откройте письмо.").foregroundStyle(Color(red:0.11,green:0.11,blue:0.12)).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                        }.frame(maxWidth:.infinity,maxHeight:.infinity).modifier(MailPaperSheet())
                    }
                    if let notice=model.notice { HStack { Text(notice).font(.caption);Spacer();Button { model.notice=nil } label:{ Image(systemName:"xmark") }.buttonStyle(.plain) }.padding(12).background(.purple.opacity(0.08)) }
                }.background { WorkspaceBackdrop(intensity:0.4) }
                    .onChange(of:letter.id) { details=false;html=false }
                    .inspector(isPresented: $model.showDossier) {
                        MailDossierInspector(letter: letter, dossier: dossier, showContact: showContact)
                            .inspectorColumnWidth(min: 250, ideal: 290, max: 380)
                    }
            } else { ContentUnavailableView("Выберите письмо",systemImage:"envelope.open",description:Text("Письмо, вложения и досье отправителя — в одном рабочем пространстве.")).background { WorkspaceBackdrop(intensity:0.4) } }
        }
        .sheet(isPresented:$model.outboxSheet) { MailOutboxView(model:model) }
        .sheet(isPresented:$model.accountSheet) { MailAccountSheet(model:model,account:model.editingAccount) }
        .sheet(item:$model.composer) { draft in MailComposeSheet(model:model,draft:draft) }
        .sheet(item:$model.notificationSettingsScope) { scope in MailNotificationSettingsView(model: model, scope: scope) }
        .sheet(isPresented: $model.automationSettings) { MailAutomationSettingsView(model: model) }
        .sheet(item: $model.historyLetter) { letter in MailReadingHistoryView(model: model, letter: letter) }
        .alert("Почта",isPresented:Binding(get:{ model.error != nil && !model.accountSheet && model.composer == nil },set:{ if !$0 { model.error=nil } })) { Button("Понятно",role:.cancel) { model.error=nil } } message:{ Text(model.error ?? "") }
    }
    private func header(_ letter: MailLetter) -> some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(alignment:.top) {
                Text(letter.subject.isEmpty ? "Без темы" : letter.subject).font(.title2.weight(.semibold)).textSelection(.enabled)
                Spacer()
                Button { Task { await model.mark(starred:!letter.flagged) } } label:{ Image(systemName:letter.flagged ? "star.fill" : "star").foregroundStyle(letter.flagged ? .yellow : .secondary) }.buttonStyle(.plain).disabled(model.busy || model.synthetic || !model.connected.contains(letter.key.accountID))
            }
            HStack(alignment:.top,spacing:12) {
                MailSenderAvatar(name: letter.senderName, address: letter.sender, size: 38)
                VStack(alignment:.leading,spacing:2) { Text(letter.senderName.isEmpty ? letter.sender : letter.senderName).font(.headline);Text(letter.sender).font(.caption).textSelection(.enabled);Text("Кому: \(letter.recipient)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                VStack(alignment:.trailing,spacing:5) { Text(letter.date.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary);Button(details ? "Скрыть детали" : "Детали") { details.toggle() }.buttonStyle(.plain).font(.caption) }
            }
            if details { VStack(alignment:.leading,spacing:5) { Text("Аккаунт: \(model.accounts.first { $0.id==letter.key.accountID }?.email ?? "")");Text("Папка: \(letter.key.folder)");Text("Message-ID: \(letter.messageID)") }.font(.caption).textSelection(.enabled).padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:10)) }
            HStack(spacing:12) {
                if model.actionFolder?.kind == .drafts { Button("Редактировать черновик") { Task { await model.editRemoteDraft() } }.disabled(model.busy || model.synthetic || letter.text == nil) }
                Button { model.compose(reply:true) } label:{ Image(systemName:"arrowshape.turn.up.left") }.help("Ответить").accessibilityLabel("Ответить")
                Button { model.compose(forward:true) } label:{ Image(systemName:"arrowshape.turn.up.right") }.help("Переслать").accessibilityLabel("Переслать")
                Menu { ForEach(model.folders.filter { $0.accountID==letter.key.accountID && $0.path != letter.key.folder }) { folder in Button(folder.title) { Task { await model.move(to:folder) } } } } label:{ Image(systemName:"folder") }.disabled(model.busy || model.synthetic || letter.text == nil || !model.connected.contains(letter.key.accountID))
                Menu {
                    Button("Сохранённые версии…") { model.historyLetter = letter }
                    Button("Уведомления отправителя…") { model.notificationSettingsScope = .sender(accountID: letter.key.accountID, address: letter.sender) }
                    Button(letter.seen ? "Отметить непрочитанным" : "Отметить прочитанным") { Task { await model.mark(seen:!letter.seen) } }.disabled(model.synthetic || !model.connected.contains(letter.key.accountID))
                    Button("Настройка архива файлов…") { Task { await model.filePolicy() } }
                    Toggle("Сохранять файлы папки в S3",isOn:Binding(get:{model.saveFiles},set:{ value in Task { await model.setFilePolicy(value) } })).disabled(model.synthetic)
                } label:{ Label("Действия", systemImage:"ellipsis.circle") }.menuStyle(.borderlessButton).accessibilityLabel("Действия письма").accessibilityIdentifier("mail.actions")
                Spacer()
                if letter.html != nil { Toggle("HTML",isOn:$html).toggleStyle(.button).help("HTML без JavaScript и внешних ресурсов") }
                Button { model.showDossier.toggle() } label:{ Image(systemName:"sidebar.trailing") }.help("Досье отправителя").accessibilityIdentifier("mail.dossier")
            }.controlSize(.small)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func attachments(_ letter: MailLetter) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(letter.attachments) { attachment in
                    HStack(spacing: 8) {
                        Image(systemName: "doc").font(.title2).foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.filename).font(.callout.weight(.medium)).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: 220, alignment: .leading)
                        Button("Сохранить…") { export(attachment, letter: letter) }.disabled(model.synthetic || model.busy)
                    }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                }
            }.padding(.horizontal, 20).padding(.vertical, 10)
        }.fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("mail.attachments")
    }
    private func export(_ attachment: MailAttachment,letter: MailLetter) {
        let panel=NSSavePanel();panel.nameFieldStringValue=URL(fileURLWithPath:attachment.filename).lastPathComponent
        guard let window=NSApp.keyWindow else { return }
        panel.beginSheetModal(for:window) { response in if response == .OK,let url=panel.url { Task { await model.export(attachment,letter:letter,to:url) } } }
    }
}
private struct MailDossierInspector: View {
    let letter: MailLetter
    @ObservedObject var dossier: WorkspaceModel
    let showContact: (UUID) -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Label("Досье отправителя",systemImage:"person.text.rectangle").font(.headline)
            Text(letter.senderName.isEmpty ? letter.sender : letter.senderName).font(.title3.bold())
            Text(letter.sender).font(.caption).textSelection(.enabled)
            if let contact=dossier.contacts.first(where: { $0.identities.contains(.init(service:"mail",accountID:letter.key.accountID,externalID:letter.sender.lowercased())) }) {
                Text(contact.organization).foregroundStyle(.secondary)
                ForEach(contact.notes.prefix(4)) { note in Text(note.text).font(.callout) }
                Button("Открыть досье") { showContact(contact.id) }.disabled(!dossier.ready || dossier.busy)
            } else {
                Button("Создать досье из отправителя") { Task { if let id=await dossier.linkMailSender(letter) { showContact(id) } } }.disabled(!dossier.canWrite || !MailAddress.isValid(letter.sender))
            }
            Text("Почтовая идентичность привязана к этому аккаунту. Ручные данные и заметки сохраняются.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(20).background { WorkspaceBackdrop(intensity:0.55) }
    }
}
