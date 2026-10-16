import MakoshCore
import MakoshVoiceCodec
import XCTest

@testable import MakoshWhatsApp

final class WhatsAppVoicePreparationTests: XCTestCase {
  func testVoicePreparationHasRealOpusBytesAndKeepsGroupPolicyOff() async throws {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"],
      let storage = ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"]
    else { throw XCTSkip("PG/S3 required") }
    let schema =
      "qa_whatsapp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let config = ContactWorkspaceConfiguration(connectionString: connection, schema: schema)
    let keys: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x79, count: 32) }
    let repository = WhatsAppRepository(configuration: config, keyProvider: keys)
    let account = WhatsAppAccount(name: "Voice")
    try await repository.saveAccount(account)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = WhatsAppFiles(
      configuration: config, storageFile: URL(fileURLWithPath: storage), spool: root,
      repository: repository, keyProvider: keys)
    let samples = (0..<30000).map { Int16(sin(Double($0) * 0.04) * 8000) }
    let file = try await files.prepareVoice(
      samples: samples, accountID: account.id, chat: "group@g.us")
    XCTAssertEqual(file.voice, true)
    XCTAssertEqual(file.record?.state, .local)
    let lease = try await files.open(file)
    defer { lease.remove() }
    let encoded = try Data(contentsOf: lease.url)
    XCTAssertEqual(encoded.prefix(4), Data("OggS".utf8))
    let decoded = try await RecordedVoiceCodec.decodeRecording(encoded)
    XCTAssertEqual(decoded.count, samples.count)
  }
}

extension WhatsAppVoicePreparationTests {
  func testRecordingLimitKeepsFirstSamplesAndCancellationClearsTheBuffer() {
    var recording = WhatsAppVoiceSamples(limit: 1000)
    recording.append(Array(repeating: 1, count: 700))
    recording.append(Array(repeating: 2, count: 700))
    XCTAssertEqual(recording.count, 1000)
    XCTAssertTrue(recording.full)
    recording.append(Array(repeating: 3, count: 700))
    let retained = recording.take()
    XCTAssertEqual(retained, Array(repeating: 1, count: 700) + Array(repeating: 2, count: 300))
    recording.append([4, 5])
    recording.clear()
    XCTAssertEqual(recording.count, 0)
    XCTAssertTrue(recording.take().isEmpty)
  }
}
