import XCTest
@testable import MakoshFiles

final class FilesFailureTests: XCTestCase {
    func testFailureMessagesAreRussianAndNeverContainTokens() {
        XCTAssertEqual(FilesFailure.unauthorized.errorDescription, "Paperless не принял токен. Проверьте токен в настройках подключения.")
        XCTAssertEqual(FilesFailure.tooLarge.errorDescription, "Сервер не принимает файл такого размера.")
        XCTAssertEqual(FilesFailure.duplicate(existingID: 120).errorDescription, "Такой документ уже есть в Paperless (#120).")
        XCTAssertEqual(FilesFailure.duplicate(existingID: nil).errorDescription, "Такой документ уже есть в Paperless.")
        XCTAssertEqual(FilesFailure.rejected(status: 500, reason: "boom").errorDescription, "Paperless отклонил запрос (500): boom")
        XCTAssertEqual(FilesFailure.rejected(status: 302, reason: "").errorDescription, "Paperless отклонил запрос (302).")
        XCTAssertEqual(FilesFailure.unreachable("timedOut").errorDescription, "Paperless недоступен (timedOut).")
        XCTAssertEqual(FilesFailure.storageMissing.errorDescription, "Подключение удалено. Файл не отправлен.")
        for failure: FilesFailure in [.archiveUnavailable, .integrity, .keyUnavailable, .invalidConnection, .unexpectedResponse] {
            let text = failure.errorDescription ?? ""
            XCTAssertFalse(text.isEmpty)
            XCTAssertTrue(text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }, "Russian text: \(text)")
        }
    }

    func testSubmissionStateTitles() {
        XCTAssertEqual(PaperlessSubmission.State.uploading.title, "Загружается…")
        XCTAssertEqual(PaperlessSubmission.State.processing.title, "Обрабатывается…")
        XCTAssertEqual(PaperlessSubmission.State.accepted(documentID: 123).title, "Документ принят · #123")
        XCTAssertEqual(PaperlessSubmission.State.accepted(documentID: nil).title, "Документ принят")
        XCTAssertEqual(PaperlessSubmission.State.duplicate(existingID: 120).title, "Такой документ уже есть в Paperless (#120).")
        XCTAssertEqual(PaperlessSubmission.State.failed(reason: "x").title, "Не отправлено: x")
        XCTAssertEqual(PaperlessSubmission.State.unknown.title, "Результат неизвестен — проверьте в Paperless")
    }
}
