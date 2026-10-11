import SwiftUI
import AppKit
import MakoshTelegram
import MakoshCore

/// A single conversation owns one panel/worker. Cache leases span the async work.
@MainActor
final class TelegramAttachmentActions: ObservableObject {
    @Published private(set) var isBusy = false
    @Published var preview: TelegramImagePreview?
    @Published var archivedPreview: TelegramArchivedFilePreview?
    @Published var error: String?
    @Published private(set) var saved = false
    private var task: Task<Void, Never>?
    private var panel: NSSavePanel?

    func showPreview(media: TelegramMediaController, key: TelegramMediaKey) {
        guard !isBusy else { return }
        begin()
        task = Task { [weak self] in
            guard let self else { return }
            defer { finish() }
            do {
                let available = try await media.withDownloadedFile(for: key) { url, size in
                    let image = try await TelegramDownloadedFileIO.image(source: url, expectedSize: size)
                    try Task.checkCancellation()
                    self.preview = image
                }
                if !available { throw TelegramFileError.unavailable }
            } catch is CancellationError { }
            catch { report(error, media: media, key: key) }
        }
    }

    func save(media: TelegramMediaController, key: TelegramMediaKey, name: String) {
        guard !isBusy else { return }
        begin()
        task = Task { [weak self] in
            guard let self else { return }
            defer { finish() }
            do {
                let available = try await media.withDownloadedFile(for: key) { url, size in
                    guard let destination = await self.chooseDestination(name: name) else { return }
                    try Task.checkCancellation()
                    try await TelegramDownloadedFileIO.copy(source: url, expectedSize: size, destination: destination)
                    try Task.checkCancellation()
                    self.saved = true
                }
                if !available { throw TelegramFileError.unavailable }
            } catch is CancellationError { }
            catch { report(error, media: media, key: key) }
        }
    }

    func saveArchived(files: TelegramFileArchiveController,record: ArchiveFileRecord) {
        guard !isBusy else { return }
        begin()
        task = Task { [weak self] in
            guard let self else { return }
            defer { finish() }
            do {
                guard let destination = await chooseDestination(name: record.attachment.name,title: "Сохранить файл из архива S3") else { return }
                try Task.checkCancellation()
                try await files.export(record,to: destination)
                try Task.checkCancellation()
                self.saved = true
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                self.error = "Не удалось получить и проверить копию файла из S3. Существующий файл не заменён."
            }
        }
    }

    func previewArchived(files: TelegramFileArchiveController, record: ArchiveFileRecord) {
        guard !isBusy, archivedPreview == nil else { return }
        begin()
        task = Task { [weak self] in
            guard let self else { return }
            defer { finish() }
            do {
                let preview = try await files.preview(record)
                try Task.checkCancellation()
                archivedPreview = preview
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                self.error = "Не удалось получить и проверить копию файла из S3. Повторите просмотр после восстановления хранилища."
            }
        }
    }

    func cancel() {
        task?.cancel()
        panel?.cancel(nil)
        preview = nil; archivedPreview = nil; error = nil; saved = false
        // Keep busy until the worker has stopped; rapid clicks cannot multiply decoders.
    }

    private func begin() { isBusy = true; error = nil; saved = false }
    private func finish() { task = nil; isBusy = false }
    private func report(_ error: Error, media: TelegramMediaController, key: TelegramMediaKey) {
        guard !Task.isCancelled else { return }
        let safe = error as? TelegramFileError ?? .unavailable
        self.error = safe.localizedDescription
        if safe == .unavailable { media.cancel(key) }
    }

    private func chooseDestination(name: String,title: String = "Сохранить вложение Telegram") async -> URL? {
        guard !Task.isCancelled else { return nil }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = telegramAttachmentName(name)
        panel.canCreateDirectories = true
        panel.title = title
        self.panel = panel
        defer { self.panel = nil }
        return await withCheckedContinuation { continuation in
            let complete: (NSApplication.ModalResponse) -> Void = { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
            if var window = NSApp.keyWindow ?? NSApp.mainWindow {
                while let child = window.attachedSheet { window = child }
                panel.beginSheetModal(for: window, completionHandler: complete)
            }
            else { panel.begin(completionHandler: complete) }
        }
    }

    isolated deinit { task?.cancel(); panel?.cancel(nil) }
}

struct TelegramAttachmentRow<MenuContent: View>: View {
    let attachment: TelegramAttachment
    let contextID: UUID
    let hasCaption: Bool
    @ObservedObject var media: TelegramMediaController
    @ObservedObject var actions: TelegramAttachmentActions
    @ObservedObject var playback: TelegramPlaybackController
    @ViewBuilder let menu: () -> MenuContent
    @State private var reveal = TelegramMediaRevealState()

    var body: some View {
        if attachment.kind == .photo || attachment.playback == .video {
            TelegramSingleMediaLayout(attachment: attachment, hasCaption: hasCaption) {
                TelegramVisualMediaView(attachment: attachment, contextID: contextID, media: media, actions: actions,
                    playback: playback, identifierPrefix: "telegram.visual", contentMode: .fit, menu: menu)
            }.clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("telegram.attachment." + attachment.id)
        } else { fileCard }
    }

    private var fileCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(attachment.name, systemImage: attachment.kind == .photo ? "photo" : "doc")
                .font(.callout.weight(.medium)).lineLimit(2)
            if let bytes = attachment.byteCount {
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
            }
            if attachment.kind == .unsupported {
                Text("Этот тип вложения пока недоступен.").font(.caption).foregroundStyle(.secondary)
            } else if reveal.isHidden(attachment, contextID: contextID) {
                Button("Показать скрытое вложение", systemImage: "eye") { reveal.reveal(attachment, contextID: contextID) }
                    .accessibilityIdentifier("telegram.attachment.reveal." + attachment.id)
            } else {
                if attachment.canDownload { controls(purpose: .full) }
                if attachment.hasPreview { controls(purpose: .preview) }
                if !attachment.canDownload && !attachment.hasPreview {
                    Text("Файл недоступен в этом сообщении.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("telegram.attachment." + attachment.id)
    }

    @ViewBuilder private func controls(purpose: TelegramMediaPurpose) -> some View {
        let key = TelegramMediaKey(attachmentID: attachment.id, purpose: purpose)
        let prefix = "telegram.media." + attachment.id + (purpose == .full ? ".full" : ".preview")
        let phase = media.phase(for: key)
        HStack(spacing: 8) {
            switch phase {
            case .idle, .cancelled, .failed, .timedOut:
                Button(phase == .idle ? (purpose == .full ? "Загрузить файл" : "Загрузить превью") : "Повторить загрузку") {
                    media.start(attachment, purpose: purpose)
                }.accessibilityIdentifier(prefix + ".download")
                if phase == .cancelled { Text("Отменено").font(.caption).foregroundStyle(.secondary) }
                if phase == .failed || phase == .timedOut {
                    Text(phase == .timedOut ? "Загрузка занимает больше времени." : "Не удалось загрузить.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .downloading(let progress):
                if let progress { ProgressView(value: progress).frame(width: 90); Text(progress, format: .percent.precision(.fractionLength(0))).font(.caption) }
                else { ProgressView().controlSize(.mini) }
                Button("Отменить") { media.cancel(key) }.accessibilityIdentifier(prefix + ".cancel")
            case .ready:
                Text(purpose == .full ? "Файл загружен" : "Превью загружено").font(.caption).foregroundStyle(.secondary)
                if purpose == .full {
                    Button("Сохранить…") { actions.save(media: media, key: key, name: attachment.name) }
                        .disabled(actions.isBusy || playback.isBusy).accessibilityIdentifier(prefix + ".save")
                    if attachment.playback != nil {
                        Button("Открыть проигрыватель") { playback.open(attachment: attachment, media: media) }
                            .disabled(actions.isBusy || playback.isBusy)
                            .accessibilityIdentifier(prefix + ".playback")
                    }
                }
                if purpose == .preview || attachment.kind == .photo {
                    Button("Посмотреть") { actions.showPreview(media: media, key: key) }
                        .disabled(actions.isBusy || playback.isBusy).accessibilityIdentifier(prefix + ".open")
                }
            }
        }.controlSize(.small)
    }
}

private struct TelegramSingleMediaLayout: Layout {
    let attachment: TelegramAttachment
    let hasCaption: Bool
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        TelegramSingleMediaPresentation.size(attachment, availableWidth: Double(proposal.width ?? 420), hasCaption: hasCaption) ?? .zero
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
            proposal: .init(width: bounds.width, height: bounds.height))
    }
}
