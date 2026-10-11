import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MakoshTelegram

@MainActor enum TelegramVideoCoverPanel {
    static func choose() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Выберите обложку видео"
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
    isolated deinit { try? TelegramUploadVideoCoverIO.discardSelection(selection) }
}

struct TelegramVideoCoverEditorView: View {
    let presentation: TelegramVideoCoverEditorPresentation
    @ObservedObject var upload: TelegramUploadController
    let close: () -> Void
    @State private var crop: TelegramUploadVideoCoverCrop
    @State private var painting = TelegramUploadVideoCoverPainting()
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
            TelegramVideoCoverCropCanvas(preview: presentation.selection.preview, painting: painting, crop: $crop)
                .frame(height: 360).disabled(applying)
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
                Spacer()
                if applying { ProgressView().controlSize(.small) }
                Button("Готово", action: apply).keyboardShortcut(.defaultAction).disabled(applying)
                    .accessibilityIdentifier("telegram.upload.videoCoverEditor.done")
            }
        }
        .padding(20).frame(width: 600)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("telegram.upload.videoCoverEditor")
        .interactiveDismissDisabled(applying)
        .onDisappear { applyTask?.cancel() }
        .sheet(isPresented: $drawingEditor) {
            TelegramVideoCoverPaintingView(preview: presentation.selection.preview, transform: crop.transform,
                painting: painting, save: { painting = $0 }, close: { drawingEditor = false })
        }
    }
    private func apply() {
        guard !applying, upload.videoCoverEditingID == presentation.id else { return }
        applying = true; error = nil
        let selection = presentation.selection, rect = crop.rect, transform = crop.transform, id = presentation.id
        let painting = painting
        applyTask = Task { @MainActor in
            defer { applying = false; applyTask = nil }
            do {
                let cover = try await TelegramUploadVideoCoverIO.stage(selection, crop: rect, transform: transform, painting: painting)
                guard !Task.isCancelled else { try? TelegramUploadVideoCoverIO.discardCover(cover); return }
                if upload.commitVideoCover(cover, editID: id) { close() }
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

private struct TelegramVideoCoverCropCanvas: View {
    let preview: TelegramImagePreview
    let painting: TelegramUploadVideoCoverPainting
    @Binding var crop: TelegramUploadVideoCoverCrop
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
                    .accessibilityLabel("Область обрезки обложки")
                    .accessibilityValue("\(Int(crop.rect.width * 100))% ширины, \(Int(crop.rect.height * 100))% высоты")
                    .accessibilityHint("Перетащите рамку или её углы. Двойной щелчок выбирает максимальную область. Стрелки перемещают рамку; изменение значения меняет размер.")
                    .accessibilityIdentifier("telegram.upload.videoCoverEditor.crop")
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
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                .coordinateSpace(name: "telegram.videoCover.cropCanvas")
                .onAppear {
                    guard !initializedSelection, fitted.width >= 1, fitted.height >= 1 else { return }
                    crop.fitInitialSelection(canvasSize: fitted.size)
                    initializedSelection = true
                }
                .simultaneousGesture(SpatialTapGesture(count: 2, coordinateSpace: .named("telegram.videoCover.cropCanvas")).onEnded { value in
                    guard selection.contains(value.location) else { return }
                    gestureStart = nil; crop.selectMaximumBounds(canvasSize: fitted.size)
                })
                .onChange(of: crop.transform) { gestureStart = nil }
        }
    }
}
