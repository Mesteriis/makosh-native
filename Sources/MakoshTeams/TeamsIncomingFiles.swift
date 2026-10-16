import Foundation
import MakoshCore

struct TeamsIncomingFile: Codable, Sendable {
    let id: UUID
    let sequence: Int64
    let scope: TeamsScope
    let messageID: String
    let attachment: TeamsAttachment
    var remote: TeamsRemoteFile?
    var capturedAt: Date?
    var receipt: ArchiveFileRecord?
    var pending: Bool
    var failure: TeamsFailure?
    var preparedID: UUID?
}
extension TeamsRepository {
    func reserveIncomingFiles(_ version: TeamsRetainedVersion, outgoingFiles: [UUID] = []) throws {
        let db = try db(), message = version.message
        guard message.attachments.count <= 1000, Set(message.attachments.map { Data($0.id.utf8) }).count == message.attachments.count else { throw TeamsFailure.invalidResponse }
        for attachment in message.attachments {
            let ownFile = version.observation.source == .outgoing ? UUID(uuidString: attachment.id).flatMap { outgoingFiles.contains($0) ? $0 : nil } : nil
            if let ownFile { _ = try preparedFiles(scope: message.scope, ids: [ownFile]) }
            let pending = version.observation.source != .outgoing
            let value = TeamsIncomingFile(id: UUID(), sequence: version.sequence, scope: message.scope, messageID: message.id, attachment: attachment, pending: pending, preparedID: ownFile)
            let token = value.id.uuidString
            _ = try db.query("INSERT INTO \(db.prefix)teams_incoming_files VALUES($1,$2,$3,$4,$5,$6::bigint,$8::boolean,$7)",
                [token, try db.token(message.scope.storageKey), try db.token(["files-account", message.scope.accountID.uuidString]),
                 try db.token(["files-message", message.id]), try db.token(["files-attachment", attachment.id]), String(version.sequence), try db.seal(value, token: "incoming-file:" + token), pending ? "true" : "false"])
        }
    }
    func bindOutgoingPreparations(message: TeamsMessage, fileIDs: [UUID]) throws {
        guard !fileIDs.isEmpty else { return }
        _ = try preparedFiles(scope: message.scope, ids: fileIDs)
        let db = try db(), scope = try db.token(message.scope.storageKey)
        let digest = try db.token(db.encoded(message))
        guard let raw = try db.query("SELECT sequence FROM \(db.prefix)teams_versions WHERE message=$1 AND digest=$2", [try db.token(["message", scope, message.id]), digest]).first?.first else { throw TeamsFailure.storage }
        for attachment in message.attachments {
            guard let id = UUID(uuidString: attachment.id), fileIDs.contains(id) else { continue }
            var job = try incomingFile(scope: message.scope, messageID: message.id, attachmentID: attachment.id, version: raw)
            job.preparedID = id; job.pending = false
            try saveIncoming(job)
        }
    }
    func incomingFiles(scope: TeamsScope, pendingOnly: Bool) throws -> [TeamsIncomingFile] {
        _ = try validate(scope); let db = try db()
        return try db.query("SELECT token,ciphertext FROM \(db.prefix)teams_incoming_files WHERE scope=$1" + (pendingOnly ? " AND pending=true" : "") + " ORDER BY sequence DESC LIMIT 100", [try db.token(scope.storageKey)]).map { try db.decode($0[1], token: "incoming-file:" + $0[0]) }
    }
    func pendingIncoming(accountID: UUID) throws -> [TeamsIncomingFile] {
        _ = try account(accountID); let db = try db()
        return try db.query("SELECT token,ciphertext FROM \(db.prefix)teams_incoming_files WHERE account=$1 AND pending=true ORDER BY sequence LIMIT 50", [try db.token(["files-account", accountID.uuidString])]).map { try db.decode($0[1], token: "incoming-file:" + $0[0]) }
    }
    func incomingFile(scope: TeamsScope, messageID: String, attachmentID: String, version: String?) throws -> TeamsIncomingFile {
        _ = try validate(scope); let db = try db()
        guard version == nil || Int64(version!) != nil else { throw TeamsFailure.invalidResource }
        let rows = try db.query("SELECT token,ciphertext FROM \(db.prefix)teams_incoming_files WHERE scope=$1 AND message=$2 AND attachment=$3" + (version == nil ? "" : " AND sequence=$4::bigint") + " ORDER BY sequence DESC LIMIT 1",
            [try db.token(scope.storageKey), try db.token(["files-message", messageID]), try db.token(["files-attachment", attachmentID])] + (version.map { [$0] } ?? []))
        guard let row = rows.first else { throw TeamsFailure.historicalFileUnavailable }
        return try db.decode(row[1], token: "incoming-file:" + row[0])
    }
    func saveIncoming(_ value: TeamsIncomingFile) throws {
        _ = try validate(value.scope); let db = try db()
        guard try db.query("UPDATE \(db.prefix)teams_incoming_files SET pending=$2::boolean,ciphertext=$3 WHERE token=$1 AND scope=$4 RETURNING token",
            [value.id.uuidString, value.pending ? "true" : "false", try db.seal(value, token: "incoming-file:" + value.id.uuidString), try db.token(value.scope.storageKey)]).count == 1 else { throw TeamsFailure.storage }
    }
    func incomingIsLatest(_ value: TeamsIncomingFile) throws -> Bool {
        try versions(scope: value.scope, messageID: value.messageID, limit: 1).first?.sequence == value.sequence
    }
}

extension TeamsFiles {
    func download(job original: TeamsIncomingFile, graph: TeamsGraphFiles, token: String, capabilities: Set<TeamsCapability>,
                  downloader: any TeamsFileDownloading) async throws -> TeamsFileLease {
        let lease = try await repository.acquireLease(kind: .sync, accountID: original.scope.accountID, operationID: UUID())
        do {
            let result = try await downloadOwned(job: original, graph: graph, token: token, capabilities: capabilities, downloader: downloader)
            try await repository.releaseLease(lease); return result
        } catch { try? await repository.releaseLease(lease); throw error }
    }
    private func downloadOwned(job original: TeamsIncomingFile, graph: TeamsGraphFiles, token: String, capabilities: Set<TeamsCapability>, downloader: any TeamsFileDownloading) async throws -> TeamsFileLease {
        let job = try await repository.incomingFile(scope: original.scope, messageID: original.messageID, attachmentID: original.attachment.id, version: String(original.sequence))
        let identity = policyIdentity(job.scope, messageID: job.messageID)
        var recovered = job.receipt
        if recovered == nil { recovered = try await archive().recoverConversationCapture(id: job.id, identity: identity, attachmentID: job.attachment.id) }
        if let record = recovered {
            let (directory, destination) = try leaseDestination(extension: URL(fileURLWithPath: job.attachment.name ?? "file").pathExtension)
            let lease = TeamsFileLease(url: destination, directory: directory)
            do { try await archive().export(record, to: destination); return lease } catch { await lease.release(); throw error }
        }
        if let preparedID = job.preparedID { return try await openPrepared(scope: job.scope, id: preparedID) }
        guard processingIncoming.insert(job.id).inserted else { throw TeamsFailure.operationBusy }
        defer { processingIncoming.remove(job.id) }
        var current = job
        do {
            let lease: TeamsFileLease
            if job.attachment.contentType == "makosh/teams-hosted" {
                let required: TeamsCapability = { if case .chat = job.scope.resource { return .basicChats }; return .channelHistory }()
                guard capabilities.contains(required) else { throw TeamsFailure.forbidden }
                let components = TeamsCollection.Kind.messages(job.scope.resource).components + [job.messageID, "hostedContents", job.attachment.id, "$value"]
                lease = try await graph.download(request: graph.request(components, token: token), name: job.attachment.name ?? "image", expectedSize: nil, downloader: downloader)
            } else {
                if current.remote == nil {
                    guard try await repository.incomingIsLatest(job), let url = job.attachment.contentURL else { throw TeamsFailure.historicalFileUnavailable }
                    current.remote = try await graph.resolveSharedURL(url, token: token, capabilities: capabilities)
                    try await repository.saveIncoming(current) // Resource/eTag is durable before byte IO.
                }
                guard let remote = current.remote else { throw TeamsFailure.invalidResource }
                lease = try await graph.download(remote, token: token, capabilities: capabilities, downloader: downloader)
            }
            do {
                let size = (try FileManager.default.attributesOfItem(atPath: lease.url.path)[.size] as? NSNumber)?.int64Value
                guard let size else { throw TeamsFailure.storage }
                let capture = try ArchiveFileCapture(file: lease.url, byteCount: size)
                let attachment = MessageArchiveAttachment(id: job.attachment.id, kind: "file", name: job.attachment.name ?? "file", size: size)
                current.receipt = try await archive().captureConversationFile(capture, identity: identity, attachment: attachment,
                    defaultEnabled: defaultEnabled(job.scope), reservedID: job.id)
                current.capturedAt = Date(); current.pending = false; current.failure = nil
                try await repository.saveIncoming(current)
                return lease
            } catch { await lease.release(); throw error }
        } catch {
            current.pending = false; current.failure = error as? TeamsFailure ?? .storage
            try await repository.saveIncoming(current); throw error
        }
    }
    func capturePending(accountID: UUID, graph: TeamsGraphFiles, token: String, capabilities: Set<TeamsCapability>, downloader: any TeamsFileDownloading,
                        authorize: @escaping @Sendable () async throws -> Void) async throws {
        while true {
            try await authorize()
            let jobs = try await repository.pendingIncoming(accountID: accountID)
            if jobs.isEmpty { return }
            for var job in jobs {
                try await authorize()
                if try await !savingFiles(scope: job.scope) { job.pending = false; try await repository.saveIncoming(job); continue }
                do { let lease = try await download(job: job, graph: graph, token: token, capabilities: capabilities, downloader: TeamsAuthorizedDownloader(base: downloader, authorize: authorize)); await lease.release() }
                catch is CancellationError { throw CancellationError() }
                catch TeamsFailure.operationBusy { throw TeamsFailure.operationBusy }
                catch { /* Durable failure is shown on explicit download; no automatic retry. */ }
            }
            await Task.yield()
        }
    }
}
