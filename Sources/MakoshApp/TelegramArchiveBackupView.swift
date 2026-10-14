import SwiftUI
import AppKit
import MakoshCore
import MakoshTelegram

struct TelegramArchiveBackupView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: TelegramArchiveBackupModel
    @StateObject private var panels = TelegramBackupPanels()
    @State private var panelTask: Task<Void, Never>?
    @State private var confirmation: RestoreConfirmation?
    @State private var viewingRestored = false
    private struct RestoreConfirmation: Identifiable {
        let id = UUID()
        let receipt: ArchiveBackupInspection
        let schema: String
    }
    init(context: TelegramArchiveBackupContext?) { _model = StateObject(wrappedValue: TelegramArchiveBackupModel(context: context)) }
    private var disabled: Bool { model.busy || panelTask != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Резервная копия архива", systemImage: "externaldrive.badge.checkmark").font(.title2.bold())
                Spacer()
                Button("Закрыть") { dismiss() }.disabled(disabled).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("telegram.backup.close")
            }
            if model.context?.synthetic == true {
                Text("СИНТЕТИЧЕСКАЯ ПРОВЕРКА • отдельные PostgreSQL/S3, без личных аккаунтов и Связки ключей")
                    .font(.caption.bold()).foregroundStyle(.secondary)
            }
            Form {
                Section("Создать копию") {
                    Text("История, правки, удаления и сохранённые файлы S3. Ключ восстановления сохраняется отдельно; для чтения нужны оба файла.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Сохранить копию и отдельный ключ…", action: chooseExport).disabled(disabled || model.context == nil)
                        .accessibilityIdentifier("telegram.backup.export")
                }
                Section("Проверить и восстановить") {
                    HStack {
                        Button("Выбрать копию…") { chooseInput(package: true) }.accessibilityIdentifier("telegram.backup.package")
                        Text(model.package?.lastPathComponent ?? "Не выбрана").lineLimit(1).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Выбрать ключ…") { chooseInput(package: false) }.accessibilityIdentifier("telegram.backup.key")
                        Text(model.recoveryKey?.lastPathComponent ?? "Не выбран").lineLimit(1).foregroundStyle(.secondary)
                    }
                    Button("Проверить копию", action: model.inspect)
                        .disabled(model.package == nil || model.recoveryKey == nil).accessibilityIdentifier("telegram.backup.inspect")
                    if let receipt = model.inspection {
                        LabeledContent("Снимки сообщений", value: String(receipt.summary.messageVersions))
                        LabeledContent("Файлы S3", value: String(receipt.summary.files))
                        LabeledContent("История", value: ByteCountFormatter.string(fromByteCount: receipt.summary.databaseBytes, countStyle: .file))
                        LabeledContent("Зашифрованные файлы", value: ByteCountFormatter.string(fromByteCount: receipt.summary.encryptedBytes, countStyle: .file))
                        TextField("Новый архив PostgreSQL", text: $model.targetSchema).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("telegram.backup.schema")
                        Text("Строчная латиница, цифры и _, до 63 символов. Первый символ — буква.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Создаётся новый архив. Текущий архив продолжит запись. Имеющиеся данные не перезаписываются. Для выключенного сохранения нужны уже существующие объекты S3.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Восстановить в новый архив…") { confirmation = .init(receipt: receipt, schema: model.targetSchema) }
                            .disabled(!model.canRestore).accessibilityIdentifier("telegram.backup.restore")
                    }
                }.disabled(disabled)
            }.formStyle(.grouped)
            if let schema = model.restoredSchema {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Новый архив: \(schema)").font(.caption.monospaced()).textSelection(.enabled)
                    Button("Открыть восстановленный архив") { viewingRestored = true }.accessibilityIdentifier("telegram.backup.openRestored")
                    Text("Просмотр и выгрузка файлов доступны сразу. Выбор рабочего архива при следующем запуске описан в документации восстановления.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.callout).accessibilityIdentifier("telegram.backup.status")
                Spacer()
                if model.busy { Button("Отменить", action: model.cancel).disabled(model.cancelling).accessibilityIdentifier("telegram.backup.cancel") }
            }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.red).accessibilityIdentifier("telegram.backup.error") }
        }.padding(24).frame(width: 650, height: 690)
            .background(TelegramBackupWindowAnchor(owner: panels).frame(width: 0, height: 0))
            .interactiveDismissDisabled(model.busy)
            .sheet(item: $confirmation) { value in
                VStack(alignment: .leading, spacing: 18) {
                    Text("Восстановить архив?").font(.title2.bold())
                    Text("\(value.receipt.summary.messageVersions) снимков и \(value.receipt.summary.files) файлов. Новый архив: \(value.schema)").textSelection(.enabled)
                    Text("Копия будет проверена повторно. Текущий архив остаётся рабочим; восстановленная история откроется отдельно.").foregroundStyle(.secondary)
                    HStack {
                        Button("Отмена") { confirmation = nil }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Восстановить") { confirmation = nil; model.restore(confirmed: value.receipt, schema: value.schema) }
                            .accessibilityIdentifier("telegram.backup.confirm")
                    }
                }.padding(24).frame(width: 480)
            }
            .sheet(isPresented: $viewingRestored) {
                if let context = model.context, let schema = model.restoredSchema { TelegramRestoredArchiveView(context: context, schema: schema) }
            }
            .onDisappear { panelTask?.cancel(); panels.cancel(); model.cancel() }
    }
    private func chooseExport() {
        guard !disabled else { return }
        panelTask = Task { @MainActor in
            defer { panelTask = nil }
            guard let destination = await panels.save(name: "Makosh-\(Date.now.formatted(.iso8601.year().month().day())).makoshbackup"), !Task.isCancelled,
                  let key = await panels.save(name: "Makosh-recovery-\(UUID().uuidString.prefix(8)).makoshkey"), !Task.isCancelled else { return }
            model.export(to: destination, key: key)
        }
    }
    private func chooseInput(package: Bool) {
        guard !disabled else { return }
        panelTask = Task { @MainActor in
            defer { panelTask = nil }
            guard let url = await panels.open(directory: package), !Task.isCancelled else { return }
            if package { model.select(package: url) } else { model.select(key: url) }
        }
    }
}

@MainActor private final class TelegramBackupPanels: ObservableObject {
    weak var view: NSView?
    private var panel: NSSavePanel?
    func save(name: String) async -> URL? {
        let value = NSSavePanel(); value.nameFieldStringValue = name
        value.canCreateDirectories = true; value.title = name.hasSuffix("makoshkey") ? "Сохранить отдельный ключ восстановления" : "Сохранить резервную копию"
        return await present(value)
    }
    func open(directory: Bool) async -> URL? {
        let value = NSOpenPanel(); value.canChooseDirectories = directory; value.canChooseFiles = !directory
        value.allowsMultipleSelection = false; value.title = directory ? "Выберите папку .makoshbackup" : "Выберите отдельный файл .makoshkey"
        return await present(value)
    }
    private func present(_ value: NSSavePanel) async -> URL? {
        guard let window = view?.window, panel == nil else { return nil }
        panel = value
        return await withCheckedContinuation { continuation in
            value.beginSheetModal(for: window) { [weak self] response in
                self?.panel = nil; continuation.resume(returning: response == .OK ? value.url : nil)
            }
        }
    }
    func cancel() { panel?.cancel(nil) }
}
private struct TelegramBackupWindowAnchor: NSViewRepresentable {
    let owner: TelegramBackupPanels
    func makeNSView(context: Context) -> NSView { let value = NSView(); owner.view = value; return value }
    func updateNSView(_ nsView: NSView, context: Context) { owner.view = nsView }
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {}
}
