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
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Использование памяти").font(.headline); Spacer(); Button("Готово") { dismiss() } }.padding()
            Form {
                Section("Облачные копии медиа") {
                    if let snapshot = controller.snapshot {
                        LabeledContent("Доступно для проверки", value: telegramByteCount(snapshot.totalBytes)).accessibilityIdentifier("telegram.data.cache.total")
                        ForEach(TelegramCacheKind.allCases) { kind in
                            Toggle(isOn: Binding(get: { selected.contains(kind) }, set: { value in
                                if value { selected.insert(kind) } else { selected.remove(kind) }
                            })) { HStack { Text(kind.title); Spacer(); Text(telegramByteCount(snapshot.bytes(for: kind))).foregroundStyle(.secondary) } }
                                .disabled(snapshot.bytes(for: kind) == 0 || controller.phase != .idle)
                                .accessibilityLabel(kind.title)
                                .accessibilityIdentifier("telegram.data.cache.\(kind.rawValue)")
                        }
                    } else if controller.phase == .scanning { ProgressView("Проверка кэша…") }
                    else { Text("Обновите состав кэша.").foregroundStyle(.secondary) }
                    Text("Показаны проверенные облачные медиа, доступные этому аккаунту. Это не полный размер данных приложения на диске.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Очистить выбранный кэш…", role: .destructive) {
                        confirmation = controller.prepareClear(categories: selected, contextID: controller.contextID)
                        notice = confirmation == nil ? "Завершите отправку, загрузку и сохранение файлов в S3, затем обновите состав кэша." : nil
                    }.disabled(controller.phase != .idle || controller.snapshot == nil ||
                        !selected.contains(where: { (controller.snapshot?.bytes(for: $0) ?? 0) > 0 }))
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
            .alert("Очистить локальные копии?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
                Button("Отмена", role: .cancel) {}
                Button("Очистить", role: .destructive) { if let confirmation { _ = controller.confirmClear(confirmation) } }
            } message: { Text("Выбрано \(telegramByteCount(confirmation?.byteCount ?? 0)). Постоянный архив и файлы в S3 сохранятся.") }
    }
}
