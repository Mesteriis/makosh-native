import XCTest
@testable import MakoshMail

final class MailIdleTests: XCTestCase {
    func testIdleReceivesChangeAndCompletesDoneBeforeNextCommand() async throws {
        let fixture = try await Fixture(mode: "imap", scenario: "idle-change"); defer { fixture.close() }
        let service = IMAPService(config: fixture.config, password: "synthetic")
        try await service.connectAndLogin()
        let changed = try await service.waitForChanges(mailbox: "INBOX", maximumWait: .seconds(2))
        XCTAssertEqual(changed, true)
        _ = try await service.select("INBOX")
        await service.disconnect()
        let done = try await fixture.count("idle_done"); XCTAssertEqual(done, 1)
    }
    func testUnsupportedIdleReturnsFallbackWithoutSendingIdle() async throws {
        let fixture = try await Fixture(mode: "imap", scenario: "accept"); defer { fixture.close() }
        let service = IMAPService(config: fixture.config, password: "synthetic")
        try await service.connectAndLogin()
        let changed = try await service.waitForChanges(mailbox: "INBOX", maximumWait: .seconds(1))
        XCTAssertNil(changed)
        await service.disconnect()
        let commands = try await fixture.count("idle"); XCTAssertEqual(commands, 0)
    }
    func testIdleCancellationWritesDoneAndDoesNotPoisonConnection() async throws {
        let fixture = try await Fixture(mode: "imap", scenario: "idle-wait"); defer { fixture.close() }
        let service = IMAPService(config: fixture.config, password: "synthetic")
        try await service.connectAndLogin()
        let task = Task { try await service.waitForChanges(mailbox: "INBOX", maximumWait: .seconds(5)) }
        for _ in 0..<100 { if FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("idle-started").path) { break }; try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled watcher must stop") } catch { XCTAssertTrue(error is CancellationError) }
        _ = try await service.select("INBOX")
        await service.disconnect()
        let done = try await fixture.count("idle_done"); XCTAssertEqual(done, 1)
    }
}
