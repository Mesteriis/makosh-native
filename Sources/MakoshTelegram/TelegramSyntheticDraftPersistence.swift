#if DEBUG
import Foundation
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
        let repository: TelegramPostboxComposerDraftRepository = try await withCheckedThrowingContinuation { continuation in
            let _ = (syntheticComposerPostbox(directory: path) |> deliverOnMainQueue).startStandalone(next: { box in
                MainActor.assumeIsolated {
                    if let box { continuation.resume(returning: TelegramPostboxComposerDraftRepository(postbox: box, accountID: -1)) }
                    else { continuation.resume(throwing: CocoaError(.fileReadCorruptFile)) }
                }
            })
        }
        let model = syntheticPreview()
        model.bindComposerDraftRepository(repository)
        return model
    }
}
#endif
