# Раздел «Файлы» и Paperless — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Раздел «Файлы» с каталогом всех сохранённых в архив вложений, подключение Paperless-ngx (просмотр и загрузка) и действие «Отправить в Paperless…» у каждого видимого файла.

**Architecture:** Новый модуль `MakoshFiles` (над `MakoshCore`): актор `FileCatalogue` читает `archive_file_events` курсором и дополняет записи датой/автором из `archive_events`; `PaperlessClient` — REST-клиент на `URLSession` без редиректов; `PaperlessSender` ведёт журнал отправок в файле; `FilesWorkspaceModel` (MainActor) держит состояние раздела. Приложение добавляет `Destination.files`, представления раздела, лист отправки, вкладку настроек и пункт меню `FileSendMenu` в четырёх существующих местах показа файла.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI/AppKit, QuickLookUI, PostgreSQL через `MessageArchiveStore`, XCTest c `URLProtocol`-заглушкой и реальным PostgreSQL (`MAKOSH_TEST_DATABASE_URL`).

**Spec:** `docs/superpowers/specs/2026-11-06-files-section-paperless-design.md`

## Global Constraints

- macOS 26+, Swift 6 strict concurrency; MainActor только для состояния UI, сеть/SQL/крипто/файлы — на акторах и `BackgroundWork.run`.
- Таблицы PostgreSQL не меняются и остаются только дописываемыми; допустим один индекс `archive_message_sequence`.
- Paperless: HTTPS (http только loopback), редиректы не выполняются, учётные данные в URL запрещены; заголовок `Authorization: Token …`; `Accept: application/json; version=9`, на `406` повтор без версии; предел загрузки 512 МиБ; `413` — отказ «сервер не принимает файл такого размера»; дубликат — не ошибка.
- Токен только в Связке ключей (`org.makosh.files.tokens.v1`); никогда в UserDefaults, логах, текстах ошибок, Git.
- Никаких автоматических повторов отправки; опрос задачи каждые 2 с до 3 минут.
- Каталог исключает `rfc822-source`, оставляет одну (последнюю) запись на (identity, attachmentID), читает пачками по 200.
- Все строки UI — по-русски, в стиле существующих разделов; доступность через `accessibilityIdentifier` с префиксом `files.`.
- Коммиты с `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`; форматировать только изменённые файлы (`scripts/format.sh HEAD`).

## Review Focus

1. Повреждённая или чужая строка `archive_file_events` при чтении каталога — ошибка целостности видна пользователю, каталог не показывает частичные данные молча (тест в Задаче 2).
2. Ответ Paperless без `Content-Type: application/json` или с HTML (страница входа nginx) — клиент сообщает «неожиданный ответ», не падает на разборе (тест в Задаче 4).
3. Перезапуск Макоша во время «обрабатывается» — после старта задача дозапрашивается по `taskID`, состояние не теряется и файл не отправляется повторно (тест в Задаче 5).
4. Смена выбранного источника во время загрузки каталога/документов — поздний результат не попадает в другой источник (тест в Задаче 6).
5. Удалённое подключение Paperless при открытом листе отправки — отправка отклоняется с понятным текстом, токен удалён из Связки ключей (тест в Задаче 3 и 6).

---

### Task 1: Чтение файловых событий и последней версии сообщения из архива

**Files:**
- Modify: `Sources/MakoshCore/MessageArchiveStore.swift` (индексы около строки 129; новые методы рядом с `files(identity:attachmentID:)`)
- Modify: `Sources/MakoshCore/MessageArchiveModels.swift` (новый тип `ArchiveFileEvent`)
- Test: `Tests/MakoshCoreTests/MessageArchiveStoreTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ArchiveFileEvent: Equatable, Sendable { public let sequence: Int64; public let record: ArchiveFileRecord }
  extension MessageArchiveStore {
      /// Oldest first, only `stored` rows; `limit` 1...200.
      public func fileEvents(after sequence: Int64, limit: Int) throws -> [ArchiveFileEvent]
      /// The newest archive observation of that message, or nil.
      public func latestRecord(identity: MessageArchiveIdentity) throws -> MessageArchiveRecord?
  }
  ```
- Индекс при инициализации: `CREATE INDEX IF NOT EXISTS archive_message_sequence ON <prefix>archive_events(message_token,sequence DESC)`.

- [ ] **Step 1: Написать падающие тесты**

```swift
func testFileEventsPageOldestFirstAndOnlyStored() throws {
    // store с тестовым keyProvider { _, _ in Data(repeating: 0x42, count: 32) };
    // три записи: A pending+stored, B stored, C pending — через appendFile как в
    // ArchiveBackupTests.swift:136-148 (@testable для ArchiveFileEnvelopeReceipt).
    let page = try store.fileEvents(after: 0, limit: 200)
    XCTAssertEqual(page.map(\.record.id), [a.id, b.id])
    XCTAssertEqual(try store.fileEvents(after: page[0].sequence, limit: 200).map(\.record.id), [b.id])
    XCTAssertThrowsError(try store.fileEvents(after: 0, limit: 0))
}
func testFileEventsTamperedRowIsIntegrityError() throws {
    // UPDATE через db.execute напрямую запрещён триггером — вставить строку с чужим ciphertext
    // INSERT INTO archive_file_events(object,state,attachment_token,ciphertext) VALUES(gen_random_uuid(),'stored','x','AAAA')
    XCTAssertThrowsError(try store.fileEvents(after: 0, limit: 200)) { XCTAssertEqual($0 as? MessageArchiveError, .integrity) }
}
func testLatestRecordReturnsNewestVersionOfThatMessageOnly() throws {
    // две версии сообщения M (text "v1", "v2") и одно сообщение N
    XCTAssertEqual(try store.latestRecord(identity: m)?.observation.event, .message(v2))
    XCTAssertNil(try store.latestRecord(identity: MessageArchiveIdentity(service: "x", accountID: "1", conversationID: "c", messageID: "none")))
}
func testMessageSequenceIndexExists() throws {
    XCTAssertEqual(try db.execute("SELECT 1 FROM pg_indexes WHERE schemaname='\(db.schema)' AND indexname='archive_message_sequence'").count, 1)
}
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `scripts/test.sh --filter MessageArchiveStoreTests`
Expected: FAIL — `fileEvents`, `latestRecord` не существуют (ошибка компиляции), индекс не найден.

- [ ] **Step 3: Реализовать методы и индекс**

`fileEvents`: `SELECT sequence,object,state,ciphertext FROM …archive_file_events WHERE state='stored' AND sequence>$1 ORDER BY sequence LIMIT $2`, расшифровка как в `files(identity:attachmentID:)` (AAD `file-<OBJECT UPPER>-<state>`), проверка `record.id`/`state`, иначе `.integrity`. `latestRecord`: `SELECT sequence,message_token,ciphertext FROM …archive_events WHERE message_token=$1 ORDER BY sequence DESC LIMIT 1` c `token([service,accountID,conversationID,messageID])` и проверкой токена как в `readRecords`.

- [ ] **Step 4: Прогнать тесты**

Run: `scripts/test.sh --filter MessageArchiveStoreTests`
Expected: PASS, все существующие тесты ядра зелёные.

- [ ] **Step 5: Коммит**

```bash
git add Sources/MakoshCore Tests/MakoshCoreTests/MessageArchiveStoreTests.swift
git commit -m "Read archive file events and the latest message version by identity"
```

### Task 2: Модуль MakoshFiles и каталог архива

**Files:**
- Modify: `Package.swift` (цели `MakoshFiles` → `["MakoshCore","CPostgres"]`, `MakoshFilesTests` → `["MakoshFiles","MakoshCore","CPostgres"]`; библиотека `MakoshFiles`; `MakoshApp` зависит от `MakoshFiles`)
- Create: `Sources/MakoshFiles/FileCatalogue.swift`, `Sources/MakoshFiles/FilesFailure.swift`
- Create: `Tests/MakoshFilesTests/FilesTestSupport.swift` (копия `PostgresTestDatabase` без `ContactStore`: только `connectionString`, `schema` c префиксом `makosh_test_`, `execute`, `cleanup`), `Tests/MakoshFilesTests/FileCatalogueTests.swift`

**Interfaces:**
- Consumes: `MessageArchiveStore.fileEvents(after:limit:)`, `latestRecord(identity:)`, `MessageArchiveKeychain.open`.
- Produces:
  ```swift
  public enum FileCategory: String, CaseIterable, Sendable { case document, image, video, audio, archive, other }
  public struct FileCatalogueItem: Identifiable, Equatable, Sendable {
      public let id: UUID                 // record.id
      public let record: ArchiveFileRecord
      public let name: String             // record.attachment.name
      public let byteCount: Int64         // plaintextByteCount
      public let service: String
      public let messageDate: Date?       // из latestRecord, иначе nil
      public let author: String?
      public var sourceTitle: String?     // заполняет FileSourceResolving
      public var date: Date { messageDate ?? record.capturedAt }
      public var category: FileCategory   // по расширению имени; "photo"/"image" kind → image
  }
  public protocol FileSourceResolving: Sendable {
      /// Title of a chat or letter for a file; nil when unknown.
      func sourceTitle(for identity: MessageArchiveIdentity) async -> String?
  }
  public actor FileCatalogue {
      public init(connectionString: String, schema: String, keyProvider: @escaping @Sendable (UUID, Bool) throws -> Data = MessageArchiveKeychain.open)
      /// Reads new events since the cursor; returns the whole deduplicated list (newest first).
      public func refresh(resolver: (any FileSourceResolving)?) async throws -> [FileCatalogueItem]
      public var items: [FileCatalogueItem] { get }
  }
  public enum FilesFailure: LocalizedError, Equatable {
      case archiveUnavailable, integrity, storageMissing, unauthorized, unreachable(String), rejected(status: Int, reason: String), tooLarge, duplicate(existingID: Int?), unexpectedResponse, invalidConnection, keyUnavailable
  }
  ```
  `FileCategory.classify(name:kind:)` — статическая функция: pdf/doc/docx/xls/xlsx/ppt/pptx/txt/md/rtf/csv/odt → document; jpg/jpeg/png/gif/heic/webp/tiff/bmp или kind "photo"/"image" → image; mp4/mov/mkv/avi/webm или kind "video" → video; mp3/m4a/ogg/opus/wav/flac или kind "audio"/"voice" → audio; zip/rar/7z/tar/gz → archive.

- [ ] **Step 1: Написать падающие тесты**

```swift
func testCatalogueListsStoredFilesNewestFirstWithoutRawLetterCopies() async throws {
    // в MessageArchiveStore тестовой схемы: записи A (telegram, capturedAt 10), B (mail, attachment.id "rfc822-source"), C (mail, "0", capturedAt 20)
    let items = try await catalogue.refresh(resolver: nil)
    XCTAssertEqual(items.map(\.id), [c.id, a.id])
}
func testOneRowPerAttachmentKeepsLatestRecord() async throws { /* два stored для одного (identity, attachmentID) → остаётся второй */ }
func testMessageDateAndAuthorComeFromArchiveEvents() async throws {
    // append observation для identity A с date 1700000000, author "Иван"; для C — без observation
    XCTAssertEqual(items.first { $0.id == a.id }?.messageDate, Date(timeIntervalSince1970: 1_700_000_000))
    XCTAssertEqual(items.first { $0.id == a.id }?.author, "Иван")
    XCTAssertEqual(items.first { $0.id == c.id }?.date, c.capturedAt)
}
func testRefreshContinuesFromCursorAndKeepsEarlierItems() async throws { /* refresh, appendFile ещё одну, refresh → 3 элемента, новая первая */ }
func testResolverFillsSourceTitles() async throws { /* заглушка возвращает "Мария" для identity A */ }
func testTamperedRowSurfacesIntegrityFailure() async throws { /* строка с мусором → FilesFailure.integrity */ }
func testCategoryByExtensionAndKind() {
    XCTAssertEqual(FileCategory.classify(name: "Счёт.PDF", kind: "document"), .document)
    XCTAssertEqual(FileCategory.classify(name: "file", kind: "photo"), .image)
    XCTAssertEqual(FileCategory.classify(name: "x.bin", kind: "file"), .other)
}
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `scripts/test.sh --filter MakoshFilesTests`
Expected: FAIL — цель не существует / типы не найдены.

- [ ] **Step 3: Добавить цели в Package.swift и реализовать каталог**

`refresh`: цикл `fileEvents(after: cursor, limit: 200)` до короткой страницы; на каждую запись `latestRecord(identity:)` (`.message` → date/author; иначе nil); словарь по ключу `"\(service)|\(accountID)|\(conversationID)|\(messageID)|\(attachment.id)"` → последняя запись; `MessageArchiveError.integrity` → `FilesFailure.integrity`, `.keyUnavailable` → `.keyUnavailable`, прочие → `.archiveUnavailable`. Отсутствующая таблица/схема (`.database` при первом открытии) → пустой список без ошибки, если схема не существует (проверка `SELECT 1 FROM pg_namespace`), иначе ошибка.

- [ ] **Step 4: Прогнать тесты**

Run: `scripts/test.sh --filter MakoshFilesTests`
Expected: PASS 7/7.

- [ ] **Step 5: Коммит**

```bash
git add Package.swift Sources/MakoshFiles Tests/MakoshFilesTests
git commit -m "Add the MakoshFiles module with the archive file catalogue"
```

### Task 3: Подключения хранилищ и токены

**Files:**
- Create: `Sources/MakoshFiles/FileStorage.swift`
- Test: `Tests/MakoshFilesTests/FileStorageTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct PaperlessConnection: Codable, Equatable, Identifiable, Sendable {
      public let id: UUID; public var name: String; public var baseURL: URL
      public var defaultDocumentType: Int?; public var defaultTags: [Int]
      public init(id: UUID = UUID(), name: String, baseURL: URL, defaultDocumentType: Int? = nil, defaultTags: [Int] = [])
      public func validated() throws -> PaperlessConnection   // как AIConnection.validated: https, http только loopback, без user/password/query/fragment, name 1...80; хвостовой "/" убирается
  }
  public enum FileStorageConnection: Codable, Equatable, Identifiable, Sendable { case paperless(PaperlessConnection); public var id: UUID }
  public struct FileStorageKeychainAccess: Sendable { /* read/write/remove по UUID, как AIKeychainAccess; system = сервис "org.makosh.files.tokens.v1" */ }
  public actor FileStorageTokenVault {
      public init(access: FileStorageKeychainAccess? = nil)
      public func load(connectionID: UUID) throws -> String?
      public func save(_ token: String, connectionID: UUID) throws   // пусто → remove; лимит 16 КиБ
      public func remove(connectionID: UUID) throws
  }
  public final class FileStorageRegistry: @unchecked Sendable {
      public static let key = "makosh.files.storages.v1"
      public init(defaults: UserDefaults = .standard, vault: FileStorageTokenVault)
      public func connections() -> [FileStorageConnection]
      public func save(_ connection: FileStorageConnection, token: String?) async throws   // validated(); token nil → без изменений
      public func remove(_ id: UUID) async throws        // удаляет и токен
  }
  ```

- [ ] **Step 1: Написать падающие тесты**

```swift
func testValidationRejectsHTTPCredentialsAndTrailingSlash() throws {
    XCTAssertThrowsError(try PaperlessConnection(name: "P", baseURL: URL(string: "http://doc.example")!).validated())
    XCTAssertThrowsError(try PaperlessConnection(name: "P", baseURL: URL(string: "https://u:p@doc.example")!).validated())
    XCTAssertEqual(try PaperlessConnection(name: " P ", baseURL: URL(string: "https://doc.example/")!).validated().baseURL.absoluteString, "https://doc.example")
    XCTAssertNoThrow(try PaperlessConnection(name: "L", baseURL: URL(string: "http://127.0.0.1:8000")!).validated())
}
func testRegistryRoundTripsWithoutTokenInDefaults() async throws {
    // UserDefaults(suiteName: UUID) + фальшивый keychain в памяти
    try await registry.save(.paperless(connection), token: "secret-token")
    XCTAssertEqual(registry.connections(), [.paperless(connection)])
    XCTAssertFalse(String(data: defaults.data(forKey: FileStorageRegistry.key)!, encoding: .utf8)!.contains("secret-token"))
    XCTAssertEqual(try await vault.load(connectionID: connection.id), "secret-token")
}
func testSaveWithNilTokenKeepsExistingToken() async throws { … }
func testRemoveDeletesConnectionAndToken() async throws { … XCTAssertNil(try await vault.load(connectionID: id)) }
func testCorruptDefaultsYieldEmptyList() { defaults.set(Data("garbage".utf8), forKey: key); XCTAssertEqual(registry.connections(), []) }
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `scripts/test.sh --filter FileStorageTests`
Expected: FAIL — типы не найдены.

- [ ] **Step 3: Реализовать `FileStorage.swift`** по образцу `AIConnection.validated()` и `AITokenVault`.

- [ ] **Step 4: Прогнать тесты**

Run: `scripts/test.sh --filter FileStorageTests`
Expected: PASS 5/5.

- [ ] **Step 5: Коммит**

```bash
git add Sources/MakoshFiles/FileStorage.swift Tests/MakoshFilesTests/FileStorageTests.swift
git commit -m "Store file storage connections with tokens in the Keychain"
```

### Task 4: Клиент Paperless

**Files:**
- Create: `Sources/MakoshFiles/PaperlessClient.swift`
- Test: `Tests/MakoshFilesTests/PaperlessStub.swift` (копия `AIStubProtocol` из `Tests/MakoshAITests/AIClientTests.swift` с очередью ответов `[Reply]` и захватом запросов/тел), `Tests/MakoshFilesTests/PaperlessClientTests.swift`

**Interfaces:**
- Consumes: `PaperlessConnection`, `FilesFailure`.
- Produces:
  ```swift
  public struct PaperlessStatus: Equatable, Sendable { public let documentCount: Int; public let version: String? }   // X-Version
  public struct PaperlessNamed: Codable, Equatable, Identifiable, Sendable { public let id: Int; public let name: String }
  public struct PaperlessDocument: Equatable, Identifiable, Sendable {
      public let id: Int; public let title: String; public let created: Date?; public let documentType: Int?; public let tags: [Int]; public let originalFileName: String?
  }
  public struct PaperlessPage<T: Sendable>: Sendable { public let items: [T]; public let hasMore: Bool }
  public enum PaperlessTaskState: Equatable, Sendable { case pending, started, success(documentID: Int?), failure(message: String) }
  public struct PaperlessUpload: Sendable { public var title: String; public var created: Date?; public var documentType: Int?; public var tags: [Int] }
  public actor PaperlessClient {
      public static let apiVersion = 9
      public static let uploadLimit: Int64 = 512 * 1024 * 1024
      public init(connection: PaperlessConnection, token: String, session: URLSession = …)   // session без редиректов (delegate возвращает nil)
      public func status() async throws -> PaperlessStatus
      public func tags() async throws -> [PaperlessNamed]
      public func documentTypes() async throws -> [PaperlessNamed]
      public func documents(query: String, page: Int) async throws -> PaperlessPage<PaperlessDocument>   // page_size=50, ordering=-created
      public func download(id: Int, original: Bool, to destination: URL) async throws
      public func upload(file: URL, name: String, options: PaperlessUpload) async throws -> String   // taskID
      public func task(id: String) async throws -> PaperlessTaskState
      public func documentURL(id: Int) -> URL   // baseURL/documents/<id>/details
  }
  ```
  Правила: заголовок `Accept: application/json; version=9`; ответ `406` → тот же запрос без версии (один раз); `401`/`403` → `.unauthorized`; `413` → `.tooLarge`; прочие 4xx/5xx → `.rejected(status, reason)` с `detail`/`error` JSON до 160 символов, без токена; сетевая ошибка → `.unreachable(code)`; тело не JSON или не ожидаемой формы → `.unexpectedResponse`. `created` читается как `yyyy-MM-dd` или ISO8601. Результат задачи со строкой, содержащей `duplicate` → `.failure`, а `upload`/`task` в отправителе распознаёт её как дубликат (Задача 5). Загрузка: multipart поля `document` (имя файла), `title`, `created` (`yyyy-MM-dd`), `document_type`, `tags` (повторяющееся поле); тело стримится из временного файла, лимит `uploadLimit`.

- [ ] **Step 1: Написать падающие тесты**

```swift
func testStatusSendsTokenAndVersionAndReadsCount() async throws   // Authorization: Token t; Accept содержит version=9; {"count":1115} + X-Version: 3.0.5
func testNotAcceptableRetriesOnceWithoutVersion() async throws      // 406 затем 200 → второй запрос без "version="
func testDocumentsParseDateOnlyAndDateTimeCreated() async throws   // results с "created":"2026-11-05" и "2026-11-05T10:00:00+01:00"; next != null → hasMore
func testUploadBuildsMultipartAndReturnsTaskID() async throws      // тело содержит name="document"; filename="Счёт.pdf", name="title", name="tags" дважды; ответ "\"7f…\"" → taskID
func testTaskStatesIncludingDuplicateMessage() async throws        // SUCCESS+related_document 123 → .success(123); FAILURE "…: It is a duplicate of Счёт.pdf (#120)" → .failure(message)
func testUnauthorizedTooLargeRejectedUnreachable() async throws     // 401 → .unauthorized; 413 → .tooLarge; 500 {"detail":"boom"} → .rejected(500,"boom"); fail → .unreachable
func testHTMLResponseIsUnexpectedNotCrash() async throws            // 200 text/html "<html>login" → .unexpectedResponse
func testRedirectIsNotFollowed() async throws                        // 302 Location другой хост → ошибка, второй хост не запрошен
func testUploadOverLimitIsRejectedBeforeRequest() async throws      // файл-заглушка с размером > лимита через resourceValues? — создать sparse-файл truncate(512 MiB+1) → .tooLarge, запросов 0
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `scripts/test.sh --filter PaperlessClientTests`
Expected: FAIL — `PaperlessClient` не найден.

- [ ] **Step 3: Реализовать `PaperlessClient.swift`** (URLSession с `URLSessionTaskDelegate.willPerformHTTPRedirection → nil`, `URLProtocol`-инъекция через `URLSessionConfiguration.protocolClasses` в тестах).

- [ ] **Step 4: Прогнать тесты**

Run: `scripts/test.sh --filter PaperlessClientTests`
Expected: PASS 9/9.

- [ ] **Step 5: Коммит**

```bash
git add Sources/MakoshFiles/PaperlessClient.swift Tests/MakoshFilesTests/Paperless*.swift
git commit -m "Add the Paperless REST client"
```

### Task 5: Передача файла и журнал отправок в Paperless

**Files:**
- Create: `Sources/MakoshFiles/FileHandoff.swift`, `Sources/MakoshFiles/PaperlessSender.swift`
- Test: `Tests/MakoshFilesTests/PaperlessSenderTests.swift`

**Interfaces:**
- Consumes: `PaperlessClient`, `FileStorageRegistry`, `FileStorageTokenVault`.
- Produces:
  ```swift
  public struct FileHandoff: Sendable {
      public let name: String; public let byteCount: Int64?; public let date: Date?
      public let produce: @Sendable (URL) async throws -> Void     // пишет файл по URL (каталог существует, файла нет)
      public init(name: String, byteCount: Int64? = nil, date: Date? = nil, produce: @escaping @Sendable (URL) async throws -> Void)
  }
  public struct PaperlessSubmission: Codable, Equatable, Identifiable, Sendable {
      public enum State: Codable, Equatable, Sendable { case uploading, processing, accepted(documentID: Int?), duplicate, failed(reason: String), unknown }
      public let id: UUID; public let connectionID: UUID; public let fileName: String; public let title: String
      public var taskID: String?; public var state: State; public let startedAt: Date; public var updatedAt: Date
  }
  public actor PaperlessSender {
      public static let pollInterval: Duration = .seconds(2), pollLimit: Duration = .seconds(180)
      public init(registry: FileStorageRegistry, vault: FileStorageTokenVault, journal: URL, clientFactory: @escaping @Sendable (PaperlessConnection, String) -> PaperlessClient = { PaperlessClient(connection: $0, token: $1) }, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
      public func submissions() -> [PaperlessSubmission]
      /// Exports through the handoff into a private 0700 directory, uploads, polls; every state change is written to the journal before it is returned.
      public func send(_ handoff: FileHandoff, to connectionID: UUID, options: PaperlessUpload, progress: @Sendable (PaperlessSubmission) -> Void) async -> PaperlessSubmission
      /// Re-queries processing/unknown submissions that have a task ID.
      public func resume() async
      public func check(_ id: UUID) async -> PaperlessSubmission?
  }
  ```
  Журнал: JSON-массив, запись через временный файл + `rename`, права 0600; при повреждении — пустой журнал и ошибка в `lastJournalFailure`. Распознавание дубликата: `.failure(message)` содержит `duplicate` (без учёта регистра) → `.duplicate`. Отсутствие ответа на `upload` (`.unreachable`) после отправки тела → `.unknown`; ошибка до отправки (экспорт, токен, лимит) → `.failed(reason)`.

- [ ] **Step 1: Написать падающие тесты**

```swift
func testSendUploadsPollsAndRecordsAccepted() async throws     // фабрика с заглушкой клиента: upload → "t1"; task: pending, started, success(5) → состояния uploading, processing, accepted(5); журнал содержит accepted
func testDuplicateFailureBecomesDuplicateState() async throws
func testUnreachableAfterUploadIsUnknownAndNeverResent() async throws   // upload бросает .unreachable → .unknown; второй send не вызывается сам; количество upload == 1
func testPollLimitLeavesProcessingWithTaskID() async throws    // task всегда pending, sleep считает время → после 180 с состояние processing, taskID сохранён
func testResumeRequeriesProcessingAfterRestart() async throws  // журнал с processing t1 → новый sender.resume() → task success(9) → accepted(9), upload не вызывался
func testCorruptJournalDoesNotCrashAndStartsEmpty() async throws
func testMissingTokenFailsBeforeExport() async throws           // produce не вызывается
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `scripts/test.sh --filter PaperlessSenderTests`
Expected: FAIL — типы не найдены.

- [ ] **Step 3: Реализовать `FileHandoff.swift` и `PaperlessSender.swift`** (клиент за протоколом `PaperlessServing` с `upload`/`task`, чтобы заглушка в тестах не ходила в сеть; `PaperlessClient: PaperlessServing`).

- [ ] **Step 4: Прогнать тесты**

Run: `scripts/test.sh --filter PaperlessSenderTests`
Expected: PASS 7/7.

- [ ] **Step 5: Коммит**

```bash
git add Sources/MakoshFiles/FileHandoff.swift Sources/MakoshFiles/PaperlessSender.swift Tests/MakoshFilesTests/PaperlessSenderTests.swift
git commit -m "Send files to Paperless with a durable submission journal"
```

### Task 6: Модель раздела «Файлы»

**Files:**
- Create: `Sources/MakoshFiles/Presentation/FilesWorkspaceModel.swift`
- Test: `Tests/MakoshFilesTests/FilesWorkspaceModelTests.swift`

**Interfaces:**
- Consumes: `FileCatalogue`, `FileStorageRegistry`, `PaperlessSender`, `PaperlessClient` (через `PaperlessServing` + `documents`/`status`/`tags`/`documentTypes`/`download` — расширить протокол), `FileSourceResolving`.
- Produces:
  ```swift
  public enum FilesSource: Hashable, Sendable { case all, service(String), storage(UUID) }
  public enum FilesSort: Sendable { case dateDescending, name }
  @MainActor public final class FilesWorkspaceModel: ObservableObject {
      @Published public var source: FilesSource = .all { didSet { generation += 1; reloadSelection() } }
      @Published public var search = ""; @Published public var category: FileCategory? = nil; @Published public var sort: FilesSort = .dateDescending
      @Published public private(set) var items: [FileCatalogueItem] = []
      @Published public private(set) var visible: [FileCatalogueItem] = []            // поиск/фильтр/сортировка; ё/е и регистр как AIContextRanking
      @Published public private(set) var connections: [FileStorageConnection] = []
      @Published public private(set) var storageStatus: [UUID: Result<PaperlessStatus, FilesFailure>] = [:]
      @Published public private(set) var documents: [PaperlessDocument] = []; @Published public private(set) var hasMoreDocuments = false
      @Published public private(set) var documentQuery = ""
      @Published public private(set) var loading = false; @Published public var error: String?
      @Published public private(set) var submissions: [PaperlessSubmission] = []
      public init(catalogue: FileCatalogue?, registry: FileStorageRegistry, vault: FileStorageTokenVault, sender: PaperlessSender, resolver: (any FileSourceResolving)?, clientFactory: …)
      public func refresh() async; public func startPolling() / stopPolling()   // каждые 30 с пока раздел открыт
      public func searchDocuments(_ query: String) async; public func loadMoreDocuments() async
      public func reloadConnections(); public func test(_ id: UUID) async
      public func send(_ handoff: FileHandoff, to connectionID: UUID, options: PaperlessUpload) async -> PaperlessSubmission
      public func lists(for connectionID: UUID) async -> (tags: [PaperlessNamed], types: [PaperlessNamed])?
      public func download(documentID: Int, from connectionID: UUID, to: URL) async throws
  }
  ```
  Каждая асинхронная загрузка запоминает `generation` и отбрасывает результат, если `source` изменился.

- [ ] **Step 1: Написать падающие тесты** (фальшивый источник каталога через новый протокол `FileCatalogueReading: Sendable { func refresh(resolver: (any FileSourceResolving)?) async throws -> [FileCatalogueItem] }`, которому соответствует `FileCatalogue`; фальшивый `PaperlessServing`; `init` модели принимает `catalogue: (any FileCatalogueReading)?`)

```swift
func testVisibleFiltersBySearchCategoryAndSort() async
func testServiceSourceShowsOnlyThatService() async
func testLateCatalogueResultForPreviousSourceIsDropped() async      // источник меняется во время refresh → items прежнего не применяются
func testStorageSourceLoadsDocumentsAndPages() async                // первая страница 50, hasMore, loadMore добавляет
func testTestConnectionRecordsStatusOrFailure() async
func testSendToRemovedConnectionFails() async                        // connection удалена между открытием листа и send → .failed("Подключение удалено")
func testPollingRefreshesWhileActiveOnly() async                     // инъекция таймера
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `scripts/test.sh --filter FilesWorkspaceModelTests`
Expected: FAIL.

- [ ] **Step 3: Реализовать модель.**

- [ ] **Step 4: Прогнать тесты**

Run: `scripts/test.sh --filter MakoshFilesTests`
Expected: PASS, весь модуль зелёный.

- [ ] **Step 5: Коммит**

```bash
git add Sources/MakoshFiles/Presentation Tests/MakoshFilesTests/FilesWorkspaceModelTests.swift
git commit -m "Add the Files workspace model"
```

### Task 7: Раздел «Файлы» в приложении: каталог, предпросмотр, сохранение

**Files:**
- Create: `Sources/MakoshApp/Files/FilesHost.swift`, `FilesSidebarView.swift`, `FilesDetailView.swift`, `FilePreviewLease.swift`, `FilePreviewView.swift`, `FileSourceBridge.swift`
- Modify: `Sources/MakoshApp/Workspace/WorkspaceView.swift` (`Destination.files = "Файлы"`, символ `folder`, между `.meetings` и `.ai`; `sectionSidebar`/`sectionDetail`; ширины `(280, 320, 390)`), `Sources/MakoshApp/MakoshApp.swift` (`delegate.files` как `environmentObject`)
- Test: `Tests/MakoshFilesTests/FilePreviewLeaseTests.swift` (аренда — в `MakoshFiles`, см. ниже)

**Interfaces:**
- `FilePreviewLease` живёт в `Sources/MakoshFiles/FilePreviewLease.swift` (`public final class FilePreviewLease: Sendable, Identifiable` по образцу `TelegramArchivedFilePreview.create(name:export:)`, но `export` — `@Sendable (URL) async throws -> Void`, без привязки к MainActor); `FilePreviewView` — копия `TelegramArchivedFilePreviewView` над `FilePreviewLease` с подписью «Сохранённая копия из архива Макоша».
- `FilesHost` (MainActor, `ObservableObject`): `model: FilesWorkspaceModel`, `registry`, `vault`, `sender`; `start(configuration: ContactWorkspaceConfiguration, storageFile: URL, spool: URL, resolver:)` создаёт `FileCatalogue` и `ArchiveFileRepository` (как `MailWorkspaceModel.worker`), вызывает `sender.resume()`; `WorkspaceView` вызывает его там же, где `ai.start(configuration:…)`, только при `ordinaryLaunch`, с `storageFile`/`spool`, вычисленными как в `WorkspaceModel.configureArchive`; `export(_ item: FileCatalogueItem, to: URL) async throws` → `repository.export(record, to:)`; `preview(_ item:) async throws -> FilePreviewLease`; `handoff(_ item:) -> FileHandoff`.
- `FileSourceBridge: FileSourceResolving` над `TelegramModel.aiContextChats`, `WhatsAppWorkspaceModel.chats`, `MailWorkspaceModel.letters` (ключ письма: `conversationID == base64(folder)`, `messageID == "\(uidValidity):\(uid)"` → тема и отправитель), `TeamsWorkspaceModel.chats` (`displayName`, если `conversationID` совпадает с `scope.storageKey` в hex/base64 — проверить формат `TeamsRepository.swift:58`). Чтение состояний моделей — на MainActor, результат возвращается актору.
- `FilesDetailView`: `Table(model.visible)` с колонками «Имя» (иконка категории + имя), «Откуда» (`sourceTitle ?? service`), «Размер», «Дата»; шапка: поиск, `Picker` категории, кнопка обновить; контекстное меню строки: «Посмотреть», «Сохранить как…» (`NSSavePanel`, как `MailViews.export`), «Открыть источник» (замыкание `openSource: (MessageArchiveIdentity) -> Void` из `WorkspaceView`: telegram → `destination = .telegram` + `telegram.open(chatID)` как в `openAICard`; whatsapp → аналогично; mail/teams → раздел), «Отправить в Paperless…» (Задача 9). Пустое состояние `ContentUnavailableView("Файлов пока нет", systemImage: "folder")`.
- `FilesSidebarView`: список источников + секция «Хранилища» с `+` (открывает редактор из Задачи 8) и строками подключений со статусом.

- [ ] **Step 1: Тест аренды предпросмотра**

```swift
func testLeaseCreatesPrivateFileAndRemovesDirectoryOnDeinit() async throws   // 0700/0600, расширение только ASCII ≤16, после освобождения каталога нет
func testLeaseExportFailureLeavesNoDirectory() async throws
```

- [ ] **Step 2: Убедиться, что тест падает** — Run: `scripts/test.sh --filter FilePreviewLeaseTests` — Expected: FAIL.

- [ ] **Step 3: Реализовать аренду, хост, представления и встроить раздел.**

- [ ] **Step 4: Проверка**

Run: `scripts/test.sh --filter FilePreviewLeaseTests && scripts/build-app.sh`
Expected: PASS 2/2; сборка приложения успешна.

- [ ] **Step 5: Коммит**

```bash
git add Sources/MakoshApp/Files Sources/MakoshApp/Workspace/WorkspaceView.swift Sources/MakoshApp/MakoshApp.swift Sources/MakoshFiles/FilePreviewLease.swift Tests/MakoshFilesTests/FilePreviewLeaseTests.swift
git commit -m "Add the Files section with the archive catalogue"
```

### Task 8: Настройки хранилищ и архив Paperless в разделе

**Files:**
- Create: `Sources/MakoshApp/Files/FilesSettingsView.swift` (список подключений, редактор: название, URL, `SecureField` токен «пусто — без изменений», тип документа и теги по умолчанию из `model.lists(for:)`, кнопки «Проверить», «Сохранить», «Удалить»), `Sources/MakoshApp/Files/PaperlessDocumentsView.swift`
- Modify: `Sources/MakoshApp/MakoshApp.swift` (вкладка `FilesSettingsView().tabItem { Label("Файлы", systemImage: "folder") }` после «Teams»), `FilesSidebarView.swift` (`+` → `sheet` с редактором; выбор строки хранилища → `model.source = .storage(id)`), `FilesDetailView.swift` (для `.storage` показывает `PaperlessDocumentsView`)

**Interfaces:**
- `PaperlessDocumentsView`: поле поиска (`onSubmit` → `model.searchDocuments`), `Table(model.documents)` «Название», «Дата», «Тип», «Теги» (названия из `lists(for:)`), «Ещё» при `hasMoreDocuments`; контекстное меню: «Посмотреть» (`model.download(documentID:from:to:)` в `FilePreviewLease`), «Сохранить как…» (оригинал), «Открыть в Paperless» (`NSWorkspace.shared.open(client.documentURL(id))`). Ошибки подключения — `ContentUnavailableView` с текстом `FilesFailure.errorDescription` и кнопкой «Повторить».

- [ ] **Step 1: Тест текстов ошибок** в `Tests/MakoshFilesTests/FilesFailureTests.swift`:

```swift
func testFailureMessagesAreRussianAndNeverContainTokens() {
    XCTAssertEqual(FilesFailure.unauthorized.errorDescription, "Paperless не принял токен. Проверьте токен в настройках подключения.")
    XCTAssertEqual(FilesFailure.tooLarge.errorDescription, "Сервер не принимает файл такого размера.")
    XCTAssertEqual(FilesFailure.duplicate(existingID: 120).errorDescription, "Такой документ уже есть в Paperless (#120).")
    XCTAssertEqual(FilesFailure.rejected(status: 500, reason: "Token abc").errorDescription, "Paperless отклонил запрос (500): Token abc") // reason уже очищен клиентом: проверить, что клиент не кладёт токен — см. PaperlessClientTests
}
```

- [ ] **Step 2: Убедиться, что тест падает** — Run: `scripts/test.sh --filter FilesFailureTests` — Expected: FAIL (тексты ещё не заданы или отличаются).

- [ ] **Step 3: Реализовать представления и тексты.**

- [ ] **Step 4: Проверка** — Run: `scripts/test.sh --filter MakoshFilesTests && scripts/build-app.sh` — Expected: PASS; сборка успешна.

- [ ] **Step 5: Коммит**

```bash
git add Sources/MakoshApp/Files Sources/MakoshApp/MakoshApp.swift Sources/MakoshFiles/FilesFailure.swift Tests/MakoshFilesTests/FilesFailureTests.swift
git commit -m "Add Paperless connections and the Paperless document browser"
```

### Task 9: «Отправить в Paperless…» у каждого файла

**Files:**
- Create: `Sources/MakoshApp/Files/FileSendMenu.swift` (`struct FileSendMenu: View` с `let handoff: () -> FileHandoff?`; показывает `Button("Отправить в Paperless…")` если есть подключения, иначе `Button("Подключить Paperless…")` → открывает Настройки на вкладке «Файлы» через `NSApp.sendAction(Selector(("showSettingsWindow:")), …)` как в существующих местах, если есть; иначе `SettingsLink`), `Sources/MakoshApp/Files/PaperlessSendSheet.swift`
- Modify: `Sources/MakoshApp/Mail/MailViews.swift` (`attachments(_:)`: `.contextMenu { FileSendMenu(...) }` на плитке; handoff через новый `MailWorkspaceModel.exportAttachment(_:letter:to:) async throws` без уведомления — добавить в `Sources/MakoshMail/Presentation/MailWorkspaceModel.swift`; `date: letter.date`)
- Modify: `Sources/MakoshApp/Telegram/TelegramAttachmentActions.swift` (`controls(purpose: .full)` в состоянии `.ready`: `FileSendMenu` с handoff через `media.withDownloadedFile(for:transfer:)` + `TelegramDownloadedFileIO.copy`, как `save(media:key:name:)`), `Sources/MakoshApp/WhatsApp/WhatsAppDetailView.swift` (в `contextMenu` сообщения с `details?.resourceID != nil`: handoff через `model.actions.download(message, expectedAccount:)` → копия `lease.url`, затем `lease.remove()`; `date` из `timestamp`), `Sources/MakoshApp/Teams/TeamsFilePreview.swift` (кнопка «В Paperless…» рядом с «Сохранить…»; handoff копирует `lease.url`), `FilesDetailView.swift` (строка каталога: `host.handoff(item)`)

**Interfaces:**
- `PaperlessSendSheet(handoff: FileHandoff)`: `Picker` подключения (скрыт при одном), `TextField` «Название» (по умолчанию имя без расширения, обрезка до 128), `DatePicker` «Дата документа» с переключателем «указать» (по умолчанию `handoff.date`), `Picker` типа, `MultiPicker` тегов (список `Toggle`), кнопка «Отправить» → `model.send`; затем полоса состояния по `PaperlessSubmission.State`: «Загружается…», «Обрабатывается…», «Документ принят · #id» + «Открыть в Paperless», «Такой документ уже есть в Paperless», «Результат неизвестен — проверьте в Paperless» + «Проверить», `failed(reason)`. Кнопка «Закрыть» всегда доступна; отправка продолжается в `sender`.

- [ ] **Step 1: Тест правил листа** в `Tests/MakoshFilesTests/PaperlessSendOptionsTests.swift` (чистая функция `PaperlessUpload.defaults(for handoff: FileHandoff, connection: PaperlessConnection) -> PaperlessUpload` в `MakoshFiles`):

```swift
func testDefaultTitleStripsExtensionAndTrimsTo128() { … "Счёт за ноябрь.pdf" → "Счёт за ноябрь"; 200 символов → 128 }
func testDefaultsTakeConnectionTypeTagsAndHandoffDate() { … }
```

- [ ] **Step 2: Убедиться, что тест падает** — Run: `scripts/test.sh --filter PaperlessSendOptionsTests` — Expected: FAIL.

- [ ] **Step 3: Реализовать `defaults`, лист, меню и четыре точки встраивания.**

- [ ] **Step 4: Проверка** — Run: `scripts/test.sh --filter "MakoshFilesTests|MakoshMailTests"` затем `scripts/build-app.sh` — Expected: PASS; сборка успешна.

- [ ] **Step 5: Коммит**

```bash
git add Sources/MakoshApp Sources/MakoshFiles Sources/MakoshMail/Presentation/MailWorkspaceModel.swift Tests/MakoshFilesTests/PaperlessSendOptionsTests.swift
git commit -m "Offer Send to Paperless wherever a file is shown"
```

### Task 10: Синтетический QA раздела и документация

**Files:**
- Create: `Sources/MakoshFiles/FilesQAIsolation.swift` (`flag = "--files-synthetic-preview"`, `validate(configuration:arguments:)` по образцу `AIQAIsolation` с префиксом `qa_files_`; `FilesSynthetic.seed(store:)` — 6 записей разных сервисов/категорий + наблюдения), `Sources/MakoshApp/Files/FilesSyntheticPreview.swift` (окно раздела с подставным `PaperlessServing`: 3 документа, загрузка → `accepted(7)`)
- Modify: `Sources/MakoshApp/MakoshApp.swift` (ветка флага, как у `AIQAIsolation.flag`), `scripts/` — при наличии общего QA-скрипта добавить запуск; иначе задокументировать команду
- Create: `docs/files.md`; Modify: `docs/architecture.md` (абзац про `MakoshFiles`), `docs/reference-interface.md` (раздел «Файлы»), `docs/development-status.md` (новый раздел сверху с фактическими результатами), `AGENTS.md` (строка в «Workflow»: QA файлов — `qa_files_`, Paperless только по команде)
- Test: `Tests/MakoshFilesTests/FilesQAIsolationTests.swift`

- [ ] **Step 1: Тест изоляции**

```swift
func testValidateRequiresFlagAbsoluteConfigAndQAFilesSchemas() throws   // как AIQAIsolationTests, если есть; иначе три случая: ок, не тот префикс, относительный путь
func testSyntheticSeedProducesSixItemsAcrossCategories() async throws
```

- [ ] **Step 2: Убедиться, что тесты падают** — Run: `scripts/test.sh --filter FilesQAIsolationTests` — Expected: FAIL.

- [ ] **Step 3: Реализовать изоляцию, синтетическое окно, документацию.**

- [ ] **Step 4: Проверка**

Run: `scripts/test.sh` (вся сборка), `scripts/build-app.sh`, затем запуск `open .build/Makosh.app --args --files-synthetic-preview --database-config <абсолютный путь к qa-конфигу>` и осмотр раздела (каталог, фильтры, предпросмотр, лист отправки с подставным Paperless), снимок в `docs/development-status.md`.
Expected: тесты зелёные; синтетический раздел показывает 6 файлов и принимает отправку.

- [ ] **Step 5: Коммит**

```bash
git add Sources Tests docs AGENTS.md scripts
git commit -m "Add the synthetic Files QA and document the Files section"
```

### Task 11: Живая проверка с реальным Paperless (только по команде пользователя)

**Files:** `docs/development-status.md`

- [ ] **Step 1:** Пользователь создаёт токен в Paperless (профиль → API token) и вводит его в Настройки → Файлы; проверка подключения показывает число документов.
- [ ] **Step 2:** Один файл, выбранный пользователем, отправляется в Paperless из письма; ожидается «Документ принят · #id» и документ виден в Paperless с тегами проверки.
- [ ] **Step 3:** Результат, скриншот и остающиеся отличия — в `docs/development-status.md`; сборки очищаются после проверки.
- [ ] **Step 4:** Коммит `Record the live Paperless check`.
