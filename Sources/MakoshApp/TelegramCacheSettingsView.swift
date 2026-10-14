import SwiftUI
import MakoshTelegram

extension TelegramCacheKind {
    var title: String { switch self { case .photos: "Фотографии"; case .videos: "Видео"; case .audio: "Аудио"; case .files: "Файлы" } }
}
struct TelegramCacheSettingsView: View {
    @ObservedObject var controller: TelegramCacheController
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set(TelegramCacheKind.allCases)
    @State private var confirmation: TelegramCacheConfirmation?
    @State private var notice: String?
    @State private var selectedPeers = Set<Int64>()
    @State private var selectChats = false
    @State private var peerLimit = 100
    private var scope: TelegramCacheScope { selectChats ? .peers(selectedPeers) : .all }
    private var confirmedTargets: String {
        let names = confirmation?.peerNames ?? []
        guard !names.isEmpty else { return "" }
        return "Чатов: \(names.count). " + names.prefix(5).joined(separator:", ") + (names.count > 5 ? " и ещё \(names.count - 5)" : "") + ". "
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Использование памяти").font(.headline); Spacer(); Button("Готово") { dismiss() } }.padding()
            Form {
                if let snapshot = controller.snapshot, !snapshot.peers.isEmpty {
                    Section("Чаты") {
                        Picker("Область очистки",selection:$selectChats) {
                            Text("Весь проверенный кэш").tag(false); Text("Выбранные чаты").tag(true)
                        }.disabled(controller.phase != .idle).accessibilityIdentifier("telegram.data.cache.scope")
                        if selectChats {
                            ForEach(Array(snapshot.peers.prefix(peerLimit))) { peer in
                                Toggle(isOn:Binding(get:{ selectedPeers.contains(peer.id) },set:{ enabled in
                                    if enabled { selectedPeers.insert(peer.id) } else { selectedPeers.remove(peer.id) }
                                })) {
                                    VStack(alignment:.leading,spacing:3) {
                                        HStack { Text(peer.title); Spacer(); Text(telegramByteCount(peer.totalBytes)).foregroundStyle(.secondary) }
                                        if peer.sharedBytes > 0 { Text("Общие с другими чатами: \(telegramByteCount(peer.sharedBytes))").font(.caption).foregroundStyle(.secondary) }
                                    }
                                }.disabled(controller.phase != .idle).accessibilityIdentifier("telegram.data.cache.peer.\(peer.id)")
                            }
                            if snapshot.peers.count > peerLimit { Button("Показать ещё чаты") { peerLimit += 100 }.accessibilityIdentifier("telegram.data.cache.morePeers") }
                            Text("Общие файлы, обнаруженные вне выбранных чатов, не включаются в очистку. Размеры ниже учитывают выбранную область.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Локальный кэш облачных медиа") {
                    if let snapshot = controller.snapshot {
                        LabeledContent("Доступно в выбранной области", value: telegramByteCount(TelegramCacheKind.allCases.reduce(0) { $0 + snapshot.bytes(for:$1,scope:scope) })).accessibilityIdentifier("telegram.data.cache.total")
                        ForEach(TelegramCacheKind.allCases) { kind in
                            Toggle(isOn: Binding(get: { selected.contains(kind) }, set: { value in
                                if value { selected.insert(kind) } else { selected.remove(kind) }
                            })) { HStack { Text(kind.title); Spacer(); Text(telegramByteCount(snapshot.bytes(for: kind,scope:scope))).foregroundStyle(.secondary) } }
                                .disabled(snapshot.bytes(for: kind,scope:scope) == 0 || controller.phase != .idle)
                                .accessibilityLabel(kind.title)
                                .accessibilityIdentifier("telegram.data.cache.\(kind.rawValue)")
                        }
                    } else if controller.phase == .scanning { ProgressView("Проверка кэша…") }
                    else { Text("Обновите состав кэша.").foregroundStyle(.secondary) }
                    Text("Показаны проверенные облачные медиа, доступные этому аккаунту. Это не полный размер данных приложения на диске.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Очистить выбранный кэш…", role: .destructive) {
                        confirmation = controller.prepareClear(categories: selected, contextID: controller.contextID, scope: scope)
                        notice = confirmation == nil ? "Завершите отправку, загрузку и сохранение файлов в S3, затем обновите состав кэша." : nil
                    }.disabled(controller.phase != .idle || controller.snapshot == nil ||
                        !selected.contains(where: { (controller.snapshot?.bytes(for: $0,scope:scope) ?? 0) > 0 }))
                        .accessibilityIdentifier("telegram.data.cache.clear")
                    Button("Обновить", action: controller.refresh).disabled(controller.phase == .validating || controller.phase == .clearing)
                        .accessibilityIdentifier("telegram.data.cache.refresh")
                    Text("Постоянный архив сообщений и файлы в S3 сохранятся. Исходники отправки и используемые копии останутся. Повторная загрузка очищенных файлов возможна, пока они доступны в Telegram.").font(.caption).foregroundStyle(.secondary)
                }
                if controller.phase == .validating || controller.phase == .clearing { Section { ProgressView("Проверка и очистка…") } }
                if let text = controller.error ?? notice { Section { Text(text).foregroundStyle(.red) } }
                if let status = controller.status { Section { Text(status).foregroundStyle(.secondary) } }
            }.formStyle(.grouped)
        }.frame(width: 520, height: 550)
            .onAppear(perform: controller.open).onDisappear(perform: controller.close)
            .onChange(of:controller.contextID) { _,_ in confirmation = nil; selectedPeers.formIntersection(Set(controller.snapshot?.peers.map(\.id) ?? [])) }
            .alert("Очистить локальные копии?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
                Button("Отмена", role: .cancel) {}
                Button("Очистить", role: .destructive) { if let confirmation { _ = controller.confirmClear(confirmation) } }
            } message: { Text("Выбрано \(telegramByteCount(confirmation?.byteCount ?? 0)). \(confirmedTargets)Постоянный архив и файлы в S3 сохранятся.") }
    }
}
