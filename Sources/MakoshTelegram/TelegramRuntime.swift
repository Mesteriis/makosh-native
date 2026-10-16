import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit
import OpenSSLEncryption

enum TelegramRuntime {
    nonisolated static func accountAuxiliaryMethods() -> AccountAuxiliaryMethods {
        AccountAuxiliaryMethods(fetchResource: { _, _, _, _ in nil },
            fetchResourceMediaReferenceHash: { _ in .single(nil) },
            prepareSecretThumbnailData: { _ in nil }, backgroundUpload: { _, _, _ in .single(nil) })
    }

    nonisolated static func networkArguments(configuration: TelegramAPIConfiguration,
        proxySettings: Signal<ProxySettings, NoError>) -> NetworkInitializationArguments {
        NetworkInitializationArguments(apiId: configuration.id, apiHash: configuration.hash,
            languagesCategory: "macos", appVersion: "Makosh 0.2", voipMaxLayer: 92, voipVersions: [
                .init(version: "2.7.7", supportsVideo: true), .init(version: "5.0.0", supportsVideo: true)],
            appData: .single(nil), externalRequestVerificationStream: .single([:]),
            externalRecaptchaRequestVerification: { _, _ in .complete() }, autolockDeadine: .single(nil),
            encryptionProvider: OpenSSLEncryptionProvider(), deviceModelName: "Mac", useBetaFeatures: false,
            isICloudEnabled: false, makoshProxySettings: proxySettings)
    }

    nonisolated static func forcedPasswordSetupNotice(_ days: Int32) -> (NoticeEntryKey, CodableEntry)? { nil }

    /// TelegramCore requires a shared logger even in a debug build. Register it
    /// before opening accounts, with all output disabled before any engine work.
    static func configureLogging(directory: URL) {
        let logger = Logger(rootPath: directory.path, basePath: directory.appendingPathComponent("disabled-logs").path)
        logger.logToFile = false
        logger.logToConsole = false
        logger.redactSensitiveData = true
        Logger.setSharedLogger(logger)
        registerLoggingFunctions()
    }
}
