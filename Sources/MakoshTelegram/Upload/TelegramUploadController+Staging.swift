import Foundation
import MakoshCore
import UniformTypeIdentifiers

/// Preparing selected files into an upload bundle.
extension TelegramUploadController {
    static func stageSelections(
        _ selected: [TelegramUploadSelection], photoSize: TelegramUploadPhotoSize,
        stage: (URL, TelegramUploadMode) async throws -> TelegramUploadFile,
        staged: inout [TelegramUploadBatchItem], isCurrent: () -> Bool
    ) async throws {
        for source in selected {
            try Task.checkCancellation()
            if source.mode == .video {
                let file = try await stage(source.source, .video)
                staged.append(.init(id: file.id, file: file))
            } else {
                let original =
                    source.mode == .photo
                    ? try await TelegramUploadFileIO.stage(source.source, mode: .file)
                    : try await stage(source.source, .file)
                // Own the raw copy before classification or derivative generation can suspend.
                staged.append(.init(id: original.id, file: original))
                let type = UTType(filenameExtension: (original.name as NSString).pathExtension)
                let photoCandidate = source.mode == .photo || type?.conforms(to: .image) == true
                let oggCandidate = try TelegramUploadAudioIO.hasOggSignature(original)
                do {
                    let webP = try await TelegramUploadWebPIO.inspect(original)
                    let selectedMIME = TelegramUploadSourceFactsIO.selectionMIME(for: original.name)
                    var selectedWebPPhoto = false
                    if webP != nil, selectedMIME.hasPrefix("image/"),
                        selectedMIME != "image/webp", !selectedMIME.hasSuffix("gif")
                    {
                        selectedWebPPhoto = try await TelegramUploadPhotoEligibility.canPrepare(
                            original,
                            photoSize: photoSize, allowsSelectedWebPPhoto: true)
                    }
                    if let webP, !selectedWebPPhoto {
                        let file = TelegramUploadFile(
                            id: original.id, name: original.name, size: original.size,
                            mode: .file, pixelWidth: nil, pixelHeight: nil, url: original.url,
                            directory: original.directory, metadata: .webP(webP))
                        staged[staged.count - 1] = .init(id: original.id, file: file)
                    } else if let gif = try await TelegramUploadGIFIO.inspect(original) {
                        let capture = try await BackgroundWork.run { try TelegramPendingUploadFiles.captureFile(original) }
                        let digest = try await BackgroundWork.run { try capture.plaintextSHA256() }
                        let converted = try await TelegramUploadGIFIO.convert(original, expected: gif, expectedPlaintextSHA256: digest)
                        let file = TelegramUploadFile(
                            id: converted.id, name: converted.name, size: converted.size,
                            mode: .video, pixelWidth: converted.pixelWidth, pixelHeight: converted.pixelHeight,
                            url: converted.url, directory: converted.directory, video: converted.video,
                            metadata: .gif(
                                .init(
                                    width: gif.width, height: gif.height,
                                    frameDurations: gif.frameDurations, sourceSHA256: digest)))
                        staged[staged.count - 1] = .init(id: original.id, file: file, originalFile: original)
                    } else if photoCandidate && !oggCandidate,
                        try await TelegramUploadPhotoEligibility.canPrepare(
                            original,
                            photoSize: photoSize, allowsSelectedWebPPhoto: selectedWebPPhoto)
                    {
                        let jpeg = try await stage(original.url, .photo)
                        let name = telegramAttachmentName((original.name as NSString).deletingPathExtension + ".jpg")
                        let file = TelegramUploadFile(
                            id: jpeg.id, name: name, size: jpeg.size, mode: jpeg.mode,
                            pixelWidth: jpeg.pixelWidth, pixelHeight: jpeg.pixelHeight, url: jpeg.url,
                            directory: jpeg.directory, video: jpeg.video, videoCover: jpeg.videoCover)
                        staged[staged.count - 1] = .init(id: original.id, file: file, originalFile: original)
                    } else if !oggCandidate && type?.preferredMIMEType?.hasPrefix("video/") == true {
                        do {
                            let info = try await TelegramUploadVideoIO.inspect(original)
                            let metadata = TelegramUploadVideoMetadata(
                                width: info.width, height: info.height,
                                duration: info.duration, hasAudio: info.hasAudio, inCollage: true)
                            let file = TelegramUploadFile(
                                id: original.id, name: original.name, size: original.size,
                                mode: .video, pixelWidth: info.width, pixelHeight: info.height,
                                url: original.url, directory: original.directory, video: metadata)
                            staged[staged.count - 1] = .init(id: original.id, file: file)
                        } catch TelegramUploadFileError.invalidVideo {
                            // An ordinary file choice remains usable when its video suffix is misleading.
                        }
                    } else if oggCandidate || type?.conforms(to: .audio) == true || type?.preferredMIMEType?.hasPrefix("audio/") == true {
                        do {
                            let audio = try await TelegramUploadAudioIO.inspect(original)
                            let file = TelegramUploadFile(
                                id: original.id, name: original.name, size: original.size,
                                mode: .file, pixelWidth: nil, pixelHeight: nil, url: original.url,
                                directory: original.directory, metadata: .audio(audio))
                            staged[staged.count - 1] = .init(id: original.id, file: file)
                        } catch TelegramUploadFileError.invalidAudio {
                            // Unsupported or misleading containers retain their unchanged generic file.
                        }
                    }
                } catch TelegramUploadFileError.invalidWebP {
                    // Recognizable unsafe WebP remains an unchanged generic file, without suffix reinterpretation.
                } catch TelegramUploadGIFError.invalidGIF {
                    // Recognizable unsafe GIF retains the unchanged document, without suffix reinterpretation.
                }
            }
            let item = staged[staged.count - 1]
            let facts = try await TelegramUploadSourceFactsIO.inspect(
                itemID: item.id, raw: item.rawSource,
                role: item.originalFile == nil ? .prepared : .original, metadata: item.file.metadata)
            staged[staged.count - 1] = .init(id: item.id, file: item.file, originalFile: item.originalFile, sourceFacts: facts)
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
        }
    }

    public func prepare(
        sources: [TelegramUploadSelection], isGrouped: Bool, target: TelegramUploadTarget, captionInput: TelegramComposerInput,
        photoSize: TelegramUploadPhotoSize = .standard, captionPolicy: TelegramUploadCaptionPolicy? = nil
    ) {
        guard preparation == nil, phase == .idle || phase == .cancelled || phase == .failed || phase == .rejected,
            provider is any TelegramUploadBatchProvider, provider?.accountID == target.accountID, target.hasValidReplySource
        else { return }
        var seen: Set<URL> = []
        let selected = sources.filter { seen.insert($0.source.standardizedFileURL).inserted }
        guard !selected.isEmpty else { return }
        clear()
        resetCancellationPresentation()
        guard items.isEmpty, recoveredArchive == nil else {
            phase = .failed
            return
        }
        usesBatchRecovery = true
        captionRules =
            captionPolicy == nil
            ? .reference : TelegramUploadCaptionRules.containsCustomEmoji(captionInput.formattedText) ? .extended : .current
        mediaRules = .reference
        self.captionPolicy = captionPolicy
        self.target = target
        self.captionInput = captionInput
        phase = .preparing
        let request = token, bound = bindingID, discard = self.discard, store = recoveryStore
        let stage = self.stage ?? { source, mode in try await TelegramUploadFileIO.stage(source, mode: mode, photoSize: photoSize) }
        preparationID = request
        didPrepare?(target, captionInput, request)
        guard token == request, phase == .preparing else { return }
        let original = originalDraftForRecovery?(target, request)
        preparation = Task { [weak self] in
            var staged: [TelegramUploadBatchItem] = []
            do {
                try await Self.stageSelections(
                    selected, photoSize: photoSize, stage: stage, staged: &staged,
                    isCurrent: { [weak self] in self?.token == request })
                guard let self, self.token == request else { throw CancellationError() }
                var presentation = TelegramUploadSourceClassifier.initialPresentation(
                    for: staged.compactMap(\.sourceFacts),
                    asMedia: selected.allSatisfy { $0.mode != .file })
                if presentation == .media && !TelegramUploadBatchItem.allowsMedia(staged, rules: self.mediaRules) { presentation = .file }
                let grouped = isGrouped && presentation.allowsGrouping(staged)
                self.sourceURLsByItemID = Dictionary(
                    uniqueKeysWithValues: zip(staged, selected).map { ($0.0.id, $0.1.source.standardizedFileURL) })
                self.preparation = nil
                self.items = staged
                self.selectedItemID = staged[0].id
                self.presentation = presentation
                self.isGrouped = grouped
                self.itemsRevision = UUID()
                self.phase = .ready
                self.persistInitial(
                    file: staged[0].file, target: target, input: captionInput, original: original,
                    id: request, bound: bound, store: store, above: false, spoiler: false, batchItems: staged, grouped: grouped)
            } catch {
                var cleanupFailed = false
                for item in staged { do { try item.discard(using: discard) } catch { cleanupFailed = true } }
                guard let self else { return }
                self.preparation = nil
                guard self.token == request else {
                    if cleanupFailed, self.bindingID == bound { self.error = "Не удалось удалить временные файлы." }
                    return
                }
                self.phase = Task.isCancelled || error is CancellationError ? .cancelled : .failed
                if cleanupFailed {
                    self.error = "Не удалось удалить временные файлы."
                } else if self.phase == .failed {
                    self.error = "Не удалось подготовить набор вложений."
                }
                self.finishPreparation()
            }
        }
    }

    public func prepare(
        source: URL, mode: TelegramUploadMode, target: TelegramUploadTarget, caption: String,
        photoSize: TelegramUploadPhotoSize = .standard
    ) {
        guard let input = try? TelegramComposerInput(formattedText: TelegramFormattedText(text: caption)) else {
            error = "Не удалось подготовить подпись."
            return
        }
        prepare(source: source, mode: mode, target: target, captionInput: input, photoSize: photoSize)
    }

    public func prepare(
        source: URL, mode: TelegramUploadMode, target: TelegramUploadTarget, captionInput: TelegramComposerInput,
        photoSize: TelegramUploadPhotoSize = .standard
    ) {
        guard preparation == nil, phase == .idle || phase == .cancelled || phase == .failed || phase == .rejected,
            provider?.accountID == target.accountID, target.hasValidReplySource
        else { return }
        clear()
        resetCancellationPresentation()
        guard file == nil, recoveredArchive == nil else {
            phase = .failed
            return
        }
        self.target = target
        self.captionInput = captionInput
        phase = .preparing
        let request = token, discard = self.discard
        let stage = self.stage ?? { source, mode in try await TelegramUploadFileIO.stage(source, mode: mode, photoSize: photoSize) }
        let bound = bindingID, store = recoveryStore
        preparationID = request
        didPrepare?(target, captionInput, request)
        guard token == request, phase == .preparing else { return }
        let original = originalDraftForRecovery?(target, request)
        preparation = Task { [weak self] in
            do {
                let result = try await stage(source, mode)
                guard let self else {
                    try? discard(result)
                    return
                }
                guard self.token == request, !Task.isCancelled else {
                    do { try discard(result) } catch {
                        if self.bindingID == bound { self.error = "Не удалось удалить временный файл." }
                    }
                    self.preparation = nil
                    return
                }
                self.preparation = nil
                self.file = result
                self.phase = .ready
                if self.requiresRecovery || store != nil {
                    self.persistInitial(
                        file: result, target: target, input: captionInput, original: original,
                        id: request, bound: bound, store: store, above: false, spoiler: false)
                }
            } catch {
                guard let self else { return }
                self.preparation = nil
                guard self.token == request else { return }
                self.phase = Task.isCancelled ? .cancelled : .failed
                if !Task.isCancelled { self.error = "Не удалось подготовить вложение." }
                self.finishPreparation()
            }
        }
    }
}
