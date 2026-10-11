import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit
import MakoshCore

struct TelegramPreparedUploadMedia {
    let resource: LocalFileMediaResource
    let reference: AnyMediaReference
    let videoThumbnail: TelegramUploadVideoThumbnailResource?
    let videoCover: TelegramUploadVideoThumbnailResource?
    init(resource: LocalFileMediaResource, reference: AnyMediaReference, videoThumbnail: TelegramUploadVideoThumbnailResource?,
         videoCover: TelegramUploadVideoThumbnailResource? = nil) {
        self.resource = resource; self.reference = reference; self.videoThumbnail = videoThumbnail; self.videoCover = videoCover
    }
}

@MainActor
final class TelegramUploadMediaBoxPreparation: TelegramUploadLease {
    private let keep = MetaDisposable(), thumbnailKeep = MetaDisposable(), coverKeep = MetaDisposable(), data = MetaDisposable()
    private var task: Task<Void, Never>?
    private var stopped = false, finished = false
    private let expectedPlaintextSHA256: String?
    private let receive: @MainActor (Result<TelegramPreparedUploadMedia, TelegramUploadFileError>) -> Void

    init(mediaBox: MediaBox, file: TelegramUploadFile, expectedPlaintextSHA256: String? = nil,
         receive: @escaping @MainActor (Result<TelegramPreparedUploadMedia, TelegramUploadFileError>) -> Void) {
        self.receive = receive
        self.expectedPlaintextSHA256 = expectedPlaintextSHA256
        task = Task { [weak self] in
            do {
                try TelegramUploadFileIO.validateOwnedStage(file)
                try await TelegramUploadFileIO.verifyMetadata(file)
                if let expectedPlaintextSHA256 {
                    guard TelegramPendingUploadDraft.isHash(expectedPlaintextSHA256),
                          try await uploadPlaintextMatches(file.url, size: file.size, expected: expectedPlaintextSHA256) else {
                        throw TelegramUploadFileError.unavailable
                    }
                }
                let jpeg = file.mode == .video ? try await TelegramUploadVideoIO.thumbnail(file) : nil
                let cover = try file.videoCover.map { try TelegramUploadVideoCoverIO.validatedBytes($0) }
                try Task.checkCancellation()
                guard let self, !self.stopped else { return }
                self.store(mediaBox: mediaBox, file: file, jpeg: jpeg, coverBytes: cover)
            } catch {
                guard let self, !self.stopped, !Task.isCancelled else { return }
                self.finish(.failure(error as? TelegramUploadFileError ?? .unavailable))
            }
        }
    }

    private func store(mediaBox: MediaBox, file: TelegramUploadFile, jpeg: TelegramUploadVideoThumbnail?, coverBytes: Data?) {
        let thumbnail = jpeg.map { TelegramUploadVideoThumbnailResource(id: Int64.random(in: Int64.min...Int64.max),
            width: $0.width, height: $0.height, size: Int64($0.data.count)) }
        let cover = file.videoCover.map { staged -> TelegramUploadVideoThumbnailResource in
            var id = Int64.random(in: Int64.min...Int64.max)
            while id == thumbnail?.id { id = Int64.random(in: Int64.min...Int64.max) }
            return TelegramUploadVideoThumbnailResource(id: id, width: staged.width, height: staged.height, size: staged.size)
        }
        guard let (resource, reference) = telegramUploadMedia(file, videoThumbnail: thumbnail, videoCover: cover) else {
            finish(.failure(.unavailable)); return
        }
        let prepared = TelegramPreparedUploadMedia(resource: resource, reference: reference, videoThumbnail: thumbnail, videoCover: cover)
        keep.set(mediaBox.keepResource(id: resource.id).start())
        if let thumbnail, let jpeg {
            thumbnailKeep.set(mediaBox.keepResource(id: thumbnail.resource.id).start())
            mediaBox.storeResourceData(thumbnail.resource.id, data: jpeg.data)
        }
        if let cover, let coverBytes {
            coverKeep.set(mediaBox.keepResource(id: cover.resource.id).start())
            mediaBox.storeResourceData(cover.resource.id, data: coverBytes)
        }
        // Void writes suppress errors. Observe complete files and verify both
        // JPEGs before publishing a capability that can enter enqueue.
        mediaBox.copyResourceData(resource.id, fromTempPath: file.url.path)
        data.set((telegramUploadMediaBoxReadback(mediaBox, resource: resource, thumbnail: thumbnail?.resource, cover: cover?.resource)
            |> deliverOnMainQueue).start(next: { [weak self] original, preview, coverData in
                guard let self, !self.stopped, !self.finished else { return }
                guard original.complete, original.offset == 0, original.size == file.size,
                      validUploadCacheFile(original.path, size: file.size) else {
                    self.finish(.failure(.unavailable)); return
                }
                if let cover, let coverBytes {
                    guard let coverData, coverData.complete, coverData.offset == 0, coverData.size == cover.size,
                          validUploadCacheFile(coverData.path, size: cover.size, expected: coverBytes) else {
                        self.finish(.failure(.unavailable)); return
                    }
                }
                if let thumbnail, let jpeg {
                    guard let preview, preview.complete, preview.offset == 0, preview.size == thumbnail.size,
                          validUploadCacheFile(preview.path, size: thumbnail.size, expected: jpeg.data) else {
                        self.finish(.failure(.unavailable)); return
                    }
                }
                if let expected = self.expectedPlaintextSHA256 {
                    self.task = Task { [weak self] in
                        do {
                            guard try await uploadPlaintextMatches(URL(fileURLWithPath: original.path), size: file.size, expected: expected) else {
                                throw TelegramUploadFileError.unavailable
                            }
                            try Task.checkCancellation()
                            guard let self, !self.stopped else { return }
                            self.finish(.success(prepared))
                        } catch {
                            guard let self, !self.stopped, !Task.isCancelled else { return }
                            self.finish(.failure(.unavailable))
                        }
                    }
                } else { self.finish(.success(prepared)) }
            }))
    }

    private func finish(_ result: Result<TelegramPreparedUploadMedia, TelegramUploadFileError>) {
        guard !stopped, !finished else { return }
        finished = true; data.dispose(); task = nil
        receive(result)
        if case .failure = result { stop() }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true; task?.cancel(); task = nil
        keep.dispose(); thumbnailKeep.dispose(); coverKeep.dispose(); data.dispose()
    }
    isolated deinit { stop() }
}

private func uploadPlaintextMatches(_ url: URL, size: Int64, expected: String) async throws -> Bool {
    let capture = try ArchiveFileCapture(file: url, byteCount: size)
    return try await Task.detached(priority: .userInitiated) { try capture.plaintextSHA256() }.value == expected
}

/// Subscribe on the native FIFO data queue after the writes, avoiding the
/// concurrent fast path observing a copy still in progress. The synchronous
/// first snapshot always emits complete or incomplete; missing bytes are a
/// known failure, not an observation left waiting for a fetch that never starts.
/// Pure mapping stays outside MainActor; only the final callback returns to UI.
private nonisolated func telegramUploadMediaBoxReadback(_ mediaBox: MediaBox,
    resource: LocalFileMediaResource, thumbnail: LocalFileMediaResource?, cover: LocalFileMediaResource?) -> Signal<(MediaResourceData, MediaResourceData?, MediaResourceData?), NoError> {
    let original = mediaBox.resourceData(resource, pathExtension: nil,
        option: .complete(waitUntilFetchStatus: false), attemptSynchronously: true) |> take(1)
    let preview: Signal<MediaResourceData?, NoError>
    if let thumbnail {
        preview = mediaBox.resourceData(thumbnail, pathExtension: nil,
            option: .complete(waitUntilFetchStatus: false), attemptSynchronously: true)
            |> take(1) |> map { Optional($0) }
    } else { preview = .single(nil) }
    let coverData: Signal<MediaResourceData?, NoError>
    if let cover {
        coverData = mediaBox.resourceData(cover, pathExtension: nil,
            option: .complete(waitUntilFetchStatus: false), attemptSynchronously: true)
            |> take(1) |> map { Optional($0) }
    } else { coverData = .single(nil) }
    return combineLatest(original, preview, coverData) |> take(1) |> runOn(mediaBox.dataQueue)
}
