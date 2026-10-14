# SPDX-License-Identifier: GPL-3.0-or-later
"""Reviewed first-open and non-destructive failure boundary for account metadata."""
import hashlib

ACCOUNT_MANAGER = 'submodules/TelegramCore/Sources/AccountManager/AccountManagerImpl.swift'
SOURCE_SHA256 = '5809794736a0590c59995db643fce16a726bf3403136c97c11ebb2ae251585d3'
ADAPTED_SHA256 = 'd674adf437a3d3e3eb68f43b45a52da4b6db08c82055f78da29a57326b9a576a'
ENGINE_LOG = 'submodules/TelegramCore/Sources/Utils/Log.swift'
LOG_SOURCE_SHA256 = 'd583e6dcd89bf1244bdf26ed646ec8e197e6fc726cfe7643430960af32002121'
LOG_ADAPTED_SHA256 = 'f85506231df8209f32f9d87644462dae3357f49fd6aa7f100c68967edff043ed'


def adapt_account_startup_source(source):
    if hashlib.sha256(source.encode()).hexdigest() != SOURCE_SHA256:
        raise RuntimeError('Unexpected native account-manager startup source')
    begin = source.index('    fileprivate init?(queue:')
    end = source.index('    deinit {', begin)
    initializer = source[begin:end].replace('preconditionFailure()', 'return nil')
    initializer = initializer.replace('return nil\n            return nil', 'return nil')
    initializer = initializer.replace('''            if removeDatabaseOnError {
                var legacyRecordDict:''', '''            // First launch has no atomic state. Admit only an actually empty
            // metadata store with no native account cache beside it. Never
            // infer that a missing/corrupt existing session should be reset.
            let fileError = e as NSError
            let siblings = try? FileManager.default.contentsOfDirectory(atPath: (basePath as NSString).deletingLastPathComponent)
            let missingEmptyState = !isReadOnly && fileError.domain == NSCocoaErrorDomain && fileError.code == NSFileReadNoSuchFileError
                && self.legacyRecordTable.getRecords().isEmpty
                && self.legacyMetadataTable.getCurrentAccountId() == nil
                && self.legacyMetadataTable.getCurrentAuthAccount() == nil
                && siblings.map({ !$0.contains(where: { $0.hasPrefix("account-") }) }) == true
            if removeDatabaseOnError || missingEmptyState {
                var legacyRecordDict:''')
    initializer = initializer.replace('self.syncAtomicStateToFile()', 'guard self.syncAtomicStateToFile(failOnError: false) else { return nil }')
    source = source[:begin] + initializer + source[end:]
    begin = source.index('    private func syncAtomicStateToFile() {')
    end = source.index('    private func getLoginTokens()', begin)
    source = source[:begin] + '''    @discardableResult
    private func syncAtomicStateToFile(failOnError: Bool = true) -> Bool {
        do {
            let data = try JSONEncoder().encode(self.currentAtomicState)
            try data.write(to: URL(fileURLWithPath: self.atomicStatePath), options: [.atomic])
            return true
        } catch {
            postboxLogSync()
            if failOnError { preconditionFailure() }
            return false
        }
    }

''' + source[end:]
    anchor = 'public final class AccountManager<Types: AccountManagerTypes> {\n'
    factory = '''    /// Makosh's non-destructive opener. All native database work and owned
    /// object lifetimes stay on the original shared account-manager queue.
    /// No account, network, authorization token or session key is opened here.
    public static func makoshOpen(basePath: String) -> Signal<AccountManager<Types>?, NoError> {
        return Signal { subscriber in
            sharedQueue.async {
                // Native SQLite's unwritable-folder probe traps. Reject path
                // obstructions before entering it; never replace an existing
                // file with a directory or remove a database to make it open.
                do {
                    for path in [basePath, basePath + "/guard_db", basePath + "/db"] {
                        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
                    }
                } catch {
                    subscriber.putNext(nil)
                    subscriber.putCompletion()
                    return
                }
                var sessionId: Int64 = 0
                arc4random_buf(&sessionId, 8)
                if let value = AccountManagerImpl<Types>(queue: sharedQueue, basePath: basePath,
                    isTemporary: false, isReadOnly: false, useCaches: true,
                    removeDatabaseOnError: false, temporarySessionId: sessionId) {
                    subscriber.putNext(AccountManager(basePath: basePath, temporarySessionId: sessionId, value: value))
                } else {
                    subscriber.putNext(nil)
                }
                subscriber.putCompletion()
            }
            return EmptyDisposable
        }
    }

    private init(basePath: String, temporarySessionId: Int64, value: AccountManagerImpl<Types>) {
        self.queue = sharedQueue
        self.basePath = basePath
        self.temporarySessionId = temporarySessionId
        self.impl = QueueLocalObject(queue: sharedQueue, generate: { value })
        self.mediaBox = MediaBox(basePath: basePath + "/media", isMainProcess: false)
    }

'''
    assert source.count(anchor) == 1
    return source.replace(anchor, anchor + factory)


def adapt_disabled_short_log_source(source):
    if hashlib.sha256(source.encode()).hexdigest() != LOG_SOURCE_SHA256:
        raise RuntimeError('Unexpected native short-log source')
    anchor = '    public func shortLog(_ tag: String, _ what: @autoclosure () -> String) {\n'
    assert source.count(anchor) == 1
    return source.replace(anchor, anchor + '        guard self.logToFile else { return }\n')
