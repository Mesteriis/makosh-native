import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MakoshTelegram

@MainActor enum TelegramVideoCoverPanel {
    static func choose(title: String = "Выберите обложку видео") async -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.resolvesAliases = false
        return await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
        }
    }
}

@MainActor final class TelegramVideoCoverEditorPresentation: Identifiable {
    let id: UUID
    let selection: TelegramUploadVideoCoverSelection
    let crop: TelegramUploadVideoCoverCrop
    init(id: UUID, selection: TelegramUploadVideoCoverSelection, video: TelegramUploadVideoMetadata) throws {
        self.id = id; self.selection = selection
        crop = try TelegramUploadVideoCoverCrop(imageSize: CGSize(width: selection.preview.image.width, height: selection.preview.image.height),
            videoSize: CGSize(width: Int(video.width), height: Int(video.height)))
    }
    isolated deinit {
        let selection = selection
        Task { try? await TelegramUploadVideoCoverIO.discardSelectionInBackground(selection) }
    }
}

struct TelegramVideoCoverEditorView: View {
    let presentation: TelegramVideoCoverEditorPresentation
    @ObservedObject var upload: TelegramUploadController
    let close: () -> Void
    @State private var crop: TelegramUploadVideoCoverCrop
    @State private var painting = TelegramUploadVideoCoverPainting()
    @State private var images = TelegramUploadVideoCoverImages()
    @State private var canvasSize = CGSize.zero
    @State private var importing = false
    @State private var importTask: Task<Void, Never>?
    @State private var copyTask: Task<Void, Never>?
    @State private var drawingEditor = false
    @State private var applying = false
    @State private var error: String?
    @State private var applyTask: Task<Void, Never>?
    init(presentation: TelegramVideoCoverEditorPresentation, upload: TelegramUploadController, close: @escaping () -> Void) {
        self.presentation = presentation; self.upload = upload; self.close = close
        _crop = State(initialValue: presentation.crop)
    }
    var body: some View {
        VStack(spacing: 12) {
            TelegramVideoCoverCropCanvas(preview: presentation.selection.preview, painting: painting, crop: $crop,
                images: $images, canvasSize: $canvasSize, error: $error)
                .frame(height: 360).disabled(applying || importing)
            if let error { Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("telegram.upload.videoCoverEditor.error") }
            HStack {
                Button("Отмена") { upload.cancelVideoCoverEdit(presentation.id); close() }
                    .keyboardShortcut(.cancelAction).disabled(applying)
                    .accessibilityIdentifier("telegram.upload.videoCoverEditor.cancel")
                Spacer()
                Button { crop.rotate() } label: { Image(systemName: "rotate.left") }
                    .keyboardShortcut("r", modifiers: .command).disabled(applying)
                    .help("Повернуть (⌘R)").accessibilityLabel("Повернуть обложку")
                    .accessibilityValue("\(crop.transform.quarterTurns * 90)°")
                    .accessibilityIdentifier("telegram.upload.videoCoverEditor.rotate")
                Button { crop.flipHorizontally() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .disabled(applying).help("Отразить по горизонтали")
                    .accessibilityLabel("Отразить обложку по горизонтали")
                    .accessibilityValue(crop.transform.isHorizontallyFlipped ? "Включено" : "Выключено")
                    .accessibilityIdentifier("telegram.upload.videoCoverEditor.flip")
                Button { drawingEditor = true } label: { Image(systemName: "pencil.tip.crop.circle") }
                    .keyboardShortcut("d", modifiers: .command).disabled(applying)
                    .help("Рисовать на обложке (⌘D)").accessibilityLabel("Рисовать на обложке")
                    .accessibilityIdentifier("telegram.upload.videoCoverEditor.draw")
                Menu {
                    Button("Из файла…", action: chooseImage)
                    Button("Скопировать вставку", action: copyImage).keyboardShortcut("c", modifiers: .command)
                        .disabled(images.selectedID == nil)
                    Button("На передний план") { images.bringSelectedToFront() }.disabled(images.selectedID == nil)
                } label: { Image(systemName: "photo.badge.plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Вставить изображение из файла").accessibilityLabel("Добавить изображение")
                    .accessibilityIdentifier("telegram.upload.videoCoverEditor.insert")
                Button(action: pasteImages) { Image(systemName: "document.on.clipboard") }
                    .keyboardShortcut("v", modifiers: .command)
                    .help("Вставить изображение (⌘V)").accessibilityLabel("Вставить изображение")
                    .accessibilityIdentifier("telegram.upload.videoCoverEditor.paste")
                Button { images.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command).disabled(!images.canUndo)
                    .help("Отменить изменение вставок (⌘Z)").accessibilityLabel("Отменить изменение вставок")
                    .accessibilityIdentifier("telegram.upload.videoCoverEditor.undo")
                Button { images.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!images.canRedo)
                    .help("Вернуть изменение вставок (⇧⌘Z)").accessibilityLabel("Вернуть изменение вставок")
                    .accessibilityIdentifier("telegram.upload.videoCoverEditor.redo")
                Button { images.deleteSelected() } label: { Image(systemName: "trash") }
                    .keyboardShortcut(.delete, modifiers: []).disabled(images.selectedID == nil)
                    .help("Удалить вставку (Delete)").accessibilityLabel("Удалить вставку")
                    .accessibilityIdentifier("telegram.upload.videoCoverEditor.deleteImage")
                Spacer()
                if applying || importing { ProgressView().controlSize(.small) }
                Button("Готово", action: apply).keyboardShortcut(.defaultAction).disabled(applying)
                    .accessibilityIdentifier("telegram.upload.videoCoverEditor.done")
            }.disabled(applying || importing || drawingEditor)
        }
        .padding(20).frame(width: 600)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("telegram.upload.videoCoverEditor")
        .interactiveDismissDisabled(applying || importing)
        .onDisappear { applyTask?.cancel(); importTask?.cancel(); copyTask?.cancel() }
        .sheet(isPresented: $drawingEditor) {
            TelegramVideoCoverPaintingView(preview: presentation.selection.preview, transform: crop.transform,
                painting: painting, save: { painting = $0 }, close: { drawingEditor = false })
        }
    }
    private func chooseImage() {
        startImport {
            guard let source = await TelegramVideoCoverPanel.choose(title: "Выберите изображение для вставки") else { return nil }
            return .files([source])
        }
    }
    private func pasteImages() { startImport { try TelegramVideoCoverImageInput.pasteboard() } }
    private func copyImage() {
        guard let item = images.items.first(where: { $0.id == images.selectedID }) else { return }
        copyTask?.cancel()
        copyTask = Task { @MainActor in
            do { try await TelegramVideoCoverImageInput.copy(item, isCurrent: {
                upload.videoCoverEditingID == presentation.id && images.items.contains(where: { $0.id == item.id })
            }) }
            catch is CancellationError { }
            catch { self.error = "Не удалось скопировать вставку." }
        }
    }
    private func startImport(_ read: @escaping @MainActor () async throws -> TelegramVideoCoverImageInput.Input?) {
        guard !applying, !importing, !drawingEditor, canvasSize.width >= 1, canvasSize.height >= 1 else { return }
        importing = true; error = nil
        let accepted = images, canvas = canvasSize
        let sourceSize = crop.transform.imageSize(CGSize(width: presentation.selection.preview.image.width,
            height: presentation.selection.preview.image.height))
        importTask = Task { @MainActor in
            defer { importing = false; importTask = nil }
            do {
                guard let input = try await read() else { return }
                let next = try await TelegramVideoCoverImageInput.adding(input, to: accepted, canvasSize: canvas, imageSize: sourceSize)
                guard !Task.isCancelled else { return }
                images = next
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Не удалось вставить изображение. Проверьте файл и ограничения редактора."
            }
        }
    }
    private func apply() {
        guard !applying, !importing, upload.videoCoverEditingID == presentation.id else { return }
        applying = true; error = nil
        let selection = presentation.selection, rect = crop.rect, transform = crop.transform, id = presentation.id
        let painting = painting, images = images
        applyTask = Task { @MainActor in
            defer { applying = false; applyTask = nil }
            do {
                let cover = try await TelegramUploadVideoCoverIO.stage(selection, crop: rect, transform: transform, painting: painting, images: images)
                guard !Task.isCancelled else { try? TelegramUploadVideoCoverIO.discardCover(cover); return }
                if await upload.commitVideoCover(cover, editID: id) { close() }
                else {
                    try? TelegramUploadVideoCoverIO.discardCover(cover)
                    error = "Подготовка видео изменилась. Откройте выбор обложки заново."
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Не удалось подготовить обложку. Выберите другое изображение."
            }
        }
    }
}

struct TelegramVideoCoverCropCanvas: View {
    let preview: TelegramImagePreview
    let painting: TelegramUploadVideoCoverPainting
    @Binding var crop: TelegramUploadVideoCoverCrop
    @Binding var images: TelegramUploadVideoCoverImages
    @Binding var canvasSize: CGSize
    @Binding var error: String?
    var circularPreview = false
    @State private var gestureStart: TelegramUploadVideoCoverCrop?
    @State private var initializedSelection = false
    @FocusState private var focused: Bool
    private let corners: [TelegramUploadVideoCoverCrop.Corner] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    var body: some View {
        GeometryReader { geometry in
            let original = CGSize(width: preview.image.width, height: preview.image.height)
            let transformed = crop.transform.imageSize(original)
            let width = transformed.width, height = transformed.height
            let size = TelegramUploadVideoCoverCrop.fittedImageSize(transformed,
                in: CGSize(width: geometry.size.width - 8, height: geometry.size.height - 8))
            let originalFitted = crop.transform.imageSize(size)
            let fitted = CGRect(x: (geometry.size.width - size.width) / 2, y: (geometry.size.height - size.height) / 2,
                width: size.width, height: size.height)
            let selection = CGRect(x: fitted.minX + crop.rect.minX * fitted.width, y: fitted.minY + crop.rect.minY * fitted.height,
                width: crop.rect.width * fitted.width, height: crop.rect.height * fitted.height)
            ZStack(alignment: .topLeading) {
                TelegramVideoCoverPaintedImage(preview: preview, painting: painting)
                    .frame(width: originalFitted.width, height: originalFitted.height)
                    .rotationEffect(.degrees(-90 * Double(crop.transform.quarterTurns)))
                    .scaleEffect(x: crop.transform.isHorizontallyFlipped ? -1 : 1, y: 1)
                    .position(x: fitted.midX, y: fitted.midY)
                    .accessibilityHidden(true)
                Path { path in path.addRect(fitted); path.addRect(selection) }
                    .fill(.black.opacity(0.55), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                if circularPreview {
                    Circle().stroke(.white.opacity(0.9), lineWidth: 1)
                        .frame(width: selection.width, height: selection.height)
                        .position(x: selection.midX, y: selection.midY).allowsHitTesting(false)
                }
                Rectangle().fill(.clear).overlay(Rectangle().stroke(.white, lineWidth: 1))
                    .frame(width: selection.width, height: selection.height)
                    .contentShape(Rectangle()).position(x: selection.midX, y: selection.midY)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("telegram.videoCover.cropCanvas")).onChanged { value in
                        focused = true
                        if gestureStart == nil { gestureStart = crop }
                        guard var start = gestureStart, fitted.width > 0, fitted.height > 0 else { return }
                        start.move(from: CGPoint(x: value.startLocation.x - fitted.minX, y: value.startLocation.y - fitted.minY),
                            to: CGPoint(x: value.location.x - fitted.minX, y: value.location.y - fitted.minY), canvasSize: fitted.size)
                        crop = start
                    }.onEnded { _ in gestureStart = nil })
                    .focusable().focusEffectDisabled().focused($focused)
                    .onMoveCommand { direction in
                        switch direction {
                        case .left: crop.move(by: CGSize(width: -1 / width, height: 0))
                        case .right: crop.move(by: CGSize(width: 1 / width, height: 0))
                        case .up: crop.move(by: CGSize(width: 0, height: -1 / height))
                        case .down: crop.move(by: CGSize(width: 0, height: 1 / height))
                        @unknown default: break
                        }
                    }
                    .accessibilityLabel(circularPreview ? "Область обрезки фотографии профиля" : "Область обрезки обложки")
                    .accessibilityValue("\(Int(crop.rect.width * 100))% ширины, \(Int(crop.rect.height * 100))% высоты")
                    .accessibilityHint("Перетащите рамку или её углы. Двойной щелчок выбирает максимальную область. Стрелки перемещают рамку; изменение значения меняет размер.")
                    .accessibilityIdentifier(circularPreview ? "telegram.avatar.crop" : "telegram.upload.videoCoverEditor.crop")
                    .accessibilityAction(named: Text("Выбрать максимальную область")) {
                        crop.selectMaximumBounds(canvasSize: fitted.size)
                    }
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: crop.resize(by: CGSize(width: 0.02, height: 0), corner: .bottomRight, canvasSize: fitted.size)
                        case .decrement: crop.resize(by: CGSize(width: -0.02, height: 0), corner: .bottomRight, canvasSize: fitted.size)
                        @unknown default: break
                        }
                    }
                ForEach(Array(corners.enumerated()), id: \.offset) { entry in
                    let corner = entry.element
                    let left = corner == .topLeft || corner == .bottomLeft
                    let top = corner == .topLeft || corner == .topRight
                    Path { path in
                        let x: CGFloat = left ? 1 : 19, y: CGFloat = top ? 1 : 19
                        path.move(to: CGPoint(x: x, y: top ? 19 : 1))
                        path.addLine(to: CGPoint(x: x, y: y))
                        path.addLine(to: CGPoint(x: left ? 19 : 1, y: y))
                    }.stroke(.white, lineWidth: 2).frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                        .position(x: left ? selection.minX + 8 : selection.maxX - 8,
                            y: top ? selection.minY + 8 : selection.maxY - 8)
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("telegram.videoCover.cropCanvas")).onChanged { value in
                            if gestureStart == nil { gestureStart = crop }
                            guard var start = gestureStart, fitted.width > 0, fitted.height > 0 else { return }
                            start.resize(to: CGPoint(x: value.location.x - fitted.minX, y: value.location.y - fitted.minY),
                                corner: corner, canvasSize: fitted.size)
                            crop = start
                        }.onEnded { _ in gestureStart = nil })
                        .accessibilityHidden(true)
                }
                TelegramVideoCoverImagesView(images: $images, canvasSize: fitted.size, error: $error)
                    .frame(width: fitted.width, height: fitted.height).clipped()
                    .position(x: fitted.midX, y: fitted.midY)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                .coordinateSpace(name: "telegram.videoCover.cropCanvas")
                .onAppear {
                    canvasSize = fitted.size
                    guard !initializedSelection, fitted.width >= 1, fitted.height >= 1 else { return }
                    crop.fitInitialSelection(canvasSize: fitted.size)
                    initializedSelection = true
                }
                .onChange(of: fitted.size) { canvasSize = fitted.size }
                .simultaneousGesture(SpatialTapGesture(count: 2, coordinateSpace: .named("telegram.videoCover.cropCanvas")).onEnded { value in
                    guard selection.contains(value.location) else { return }
                    let local = CGPoint(x: value.location.x - fitted.minX, y: value.location.y - fitted.minY)
                    guard !TelegramVideoCoverImagesView.contains(local, images: images) else { return }
                    gestureStart = nil; crop.selectMaximumBounds(canvasSize: fitted.size)
                })
                .onChange(of: crop.transform) { gestureStart = nil }
        }
    }
}
