#if DEBUG
import Foundation
import MakoshCore
import Postbox
import TelegramCore
import SwiftSignalKit

private func syntheticComposerPostbox(directory: URL) -> Signal<Postbox?, NoError> {
    // Public synthetic constants, deliberately unrelated to any real session key.
    let encryption = ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true,
        key: ValueBoxEncryptionParameters.Key(data: Data(repeating: 69, count: 32))!,
        salt: ValueBoxEncryptionParameters.Salt(data: Data(repeating: 70, count: 16))!)
    return openPostbox(basePath: directory.path, seedConfiguration: telegramPostboxSeedConfiguration,
        encryptionParameters: encryption, timestampForAbsoluteTimeBasedOperations: 1,
        isMainProcess: true, isTemporary: false, isReadOnly: false, useCopy: false,
        useCaches: false, removeDatabaseOnError: false)
        |> filter { result in
            switch result { case .postbox, .error: true; case .upgrading: false }
        }
        |> take(1)
        |> map { result in if case let .postbox(box) = result { return box }; return nil }
}

extension TelegramModel {
    /// Explicit DEBUG fixture only. Ordinary syntheticPreview remains memory-only.
    /// The caller must create a private, distinctly named synthetic directory.
    public static func syntheticDraftPreview(directory: URL) async throws -> TelegramModel {
        let path = directory.standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard directory.isFileURL, path == directory.resolvingSymlinksInPath(),
              path.lastPathComponent.hasPrefix("qa_telegram_drafts_"),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
            throw CocoaError(.fileReadNoPermission)
        }
        initializeAccountManagement()
        let model = syntheticPreview()
        let _: Void = try await withCheckedThrowingContinuation { continuation in
            let _ = (syntheticComposerPostbox(directory: path) |> deliverOnMainQueue).startStandalone(next: { box in
                MainActor.assumeIsolated {
                    guard let box else { continuation.resume(throwing: CocoaError(.fileReadCorruptFile)); return }
                    model.syntheticPendingPostbox = box
                    model.composerForward.bind(TelegramSyntheticForwardProvider(postbox: box,
                        loseAcknowledgement: ProcessInfo.processInfo.arguments.contains("--telegram-forward-ack-loss-qa")))
                    model.bindComposerDraftRepository(TelegramPostboxComposerDraftRepository(postbox: box, accountID: -1))
                    continuation.resume()
                }
            })
        }
        return model
    }
    public func configurePendingUploadRecoveryQA(connectionString: String, schema: String, configurationFile: URL, spoolDirectory: URL) throws {
        guard ProcessInfo.processInfo.arguments.contains("--telegram-pending-upload-qa"), isSyntheticPreview, schema.hasPrefix("qa_telegram_dossier_"),
              let postbox = syntheticPendingPostbox else { throw MessageArchiveError.invalid }
        try archive.files.configureSynthetic(connectionString: connectionString, schema: schema, configurationFile: configurationFile, spoolDirectory: spoolDirectory)
        let store = TelegramPendingUploadSession(repository: TelegramPostboxPendingUploadRepository(postbox: postbox, accountID: -1), files: { [weak self] in
            guard let self else { throw TelegramUploadFileError.unavailable }
            return try self.archive.files.pendingUploadFiles()
        })
        upload.bind(provider: TelegramSyntheticUploadProvider(postbox: postbox,
            loseAcknowledgement: ProcessInfo.processInfo.arguments.contains("--telegram-pending-upload-ack-loss-qa")),
            recoveryStore: store, requiresRecovery: true)
        bindPendingUploadRecovery(store, replyProvider: TelegramSyntheticComposerReplyProvider())
    }
}
#endif
