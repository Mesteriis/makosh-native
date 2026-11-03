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
    @Published public private(set) var thumbnails: [String: TelegramImagePreview] = [:]
    @Published public private(set) var isSaving = false
    public var suggestedFileName: String { "photo." + (image?.originalExtension ?? "jpg") }
    private var original: (url: URL, size: Int64, sha256: String)?
    private var saveTask: Task<Void, Error>?
    @MainActor private final class ThumbnailJob {
        var lease: (any TelegramAvatarLease)?
        var decode: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        func cancel() { lease?.cancel(); decode?.cancel(); deadline?.cancel() }
    }
    private var thumbnailJobs: [String: ThumbnailJob] = [:]
    public private(set) var peerID: Int64?
    public var selectedPhoto: TelegramProfilePhoto? { photos.indices.contains(selectedIndex) ? photos[selectedIndex] : nil }
    public var canGoBack: Bool { !isSaving && selectedIndex > 0 }
    public var canGoForward: Bool { !isSaving && selectedIndex + 1 < photos.count }
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
        saveTask?.cancel(); for job in thumbnailJobs.values { job.cancel() }
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
            self.stopSupplementaryWork()
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
    public func retryImage() { guard !isSaving, state == .ready else { return }; loadImage() }
    public func move(by delta: Int) {
        guard !isSaving, state == .ready, delta == -1 || delta == 1,
              photos.indices.contains(selectedIndex + delta) else { return }
        selectedIndex += delta; loadImage()
    }

    public func select(photoID: String) {
        guard !isSaving, state == .ready, let index = photos.firstIndex(where: { $0.id == photoID }), index != selectedIndex else { return }
        selectedIndex = index; loadImage()
    }

    public func save(to destination: URL) async throws {
        guard !isSaving, let original, image != nil, let request = imageRequestID else { throw TelegramFileError.unavailable }
        isSaving = true
        let task = Task { try await TelegramDownloadedFileIO.copy(source: original.url, expectedSize: original.size, destination: destination, expectedSHA256: original.sha256) }
        saveTask = task
        defer { if imageRequestID == request { saveTask = nil; isSaving = false } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func requestThumbnail(photoID: String) {
        guard state == .ready, let session, photos.contains(where: { $0.id == photoID }),
              thumbnailJobs[photoID] == nil, thumbnailJobs.count < 32 else { return }
        let job = ThumbnailJob(), context = contextID, request = requestID
        thumbnailJobs[photoID] = job
        job.deadline = Task { [weak self, weak job] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, let job, self.thumbnailJobs[photoID] === job else { return }
            self.releaseThumbnail(photoID: photoID)
        }
        let lease = session.thumbnail(photoID: photoID) { [weak self, weak job] event in
            guard let self, let job, self.contextID == context, self.requestID == request,
                  self.thumbnailJobs[photoID] === job else { return }
            switch event {
            case .failed:
                guard self.thumbnails[photoID] == nil else { return }
                self.releaseThumbnail(photoID: photoID)
            case let .data(url, size):
                guard job.decode == nil, self.thumbnails[photoID] == nil else { return }
                job.decode = Task { [weak self, weak job] in
                    do {
                        let preview = try await TelegramDownloadedFileIO.image(source: url, expectedSize: size,
                            maximumBytes: 2 * 1_024 * 1_024, maximumDimension: 4096, maximumPixels: 16_000_000, thumbnailPixelSize: 128)
                        try Task.checkCancellation()
                        guard let self, let job, self.thumbnailJobs[photoID] === job, self.contextID == context, self.requestID == request else { return }
                        job.deadline?.cancel(); job.deadline = nil; job.decode = nil
                        self.thumbnails[photoID] = preview
                    } catch {
                        guard !Task.isCancelled, let self, let job,
                              self.thumbnailJobs[photoID] === job, self.contextID == context,
                              self.requestID == request else { return }
                        self.releaseThumbnail(photoID: photoID)
                    }
                }
            }
        }
        if thumbnailJobs[photoID] === job { job.lease = lease } else { lease.cancel() }
    }

    public func releaseThumbnail(photoID: String) {
        let job = thumbnailJobs.removeValue(forKey: photoID)
        thumbnails.removeValue(forKey: photoID); job?.cancel()
    }

    private func stopSupplementaryWork() {
        saveTask?.cancel(); saveTask = nil; isSaving = false
        let previous = thumbnailJobs; thumbnailJobs.removeAll(); thumbnails.removeAll()
        for job in previous.values { job.cancel() }
    }

    public func close() {
        stopSupplementaryWork()
        requestID = nil
        deadline?.cancel(); deadline = nil
        stopImage(); session?.cancel(); session = nil
        peerID = nil; photos = []; selectedIndex = 0; state = .idle
    }

    private func failLoad() {
        stopSupplementaryWork()
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
                        guard let digest = image.originalSHA256 else { throw TelegramFileError.invalidImage }
                        self.original = (url, size, digest); self.image = image; self.imageLoading = false; self.decode = nil
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
        original = nil
        imageRequestID = nil
        decode?.cancel(); decode = nil
        imageDeadline?.cancel(); imageDeadline = nil
        imageLease?.cancel(); imageLease = nil
        image = nil; imageLoading = false; imageError = nil
    }
}
