import SwiftUI
import AppKit
import MakoshFiles
import MakoshMail
import MakoshCore

struct MailMessageListView: View {
    @ObservedObject var model: MailWorkspaceModel
    @FocusState private var listFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.showArchive ? "Сохранённая переписка" : model.selectedFolder?.title ?? "Почта")
                    .font(.system(size: 21, weight: .bold)).lineLimit(1)
                Text("\(model.displayed.filter { !$0.seen }.count)")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 4)
                if model.busy { ProgressView().controlSize(.small) }
                MakoshMenu {
                    MakoshDropdownToggle("Непрочитанные", isOn: $model.unreadOnly)
                    MakoshDropdownToggle("Отмеченные", isOn: $model.starredOnly)
                    MakoshMenuItem("Сбросить фильтры", systemImage: "arrow.counterclockwise") {
                        model.unreadOnly = false
                        model.starredOnly = false
                    }
                } label: {
                    Label(
                        model.unreadOnly ? "Непрочитанные" : model.starredOnly ? "Отмеченные" : "Все письма",
                        systemImage: "line.3.horizontal.decrease"
                    )
                    .font(.caption)
                }.makoshMenuStyle(.plain).makoshMenuIndicator(.visible).makoshMenuWidth(220).fixedSize()
                    .accessibilityIdentifier("mail.filters").accessibilityLabel("Фильтр писем")
            }.padding(.horizontal, 18).frame(height: WorkspaceStyle.mailPaneHeaderHeight)
            Divider()
            if !model.ready {
                ContentUnavailableView("Почта ожидает PostgreSQL", systemImage: "externaldrive.badge.exclamationmark").frame(
                    maxHeight: .infinity)
            } else if model.accounts.isEmpty {
                ContentUnavailableView {
                    Label("Подключите почту", systemImage: "envelope.badge")
                } description: {
                    Text("Добавьте IMAP/SMTP-аккаунт. Пароли хранятся в Связке ключей.")
                } actions: {
                    Button("Добавить аккаунт") { model.accountSheet = true }.buttonStyle(.borderedProminent).accessibilityIdentifier(
                        "mail.connect.empty")
                }.frame(maxHeight: .infinity)
            } else if model.displayed.isEmpty {
                ContentUnavailableView(
                    "Нет писем", systemImage: "tray",
                    description: Text("Выберите папку или измените поиск. Для синхронизации подключите аккаунт.")
                ).frame(maxHeight: .infinity)
                Button("Загрузить ещё сохранённые письма") { Task { await model.refresh(older: true) } }.disabled(model.busy).padding(10)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.displayed) { letter in
                                Button {
                                    model.select(letter.id)
                                    listFocused = true
                                } label: {
                                    messageRow(letter)
                                }
                                .buttonStyle(.plain)
                                .background(
                                    model.selectedID == letter.id ? WorkspaceStyle.accent.opacity(0.20) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .id(letter.id).accessibilityIdentifier("mail.letter.\(letter.id)")
                                .accessibilityValue(model.selectedID == letter.id ? "Выбрано" : "")
                                .contextMenu {
                                    Button("Сохранённые версии…") { model.historyLetter = letter }
                                    Button("Уведомления отправителя…") {
                                        model.notificationSettingsScope = .sender(accountID: letter.key.accountID, address: letter.sender)
                                    }
                                }
                            }
                        }.padding(.horizontal, 8).padding(.vertical, 8)
                    }
                    .focusable().focused($listFocused).focusEffectDisabled()
                    .onKeyPress(.downArrow) {
                        moveSelection(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -1)
                        return .handled
                    }
                    .onChange(of: model.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
                }.disabled(model.busy)
                Button("Загрузить ещё") { Task { await model.refresh(older: true) } }.disabled(model.busy).padding(10)
            }
            if !model.drafts.isEmpty {
                Divider()
                MakoshMenu("Черновики · \(model.drafts.count)") {
                    ForEach(model.drafts) { draft in
                        MakoshMenuItem(draft.subject.isEmpty ? "Без темы" : draft.subject) { model.composer = draft }
                    }
                }.padding(12)
            }
            if let pending = model.submissions.last(where: { $0.state == .unknown || $0.state == .submitting }) {
                Label(
                    "Отправка \(pending.date.formatted(date:.abbreviated,time:.shortened)): исход неизвестен. Автоповтор запрещён.",
                    systemImage: "exclamationmark.triangle"
                ).font(.caption).foregroundStyle(.orange).padding(12)
            }
        }.background { WorkspaceBackdrop(intensity: 0.6) }
    }
    private func messageRow(_ letter: MailLetter) -> some View {
        HStack(alignment: .top, spacing: 10) {
            MailSenderAvatar(name: letter.senderName, address: letter.sender, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(letter.senderName.isEmpty ? letter.sender : letter.senderName).font(
                        .subheadline.weight(letter.seen ? .regular : .semibold)
                    ).lineLimit(1)
                    Spacer(minLength: 4)
                    if letter.flagged { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                    Text(compactDate(letter.date)).font(.caption).foregroundStyle(.secondary).fixedSize().help(
                        letter.date.formatted(date: .complete, time: .shortened))
                }
                Text(letter.subject.isEmpty ? "Без темы" : letter.subject).font(.callout.weight(letter.seen ? .regular : .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if !letter.attachments.isEmpty { Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary) }
                    Text(String((letter.text ?? letter.sender).prefix(160)).split(whereSeparator: \.isWhitespace).joined(separator: " "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let labels = model.automation.labelsByLetter[letter.id], !labels.isEmpty {
                    Text(labels.joined(separator: " · ")).font(.caption2).foregroundStyle(WorkspaceStyle.accent)
                }
            }
            if !letter.seen { Circle().fill(WorkspaceStyle.accent).frame(width: 7, height: 7).padding(.top, 6) }
        }
        .padding(.horizontal, 10).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    private func moveSelection(by offset: Int) {
        guard !model.busy, !model.displayed.isEmpty else { return }
        let letters = model.displayed
        let index = letters.firstIndex { $0.id == model.selectedID } ?? (offset > 0 ? -1 : letters.count)
        model.select(letters[min(max(index + offset, 0), letters.count - 1)].id)
    }
    private func compactDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}
struct MailReadingView: View {
    @ObservedObject var model: MailWorkspaceModel
    @ObservedObject var dossier: WorkspaceModel
    @State private var details = false
    @State private var html = false
    let showContact: (UUID) -> Void
    var body: some View {
        Group {
            if let letter = model.selected {
                HStack(spacing: 0) {
                    reader(letter).frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    if model.showDossier {
                        MailDossierInspector(letter: letter, dossier: dossier, showContact: showContact)
                            .frame(width: 280).frame(maxHeight: .infinity)
                    }
                }
                .background { WorkspaceBackdrop(intensity: 0.4) }
                .onChange(of: letter.id) {
                    details = false
                    html = false
                }
            } else {
                ContentUnavailableView(
                    "Выберите письмо", systemImage: "envelope.open",
                    description: Text("Письмо, вложения и досье отправителя — в одном рабочем пространстве.")
                ).background { WorkspaceBackdrop(intensity: 0.4) }
            }
        }
        .sheet(isPresented: $model.outboxSheet) { MailOutboxView(model: model).makoshAppearance() }
        .sheet(isPresented: $model.accountSheet) { MailAccountSheet(model: model, account: model.editingAccount).makoshAppearance() }
        .sheet(item: $model.composer) { draft in MailComposeSheet(model: model, draft: draft).makoshAppearance() }
        .sheet(item: $model.notificationSettingsScope) { scope in
            MailNotificationSettingsView(model: model, scope: scope).makoshAppearance()
        }
        .sheet(isPresented: $model.automationSettings) { MailAutomationSettingsView(model: model).makoshAppearance() }
        .sheet(item: $model.historyLetter) { letter in MailReadingHistoryView(model: model, letter: letter).makoshAppearance() }
        .alert(
            "Почта",
            isPresented: Binding(
                get: { model.error != nil && !model.accountSheet && model.composer == nil }, set: { if !$0 { model.error = nil } })
        ) {
            Button("Понятно", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }
    private func reader(_ letter: MailLetter) -> some View {
        VStack(spacing: 0) {
            actions(letter).padding(.horizontal, 28).frame(height: WorkspaceStyle.mailPaneHeaderHeight)
            Divider()
            header(letter).padding(32)
            Divider().padding(.horizontal, 32)
            if html, let content = letter.html {
                MailHTMLView(html: content).frame(maxWidth: .infinity, maxHeight: .infinity).modifier(MailPaperSheet())
                if !letter.attachments.isEmpty { attachments(letter).padding(.horizontal, 32).padding(.bottom, 20) }
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            MailTextBody(
                                text: letter.text ?? "Содержимое ещё не загружено. Подключите аккаунт и откройте письмо.",
                                font: .system(size: 16)
                            )
                            .foregroundStyle(.primary)
                            .frame(width: max(0, min(650, geometry.size.width - 64)), alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            if !letter.attachments.isEmpty {
                                Divider()
                                attachments(letter)
                            }
                            Divider()
                            Button {
                                model.compose(reply: true)
                            } label: {
                                Label("Ответить", systemImage: "arrowshape.turn.up.left")
                            }
                            .controlSize(.large).accessibilityIdentifier("mail.reply.bottom")
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(32)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let notice = model.notice {
                HStack {
                    Text(notice).font(.caption)
                    Spacer()
                    Button {
                        model.notice = nil
                    } label: {
                        Image(systemName: "xmark")
                    }.buttonStyle(.plain)
                }.padding(12).background(WorkspaceStyle.accent.opacity(0.08))
            }
        }
    }
    private func header(_ letter: MailLetter) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text(letter.subject.isEmpty ? "Без темы" : letter.subject).font(.system(size: 28, weight: .bold)).textSelection(.enabled)
                Spacer()
                Button {
                    Task { await model.mark(starred: !letter.flagged) }
                } label: {
                    Image(systemName: letter.flagged ? "star.fill" : "star").foregroundStyle(letter.flagged ? .yellow : .secondary)
                }.buttonStyle(.plain).disabled(model.busy || model.synthetic || !model.connected.contains(letter.key.accountID))
            }
            HStack(alignment: .top, spacing: 12) {
                MailSenderAvatar(name: letter.senderName, address: letter.sender, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(letter.senderName.isEmpty ? letter.sender : letter.senderName).font(.headline)
                    Text(letter.sender).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Кому: \(letter.recipient)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(letter.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    Button(details ? "Скрыть детали" : "Детали") { details.toggle() }.buttonStyle(.plain).font(.caption)
                }
            }
            if details {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Аккаунт: \(model.accounts.first { $0.id==letter.key.accountID }?.email ?? "")")
                    Text("Папка: \(letter.key.folder)")
                    Text("Message-ID: \(letter.messageID)")
                }.font(.caption).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
                    .quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func actions(_ letter: MailLetter) -> some View {
        ViewThatFits(in: .horizontal) {
            actionButtons(letter).labelStyle(.titleAndIcon)
            actionButtons(letter).labelStyle(.iconOnly)
        }
    }
    private func actionButtons(_ letter: MailLetter) -> some View {
        HStack(spacing: 12) {
            if model.actionFolder?.kind == .drafts {
                Button("Редактировать черновик") { Task { await model.editRemoteDraft() } }.disabled(
                    model.busy || model.synthetic || letter.text == nil)
            }
            Button {
                model.compose(reply: true)
            } label: {
                Label("Ответить", systemImage: "arrowshape.turn.up.left").fixedSize()
            }.help("Ответить").accessibilityLabel("Ответить")
            Button {
                model.compose(forward: true)
            } label: {
                Label("Переслать", systemImage: "arrowshape.turn.up.right").fixedSize()
            }.help("Переслать").accessibilityLabel("Переслать")
            MakoshMenu {
                ForEach(model.folders.filter { $0.accountID == letter.key.accountID && $0.path != letter.key.folder }) { folder in
                    MakoshMenuItem(folder.title) { Task { await model.move(to: folder) } }
                }
            } label: {
                Image(systemName: "folder")
            }.disabled(model.busy || model.synthetic || letter.text == nil || !model.connected.contains(letter.key.accountID))
            if let folder = model.folders.first(where: {
                $0.accountID == letter.key.accountID && $0.kind == .archive && $0.path != letter.key.folder
            }) {
                Button {
                    Task { await model.move(to: folder) }
                } label: {
                    Image(systemName: "archivebox")
                }
                .help("Архивировать").accessibilityLabel("Архивировать")
                .accessibilityIdentifier("mail.archive")
                .disabled(model.busy || model.synthetic || letter.text == nil || !model.connected.contains(letter.key.accountID))
            }
            MakoshMenu {
                MakoshMenuItem("Сохранённые версии…") { model.historyLetter = letter }
                MakoshMenuItem("Уведомления отправителя…") {
                    model.notificationSettingsScope = .sender(accountID: letter.key.accountID, address: letter.sender)
                }
                MakoshMenuItem(letter.seen ? "Отметить непрочитанным" : "Отметить прочитанным") {
                    Task { await model.mark(seen: !letter.seen) }
                }.disabled(model.synthetic || !model.connected.contains(letter.key.accountID))
                MakoshMenuItem("Настройка архива файлов…") { Task { await model.filePolicy() } }
                MakoshDropdownToggle(
                    "Сохранять файлы папки в S3",
                    isOn: Binding(get: { model.saveFiles }, set: { value in Task { await model.setFilePolicy(value) } })
                ).disabled(model.synthetic)
                if !model.synthetic {
                    AIAccessMenuToggle(scope: .mailAccount(accountID: letter.key.accountID), title: "Ящик доступен для ИИ")
                }
            } label: {
                Image(systemName: "ellipsis")
            }.makoshMenuStyle(.plain).accessibilityLabel("Действия письма").accessibilityIdentifier("mail.actions")
            Spacer()
            if letter.html != nil { Toggle("HTML", isOn: $html).toggleStyle(.button).help("HTML без JavaScript и внешних ресурсов") }
            Button {
                model.showDossier.toggle()
            } label: {
                Image(systemName: "sidebar.trailing")
            }.help("Досье отправителя").accessibilityIdentifier("mail.dossier")
        }.controlSize(.regular).buttonStyle(.borderless).tint(.primary)
    }
    private func attachments(_ letter: MailLetter) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Вложения · \(letter.attachments.count)").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(letter.attachments) { attachment in
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text").font(.title2)
                            .foregroundStyle(attachment.mimeType == "application/pdf" ? Color.red : WorkspaceStyle.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(attachment.filename).font(.callout.weight(.medium)).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)).font(.caption)
                                .foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            export(attachment, letter: letter)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(.plain).help("Сохранить \(attachment.filename)")
                        .accessibilityLabel("Сохранить \(attachment.filename)")
                        .accessibilityIdentifier("mail.attachment.save.\(attachment.id)")
                        .disabled(model.synthetic || model.busy)
                        Menu {
                            FileActionsMenu(handoff: {
                                FileHandoff(name: attachment.filename, byteCount: Int64(attachment.byteCount), date: letter.date) { url in
                                    try await model.exportAttachmentFile(attachment, letter: letter, to: url)
                                }
                            })
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Действия с файлом")
                        .accessibilityIdentifier("mail.attachment.actions.\(attachment.id)").disabled(model.synthetic)
                    }.padding(12).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        .contextMenu {
                            Button("Сохранить…") { export(attachment, letter: letter) }.disabled(model.synthetic || model.busy)
                            FileActionsMenu(handoff: {
                                FileHandoff(name: attachment.filename, byteCount: Int64(attachment.byteCount), date: letter.date) { url in
                                    try await model.exportAttachmentFile(attachment, letter: letter, to: url)
                                }
                            })
                        }
                }
            }
        }.accessibilityIdentifier("mail.attachments")
    }
    private func export(_ attachment: MailAttachment, letter: MailLetter) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: attachment.filename).lastPathComponent
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { Task { await model.export(attachment, letter: letter, to: url) } }
        }
    }
}
private struct MailDossierInspector: View {
    let letter: MailLetter
    @ObservedObject var dossier: WorkspaceModel
    let showContact: (UUID) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Досье отправителя", systemImage: "person.text.rectangle").font(.headline)
                .padding(.horizontal, 20).frame(height: WorkspaceStyle.mailPaneHeaderHeight)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text(letter.senderName.isEmpty ? letter.sender : letter.senderName).font(.title3.bold())
                Text(letter.sender).font(.caption).textSelection(.enabled)
                if let contact = dossier.persons.first(where: {
                    $0.identities.contains(.init(service: "mail", accountID: letter.key.accountID, externalID: letter.sender.lowercased()))
                }) {
                    Text(contact.organization).foregroundStyle(.secondary)
                    ForEach(contact.notes.prefix(4)) { note in Text(note.text).font(.callout) }
                    Button("Открыть досье") { showContact(contact.id) }.disabled(!dossier.ready || dossier.busy)
                } else {
                    Button("Создать досье из отправителя") { Task { if let id = await dossier.linkMailSender(letter) { showContact(id) } } }
                        .disabled(!dossier.canWrite || !MailAddress.isValid(letter.sender))
                }
                Text("Почтовая идентичность привязана к этому аккаунту. Ручные данные и заметки сохраняются.").font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }.padding(20)
        }
    }
}
