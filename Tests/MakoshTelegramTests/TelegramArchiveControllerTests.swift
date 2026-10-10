import XCTest
import MakoshCore
import SwiftSignalKit
@testable import MakoshTelegram

private actor ArchiveFixtureRepository: TelegramArchiveRepository {
    var stored: [MessageArchiveRecord] = []
    var fail = false
    var hold = false
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func configure(fail: Bool = false, hold: Bool = false) { self.fail = fail; self.hold = hold }
    func release() { hold = false; continuation?.resume(); continuation = nil }
    func hasStarted() -> Bool { started }
    func append(_ observations: [MessageArchiveObservation]) async throws -> Int {
        started = true
        if hold { await withCheckedContinuation { continuation = $0 } }
        if fail { throw MessageArchiveError.database }
        var count = 0
        for observation in observations where !stored.contains(where: { $0.id == observation.id }) {
            stored.insert(MessageArchiveRecord(sequence: Int64(stored.count + 1), observation: observation), at: 0)
            count += 1
        }
        return count
    }
    func records(before: Int64?) throws -> [MessageArchiveRecord] { Array(stored.filter { before == nil || $0.sequence < before! }.prefix(100)) }
    func all() -> [MessageArchiveRecord] { stored }
}

@MainActor private final class ArchiveFixtureJournal: TelegramArchiveJournal {
    let accountID: Int64
    var pending: [TelegramArchiveJournalItem]
    var acknowledgements: [[Int64]] = []
    var callback: (@MainActor (Result<[TelegramArchiveJournalItem], TelegramArchiveReadError>) -> Void)?
    var delayed = false
    var ackSucceeds = true
    init(accountID: Int64, pending: [TelegramArchiveJournalItem]) { self.accountID = accountID; self.pending = pending }
    func read(receive: @escaping @MainActor (Result<[TelegramArchiveJournalItem], TelegramArchiveReadError>) -> Void) -> Disposable {
        callback = receive
        if !delayed { receive(.success(pending)) }
        return EmptyDisposable
    }
    func acknowledge(sequences: [Int64], receive: @escaping @MainActor (Bool) -> Void) -> Disposable {
        acknowledgements.append(sequences)
        if ackSucceeds { pending.removeAll { sequences.contains($0.sequence) } }
        receive(ackSucceeds)
        return EmptyDisposable
    }
}

@MainActor final class TelegramArchiveControllerTests: XCTestCase {
    private func item(account: Int64 = 1, sequence: Int64 = 1, text: String = "original", removed: Bool = false) -> TelegramArchiveJournalItem {
        let identity = MessageArchiveIdentity(service: "telegram", accountID: String(account), conversationID: "100", messageID: "0:42")
        let date = Date(timeIntervalSince1970: 100)
        let observation = MessageArchiveObservation(identity: identity, observedAt: date, source: .synthetic,
            event: .message(MessageArchiveContent(date: date, text: text, author: "fixture", isOutgoing: false)))
        var observations = [observation]
        if removed { observations.append(MessageArchiveObservation(identity: identity, observedAt: date, source: .synthetic, event: .removedFromSource)) }
        return TelegramArchiveJournalItem(sequence: sequence, observations: observations)
    }
    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Expected asynchronous archive state")
    }
    func testOriginalAndEditsRemainAfterSourceRemovalAndOnlyCommittedBatchIsAcknowledged() async {
        let repository = ArchiveFixtureRepository(), controller = TelegramArchiveController()
        let journal = ArchiveFixtureJournal(accountID: 1, pending: [item(), item(sequence: 2, text: "edit"), item(sequence: 3, text: "edit", removed: true)])
        controller.configure(repository: repository); controller.bind(journal: journal)
        await eventually { journal.acknowledgements.count == 1 }
        let values = await repository.all()
        let texts = values.compactMap { record -> String? in if case let .message(content) = record.observation.event { return content.text }; return nil }
        XCTAssertTrue(texts.contains("original")); XCTAssertTrue(texts.contains("edit"))
        XCTAssertEqual(journal.acknowledgements, [[1, 2, 3]])
        XCTAssertTrue(values.contains { $0.observation.event == .removedFromSource })
        controller.bind(journal: nil); controller.reload()
        await eventually { !controller.isLoading }
        XCTAssertEqual(controller.records.count, 4)
    }
    func testFailedArchiveWriteDoesNotAcknowledgeAndExplicitRetryUsesStableObservations() async {
        let repository = ArchiveFixtureRepository(), controller = TelegramArchiveController()
        await repository.configure(fail: true)
        let pending = item(), journal = ArchiveFixtureJournal(accountID: 1, pending: [pending])
        controller.configure(repository: repository); controller.bind(journal: journal)
        await eventually { controller.error != nil }
        XCTAssertTrue(journal.acknowledgements.isEmpty)
        XCTAssertEqual(journal.pending.first?.observations.first?.id, pending.observations.first?.id)
        await repository.configure(); controller.retry()
        await eventually { journal.acknowledgements.count == 1 }
        let stored = await repository.all(); XCTAssertEqual(stored.count, 1)
        XCTAssertNil(controller.error)
    }
    func testRebindingDuringWriteCommitsCapturedAccountAndDoesNotAcknowledgeNewJournalForOldBatch() async {
        for nextAccount: Int64 in [1, 2] {
            let repository = ArchiveFixtureRepository(), controller = TelegramArchiveController()
            await repository.configure(hold: true)
            let old = ArchiveFixtureJournal(accountID: 1, pending: [item()])
            let new = ArchiveFixtureJournal(accountID: nextAccount, pending: [item(account: nextAccount, sequence: 9, text: "new")])
            controller.configure(repository: repository); controller.bind(journal: old)
            for _ in 0..<1000 { if await repository.hasStarted() { break }; await Task.yield() }
            controller.bind(journal: new)
            XCTAssertTrue(old.acknowledgements.isEmpty); XCTAssertTrue(new.acknowledgements.isEmpty)
            await repository.release()
            await eventually { new.acknowledgements.count == 1 }
            XCTAssertTrue(old.acknowledgements.isEmpty)
            XCTAssertEqual(new.acknowledgements, [[9]])
            let stored = await repository.all(); XCTAssertEqual(stored.count, 2)
            controller.bind(journal: nil)
        }
    }
    func testWrongAccountAndStaleDuplicateReadCannotWriteOrAcknowledge() async {
        let repository = ArchiveFixtureRepository(), controller = TelegramArchiveController()
        let stale = ArchiveFixtureJournal(accountID: 1, pending: [item()]); stale.delayed = true
        controller.configure(repository: repository); controller.bind(journal: stale)
        let bad = ArchiveFixtureJournal(accountID: 2, pending: [item(account: 1)])
        controller.bind(journal: bad)
        XCTAssertNotNil(controller.error)
        stale.callback?(.success(stale.pending))
        await Task.yield()
        XCTAssertTrue(stale.acknowledgements.isEmpty); XCTAssertTrue(bad.acknowledgements.isEmpty)
        let initiallyStored = await repository.all(); XCTAssertTrue(initiallyStored.isEmpty)
        let good = ArchiveFixtureJournal(accountID: 1, pending: [item()])
        controller.bind(journal: good)
        good.callback?(.success(good.pending))
        await eventually { good.acknowledgements.count == 1 }
        let stored = await repository.all(); XCTAssertEqual(stored.count, 1)
    }
    func testArchiveCommitSurvivesFailedAcknowledgementAndRedeliveryDoesNotDuplicate() async {
        let repository = ArchiveFixtureRepository(), controller = TelegramArchiveController()
        let journal = ArchiveFixtureJournal(accountID: 1, pending: [item()]); journal.ackSucceeds = false
        controller.configure(repository: repository); controller.bind(journal: journal)
        await eventually { controller.error != nil }
        let stored = await repository.all(); XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(journal.pending.count, 1)
        journal.ackSucceeds = true; controller.retry()
        await eventually { journal.acknowledgements.count == 2 }
        let replayed = await repository.all(); XCTAssertEqual(replayed.count, 1)
        XCTAssertTrue(journal.pending.isEmpty)
    }
}
