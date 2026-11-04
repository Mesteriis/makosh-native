# Домен «ИИ», часть 2: флаги «Доступно для ИИ», индекс и RAG — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Беседа ИИ отвечает по данным Макоша (сообщения Telegram/WhatsApp/Teams, письма, контакты) только из явно разрешённых источников и показывает ссылки на оригиналы.

**Architecture:** Флаги источников — новая зашифрованная таблица `archive_ai_policy` в `MessageArchiveStore` (входит в резервную копию). Флаг контакта — поле `aiAccess` в записи контакта. `MakoshCore` получает узкий контракт `AIIndexSource`, его реализуют журнал архива (`MessageArchiveIndexSource`) и почта (`MailAIIndexSource`). `MakoshAI` получает `AIVectorStore` (pgvector), `AIIndexer` (actor: курсоры, догрузка, допуск, удаление) и поиск в `AIWorker`. Приложение связывает источники с `AIHost`. `MakoshAI` по-прежнему не импортирует модули сервисов.

**Tech Stack:** Swift 6.2, SwiftUI/AppKit, macOS 26, PostgreSQL 18 + pgvector, libpq (`CPostgres`), CryptoKit, URLSession. Новая зависимость — только серверное расширение pgvector в dev-образе PostgreSQL.

**Spec:** [2026-11-04-ai-domain-design.md](../specs/2026-11-04-ai-domain-design.md). Часть 1 — [2026-11-04-ai-domain-foundation.md](2026-11-04-ai-domain-foundation.md) (выполнена).

## Global Constraints

- По умолчанию выключено: флаг чата и почтового ящика. Флаг контакта — `inherit` (по умолчанию) / `allowed` / `forbidden`. Уровни ограничивают друг друга: `allowed` на контакте не открывает выключенный чат/ящик; `forbidden` закрывает контакт везде.
- Собственные исходящие сообщения флагом контакта не ограничиваются.
- Проверка допуска — дважды: при индексации и при выдаче фрагмента в запрос.
- Выключение флага удаляет фрагменты источника из индекса; архив сообщений и почты не изменяется. Индекс никогда не пишет в архив.
- Включение флага догружает прежнюю историю источника.
- Ни один фрагмент данных не уходит провайдеру (эмбеддинги, беседа) без действующего допуска — включая повторы, догрузку и смену модели.
- Текст фрагментов — AES-GCM в PostgreSQL (ключи `AIPostgres`); векторы — открытые (решение пользователя). Токены источников/авторов — HMAC (`AIPostgres.token`).
- Без pgvector: беседа работает, RAG недоступен с ошибкой в настройках; запуск Макоша и другие домены не затрагиваются.
- Смена модели эмбеддингов → новое поколение индекса; поколения не смешиваются; старое поколение отвечает до готовности нового.
- Размерность эмбеддингов ≤ 2000 (предел HNSW pgvector для `vector`); больше — ошибка роли с понятным текстом.
- MainActor — только UI. Индексация — на `AIIndexer`, сетевые запросы — `AIClient`, SQL — `AIVectorStore`/репозитории.
- Синтетические данные и схемы `qa_ai_` для тестов/QA; реальные аккаунты и провайдеры — только по явному разрешению пользователя.
- Каждая задача: `scripts/format.sh`, тесты задачи; на границах — `scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh`; затем чистка сборок.

## Решения плана (не из спецификации; проверьте)

- Уровни флагов части 2: **чат** (Telegram/WhatsApp/Teams), **почтовый ящик = аккаунт почты**, **контакт**. Флаги папки почты и аккаунта мессенджера, упомянутые в спецификации «где применимо», в часть 2 не входят (их добавление — новые области той же таблицы, без смены схемы).
- События архива с `service == "mail"` (исходящие письма) индексатор пропускает: почта индексируется целиком из `MailAIIndexSource`.
- Автор сообщения сопоставляется с контактом через `ServiceIdentity(service, accountID, externalID: authorID)` архива; для почты — `ServiceIdentity("mail", accountID, sender.lowercased())` (как `WorkspaceModel` линкует письма в досье). Если сопоставить нельзя — действует только флаг чата/ящика.
- Чтение журналов по `BIGSERIAL` с перекрытием: каждый цикл перечитывает последние 1000 последовательностей ниже курсора, чтобы поймать поздно закоммиченные строки; повтор безопасен благодаря детерминированным id фрагментов.
- Фрагменты: окно до 8 соседних сообщений одного разговора и ≤ 1500 символов, шаг 6 (перекрытие 2); письмо — заголовки (тема/от/кому/дата) + тело, части ≤ 1500 символов. id фрагмента = HMAC от поколения и упорядоченных токенов сообщений.
- Эмбеддинги — пакетами по 64 входа, не чаще 2 запросов/с; 401 останавливает индексацию до правки подключения; сетевые ошибки — повтор через 30 с.
- Поиск: top-k = 8, косинусное расстояние ≤ 0.6 (значения — константы `AIRetrieval`, меняются одним местом).
- Новая таблица резервной копии добавляется без смены версии формата: старые копии восстанавливаются без неё.

## Review Focus

1. **Флаг выключили во время догрузки или пока пакет эмбеддингов в полёте** — ничего из этого источника не должно сохраниться после ответа провайдера. Тест: `testDisableDuringEmbeddingDiscardsBatch` (Task 6).
2. **Объединение контакта «запрещено» с контактом «разрешено» и отмена объединения** — после слияния запрет действует; после отмены каждый контакт получает своё прежнее значение; индекс пересчитывается. Тесты: `testMergeKeepsForbidden`, `testUndoRestoresBothPolicies` (Task 2), `testContactForbidPurgesAuthorChunks` (Task 6).
3. **Сообщение удалено/помечено `removedFromSource` после индексации** — его фрагменты пропадают из индекса, архив цел. Тест: `testDeletedMessageRemovesChunks` (Task 6).
4. **Смена модели эмбеддингов посередине индексации** — запросы старого поколения не смешиваются с новым, поиск отвечает старым до готовности нового. Тест: `testModelChangeBuildsNewGeneration` (Task 6).
5. **Фрагмент попал в индекс, а затем запрещён, но очистка ещё не дошла** — он не попадает в запрос к модели. Тест: `testRetrievalRechecksAdmission` (Task 7).

---

## File Structure

```
Sources/MakoshCore/
  AIAccessPolicy.swift            AIAccessScope, AIContactAccess, AIIndexItem, AIIndexSource (контракты)
  MessageArchiveStore.swift       + archive_ai_policy, records(after:), records(scope ascending)
  MessageArchiveIndexSource.swift реализация AIIndexSource поверх журнала архива
  ArchiveBackupRecords.swift      + ArchiveBackupTable.aiPolicies
  Models.swift                    + Contact.aiAccess
  ContactStore.swift / ContactReconciliation.swift / ContactWorkspaceWorker.swift  + setAIAccess, правило слияния
Sources/MakoshMail/MailAIIndexSource.swift   реализация AIIndexSource поверх mail_versions
Sources/MakoshAI/
  AIVectorStore.swift             pgvector: поколения, фрагменты, поиск
  AIIndexer.swift                 actor: циклы, курсоры, догрузка, допуск, удаление
  AIChunker.swift                 окна сообщений и части писем
  AIRetrieval.swift               константы, сборка контекста и источников
  AIClient.swift                  + embeddings
  AIWorker.swift / AIModels.swift + RAG в send, AIMessageVersion.sources
  Presentation/AISettingsModel.swift + прогресс/пауза индекса, сводка флагов
Sources/MakoshApp/  флаги в настройках чатов, почты, DossierView; AIHost связывает источники
compose.yaml, THIRD_PARTY_NOTICES.md, docs/*
```

---

### Task 1: Флаги источников в архиве (+ резервная копия)

**Files:** Create `Sources/MakoshCore/AIAccessPolicy.swift`; Modify `Sources/MakoshCore/MessageArchiveStore.swift`, `Sources/MakoshCore/ArchiveBackupRecords.swift` (+ места, где перечисляются `ArchiveBackupTable`: снимок/восстановление в `MessageArchiveStore` и `ArchiveBackup*`); Test `Tests/MakoshCoreTests/AIAccessPolicyTests.swift`, `Tests/MakoshCoreTests/ArchiveBackupTests.swift`.

**Interfaces — Produces:**
```swift
public enum AIAccessScope: Codable, Hashable, Sendable {
    case conversation(service: String, accountID: String, conversationID: String)
    case mailAccount(accountID: String)
}
public extension MessageArchiveStore {
    func aiAccessEnabled(_ scope: AIAccessScope) throws -> Bool            // default false
    func setAIAccess(_ scope: AIAccessScope, enabled: Bool) throws
    func enabledAIScopes() throws -> [AIAccessScope]
}
```
Таблица `archive_ai_policy(scope_token TEXT PRIMARY KEY, ciphertext TEXT NOT NULL)`; токен — `token(["ai-policy", kind, ...fields])`, AAD — `binding("ai-policy-\(token)", 0)`, как у `archive_conversation_file_policy`. `ArchiveBackupTable.aiPolicies = "archive_ai_policy"`, колонки `["scope_token","ciphertext"]`, порядок `scope_token COLLATE "C"`.

- [ ] **Step 1: Тесты:** `testDefaultIsDisabled`, `testSetAndListScopes`, `testScopesAreIndependent` (чат A не влияет на чат B и на почтовый аккаунт), `testPolicyIsEncrypted` (имя разговора не видно в `ciphertext`), `testBackupRestoresAIPolicies`, `testOldBackupWithoutAIPoliciesRestores`.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** `swift test --filter 'MakoshCoreTests.AIAccessPolicyTests|MakoshCoreTests.ArchiveBackupTests'` → PASS.
- [ ] **Step 5:** format, commit `Add AI access policies to the message archive`.

### Task 2: Флаг контакта

**Files:** Modify `Sources/MakoshCore/Models.swift`, `Sources/MakoshCore/ContactStore.swift`, `Sources/MakoshCore/ContactReconciliation.swift` (правило слияния), `Sources/MakoshCore/ContactWorkspaceWorker.swift` (команда); Test `Tests/MakoshCoreTests/ContactAIAccessTests.swift`.

**Interfaces — Produces:**
```swift
public enum AIContactAccess: String, Codable, Sendable { case inherit, allowed, forbidden }  // в AIAccessPolicy.swift
// Contact: public var aiAccess: AIContactAccess  — decodeIfPresent ?? .inherit
public func setAIAccess(contactID: UUID, access: AIContactAccess) throws   // ContactStore; revision += 1, событие "aiAccess"
// ContactWorkspaceCommand: case setAIAccess(contactID: UUID, access: AIContactAccess)
```
Слияние: `forbidden`, если у любого; иначе `allowed`, если у любого; иначе `inherit`. Отмена слияния восстанавливает снимки (поле в них уже есть).

- [ ] **Step 1: Тесты:** `testDefaultInheritForOldRows` (JSON без поля → `.inherit`), `testSetBumpsRevisionAndBlocksStaleUndo`, `testMergeKeepsForbidden`, `testMergeAllowedOverInherit`, `testUndoRestoresBothPolicies`.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** `swift test --filter MakoshCoreTests.ContactAIAccessTests` → PASS; плюс существующие `ContactStoreTests`.
- [ ] **Step 5:** format, commit `Add per-contact AI access`.

### Task 3: Контракт источника и источник архива

**Files:** Modify `Sources/MakoshCore/AIAccessPolicy.swift`, `Sources/MakoshCore/MessageArchiveStore.swift`; Create `Sources/MakoshCore/MessageArchiveIndexSource.swift`; Test `Tests/MakoshCoreTests/MessageArchiveIndexSourceTests.swift`.

**Interfaces — Produces:**
```swift
public struct AIIndexItem: Sendable, Equatable {
    public let sequence: Int64
    public let identity: MessageArchiveIdentity          // для почты: service "mail", conversationID = mailbox, messageID = letter id
    public let scope: AIAccessScope
    public let author: ServiceIdentity?                  // nil, если не сопоставим
    public let isOutgoing: Bool
    public let date: Date
    public let title: String                              // имя чата / тема письма; может быть пустым
    public let text: String
    public let removed: Bool                              // deleted / removedFromSource
}
public protocol AIIndexSource: Sendable {
    var name: String { get }                              // "archive", "mail" — ключ курсора
    func items(after sequence: Int64, limit: Int) async throws -> [AIIndexItem]          // по возрастанию
    func items(in scope: AIAccessScope, after sequence: Int64, limit: Int) async throws -> [AIIndexItem]   // догрузка
}
public extension MessageArchiveStore {
    func records(after: Int64, limit: Int) throws -> [MessageArchiveRecord]           // ASC
    func records(service: String, accountID: String, conversationID: String, after: Int64, limit: Int) throws -> [MessageArchiveRecord]
}
public final class MessageArchiveIndexSource: AIIndexSource, @unchecked Sendable {
    public init(connectionString: String, schema: String, keyProvider: @escaping (UUID, Bool) throws -> Data)   // readOnly-открытие MessageArchiveStore
}
```
Источник пропускает события `service == "mail"`; автор — `ServiceIdentity(service, accountID, authorID)` при непустом `authorID`, `isOutgoing` из содержимого; `.deleted`/`.removedFromSource` → `removed = true`. Лимит 1…200.

- [ ] **Step 1: Тесты:** `testItemsAfterAscendingAndBounded`, `testMailEventsSkipped`, `testDeletionBecomesRemoved`, `testScopeBackfillOnlyThatConversation`, `testAuthorMapping` (с синтетическими наблюдениями Telegram/WhatsApp/Teams).
- [ ] **Step 2:** Сверить в коде каждого сервиса, что `authorID` архива совпадает с `externalID` его досье-идентичности (`TelegramContactProfile.dossierIdentity`, WhatsApp/Teams в `WorkspaceModel` и их архивных проекциях). Расхождение — записать в `docs/development-status.md` как ограничение (флаг контакта не применится к этому сервису) и в ledger как Ruling; код сервисов не менять.
- [ ] **Step 3:** FAIL. **Step 4:** реализовать. **Step 5:** PASS. **Step 6:** format, commit `Add AI index source contract and archive source`.

### Task 4: Источник почты

**Files:** Create `Sources/MakoshMail/MailAIIndexSource.swift`; Modify `Sources/MakoshMail/MailRepository.swift` (чтение `versionTable` по возрастанию `sequence`, по аккаунту); Test `Tests/MakoshMailTests/MailAIIndexSourceTests.swift`.

**Interfaces — Produces:** `public struct MailAIIndexSource: AIIndexSource { public init(repository: MailRepository) }`, `name == "mail"`, `scope = .mailAccount(accountID)`, `identity = MessageArchiveIdentity(service: "mail", accountID, conversationID: key.mailbox, messageID: letter.id)`, `author = ServiceIdentity("mail", accountID, sender.lowercased())`, `isOutgoing` — отправитель совпадает с адресом аккаунта, `title = subject`, `text` — `text`, иначе HTML без тегов (существующий конвертер почты), `removed = removedFromSource == true`.

- [ ] **Step 1: Тесты:** `testVersionsAscendingFromCursor`, `testAccountBackfillOnlyThatAccount`, `testHTMLOnlyLetterBecomesPlainText`, `testRemovedLetterMarked`.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** PASS. **Step 5:** format, commit `Add mail AI index source`.

### Task 5: pgvector и векторное хранилище

**Files:** Modify `compose.yaml` (образ `pgvector/pgvector:<версия>-pg18-<debian>` по digest; убедиться, что том `postgres:18.6` совместим — тот же мажор 18), `THIRD_PARTY_NOTICES.md` (pgvector, PostgreSQL License), `docs/object-storage.md`/`docs/architecture.md`; Create `Sources/MakoshAI/AIVectorStore.swift`; Test `Tests/MakoshAITests/AIVectorStoreTests.swift`.

**Interfaces — Produces:**
```swift
public struct AIIndexGeneration: Codable, Equatable, Sendable { public let id: Int64; public let connectionID: UUID; public let model: String; public let dimensions: Int; public var ready: Bool }
public struct AIChunk: Sendable, Equatable {
    public let id: String                                   // HMAC
    public let scope: AIAccessScope
    public let messages: [MessageArchiveIdentity]
    public let authors: [ServiceIdentity]
    public let text: String
    public let date: Date
    public let title: String
}
public struct AIChunkMatch: Sendable, Equatable { public let chunk: AIChunk; public let distance: Double }
public actor AIVectorStore {
    public init(database: AIRepository)                     // использует то же соединение/ключи, что AIRepository
    public func available() throws -> Bool                  // CREATE EXTENSION IF NOT EXISTS vector; false при отказе
    public func generation(connectionID: UUID, model: String, dimensions: Int) throws -> AIIndexGeneration   // создаёт или находит
    public func activeGeneration() throws -> AIIndexGeneration?   // последняя ready
    public func markReady(_ id: Int64) throws               // старые поколения удаляются после этого
    public func contains(_ chunkIDs: [String], generation: Int64) throws -> Set<String>
    public func insert(_ chunks: [(AIChunk, [Float])], generation: Int64) throws
    public func delete(scope: AIAccessScope) throws
    public func delete(author: ServiceIdentity) throws
    public func delete(message: MessageArchiveIdentity) throws
    public func search(_ vector: [Float], generation: Int64, limit: Int, maxDistance: Double) throws -> [AIChunkMatch]
}
```
Таблицы: `ai_index_generations`, `ai_chunks(generation BIGINT, chunk_token TEXT, scope_token TEXT, author_tokens TEXT[], message_tokens TEXT[], date DOUBLE PRECISION, embedding vector, ciphertext TEXT, PRIMARY KEY(generation, chunk_token))`; на каждое поколение — частичный индекс `USING hnsw ((embedding::vector(N)) vector_cosine_ops) WHERE generation = G`; поиск использует то же выражение. Для этого `AIRepository` открывает пакетный (`package`) доступ к `AIPostgres` (`token`, `seal`, `decode`, `query`, `transaction`).

- [ ] **Step 1:** Закрепить образ: найти актуальный тег pgvector для PostgreSQL 18 (проверить, что тег существует, и получить digest через `docker buildx imagetools inspect`), обновить `compose.yaml`, `scripts/dev-db.sh up`, `SELECT extversion FROM pg_available_extensions WHERE name='vector'`.
- [ ] **Step 2: Тесты:** `testUnavailableWithoutExtension` (подставное соединение, отказ `CREATE EXTENSION` → `false`, без исключения наружу), `testInsertSearchNearestFirst`, `testGenerationsDoNotMix`, `testDeleteByScopeAuthorMessage`, `testChunkTextEncrypted`, `testDimensionAbove2000Rejected`.
- [ ] **Step 3:** FAIL. **Step 4:** реализовать. **Step 5:** PASS. **Step 6:** format, commit `Add pgvector index store for AI`.

### Task 6: Эмбеддинги и индексатор

**Files:** Modify `Sources/MakoshAI/AIClient.swift` (+ `embeddings`), `Sources/MakoshAI/AIModels.swift` (`AIFailure.vectorUnavailable`, `.dimensionsTooLarge`); Create `Sources/MakoshAI/AIChunker.swift`, `Sources/MakoshAI/AIIndexer.swift`; Test `Tests/MakoshAITests/AIClientTests.swift`, `Tests/MakoshAITests/AIChunkerTests.swift`, `Tests/MakoshAITests/AIIndexerTests.swift`.

**Interfaces — Produces:**
```swift
// AIServing += func embeddings(connection: AIConnection, token: String?, model: String, inputs: [String]) async throws -> [[Float]]
public struct AIAccessSnapshot: Sendable {                 // собирается индексатором на каждом цикле
    public let enabledScopes: Set<AIAccessScope>
    public let contactAccess: [ServiceIdentity: AIContactAccess]
    public func admits(_ item: AIIndexItem) -> Bool         // scope ∈ enabled && (isOutgoing || author == nil || contactAccess[author] != .forbidden)
}
public protocol AIAccessProvider: Sendable {               // приложение связывает с MessageArchiveStore и ContactWorkspaceWorker
    func snapshot() async throws -> AIAccessSnapshot
    func setScope(_ scope: AIAccessScope, enabled: Bool) async throws
}
// AIWorker += func embed(_ inputs: [String]) async throws -> (connectionID: UUID, model: String, vectors: [[Float]])
//   — роль embeddings; .roleUnassigned(.embeddings), если не назначена
public struct AIIndexStatus: Sendable, Equatable { public var indexed: Int; public var pending: Int; public var paused: Bool; public var failure: AIFailure? }
public actor AIIndexer {
    public init(worker: AIWorker, vectors: AIVectorStore, sources: [any AIIndexSource], access: any AIAccessProvider, now: @escaping @Sendable () -> Date = Date.init)
    public func runOnce() async throws -> AIIndexStatus      // один цикл: снимок допуска → удаление → новые элементы → догрузка → эмбеддинги
    public func start()                                      // цикл runOnce каждые 30 с, пока не пауза/закрытие
    public func pause(_ paused: Bool)
    public func accessChanged()                              // немедленный цикл после смены флага
    public func status() -> AIIndexStatus
    public func close() async
}
```
Поведение цикла: (1) снимок допуска; сравнить с предыдущим: выключенные области → `delete(scope:)`; ставшие `forbidden` идентичности → `delete(author:)` и догрузка их областей заново; включённые области и снятые запреты → в очередь догрузки. (2) Новые элементы каждого источника от курсора с перекрытием 1000; `removed` → `delete(message:)`. (3) Элементы, прошедшие `admits`, режутся `AIChunker`; уже существующие id пропускаются. (4) Пакет эмбеддингов: **после ответа провайдера** взять свежий снимок допуска и отбросить фрагменты, переставшие проходить. (5) Сохранить; курсоры и состояние догрузки — в `ai_records` (`kind = indexCursor`). Роль `embeddings` не назначена → ничего не делать, статус с `roleUnassigned`. 401 → пауза до сохранения подключения.

- [ ] **Step 1: Тесты:** клиент — `testEmbeddingsOrderedByIndex`; чанкер — `testChatWindowsOverlap`, `testWindowSkipsForbiddenAuthorOnly`, `testLongLetterSplitWithHeaders`, `testChunkIDDeterministic`; индексатор (подставные источники, доступ, сервис; реальная PostgreSQL+pgvector) — `testNothingSentWithoutEnabledScope`, `testEnableBackfillsHistory`, `testDisablePurgesScope`, `testContactForbidPurgesAuthorChunks`, `testOutgoingIndexedDespiteForbiddenRecipient`, `testDeletedMessageRemovesChunks`, `testDisableDuringEmbeddingDiscardsBatch`, `testModelChangeBuildsNewGeneration`, `testUnauthorizedPausesIndexing`, `testCursorOverlapCatchesLateCommit`, `testRestartResumesFromCursor`.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** PASS. **Step 5:** format, commit `Add AI indexer with access-checked embeddings`.

### Task 7: RAG в беседе

**Files:** Create `Sources/MakoshAI/AIRetrieval.swift`; Modify `Sources/MakoshAI/AIModels.swift` (`AIMessageVersion.sources: [AISourceReference]` с `decodeIfPresent ?? []`; `AIConversation.searchMyData: Bool`, по умолчанию `true`), `Sources/MakoshAI/AIWorker.swift`, `Sources/MakoshAI/Presentation/AIWorkspaceModel.swift`; Test `Tests/MakoshAITests/AIRetrievalTests.swift`, `Tests/MakoshAITests/AIWorkerTests.swift`.

**Interfaces — Produces:**
```swift
public struct AISourceReference: Codable, Equatable, Sendable { public let identity: MessageArchiveIdentity; public let title: String; public let date: Date }
public enum AIRetrieval { public static let limit = 8; public static let maxDistance = 0.6 }
// AIWorker.attachRetrieval(vectors: AIVectorStore, access: any AIAccessProvider)  — вызывается AIHost после создания индексатора (без цикла в init)
// AIWorker.setSearchMyData(_ enabled: Bool, conversationID: UUID) async throws
// AIWorkspaceModel.setSearchMyData(_ enabled: Bool) async
```
В `prepareSend`/`prepareRegenerate`: если беседа `searchMyData`, роль `embeddings` назначена и есть готовое поколение — эмбеддинг вопроса → `search` → **повторная проверка `admits` по свежему снимку** → системное сообщение с пронумерованными фрагментами и требованием ссылаться на номера → `sources` версии ответа. Без поколения/роли/pgvector — обычная беседа, без ошибки.

- [ ] **Step 1: Тесты:** `testRetrievalRechecksAdmission`, `testAnswerCarriesSources`, `testSearchDisabledSendsNoEmbeddings`, `testNoGenerationFallsBackToPlainChat`, `testOldVersionsDecodeWithoutSources`.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** PASS. **Step 5:** format, commit `Use permitted Makosh data in AI answers`.

### Task 8: Флаги в интерфейсе, сборка в приложении, проверки

**Files:** Modify `Sources/MakoshApp/Telegram/TelegramConversationFilePolicyMenu.swift`, `Sources/MakoshApp/WhatsApp/WhatsAppChatSettingsView.swift`, `Sources/MakoshApp/Teams/TeamsChatSettingsView.swift` (переключатель «Доступно для ИИ» рядом с «Сохранять файлы в S3»), настройки аккаунта почты в `Sources/MakoshApp/Mail/MailViews.swift`, `Sources/MakoshApp/Contacts/DossierView.swift` (выбор «Как у чата / Разрешено / Запрещено»), `Sources/MakoshApp/AI/AIHost.swift` (создаёт `MessageArchiveIndexSource`, `MailAIIndexSource`, `AIAccessProvider`, `AIIndexer`), `Sources/MakoshApp/AI/AISettingsView.swift` (сводка включённых источников, прогресс/пауза индекса, ошибка pgvector), `Sources/MakoshApp/AI/AIWorkspaceViews.swift` (переключатель «Искать в моих данных», список источников у ответа; клик открывает оригинал через существующую навигацию досье/раздела), `Sources/MakoshApp/AI/AISyntheticPreview.swift` + `scripts/run-ai-qa.py` (синтетический разговор в QA-схеме архива с включённым флагом, подставные эмбеддинги в `AISyntheticService`); Test `Tests/MakoshAITests/AIQAIsolationTests.swift`, `scripts/test-ai-qa.py`.

Переключатели вызывают `AIAccessProvider.setScope`/`ContactWorkspaceCommand.setAIAccess`, затем `AIIndexer.accessChanged()`. Подпись: «Доступно для ИИ — сообщения этого чата могут уходить провайдеру модели».

- [ ] **Step 1: Тесты:** `testSyntheticEmbeddingsDeterministic`, `testSyntheticPreviewSeedsEnabledConversation` (QA-изоляция), обновлённый `scripts/test-ai-qa.py`.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** PASS.
- [ ] **Step 5:** `scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh` → exit 0; `python3 scripts/run-ai-qa.py --launch` (при отсутствии окна — повторный `open` бандла): проверить в QA-схеме фрагменты индекса только из включённого синтетического разговора; визуально — если доступны разрешения записи экрана/Accessibility. Записать факты и непроверенное в `docs/development-status.md`, ADR в `docs/architecture.md`, удалить QA-схемы и папки этого запуска.
- [ ] **Step 6:** format, commit `Add AI access controls and index wiring`; чистка сборок.
