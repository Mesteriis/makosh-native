import Foundation
import Combine

public enum TelegramProfilePhotosState: Equatable, Sendable { case idle, loading, ready, unavailable }

/// One explicitly opened gallery, owned by the currently bound account.
@MainActor public final class TelegramProfilePhotosController: ObservableObject {
    @Published public private(set) var state: TelegramProfilePhotosState = .idle
    @Published public private(set) var photos: [TelegramProfilePhoto] = []
    @Published public private(set) var selectedIndex = 0
    @Published public private(set) var image: TelegramImagePreview?
    @Published public private(set) var imageLoading = false
    @Published public private(set) var imageError: String?
    public private(set) var peerID: Int64?
    public var selectedPhoto: TelegramProfilePhoto? { photos.indices.contains(selectedIndex) ? photos[selectedIndex] : nil }
    public var canGoBack: Bool { selectedIndex > 0 }
    public var canGoForward: Bool { selectedIndex + 1 < photos.count }
    private var provider: (any TelegramProfilePhotoProvider)?
    private var session: (any TelegramProfilePhotoSession)?
    private var imageLease: (any TelegramAvatarLease)?
    private var contextID = UUID()
    private var requestID: UUID?
    private var imageRequestID: UUID?
    private var deadline: Task<Void, Never>?
    private var imageDeadline: Task<Void, Never>?
    private var decode: Task<Void, Never>?
    public init() {}
    isolated deinit {
        deadline?.cancel(); imageDeadline?.cancel(); decode?.cancel()
        imageLease?.cancel(); session?.cancel()
    }

    func bind(_ provider: (any TelegramProfilePhotoProvider)?) {
        close(); contextID = UUID(); self.provider = provider
    }

    public func open(peerID: Int64) {
        close(); self.peerID = peerID
        guard let provider else { state = .unavailable; return }
        state = .loading
        let request = UUID(), context = contextID
        requestID = request
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.requestID == request, self.contextID == context else { return }
            self.failLoad()
        }
        let session = provider.load(peerID: peerID) { [weak self] photos in
            guard let self, self.requestID == request, self.contextID == context, self.peerID == peerID else { return }
            self.deadline?.cancel(); self.deadline = nil
            var seen = Set<String>()
            guard !photos.isEmpty, photos.count <= 2_000,
                  photos.allSatisfy({ !$0.id.isEmpty && seen.insert($0.id).inserted }) else { self.failLoad(); return }
            self.stopImage()
            self.photos = photos; self.selectedIndex = 0; self.state = .ready
            self.loadImage()
        }
        if requestID == request {
            self.session = session
            // A fixture/cache may publish synchronously before returning its session.
            if state == .ready { loadImage() }
        } else { session.cancel() }
    }

    public func retry() { if let peerID { open(peerID: peerID) } }
    public func retryImage() { guard state == .ready else { return }; loadImage() }
    public func move(by delta: Int) {
        guard state == .ready, delta == -1 || delta == 1,
              photos.indices.contains(selectedIndex + delta) else { return }
        selectedIndex += delta; loadImage()
    }

    public func close() {
        requestID = nil
        deadline?.cancel(); deadline = nil
        stopImage(); session?.cancel(); session = nil
        peerID = nil; photos = []; selectedIndex = 0; state = .idle
    }

    private func failLoad() {
        requestID = nil; deadline?.cancel(); deadline = nil
        stopImage(); session?.cancel(); session = nil
        photos = []; selectedIndex = 0; state = .unavailable
    }

    private func loadImage() {
        stopImage()
        guard let session, let photo = selectedPhoto, let request = requestID else { return }
        let imageRequest = UUID(), context = contextID
        imageRequestID = imageRequest; imageLoading = true
        imageDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.imageRequestID == imageRequest else { return }
            self.imageFailed("Фотография пока не загрузилась. Повторите запрос.")
        }
        let lease = session.image(photoID: photo.id) { [weak self] event in
            guard let self, self.contextID == context, self.requestID == request,
                  self.imageRequestID == imageRequest, self.selectedPhoto?.id == photo.id,
                  self.imageLoading else { return }
            switch event {
            case let .data(url, size):
                guard self.decode == nil else { return }
                self.decode = Task { [weak self] in
                    do {
                        let image = try await TelegramDownloadedFileIO.image(source: url, expectedSize: size)
                        try Task.checkCancellation()
                        guard let self, self.contextID == context, self.requestID == request,
                              self.imageRequestID == imageRequest, self.selectedPhoto?.id == photo.id else { return }
                        self.image = image; self.imageLoading = false; self.decode = nil
                        self.imageDeadline?.cancel(); self.imageDeadline = nil
                    } catch {
                        guard !Task.isCancelled, let self, self.imageRequestID == imageRequest else { return }
                        self.imageFailed("Не удалось прочитать фотографию. Повторите загрузку.")
                    }
                }
            case .failed: self.imageFailed("Не удалось загрузить фотографию. Повторите запрос.")
            }
        }
        if imageRequestID == imageRequest, imageLoading || image != nil { imageLease = lease }
        else { lease.cancel() }
    }

    private func imageFailed(_ message: String) {
        stopImage(); imageError = message
    }

    private func stopImage() {
        imageRequestID = nil
        decode?.cancel(); decode = nil
        imageDeadline?.cancel(); imageDeadline = nil
        imageLease?.cancel(); imageLease = nil
        image = nil; imageLoading = false; imageError = nil
    }
}
