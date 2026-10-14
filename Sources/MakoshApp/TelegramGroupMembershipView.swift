import SwiftUI
import AppKit
import MakoshTelegram

enum TelegramGroupViewMode { case invite, links, requests, history }
private struct GroupConfirmation {
    let change: TelegramGroupMembershipChange
    let basis: TelegramGroupMembershipSnapshot
    let contextID: UUID
    let searchContextID: UUID
    let message: String
}
struct TelegramGroupMembershipView: View {
    @ObservedObject var controller: TelegramGroupMembershipController
    @ObservedObject var search: TelegramRemotePeerSearch
    let mode: TelegramGroupViewMode
    let invite: (TelegramDiscoveredPeer, UUID, TelegramGroupMembershipSnapshot, UUID) -> Bool
    @State private var query = ""
    @State private var pending: GroupConfirmation?
    @State private var creating = false
    @State private var confirmationFailed = false
    @State private var historyEditor: TelegramAdminHistoryFilterDraft?
    @State private var historyActors: [Int64: String] = [:]
    private var blocked: Bool { controller.isBusy || controller.status != .ready || controller.phase == .uncertain }
    var body: some View {
        VStack(spacing: 0) {
            if mode == .history {
                HStack {
                    Button("Фильтр событий") {
                        historyEditor = .init(id: controller.contextID, filter: controller.historyFilter, actors: historyActors)
                    }.disabled(controller.snapshot?.canHistory != true || controller.isBusy)
                        .accessibilityIdentifier("telegram.group.history.filter.open")
                    Spacer()
                    Text(controller.historyFilter == .all ? "Все события" : "Выбранные события").font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            }
            if mode == .links { linkControls }
            if mode == .invite || mode == .requests || mode == .history {
                TextField(mode == .invite ? "Имя или имя пользователя" : "Поиск", text: $query)
                    .textFieldStyle(.roundedBorder).padding(12).disabled(controller.isBusy)
                    .accessibilityIdentifier("telegram.group.search")
                    .onChange(of: query) { _, value in
                        if mode == .invite { search.search(value) }
                    }
                    .task(id: query) {
                        guard mode == .requests || mode == .history else { return }
                        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                        _ = controller.show(mode == .requests ? .requests : .history, query: query)
                    }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if mode == .invite { memberRows }
                    else if mode == .links { linkRows }
                    else if mode == .requests { requestRows }
                    else { historyRows }
                    readStatus
                    if controller.canLoadMore && mode != .invite {
                        Button("Загрузить ещё", action: controller.loadMore).padding(12).accessibilityIdentifier("telegram.group.more")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityIdentifier("telegram.group.list")
            Divider()
            TelegramGroupMutationStatus(controller: controller).padding(12)
            if confirmationFailed { Text("Контекст изменился. Обновите список перед новым действием.").foregroundStyle(.orange).padding(12) }
        }
        .alert("Подтвердить действие", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { value in
            Button("Отмена", role: .cancel) { pending = nil }
            Button("Подтвердить") {
                let accepted: Bool
                if case let .invite(peer) = value.change { accepted = invite(peer, value.searchContextID, value.basis, value.contextID) }
                else { accepted = controller.apply(value.change, basis: value.basis, contextID: value.contextID) }
                confirmationFailed = !accepted; pending = nil
            }.accessibilityIdentifier("telegram.group.confirm")
        } message: { Text($0.message) }
        .sheet(isPresented: $creating) { TelegramGroupInviteEditor(controller: controller) }
        .sheet(item: $historyEditor) { TelegramAdminHistoryFilterView(controller: controller, basis: $0) }
        .onChange(of: controller.events, initial: true) { _, events in
            for event in events where historyActors.count < 1000 || historyActors[event.actorID] != nil { historyActors[event.actorID] = event.actor }
        }
        .onDisappear { if mode == .invite { search.search("") } }
    }
    private func confirm(_ change: TelegramGroupMembershipChange, _ message: String) {
        guard let basis = controller.snapshot, controller.canSubmit(change) else { return }
        confirmationFailed = false
        pending = .init(change: change, basis: basis, contextID: controller.contextID, searchContextID: search.contextID, message: message)
    }
    private var linkControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Ссылки", selection: Binding(get: { controller.page }, set: { _ = controller.show($0) })) {
                Text("Активные").tag(TelegramGroupMembershipSection.activeLinks)
                Text("Отозванные").tag(TelegramGroupMembershipSection.revokedLinks)
            }.pickerStyle(.segmented).disabled(controller.isBusy).accessibilityIdentifier("telegram.group.links.category")
            if controller.snapshot?.isCreator == true {
                Picker("Создатель ссылки", selection: Binding(get: { controller.ownerID ?? controller.accountID ?? 0 }, set: { _ = controller.selectOwner($0) })) {
                    if let own = controller.accountID { Text("Мои ссылки").tag(own) }
                    ForEach(controller.creators.filter { $0.id != controller.accountID }) { Text($0.title).tag($0.id) }
                }.disabled(controller.isBusy).accessibilityIdentifier("telegram.group.links.owner")
            }
            Button("Создать ссылку") { creating = true }.disabled(blocked || controller.snapshot?.canManageLinks != true)
                .accessibilityIdentifier("telegram.group.links.create")
        }.padding(12)
    }
    @ViewBuilder private var memberRows: some View {
        ForEach(search.results.filter { $0.id != controller.accountID && $0.isUser }) { peer in
            HStack {
                VStack(alignment: .leading) { Text(peer.chat.title); if let username = peer.username { Text("@" + username).font(.caption).foregroundStyle(.secondary) } }
                Spacer()
                Button("Добавить") { confirm(.invite(peer), "Добавить \(peer.chat.title) в \(controller.snapshot?.title ?? "диалог")?") }
                    .disabled(blocked).accessibilityIdentifier("telegram.group.invite.\(peer.id)")
            }.padding(12)
            Divider()
        }
        if search.status == .loading { ProgressView("Поиск в Telegram…").padding() }
        else if search.status == .failed || search.status == .timedOut {
            Text("Поиск не завершился.").padding(); Button("Повторить поиск", action: search.retry).padding()
        } else if search.status == .ready && search.results.isEmpty { Text("Ничего не найдено").foregroundStyle(.secondary).padding(24) }
        else if search.status == .idle { Text("Найдите человека по имени или имени пользователя.").foregroundStyle(.secondary).padding(24) }
    }
    @ViewBuilder private var linkRows: some View {
        ForEach(controller.links) { row in
            VStack(alignment: .leading, spacing: 7) {
                Text(row.title ?? (row.permanent ? "Основная ссылка" : "Пригласительная ссылка")).font(.body.weight(.medium))
                if let link = row.link {
                    Text(link).font(.callout).textSelection(.enabled)
                    Text("Вступили: \(row.usage) · Заявки: \(row.requested)").font(.caption).foregroundStyle(.secondary)
                    if let until = row.expireDate { Text("До \(Date(timeIntervalSince1970: Double(until)).formatted())").font(.caption) }
                    if let limit = row.usageLimit { Text("Лимит вступлений: \(limit)").font(.caption) }
                    if row.requiresApproval { Text("С одобрением администратора").font(.caption) }
                    if row.paid { Text("Платная подписка · параметры здесь не редактируются").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button("Копировать") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link, forType: .string) }
                            .accessibilityIdentifier("telegram.group.link.copy.\(row.id)")
                        if controller.canSubmit(.revoke(row)) {
                            Button("Отозвать", role: .destructive) { confirm(.revoke(row), "Отозвать ссылку \(row.title ?? link)? По ней больше нельзя будет вступить.") }
                                .accessibilityIdentifier("telegram.group.link.revoke.\(row.id)")
                        }
                    }
                } else { Text("Публичные заявки на вступление").foregroundStyle(.secondary) }
            }.padding(12)
            Divider()
        }
    }
    @ViewBuilder private var requestRows: some View {
        ForEach(controller.requests) { row in
            VStack(alignment: .leading, spacing: 7) {
                Text(row.title).font(.body.weight(.medium))
                if let username = row.username { Text("@" + username).font(.caption).foregroundStyle(.secondary) }
                Text(Date(timeIntervalSince1970: Double(row.date)), format: .dateTime).font(.caption).foregroundStyle(.secondary)
                if let about = row.about { Text(about).font(.callout) }
                HStack {
                    Button("Принять") { confirm(.request(row, approve: true), "Принять заявку \(row.title) в \(controller.snapshot?.title ?? "диалог")?") }
                        .accessibilityIdentifier("telegram.group.request.approve.\(row.id)")
                    Button("Отклонить", role: .destructive) { confirm(.request(row, approve: false), "Отклонить заявку \(row.title)?") }
                        .accessibilityIdentifier("telegram.group.request.decline.\(row.id)")
                }.disabled(blocked)
            }.padding(12)
            Divider()
        }
    }
    @ViewBuilder private var historyRows: some View {
        ForEach(controller.events) { event in
            VStack(alignment: .leading, spacing: 7) {
                HStack { Text(event.actor).font(.body.weight(.medium)); Spacer(); Text(Date(timeIntervalSince1970: Double(event.date)), format: .dateTime).font(.caption).foregroundStyle(.secondary) }
                Text(event.summary)
                if event.allowsCopy { eventTexts(event).textSelection(.enabled) }
                else { eventTexts(event) }
                if event.contentUnavailable { Text("Содержимое недоступно в ответе Telegram.").font(.caption).foregroundStyle(.secondary) }
            }.padding(12)
            Divider()
        }
    }
    @ViewBuilder private func eventTexts(_ event: TelegramGroupAdminEvent) -> some View {
        if let before = event.previousText { Text("Было: " + before).font(.callout).foregroundStyle(.secondary) }
        if let current = event.currentText { Text("Стало / содержимое: " + current).font(.callout) }
    }
    @ViewBuilder private var readStatus: some View {
        if controller.status == .loading { ProgressView("Обновление…").padding() }
        else if controller.status == .failed || controller.status == .timedOut {
            Text("Не удалось обновить сведения. Ранее загруженные строки могут быть устаревшими.").foregroundStyle(.secondary).padding()
            Button("Повторить", action: controller.refresh).padding().accessibilityIdentifier("telegram.group.retry")
        } else if mode != .invite && controller.links.isEmpty && controller.requests.isEmpty && controller.events.isEmpty {
            Text("В этом списке пока нет записей").foregroundStyle(.secondary).padding(24)
        }
    }
}
private struct TelegramGroupMutationStatus: View {
    @ObservedObject var controller: TelegramGroupMembershipController
    var body: some View {
        switch controller.phase {
        case .idle: EmptyView()
        case .validating:
            HStack { ProgressView("Проверка прав и выбранного действия…"); Button("Отменить", action: controller.cancelValidation).accessibilityIdentifier("telegram.group.cancelValidation") }
        case .committing: ProgressView("Ожидание подтверждения Telegram…")
        case .saved: Label("Telegram подтвердил результат", systemImage: "checkmark.circle").foregroundStyle(.green).accessibilityIdentifier("telegram.group.saved")
        case .privacyLimited: Text("Настройки приватности человека не разрешили добавление. Можно передать ему ссылку-приглашение.").foregroundStyle(.orange)
        case .changed: Text("Права или выбранные сведения изменились. Обновите список.").foregroundStyle(.orange)
        case .failed: Text("Запрос не завершился. Обновите сведения перед новым действием.").foregroundStyle(.red)
        case .uncertain:
            VStack(alignment: .leading) {
                Text("Результат неизвестен: действие могло выполниться. Повтор заблокирован до проверки свежих сведений.")
                Button("Проверить результат", action: controller.refresh).accessibilityIdentifier("telegram.group.reconcile")
            }.foregroundStyle(.orange)
        }
    }
}
private struct TelegramGroupInviteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: TelegramGroupMembershipController
    @State private var title = ""
    @State private var approval = false
    @State private var expires = false
    @State private var until = Date().addingTimeInterval(86400)
    @State private var limited = false
    @State private var usage = "10"
    @State private var pending: GroupConfirmation?
    @State private var error = false
    private var draft: TelegramGroupInviteDraft? {
        let date = expires ? Int32(exactly: until.timeIntervalSince1970.rounded(.down)) : nil
        let limit = limited ? Int32(usage) : nil
        guard (!expires || date != nil), (!limited || (limit.map { $0 > 0 } ?? false)) else { return nil }
        return .init(title: title, expireDate: date, usageLimit: limit, requiresApproval: approval)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Новая пригласительная ссылка").font(.headline); Spacer(); Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(16)
            Form {
                Section("Название") {
                    TextField("Название (необязательно)", text: $title).accessibilityIdentifier("telegram.group.create.title")
                    Text("\(title.utf16.count)/32").font(.caption).foregroundStyle(.secondary)
                }
                Section("Параметры") {
                    Toggle("Одобрять новых участников", isOn: $approval).accessibilityIdentifier("telegram.group.create.approval")
                        .onChange(of: approval) { _, value in if value { limited = false } }
                    Toggle("Ограничить срок действия", isOn: $expires).accessibilityIdentifier("telegram.group.create.expires")
                    if expires { DatePicker("Действует до", selection: $until, displayedComponents: [.date, .hourAndMinute]) }
                    Toggle("Ограничить число вступлений", isOn: $limited).disabled(approval).accessibilityIdentifier("telegram.group.create.limited")
                    if limited { TextField("Число вступлений", text: $usage).accessibilityIdentifier("telegram.group.create.usage") }
                }
                if error { Text("Сведения изменились. Обновите список.").foregroundStyle(.orange) }
                Button("Создать") {
                    guard let draft, let basis = controller.snapshot else { return }
                    pending = .init(change: .create(draft), basis: basis, contextID: controller.contextID, searchContextID: UUID(), message: "Создать ссылку в \(basis.title) с выбранными параметрами?")
                }.disabled(draft.map { !controller.canSubmit(.create($0)) } ?? true).accessibilityIdentifier("telegram.group.create.save")
            }.formStyle(.grouped)
        }.frame(width: 480, height: 480)
        .alert("Создать приглашение", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { value in
            Button("Отмена", role: .cancel) { pending = nil }
            Button("Создать") {
                let accepted = controller.apply(value.change, basis: value.basis, contextID: value.contextID)
                pending = nil; error = !accepted; if accepted { dismiss() }
            }.accessibilityIdentifier("telegram.group.create.confirm")
        } message: { Text($0.message) }
    }
}
