import SwiftUI
import AppKit
import MakoshTelegram
import MakoshCore

struct TelegramAvatarEditingView: View {
    @ObservedObject var controller: TelegramAvatarEditingController
    let target: TelegramAvatarTarget
    var synthetic = false
    let close: () -> Void
    @State private var selection: AvatarCropPresentation?
    @State private var picking = false
    @State private var pickerTask: Task<Void, Never>?
    @State private var error: String?
    @State private var confirming = false
    private var enabled: Bool {
        controller.status == .ready && controller.snapshot?.canEdit == true && !controller.isBusy && controller.phase != .uncertain
            && !picking
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(target.kind == .fallback ? "Публичная фотография" : "Фотография профиля").font(.headline)
                Spacer()
                Button("Готово", action: close).keyboardShortcut(.cancelAction)
                    .disabled(controller.isBusy).accessibilityIdentifier("telegram.avatar.close")
            }.padding()
            Divider()
            Form {
                if let draft = controller.draft {
                    Section("Подготовленное изменение") {
                        HStack(spacing: 12) {
                            if let photo = draft.photo {
                                Image(decorative: photo.preview.image, scale: 1).resizable().scaledToFit()
                                    .frame(width: 64, height: 64).clipShape(Circle())
                            }
                            Text(draft.photo == nil ? "Удаление ещё не подтверждено." : "Новая фотография ещё не сохранена.")
                        }
                        HStack {
                            Button("Отменить изменение", action: controller.discardDraft).disabled(controller.isBusy)
                                .accessibilityIdentifier("telegram.avatar.discard")
                            Spacer(minLength: 8)
                            Button("Сохранить") { confirming = true }.disabled(!enabled)
                                .buttonStyle(WorkspaceButtonStyle(prominent: true))
                                .accessibilityIdentifier("telegram.avatar.save")
                        }
                    }
                }
                Section {
                    if let snapshot = controller.snapshot {
                        Text(snapshot.title).font(.title3.bold()).accessibilityIdentifier("telegram.avatar.title")
                        if target.kind == .fallback {
                            Text("Эту фотографию увидят пользователи, которым основная фотография скрыта настройками приватности.").font(
                                .callout
                            ).foregroundStyle(.secondary)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                chooseButton
                                removeButton(hasPhoto: snapshot.photoID != nil)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                chooseButton
                                removeButton(hasPhoto: snapshot.photoID != nil)
                            }
                        }
                        #if DEBUG
                        if synthetic {
                            Button("Использовать тестовую фотографию", action: chooseSynthetic)
                                .disabled(!enabled).accessibilityIdentifier("telegram.avatar.chooseSynthetic")
                        }
                        #endif
                        if !snapshot.canEdit { Text("Нет прав на изменение фотографии.").foregroundStyle(.secondary) }
                    } else if controller.status == .loading {
                        ProgressView("Загружаем фотографию…")
                    }
                }
                Section {
                    Text(error ?? statusText).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("telegram.avatar.status")
                    if picking || controller.isBusy {
                        ProgressView(value: Double(controller.progress)).accessibilityIdentifier("telegram.avatar.progress")
                    }
                    if controller.phase == .uploading {
                        Button("Отменить загрузку", action: controller.cancelUpload).accessibilityIdentifier("telegram.avatar.cancelUpload")
                    }
                    Button("Обновить") {
                        error = nil
                        controller.refresh()
                    }.disabled(controller.isBusy || picking)
                        .accessibilityIdentifier("telegram.avatar.refresh")
                }
            }.formStyle(WorkspaceFormStyle())
        }.frame(width: 480, height: 460)
            .buttonStyle(WorkspaceButtonStyle())
            .background { WorkspaceBackdrop(intensity: 0.4) }
            .onAppear { controller.open(target) }
            .onDisappear {
                pickerTask?.cancel()
                selection = nil
                controller.close()
            }
            .onChange(of: controller.contextID) { _, _ in
                pickerTask?.cancel()
                selection = nil
                confirming = false
            }
            .interactiveDismissDisabled(controller.isBusy)
            .sheet(item: $selection) { presentation in
                AvatarCropView(presentation: presentation) { photo in
                    guard controller.stage(photo, contextID: presentation.contextID) else {
                        error = "Аккаунт или фотография изменились. Выберите фотографию заново."
                        return
                    }
                    selection = nil
                    confirming = true
                } close: {
                    selection = nil
                }
            }
            .confirmationDialog(
                controller.draft?.photo == nil ? "Удалить текущую фотографию?" : "Сохранить новую фотографию?", isPresented: $confirming,
                titleVisibility: .visible
            ) {
                if let draft = controller.draft {
                    Button(draft.photo == nil ? "Удалить" : "Сохранить", role: draft.photo == nil ? .destructive : nil) {
                        if !controller.apply(draftID: draft.id, contextID: controller.contextID) {
                            error = "Сведения изменились. Обновите их и подтвердите заново."
                        }
                    }.accessibilityIdentifier("telegram.avatar.confirm")
                }
                Button("Отмена", role: .cancel) {}.accessibilityIdentifier("telegram.avatar.confirm.cancel")
            } message: {
                Text(
                    "\(controller.snapshot?.title ?? "Профиль") · \(target.kind == .fallback ? "публичная фотография" : "основная фотография")"
                )
            }
    }
    private var chooseButton: some View {
        Button("Выбрать фотографию…", action: choose).disabled(!enabled)
            .accessibilityIdentifier("telegram.avatar.choose")
    }
    private func removeButton(hasPhoto: Bool) -> some View {
        Button("Удалить фотографию", role: .destructive) {
            if controller.stageRemoval(contextID: controller.contextID) { confirming = true }
        }.disabled(!enabled || !hasPhoto).accessibilityIdentifier("telegram.avatar.remove")
    }
    #if DEBUG
    private func chooseSynthetic() {
        guard enabled else { return }
        picking = true
        error = nil
        let context = controller.contextID
        pickerTask = Task { @MainActor in
            defer {
                picking = false
                pickerTask = nil
            }
            do {
                let preview = try await BackgroundWork.run {
                    guard
                        let bitmap = CGContext(
                            data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 2560,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                        )
                    else { throw CocoaError(.coderInvalidValue) }
                    bitmap.setFillColor(CGColor(red: 0.20, green: 0.14, blue: 0.40, alpha: 1))
                    bitmap.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
                    bitmap.setFillColor(CGColor(red: 0.72, green: 0.48, blue: 0.94, alpha: 1))
                    bitmap.fillEllipse(in: CGRect(x: 175, y: 130, width: 250, height: 250))
                    guard let image = bitmap.makeImage() else { throw CocoaError(.coderInvalidValue) }
                    return TelegramImagePreview(image: image)
                }
                guard !Task.isCancelled, controller.contextID == context else { return }
                selection = try AvatarCropPresentation(preview: preview, contextID: context)
            } catch {
                if !Task.isCancelled { self.error = "Не удалось подготовить тестовую фотографию." }
            }
        }
    }
    #endif
    private var statusText: String {
        switch controller.phase {
        case .uploading: return "Загружаем подготовленную фотографию…"
        case .committing: return "Сохраняем и проверяем ответ Telegram…"
        case .saved: return "Изменение подтверждено Telegram."
        case .changed: return "Фотография или права изменились. Обновите сведения и подтвердите заново."
        case .failed: return "Не удалось выполнить операцию. Обновите сведения перед повтором."
        case .uncertain: return "Результат записи не подтверждён. Обновите сведения перед следующим изменением."
        case .idle:
            if controller.status == .failed || controller.status == .timedOut {
                return "Не удалось загрузить сведения. Повторите обновление."
            }
            return controller.draft == nil ? "Выберите фотографию или удалите текущую." : "Изменение ещё не сохранено."
        }
    }
    private func choose() {
        guard enabled else { return }
        picking = true
        error = nil
        let context = controller.contextID
        pickerTask = Task { @MainActor in
            defer {
                picking = false
                pickerTask = nil
            }
            guard let url = await AvatarImagePicker().choose(), !Task.isCancelled,
                controller.contextID == context
            else { return }
            do {
                let raw = try await TelegramUploadVideoCoverIO.openSelection(url)
                guard !Task.isCancelled, controller.contextID == context else {
                    try? await TelegramUploadVideoCoverIO.discardSelectionInBackground(raw)
                    return
                }
                do { selection = try AvatarCropPresentation(selection: raw, contextID: context) } catch {
                    try? await TelegramUploadVideoCoverIO.discardSelectionInBackground(raw)
                    throw error
                }
            } catch { if !Task.isCancelled { self.error = "Не удалось открыть изображение. Допустим файл до20МБ и40млн пикселей." } }
        }
    }
}
@MainActor private final class AvatarCropPresentation: Identifiable {
    let id = UUID(), preview: TelegramImagePreview, crop: TelegramUploadVideoCoverCrop, contextID: UUID
    private let selection: TelegramUploadVideoCoverSelection?
    convenience init(selection: TelegramUploadVideoCoverSelection, contextID: UUID) throws {
        try self.init(preview: selection.preview, contextID: contextID, selection: selection)
    }
    init(preview: TelegramImagePreview, contextID: UUID, selection: TelegramUploadVideoCoverSelection? = nil) throws {
        self.selection = selection
        self.preview = preview
        self.contextID = contextID
        crop = try .init(
            imageSize: CGSize(width: preview.image.width, height: preview.image.height),
            videoSize: CGSize(width: 1, height: 1))
    }
    isolated deinit {
        if let selection { Task { try? await TelegramUploadVideoCoverIO.discardSelectionInBackground(selection) } }
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
        self.presentation = presentation
        self.save = save
        self.close = close
        _crop = State(initialValue: presentation.crop)
    }
    var body: some View {
        VStack(spacing: 14) {
            Text("Выберите область фотографии").font(.headline)
            TelegramVideoCoverCropCanvas(
                preview: presentation.preview, painting: .init(), crop: $crop, images: $images, canvasSize: $canvas,
                error: $error, circularPreview: true
            ).frame(height: 360).disabled(preparing)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Отмена", action: close).keyboardShortcut(.cancelAction).accessibilityIdentifier("telegram.avatar.crop.cancel")
                Spacer()
                Button {
                    crop.rotate()
                } label: {
                    Image(systemName: "rotate.left")
                }.disabled(preparing).accessibilityLabel("Повернуть фотографию").accessibilityIdentifier("telegram.avatar.crop.rotate")
                Button {
                    crop.flipHorizontally()
                } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }.disabled(preparing).accessibilityLabel("Отразить фотографию").accessibilityIdentifier("telegram.avatar.crop.flip")
                Spacer()
                Button("Готово") {
                    guard !preparing else { return }
                    preparing = true
                    let preview = presentation.preview, rect = crop.rect, transform = crop.transform
                    prepareTask = Task { @MainActor in
                        defer {
                            preparing = false
                            prepareTask = nil
                        }
                        do {
                            let photo = try await BackgroundWork.run {
                                try TelegramAvatarPhoto.prepare(preview: preview, crop: rect, transform: transform)
                            }
                            try Task.checkCancellation()
                            save(photo)
                        } catch is CancellationError {} catch {
                            self.error = "Не удалось подготовить квадратную фотографию. Увеличьте область обрезки."
                        }
                    }
                }.disabled(preparing).keyboardShortcut(.defaultAction).accessibilityIdentifier("telegram.avatar.crop.done")
            }
        }.padding(20).frame(width: 560)
            .buttonStyle(WorkspaceButtonStyle())
            .background { WorkspaceBackdrop(intensity: 0.4) }
            .onDisappear { prepareTask?.cancel() }
    }
}

struct TelegramAvatarEditingButton: View {
    @ObservedObject var controller: TelegramAvatarEditingController
    let target: TelegramAvatarTarget
    let title: String
    var synthetic = false
    @State private var presented = false
    var body: some View {
        Button(title) { presented = true }
            .accessibilityIdentifier(target.kind == .fallback ? "telegram.avatar.open.fallback" : "telegram.avatar.open.main")
            .sheet(isPresented: $presented) {
                TelegramAvatarEditingView(controller: controller, target: target, synthetic: synthetic) { presented = false }
            }
            .onChange(of: controller.accountID) { _, _ in presented = false }
    }
}

@MainActor private final class AvatarImagePicker {
    private let panel = NSOpenPanel()
    func choose() async -> URL? {
        panel.title = "Выберите фотографию профиля"
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                panel.begin { [self] response in continuation.resume(returning: response == .OK ? panel.url : nil) }
            }
        } onCancel: {
            Task { @MainActor [self] in panel.cancel(nil) }
        }
    }
}
