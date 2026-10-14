import SwiftUI
import MakoshTelegram

extension TelegramDownloadKind {
    var title: String { switch self { case .photos: "Фотографии"; case .videos: "Видео"; case .files: "Файлы" } }
}
extension TelegramDownloadPeer {
    var title: String { switch self { case .contacts: "Контакты"; case .privateChats: "Другие личные чаты"; case .groups: "Группы"; case .channels: "Каналы" } }
}
func telegramByteCount(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary) }

struct TelegramDataSettingsView: View {
    @ObservedObject var settings: TelegramAutoDownloadSettings
    @ObservedObject var cache: TelegramCacheController
    var maintenance: TelegramCacheMaintenance? = nil
    @ObservedObject var proxy: TelegramProxyController
    private struct RuleChoice: Identifiable { let id: TelegramDownloadKind; let context: UUID; let value: TelegramAutoDownloadPreferences }
    @State private var rule: RuleChoice?
    @State private var showCache = false
    @State private var showProxy = false
    @State private var resetContext: UUID?
    var body: some View {
        let context = settings.contextID
        Form {
            Section {
                Button { showCache = true } label: { row("Использование памяти", detail: cache.snapshot.map { telegramByteCount($0.totalBytes) }) }
                    .buttonStyle(.plain).disabled(settings.accountID == nil).accessibilityIdentifier("telegram.data.cache")
            }
            Section("Автозагрузка медиа") {
                Toggle("Автоматически загружать медиа", isOn: Binding(get: { settings.preferences.enabled }, set: { value in
                    var p = settings.preferences; p.enabled = value; settings.update(p, contextID: context)
                })).accessibilityIdentifier("telegram.data.auto.enabled")
                ForEach(TelegramDownloadKind.allCases) { kind in
                    Button { rule = .init(id: kind, context: context, value: settings.preferences) } label: {
                        row(kind.title, detail: settings.preferences[kind].peers.isEmpty ? "Выключено" : "До \(telegramByteCount(settings.preferences[kind].limit))")
                    }.buttonStyle(.plain).accessibilityIdentifier("telegram.data.auto.\(kind.rawValue)")
                }
                Button("Сбросить настройки автозагрузки…") { resetContext = context }.accessibilityIdentifier("telegram.data.auto.reset")
            }.disabled(settings.accountID == nil || settings.error != nil)
            if let error = settings.error { Section { Text(error).foregroundStyle(.red) } }
            if settings.error != nil {
                Section { Button("Восстановить настройки по умолчанию…") { resetContext = context }.disabled(settings.accountID == nil) }
            }
            Section {
                Text(settings.accountID == nil ? "Автозагрузка и кэш доступны после подключения аккаунта. Прокси можно настроить перед входом." :
                    "Настройки действуют для этого аккаунта на этом Mac. Загружаются только видимые входящие сообщения активного окна. Правило сохранения файлов в S3 задаётся отдельно в каждом чате.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Прокси") {
                Button { showProxy = true } label: { row("Настройки прокси", detail: proxy.enabled.map { $0 ? "Включён" : "Выключен" }) }
                    .buttonStyle(.plain).accessibilityIdentifier("telegram.data.proxy")
            }
        }.formStyle(.grouped)
            .sheet(item: $rule) { item in TelegramDownloadRuleEditor(settings: settings, kind: item.id, contextID: item.context, value: item.value) }
            .sheet(isPresented: $showCache) { TelegramCacheSettingsView(controller: cache,maintenance:maintenance) }
            .sheet(isPresented: $showProxy) { TelegramProxySettingsView(controller: proxy) }
            .alert("Сбросить автозагрузку?", isPresented: Binding(get: { resetContext != nil }, set: { if !$0 { resetContext = nil } })) {
                Button("Отмена", role: .cancel) {}
                Button("Сбросить", role: .destructive) { if let resetContext { settings.reset(contextID: resetContext) } }
            } message: { Text("Автозагрузка выключится. Фото и видео: до 10 МБ для всех чатов; файлы: выключены. Уже сохранённые файлы останутся.") }
    }
    private func row(_ title: String, detail: String?) -> some View {
        HStack { Text(title); Spacer(); if let detail { Text(detail).foregroundStyle(.secondary) }; Image(systemName: "chevron.right").foregroundStyle(.secondary) }.frame(minHeight: 30)
    }
}

private struct TelegramDownloadRuleEditor: View {
    @ObservedObject var settings: TelegramAutoDownloadSettings
    let kind: TelegramDownloadKind, contextID: UUID
    @State var value: TelegramAutoDownloadPreferences
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { Button("Отмена") { dismiss() }; Spacer(); Text(kind.title).font(.headline); Spacer()
                Button("Сохранить") { if settings.update(value, contextID: contextID) { dismiss() } else { error = "Настройки изменились. Откройте редактор заново." } }
                    .disabled(settings.contextID != contextID).accessibilityIdentifier("telegram.data.auto.save")
            }.padding()
            Form {
                Section("Автоматически загружать") {
                    ForEach(TelegramDownloadPeer.allCases, id: \.self) { peer in
                        Toggle(peer.title, isOn: Binding(get: { value[kind].peers.contains(peer) }, set: { enabled in
                            if enabled { value[kind].peers.insert(peer) } else { value[kind].peers.remove(peer) }
                        })).accessibilityIdentifier("telegram.data.auto.peer.\(peer.rawValue)")
                    }
                }
                Section("Максимальный размер") {
                    Picker("Размер файла", selection: Binding(get: { value[kind].limit }, set: { value[kind].limit = $0 })) {
                        ForEach(Array(Set([Int64(1),5,10,50,100,500,1024,2048].map { $0 * 1_048_576 } + [value[kind].limit])).sorted(), id: \.self) { size in
                            Text(telegramByteCount(size)).tag(size)
                        }
                    }.accessibilityIdentifier("telegram.data.auto.limit")
                    Text("Файлы с неизвестным размером, платные медиа и спойлеры требуют ручной загрузки.").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if settings.contextID != contextID { Text("Настройки изменились. Закройте редактор и откройте его заново.").foregroundStyle(.secondary) }
            }.formStyle(.grouped)
        }.frame(width: 480, height: 420)
    }
}
