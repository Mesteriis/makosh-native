#if DEBUG
import Foundation
import MakoshCore

actor TelegramSyntheticArchiveRepository: TelegramArchiveRepository {
    private var stored: [MessageArchiveRecord]
    init(includeFile: Bool = false) {
        let identity = MessageArchiveIdentity(service: "telegram", accountID: "-1", conversationID: "1", messageID: "0:9001")
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let original = MessageArchiveContent(date: date, text: "Синтетический оригинал: это сообщение должно остаться в Макоше.",
            author: "Синтетический собеседник", isOutgoing: false,attachments: includeFile ? [MessageArchiveAttachment(id: "synthetic-s3-file",kind: "file",name: "synthetic-retained.txt",size: nil)] : [])
        let edit = MessageArchiveContent(date: date, editedAt: date.addingTimeInterval(10),
            text: "Синтетическая правка. Оригинал хранится отдельным снимком.", author: "Синтетический собеседник", isOutgoing: false)
        stored = [
            MessageArchiveRecord(sequence: 3, observation: MessageArchiveObservation(identity: identity, observedAt: date.addingTimeInterval(20), source: .synthetic, event: .removedFromSource)),
            MessageArchiveRecord(sequence: 2, observation: MessageArchiveObservation(identity: identity, observedAt: date.addingTimeInterval(10), source: .synthetic, event: .message(edit))),
            MessageArchiveRecord(sequence: 1, observation: MessageArchiveObservation(identity: identity, observedAt: date, source: .synthetic, event: .message(original)))
        ]
    }
    func append(_ observations: [MessageArchiveObservation]) throws -> Int {
        var inserted = 0
        for observation in observations where !stored.contains(where: { $0.id == observation.id }) {
            let sequence = (stored.first?.sequence ?? 0) + 1
            stored.insert(MessageArchiveRecord(sequence: sequence, observation: observation), at: 0); inserted += 1
        }
        return inserted
    }
    func records(before: Int64?) throws -> [MessageArchiveRecord] {
        Array(stored.filter { before == nil || $0.sequence < before! }.prefix(100))
    }
}
#endif
