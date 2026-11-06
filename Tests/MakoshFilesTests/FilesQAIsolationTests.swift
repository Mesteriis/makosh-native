import Foundation
import MakoshCore
import XCTest
@testable import MakoshFiles

final class FilesQAIsolationTests: XCTestCase {
    private let arguments = ["/Applications/Makosh", "--files-synthetic-preview", "--database-config", "/tmp/qa.json"]
    private func configuration(schema: String = "qa_files_preview", host: String = "127.0.0.1") -> ContactWorkspaceConfiguration {
        .init(
            connectionString: "host=\(host) hostaddr=127.0.0.1 port=5432 dbname=makosh user=makosh", schema: schema, archiveSchema: schema)
    }

    func testValidateRequiresFlagAbsoluteConfigAndQAFilesSchemas() {
        XCTAssertNoThrow(try FilesQAIsolation.validate(configuration: configuration(), arguments: arguments))
        XCTAssertThrowsError(try FilesQAIsolation.validate(configuration: configuration(schema: "makosh"), arguments: arguments))
        XCTAssertThrowsError(try FilesQAIsolation.validate(configuration: configuration(schema: "qa_ai_preview"), arguments: arguments))
        XCTAssertThrowsError(try FilesQAIsolation.validate(configuration: configuration(host: "db.example.com"), arguments: arguments))
        XCTAssertThrowsError(
            try FilesQAIsolation.validate(
                configuration: configuration(),
                arguments: ["/Applications/Makosh", "--files-synthetic-preview", "--database-config", "qa.json"]))
        XCTAssertThrowsError(
            try FilesQAIsolation.validate(configuration: configuration(), arguments: arguments + ["--telegram-synthetic-preview"]))
    }

    func testSyntheticSeedProducesSixItemsAcrossCategoriesOnce() async throws {
        let db = try filesDatabase(), store = try archiveStore(db)
        try FilesSyntheticSeed.seed(store)
        try FilesSyntheticSeed.seed(store)
        let items = try await FileCatalogue(connectionString: db.connectionString, schema: db.schema) { _, _ in filesTestKey }.refresh(
            resolver: nil)
        XCTAssertEqual(items.count, 6, "seeding twice adds nothing")
        XCTAssertEqual(Set(items.map(\.service)), ["mail", "telegram", "whatsapp", "teams"])
        XCTAssertTrue(Set(items.map(\.category)).isSuperset(of: [.document, .image, .archive]))
        XCTAssertTrue(items.allSatisfy { $0.messageDate != nil && $0.author != nil }, "every seeded file has its message")
    }
}
