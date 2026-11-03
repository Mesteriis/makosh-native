import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MakoshTelegram

/// Captures the input boundary before asynchronous item-provider loading begins.
@MainActor struct TelegramUploadDropCapture {
    let contextID: UUID
    let target: TelegramUploadTarget
    let input: TelegramComposerInput

    init?(model: TelegramModel) {
        guard model.upload.phase == .idle, !model.voiceRecording.isActive,
              let target = model.uploadTarget(replyTo: model.composerReply.resolved?.source,
                                              contextID: model.uploadContextID) else { return nil }
        self.contextID = model.uploadContextID; self.target = target; self.input = model.composerInput
    }

    @discardableResult func prepare(urls: [URL], asMedia: Bool, model: TelegramModel,
                                   photoSize: TelegramUploadPhotoSize) -> Bool {
        guard let current = Self(model: model), current.contextID == contextID,
              current.target == target, current.input == input, !urls.isEmpty,
              urls.allSatisfy({ $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost") }) else { return false }
        var seen = Set<URL>()
        let sources = urls.filter { seen.insert($0.standardizedFileURL).inserted }.map { url in
            let type = UTType(filenameExtension: url.pathExtension)
            let mode: TelegramUploadMode = !asMedia ? .file :
                type?.conforms(to: .image) == true ? .photo :
                type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true ? .video : .file
            return TelegramUploadSelection(source: url, mode: mode)
        }
        model.prepareUpload(sources: sources, isGrouped: sources.count > 1, target: target,
                            captionInput: input, contextID: contextID, photoSize: photoSize)
        return model.upload.phase == .preparing
    }
}

@MainActor private final class TelegramUploadDropState: ObservableObject {
    @Published var capture: TelegramUploadDropCapture?
    @Published var media = false
    @Published var canUseMedia = false
    private var loading: Task<Void, Never>?
    private var loadID: UUID?

    func cancel() { loading?.cancel(); loading = nil; loadID = nil; capture = nil }

    func receive(_ providers: [NSItemProvider], capture: TelegramUploadDropCapture,
                 asMedia: Bool, model: TelegramModel, photoSize: TelegramUploadPhotoSize) {
        cancel()
        let id = UUID(); loadID = id
        loading = Task { [weak self] in
            do {
                let urls = try await TelegramUploadDropLoading.urls(providers)
                guard !Task.isCancelled, self?.loadID == id else { return }
                _ = capture.prepare(urls: urls, asMedia: asMedia, model: model, photoSize: photoSize)
            } catch {
                if !Task.isCancelled, self?.loadID == id,
                   let current = TelegramUploadDropCapture(model: model), current.contextID == capture.contextID,
                   current.target == capture.target, current.input == capture.input { model.error = "Не удалось прочитать перетаскиваемые файлы." }
            }
            if self?.loadID == id { self?.loading = nil; self?.loadID = nil }
        }
    }
    isolated deinit { loading?.cancel() }
}

/// The reference reveals stacked File/Media destinations only during a file drag.
struct TelegramUploadDropModifier: ViewModifier {
    @ObservedObject var model: TelegramModel
    @StateObject private var state = TelegramUploadDropState()
    @AppStorage(TelegramUploadPhotoSize.preferenceKey) private var largePhotos = false
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content.overlay {
                if state.capture != nil {
                    VStack(spacing: 5) {
                        destination("Отправить файлы", detail: "Без сжатия", selected: !state.media)
                        if state.canUseMedia { destination("Отправить медиа", detail: "Фото и видео", selected: state.media) }
                    }.padding(5).allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.fileURL], delegate: FileDropDelegate(model: model, state: state,
                height: geometry.size.height, photoSize: largePhotos ? .large : .standard))
        }
        .onChange(of: model.selectedChatID) { _, _ in state.cancel() }
        .onChange(of: model.uploadContextID) { _, _ in state.cancel() }
        .onDisappear { state.cancel() }
    }
    private func destination(_ title: String, detail: String, selected: Bool) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.title2).foregroundStyle(.secondary)
            Text(detail).font(.system(size: 16, weight: .medium))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 2) }
    }
}

@MainActor private struct FileDropDelegate: DropDelegate {
    let model: TelegramModel
    let state: TelegramUploadDropState
    let height: CGFloat
    let photoSize: TelegramUploadPhotoSize
    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL]) && TelegramUploadDropCapture(model: model) != nil
    }
    func dropEntered(info: DropInfo) {
        state.capture = TelegramUploadDropCapture(model: model)
        // A provider may omit its suggested name. Show both destinations then;
        // the normal source classifier decides the final eligible presentation.
        state.canUseMedia = info.itemProviders(for: [UTType.fileURL]).contains { provider in
            guard let name = provider.suggestedName else { return true }
            let type = UTType(filenameExtension: (name as NSString).pathExtension)
            return type?.conforms(to: .image) == true || type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true
        }
        state.media = state.canUseMedia && info.location.y > height / 2
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        state.media = state.canUseMedia && info.location.y > height / 2
        return DropProposal(operation: state.capture == nil ? .cancel : .copy)
    }
    func dropExited(info: DropInfo) { state.capture = nil }
    func performDrop(info: DropInfo) -> Bool {
        guard let capture = state.capture else { return false }
        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else { return false }
        state.receive(providers, capture: capture, asMedia: state.media, model: model, photoSize: photoSize)
        return true
    }
}
