import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MakoshTelegram

/// A drag belongs to one account context and one visible preparation revision.
@MainActor struct TelegramUploadAppendDropCapture {
    let contextID: UUID
    let preparationID: UUID
    let revision: UUID
    let captionRevision: UUID
    let target: TelegramUploadTarget
    let presentation: TelegramUploadPresentation

    init?(upload: TelegramUploadController, contextID: UUID) {
        guard upload.canAppendItems, let preparationID = upload.preparationContextID,
              let target = upload.target else { return nil }
        self.contextID = contextID; self.preparationID = preparationID; self.target = target
        revision = upload.itemsRevision; captionRevision = upload.captionRevision; presentation = upload.presentation
    }
    @discardableResult func prepare(urls: [URL], upload: TelegramUploadController, currentContextID: UUID,
                                   photoSize: TelegramUploadPhotoSize) -> Bool {
        guard currentContextID == contextID,
              let current = Self(upload: upload, contextID: currentContextID),
              current.preparationID == preparationID, current.revision == revision,
              current.captionRevision == captionRevision, current.target == target,
              current.presentation == presentation, !urls.isEmpty,
              urls.allSatisfy({ $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost") }) else { return false }
        let sources = urls.map { url in
            let type = UTType(filenameExtension: url.pathExtension)
            let mode: TelegramUploadMode = presentation == .file ? .file :
                type?.conforms(to: .image) == true ? .photo :
                type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true ? .video : .file
            return TelegramUploadSelection(source: url, mode: mode)
        }
        return upload.append(sources: sources, contextID: preparationID, revision: revision, photoSize: photoSize)
    }
}

@MainActor private final class TelegramUploadAppendDropState: ObservableObject {
    @Published var capture: TelegramUploadAppendDropCapture?
    private var loading: Task<Void, Never>?
    private var loadID: UUID?
    func cancel() { loading?.cancel(); loading = nil; loadID = nil; capture = nil }
    func receive(_ providers: [NSItemProvider], capture: TelegramUploadAppendDropCapture,
                 model: TelegramModel, photoSize: TelegramUploadPhotoSize) {
        cancel()
        let id = UUID(); loadID = id
        loading = Task { [weak self] in
            do {
                let urls = try await TelegramUploadDropLoading.urls(providers)
                guard !Task.isCancelled, self?.loadID == id, model.selectedChatID == capture.target.chatID else { return }
                _ = capture.prepare(urls: urls, upload: model.upload, currentContextID: model.uploadContextID, photoSize: photoSize)
            } catch {
                if !Task.isCancelled, self?.loadID == id, model.uploadContextID == capture.contextID,
                   model.selectedChatID == capture.target.chatID, model.upload.preparationContextID == capture.preparationID,
                   model.upload.itemsRevision == capture.revision { model.error = "Не удалось прочитать добавляемые файлы." }
            }
            if self?.loadID == id { self?.loading = nil; self?.loadID = nil }
        }
    }
    isolated deinit { loading?.cancel() }
}

struct TelegramUploadAppendDropModifier: ViewModifier {
    @ObservedObject var model: TelegramModel
    @StateObject private var state = TelegramUploadAppendDropState()
    @AppStorage(TelegramUploadPhotoSize.preferenceKey) private var largePhotos = false
    func body(content: Content) -> some View {
        content.overlay {
            if state.capture != nil {
                Text("Добавить файлы").font(.title2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2) }
                    .padding(5).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], delegate: AppendDropDelegate(model: model, state: state,
            photoSize: largePhotos ? .large : .standard))
        .onChange(of: model.selectedChatID) { _, _ in state.cancel() }
        .onChange(of: model.uploadContextID) { _, _ in state.cancel() }
        .onDisappear { state.cancel() }
    }
}

@MainActor private struct AppendDropDelegate: DropDelegate {
    let model: TelegramModel
    let state: TelegramUploadAppendDropState
    let photoSize: TelegramUploadPhotoSize
    private var capture: TelegramUploadAppendDropCapture? {
        guard model.selectedChatID == model.upload.target?.chatID else { return nil }
        return .init(upload: model.upload, contextID: model.uploadContextID)
    }
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [UTType.fileURL]) && capture != nil }
    func dropEntered(info: DropInfo) { state.capture = capture }
    func dropUpdated(info: DropInfo) -> DropProposal? { .init(operation: state.capture == nil ? .cancel : .copy) }
    func dropExited(info: DropInfo) { state.capture = nil }
    func performDrop(info: DropInfo) -> Bool {
        guard let capture = state.capture else { return false }
        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else { return false }
        state.receive(providers, capture: capture, model: model, photoSize: photoSize)
        return true
    }
}
