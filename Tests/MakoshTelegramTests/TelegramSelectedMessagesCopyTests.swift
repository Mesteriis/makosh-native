import XCTest
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramSelectedMessagesCopyTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        let lock = NSLock(); private var count = 0
        func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    private final class Provider: TelegramSelectedMessagesCopyProvider {
        let accountID: Int64 = 1
        let disposal = Counter()
        var callbacks: [@MainActor (String?) -> Void] = []
        var synchronous = false
        func resolve(request: TelegramSelectedMessagesCopyRequest, completion: @escaping @MainActor (String?) -> Void) -> Disposable {
            callbacks.append(completion); if synchronous { completion("masked") }
            let counter = disposal; return ActionDisposable { counter.increment() }
        }
    }
    private func request() throws -> TelegramSelectedMessagesCopyRequest {
        let selection = TelegramMessageSelectionController()
        let source = TelegramMessageActionSource(accountID: 1, chatID: 7, peerID: 7, namespace: 0, messageID: 1,
            fingerprint: "v", text: "text", canReply: true, canEdit: false, canForward: true,
            canDeleteLocally: true, canDeleteForEveryone: false, canCopy: true)
        XCTAssertTrue(selection.begin(source: source, contextID: UUID()))
        return .init(session: try XCTUnwrap(selection.session))
    }
    func testSynchronousResultDisposesReturnedSubscriptionAndIgnoresDuplicate() throws {
        let controller = TelegramSelectedMessagesCopyController(), provider = Provider(); provider.synchronous = true
        controller.bind(provider: provider); var values: [String] = []
        XCTAssertTrue(controller.start(request: try request(), isCurrent: { true }, receive: { values.append($0) }))
        XCTAssertEqual(values, ["masked"]); XCTAssertFalse(controller.isBusy); XCTAssertEqual(provider.disposal.value, 1)
        provider.callbacks[0]("duplicate"); XCTAssertEqual(values, ["masked"])
    }
    func testCurrentCheckFailureTimeoutCancellationAndRebindNeverPublishLateText() throws {
        let controller = TelegramSelectedMessagesCopyController(), provider = Provider(), request = try request()
        controller.bind(provider: provider); var current = true, received = 0
        XCTAssertTrue(controller.start(request: request, isCurrent: { current }, receive: { _ in received += 1 }))
        XCTAssertFalse(controller.start(request: request, isCurrent: { true }, receive: { _ in XCTFail("duplicate") }))
        current = false; provider.callbacks[0]("stale"); XCTAssertEqual(received, 0); XCTAssertNil(controller.error)
        current = true
        XCTAssertTrue(controller.start(request: request, isCurrent: { current }, receive: { _ in received += 1 }))
        controller.timeout(); XCTAssertNotNil(controller.error); provider.callbacks[1]("late"); XCTAssertEqual(received, 0)
        XCTAssertTrue(controller.start(request: request, isCurrent: { true }, receive: { _ in received += 1 }))
        provider.callbacks[2](nil); XCTAssertNotNil(controller.error); XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(controller.start(request: request, isCurrent: { true }, receive: { _ in received += 1 }))
        controller.bind(provider: nil); provider.callbacks[3]("old account"); XCTAssertEqual(received, 0)
        XCTAssertEqual(provider.disposal.value, 4)
        XCTAssertFalse(controller.start(request: request, isCurrent: { true }, receive: { _ in XCTFail("unbound") }))
    }
    func testMaskingFormattingAndMediaNeverUseRawMalformedFallback() throws {
        let rich = try TelegramFormattedText(text: "secret code 12345", entities: [.init(offset: 0, length: 6, kind: .spoiler)])
        let output = telegramSelectedCopyText([
            .init(author: "Forward author", formatted: rich, attachments: [], maskServiceCodes: true),
            .init(author: "Author", formatted: nil, attachments: [], maskServiceCodes: false),
            .init(author: "Photo", formatted: try .init(text: ""), attachments: [.init(id: "p", kind: .photo, name: "private.jpg", byteCount: nil, mimeType: nil, hasPreview: true, canDownload: true)], maskServiceCodes: false)
        ])
        XCTAssertEqual(output, "> Forward author:\n██████ code █████\n\n> Author:\nФорматирование сообщения недоступно\n\n> Photo:\nФото")
        XCTAssertFalse(output.contains("secret")); XCTAssertFalse(output.contains("12345")); XCTAssertFalse(output.contains("private.jpg"))
    }
    func testSupportedMediaPrefixesKeepMaskedCaptionAndSafeTypedLabels() throws {
        let caption = try TelegramFormattedText(text: "secret caption", entities: [.init(offset: 0, length: 6, kind: .spoiler)])
        let items: [TelegramSelectedCopyItem] = [
            .init(author: "A", formatted: caption, attachments: [], maskServiceCodes: false, media: .photo),
            .init(author: "B", formatted: caption, attachments: [], maskServiceCodes: false, media: .file("unused.txt")),
            .init(author: "C", formatted: caption, attachments: [], maskServiceCodes: false, media: .voice),
            .init(author: "D", formatted: try .init(text: ""), attachments: [], maskServiceCodes: false, media: .file("report.txt"))
        ]
        let text = telegramSelectedCopyText(items)
        XCTAssertTrue(text.contains("🖼 ██████ caption")); XCTAssertTrue(text.contains("📎 ██████ caption"))
        XCTAssertTrue(text.contains("🎤 ██████ caption")); XCTAssertTrue(text.contains("report.txt"))
        XCTAssertFalse(text.contains("secret")); XCTAssertFalse(text.contains("unused.txt"))
    }
    #if DEBUG
    func testSyntheticProviderOrdersAndRefusesWholeProtectedOrChangedSelection() throws {
        let pages = TelegramSyntheticPages(), page = pages.messages(chatID: 10001, anchor: nil)
        let selection = TelegramMessageSelectionController(), context = UUID()
        func source(_ n: Int32) throws -> TelegramMessageActionSource {
            .init(metadata: try XCTUnwrap(page.items.first { $0.actionMetadata?.messageID == n }?.actionMetadata), accountID: -1, chatID: 10001)
        }
        XCTAssertTrue(selection.begin(source: try source(122), contextID: context)); let id = try XCTUnwrap(selection.session?.id)
        XCTAssertTrue(selection.toggle(source: try source(121), sessionID: id, contextID: context))
        let provider = TelegramSyntheticSelectedMessagesCopyProvider(); var result: String?
        _ = provider.resolve(request: .init(session: try XCTUnwrap(selection.session))) { result = $0 }
        let text = try XCTUnwrap(result); XCTAssertFalse(text.contains("СЕКРЕТ_QA_121"))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "сообщение 121")?.lowerBound), try XCTUnwrap(text.range(of: "сообщение 122")?.lowerBound))
        XCTAssertTrue(selection.toggle(source: try source(120), sessionID: id, contextID: context))
        _ = provider.resolve(request: .init(session: try XCTUnwrap(selection.session))) { result = $0 }
        XCTAssertNil(result)
    }
    #endif
}
