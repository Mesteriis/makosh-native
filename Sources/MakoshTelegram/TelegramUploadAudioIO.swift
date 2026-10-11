import Foundation
import AVFoundation
import AudioToolbox
import Darwin

enum TelegramUploadAudioIO {
    static func inspect(_ raw: TelegramUploadFile) async throws -> TelegramUploadAudioMetadata {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { try await inspectOwned(raw) }
        let metadata = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        return metadata
    }

    /// The expected persisted metadata is deliberately ignored: restore must probe bytes independently.
    private static func inspectOwned(_ raw: TelegramUploadFile) async throws -> TelegramUploadAudioMetadata {
        try Task.checkCancellation()
        guard raw.mode == .file else { throw TelegramUploadFileError.unavailable }
        try TelegramUploadFileIO.validateOwnedStage(raw)
        guard raw.size > 0 else { throw TelegramUploadFileError.invalidAudio }
        let fd = Darwin.open(raw.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TelegramUploadFileError.unavailable }
        defer { Darwin.close(fd) }
        var original = stat()
        guard fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
              original.st_uid == getuid(), original.st_mode & 0o777 == 0o600,
              original.st_size == raw.size else { throw TelegramUploadFileError.unavailable }
        do {
            // The owned payload has no extension. Derive its native hint from bytes on the held fd.
            let mime = try containerMIME(fd: fd, size: raw.size)
            try Task.checkCancellation()
            let asset = AVURLAsset(url: raw.url, options: [
                AVURLAssetOverrideMIMETypeKey: mime,
                AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
                AVURLAssetShouldSupportAliasDataReferencesKey: false
            ])
            defer { asset.cancelLoading() }
            return try await withTaskCancellationHandler {
                let playable = try await asset.load(.isPlayable)
                let duration = try await asset.load(.duration).seconds
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                try Task.checkCancellation()
                guard playable, duration.isFinite, duration > 0, duration <= 604_800,
                      !tracks.isEmpty else { throw TelegramUploadFileError.invalidAudio }
                for track in tracks {
                    let range = try await track.load(.timeRange)
                    guard range.start.seconds.isFinite, range.duration.seconds.isFinite,
                          range.duration.seconds > 0, range.duration.seconds <= 604_800,
                          range.end.seconds.isFinite else { throw TelegramUploadFileError.invalidAudio }
                    try Task.checkCancellation()
                    try validateDecoding(asset, track: track, range: range)
                }
                let tags = try await readTags(asset)
                let result = TelegramUploadAudioMetadata(duration: Int32(duration),
                    title: tags.title, performer: tags.performer)
                guard result.isValid else { throw TelegramUploadFileError.invalidAudio }
                try Task.checkCancellation()
                try TelegramUploadVideoIO.validateSnapshot(raw, fd: fd, original: original)
                return result
            } onCancel: { asset.cancelLoading() }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            // Mutation stays an ownership error even when it first causes a native decoder failure.
            try TelegramUploadVideoIO.validateSnapshot(raw, fd: fd, original: original)
            if let error = error as? TelegramUploadFileError { throw error }
            throw TelegramUploadFileError.invalidAudio
        }
    }

    private struct AudioSource {
        let fd: Int32
        let size: Int64
        var remainingProbeBytes: Int64 = 16 * 1024 * 1024
    }

    private static func containerMIME(fd: Int32, size: Int64) throws -> String {
        var source = AudioSource(fd: fd, size: size)
        return try withUnsafeMutablePointer(to: &source) { context in
            var file: AudioFileID?
            let status = AudioFileOpenWithCallbacks(context, { context, position, requested, buffer, count in
                let source = context.assumingMemoryBound(to: AudioSource.self)
                count.pointee = 0
                guard !Task.isCancelled, position >= 0, position <= source.pointee.size else {
                    return kAudioFileUnspecifiedError
                }
                let amount = min(Int64(requested), source.pointee.size - position)
                guard amount <= source.pointee.remainingProbeBytes else { return kAudioFileUnspecifiedError }
                var actual: Int
                repeat { actual = pread(source.pointee.fd, buffer, Int(amount), position) }
                while actual < 0 && errno == EINTR && !Task.isCancelled
                guard actual >= 0 else { return kAudioFileUnspecifiedError }
                source.pointee.remainingProbeBytes -= Int64(actual)
                count.pointee = UInt32(actual)
                return noErr
            }, nil, { context in context.assumingMemoryBound(to: AudioSource.self).pointee.size }, nil, 0, &file)
            guard status == noErr, let file else { throw TelegramUploadFileError.invalidAudio }
            defer { AudioFileClose(file) }
            var type: AudioFileTypeID = 0
            var propertySize = UInt32(MemoryLayout<AudioFileTypeID>.size)
            guard AudioFileGetProperty(file, kAudioFilePropertyFileFormat, &propertySize, &type) == noErr else {
                throw TelegramUploadFileError.invalidAudio
            }
            var names: Unmanaged<CFArray>?
            propertySize = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
            let mimeStatus = AudioFileGetGlobalInfo(kAudioFileGlobalInfo_MIMETypesForType,
                UInt32(MemoryLayout<AudioFileTypeID>.size), &type, &propertySize, &names)
            let values = names?.takeRetainedValue() as? [String]
            guard mimeStatus == noErr, let mime = values?.first, !mime.isEmpty else {
                throw TelegramUploadFileError.invalidAudio
            }
            return mime
        }
    }

    /// Validate native codec support with a bounded PCM read; preserve the original resource unchanged.
    private static func validateDecoding(_ asset: AVAsset, track: AVAssetTrack, range: CMTimeRange) throws {
        try Task.checkCancellation()
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TelegramUploadFileError.invalidAudio }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: range.start,
            duration: CMTime(seconds: min(1, range.duration.seconds), preferredTimescale: 44_100))
        // cancelReading must never race copyNextSampleBuffer; cancellation is checked between reads.
        defer { reader.cancelReading() }
        guard reader.startReading() else { throw TelegramUploadFileError.invalidAudio }
        for _ in 0..<64 {
            guard let sample = output.copyNextSampleBuffer() else { break }
            try Task.checkCancellation()
            if CMSampleBufferGetNumSamples(sample) > 0 {
                guard CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample),
                      reader.status != .failed else { throw TelegramUploadFileError.invalidAudio }
                return
            }
        }
        try Task.checkCancellation()
        throw TelegramUploadFileError.invalidAudio
    }

    private static func readTags(_ asset: AVAsset) async throws -> (title: String, performer: String) {
        var title = "", performer = ""
        for format in try await asset.load(.availableMetadataFormats) {
            for item in try await asset.loadMetadata(for: format) {
                try Task.checkCancellation()
                guard let identifier = item.identifier else { continue }
                let isLead = identifier == .id3MetadataLeadPerformer
                let isArtist = isLead || identifier == .iTunesMetadataArtist ||
                    identifier == .quickTimeUserDataArtist || identifier == .commonIdentifierArtist ||
                    identifier.rawValue.hasSuffix("aART") || identifier.rawValue.hasSuffix("wrt")
                let isTitle = identifier == .id3MetadataTitleDescription || identifier == .iTunesMetadataSongName ||
                    identifier == .quickTimeUserDataTrackName || identifier == .commonIdentifierTitle ||
                    identifier.rawValue.hasSuffix("nam")
                guard isArtist || isTitle else { continue }
                guard let value = try await item.load(.stringValue), value.utf8.count <= 4_096,
                      !value.utf8.contains(0) else { throw TelegramUploadFileError.invalidAudio }
                if isTitle { title = value }
                if isLead || (isArtist && performer.isEmpty) { performer = value }
            }
            if !title.isEmpty && !performer.isEmpty { break }
        }
        return (title, performer)
    }
}
