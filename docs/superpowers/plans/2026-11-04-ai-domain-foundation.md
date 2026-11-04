# Домен «ИИ», часть 1: основа и беседа — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Модуль `MakoshAI` с подключениями к OpenAI-совместимому API, ролями моделей, зашифрованными беседами с потоковым ответом, версиями, диктовкой, озвучкой и генерацией изображений — пункт «ИИ» в общем рабочем пространстве.

**Architecture:** По образцу `MakoshTelemost`: `AIRepository` (actor) владеет PostgreSQL-схемой с шифрованием по ключу `MessageArchiveKeychain`; `AITokenVault` (actor) — Keychain; `AIClient` — собственный `URLSession`-клиент; `AIWorker` (actor) — оркестрация и поколения; `AIWorkspaceModel` (`@MainActor`, `Presentation/`, `package`) — состояние UI. Приложение добавляет `Destination.ai`, вкладку настроек и синтетический QA-запуск.

**Tech Stack:** Swift 6.2, SwiftUI/AppKit, macOS 26, Foundation/URLSession, CryptoKit, Security, AVFoundation, libpq (`CPostgres`), S3 (`MakoshCore.S3ObjectStore`). Новых внешних зависимостей нет.

**Spec:** [2026-11-04-ai-domain-design.md](../specs/2026-11-04-ai-domain-design.md). Часть 2 (флаги «Доступно для ИИ», pgvector, индексатор, RAG в беседе, резервные копии флагов) — отдельный план после приёмки части 1.

## Global Constraints

- Нативный SwiftUI/AppKit, macOS 26+, Apple Silicon. Только OpenAI-совместимый протокол; без сторонних SDK; TLS системный.
- Токен — только Keychain, сервис `org.makosh.ai.tokens.v1`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Не в PostgreSQL, логах, ошибках, `docs/`, Git.
- Базовый URL: `https` любой хост, либо `http` только для `localhost`/`127.0.0.1`/`::1` (локальные серверы). Иначе — ошибка валидации.
- Никакого логирования тел запросов/ответов. `AIFailure` не несёт текста ответа сервера.
- MainActor — только UI. HTTP, SSE, SQL, крипто, файлы — на `AIWorker`/`AIRepository`. Публикация в UI только после проверки поколения беседы (`docs/main-thread-boundaries.md`).
- PostgreSQL: таблицы с префиксом `ai_` в схеме из `ContactWorkspaceConfiguration.schema`; всё содержимое — `ciphertext` (AES-GCM, HKDF info `makosh-ai-encryption-v1`, токены поиска — HMAC, info `makosh-ai-lookup-v1`). QA/тестовые схемы — префикс `qa_ai_`.
- Беседы удаляемы (единственное исключение из правила неудаляемой истории); архив сообщений не затрагивается.
- Прерванный поток сохраняется с `state = .interrupted`; автоматического повтора нет.
- Изображения: S3-ключ `ai/<conversationID>/<objectID>`, тело — `ArchiveFileCapture.seal` (зашифровано), политика S3 для бесед ИИ по умолчанию ON; при OFF — зашифрованный файл в `Application Support/Makosh/AI/<objectID>`.
- Синтетический QA: флаг `--ai-synthetic-preview` + `--database-config`; схемы `qa_ai_`; подставной клиент; остальные сервисы не стартуют. Реальный провайдер — только по явному разрешению пользователя.
- Каждая задача: `scripts/format.sh`, тесты задачи; на границах — `scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh`; затем чистка сборок (`.build`, подготовленные кэши `.local`, без `*-source.git`).

## Review Focus

1. **Обрыв SSE посреди события / сервер шлёт `data:` без `[DONE]` и закрывает соединение** — ответ сохраняется как `interrupted` с полученным текстом, не как ошибка без текста. Тест: `testStreamWithoutDoneIsInterrupted` (Task 4/5).
2. **Ошибка 401/429/5xx до первого байта и JSON-тело ошибки** — пользователь видит понятный тип ошибки, токен и тело не попадают в сообщение. Тест: `testHTTPErrorsMapWithoutBody` (Task 4).
3. **Пользователь переключил беседу или удалил её во время потока** — дельты старой беседы не появляются в новой, удалённая не воскресает. Тест: `testDeleteDuringStreamDiscardsDeltas` (Task 5), `testSwitchConversationIgnoresStaleDeltas` (Task 6).
4. **Роль не назначена или подключение удалено, а роль на него ссылается** — действие недоступно с подсказкой, удаление подключения сбрасывает его роли. Тест: `testRemovingConnectionClearsItsRoles` (Task 3).
5. **Токен с пробелами/переводом строки из буфера обмена, пустой токен для локального сервера** — пробелы обрезаются, пустой токен — без заголовка `Authorization`. Тест: `testTokenTrimmedAndEmptyOmitsHeader` (Task 4).

---

## File Structure

```
Sources/MakoshAI/
  AIModels.swift            AIConnection, AIRole, AIRoleAssignment, AIConversation, AIMessage, AIMessageVersion, AIFailure
  AITokenVault.swift        AIKeychainAccess, AITokenStoring, AITokenVault
  AIPostgres.swift          соединение, схема, шифрование (по образцу TelemostPostgres)
  AIRepository.swift        actor: CRUD подключений/ролей/бесед/сообщений/версий, удаление
  AIClient.swift            AIClient: models, chatStream, images, transcription, speech
  AIServerSentEvents.swift  разбор SSE в дельты
  AIWorker.swift            actor: оркестрация, поколения, поток, стоп, версии
  AIImageStore.swift        S3/локальное хранение сгенерированных изображений
  AIQAIsolation.swift       проверка аргументов и схем qa_ai_
  AISynthetic.swift         подставной клиент для QA
  Presentation/AIWorkspaceModel.swift   @MainActor, package
  Presentation/AISettingsModel.swift    @MainActor, package
Sources/MakoshCore/S3ObjectStore.swift   + delete(key:)
Sources/MakoshApp/AI/
  AIWorkspaceViews.swift    список бесед, окно беседы, поле ввода
  AISettingsView.swift      подключения и роли
  AIVoiceInput.swift        запись диктовки (AVAudioRecorder → m4a)
Sources/MakoshApp/Workspace/WorkspaceView.swift  + Destination.ai
Sources/MakoshApp/MakoshApp.swift                + вкладка настроек, синтетический запуск
Tests/MakoshAITests/...
Package.swift                                    + target/product/testTarget MakoshAI
```

---

### Task 1: Модуль и модели

**Files:**
- Modify: `Package.swift` — `.library(name: "MakoshAI", targets: ["MakoshAI"])`, `.target(name: "MakoshAI", dependencies: ["MakoshCore", "CPostgres"])`, `.testTarget(name: "MakoshAITests", dependencies: ["MakoshAI", "MakoshCore", "CPostgres"])` (без `MakoshApp`), `MakoshApp` += `"MakoshAI"`.
- Create: `Sources/MakoshAI/AIModels.swift`, `Tests/MakoshAITests/AIModelsTests.swift`

**Interfaces — Produces:**
```swift
public enum AIRole: String, Codable, CaseIterable, Sendable { case chat, embeddings, images, transcription, speech }
public struct AIConnection: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID; public var name: String; public var baseURL: URL
    public var organization: String?; public var project: String?
    public func validated() throws -> AIConnection   // AIFailure.invalidConnection
}
public struct AIRoleAssignment: Codable, Equatable, Sendable { public let role: AIRole; public let connectionID: UUID; public let model: String }
public struct AIConversation: Codable, Equatable, Identifiable, Sendable { public let id: UUID; public var title: String; public let createdAt: Date; public var updatedAt: Date }
public enum AIMessageAuthor: String, Codable, Sendable { case user, assistant }
public enum AIMessageState: String, Codable, Sendable { case complete, streaming, interrupted, failed }
public struct AIImageReference: Codable, Equatable, Sendable { public let objectID: UUID; public let byteCount: Int64; public let sha256: String; public let inS3: Bool }
public struct AIMessageVersion: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID; public var text: String; public var state: AIMessageState; public let model: String?; public let createdAt: Date; public var image: AIImageReference?
}
public struct AIMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID; public let conversationID: UUID; public let parentID: UUID?   // ветвление: предыдущее сообщение пути
    public let author: AIMessageAuthor; public var versions: [AIMessageVersion]; public var selectedVersion: Int
}
public enum AIFailure: Error, Equatable, Sendable {
    case invalidConnection, invalidConfiguration, storage, keyUnavailable, roleUnassigned(AIRole)
    case unauthorized, rateLimited, server(status: Int), network, malformedResponse, cancelled
}
```

- [ ] **Step 1: Тесты** `testHTTPSAccepted`, `testLoopbackHTTPAccepted` (`http://localhost:11434/v1`, `http://127.0.0.1:1234/v1`, `http://[::1]:8080/v1`), `testRemoteHTTPRejected` (`http://example.com/v1` → `.invalidConnection`), `testEmptyNameRejected`, `testNameTrimmedAndLimitedTo80` (имя > 80 символов → ошибка).
- [ ] **Step 2:** `swift test --filter MakoshAITests.AIModelsTests` → FAIL (нет модуля).
- [ ] **Step 3:** Реализовать типы выше; `validated()` обрезает пробелы в имени, требует схему/хост по Global Constraints, без `user:password@`, без query/fragment.
- [ ] **Step 4:** Тест → PASS.
- [ ] **Step 5:** `scripts/format.sh`; commit `Add MakoshAI module and models`.

### Task 2: Хранилище токенов

**Files:** Create `Sources/MakoshAI/AITokenVault.swift`, `Tests/MakoshAITests/AITokenVaultTests.swift`

**Interfaces — Produces:** `AIKeychainAccess` (как `TelemostKeychainAccess`, сервис `org.makosh.ai.tokens.v1`, ключ — `connectionID.uuidString`); `public protocol AITokenStoring: Sendable { func load(connectionID: UUID) async throws -> String?; func save(_ token: String, connectionID: UUID) async throws; func remove(connectionID: UUID) async throws }`; `public actor AITokenVault: AITokenStoring`.

- [ ] **Step 1: Тесты** на подставном `AIKeychainAccess` (словарь в памяти): `testRoundTrip`, `testTokenTrimmed` (`"  sk-abc\n"` → `"sk-abc"`), `testEmptyTokenRemovesItem`, `testOversizeRejected` (> 16 KiB → `.keyUnavailable`), `testKeychainErrorIsKeyUnavailable`.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** PASS. **Step 5:** format, commit `Add AI token vault`.

### Task 3: Репозиторий PostgreSQL

**Files:** Create `Sources/MakoshAI/AIPostgres.swift`, `Sources/MakoshAI/AIRepository.swift`, `Tests/MakoshAITests/AIRepositoryTests.swift` (+ `AITestDatabase` по образцу `TelemostTestDatabase`, схема `qa_ai_<uuid>`, ключ `Data(repeating: 0x61, count: 32)`).

**Schema** (в транзакции под `pg_advisory_xact_lock(hashtext('makosh-ai-schema'), hashtext(schema))`):
- `ai_metadata(id SMALLINT PK CHECK(id=1), version INTEGER, vault UUID, ciphertext TEXT)`
- `ai_records(token TEXT PK, kind TEXT, owner TEXT, sequence BIGSERIAL UNIQUE, ciphertext TEXT)` — kind ∈ `connection`, `role`, `conversation`, `message`, `settings`; owner для сообщений — токен беседы.
- Метаданные/ключ — как `TelemostPostgres.open` (существующие строки без метаданных → `.keyUnavailable`).

**Interfaces — Produces:**
```swift
public actor AIRepository {
    public init(keyProvider: @escaping @Sendable (UUID, Bool) throws -> Data = MessageArchiveKeychain.open)
    public func open(configuration: ContactWorkspaceConfiguration) throws
    public func close()
    public func connections() throws -> [AIConnection]
    public func save(_ connection: AIConnection) throws
    public func removeConnection(_ id: UUID) throws          // удаляет и роли, ссылающиеся на него
    public func roles() throws -> [AIRoleAssignment]
    public func assign(_ assignment: AIRoleAssignment?, role: AIRole) throws   // nil — снять
    public func conversations() throws -> [AIConversation]   // по updatedAt DESC
    public func save(_ conversation: AIConversation) throws
    public func messages(conversationID: UUID) throws -> [AIMessage]
    public func save(_ message: AIMessage) throws
    public func deleteConversation(_ id: UUID) throws -> [AIImageReference]  // возвращает изображения для удаления из хранилища
    public func imagesSavedToS3() throws -> Bool             // default true
    public func setImagesSavedToS3(_ value: Bool) throws
}
```

- [ ] **Step 1: Тесты:** `testConnectionsRoundTripEncrypted` (в `ai_records.ciphertext` нет имени подключения в открытом виде), `testRemovingConnectionClearsItsRoles`, `testConversationOrderByUpdatedAt`, `testMessagesVersionsRoundTrip`, `testDeleteConversationRemovesMessagesAndReturnsImages`, `testDeleteDoesNotTouchOtherConversations`, `testReopenWithWrongKeyFails`, `testImagesSavedToS3DefaultsOn`.
- [ ] **Step 2:** `MAKOSH_TEST_DATABASE_URL=… swift test --filter MakoshAITests.AIRepositoryTests` → FAIL.
- [ ] **Step 3:** Реализовать по образцу `TelemostPostgres`/`TelemostRepository`.
- [ ] **Step 4:** PASS. **Step 5:** format, commit `Add encrypted AI repository`.

### Task 4: Клиент OpenAI-совместимого API

**Files:** Create `Sources/MakoshAI/AIServerSentEvents.swift`, `Sources/MakoshAI/AIClient.swift`, `Tests/MakoshAITests/AIClientTests.swift` (подставной `URLProtocol`).

**Interfaces — Produces:**
```swift
public struct AIChatTurn: Sendable, Equatable { public let author: AIMessageAuthor; public let text: String }
public enum AIStreamEvent: Sendable, Equatable { case delta(String), done }
public protocol AIServing: Sendable {
    func models(connection: AIConnection, token: String?) async throws -> [String]
    func chat(connection: AIConnection, token: String?, model: String, turns: [AIChatTurn]) -> AsyncThrowingStream<AIStreamEvent, Error>
    func image(connection: AIConnection, token: String?, model: String, prompt: String) async throws -> Data   // PNG
    func transcribe(connection: AIConnection, token: String?, model: String, audio: URL) async throws -> String
    func speech(connection: AIConnection, token: String?, model: String, text: String) async throws -> Data     // mp3
}
public struct AIClient: AIServing { public init(session: URLSession = .init(configuration: .ephemeral)) }
struct AIServerSentEvents { mutating func feed(_ line: String) throws -> AIStreamEvent? }
```
Пути относительно `baseURL`: `models`, `chat/completions` (`stream: true`, `choices[0].delta.content`), `images/generations` (`response_format: "b64_json"`), `audio/transcriptions` (multipart, поле `file`, `model`), `audio/speech` (`voice: "alloy"`, `response_format: "mp3"`). Заголовки: `Authorization: Bearer` только при непустом токене; `OpenAI-Organization`/`OpenAI-Project` при наличии. Кэш и cookies выключены (ephemeral). Тело ответа ≤ 32 MiB для изображений/речи, ≤ 4 MiB для JSON.

- [ ] **Step 1: Тесты:** `testSSEParsesDeltasAcrossChunks` (событие разрезано между чтениями), `testSSEIgnoresCommentsAndEmptyDelta`, `testStreamWithoutDoneIsInterrupted` (поток бросает `AIFailure.network` после дельт), `testHTTPErrorsMapWithoutBody` (401→`.unauthorized`, 429→`.rateLimited`, 503→`.server(status: 503)`; `String(describing:)` ошибки не содержит тело ответа и токен), `testTokenTrimmedAndEmptyOmitsHeader`, `testModelsSortedUnique`, `testImageDecodesB64`, `testTranscriptionMultipart`.
- [ ] **Step 2:** FAIL. **Step 3:** Реализовать; поток через `session.bytes(for:)` и `.lines`, отмена задачи → `.cancelled`. **Step 4:** PASS. **Step 5:** format, commit `Add OpenAI-compatible AI client`.

### Task 5: Worker и изображения

**Files:** Create `Sources/MakoshAI/AIWorker.swift`, `Sources/MakoshAI/AIImageStore.swift`; Modify `Sources/MakoshCore/S3ObjectStore.swift` (+ `public func delete(key: String) async throws`, 204/404 — успех); Test `Tests/MakoshAITests/AIWorkerTests.swift`, `Tests/MakoshCoreTests/S3ObjectStoreDeleteTests.swift`.

**Interfaces — Consumes:** Tasks 1–4. **Produces:**
```swift
public struct AIWorkspaceSnapshot: Sendable, Equatable { public let connections: [AIConnection]; public let roles: [AIRoleAssignment]; public let conversations: [AIConversation]; public let imagesSavedToS3: Bool }
public enum AIConversationEvent: Sendable, Equatable { case updated(AIMessage), finished(UUID) }
public actor AIWorker {
    public init(repository: AIRepository = .init(), client: any AIServing = AIClient(), vault: any AITokenStoring = AITokenVault(), images: AIImageStore? = nil, now: @escaping @Sendable () -> Date = Date.init)
    public func open(configuration: ContactWorkspaceConfiguration) async throws
    public func snapshot() async throws -> AIWorkspaceSnapshot
    public func save(_ connection: AIConnection, token: String?) async throws          // token nil — не менять
    public func removeConnection(_ id: UUID) async throws                            // + токен из Keychain
    public func testConnection(_ id: UUID) async throws -> [String]                  // models
    public func assign(_ assignment: AIRoleAssignment?, role: AIRole) async throws
    public func createConversation() async throws -> AIConversation
    public func deleteConversation(_ id: UUID) async throws                          // отменяет поток, удаляет записи и изображения
    public func messages(_ conversationID: UUID) async throws -> [AIMessage]
    public func send(_ text: String, conversationID: UUID, editing: UUID?) -> AsyncThrowingStream<AIConversationEvent, Error>
    public func regenerate(_ assistantMessageID: UUID, conversationID: UUID) -> AsyncThrowingStream<AIConversationEvent, Error>
    public func stop(conversationID: UUID)
    public func generateImage(prompt: String, conversationID: UUID) async throws -> AIMessage
    public func transcribe(_ audio: URL) async throws -> String
    public func speech(_ text: String) async throws -> Data
    public func setImagesSavedToS3(_ value: Bool) async throws
    public func close() async
}
public actor AIImageStore {
    public init(s3: S3ObjectStore?, localDirectory: URL, key: @escaping @Sendable () throws -> Data)
    public func store(_ png: Data, conversationID: UUID, toS3: Bool) async throws -> AIImageReference
    public func load(_ reference: AIImageReference, conversationID: UUID) async throws -> Data
    public func delete(_ reference: AIImageReference, conversationID: UUID) async throws
}
```
Поведение: путь беседы — цепочка `parentID` от последнего сообщения; `editing` создаёт новую версию пользовательского сообщения и новую ветку ответа; `regenerate` добавляет версию ассистента и выбирает её; дельты сохраняются в БД не чаще раза в 500 мс и при завершении; `stop`/ошибка → `state = .interrupted`/`.failed` с полученным текстом; одна активная генерация на беседу (вторая отправка → ошибка, а не очередь). Заголовок беседы — первые 60 символов первого сообщения пользователя.

- [ ] **Step 1: Тесты** (подставные клиент/хранилище/репозиторий на `qa_ai_`): `testSendStreamsAndPersistsComplete`, `testStopKeepsPartialAsInterrupted`, `testStreamWithoutDoneIsInterrupted`, `testRegenerateAddsVersionAndKeepsOld`, `testEditCreatesBranch`, `testDeleteDuringStreamDiscardsDeltas`, `testRoleUnassignedFailsWithoutNetwork`, `testSecondSendWhileStreamingRejected`, `testImageStoredInS3WhenEnabledElseLocal`, `testDeleteConversationDeletesImages`, `testRemoveConnectionRemovesToken`; Core: `testDeleteTreats404AsSuccess`.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** PASS. **Step 5:** format, commit `Add AI worker with streaming, versions and images`.

### Task 6: Презентационные модели

**Files:** Create `Sources/MakoshAI/Presentation/AIWorkspaceModel.swift`, `Sources/MakoshAI/Presentation/AISettingsModel.swift`, `Tests/MakoshAITests/AIWorkspaceModelTests.swift`.

**Interfaces — Produces:**
```swift
@MainActor package final class AIWorkspaceModel: ObservableObject {
    package init(worker: AIWorker)
    @Published package private(set) var conversations: [AIConversation]
    @Published package var selectedConversationID: UUID?
    @Published package private(set) var path: [AIMessage]          // выбранная ветка
    @Published package private(set) var isStreaming: Bool
    @Published package private(set) var failure: AIFailure?
    @Published package private(set) var roles: [AIRole: AIRoleAssignment]
    package func start(configuration: ContactWorkspaceConfiguration) async
    package func newConversation() async; package func delete(_ id: UUID) async
    package func send(_ text: String) async; package func edit(_ messageID: UUID, text: String) async
    package func regenerate(_ messageID: UUID) async; package func selectVersion(_ index: Int, of messageID: UUID)
    package func stop(); package func generateImage(_ prompt: String) async
    package func transcribe(_ audio: URL) async -> String?; package func speak(_ messageID: UUID) async -> Data?
}
@MainActor package final class AISettingsModel: ObservableObject {
    package init(worker: AIWorker)
    @Published package private(set) var connections: [AIConnection]; @Published package private(set) var roles: [AIRole: AIRoleAssignment]
    @Published package private(set) var availableModels: [UUID: [String]]; @Published package private(set) var testResult: [UUID: Result<Int, AIFailure>]
    package func save(_ connection: AIConnection, token: String?) async; package func remove(_ id: UUID) async
    package func test(_ id: UUID) async; package func assign(_ role: AIRole, connectionID: UUID?, model: String) async
}
```
Каждое обновление из потока сверяется с `selectedConversationID` и поколением выбора, захваченным до `await`.

- [ ] **Step 1: Тесты:** `testSwitchConversationIgnoresStaleDeltas`, `testStopClearsStreaming`, `testUnassignedChatRoleShowsFailure`, `testSettingsTestStoresModelCount`, `testAssignNilClearsRole`.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** PASS. **Step 5:** format, commit `Add AI presentation models`.

### Task 7: Интерфейс, настройки и синтетический QA

**Files:** Create `Sources/MakoshApp/AI/AIWorkspaceViews.swift`, `Sources/MakoshApp/AI/AISettingsView.swift`, `Sources/MakoshApp/AI/AIVoiceInput.swift`, `Sources/MakoshAI/AIQAIsolation.swift`, `Sources/MakoshAI/AISynthetic.swift`; Modify `Sources/MakoshApp/Workspace/WorkspaceView.swift` (`case ai = "ИИ"`, символ `sparkles`, старт `ai.start(configuration:)` при выборе), `Sources/MakoshApp/MakoshApp.swift` (вкладка `AISettingsView().tabItem { Label("ИИ", systemImage: "sparkles") }`, ветка `--ai-synthetic-preview`), `Info.plist`/bundle-скрипт — `NSMicrophoneUsageDescription` при отсутствии; Test `Tests/MakoshAITests/AIQAIsolationTests.swift`.

UI (визуальный язык существующих доменов, `WorkspaceSplitView`): слева — список бесед (новая, удалить с подтверждением); справа — сообщения выбранной ветки, переключатель версий `‹ 2/3 ›` у сообщений с несколькими версиями, «Перегенерировать», «Изменить» у своих, «Озвучить» (через `AVAudioPlayer`, без сохранения), состояние «прервано»; поле ввода: отправка ⌘↩/↩, «Стоп» во время потока, микрофон (запись → `transcribe` → вставка в поле, без отправки), «Изображение» (промпт из поля → `generateImage`). Недоступная роль — кнопка выключена с подсказкой «Назначьте модель в Настройки → ИИ». Настройки: список подключений (имя, URL, токен `SecureField`, организация/проект, «Проверить» с числом моделей или ошибкой), секция ролей (подключение + модель: `Picker` из `availableModels` или ввод вручную), переключатель «Сохранять изображения в S3».

`AIQAIsolation.validate(configuration:arguments:)` — как `TelemostQAIsolation`, флаги `--ai-synthetic-preview`, `--database-config`, схемы `qa_ai_`, только loopback PostgreSQL. `AISynthetic` — `AIServing` с детерминированными ответами (поток из 5 дельт, модели `synthetic-chat`, `synthetic-embed`), без сети.

- [ ] **Step 1: Тесты:** `testQAIsolationRequiresQAPrefix`, `testQAIsolationRejectsRemoteHost`, `testQAIsolationRejectsUnknownFlag`.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать представления и изоляцию. **Step 4:** PASS.
- [ ] **Step 5:** `scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh` → exit 0; запуск `.app` с `--ai-synthetic-preview --database-config <qa_ai_ config>`: создать беседу, отправить, остановить, перегенерировать, переключить версии, удалить; осмотреть UI (скриншоты) в рамках разрешённого QA. Записать фактические результаты и непроверенное (микрофон/TCC, реальный провайдер) в `docs/development-status.md`; ADR «MakoshAI service boundary» в `docs/architecture.md`.
- [ ] **Step 6:** format, commit `Add AI workspace, settings and synthetic QA`; чистка сборок.
