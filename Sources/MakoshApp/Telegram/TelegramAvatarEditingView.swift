import SwiftUI
import AppKit
import MakoshTelegram
import MakoshCore

struct TelegramAvatarEditingView: View {
    @ObservedObject var controller: TelegramAvatarEditingController
    let target: TelegramAvatarTarget
    let close: () -> Void
    @State private var selection: AvatarCropPresentation?
    @State private var picking = false
    @State private var pickerTask: Task<Void, Never>?
    @State private var error: String?
    @State private var confirming = false
    private var enabled: Bool { controller.status == .ready && controller.snapshot?.canEdit == true && !controller.isBusy && controller.phase != .uncertain && !picking }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(target.kind == .fallback ? "Публичная фотография" : "Фотография профиля").font(.headline)
                Spacer()
                Button("Готово", action: close).disabled(controller.isBusy).accessibilityIdentifier("telegram.avatar.close")
            }.padding()
            Divider()
            Form {
                Section {
                    if let snapshot = controller.snapshot {
                        Text(snapshot.title).font(.title3.bold()).accessibilityIdentifier("telegram.avatar.title")
                        if let photo = controller.draft?.photo {
                            Image(decorative: photo.preview.image, scale: 1).resizable().scaledToFit()
                                .frame(width: 144, height: 144).clipShape(Circle())
                                .accessibilityLabel("Новая фотография, ещё не сохранена")
                        }
                        if target.kind == .fallback {
                            Text("Эту фотографию увидят пользователи, которым основная фотография скрыта настройками приватности.").font(.callout).foregroundStyle(.secondary)
                        }
                        Button("Выбрать фотографию…", action: choose).disabled(!enabled)
                            .accessibilityIdentifier("telegram.avatar.choose")
                        Button("Удалить текущую фотографию", role: .destructive) {
                            if controller.stageRemoval(contextID: controller.contextID) { confirming = true }
                        }.disabled(!enabled || snapshot.photoID == nil).accessibilityIdentifier("telegram.avatar.remove")
                        if !snapshot.canEdit { Text("Нет прав на изменение фотографии.").foregroundStyle(.secondary) }
                    } else if controller.status == .loading { ProgressView("Загружаем фотографию…") }
                }
                if let draft = controller.draft {
                    Section("Подготовленное изменение") {
                        Text(draft.photo == nil ? "Удаление текущей фотографии ещё не подтверждено." : "Новая фотография ещё не сохранена.")
                        Button("Сохранить") { confirming = true }.disabled(!enabled).accessibilityIdentifier("telegram.avatar.save")
                        Button("Отменить изменение", action: controller.discardDraft).disabled(controller.isBusy).accessibilityIdentifier("telegram.avatar.discard")
                    }
                }
                Section {
                    Text(error ?? statusText).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("telegram.avatar.status")
                    if picking || controller.isBusy { ProgressView(value: Double(controller.progress)).accessibilityIdentifier("telegram.avatar.progress") }
                    if controller.phase == .uploading {
                        Button("Отменить загрузку", action: controller.cancelUpload).accessibilityIdentifier("telegram.avatar.cancelUpload")
                    }
                    Button("Обновить") { error = nil; controller.refresh() }.disabled(controller.isBusy || picking)
                        .accessibilityIdentifier("telegram.avatar.refresh")
                }
            }.formStyle(.grouped)
        }.frame(width: 480, height: 610)
        .onAppear { controller.open(target) }
        .onDisappear { pickerTask?.cancel(); selection = nil; controller.close() }
        .onChange(of: controller.contextID) { _, _ in pickerTask?.cancel(); selection = nil; confirming = false }
        .interactiveDismissDisabled(controller.isBusy)
        .sheet(item: $selection) { presentation in
            AvatarCropView(presentation: presentation) { photo in
                guard controller.stage(photo, contextID: presentation.contextID) else { error = "Аккаунт или фотография изменились. Выберите фотографию заново."; return }
                selection = nil; confirming = true
            } close: { selection = nil }
        }
        .confirmationDialog(controller.draft?.photo == nil ? "Удалить текущую фотографию?" : "Сохранить новую фотографию?", isPresented: $confirming, titleVisibility: .visible) {
            if let draft = controller.draft {
                Button(draft.photo == nil ? "Удалить" : "Сохранить", role: draft.photo == nil ? .destructive : nil) {
                    if !controller.apply(draftID: draft.id, contextID: controller.contextID) { error = "Сведения изменились. Обновите их и подтвердите заново." }
                }.accessibilityIdentifier("telegram.avatar.confirm")
            }
            Button("Отмена", role: .cancel) {}.accessibilityIdentifier("telegram.avatar.confirm.cancel")
        } message: { Text("\(controller.snapshot?.title ?? "Профиль") · \(target.kind == .fallback ? "публичная фотография" : "основная фотография")") }
    }
    private var statusText: String {
        switch controller.phase {
        case .uploading: return "Загружаем подготовленную фотографию…"
        case .committing: return "Сохраняем и проверяем ответ Telegram…"
        case .saved: return "Изменение подтверждено Telegram."
        case .changed: return "Фотография или права изменились. Обновите сведения и подтвердите заново."
        case .failed: return "Не удалось выполнить операцию. Обновите сведения перед повтором."
        case .uncertain: return "Результат записи не подтверждён. Обновите сведения перед следующим изменением."
        case .idle:
            if controller.status == .failed || controller.status == .timedOut { return "Не удалось загрузить сведения. Повторите обновление." }
            return controller.draft == nil ? "Выберите фотографию или удалите текущую." : "Изменение ещё не сохранено."
        }
    }
    private func choose() {
        guard enabled else { return }
        picking = true; error = nil
        let context = controller.contextID
        pickerTask = Task { @MainActor in
            defer { picking = false; pickerTask = nil }
            guard let url = await AvatarImagePicker().choose(), !Task.isCancelled,
                  controller.contextID == context else { return }
            do {
                let raw = try await TelegramUploadVideoCoverIO.openSelection(url)
                guard !Task.isCancelled, controller.contextID == context else { try? await TelegramUploadVideoCoverIO.discardSelectionInBackground(raw); return }
                do { selection = try AvatarCropPresentation(selection: raw, contextID: context) }
                catch { try? await TelegramUploadVideoCoverIO.discardSelectionInBackground(raw); throw error }
            } catch { if !Task.isCancelled { self.error = "Не удалось открыть изображение. Допустим файл до20МБ и40млн пикселей." } }
        }
    }
}
@MainActor private final class AvatarCropPresentation: Identifiable {
    let id = UUID(), selection: TelegramUploadVideoCoverSelection, crop: TelegramUploadVideoCoverCrop, contextID: UUID
    init(selection: TelegramUploadVideoCoverSelection, contextID: UUID) throws {
        self.selection = selection; self.contextID = contextID
        crop = try .init(imageSize: CGSize(width: selection.preview.image.width, height: selection.preview.image.height), videoSize: CGSize(width: 1, height: 1))
    }
    isolated deinit {
        let selection = selection
        Task { try? await TelegramUploadVideoCoverIO.discardSelectionInBackground(selection) }
    }
}
private struct AvatarCropView: View {
    let presentation: AvatarCropPresentation
    let save: (TelegramAvatarPhoto) -> Void, close: () -> Void
    @State private var crop: TelegramUploadVideoCoverCrop
    @State private var images = TelegramUploadVideoCoverImages()
    @State private var canvas = CGSize.zero
    @State private var error: String?
    @State private var preparing = false
    @State private var prepareTask: Task<Void, Never>?
    init(presentation: AvatarCropPresentation, save: @escaping (TelegramAvatarPhoto) -> Void, close: @escaping () -> Void) {
        self.presentation = presentation; self.save = save; self.close = close; _crop = State(initialValue: presentation.crop)
    }
    var body: some View {
        VStack(spacing: 14) {
            Text("Выберите область фотографии").font(.headline)
            TelegramVideoCoverCropCanvas(preview: presentation.selection.preview, painting: .init(), crop: $crop, images: $images, canvasSize: $canvas, error: $error, circularPreview: true).frame(height: 360).disabled(preparing)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Отмена", action: close).keyboardShortcut(.cancelAction).accessibilityIdentifier("telegram.avatar.crop.cancel")
                Spacer()
                Button { crop.rotate() } label: { Image(systemName: "rotate.left") }.disabled(preparing).accessibilityLabel("Повернуть фотографию").accessibilityIdentifier("telegram.avatar.crop.rotate")
                Button { crop.flipHorizontally() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }.disabled(preparing).accessibilityLabel("Отразить фотографию").accessibilityIdentifier("telegram.avatar.crop.flip")
                Spacer()
                Button("Готово") {
                    guard !preparing else { return }
                    preparing = true
                    let preview = presentation.selection.preview, rect = crop.rect, transform = crop.transform
                    prepareTask = Task { @MainActor in
                        defer { preparing = false; prepareTask = nil }
                        do {
                            let photo = try await BackgroundWork.run { try TelegramAvatarPhoto.prepare(preview: preview, crop: rect, transform: transform) }
                            try Task.checkCancellation(); save(photo)
                        } catch is CancellationError { }
                        catch { self.error = "Не удалось подготовить квадратную фотографию. Увеличьте область обрезки." }
                    }
                }.disabled(preparing).keyboardShortcut(.defaultAction).accessibilityIdentifier("telegram.avatar.crop.done")
            }
        }.padding(20).frame(width: 560).onDisappear { prepareTask?.cancel() }
    }
}

struct TelegramAvatarEditingButton: View {
    @ObservedObject var controller: TelegramAvatarEditingController
    let target: TelegramAvatarTarget
    let title: String
    @State private var presented = false
    var body: some View {
        Button(title) { presented = true }
            .accessibilityIdentifier(target.kind == .fallback ? "telegram.avatar.open.fallback" : "telegram.avatar.open.main")
            .sheet(isPresented: $presented) {
                TelegramAvatarEditingView(controller: controller, target: target) { presented = false }
            }
            .onChange(of: controller.accountID) { _, _ in presented = false }
    }
}

@MainActor private final class AvatarImagePicker {
    private let panel = NSOpenPanel()
    func choose() async -> URL? {
        panel.title = "Выберите фотографию профиля"
        panel.allowedContentTypes = [.image]; panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.resolvesAliases = false
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                panel.begin { [self] response in continuation.resume(returning: response == .OK ? panel.url : nil) }
            }
        } onCancel: {
            Task { @MainActor [self] in panel.cancel(nil) }
        }
    }
}
