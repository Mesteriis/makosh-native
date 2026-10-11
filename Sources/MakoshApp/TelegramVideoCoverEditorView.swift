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
    @State private var applying = false
    @State private var error: String?
    @State private var applyTask: Task<Void, Never>?
    init(presentation: TelegramVideoCoverEditorPresentation, upload: TelegramUploadController, close: @escaping () -> Void) {
        self.presentation = presentation; self.upload = upload; self.close = close
        _crop = State(initialValue: presentation.crop)
    }
    var body: some View {
        VStack(spacing: 12) {
            TelegramVideoCoverCropCanvas(preview: presentation.selection.preview, crop: $crop)
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
    }
    private func apply() {
        guard !applying, upload.videoCoverEditingID == presentation.id else { return }
        applying = true; error = nil
        let selection = presentation.selection, rect = crop.rect, transform = crop.transform, id = presentation.id
        applyTask = Task { @MainActor in
            defer { applying = false; applyTask = nil }
            do {
                let cover = try await TelegramUploadVideoCoverIO.stage(selection, crop: rect, transform: transform)
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
    @Binding var crop: TelegramUploadVideoCoverCrop
    @State private var gestureStart: TelegramUploadVideoCoverCrop?
    @FocusState private var focused: Bool
    private let corners: [TelegramUploadVideoCoverCrop.Corner] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    var body: some View {
        GeometryReader { geometry in
            let original = CGSize(width: preview.image.width, height: preview.image.height)
            let transformed = crop.transform.imageSize(original)
            let width = transformed.width, height = transformed.height
            let scale = min(geometry.size.width / width, geometry.size.height / height)
            let fitted = CGRect(x: (geometry.size.width - width * scale) / 2, y: (geometry.size.height - height * scale) / 2,
                width: width * scale, height: height * scale)
            let selection = CGRect(x: fitted.minX + crop.rect.minX * fitted.width, y: fitted.minY + crop.rect.minY * fitted.height,
                width: crop.rect.width * fitted.width, height: crop.rect.height * fitted.height)
            ZStack(alignment: .topLeading) {
                Image(preview.image, scale: 1, label: Text("Изображение для обложки")).resizable()
                    .frame(width: original.width * scale, height: original.height * scale)
                    .rotationEffect(.degrees(-90 * Double(crop.transform.quarterTurns)))
                    .scaleEffect(x: crop.transform.isHorizontallyFlipped ? -1 : 1, y: 1)
                    .position(x: fitted.midX, y: fitted.midY)
                    .accessibilityHidden(true)
                Path { path in path.addRect(fitted); path.addRect(selection) }
                    .fill(.black.opacity(0.55), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                Rectangle().fill(.clear).overlay(Rectangle().stroke(.white, lineWidth: 1))
                    .frame(width: selection.width, height: selection.height)
                    .contentShape(Rectangle()).position(x: selection.midX, y: selection.midY)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        focused = true
                        if gestureStart == nil { gestureStart = crop }
                        guard var start = gestureStart, fitted.width > 0, fitted.height > 0 else { return }
                        start.move(by: CGSize(width: value.translation.width / fitted.width, height: value.translation.height / fitted.height))
                        crop = start
                    }.onEnded { _ in gestureStart = nil })
                    .focusable().focused($focused)
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
                    .accessibilityHint("Перетащите рамку или её углы. Стрелки перемещают рамку; изменение значения меняет размер.")
                    .accessibilityIdentifier("telegram.upload.videoCoverEditor.crop")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: crop.resize(by: CGSize(width: 0.02, height: 0), corner: .bottomRight)
                        case .decrement: crop.resize(by: CGSize(width: -0.02, height: 0), corner: .bottomRight)
                        @unknown default: break
                        }
                    }
                ForEach(Array(corners.enumerated()), id: \.offset) { entry in
                    let corner = entry.element
                    let left = corner == .topLeft || corner == .bottomLeft
                    let top = corner == .topLeft || corner == .topRight
                    RoundedRectangle(cornerRadius: 1).fill(.white).frame(width: 10, height: 10)
                        .contentShape(Rectangle().size(width: 18, height: 18))
                        .position(x: left ? selection.minX : selection.maxX, y: top ? selection.minY : selection.maxY)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            if gestureStart == nil { gestureStart = crop }
                            guard var start = gestureStart, fitted.width > 0, fitted.height > 0 else { return }
                            start.resize(by: CGSize(width: value.translation.width / fitted.width, height: value.translation.height / fitted.height), corner: corner)
                            crop = start
                        }.onEnded { _ in gestureStart = nil })
                        .accessibilityHidden(true)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                .onChange(of: crop.transform) { gestureStart = nil }
        }
    }
}
