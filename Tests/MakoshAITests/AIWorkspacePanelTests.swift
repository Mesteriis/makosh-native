import Foundation
import MakoshCore
import XCTest
@testable import MakoshAI

@MainActor final class AIWorkspacePanelTests: XCTestCase {
    private var database: AITestDatabase!
    private var worker: AIWorker!
    private var provider: AIFakeContextProvider!
    private var model: AIWorkspaceModel!
    private let chatA = AIContextCard.chat(service: "telegram", accountID: "1", chatID: "A", title: "Мария", range: .standard)
    private let chatB = AIContextCard.chat(service: "telegram", accountID: "1", chatID: "B", title: "Работа", range: .standard)

    override func setUp() async throws {
        database = try AITestDatabase()
        worker = AIWorker(repository: AIRepository(keyProvider: aiTestKey), client: AIFakeService(), vault: AIFakeVault())
        provider = AIFakeContextProvider()
        await provider.set(chatA, text: "a")
        await provider.set(chatB, text: "b")
        await worker.attachContext(provider)
        model = AIWorkspaceModel(worker: worker)
        await model.start(configuration: database.configuration)
    }
    override func tearDown() async throws {
        await worker?.close()
        try database?.cleanup()
    }

    func testOpenAnchorCreatesConversationWithCurrentChatCard() async throws {
        await model.open(anchor: chatA)
        XCTAssertEqual(model.anchor, chatA)
        XCTAssertEqual(model.cards, [chatA])
        XCTAssertEqual(model.previews[chatA.id]?.lines.first?.text, "a")
    }

    func testOpenAnchorReusesLatestConversationOfThatChat() async throws {
        await model.open(anchor: chatA)
        let first = try XCTUnwrap(model.selectedConversationID)
        await model.open(anchor: chatB)
        XCTAssertNotEqual(model.selectedConversationID, first)
        await model.open(anchor: chatA)
        XCTAssertEqual(model.selectedConversationID, first)
        XCTAssertEqual(model.visibleConversations.map(\.id), [first])
    }

    func testSwitchingAnchorDropsLateResultsOfPreviousChat() async throws {
        let model = self.model!, chatA = self.chatA
        let first = Task { @MainActor in await model.open(anchor: chatA) }
        // Let the first call begin, so the second is the later one.
        while model.anchor != chatA { await Task.yield() }
        await model.open(anchor: chatB)
        await first.value
        XCTAssertEqual(model.anchor, chatB)
        XCTAssertEqual(model.cards.first?.id, chatB.id)
    }

    func testRemovingACardCancelsItsPreview() async throws {
        await model.open(anchor: chatA)
        await provider.hold(chatB)
        let model = self.model!, chatB = self.chatB, provider = self.provider!
        let adding = Task { @MainActor in await model.add(chatB) }
        while await !provider.reads.contains(chatB.id) { await Task.yield() }
        model.reportExtraction(cardID: chatB.id, progress: AIExtractionProgress(done: 1, total: 9))
        XCTAssertEqual(model.extraction[chatB.id], AIExtractionProgress(done: 1, total: 9))
        await model.remove(chatB.id)
        XCTAssertEqual(model.cards.map(\.id), [chatA.id], "removal does not wait for the held read")
        XCTAssertNil(model.extraction[chatB.id])
        await provider.release(chatB)
        await adding.value
        XCTAssertNil(model.previews[chatB.id], "the late material of a removed card never lands")
        XCTAssertEqual(model.previews[chatA.id]?.lines.first?.text, "a")
    }

    func testRemovingAndAddingCardsUpdatesConversation() async throws {
        await model.open(anchor: chatA)
        await model.add(chatB)
        XCTAssertEqual(model.cards.map(\.id), [chatA.id, chatB.id])
        await model.add(chatB)
        XCTAssertEqual(model.cards.count, 2, "a card is attached once")
        await model.remove(chatA.id)
        XCTAssertEqual(model.cards.map(\.id), [chatB.id])
        let stored = try await worker.conversations(anchoredTo: chatA).first?.cards.map(\.id)
        XCTAssertEqual(stored, [chatB.id])
    }

    func testChangingRangeKeepsCardAndRefreshesPreview() async throws {
        await model.open(anchor: chatA)
        await model.setRange(.lastDays(7), for: chatA.id)
        guard case .chat(_, _, _, _, let range)? = model.cards.first else { return XCTFail() }
        XCTAssertEqual(range, .lastDays(7))
    }

    func testSetPagesKeepsCardIdentityAndRefreshesPreview() async throws {
        let file = AIContextCard.file(source: .staged(id: UUID()), title: "Договор.pdf", pages: nil)
        await provider.set(file, text: "текст")
        await model.open(anchor: chatA)
        await model.add(file)
        let before = await provider.reads.filter { $0 == file.id }.count
        await model.setPages(2...3, for: file.id)
        guard case .file(_, _, let pages)? = model.cards.first(where: { $0.id == file.id }) else { return XCTFail("\(model.cards)") }
        XCTAssertEqual(pages, 2...3)
        XCTAssertEqual(model.cards.map(\.id), [chatA.id, file.id], "the card keeps its place and id")
        let after = await provider.reads.filter { $0 == file.id }.count
        XCTAssertGreaterThan(after, before, "the preview is read again for the new pages")
        await model.setPages(nil, for: file.id)
        guard case .file(_, _, nil)? = model.cards.first(where: { $0.id == file.id }) else { return XCTFail("\(model.cards)") }
    }

    func testUnavailableCardShowsFailureOnItsPreview() async throws {
        let secret = AIContextCard.chat(service: "telegram", accountID: "1", chatID: "S", title: "Секрет", range: .standard)
        await provider.fail(secret, .contextUnavailable("Секретный чат нельзя прикрепить."))
        await model.open(anchor: chatA)
        await model.add(secret)
        XCTAssertEqual(model.previewFailures[secret.id], .contextUnavailable("Секретный чат нельзя прикрепить."))
    }

    func testFilterSeparatesAnchoredConversations() async throws {
        await model.open(anchor: chatA)
        let anchored = try XCTUnwrap(model.selectedConversationID)
        let plain = try await worker.createConversation()
        await model.leaveAnchor()
        await model.reload()
        model.filter = .anchored
        XCTAssertEqual(model.visibleConversations.map(\.id), [anchored])
        model.filter = .unanchored
        XCTAssertEqual(model.visibleConversations.map(\.id), [plain.id])
        model.filter = .all
        XCTAssertEqual(Set(model.visibleConversations.map(\.id)), [anchored, plain.id])
    }

    func testSelectingConversationWithCardsLoadsPreviewsOutsideThePanel() async throws {
        let conversation = try await worker.createConversation(anchor: chatA)
        await model.reload()
        await model.select(conversation.id)
        XCTAssertNil(model.anchor)
        XCTAssertEqual(model.previews[chatA.id]?.lines.first?.text, "a")
    }

    func testSwitchingPanelConversationRefreshesPreviews() async throws {
        await model.open(anchor: chatA)
        let first = try XCTUnwrap(model.selectedConversationID)
        await model.newConversation()
        await model.add(chatB)
        XCTAssertNotNil(model.previews[chatB.id])
        await model.select(first)
        XCTAssertNil(model.previews[chatB.id])
        XCTAssertNotNil(model.previews[chatA.id])
    }
}
