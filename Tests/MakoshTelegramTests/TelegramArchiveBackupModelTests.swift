import XCTest
@testable import MakoshCore
@testable import MakoshApp

@MainActor final class TelegramArchiveBackupModelTests: XCTestCase {
    private var context: TelegramArchiveBackupContext {
        .init(connectionString: "unused-synthetic", schema: "qa_telegram_dossier_source", storageFile: nil,
            keys: .init(lookup: { _ in Data(repeating: 0x51, count: 32) }, install: { _, _ in }), synthetic: true)
    }
    func testSuggestedArchiveNameIsImmediatelyValidForOrdinaryAndSyntheticRecovery() throws {
        let id = try XCTUnwrap(UUID(uuidString: "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF"))
        for (configuration, expected) in [(nil, "makosh_restored_abcdefabcdef"), (Optional(context), "qa_telegram_dossier_r_abcdefabcdef")] {
            let model = TelegramArchiveBackupModel(context: configuration, restoreID: id)
            XCTAssertEqual(model.targetSchema, expected)
            XCTAssertTrue(ArchiveBackup.isValidSchemaName(model.targetSchema))
            XCTAssertFalse(model.canRestore, "A valid name still requires an inspected backup")
        }
    }
    func testAnUninspectedCallerCannotForgeTheRestoreConfirmation() {
        let model = TelegramArchiveBackupModel(context: context)
        model.targetSchema = "qa_telegram_dossier_destination"
        let receipt = ArchiveBackupInspection(summary: .init(vaultID: UUID(), messageVersions: 1, files: 0, encryptedBytes: 0, databaseBytes: 1),
            fingerprint: String(repeating: "a", count: 64))
        model.restore(confirmed: receipt, schema: model.targetSchema)
        XCTAssertFalse(model.busy); XCTAssertNil(model.restoredSchema)
        XCTAssertEqual(model.status, "Выберите копию и отдельный ключ для проверки.")
    }
}
