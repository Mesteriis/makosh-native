import Foundation
import XCTest
@testable import MakoshFiles

final class PaperlessSendOptionsTests: XCTestCase {
    private let connection = PaperlessConnection(
        name: "Docs", baseURL: URL(string: "https://doc.example")!, defaultDocumentType: 4, defaultTags: [1, 2])

    func testDefaultTitleStripsExtensionAndTrimsTo128() {
        let short = PaperlessUpload.defaults(for: FileHandoff(name: "Счёт за ноябрь.pdf") { _ in }, connection: connection)
        XCTAssertEqual(short.title, "Счёт за ноябрь")
        let long = PaperlessUpload.defaults(
            for: FileHandoff(name: String(repeating: "д", count: 200) + ".pdf") { _ in }, connection: connection)
        XCTAssertEqual(long.title.count, 128)
        let bare = PaperlessUpload.defaults(for: FileHandoff(name: ".hidden") { _ in }, connection: connection)
        XCTAssertEqual(bare.title, ".hidden", "a name that is only an extension stays as it is")
        let empty = PaperlessUpload.defaults(for: FileHandoff(name: "   ") { _ in }, connection: connection)
        XCTAssertEqual(empty.title, "Документ")
    }

    func testDefaultsTakeConnectionTypeTagsAndHandoffDate() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let options = PaperlessUpload.defaults(for: FileHandoff(name: "a.pdf", date: date) { _ in }, connection: connection)
        XCTAssertEqual(options.documentType, 4)
        XCTAssertEqual(options.tags, [1, 2])
        XCTAssertEqual(options.created, date)
        let plain = PaperlessUpload.defaults(
            for: FileHandoff(name: "a.pdf") { _ in }, connection: PaperlessConnection(name: "P", baseURL: URL(string: "https://p.example")!)
        )
        XCTAssertNil(plain.documentType)
        XCTAssertEqual(plain.tags, [])
        XCTAssertNil(plain.created)
    }
}
