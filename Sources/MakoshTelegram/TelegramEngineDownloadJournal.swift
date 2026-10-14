import Foundation
import MakoshCore
import Postbox
import TelegramCore
import SwiftSignalKit

nonisolated func telegramDownloadJournalKey(accountID: Int64) -> ValueBoxKey {
    let prefix = Data("Makosh.ManualDownloads.v1\0".utf8)
    let key = ValueBoxKey(length:prefix.count + 8)
    key.setData(0,value:prefix); key.setInt64(prefix.count,value:accountID); return key
}
nonisolated func telegramDownloadJournalRead(transaction:Transaction,accountID:Int64) -> Result<TelegramDownloadJournalSnapshot?,TelegramDownloadJournalError> {
    guard accountID != 0 else { return .failure(.invalid) }
    guard let entry = transaction.getPreferencesEntry(key:telegramDownloadJournalKey(accountID:accountID)) else { return .success(nil) }
    do { return .success(try .decode(entry.data,accountID:accountID)) }
    catch { return .failure(.invalid) }
}
nonisolated func telegramDownloadJournalWrite(transaction:Transaction,value:TelegramDownloadJournalSnapshot,expected:UUID?) -> Result<Void,TelegramDownloadJournalError> {
    guard let data = try? value.encoded(), value.revision != expected else { return .failure(.invalid) }
    switch telegramDownloadJournalRead(transaction:transaction,accountID:value.accountID) {
    case let .failure(error): return .failure(error)
    case let .success(current):
        guard current?.revision == expected else { return .failure(.changed) }
        transaction.setPreferencesEntry(key:telegramDownloadJournalKey(accountID:value.accountID),value:PreferencesEntry(data:data))
        return .success(())
    }
}

/// Fresh native lookup, with no network, read marker or saved cache path. A
/// changed file with the same resource ID must still match the frozen size/name.
nonisolated func telegramDownloadSource(transaction:Transaction,accountID:Int64,record:TelegramDownloadRecord) -> TelegramAttachmentSource? {
    guard accountID != 0, record.isValid else { return nil }
    let peerID = PeerId(record.peerID), id = MessageId(peerId:peerID,namespace:record.namespace,id:record.messageID)
    guard let message = transaction.getMessage(id), message.id == id,
          message.flags.intersection([.Unsent,.Sending,.Failed,.CopyProtected]).isEmpty, !message.containsSecretMedia,
          let peer = transaction.getPeer(peerID) else { return nil }
    if let user = peer as? TelegramUser {
        guard !user.isDeleted else { return nil }
    } else if let group = peer as? TelegramGroup {
        guard group.membership == .Member, !group.flags.contains(.deactivated),
              !group.flags.contains(.copyProtectionEnabled), group.defaultBannedRights?.flags.contains(.banReadMessages) != true else { return nil }
    } else if let channel = peer as? TelegramChannel {
        guard channel.participationStatus == .member, !channel.flags.contains(.copyProtectionEnabled),
              channel.bannedRights?.flags.contains(.banReadMessages) != true,
              channel.defaultBannedRights?.flags.contains(.banReadMessages) != true else { return nil }
    } else if peer is TelegramSecretChat {
        guard let session = telegramSecretSessionSnapshot(transaction:transaction,accountID:accountID,chatID:record.peerID),
              session.state == .active, session.keyAvailable else { return nil }
    } else { return nil }
    guard let source = telegramAttachments(message).first(where:{ $0.attachment.id == record.attachmentID }),
          source.attachment.canDownload, source.full != nil, source.attachment.name == record.name,
          source.attachment.byteCount == record.byteCount, (source.attachment.kind == .photo) == record.photo else { return nil }
    return source
}

private nonisolated func readDownloadJournal(postbox:Postbox,accountID:Int64) -> Signal<Result<TelegramDownloadJournalSnapshot?,TelegramDownloadJournalError>,NoError> {
    postbox.transaction { telegramDownloadJournalRead(transaction:$0,accountID:accountID) }
}
private nonisolated func writeDownloadJournal(postbox:Postbox,value:TelegramDownloadJournalSnapshot,expected:UUID?) -> Signal<Result<Void,TelegramDownloadJournalError>,NoError> {
    postbox.transaction { telegramDownloadJournalWrite(transaction:$0,value:value,expected:expected) }
}
@MainActor final class TelegramPostboxDownloadJournalRepository: TelegramDownloadJournalRepository {
    let accountID: Int64
    private let postbox: Postbox
    init(postbox:Postbox,accountID:Int64) { self.postbox = postbox; self.accountID = accountID }
    func load(completion:@escaping @MainActor (Result<TelegramDownloadJournalSnapshot?,TelegramDownloadJournalError>) -> Void) -> any TelegramDownloadJournalRequest {
        let request = Request(), account = accountID
        let signal = readDownloadJournal(postbox:postbox,accountID:account)
            |> timeout(30,queue:.mainQueue(),alternate:.single(.failure(.unavailable))) |> deliverOnMainQueue
        request.disposable.set(signal.start(next:{ result in MainActor.assumeIsolated { completion(result) } }))
        return request
    }
    func save(_ value:TelegramDownloadJournalSnapshot,expected:UUID?,completion:@escaping @MainActor (Result<Void,TelegramDownloadJournalError>) -> Void) {
        guard value.accountID == accountID else { completion(.failure(.invalid)); return }
        // The standalone write retains the serial journal until every already
        // queued mutation finishes, even when the old account view is released.
        let _ = (writeDownloadJournal(postbox:postbox,value:value,expected:expected)
            |> timeout(30,queue:.mainQueue(),alternate:.single(.failure(.unavailable)))
            |> deliverOnMainQueue).startStandalone(next:{ result in MainActor.assumeIsolated { completion(result) } })
    }
    private final class Request: TelegramDownloadJournalRequest {
        let disposable = MetaDisposable()
        func cancel() { disposable.dispose() }
        isolated deinit { disposable.dispose() }
    }
}

private struct DownloadRestoration {
    let record: TelegramDownloadRecord
    let source: TelegramAttachmentSource?
}
private nonisolated func readDownloadSources(postbox:Postbox,accountID:Int64,records:[TelegramDownloadRecord]) -> Signal<[DownloadRestoration]?,NoError> {
    guard accountID != 0, records.count <= 1000, records.allSatisfy(\.isValid) else { return .single(nil) }
    return postbox.transaction { tx in
        records.map { DownloadRestoration(record:$0,source:telegramDownloadSource(transaction:tx,accountID:accountID,record:$0)) } as [DownloadRestoration]?
    }
}

/// Account-owned bridge; native message references are reconstructed in memory.
/// Its repository owns only encrypted metadata, never file bytes/access hashes.
@MainActor final class TelegramEngineDownloadJournal {
    let journal = TelegramDownloadJournal()
    private let postbox: Postbox, accountID: Int64, contextID: UUID
    private weak var media: TelegramMediaController?
    private let provider: TelegramEngineMediaProvider
    private let completedFile: @MainActor (TelegramDownloadRecord,TelegramAttachment,URL,Int64) -> Void
    private let reserveFile: (@MainActor (TelegramDownloadRecord,TelegramAttachment) -> (any TelegramMediaArchiveReservation)?)?
    private let reading = MetaDisposable()
    private var operation = UUID(), needsReplay = true
    init(postbox:Postbox,accountID:Int64,media:TelegramMediaController,provider:TelegramEngineMediaProvider,
        reserveFile:(@MainActor (TelegramDownloadRecord,TelegramAttachment) -> (any TelegramMediaArchiveReservation)?)? = nil,
        completedFile:@escaping @MainActor (TelegramDownloadRecord,TelegramAttachment,URL,Int64) -> Void) {
        self.postbox = postbox; self.accountID = accountID; self.media = media; self.provider = provider
        self.contextID = media.transferContextID; self.completedFile = completedFile; self.reserveFile = reserveFile
        media.configureJournal(journal,recordFor:{ [weak self] attachment,state in self?.record(attachment,state:state) })
        journal.didLoad = { [weak self] snapshot in self?.needsReplay = true; self?.restore(snapshot,recheck:true) }
        journal.didCommit = { [weak self] snapshot in
            guard let self, self.needsReplay else { return }; self.restore(snapshot,recheck:false)
        }
        journal.bind(repository:TelegramPostboxDownloadJournalRepository(postbox:postbox,accountID:accountID))
    }
    isolated deinit { reading.dispose(); journal.didLoad = nil; journal.didCommit = nil }
    private func record(_ attachment:TelegramAttachment,state:TelegramDownloadRecord.State) -> TelegramDownloadRecord? {
        guard media?.transferContextID == contextID else { return nil }
        if let source = provider.sources[attachment.id], source.attachment == attachment {
            return .init(attachmentID:attachment.id,peerID:source.messageID.peerId.toInt64(),namespace:source.messageID.namespace,messageID:source.messageID.id,name:attachment.name,byteCount:attachment.byteCount,photo:attachment.kind == .photo,state:state)
        }
        // A refused source still needs a durable cancel/failed/clear operation.
        guard var record = journal.records.first(where:{ $0.attachmentID == attachment.id }),
              record.name == attachment.name, record.byteCount == attachment.byteCount,
              record.photo == (attachment.kind == .photo) else { return nil }
        record.state = state; return record
    }
    private func restore(_ snapshot:TelegramDownloadJournalSnapshot,recheck:Bool) {
        guard let media, media.transferContextID == contextID, snapshot.accountID == accountID,
              journal.accountID == accountID, journal.error == nil else { return }
        reading.set(nil); operation = UUID(); let token = operation, restoreContext = media.restorationContextID
        let records = snapshot.records.filter { record in
            let phase = media.phase(for:.init(attachmentID:record.attachmentID,purpose:.full))
            return !media.hasTransfer(attachmentID:record.attachmentID) || (recheck && [.failed,.cancelled,.timedOut].contains(phase))
        }
        guard !records.isEmpty else { needsReplay = false; media.setQueueRestoring(false,contextID:contextID); return }
        media.setQueueRestoring(true,contextID:contextID)
        reading.set((readDownloadSources(postbox:postbox,accountID:accountID,records:records)
            |> timeout(30,queue:.mainQueue(),alternate:.single(nil)) |> deliverOnMainQueue).start(next:{ [weak self] restored in
                guard let self, self.operation == token, let media = self.media, media.transferContextID == self.contextID else { return }
                media.setQueueRestoring(false,contextID:self.contextID)
                guard media.restorationContextID == restoreContext else { return }
                guard let restored, self.journal.error == nil else { media.noteQueueRestorationFailure(); return }
                self.needsReplay = false
                for value in restored {
                    let record = value.record
                    guard self.journal.records.contains(record) else { continue }
                    if let source = value.source {
                        self.provider.sources[record.attachmentID] = source
                        let capture = self.completedFile
                        let reservation: (@MainActor () -> (any TelegramMediaArchiveReservation)?)?
                        if let factory = self.reserveFile { let attachment = source.attachment; reservation = { factory(record,attachment) } }
                        else { reservation = nil }
                        media.restoreManual(attachment:source.attachment,state:record.state,completedFile:{ _,url,size in
                            capture(record,source.attachment,url,size)
                        },contextID:restoreContext,reserveFile:reservation)
                    } else {
                        self.provider.sources.removeValue(forKey:record.attachmentID)
                        media.restoreManual(attachment:record.placeholder,state:record.state == .cancelled ? .cancelled : .failed,completedFile:nil,contextID:restoreContext)
                        media.noteQueueRestorationFailure()
                        if record.state == .pending || record.state == .ready {
                            var failed = record; failed.state = .failed; self.journal.upsert(failed) { _ in }
                        }
                    }
                }
            }))
    }
}
