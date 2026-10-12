import SwiftUI
import AppKit
import MakoshTelegram

struct TelegramProfilePhotosView: View {
    @ObservedObject var gallery: TelegramProfilePhotosController
    let title: String
    let close: () -> Void
    @StateObject private var anchor = GallerySaveAnchor()
    @State private var scale: CGFloat = 1
    @State private var rotation = 0
    @State private var pan = CGSize.zero
    @GestureState private var dragging = CGSize.zero
    @GestureState private var magnification: CGFloat = 1
    @State private var saveTask: Task<Void, Never>?
    @State private var saveError: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.9).ignoresSafeArea()
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    ZStack {
                        if let preview = gallery.image {
                            let turned = rotation % 2 != 0
                            let width = CGFloat(turned ? preview.image.height : preview.image.width)
                            let height = CGFloat(turned ? preview.image.width : preview.image.height)
                            let fit = min(geometry.size.width / width, geometry.size.height / height)
                            let zoom = min(8, max(0.25, scale * magnification))
                            let bounds = CGSize(width: max(0, (width * fit * zoom - geometry.size.width) / 2),
                                                height: max(0, (height * fit * zoom - geometry.size.height) / 2))
                            Image(preview.image, scale: 1, label: Text("Фотография профиля \(gallery.selectedIndex + 1)"))
                                .resizable().frame(width: CGFloat(preview.image.width) * fit, height: CGFloat(preview.image.height) * fit)
                                .rotationEffect(.degrees(Double(rotation) * 90)).scaleEffect(zoom)
                                .offset(x: clamp(pan.width + dragging.width, bounds.width), y: clamp(pan.height + dragging.height, bounds.height))
                                .allowsHitTesting(!transformDisabled)
                                .gesture(DragGesture().updating($dragging) { value, state, _ in state = value.translation }
                                    .onEnded { value in pan = CGSize(width: clamp(pan.width + value.translation.width, bounds.width), height: clamp(pan.height + value.translation.height, bounds.height)) })
                                .simultaneousGesture(MagnificationGesture().updating($magnification) { value, state, _ in state = value }
                                    .onEnded { value in scale = min(8, max(0.25, scale * value)); pan = .zero })
                                .accessibilityIdentifier("telegram.profilePhotos.image")
                                .accessibilityValue("Масштаб \(Int(scale * 100)) процентов; поворот \(rotation * 90) градусов")
                        } else if gallery.state == .loading || gallery.imageLoading {
                            ProgressView("Загрузка фотографии…").tint(.white)
                        } else {
                            VStack(spacing: 12) {
                                Text(gallery.imageError ?? "Доступных фотографий нет или их не удалось получить.")
                                Button("Повторить") { gallery.state == .ready ? gallery.retryImage() : gallery.retry() }
                                    .accessibilityIdentifier(gallery.state == .ready ? "telegram.profilePhotos.retryImage" : "telegram.profilePhotos.retry")
                            }
                        }
                    }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
                controls.frame(height: 95)
            }
            Button(action: close) { Image(systemName: "xmark").font(.title2).padding(14) }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction).padding(12)
                .accessibilityLabel("Закрыть").accessibilityIdentifier("telegram.profilePhotos.close")
        }.foregroundStyle(.white)
            .background(GalleryWindowAnchor(owner: anchor, command: command).frame(width: 0, height: 0))
            .onChange(of: gallery.selectedPhoto?.id) { _, _ in scale = 1; rotation = 0; pan = .zero }
            .onDisappear { saveTask?.cancel(); saveTask = nil; anchor.cancel() }
            .alert("Не удалось сохранить фотографию", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "") }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).lineLimit(1)
                if let photo = gallery.selectedPhoto {
                    Text("\(gallery.selectedIndex + 1) из \(gallery.photos.count)").accessibilityIdentifier("telegram.profilePhotos.position")
                    if photo.date > 0 { Text(Date(timeIntervalSince1970: Double(photo.date)).formatted(date: .abbreviated, time: .shortened)).font(.caption) }
                    if photo.totalCount > gallery.photos.count { Text("Доступно \(gallery.photos.count) из \(photo.totalCount)").font(.caption) }
                    if photo.hasVideo { Text("Фотокадр видеоаватара").font(.caption) }
                }
            }.frame(maxWidth: 180, alignment: .leading)
            Button { gallery.move(by: -1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: []).disabled(!gallery.canGoBack || gallery.isSaving || saveTask != nil)
                .accessibilityLabel("Предыдущая фотография").accessibilityIdentifier("telegram.profilePhotos.previous")
            ScrollViewReader { proxy in
              ScrollView(.horizontal) {
                LazyHStack(spacing: 5) {
                    ForEach(Array(gallery.photos.enumerated()), id: \.element.id) { index, photo in
                        Button { gallery.select(photoID: photo.id) } label: {
                            ZStack {
                                Color.white.opacity(0.1)
                                if let thumbnail = gallery.thumbnails[photo.id] {
                                    Image(thumbnail.image, scale: 1, label: Text("Фотография")).resizable().scaledToFill()
                                } else { Image(systemName: "photo") }
                            }.frame(width: 60, height: 60).clipped()
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(gallery.selectedPhoto?.id == photo.id ? Color.white : Color.clear, lineWidth: 2))
                        }.buttonStyle(.plain).disabled(gallery.isSaving || saveTask != nil)
                            .id(photo.id)
                            .accessibilityLabel("Фотография \(index + 1) из \(gallery.photos.count)")
                            .accessibilityValue(gallery.selectedPhoto?.id == photo.id ? "Выбрана" : "")
                            .accessibilityIdentifier("telegram.profilePhotos.thumbnail.\(index)")
                            .onAppear { gallery.requestThumbnail(photoID: photo.id) }
                            .onDisappear { gallery.releaseThumbnail(photoID: photo.id) }
                    }
                }.padding(4)
            }
              .onAppear { if let id = gallery.selectedPhoto?.id { proxy.scrollTo(id, anchor: .center) } }
              .onChange(of: gallery.selectedPhoto?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
            }.frame(maxWidth: 400).frame(height: 80)
            Button { gallery.move(by: 1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: []).disabled(!gallery.canGoForward || gallery.isSaving || saveTask != nil)
                .accessibilityLabel("Следующая фотография").accessibilityIdentifier("telegram.profilePhotos.next")
            Spacer(minLength: 0)
            Button { zoom(-0.5) } label: { Image(systemName: "minus.magnifyingglass") }.keyboardShortcut("-", modifiers: [])
                .accessibilityLabel("Уменьшить").accessibilityIdentifier("telegram.profilePhotos.zoomOut")
                .disabled(transformDisabled || scale <= 0.25)
            Button { zoom(0.5) } label: { Image(systemName: "plus.magnifyingglass") }.keyboardShortcut("=", modifiers: [])
                .accessibilityLabel("Увеличить").accessibilityIdentifier("telegram.profilePhotos.zoomIn")
                .disabled(transformDisabled || scale >= 8)
            Button(action: rotate) { Image(systemName: "rotate.right") }
                .keyboardShortcut("r", modifiers: .command).accessibilityLabel("Повернуть")
                .accessibilityIdentifier("telegram.profilePhotos.rotate").disabled(transformDisabled)
            Button(action: save) { Image(systemName: "square.and.arrow.down") }
                .keyboardShortcut("s", modifiers: .command).disabled(gallery.image == nil || gallery.isSaving || saveTask != nil)
                .accessibilityLabel("Сохранить оригинал").accessibilityIdentifier("telegram.profilePhotos.save")
        }.buttonStyle(.plain).padding(.horizontal, 24)
    }
    private var transformDisabled: Bool { gallery.image == nil || gallery.isSaving || saveTask != nil }
    private func command(_ command: TelegramProfilePhotosPresenter.GalleryWindow.Command) {
        switch command {
        case .previous: if !gallery.isSaving && saveTask == nil { gallery.move(by: -1) }
        case .next: if !gallery.isSaving && saveTask == nil { gallery.move(by: 1) }
        case .zoomIn: if !transformDisabled { zoom(0.5) }
        case .zoomOut: if !transformDisabled { zoom(-0.5) }
        case .rotate: if !transformDisabled { rotate() }
        case .save: if !transformDisabled { save() }
        }
    }
    private func rotate() { rotation = (rotation + 1) % 4; pan = .zero }
    private func clamp(_ value: CGFloat, _ limit: CGFloat) -> CGFloat { min(limit, max(-limit, value)) }
    private func zoom(_ amount: CGFloat) { scale = min(8, max(0.25, scale + amount)); pan = .zero }
    private func save() {
        guard saveTask == nil, gallery.image != nil else { return }
        saveTask = Task { @MainActor in
            defer { saveTask = nil }
            guard let destination = await anchor.choose(name: gallery.suggestedFileName), !Task.isCancelled else { return }
            do { try await gallery.save(to: destination) }
            catch { if !Task.isCancelled { saveError = "Не удалось сохранить оригинал. Проверьте выбранную папку и повторите." } }
        }
    }
}

@MainActor private final class GallerySaveAnchor: ObservableObject {
    weak var view: NSView?
    private var panel: NSSavePanel?
    func choose(name: String) async -> URL? {
        guard let window = view?.window, panel == nil else { return nil }
        let panel = NSSavePanel(); self.panel = panel
        panel.nameFieldStringValue = name
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { [weak self] response in
                self?.panel = nil
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
    func cancel() { panel?.cancel(nil) }
}
private struct GalleryWindowAnchor: NSViewRepresentable {
    let owner: GallerySaveAnchor
    let command: (TelegramProfilePhotosPresenter.GalleryWindow.Command) -> Void
    func makeNSView(context: Context) -> Anchor {
        let view = Anchor(); owner.view = view; view.command = command; return view
    }
    func updateNSView(_ nsView: Anchor, context: Context) {
        nsView.command = command; nsView.install()
    }
    static func dismantleNSView(_ nsView: Anchor, coordinator: ()) {
        (nsView.window as? TelegramProfilePhotosPresenter.GalleryWindow)?.commandHandler = nil
        nsView.command = nil
    }
    final class Anchor: NSView {
        var command: ((TelegramProfilePhotosPresenter.GalleryWindow.Command) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); install() }
        func install() { (window as? TelegramProfilePhotosPresenter.GalleryWindow)?.commandHandler = command }
    }
}
