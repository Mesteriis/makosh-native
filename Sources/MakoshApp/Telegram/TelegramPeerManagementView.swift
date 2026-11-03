import SwiftUI
import MakoshTelegram

struct TelegramPeerManagementStatusView: View {
    @ObservedObject var controller: TelegramPeerManagementController
    var body: some View {
        switch controller.mutationStatus {
        case .idle: EmptyView()
        case .saving: ProgressView("Сохранение в Telegram…")
        case .saved: Label("Telegram подтвердил изменение", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .failed: Text("Telegram не принял изменение. Обновите сведения перед повтором.").foregroundStyle(.red)
        case .changed: Text("Сведения или права изменились. Проверьте обновлённые значения.").foregroundStyle(.orange)
        case .uncertain:
            VStack(alignment: .leading) {
                Text("Результат запроса неизвестен. Он мог быть выполнен. Проверьте сведения перед новым изменением.")
                Button("Проверить сведения", action: controller.refresh)
            }.foregroundStyle(.orange)
        }
    }
}

struct TelegramPeerInfoEditor: View {
    @ObservedObject var controller: TelegramPeerManagementController
    var avatarEditing: TelegramAvatarEditingController? = nil
    var avatarTarget: TelegramAvatarTarget? = nil
    @State private var name = ""
    @State private var about = ""
    @State private var basis: TelegramPeerManagementSnapshot?
    @State private var context = UUID()
    private var busy: Bool { controller.mutationStatus == .saving || controller.status != .ready }
    var body: some View {
        Form {
            if let avatarEditing, let avatarTarget, controller.snapshot?.canEditInfo == true {
                Section {
                    TelegramAvatarEditingButton(controller: avatarEditing, target: avatarTarget, title: "Изменить фотографию")
                }
            }
            Section("Название") {
                TextField("Название", text: $name).accessibilityIdentifier("telegram.profile.edit.title")
                Text("\(name.utf16.count)/255").font(.caption).foregroundStyle(.secondary)
                Button("Сохранить название") {
                    guard let basis else { return }
                    controller.apply(.title(previous: basis.title, value: name), contextID: context)
                }.disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.utf16.count > 255 || name == basis?.title)
                    .accessibilityIdentifier("telegram.profile.edit.saveTitle")
            }
            Section("Описание") {
                TextEditor(text: $about).frame(minHeight: 100).accessibilityIdentifier("telegram.profile.edit.about")
                Text("\(about.utf16.count)/255").font(.caption).foregroundStyle(.secondary)
                Button("Сохранить описание") {
                    guard let basis else { return }
                    controller.apply(.about(previous: basis.about, value: about), contextID: context)
                }.disabled(busy || about.utf16.count > 255 || about == (basis?.about ?? ""))
                    .accessibilityIdentifier("telegram.profile.edit.saveAbout")
            }
            Section { TelegramPeerManagementStatusView(controller: controller) }
        }.formStyle(.grouped)
            .onAppear(perform: reset)
            .onChange(of: controller.snapshot) { _, _ in
                if controller.mutationStatus == .saved || controller.mutationStatus == .changed { reset() }
            }
    }
    private func reset() {
        basis = controller.snapshot; name = basis?.title ?? ""; about = basis?.about ?? ""; context = controller.contextID
    }
}

struct TelegramPeerMembersView: View {
    @ObservedObject var controller: TelegramPeerManagementController
    @ObservedObject var avatars: TelegramAvatarStore
    @State private var query = ""
    @State private var selected: TelegramPeerMember?
    var body: some View {
        VStack(spacing: 0) {
            Picker("Список", selection: Binding(get: { controller.category ?? .members }, set: { controller.show($0, query: query) })) {
                ForEach(TelegramPeerMemberCategory.allCases.filter { category in
                    guard let snapshot = controller.snapshot else { return false }
                    switch category {
                    case .members: return snapshot.canViewMembers
                    case .administrators: return snapshot.canViewAdministrators
                    case .restricted, .removed: return snapshot.canRestrict && !snapshot.basicGroup
                    }
                }) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).padding(12).accessibilityIdentifier("telegram.profile.members.category")
                .disabled(controller.mutationStatus == .saving)
            TextField("Поиск участников", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 12)
                .accessibilityIdentifier("telegram.profile.members.search")
                .disabled(controller.mutationStatus == .saving)
                .task(id: query) {
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                    guard query.trimmingCharacters(in: .whitespacesAndNewlines) != controller.query else { return }
                    controller.show(controller.category ?? .members, query: query)
                }
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(controller.members) { member in
                        HStack(spacing: 12) {
                            TelegramChatAvatar(title: member.title, peerID: member.id, store: avatars, size: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(member.title).font(.body.weight(.medium))
                                Text(member.rank.flatMap { $0.isEmpty ? nil : $0 } ?? member.role.title).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if member.editable, member.id != controller.snapshot?.accountID,
                               (controller.snapshot?.canPromote == true && (member.role == .member || member.role == .administrator)) ||
                                (controller.snapshot?.canRestrict == true && member.role != .creator && member.role != .administrator) {
                                Button("Права") { selected = member }.accessibilityIdentifier("telegram.profile.member.edit.\(member.id)")
                            }
                        }.padding(12)
                        Divider().padding(.leading, 60)
                    }
                    if controller.status == .loading { ProgressView().padding() }
                    else if controller.status == .failed || controller.status == .timedOut {
                        Text("Не удалось получить список. Ранее загруженные строки могут быть устаревшими.").foregroundStyle(.secondary).padding()
                        Button("Повторить", action: controller.refresh).padding(.bottom)
                    } else if controller.members.isEmpty { Text("Нет участников для этого списка и запроса").foregroundStyle(.secondary).padding(24) }
                    if controller.canLoadMore { Button("Загрузить ещё", action: controller.loadMore).padding().accessibilityIdentifier("telegram.profile.members.more") }
                }
            }.accessibilityIdentifier("telegram.profile.members.list")
            TelegramPeerManagementStatusView(controller: controller).font(.callout).padding(12)
        }.sheet(item: $selected) { member in
            TelegramPeerMemberEditor(controller: controller, member: member)
        }
    }
}

private struct TelegramPeerMemberEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: TelegramPeerManagementController
    let member: TelegramPeerMember
    @State private var admin = true
    @State private var rights: Int32 = 0
    @State private var bans: Int32 = 0
    @State private var rank = ""
    @State private var permanent = true
    @State private var until = Date().addingTimeInterval(86400)
    @State private var context = UUID()
    @State private var pending: TelegramPeerChange?
    private var canAdmin: Bool { controller.snapshot?.canPromote == true && (member.role == .member || member.role == .administrator) }
    private var canRestrict: Bool { controller.snapshot?.canRestrict == true && member.role != .creator && member.role != .administrator }
    private var expiration: Int32? {
        if permanent { return Int32.max }
        return telegramPeerRestrictionExpiration(until)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(member.title).font(.headline); Spacer(); Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(16)
            Divider()
            Form {
                if canAdmin && canRestrict {
                    Picker("Действие", selection: $admin) { Text("Администратор").tag(true); Text("Ограничения").tag(false) }.pickerStyle(.segmented)
                }
                if admin {
                    Section("Права администратора") {
                        if controller.snapshot?.basicGroup == true {
                            Toggle("Администратор", isOn: flag(1, value: $rights))
                        } else {
                            ForEach(TelegramPeerRight.administrators.filter { $0.id & (controller.snapshot?.grantableRights ?? 0) != 0 }) { right in
                                Toggle(right.title, isOn: flag(right.id, value: $rights))
                            }
                            TextField("Должность", text: $rank).accessibilityIdentifier("telegram.profile.member.rank")
                            Text("\(rank.utf16.count)/16").font(.caption).foregroundStyle(.secondary)
                        }
                        if member.role == .administrator { Button("Снять права администратора") { rights = 0; rank = "" } }
                        if rights & ~(controller.snapshot?.grantableRights ?? 0) != 0 {
                            Text("У участника есть права, которые вы не можете изменять.").foregroundStyle(.orange)
                        }
                    }
                } else {
                    Section("Запреты участника") {
                        ForEach(controller.snapshot?.basicGroup == true ? Array(TelegramPeerRight.restrictions.prefix(1)) : TelegramPeerRight.restrictions) { right in Toggle(right.title, isOn: flag(right.id, value: $bans)) }
                        if controller.snapshot?.basicGroup != true {
                            Toggle("Без срока", isOn: $permanent)
                            if !permanent {
                                DatePicker("До", selection: $until, in: Date().addingTimeInterval(60)...Date().addingTimeInterval(365 * 86400), displayedComponents: [.date, .hourAndMinute])
                                Text("От 1 минуты до 365 дней. Для постоянного ограничения включите «Без срока».").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if member.bannedRights != 0 { Button("Снять все ограничения") { bans = 0; permanent = true } }
                    }
                }
                Section {
                    Button("Сохранить…") {
                        pending = admin ? .administrator(member: member, rights: rights, rank: rank)
                            : expiration.map { .restriction(member: member, rights: bans, untilDate: $0) }
                    }.disabled(controller.status != .ready || controller.mutationStatus == .saving ||
                        controller.mutationStatus == .uncertain || (admin ? !canAdmin || rank.utf16.count > 16 || rights & ~(controller.snapshot?.grantableRights ?? 0) != 0 : !canRestrict || expiration == nil))
                        .accessibilityIdentifier("telegram.profile.member.save")
                    TelegramPeerManagementStatusView(controller: controller)
                }
            }.formStyle(.grouped)
        }.frame(width: 500, height: 640)
            .onAppear {
                context = controller.contextID; admin = canAdmin; rights = member.adminRights; bans = member.bannedRights; rank = member.rank ?? ""
                permanent = member.untilDate == 0 || member.untilDate == Int32.max
                if !permanent { until = Date(timeIntervalSince1970: Double(member.untilDate)) }
            }
            .confirmationDialog(admin ? "Изменить права администратора \(member.title)?" : "Изменить ограничения \(member.title)?",
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                    Button("Подтвердить изменение") {
                        if let pending, controller.apply(pending, contextID: context) { dismiss() }
                        pending = nil
                    }
                    Button("Отмена", role: .cancel) { pending = nil }
                } message: {
                    Text(admin ? "Права будут изменены в Telegram." : "Включённый запрет входа исключает участника из чата. Остальные запреты ограничивают его сообщения.")
                }
    }
    private func flag(_ mask: Int32, value: Binding<Int32>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue & mask != 0 }, set: { enabled in
            value.wrappedValue = enabled ? value.wrappedValue | mask : value.wrappedValue & ~mask
        })
    }
}

extension TelegramPeerMemberCategory {
    var title: String {
        switch self { case .members: "Участники"; case .administrators: "Администраторы"; case .restricted: "Ограничения"; case .removed: "Исключённые" }
    }
}
private extension TelegramPeerMember.Role {
    var title: String {
        switch self { case .creator: "Владелец"; case .administrator: "Администратор"; case .member: "Участник"; case .restricted: "Ограничен"; case .removed: "Исключён" }
    }
}
