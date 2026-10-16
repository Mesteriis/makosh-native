import SwiftUI
import AppKit
import MakoshTelegram

/// Image controls sit in the main editor, above crop interaction, as in the
/// reference. Positions remain captured fitted-canvas points across base edits.
struct TelegramVideoCoverImagesView: View {
    @Binding var images: TelegramUploadVideoCoverImages
    let canvasSize: CGSize
    @Binding var error: String?
    @State private var dragStart: TelegramUploadVideoCoverImages?
    @State private var copyTask: Task<Void, Never>?
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(images.items) { item in
                let rect = item.rect
                Image(item.image, scale: 1, label: Text("Вставленное изображение")).resizable()
                    .frame(width: rect.width, height: rect.height)
                    .contentShape(Rectangle())
                    .position(x: rect.midX, y: rect.midY)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("telegram.coverImages")).onChanged { value in
                        edit { try $0.move(item.id, by: value.translation, canvasSize: canvasSize) }
                    }.onEnded { _ in dragStart = nil })
                    .onTapGesture(count: 2) { images.select(item.id); images.bringSelectedToFront() }
                    .onTapGesture { images.select(item.id) }
                    .contextMenu {
                        Button("На передний план") { images.select(item.id); images.bringSelectedToFront() }
                        Button("Скопировать изображение") { copy(item) }
                        Button("Удалить вставку") { images.select(item.id); images.deleteSelected() }
                    }
                    .accessibilityLabel("Вставленное изображение \(index(item.id) + 1)")
                    .accessibilityValue(images.selectedID == item.id ? "Выбрано" : "Не выбрано")
                    .accessibilityIdentifier("telegram.upload.videoCoverEditor.image.\(item.id)")
                    .accessibilityAction(named: Text("Выбрать")) { images.select(item.id) }
                    .accessibilityAction(named: Text("На передний план")) { images.select(item.id); images.bringSelectedToFront() }
                    .accessibilityAction(named: Text("Удалить вставку")) { images.select(item.id); images.deleteSelected() }
                if images.selectedID == item.id {
                    ForEach(Array(TelegramUploadVideoCoverImages.Handle.allCases.enumerated()), id: \.offset) { entry in
                        let handle = entry.element
                        let point = Self.position(handle, rect: rect)
                        Circle().fill(.white).overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 1))
                            .frame(width: 12, height: 12).contentShape(Rectangle())
                            .position(x: point.x, y: point.y)
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("telegram.coverImages")).onChanged { value in
                                edit { try $0.resize(item.id, by: value.translation, handle: handle,
                                    preserveAspect: !NSEvent.modifierFlags.contains(.shift)) }
                            }.onEnded { _ in dragStart = nil })
                            .accessibilityLabel("Размер вставки: \(label(handle))")
                            .accessibilityIdentifier("telegram.upload.videoCoverEditor.imageHandle.\(String(describing: handle))")
                            .accessibilityAdjustableAction { direction in
                                do { try images.resize(item.id, by: CGSize(width: direction == .increment ? 4 : -4, height: direction == .increment ? 4 : -4), handle: handle) }
                                catch { self.error = "Не удалось изменить размер вставки." }
                            }
                    }
                }
            }
        }.coordinateSpace(name: "telegram.coverImages").onDisappear { copyTask?.cancel() }
    }
    private func edit(action: (inout TelegramUploadVideoCoverImages) throws -> Void) {
        if dragStart == nil { dragStart = images }
        guard var next = dragStart else { return }
        do { try action(&next); images = next; error = nil }
        catch { self.error = "Не удалось изменить вставку." }
    }
    private func index(_ id: UUID) -> Int { images.items.firstIndex(where: { $0.id == id }) ?? 0 }
    private func copy(_ item: TelegramUploadVideoCoverImages.Item) {
        copyTask?.cancel()
        copyTask = Task { @MainActor in
            do { try await TelegramVideoCoverImageInput.copy(item, isCurrent: {
                images.items.contains(where: { $0.id == item.id })
            }) }
            catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = "Не удалось скопировать вставку." } }
        }
    }
    static func contains(_ point: CGPoint, images: TelegramUploadVideoCoverImages) -> Bool {
        images.items.contains { item in
            if item.rect.contains(point) { return true }
            guard images.selectedID == item.id else { return false }
            return TelegramUploadVideoCoverImages.Handle.allCases.contains { handle in
                let center = position(handle, rect: item.rect)
                return CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12).contains(point)
            }
        }
    }
    private static func position(_ handle: TelegramUploadVideoCoverImages.Handle, rect: CGRect) -> CGPoint {
        let x: CGFloat = switch handle { case .topLeft, .bottomLeft, .left: rect.minX - 7; case .topRight, .bottomRight, .right: rect.maxX + 7; case .top, .bottom: rect.midX }
        let y: CGFloat = switch handle { case .topLeft, .topRight, .top: rect.minY - 7; case .bottomLeft, .bottomRight, .bottom: rect.maxY + 7; case .left, .right: rect.midY }
        return CGPoint(x: x, y: y)
    }
    private func label(_ handle: TelegramUploadVideoCoverImages.Handle) -> String {
        switch handle { case .topLeft: "верхний левый угол"; case .topRight: "верхний правый угол"; case .bottomLeft: "нижний левый угол"; case .bottomRight: "нижний правый угол"; case .top: "сверху"; case .bottom: "снизу"; case .left: "слева"; case .right: "справа" }
    }
}
