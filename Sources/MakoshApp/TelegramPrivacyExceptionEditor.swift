import SwiftUI
import MakoshTelegram

struct TelegramPrivacyExceptionEditor: View {
    @ObservedObject var directory: TelegramPrivacyPeerDirectoryController
    let side: TelegramPrivacyExceptionSide
    let setting: TelegramPrivacySetting
    let apply: ([TelegramPrivacyPeerID]) -> Bool
    let close: () -> Void
    @State private var peers: [TelegramPrivacyPeerID]
    @State private var names: [TelegramPrivacyPeerID: String] = [:]
    @State private var adding = false
    @State private var invalid = false
    init(directory: TelegramPrivacyPeerDirectoryController, side: TelegramPrivacyExceptionSide, setting: TelegramPrivacySetting,
         apply: @escaping ([TelegramPrivacyPeerID]) -> Bool, close: @escaping () -> Void) {
        self.directory = directory; self.side = side; self.setting = setting; self.apply = apply; self.close = close
        _peers = State(initialValue: setting.exceptionPeers(side))
    }
    private var include: [TelegramPrivacyPeerID] { Array(Set(setting.exceptionPeers(.allow) + setting.exceptionPeers(.deny) + peers)) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Отмена", action: close).accessibilityIdentifier("telegram.privacy.exceptions.cancel")
                Spacer(); Text(side == .allow ? "Всегда разрешать" : "Никогда не разрешать").font(.headline); Spacer()
                Button("Готово") { invalid = !apply(peers); if !invalid { close() } }.accessibilityIdentifier("telegram.privacy.exceptions.done")
            }.padding()
            Divider()
            Form {
                Section {
                    Button("Добавить пользователя или группу") { adding = true }.accessibilityIdentifier("telegram.privacy.exceptions.add")
                    if peers.isEmpty { Text("Нет исключений").foregroundStyle(.secondary) }
                    ForEach(peers) { peer in
                        HStack {
                            Text(names[peer] ?? privacyPeerFallback(peer)); Spacer()
                            Button { peers.removeAll { $0 == peer } } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.borderless).accessibilityLabel("Удалить исключение").accessibilityIdentifier("telegram.privacy.exception.remove.\(peer.id)")
                        }
                    }
                }
                Section {
                    Text("Изменения попадут в черновик. Для отправки в Telegram нажмите «Сохранить» на предыдущем экране.").font(.caption).foregroundStyle(.secondary)
                    if invalid { Text("Не удалось подготовить список исключений. Проверьте выбранные записи.").foregroundStyle(.red) }
                }
            }.formStyle(.grouped)
        }.frame(width: 520, height: 630)
        .onAppear { directory.search(query: "", include: include) }
        .onChange(of: directory.result) { _, value in remember(value) }
        .onDisappear { directory.close() }
        .sheet(isPresented: $adding) {
            TelegramPrivacyPeerPicker(directory: directory, initial: peers, include: include, names: names, finish: { selected, titles in
                peers = selected; names.merge(titles) { _, new in new }; adding = false
            }, close: { adding = false })
        }
    }
    private func remember(_ value: TelegramPrivacyPeerDirectory?) {
        guard let value else { return }
        for peer in value.candidates + value.existing { names[peer.id] = peer.title }
    }
}

private struct TelegramPrivacyPeerPicker: View {
    @ObservedObject var directory: TelegramPrivacyPeerDirectoryController
    let include: [TelegramPrivacyPeerID]
    let finish: ([TelegramPrivacyPeerID], [TelegramPrivacyPeerID: String]) -> Void
    let close: () -> Void
    @State private var chosen: [TelegramPrivacyPeerID]
    @State private var names: [TelegramPrivacyPeerID: String]
    @State private var query = ""
    init(directory: TelegramPrivacyPeerDirectoryController, initial: [TelegramPrivacyPeerID], include: [TelegramPrivacyPeerID],
         names: [TelegramPrivacyPeerID: String], finish: @escaping ([TelegramPrivacyPeerID], [TelegramPrivacyPeerID: String]) -> Void, close: @escaping () -> Void) {
        self.directory = directory; self.include = include; self.finish = finish; self.close = close
        _chosen = State(initialValue: initial); _names = State(initialValue: names)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Отмена", action: close).accessibilityIdentifier("telegram.privacy.peers.cancel")
                Spacer(); Text("Пользователи и группы").font(.headline); Spacer()
                Button("Готово") { finish(chosen, names) }.accessibilityIdentifier("telegram.privacy.peers.done")
            }.padding()
            TextField("Поиск в контактах и чатах аккаунта", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal).accessibilityIdentifier("telegram.privacy.peers.search")
            Text("Выбрано: \(chosen.count). Без запроса показаны контакты аккаунта.").font(.caption).foregroundStyle(.secondary).padding(10)
            if directory.status == .loading { ProgressView().controlSize(.small) }
            if directory.status == .failed || directory.status == .timedOut { Text("Не удалось загрузить список.").foregroundStyle(.secondary) }
            List {
                ForEach(directory.result?.candidates ?? []) { peer in
                    Toggle(isOn: Binding(get: { chosen.contains(peer.id) }, set: { checked in
                        if checked { if !chosen.contains(peer.id) { chosen.append(peer.id) }; names[peer.id] = peer.title }
                        else { chosen.removeAll { $0 == peer.id } }
                    })) { HStack { Text(peer.title); Spacer(); if case .chat = peer.id { Text("Группа").font(.caption).foregroundStyle(.secondary) } } }
                        .toggleStyle(.checkbox).disabled(!chosen.contains(peer.id) && atLimit(peer.id))
                        .accessibilityIdentifier("telegram.privacy.peer.\(peer.id.id)")
                }
                if directory.status == .ready && directory.result?.candidates.isEmpty == true { Text("Ничего не найдено").foregroundStyle(.secondary) }
                if directory.result?.hasMore == true { Text("Показаны первые 200 записей. Уточните поиск.").font(.caption).foregroundStyle(.secondary) }
            }
        }.frame(width: 520, height: 630)
        .onChange(of: query) { _, _ in
            directory.close()
            if query.count > 128 { query = String(query.prefix(128)) }
        }
        .task(id: query) {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled else { return }
            directory.search(query: query.trimmingCharacters(in: .whitespacesAndNewlines), include: include)
        }
        .onChange(of: directory.result) { _, value in
            guard let value else { return }; for peer in value.candidates + value.existing { names[peer.id] = peer.title }
        }
        .onDisappear { directory.close() }
    }
    private func atLimit(_ id: TelegramPrivacyPeerID) -> Bool {
        if chosen.count >= 2048 { return true }
        return chosen.filter { peer in switch (peer, id) { case (.user, .user), (.chat, .chat): true; default: false } }.count >= 1024
    }
}
private func privacyPeerFallback(_ id: TelegramPrivacyPeerID) -> String {
    switch id { case .user: "Недоступный пользователь"; case .chat: "Недоступная группа" }
}
