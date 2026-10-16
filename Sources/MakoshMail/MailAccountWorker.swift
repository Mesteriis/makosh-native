import Foundation
import MakoshCore
import CryptoKit

/// One account owns its connection and serialized operations. Actor reentrancy never
/// interleaves SELECT/FETCH or SELECT/STORE pairs; busy admission precedes suspension.
public actor MailAccountWorker {
    public let account: MailAccount
    private let repository: MailRepository
    private let configuration: ContactWorkspaceConfiguration
    private let credentials: MailCredentialAccess
    private let keyProvider: @Sendable (UUID, Bool) throws -> Data
    private let tlsCAFile: String?
    private var session: IMAPService?
    private var smtpSession: SMTPService?
    private var monitors: [UUID: IMAPService] = [:]
    private var backloggedFolders = Set<String>()
    private var busy=false
    private var disconnectRequested=false
    private var archive: MessageArchiveStore?
    private var files: ArchiveFileRepository?
    private let storageFile: URL?
    private let spool: URL
    private var currentAttachments: (MailMessageKey,[MIME.Attachment])?
    public init(account: MailAccount,repository: MailRepository,configuration: ContactWorkspaceConfiguration,storageFile: URL?,spool: URL, credentials: MailCredentialAccess = .keychain,
                keyProvider: @escaping @Sendable (UUID, Bool) throws -> Data = MessageArchiveKeychain.open, tlsCAFile: String? = nil) {
        self.account=account;self.repository=repository;self.configuration=configuration;self.storageFile=storageFile;self.spool=spool;self.credentials=credentials;self.keyProvider=keyProvider;self.tlsCAFile=tlsCAFile
    }
    public var isConnected: Bool { session != nil && !disconnectRequested }
    private func begin() throws { guard !busy else { throw MailFailure.busy };busy=true }
    private func finish() { busy=false }
    public func connect(imapPassword: String?=nil,smtpPassword: String?=nil) async throws -> [MailFolder] {
        try begin();defer { finish() }
        try Task.checkCancellation()
        try account.validate()
        try await repository.validateAccountSource(account)
        if let imapPassword { try credentials.saveValue(imapPassword,account.id,"imap") }
        if let smtpPassword { try credentials.saveValue(smtpPassword,account.id,"smtp") }
        disconnectRequested=false
        if let session { await session.disconnect() };session=nil
        let service=IMAPService(config:account.transport,password:try credentials.readValue(account.id,"imap"),tlsCAFile:tlsCAFile)
        do {
            try await service.connectAndLogin()
            let folders=try await service.listMailboxes().filter(\.selectable).map { MailFolder(accountID:account.id,path:$0.name,kind:MailFolderKind(rawValue:$0.kind.rawValue) ?? .other,displayName:$0.displayName) }
            guard !disconnectRequested, !Task.isCancelled else { throw CancellationError() }
            try await repository.saveAccount(account);try await repository.saveFolders(folders,accountID:account.id)
            session=service;return folders
        } catch { await service.disconnect();throw safe(error) }
    }
    public func updates(folder: MailFolder, interval: Duration = .seconds(60)) -> AsyncStream<MailRefreshEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { [weak self] in await self?.poll(folder: folder, interval: interval, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private func poll(folder: MailFolder, interval: Duration, continuation: AsyncStream<MailRefreshEvent>.Continuation) async {
        let monitorID = UUID()
        defer { monitors.removeValue(forKey: monitorID); continuation.finish() }
        var monitor: IMAPService?
        var pollingOnly = false, pendingRefresh = false
        while !Task.isCancelled && !disconnectRequested {
            if backloggedFolders.contains(folder.id) { pendingRefresh = true }
            if !pendingRefresh {
                do {
                    if monitor == nil && !pollingOnly {
                        let candidate = IMAPService(config: account.transport, password: try credentials.readValue(account.id, "imap"), tlsCAFile: tlsCAFile)
                        monitor = candidate
                        monitors[monitorID] = candidate
                        try await candidate.connectAndLogin()
                    }
                    if let activeMonitor = monitor {
                        if try await activeMonitor.waitForChanges(mailbox: folder.path) == nil {
                            await activeMonitor.disconnect(); monitor = nil
                            pollingOnly = true
                            try await Task.sleep(for: interval)
                        }
                    } else { try await Task.sleep(for: interval) }
                    pendingRefresh = true
                } catch {
                    await monitor?.disconnect(); monitor = nil
                    if Task.isCancelled || disconnectRequested { break }
                    // A watcher failure does not revoke a healthy command connection.
                    do { try await Task.sleep(for: interval) } catch { break }
                    pendingRefresh = true
                }
            }
            guard !Task.isCancelled, !disconnectRequested else { break }
            if busy { do { try await Task.sleep(for: .milliseconds(200)) } catch { break }; continue }
            do {
                if session == nil { _ = try await connect() }
                _ = try await page(folder: folder)
                pendingRefresh = false
                if !Task.isCancelled { continuation.yield(.updated(folderID: folder.id)) }
            } catch {
                guard !Task.isCancelled else { break }
                if error as? MailFailure == .busy { continue }
                pendingRefresh = false
                continuation.yield(.offline(folderID: folder.id))
                if safe(error) as? MailFailure != .offline { break }
            }
        }
        await monitor?.disconnect()
    }
    public func disconnect() async {
        disconnectRequested=true
        smtpSession?.cancel(); smtpSession = nil
        let watching = Array(monitors.values); monitors.removeAll()
        let old=session;session=nil;currentAttachments=nil
        await old?.disconnect()
        for service in watching { await service.disconnect() }
    }
    public func runAutomation(now: Date = Date()) async throws {
        guard !busy, session != nil, !disconnectRequested else { return }
        let snapshot = try await repository.snapshot()
        for operation in snapshot.automation?.ruleOperations.filter({ $0.key.accountID == account.id && $0.state == .pending }).prefix(20) ?? [] {
            try Task.checkCancellation()
            guard !busy, !disconnectRequested, let letter = try await repository.letter(operation.key.id), letter.removedFromSource != true,
                  let destination = snapshot.folders.first(where: { $0.accountID == account.id && $0.kind == operation.destination }) else { continue }
            // Loading the complete body can fail safely before non-idempotent admission.
            let retained: MailLetter
            do { retained = letter.text == nil ? try await body(letter) : letter }
            catch {
                if Task.isCancelled || disconnectRequested { throw CancellationError() }
                if error as? MailFailure == .busy { continue }
                try await repository.failRulePreparation(operation.id, failure: safe(error) as? MailFailure ?? .storage)
                continue
            }
            guard !Task.isCancelled, !disconnectRequested, let claimed = try await repository.claimRuleOperation(operation.id) else { continue }
            do { try await move(retained, to: destination); try await repository.finishRuleOperation(claimed.id, state: .completed) }
            catch {
                try await repository.finishRuleOperation(claimed.id, state: error as? MailFailure == .busy ? .pending : .unknown)
                throw error
            }
        }
        guard !busy, !disconnectRequested else { return }
        try Task.checkCancellation()
        guard let item = try await repository.claimScheduled(accountID: account.id, now: now) else { return }
        do { _ = try await send(item.draft, attachmentFiles: []); try await repository.finishSchedule(item.id, state: .completed) }
        catch {
            try await repository.finishSchedule(item.id, state: error as? MailFailure == .busy ? .pending : .unknown)
            throw error
        }
    }
    public func automationUpdates(interval: Duration = .seconds(15)) -> AsyncStream<Result<Void, MailFailure>> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { [weak self] in await self?.automationLoop(interval: interval, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private func automationLoop(interval: Duration, continuation: AsyncStream<Result<Void, MailFailure>>.Continuation) async {
        defer { continuation.finish() }
        while !Task.isCancelled && !disconnectRequested {
            do { try await runAutomation(); continuation.yield(.success(())) }
            catch {
                if Task.isCancelled { break }
                if error as? MailFailure != .busy { continuation.yield(.failure(safe(error) as? MailFailure ?? .storage)) }
            }
            do { try await Task.sleep(for: interval) } catch { break }
        }
    }
    public func page(folder: MailFolder,beforeUID: UInt32?=nil,query: String="") async throws -> [MailLetter] {
        try begin();defer { finish() }
        let service=try connected(folder)
        do {
            _ = try await service.select(folder.path)
            let validity = service.selectedUIDValidity
            guard !disconnectRequested, validity > 0 else { throw MailFailure.staleFolder }
            let snapshot = try await repository.snapshot()
            let checkpoint = snapshot.notifications?.checkpoints[folder.id]
            if beforeUID == nil, query.isEmpty, folder.kind == .inbox, let checkpoint, checkpoint.uidValidity == validity {
                var cursor = checkpoint.maximumUID, result: [MailLetter] = []
                backloggedFolders.remove(folder.id)
                for page in 0..<20 {
                    try Task.checkCancellation()
                    guard !disconnectRequested else { throw CancellationError() }
                    let next = try await service.fetchNewAfter(mailbox: folder.path, afterUID: cursor, limit: 50)
                    result += try await persistPage(next.messages, service: service, folder: folder, validity: validity, notify: true, through: next.through)
                    cursor = next.through
                    if !next.hasMore {
                        // Update visible flags after the arrival cursor is fully drained.
                        if result.isEmpty {
                            return try await persistPage(service.fetchRecent(mailbox: folder.path, limit: 50), service: service, folder: folder, validity: validity, notify: true)
                        }
                        return result
                    }
                    if page == 19 { backloggedFolders.insert(folder.id) }
                }
                return result
            }
            let rows: [IMAPMessage]
            if !query.isEmpty { rows = try await service.searchText(mailbox: folder.path, query: query, limit: 100) }
            else if let beforeUID { rows = try await service.fetchOlder(mailbox: folder.path, beforeUID: beforeUID, limit: 50) }
            else { rows = try await service.fetchRecent(mailbox: folder.path, limit: 50) }
            return try await persistPage(rows, service: service, folder: folder, validity: validity, notify: beforeUID == nil && query.isEmpty)
        } catch { await service.disconnect();session=nil;throw safe(error) }
    }
    private func persistPage(_ rows: [IMAPMessage], service: IMAPService, folder: MailFolder, validity: UInt32, notify: Bool, through: UInt32? = nil) async throws -> [MailLetter] {
        guard !disconnectRequested else { throw CancellationError() }
        let letters = rows.map { row in
            var letter = MailLetter(key: .init(accountID: account.id, folder: folder.path, uidValidity: validity, uid: row.uid), subject: row.subject,
                senderName: row.fromName, sender: row.fromEmail, recipient: row.toEmail, date: row.date, seen: row.seen, flagged: row.flagged, messageID: row.messageID)
            letter.cc = row.ccEmail; letter.bcc = row.bccEmail; return letter
        }
        let known = Array(try await repository.snapshot().letters.filter {
            $0.key.accountID == account.id && $0.key.folder == folder.path && $0.key.uidValidity == validity && $0.removedFromSource != true
        }.prefix(1000))
        let present = try await service.existingUIDs(mailbox: folder.path, uids: known.map(\.key.uid))
        let removed = known.filter { !present.contains($0.key.uid) }.map { letter in var value = letter; value.removedFromSource = true; return value }
        if !removed.isEmpty { _ = try archiveStore().append(removed.map { .init(identity: $0.key.archiveIdentity, source: .update, event: .removedFromSource) }) }
        try retain(letters, source: .history)
        try await repository.savePage(removed + letters, folder: folder, uidValidity: validity, notifyIncoming: notify, synchronizedThroughUID: through)
        return letters
    }
    public func body(_ letter: MailLetter) async throws -> MailLetter {
        try begin();defer { finish() }
        let service=try await selected(letter.key)
        do {
            let raw=try await service.fetchMessageData(mailbox:letter.key.folder,uid:letter.key.uid,byteLimit:nil)
            guard !raw.isEmpty else { throw MailFailure.staleFolder }
            guard raw.count<=32*1024*1024 else { throw MailFailure.tooLarge }
            guard !disconnectRequested,!Task.isCancelled else { throw CancellationError() }
            let parsed=MIME.parse(raw)
            var result=letter;result.text=parsed.text;result.html=parsed.html
            result.attachments=parsed.attachments.enumerated().map { .init(id:String($0.offset),filename:$0.element.filename,mimeType:$0.element.mimeType,byteCount:$0.element.data.count) }
            currentAttachments=(letter.key,parsed.attachments)
            try await repository.saveLetters([result])
            try retain([result],source:.history)
            if let files=try fileRepository() {
                if try await files.conversationFileSavingEnabled(identity:letter.key.archiveIdentity,defaultEnabled:true) {
                    try await capture(raw,identity:letter.key.archiveIdentity,attachment:.init(id:"rfc822-source",kind:"document",name:"message.eml",size:Int64(raw.count)),files:files)
                    for (i,value) in parsed.attachments.enumerated() {
                        try await capture(value.data,identity:letter.key.archiveIdentity,attachment:.init(id:String(i),kind:"document",name:String(value.filename.prefix(512)),size:Int64(value.data.count)),files:files)
                    }
                }
            }
            try await repository.saveLetters([result]);return result
        } catch { await service.disconnect(); session = nil; throw safe(error) }
    }
    public func flag(_ letter: MailLetter,seen: Bool?=nil,starred: Bool?=nil) async throws -> MailLetter {
        try begin();defer { finish() };let service=try await selected(letter.key)
        var updated=letter
        do {
            if let seen { try await service.store(mailbox:letter.key.folder,uid:letter.key.uid,.seen,add:seen);updated.seen=seen }
            if let starred { try await service.store(mailbox:letter.key.folder,uid:letter.key.uid,.flagged,add:starred);updated.flagged=starred }
            try await repository.saveLetters([updated]);return updated
        } catch { throw safe(error) }
    }
    public func move(_ letter: MailLetter,to folder: MailFolder) async throws {
        try begin();defer { finish() }
        guard folder.accountID==account.id else { throw MailFailure.invalidInput }
        let service=try await selected(letter.key)
        // Preserve received content first, then issue exactly one non-idempotent MOVE.
        let retained = try await repository.letter(letter.id) ?? letter
        try retain([retained],source:.update)
        do {
            try Task.checkCancellation()
            guard !disconnectRequested else { throw CancellationError() }
            guard letter.text != nil else { throw MailFailure.invalidInput }
            try await service.move(uid:letter.key.uid,from:letter.key.folder,to:folder.path)
            var removed = letter; removed.removedFromSource = true
            try await repository.saveLetters([removed])
        }
        catch { throw safe(error) }
    }
    public func fileSaving(folder: MailFolder) async throws -> Bool {
        guard folder.accountID==account.id,let files=try fileRepository() else { throw MailFailure.storage }
        return try await files.conversationFileSavingEnabled(identity:policyIdentity(folder),defaultEnabled:true)
    }
    public func setFileSaving(folder: MailFolder,enabled: Bool) async throws {
        guard folder.accountID==account.id,let files=try fileRepository() else { throw MailFailure.storage }
        try await files.setConversationFileSavingEnabled(identity:policyIdentity(folder),enabled:enabled)
    }
    public func exportAttachment(_ attachment: MailAttachment,letter: MailLetter,to destination: URL) async throws {
        try begin();defer { finish() }
        guard letter.key.accountID==account.id else { throw MailFailure.invalidInput }
        if let files=try fileRepository(),let record=try await files.files(identity:letter.key.archiveIdentity,attachmentID:attachment.id).last(where: { $0.state == .stored }) {
            try await files.export(record,to:destination);return
        }
        if currentAttachments?.0 != letter.key {
            try Task.checkCancellation()
            let service = try await selected(letter.key)
            let raw = try await service.fetchMessageData(mailbox: letter.key.folder, uid: letter.key.uid, byteLimit: nil)
            guard !raw.isEmpty else { throw MailFailure.staleFolder }
            guard raw.count <= 32*1024*1024 else { throw MailFailure.tooLarge }
            currentAttachments = (letter.key, MIME.parse(raw).attachments)
        }
        guard let cached=currentAttachments,cached.0==letter.key,let index=Int(attachment.id),cached.1.indices.contains(index) else { throw MailFailure.staleFolder }
        guard !FileManager.default.fileExists(atPath:destination.path) else { throw MailFailure.invalidInput }
        try cached.1[index].data.write(to:destination,options:.withoutOverwriting)
    }
    public func prepareDraft(_ draft: MailDraft, attachmentFiles: [URL]) async throws -> MailDraft {
        try begin(); defer { finish() }
        return try await prepare(draft, attachmentFiles: attachmentFiles)
    }
    private func prepare(_ draft: MailDraft, attachmentFiles: [URL]) async throws -> MailDraft {
        try Task.checkCancellation()
        guard draft.accountID == account.id else { throw MailFailure.invalidInput }
        var prepared = draft
        let identity = MessageArchiveIdentity(service: "mail", accountID: account.id,
            conversationID: Data(draft.sourceFolder.utf8).base64EncodedString(), messageID: "draft:" + draft.id.uuidString)
        guard draft.files.allSatisfy({ $0.record.identity == identity }) else { throw MailFailure.invalidInput }
        if !attachmentFiles.isEmpty {
            guard let files = try fileRepository() else { throw MailFailure.storage }
            var total = draft.files.reduce(Int64(0)) { $0 + $1.record.plaintextByteCount }
            for url in attachmentFiles {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, let count = values.fileSize else { throw MailFailure.invalidInput }
                total += Int64(count); guard total <= 24 * 1024 * 1024 else { throw MailFailure.tooLarge }
                let attachment = MessageArchiveAttachment(id: UUID().uuidString, kind: "document", name: String(url.lastPathComponent.prefix(200)), size: Int64(count))
                let record = try await files.capture(ArchiveFileCapture(file: url, byteCount: Int64(count)), identity: identity, attachment: attachment, defaultEnabled: true)
                prepared.files.append(.init(record: record))
            }
        }
        try await repository.saveDraft(prepared)
        return prepared
    }
    /// Saving locally is always durable first. The server APPEND is admitted once,
    /// before suspension, and an uncertain result survives restart without replay.
    public func saveDraft(_ draft: MailDraft, attachmentFiles: [URL]) async throws -> MailDraft {
        try Task.checkCancellation()
        try begin(); defer { finish() }
        try draft.validateForSaving()
        let prepared = try await prepare(draft, attachmentFiles: attachmentFiles)
        guard let session, !disconnectRequested,
              let folder = try await repository.snapshot().folders.first(where: { $0.accountID == account.id && $0.kind == .drafts }) else { return prepared }
        var fingerprint = prepared; fingerprint.remoteSave = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let digest = SHA256.hash(data: try encoder.encode(fingerprint)).map { String(format: "%02x", $0) }.joined()
        let raw = try await render(prepared, includeBcc: true)
        try Task.checkCancellation()
        if let attempt = try await repository.admitDraftAppend(draft.id, digest: digest) {
            do { try Task.checkCancellation() }
            catch { try await repository.updateDraftRemoteSave(draft.id, expected: attempt, state: .notDispatched); throw error }
            do {
                try await session.append(mailbox: folder.path, rawMessage: raw, seen: true, draft: true)
                try await repository.updateDraftRemoteSave(draft.id, expected: attempt, state: .saved)
            } catch {
                try? await repository.updateDraftRemoteSave(draft.id, expected: attempt, state: .unknown)
                throw MailFailure.unknownDraftSave
            }
        }
        return try await repository.snapshot().drafts.first { $0.id == draft.id } ?? prepared
    }
    public func editRemoteDraft(_ letter: MailLetter) async throws -> MailDraft {
        try begin(); defer { finish() }
        guard letter.key.accountID == account.id,
              let folder = try await repository.snapshot().folders.first(where: { $0.accountID == account.id && $0.path == letter.key.folder }), folder.kind == .drafts,
              let full = try await repository.letter(letter.id), let text = full.text else { throw MailFailure.offline }
        let hex = String(letter.id.prefix(32)); let parts = [8,4,4,4,12]
        var index = hex.startIndex
        let uuidText = parts.map { count -> String in let end = hex.index(index, offsetBy: count); defer { index = end }; return String(hex[index..<end]) }.joined(separator: "-")
        guard let id = UUID(uuidString: uuidText) else { throw MailFailure.invalidInput }
        if let existing = try await repository.snapshot().drafts.first(where: { $0.id == id }) { return existing }
        let draft = MailDraft(id: id, accountID: account.id, to: full.recipient, cc: full.cc ?? "", bcc: full.bcc ?? "", subject: full.subject, body: text, sourceFolder: full.key.folder, bodyHTML: full.html)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-mail-draft-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var urls: [URL] = []
        for attachment in full.attachments {
            try Task.checkCancellation()
            let directory = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let leaf = URL(fileURLWithPath: attachment.filename).lastPathComponent
            let url = directory.appendingPathComponent(leaf.isEmpty || leaf == "." || leaf == ".." ? "attachment.bin" : leaf)
            if let cached = currentAttachments, cached.0 == full.key, let i = Int(attachment.id), cached.1.indices.contains(i) {
                try cached.1[i].data.write(to: url, options: .withoutOverwriting)
            } else if let files = try fileRepository(), let record = try await files.files(identity: full.key.archiveIdentity, attachmentID: attachment.id).last(where: { $0.state == .stored }) {
                try await files.export(record, to: url)
            } else {
                // Durable bytes take priority even with a stale or offline connection.
                // Fetch only missing content; S3 OFF never creates an incoming copy.
                let service = try await selected(full.key)
                let raw = try await service.fetchMessageData(mailbox: full.key.folder, uid: full.key.uid, byteLimit: nil)
                guard !raw.isEmpty else { throw MailFailure.staleFolder }
                guard raw.count <= 32*1024*1024 else { throw MailFailure.tooLarge }
                let parts = MIME.parse(raw).attachments
                guard let i = Int(attachment.id), parts.indices.contains(i) else { throw MailFailure.staleFolder }
                currentAttachments = (full.key, parts)
                try parts[i].data.write(to: url, options: .withoutOverwriting)
            }
            urls.append(url)
        }
        return try await prepare(draft, attachmentFiles: urls)
    }
    private func render(_ prepared: MailDraft, includeBcc: Bool) async throws -> String {
        var attachments: [ComposeAttachment] = []
        if !prepared.files.isEmpty {
            guard let files = try fileRepository() else { throw MailFailure.storage }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-mail-send-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            for file in prepared.files {
                let url = root.appendingPathComponent(UUID().uuidString)
                try await files.export(file.record, to: url)
                let data = try Data(contentsOf: url)
                let filename = String(file.filename.filter { !$0.isNewline && $0 != "\"" && $0 != "\\" && $0 != "\0" }.prefix(200))
                attachments.append(.init(filename: filename, mimeType: "application/octet-stream", data: data))
            }
        }
        var raw=MIME.buildMessage(from:account.email,fromName:account.displayName,to:prepared.to,cc:prepared.cc,subject:prepared.subject,body:prepared.body,attachments:attachments,bodyHTML:prepared.bodyHTML)
        if let reply=prepared.replyMessageID,!reply.isEmpty {
            guard reply.utf8.count<=998,!reply.contains(where: { $0.isNewline || $0 == "\0" }) else { throw MailFailure.invalidInput }
            raw="In-Reply-To: \(reply)\r\nReferences: \(reply)\r\n"+raw
        }
        if includeBcc && !prepared.bcc.isEmpty { raw = "Bcc: \(prepared.bcc)\r\n" + raw }
        guard raw.utf8.count <= 32*1024*1024 else { throw MailFailure.tooLarge }
        return raw
    }
    public func send(_ draft: MailDraft,attachmentFiles: [URL]) async throws -> MailSubmission {
        try begin();defer { finish() }
        guard draft.accountID==account.id,!disconnectRequested else { throw MailFailure.offline }
        try draft.validate()
        let prepared = try await prepare(draft, attachmentFiles: attachmentFiles)
        let raw = try await render(prepared, includeBcc: false)
        let password=try credentials.readValue(account.id,"smtp")
        var submission=MailSubmission(draftID:draft.id,accountID:account.id,state:.submitting)
        let identity = MessageArchiveIdentity(service: "mail", accountID: account.id, conversationID: Data(draft.sourceFolder.utf8).base64EncodedString(), messageID: "draft:" + draft.id.uuidString)
        _ = try archiveStore().append([.init(identity: identity, source: .outgoing, event: .message(.init(date: submission.date, text: "Тема: \(draft.subject)\nКому: \(draft.to)\n\n" + String(draft.body.prefix(128000)), author: account.displayName, authorID: account.email, isOutgoing: true, attachments: prepared.files.map { $0.record.attachment })))])
        if let files = try fileRepository() {
            let root = spool.appendingPathComponent("MailCapture", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = root.appendingPathComponent(UUID().uuidString)
            let bytes = Data(raw.utf8)
            try bytes.write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            defer { try? FileManager.default.removeItem(at: url) }
            submission.rawMessage = try await files.capture(ArchiveFileCapture(file: url, byteCount: Int64(bytes.count)), identity: identity, attachment: .init(id: "rfc822-source", kind: "document", name: "message.eml", size: Int64(bytes.count)), defaultEnabled: true)
        }
        try await repository.admit(submission)
        defer { let id = submission.id; Task { await repository.endSubmissionAttempt(id) } }
        let recipients=try MailAddress.recipients(draft.to)+(draft.cc.isEmpty ? [] : MailAddress.recipients(draft.cc))+(draft.bcc.isEmpty ? [] : MailAddress.recipients(draft.bcc))
        do {
            try Task.checkCancellation()
            guard !disconnectRequested else { throw CancellationError() }
            let smtp = SMTPService(config:account.transport,password:password,tlsCAFile:tlsCAFile)
            smtpSession = smtp
            defer { smtpSession = nil }
            try await smtp.send(from:account.email,fromName:account.displayName,recipients:recipients,message:raw)
            submission.state = .accepted
        } catch {
            submission.state = error as? MailFailure == .unknownSubmission ? .unknown : .rejected
            try await repository.updateSubmission(submission)
            throw submission.state == .unknown ? MailFailure.unknownSubmission : MailFailure.serverRejected
        }
        // A failed durable update leaves the existing .submitting admission blocked.
        try await repository.updateSubmission(submission)
        let snapshot=try await repository.snapshot()
        if let sent=snapshot.folders.first(where: { $0.accountID==account.id && $0.kind == .sent }),let session {
            do { try await session.append(mailbox:sent.path,rawMessage:raw,seen:true,draft:false);submission.sentCopySaved=true }
            catch { /* Accepted SMTP is never resent due to missing Sent acknowledgement. */ }
            try await repository.updateSubmission(submission)
        }
        try await repository.deleteDraft(draft.id)
        return submission
    }
    private func connected(_ folder: MailFolder) throws -> IMAPService {
        guard folder.accountID==account.id,let session,!disconnectRequested else { throw MailFailure.offline };return session
    }
    private func selected(_ key: MailMessageKey) async throws -> IMAPService {
        guard key.accountID==account.id,let session,!disconnectRequested else { throw MailFailure.offline }
        _=try await session.select(key.folder)
        guard session.selectedUIDValidity==key.uidValidity else { throw MailFailure.staleFolder };return session
    }
    private func archiveStore() throws -> MessageArchiveStore {
        if let archive { return archive }
        let value=try MessageArchiveStore(connectionString:configuration.connectionString,schema:configuration.archiveSchema ?? configuration.schema,keyProvider:keyProvider)
        archive=value;return value
    }
    private func retain(_ letters: [MailLetter],source: MessageArchiveSource) throws {
        _ = try archiveStore().append(letters.map { letter in
            .init(identity:letter.key.archiveIdentity,source:source,event:.message(.init(date:letter.date,text:"Тема: \(letter.subject)\nКому: \(letter.recipient)\nMessage-ID: \(letter.messageID)\n\n" + String((letter.text ?? "").prefix(128000)),author:letter.senderName,authorID:letter.sender,isOutgoing:letter.sender.caseInsensitiveCompare(account.email) == .orderedSame,attachments:letter.attachments.map { .init(id:$0.id,kind:"document",name:String($0.filename.prefix(512)),size:Int64($0.byteCount)) })))
        })
    }
    private func fileRepository() throws -> ArchiveFileRepository? {
        if let files { return files };guard let storageFile else { return nil }
        let value=try ArchiveFileRepository(connectionString:configuration.connectionString,schema:configuration.archiveSchema ?? configuration.schema,configuration:S3ConfigurationFile.read(storageFile),spoolDirectory:spool,keyProvider:keyProvider)
        files=value;return value
    }
    private func capture(_ bytes: Data,identity: MessageArchiveIdentity,attachment: MessageArchiveAttachment,files: ArchiveFileRepository) async throws {
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        if try await files.files(identity: identity, attachmentID: attachment.id).contains(where: { $0.state == .stored && $0.plaintextSHA256 == hash }) { return }
        let root=spool.appendingPathComponent("MailCapture",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let url=root.appendingPathComponent(UUID().uuidString)
        try bytes.write(to:url,options:.withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        defer { try? FileManager.default.removeItem(at:url) }
        let capture=try ArchiveFileCapture(file:url,byteCount:Int64(bytes.count))
        _=try await files.captureConversationFile(capture,identity:identity,attachment:attachment,defaultEnabled:true)
    }
    private func policyIdentity(_ folder: MailFolder) -> MessageArchiveIdentity {
        .init(service:"mail",accountID:account.id,conversationID:Data(folder.path.utf8).base64EncodedString(),messageID:"policy")
    }
    private func safe(_ error: Error) -> Error {
        if let error=error as? MailFailure { return error }
        if error is CancellationError { return error }
        if let error=error as? MailError {
            switch error { case .notConnected, .connectFailed: return MailFailure.offline; default: return MailFailure.serverRejected }
        }
        return MailFailure.serverRejected
    }
}
