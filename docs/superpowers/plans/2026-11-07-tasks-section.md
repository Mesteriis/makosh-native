# Раздел «Задачи»: план реализации — 2026-11-07

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Раздел «Задачи» в общем рабочем пространстве Makosh: локальный домен задач по правилам TaskOrchestrator, Jira Cloud как первый провайдер с пятью явными действиями, учёт времени таймером, вручную и из встреч Telemost.

**Architecture:** Два новых модуля. `MakoshTasks` — домен, хранилище PostgreSQL (схема приложения), журнал попыток Jira, зеркало, время, QA-изоляция. `MakoshJira` — протокольный слой Jira Cloud, перенесённый из `MacTowerWorkTracking` по образцу MMail (`Dependencies/Jira.lock.json`), за протоколом `JiraAdapter`. Приложение добавляет `Destination.tasks`, `TasksHost`, витрины «Мои» и «Jira», карточку, быстрый ввод, таймер в строке состояния, Настройки → Задачи и две точки в Telemost. MainActor держит модели и команды; сеть, SQL, Keychain — в акторах.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI/AppKit, macOS 26+, PostgreSQL через `MakoshCore.PostgresConnection`, Keychain через `MakoshSecretStore`, XCTest, `scripts/test.sh`, `scripts/build-app.sh`, Python-лаунчер QA.

**Spec:** `docs/superpowers/specs/2026-11-07-tasks-section-design.md`

## Global Constraints

- Native SwiftUI/AppKit, macOS 26+, Swift 6, строгая изоляция; актор-проверки включены.
- Локальный слой никогда не пишет в Jira; единственный автоматизм — категория «Готово» в Jira → локальный `done`, если локальный статус не `done`/`cancelled`.
- Попытка Jira с состоянием `unknown` никогда не повторяется сама; разрешение только явное (сверка или отказ).
- Токен, почта, JQL и тела ответов Jira не попадают в логи, ошибки, `description` типов и вывод QA.
- Наблюдения провайдера и версии задач append-only; удаление задач мягкое; удаление подключения не удаляет задачи и историю; токен удаляется из Keychain первым.
- Таблицы задач — в схеме приложения (`configuration.schema`), префикс имён `tasks_`; QA — одна схема `qa_tasks_<suffix>` на loopback PostgreSQL; интеграционные тесты — `MAKOSH_TEST_DATABASE_URL` и `makosh_test_` схемы (как `FilesTestDatabase`).
- Worklog короче 60 с не отправляется; черновик округляет вверх до минуты.
- Сборка и тесты не читают `~/projects/Personal/mac-tower`, `.references/` и личные базы.
- Коммиты заканчиваются строкой `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`; форматировать только изменённые файлы (`scripts/format.sh HEAD`).
- Живая Jira — только по команде пользователя; план не содержит живых шагов.

## Review Focus

1. Переход Jira с обязательным полем неподдерживаемого типа (например, каскадный выбор): карточка показывает «заполняется только в Jira» и ссылку, запрос не отправляется — Task 8 `testTransitionWithUnsupportedRequiredFieldIsBlockedBeforeSend`.
2. Два подтверждения одной остановки таймера подряд (двойной клик, повтор после перезапуска): одна запись времени и одна попытка worklog — Task 12 `testConfirmingTheSameDraftTwiceCreatesOneEntry`.
3. Ответ 429 без `Retry-After` в середине страницы зеркала: применённые страницы остаются, следующий опрос откладывается на локальный backoff, задачи не исчезают из «Моих» — Task 10 `testRateLimitMidPageKeepsAppliedPagesAndDefers`.
4. Описание Jira с таблицей или вложением: поле только для чтения, попытка `fields` без описания проходит, с описанием отклоняется до отправки — Task 8 `testRichDescriptionIsReadOnly`.
5. Быстрый ввод `~ABC-123` для ключа задачи, которой нет в зеркале: зависимость не создаётся, токен остаётся в названии, предпросмотр говорит «задача не найдена» — Task 4 `testUnknownDependencyKeyStaysInTitle`.

## File Structure

- `references.lock.json`, `Dependencies/Jira.lock.json`, `THIRD_PARTY_NOTICES.md`, `docs/xerj.md` — референсы и пин.
- `Package.swift` — цели `MakoshTasks`, `MakoshJira`, `MakoshTasksTests`, `MakoshJiraTests`.
- `Sources/MakoshJira/`
  - `JiraHTTPSession.swift`, `JiraTransport.swift`, `JiraRequest.swift` — перенос (TLS, сессия, подпись Basic, 16 KiB лимит тела ошибки, `Retry-After`).
  - `JiraModels.swift` — `JiraIssue`, `JiraStatus`, `JiraTransition`, `JiraField`, `JiraComment`, `JiraWorklog`, `JiraUser`, `JiraPriority`, `JiraProjectStatuses`, `JiraPage<T>`.
  - `JiraADF.swift` — текстовая проекция, классификатор «простой ADF», сборка из текста.
  - `JiraAdapter.swift` — протокол и `JiraAdapterError`.
  - `JiraCloudAdapter.swift` — реализация на `JiraRESTClient`.
  - `JiraRESTClient.swift` — запросы v3.
  - `JiraDiagnostics.swift` — коды стадий без тел.
- `Sources/MakoshTasks/`
  - `TaskModels.swift` — `Task`, `TaskStatus`, `TaskSource`, `TaskMembership`, `TaskProviderObservation`, `TaskVersion`.
  - `TaskDomain.swift` — чистые правила.
  - `TaskQuickEntry.swift`, `TaskDateParser.swift`.
  - `TaskStore.swift`, `TaskStoreSchema.swift` — PostgreSQL.
  - `TaskUndo.swift`.
  - `TaskJiraAttempt.swift`, `TaskJiraAttemptJournal.swift`.
  - `JiraConnection.swift`, `JiraTokenVault.swift`.
  - `JiraMirror.swift`.
  - `TaskTime.swift`, `TaskTimeService.swift`.
  - `TasksQAIsolation.swift`, `JiraSyntheticAdapter.swift`.
  - `Presentation/TasksWorkspaceModel.swift`.
- `Sources/MakoshApp/Tasks/` — `TasksHost.swift`, `TasksViews.swift`, `TasksSidebar.swift`, `TaskListView.swift`, `JiraBoardView.swift`, `TaskDetailView.swift`, `JiraIssueCard.swift`, `TaskQuickEntryField.swift`, `TaskTimerBar.swift`, `TaskTimeDraftSheet.swift`, `TasksSettingsView.swift`, `TasksSyntheticPreview.swift`.
- `Sources/MakoshApp/Telemost/TelemostViews.swift`, `Sources/MakoshApp/Workspace/WorkspaceView.swift`, `Sources/MakoshApp/MakoshApp.swift` — подключение.
- `scripts/run-tasks-qa.py`.
- `docs/tasks.md`, `docs/architecture.md`, `docs/development-status.md`, `docs/reference-interface.md`, `AGENTS.md`.

---

### Task 1: Референсы и пин Jira

**Files:**
- Modify: `references.lock.json`
- Create: `Dependencies/Jira.lock.json`
- Modify: `THIRD_PARTY_NOTICES.md`, `docs/xerj.md`
- Test: `Tests/MakoshCoreTests/DependencyLockTests.swift` (новый)

**Interfaces:**
- Produces: `Dependencies/Jira.lock.json` `{schemaVersion: 1, source: {url, revision, license}, files: [{path, sha256}]}` — список файлов MacTower, перенесённых в Task 7–8.

- [ ] **Step 1: Write the failing test**

```swift
func testJiraLockNamesTheMacTowerRevision() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Dependencies/Jira.lock.json")
    let lock = try JSONDecoder().decode(DependencyLock.self, from: Data(contentsOf: url))
    XCTAssertEqual(lock.source.revision.count, 40)
    XCTAssertTrue(lock.source.revision.hasPrefix("317eeaf"))
    XCTAssertEqual(lock.source.license, "MIT")
    XCTAssertFalse(lock.files.isEmpty)
}
```
(`DependencyLock` — тестовый `Decodable` в том же файле: `source {url: String, revision: String, license: String}`, `files [{path: String, sha256: String}]`.) Точную полную ревизию взять из `git -C ~/projects/Personal/mac-tower rev-parse HEAD`.

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter DependencyLockTests`
Expected: FAIL — файла `Dependencies/Jira.lock.json` нет.

- [ ] **Step 3: Write the lock, reference entries and notices**

`references.lock.json`: две записи в `references` по образцу существующих — `TaskOrchestrator` (`https://github.com/yuriyda/TaskOrchestrator`, `path: ".references/TaskOrchestrator"`, sha `055c1f173b58f54681806b8293a6c3e4734383b6`, license `MIT`, purpose «правила локального домена задач», xerj prefix `mk-ref-taskorchestrator`) и `mac-tower` (`https://git.sh-inc.ru/avm/mac-tower.git`, `path: ".references/mac-tower"`, полная sha HEAD `317eeaf…`, license `MIT`, purpose «протокольный слой Jira и учёт времени», xerj prefix `mk-ref-mactower`). `Dependencies/Jira.lock.json`: `files` — пути `src/MacTowerWorkTracking/{JiraHTTPSession,JiraTransport,JiraResponseParsing,JiraTaskTransitions,JiraDiagnostics}.swift` с sha256 содержимого на этой ревизии (`git -C … show 317eeaf:<path> | shasum -a 256`). `THIRD_PARTY_NOTICES.md`: раздел «## Jira — перенос из MacTower» (источник, ревизия, MIT, что перенесено, что написано заново). `docs/xerj.md`: абзац «Задачи: референсы» с командами индексации обоих префиксов и пометкой, что индексация выполняется отдельно и до неё поиск по ним не заявлен.

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter DependencyLockTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add references.lock.json Dependencies/Jira.lock.json THIRD_PARTY_NOTICES.md docs/xerj.md Tests/MakoshCoreTests/DependencyLockTests.swift
git commit -m "Pin the task references and the Jira transfer source"
```

---

### Task 2: Цели пакета

**Files:**
- Modify: `Package.swift`
- Create: `Sources/MakoshJira/JiraModels.swift`, `Sources/MakoshTasks/TaskModels.swift`, `Tests/MakoshJiraTests/JiraModelsTests.swift`, `Tests/MakoshTasksTests/TaskModelsTests.swift`
- Modify: `scripts/test.sh` (если бандлы перечислены явно — добавить оба)

**Interfaces:**
- Produces: библиотеки `MakoshJira` (deps: нет, только Foundation/Security/CryptoKit) и `MakoshTasks` (deps: `MakoshCore`, `MakoshJira`, `CPostgres`); `MakoshApp` зависит от обеих.
- Produces: `public enum TaskStatus: String, Codable, CaseIterable, Sendable { case inbox, active, done, cancelled }`; `public struct Task: Codable, Equatable, Identifiable, Sendable` с полями спеки (`id: UUID`, `code: String`, `title`, `status`, `priority: Int`, `list: String?`, `tags: [String]`, `due: Date?`, `start: Date?`, `estimateMinutes: Int?`, `url: URL?`, `postponed: Int`, `dependsOn: [UUID]`, `notes: String`, `source: TaskSource?`, `createdAt`, `updatedAt`, `completedAt: Date?`, `deletedAt: Date?`, `revision: Int64`); `public struct TaskSource: Codable, Hashable, Sendable { public var identity: ServiceIdentity; public var membership: TaskMembership }`; `public enum TaskMembership: String, Codable, Sendable { case assigned, mentioned, kept, none }`.
- Produces: `public struct JiraIssue: Codable, Equatable, Sendable` (`id: String`, `key`, `projectKey`, `summary`, `descriptionADF: Data?`, `descriptionText: String`, `status: JiraStatus`, `issueType: String`, `priority: JiraPriority?`, `assignee: JiraUser?`, `reporter: JiraUser?`, `labels: [String]`, `due: Date?`, `updated: Date`, `browseURL: URL`); `JiraStatus {id, name, category: JiraStatusCategory}`; `enum JiraStatusCategory: String { case new = "new", indeterminate, done, undefined }`; `JiraUser {accountID, displayName}`; `JiraPriority {id, name}`; `public struct JiraPage<T: Sendable>: Sendable { let items: [T]; let nextToken: String? }`.
- Produces: `public static func TaskCode.make(from id: UUID) -> String` — 5 символов Crockford Base32 от первых 25 бит UUID.

- [ ] **Step 1: Write the failing tests**

```swift
// TaskModelsTests
func testCodeIsFiveCrockfordCharacters() {
    let code = TaskCode.make(from: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
    XCTAssertEqual(code.count, 5)
    XCTAssertTrue(code.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) })
}
func testStatusCycleOrder() { XCTAssertEqual(TaskStatus.allCases, [.inbox, .active, .done, .cancelled]) }
// JiraModelsTests
func testStatusCategoryDecodesUnknownAsUndefined() throws {
    let data = Data(#"{"id":"1","name":"X","category":"weird"}"#.utf8)
    XCTAssertEqual(try JSONDecoder().decode(JiraStatus.self, from: data).category, .undefined)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh --filter "TaskModelsTests|JiraModelsTests"`
Expected: FAIL — цели не существуют (ошибка сборки).

- [ ] **Step 3: Add targets and models**

`Package.swift`: `.library(name: "MakoshTasks", …)`, `.library(name: "MakoshJira", …)`, `.target(name: "MakoshJira")`, `.target(name: "MakoshTasks", dependencies: ["MakoshCore", "MakoshJira", "CPostgres"])`, `MakoshApp` += `"MakoshTasks", "MakoshJira"`, `.testTarget(name: "MakoshJiraTests", dependencies: ["MakoshJira"])`, `.testTarget(name: "MakoshTasksTests", dependencies: ["MakoshTasks", "MakoshJira", "MakoshCore", "CPostgres"])`. Модели по Interfaces; `JiraStatusCategory` с `init(from:)`, возвращающим `.undefined` для неизвестного.

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh --filter "TaskModelsTests|JiraModelsTests"`
Expected: PASS, 3 теста.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/MakoshJira Sources/MakoshTasks Tests/MakoshJiraTests Tests/MakoshTasksTests scripts/test.sh
git commit -m "Add the MakoshTasks and MakoshJira targets"
```

---

### Task 3: Правила домена

**Files:**
- Create: `Sources/MakoshTasks/TaskDomain.swift`
- Test: `Tests/MakoshTasksTests/TaskDomainTests.swift`

**Interfaces:**
- Produces: `public enum TaskDomain` с чистыми функциями:
  `static func nextCycleStatus(_ current: TaskStatus, blocked: Bool) -> TaskStatus`;
  `static func isBlocked(_ task: Task, resolve: (UUID) -> Task?) -> Bool` (есть зависимость, чей статус не `done`/`cancelled`; отсутствующая задача не блокирует);
  `static func blockers(_ task: Task, resolve:) -> [Task]`;
  `static func wouldCreateCycle(adding dependency: UUID, to taskID: UUID, resolve:) -> Bool`;
  `static func dependentsToActivate(after completed: UUID, among tasks: [Task]) -> [UUID]` (`inbox`-задачи, у которых все блокеры закрыты);
  `static func isOverdue(_ task: Task, today: Date, calendar: Calendar) -> Bool`;
  `static func postponed(_ task: Task, today: Date, calendar:) -> Task` (срок = max(срок, сегодня) + 1 день; `postponed += 1`);
  `static func applying(status: TaskStatus, to task: Task, now: Date) throws -> Task` (`TaskDomainError.blocked(by: [UUID])` при переводе заблокированной в `active`/`done`; `completedAt` ставится/снимается; повторный `done` возвращает задачу без изменений).
- Produces: `public enum TaskDomainError: Error, Equatable { case blocked(by: [UUID]), cycle, invalidPriority }`.

- [ ] **Step 1: Write the failing tests** — по одному на правило:
  `testFullCycleWrapsAround` (`cancelled` → `inbox`), `testBlockedCycleSkipsActiveAndDone`, `testBlockedTaskCannotBecomeActive` (throws `.blocked(by:)`), `testCancelledBlockerDoesNotBlock`, `testMissingBlockerDoesNotBlock`, `testCycleDetectionThroughTwoHops`, `testCompletionActivatesOnlyFullyUnblockedDependents`, `testOverdueIgnoresDoneAndCancelled`, `testOverdueIsStrictlyBeforeToday`, `testPostponeMovesPastDueToTomorrow`, `testDoneSetsCompletedAtAndRepeatIsNoop`, `testLeavingDoneClearsCompletedAt`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh --filter TaskDomainTests`
Expected: FAIL — `TaskDomain` не определён.

- [ ] **Step 3: Implement `TaskDomain`** — DFS для цикла, без рекурсии глубже множества посещённых.

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh --filter TaskDomainTests`
Expected: PASS, 12 тестов.

- [ ] **Step 5: Commit**

```bash
git add Sources/MakoshTasks/TaskDomain.swift Tests/MakoshTasksTests/TaskDomainTests.swift
git commit -m "Add the task domain rules"
```

---

### Task 4: Быстрый ввод и даты

**Files:**
- Create: `Sources/MakoshTasks/TaskDateParser.swift`, `Sources/MakoshTasks/TaskQuickEntry.swift`
- Test: `Tests/MakoshTasksTests/TaskDateParserTests.swift`, `Tests/MakoshTasksTests/TaskQuickEntryTests.swift`

**Interfaces:**
- Produces: `public enum TaskDateParser { static func parse(_ text: String, today: Date, calendar: Calendar) -> Date? }` — правила спеки (цель 2), регистронезависимо, `ё`=`е`.
- Produces: `public struct TaskQuickEntry: Equatable, Sendable { title: String; list: String?; tags: [String]; priority: Int?; due: Date?; dependencyRefs: [String]; url: URL?; tokens: [Token] }`, `public struct Token: Equatable, Sendable { kind: Kind; text: String; resolved: Bool }`, `enum Kind { text, list, tag, priority, due, dependency, url }`; `public static func parse(_ input: String, today: Date, calendar: Calendar, resolveDependency: (String) -> UUID?) -> TaskQuickEntry` — `~` принимает короткий код или ключ Jira; нераспознанная дата и неизвестная зависимость остаются в названии с `resolved: false`; `>>`, `*`, `/` не распознаются (обычный текст).

- [ ] **Step 1: Write the failing tests**

Даты (today = 2026-11-07, суббота, `Calendar(identifier: .gregorian)`, Москва): `testTodayTomorrowYesterdayRuAndEn`, `testWeekdayIsStrictlyAfterToday` («сб» → 2026-11-14, «пн» → 2026-11-09), `testRelativeOffsets` (`+3d` → 11-10, `+2w` → 11-21, `+1m` → 12-07), `testBareDayRollsToNextMonth` («20» → 11-20, «5» → 12-05), `testDayMonthRollsToNextYear` («20.04» → 2027-04-20, «25/12» → 2026-12-25), `testFullDateAsIs` («20.04.2026»), `testMonthNames` («5янв» → 2027-01-05, «jan5», «15авг» → 2027-08-15), `testGarbageIsNil`.
Ввод: `testTokensAreExtractedInAnyOrder` («Счёт @Работа #финансы !1 ^завтра» → title «Счёт», list, tags, priority 1, due), `testUnparsedDateStaysInTitle` («^когда-нибудь»), `testUnknownDependencyKeyStaysInTitle` (`~ABC-123`, резолвер nil → `dependencyRefs` пуст, title содержит `~ABC-123`, token `.dependency` с `resolved: false`), `testKnownDependencyResolves`, `testUrlIsPickedOnce`, `testFlowRecurrencePersonaAreOrdinaryText`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh --filter "TaskDateParserTests|TaskQuickEntryTests"`
Expected: FAIL — типы не определены.

- [ ] **Step 3: Implement the parser and quick entry**

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh --filter "TaskDateParserTests|TaskQuickEntryTests"`
Expected: PASS, 14 тестов.

- [ ] **Step 5: Commit**

```bash
git add Sources/MakoshTasks/TaskDateParser.swift Sources/MakoshTasks/TaskQuickEntry.swift Tests/MakoshTasksTests/TaskDateParserTests.swift Tests/MakoshTasksTests/TaskQuickEntryTests.swift
git commit -m "Add quick entry and date parsing for tasks"
```

---

### Task 5: Хранилище задач в PostgreSQL

**Files:**
- Create: `Sources/MakoshTasks/TaskStoreSchema.swift`, `Sources/MakoshTasks/TaskStore.swift`, `Tests/MakoshTasksTests/TasksTestSupport.swift` (копия `FilesTestDatabase` под именем `TasksTestDatabase`)
- Test: `Tests/MakoshTasksTests/TaskStoreTests.swift`

**Interfaces:**
- Produces: `public actor TaskStore { public init(connectionString: String, schema: String); public func open() throws; public func close() }`.
  Чтение: `tasks(includeDeleted: Bool = false) throws -> [Task]`, `task(id:) throws -> Task?`, `task(code:)`, `task(source: ServiceIdentity)`.
  Запись (каждая — транзакция + строка `tasks_versions` с `actor: TaskActor` (`.user`, `.provider`), `changedFields: [String]`): `insert(_ task: Task, actor:) throws -> Task`, `update(_ task: Task, expectedRevision: Int64, actor:) throws -> Task` (бросает `TaskStoreError.staleRevision` при расхождении; `revision += 1`, `updatedAt = now`), `softDelete(id:expectedRevision:actor:)`, `restore(id:)`.
  Наблюдения: `saveObservation(_ o: TaskProviderObservation, for taskID: UUID) throws` (строка в `tasks_source_versions` + обновление `tasks_sources`), `latestObservation(taskID:) -> TaskProviderObservation?`, `observations(taskID:limit:)`.
  Настройки: `preferences() -> TaskPreferences`, `savePreferences(_:)` (`sort`, `filter`, `showCompleted` — JSON в `tasks_preferences(id=1)`).
- Produces: `public struct TaskProviderObservation: Codable, Equatable, Sendable { identity: ServiceIdentity; observedAt: Date; raw: Data; issue: JiraIssue; comments: [JiraComment]; myWorklogs: [JiraWorklog]; transitions: [JiraTransition] }` (`JiraComment {id, author: JiraUser, created, updated, bodyADF: Data, bodyText}`, `JiraWorklog {id, author, started, seconds, commentText}`, `JiraTransition {id, name, to: JiraStatus, fields: [JiraField]}`, `JiraField {key, name, required, schemaType: String, allowedValues: [JiraFieldOption]?}` — добавить в `JiraModels.swift`).
- Таблицы (`\(schema).tasks_*`): `tasks_tasks(id UUID PK, code TEXT UNIQUE, data JSONB, status TEXT, due DATE, deleted_at TIMESTAMPTZ, revision BIGINT, updated_at TIMESTAMPTZ)`, `tasks_versions(seq BIGSERIAL PK, task_id UUID, revision BIGINT, actor TEXT, changed TEXT[], data JSONB, at TIMESTAMPTZ)`, `tasks_sources(identity TEXT PK, task_id UUID UNIQUE, membership TEXT, observed_at TIMESTAMPTZ, data JSONB)`, `tasks_source_versions(seq BIGSERIAL PK, identity TEXT, observed_at, data JSONB)`, `tasks_preferences(id SMALLINT PK CHECK(id=1), data JSONB)`; остальные таблицы добавляют Task 9, 11, 12. `open()` создаёт схему и таблицы `IF NOT EXISTS`, имя схемы проверяется `PostgresConnection.isValidSchemaName`.

- [ ] **Step 1: Write the failing tests** (интеграционные, `TasksTestDatabase`, `tearDown` дропает схему):
  `testInsertAssignsCodeAndFirstVersion`, `testUpdateWithStaleRevisionFails`, `testUpdateRecordsChangedFields`, `testSoftDeleteHidesAndRestoreReturns`, `testObservationVersionsAreAppendOnly` (два `saveObservation` → `observations` 2, `latestObservation` второй), `testTaskBySourceIdentity`, `testPreferencesRoundTrip`, `testOpenIsIdempotent`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `MAKOSH_TEST_DATABASE_URL=… scripts/test.sh --filter TaskStoreTests` (`scripts/test.sh` уже задаёт переменную из `.local`; иначе тесты честно падают с сообщением о конфигурации)
Expected: FAIL — `TaskStore` не определён.

- [ ] **Step 3: Implement schema and store** — SQL через `PostgresConnection.query/execute/transaction`; JSON — `JSONEncoder` с `.iso8601`; `code` при коллизии (UNIQUE) пересчитывается от нового UUID до 3 раз.

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh --filter TaskStoreTests`
Expected: PASS, 8 тестов.

- [ ] **Step 5: Commit**

```bash
git add Sources/MakoshTasks/TaskStore.swift Sources/MakoshTasks/TaskStoreSchema.swift Sources/MakoshJira/JiraModels.swift Tests/MakoshTasksTests
git commit -m "Add the PostgreSQL task store with versions and observations"
```

---

### Task 6: Undo

**Files:**
- Create: `Sources/MakoshTasks/TaskUndo.swift`
- Test: `Tests/MakoshTasksTests/TaskUndoTests.swift`

**Interfaces:**
- Produces: `public struct TaskUndoStep: Sendable { taskID: UUID; before: Task; after: Task; at: Date }`; `public struct TaskUndoHistory: Sendable { init(limit: Int = 5, lifetime: TimeInterval = 12*3600); mutating func record(_ step: TaskUndoStep); mutating func clear(); mutating func pop(now: Date) -> TaskUndoStep? }` — `pop` отбрасывает просроченные; `record` хранит не больше `limit`.
- Producer применения — Task 13: `undo()` берёт шаг, читает задачу из `TaskStore`, и если `task.revision != step.after.revision` — шаг недоступен (сообщение «задача менялась»), иначе `update(step.before, expectedRevision:)`.

- [ ] **Step 1: Write the failing tests** — `testKeepsAtMostFiveSteps`, `testExpiredStepIsDropped`, `testClearEmptiesHistory`, `testPopIsLIFO`.
- [ ] **Step 2: Run** `scripts/test.sh --filter TaskUndoTests` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — Expected: PASS, 4 теста.
- [ ] **Step 5: Commit** — `git commit -m "Add short-lived task undo history"`.

---

### Task 7: Перенос протокольного слоя Jira и чтение

**Files:**
- Create: `Sources/MakoshJira/JiraHTTPSession.swift`, `JiraTransport.swift`, `JiraRequest.swift`, `JiraDiagnostics.swift`, `JiraAdapter.swift`, `JiraRESTClient.swift`, `JiraCloudAdapter.swift`
- Create: `Tests/MakoshJiraTests/JiraStub.swift` (по образцу `PaperlessStubProtocol`), `Tests/MakoshJiraTests/Fixtures/*.json`
- Test: `Tests/MakoshJiraTests/JiraTransportTests.swift`, `Tests/MakoshJiraTests/JiraCloudAdapterReadTests.swift`

**Interfaces:**
- Consumes: Task 1 перечень файлов MacTower; содержимое берётся командой `git -C ~/projects/Personal/mac-tower show 317eeaf:<path>` при переносе (один раз, руками исполнителя; результат — файлы в репозитории Makosh, без ссылки на чекаут).
- Produces: `public struct JiraCredential: Sendable { origin: URL; email: String; apiToken: String }` (`CustomStringConvertible` — «JiraCredential(redacted)»), `public struct JiraTransport: Sendable { init(credential: JiraCredential, session: URLSession = …); func send(_ request: JiraRequest) async throws -> Data }` — перенос без OAuth1 и custom CA (вырезаются; `JiraOAuth1Signing` не переносится), Basic-авторизация, 30 с таймаут, лимит тела ошибки 16 KiB, `JiraAdapterError.rateLimited(retryAfter: TimeInterval?)` для 429/503 с `Retry-After`, `.unauthorized` (401/403), `.notFound` (404), `.invalidCursor` (400 с документированным сообщением), `.http(status: Int)`, `.transport(code: String)` — ни один не несёт тело или URL.
- Produces: `public protocol JiraAdapter: Sendable` — `currentUser() async throws -> JiraUser`; `searchIssues(jql: String, nextToken: String?, limit: Int) async throws -> JiraPage<JiraIssue>` (`POST /rest/api/3/search/jql`, fields: summary, description, status, issuetype, priority, assignee, reporter, labels, duedate, updated, project); `issue(id: String) async throws -> JiraIssue`; `transitions(issueID:) async throws -> [JiraTransition]` (`expand=transitions.fields`); `comments(issueID:, nextToken:) async throws -> JiraPage<JiraComment>`; `worklogs(issueID:) async throws -> [JiraWorklog]`; `projectStatuses(projectKey:) async throws -> [JiraStatus]`; `priorities() async throws -> [JiraPriority]`; `assignableUsers(projectKey:, query:) async throws -> [JiraUser]`; записи — Task 8.
- Produces: `public struct JiraCloudAdapter: JiraAdapter { public init(credential: JiraCredential, session: URLSession = …) }`.

- [ ] **Step 1: Write the failing tests** — транспорт: `testBasicAuthorizationHeaderIsSet`, `testRateLimitedCarriesRetryAfterSeconds`, `testErrorBodyIsNeverInTheError` (тело «secret-body» → `String(describing: error)` не содержит), `testInvalidCursorMessageMapsToInvalidCursor`; чтение на фикстурах (файлы `search.json`, `issue.json`, `transitions.json`, `comments.json`, `worklogs.json`, `project-statuses.json`, `priorities.json`, `assignable.json` — составить по документации v3, минимальные): `testSearchDecodesIssuesAndNextToken`, `testIssueDescriptionTextIsProjected` (ADF абзацы → текст с `\n`), `testTransitionsIncludeRequiredFields`, `testCommentsPageDecodes`, `testWorklogsDecodeStartedWithOffset`, `testProjectStatusesDecode`, `testAssignableUsersQueryIsSent`.

- [ ] **Step 2: Run** `scripts/test.sh --filter "JiraTransportTests|JiraCloudAdapterReadTests"` — Expected: FAIL.

- [ ] **Step 3: Transfer and implement** — перенести файлы из Task 1, убрать `MacTowerCore`, OAuth1, custom CA и Data Center ветки; `JiraRESTClient` переписать под v3 и новые модели; `JiraADF.text(from:)` временно минимальный (полный — Task 8).

- [ ] **Step 4: Run** — Expected: PASS, 11 тестов.

- [ ] **Step 5: Commit**

```bash
git add Sources/MakoshJira Tests/MakoshJiraTests
git commit -m "Transfer the Jira transport and add Cloud reads"
```

---

### Task 8: Записи Jira и ADF

**Files:**
- Create: `Sources/MakoshJira/JiraADF.swift`
- Modify: `Sources/MakoshJira/JiraAdapter.swift`, `JiraRESTClient.swift`, `JiraCloudAdapter.swift`
- Test: `Tests/MakoshJiraTests/JiraADFTests.swift`, `Tests/MakoshJiraTests/JiraCloudAdapterWriteTests.swift`

**Interfaces:**
- Produces: `public enum JiraADF { static func text(from adf: Data) -> String; static func isSimple(_ adf: Data) -> Bool` (только `doc`, `paragraph`, `text` с `strong`/`em`/`link`, `hardBreak`, `mention`, `bulletList`/`orderedList`/`listItem`); `static func document(fromText text: String, mentions: [String: String] = [:]) -> Data` (абзацы по пустой строке, строки → `hardBreak`; `@accountId` из `mentions` → узел `mention`).
- Produces (в `JiraAdapter`): `addWorklog(issueID:, started: Date, seconds: Int, comment: String?) async throws -> String` (worklog id); `addComment(issueID:, body: Data) async throws -> String`; `transition(issueID:, transitionID:, fields: [String: JiraFieldValue]) async throws`; `updateFields(issueID:, patch: JiraIssuePatch) async throws` (`JiraIssuePatch { summary: String?; descriptionADF: Data?; priorityID: String?; due: Date??; labels: [String]? }`); `assign(issueID:, accountID: String?) async throws`.
- Produces: `public enum JiraFieldValue: Codable, Equatable, Sendable { case text(String), number(Double), date(Date), option(id: String), resolution(id: String) }`; `public enum JiraFieldSupport { static func isSupported(_ field: JiraField) -> Bool }` — `string`, `number`, `date`, `option`, `resolution`; `static func unsupportedRequired(_ transition: JiraTransition) -> [JiraField]`.

- [ ] **Step 1: Write the failing tests** — ADF: `testParagraphsAndHardBreaksProject`, `testMentionProjectsAsDisplayName`, `testTableIsNotSimple`, `testMediaIsNotSimple`, `testSimpleListIsSimple`, `testDocumentFromTextRoundTrips`; записи (стаб проверяет метод, путь и тело): `testAddWorklogSendsStartedInJiraFormat` (`yyyy-MM-dd'T'HH:mm:ss.SSSZ`, `timeSpentSeconds`), `testAddWorklogUnderSixtySecondsIsRefusedLocally` (`JiraAdapterError.invalidRequest`, запросов 0), `testAddCommentSendsADF`, `testTransitionSendsFields`, `testTransitionWithUnsupportedRequiredFieldIsBlockedBeforeSend` (`JiraFieldSupport.unsupportedRequired` непуст → адаптер бросает `.unsupportedFields([...])`, запросов 0), `testRichDescriptionIsReadOnly` (`updateFields` с `descriptionADF` при `isSimple == false` исходного — проверяется вызывающим: `JiraIssuePatch.validate(against: JiraIssue)` бросает `.descriptionNotEditable`), `testAssignSendsAccountIDAndNullUnassigns`.

- [ ] **Step 2: Run** `scripts/test.sh --filter "JiraADFTests|JiraCloudAdapterWriteTests"` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — Expected: PASS, 13 тестов.
- [ ] **Step 5: Commit** — `git commit -m "Add Jira writes and ADF handling"`.

---

### Task 9: Журнал попыток Jira

**Files:**
- Create: `Sources/MakoshTasks/TaskJiraAttempt.swift`, `Sources/MakoshTasks/TaskJiraAttemptJournal.swift`
- Modify: `Sources/MakoshTasks/TaskStoreSchema.swift`, `TaskStore.swift`
- Test: `Tests/MakoshTasksTests/TaskJiraAttemptJournalTests.swift`

**Interfaces:**
- Produces: `public struct TaskJiraAttempt: Codable, Equatable, Identifiable, Sendable { id: UUID; taskID: UUID; connectionID: UUID; issueID: String; kind: Kind; payload: Payload; state: State; createdAt; updatedAt; resolvedAt: Date?; resultID: String?; reason: String? }`, `enum Kind: String { transition, worklog, comment, fields, assignee }`, `enum State: String { queued, sent, unknown, confirmed, rejected }`, `enum Payload: Codable { case transition(id: String, fields: [String: JiraFieldValue]); case worklog(started: Date, seconds: Int, comment: String?, entryID: UUID); case comment(text: String, adf: Data); case fields(JiraIssuePatch); case assignee(accountID: String?) }`.
- Produces: `TaskStore`: `attempts(taskID:) -> [TaskJiraAttempt]`, `openAttempts() -> [TaskJiraAttempt]` (`queued|sent|unknown`), `insertAttempt`, `updateAttempt(_:expectedState:)` (только разрешённые переходы: `queued→sent`, `sent→confirmed|rejected|unknown`, `unknown→confirmed|rejected`; иначе `TaskStoreError.invalidTransition`); таблица `tasks_jira_attempts(id UUID PK, task_id, connection_id, issue_id, kind, state, data JSONB, created_at, updated_at, resolved_at)`.
- Produces: `public actor TaskJiraAttemptJournal { init(store: TaskStore, adapter: @Sendable (UUID) async -> (any JiraAdapter)?); func submit(_ attempt: TaskJiraAttempt) async -> TaskJiraAttempt` (отказ, если по `(taskID, kind)` есть открытая попытка → возвращает её с `reason: "уже выполняется"`; иначе `sent`, вызов адаптера, `confirmed` с `resultID` / `rejected` с кодом / `unknown` при таймауте, обрыве, 5xx без ответа); `func resume() async` (все `sent` → `unknown` с `reason: "перезапуск"`); `func resolve(_ id: UUID) async -> TaskJiraAttempt` (сверка по виду: worklog — `worklogs(issueID)` и совпадение автора, `started` ±1 с, `seconds`, текст; comment — `comments` по автору и тексту; transition — `issue(id).status.id == transition.to.id`; fields — сравнение полей; assignee — `assignee?.accountID`; одно совпадение → `confirmed`, ноль → `rejected("не найдено")`, несколько → остаётся `unknown` с `reason: "несколько совпадений"`); `func dismiss(_ id: UUID) async` (`unknown → rejected("отказ пользователя")`).

- [ ] **Step 1: Write the failing tests** (фейковый `JiraAdapter` в тестах: `FakeJiraAdapter` с настраиваемыми ответами и записью вызовов; хранилище — `TasksTestDatabase`): `testSubmitConfirmsWithResultID`, `testSubmitRejectedKeepsCodeOnly`, `testTimeoutLeavesUnknownAndNeverRetries` (после `resume()` и повторного `submit` того же вида — отказ «уже выполняется», вызовов адаптера ровно 1), `testResumeTurnsSentIntoUnknown`, `testResolveWorklogByExactMatch`, `testResolveWorklogAmbiguousStaysUnknown`, `testResolveTransitionByStatus`, `testDismissRejects`, `testStoreRefusesInvalidStateTransition`.

- [ ] **Step 2: Run** `scripts/test.sh --filter TaskJiraAttemptJournalTests` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — Expected: PASS, 9 тестов.
- [ ] **Step 5: Commit** — `git commit -m "Add the Jira attempt journal"`.

---

### Task 10: Зеркало Jira

**Files:**
- Create: `Sources/MakoshTasks/JiraMirror.swift`
- Modify: `Sources/MakoshTasks/TaskStore.swift` (`sources(connectionID:)`, `setMembership(taskID:_:)`)
- Test: `Tests/MakoshTasksTests/JiraMirrorTests.swift`

**Interfaces:**
- Consumes: `TaskStore` (Task 5), `JiraAdapter` (Task 7), `TaskDomain.applying` (Task 3).
- Produces: `public actor JiraMirror { init(store: TaskStore, connectionID: UUID, adapter: any JiraAdapter, accountID: String, mentions: Bool, now: @Sendable () -> Date = Date.init); func sync(full: Bool) async -> JiraMirrorResult; func refresh(issueID: String) async throws -> TaskProviderObservation }`.
  JQL: `assignee = currentUser()` + (при `mentions`) ` OR comment ~ "<accountID>"`, обёрнутые в скобки, ` AND updated >= "<окно>"` при `full == false` (окно = последний успешный `sync` минус 10 минут, формат `yyyy-MM-dd HH:mm`), ` ORDER BY updated ASC`; страницы по 50, `nextToken` до конца.
  Применение каждой задачи: нет записи по `ServiceIdentity(service: "jira", accountID: connectionID.uuidString, externalID: issue.id)` → `insert` `Task(status: .inbox, priority: 4, title: issue.summary, url: browseURL, source: assigned|mentioned)` + `saveObservation`; есть → `saveObservation`, `membership` по текущему признаку (`assignee == me` → `assigned`, иначе `mentioned`), `title`/`url` обновляются, если пользователь их не менял (сравнение с предыдущим наблюдением); `issue.status.category == .done` и локальный статус не `done`/`cancelled` → `TaskDomain.applying(.done)` через `update(actor: .provider)`.
  При `full == true` задачи подключения, не вернувшиеся в выборке: `kept`, если `status == .active` или есть открытая попытка или запись времени без `confirmed` worklog или идущий таймер по ней (запросы к `TaskStore`), иначе `none`.
  `JiraMirrorResult { applied: Int; left: Int; mentionsUnavailable: Bool; deferredUntil: Date?; failure: String? }`; `rateLimited(retryAfter)` → `deferredUntil = now + (retryAfter ?? backoff)` с backoff 5 с ×2 до 1 ч между неудачами, применённые страницы сохраняются; `.http(400)` на JQL с `comment ~` → повтор без части упоминаний в том же `sync` и `mentionsUnavailable = true`; `.invalidCursor` → одна перезапуска страницы с `nextToken = nil` на этот `sync`.
- Produces: `TaskStore.setMembership(taskID: UUID, _ membership: TaskMembership) throws`, `sources(connectionID: UUID) throws -> [(taskID: UUID, source: TaskSource)]`.

- [ ] **Step 1: Write the failing tests** (`FakeJiraAdapter`, `TasksTestDatabase`): `testNewAssignedIssueBecomesInboxTask`, `testMentionedIssueIsMarkedMentioned`, `testChangedIssueAppendsObservationAndKeepsLocalLayer` (локальный приоритет 1 и список остаются), `testUserEditedTitleIsNotOverwritten`, `testDoneCategoryCompletesLocalTask`, `testDoneCategoryDoesNotTouchCancelled`, `testLeftIssueWithActiveStatusIsKept`, `testLeftIssueWithoutActivityIsNone`, `testRateLimitMidPageKeepsAppliedPagesAndDefers` (страница 1 ок, страница 2 → 429 без `Retry-After`: `applied == 50`, `deferredUntil ≈ now+5s`, задачи страницы 1 в хранилище), `testMentionsQueryRejectedFallsBackToAssigned`, `testInvalidCursorRestartsPageOnce`, `testIncrementalWindowUsesLastSync`.

- [ ] **Step 2: Run** `scripts/test.sh --filter JiraMirrorTests` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — Expected: PASS, 12 тестов.
- [ ] **Step 5: Commit** — `git commit -m "Mirror assigned and mentioned Jira issues into tasks"`.

---

### Task 11: Подключения Jira

**Files:**
- Create: `Sources/MakoshTasks/JiraConnection.swift`, `Sources/MakoshTasks/JiraTokenVault.swift`
- Modify: `Sources/MakoshTasks/TaskStoreSchema.swift`, `TaskStore.swift`
- Test: `Tests/MakoshTasksTests/JiraConnectionTests.swift`

**Interfaces:**
- Produces: `public struct JiraConnection: Codable, Equatable, Identifiable, Sendable { id: UUID; name: String; origin: URL; email: String; accountID: String?; pollInterval: TimeInterval (300); mentions: Bool (true); suggestWorklog: Bool (true); lastSyncAt: Date?; lastFailure: String?; mentionsUnavailable: Bool }`, `func validated() throws -> JiraConnection` (`https`, хост непустой, без пути/запроса, почта с одним `@`).
- Produces: `public actor JiraTokenVault { init(access: JiraKeychainAccess = .system); load(connectionID:) throws -> String?; save(_ token: String, connectionID:) throws (trim; перевод строки/управляющие → TasksFailure.invalidToken); remove(connectionID:) }` по образцу `FileStorageTokenVault` на `MakoshSecretStore` (`service: "org.makosh.jira"`, `account: <uuid>`), `JiraKeychainAccess.memory()` для тестов и QA.
- Produces: `TaskStore`: `connections() -> [JiraConnection]`, `saveConnection(_:)`, `removeConnection(id:)` (таблица `tasks_jira_connections(id UUID PK, data JSONB)`; удаление не трогает задачи — их `membership` становится `none` через `setMembership`, а `TaskSource.identity` остаётся).
- Produces: `public enum TasksFailure: Error, LocalizedError, Equatable { invalidToken, invalidConnection(String), unauthorized, unavailable, storage(String), blocked([String]), cycle, staleRevision, attemptInFlight, descriptionNotEditable, unsupportedFields([String]) }` с русскими описаниями.

- [ ] **Step 1: Write the failing tests** — `testValidationRejectsHttpAndPath`, `testTokenWithNewlineIsRejected`, `testRemoveDeletesTokenBeforeConnection` (фейковый Keychain с записью порядка вызовов; при падении удаления подключения токен уже удалён), `testRemoveKeepsTasksWithMembershipNone`, `testConnectionsRoundTrip`.
- [ ] **Step 2: Run** `scripts/test.sh --filter JiraConnectionTests` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — Expected: PASS, 5 тестов.
- [ ] **Step 5: Commit** — `git commit -m "Add Jira connections and the token vault"`.

---

### Task 12: Учёт времени

**Files:**
- Create: `Sources/MakoshTasks/TaskTime.swift`, `Sources/MakoshTasks/TaskTimeService.swift`
- Modify: `Sources/MakoshTasks/TaskStoreSchema.swift`, `TaskStore.swift`
- Test: `Tests/MakoshTasksTests/TaskTimeServiceTests.swift`

**Interfaces:**
- Produces: `public struct TaskTimeEntry: Codable, Equatable, Identifiable, Sendable { id: UUID; taskID: UUID; source: Source; startedAt: Date; seconds: Int; note: String; meetingID: UUID?; attemptID: UUID?; worklogID: String?; worklogState: WorklogState (.none, .pending, .confirmed, .deletedInJira); createdAt; updatedAt }`, `enum Source: String { timer, manual, meeting }`; `public struct TaskTimer: Codable, Equatable, Sendable { taskID: UUID; startedAt: Date; note: String }`; `public struct TaskTimeDraft: Equatable, Sendable { id: UUID; taskID: UUID; source: Source; startedAt: Date; seconds: Int; note: String; meetingID: UUID?; sendToJira: Bool }`.
- Produces: `TaskStore`: `timer() -> TaskTimer?`, `saveTimer(_:)`, `clearTimer()`, `entries(taskID:)`, `entries(from: Date, to: Date)`, `insertEntry(_:)` (UNIQUE по `id` — повторная вставка того же черновика → `TaskStoreError.duplicate`), `updateEntry(_:)`, `deleteEntry(id:)` (отказ `TasksFailure.entryLocked`, если `worklogState == .confirmed`); таблицы `tasks_time_entries(id UUID PK, task_id, started_at, seconds, data JSONB)`, `tasks_timer(id SMALLINT PK CHECK(id=1), data JSONB)`.
- Produces: `public actor TaskTimeService { init(store: TaskStore, journal: TaskJiraAttemptJournal, connections: @Sendable () async -> [JiraConnection]); func start(taskID: UUID, note: String) async throws -> TaskTimer` (идущий таймер по другой задаче → `TasksFailure.timerRunning(taskID)`, вызывающий сначала `stop`); `func stop() async throws -> TaskTimeDraft` (`seconds` округлён вверх до 60; `sendToJira` = задача с источником Jira и `suggestWorklog` подключения); `func draft(manual taskID: UUID, startedAt: Date, seconds: Int, note: String, meetingID: UUID?) -> TaskTimeDraft`; `func confirm(_ draft: TaskTimeDraft) async throws -> TaskTimeEntry` (вставка записи с `id = draft.id`; при `sendToJira` — `journal.submit(.worklog(... entryID))`, `attemptID` и `worklogState = .pending`; подтверждённая попытка → `worklogID`, `.confirmed`); `func applyWorklogs(_ worklogs: [JiraWorklog], taskID: UUID) async throws` (запись с `worklogID`, которого нет в списке → `.deletedInJira`; изменённые `started`/`seconds` → обновить запись); `func summary(day: Date, calendar:) -> (daySeconds: Int, weekSeconds: Int)`.

- [ ] **Step 1: Write the failing tests** — `testStartPersistsTimerAcrossReopen` (новый `TaskStore` над той же схемой видит таймер), `testStopRoundsUpToWholeMinute` (90 с → 120), `testStartWhileRunningIsRefused`, `testConfirmCreatesEntryAndWorklogAttemptForJiraTask`, `testConfirmWithoutJiraKeepsLocalEntry`, `testConfirmingTheSameDraftTwiceCreatesOneEntry` (второй `confirm` → `duplicate`, попыток 1), `testConfirmedEntryIsLockedForEditAndDelete`, `testWorklogDeletedInJiraMarksEntry`, `testWorklogChangedInJiraUpdatesEntry`, `testDaySummaryUsesLocalCalendar`.

- [ ] **Step 2: Run** `scripts/test.sh --filter TaskTimeServiceTests` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — Expected: PASS, 10 тестов.
- [ ] **Step 5: Commit** — `git commit -m "Add task time entries, the timer and worklog drafts"`.

---

### Task 13: Модель раздела

**Files:**
- Create: `Sources/MakoshTasks/Presentation/TasksWorkspaceModel.swift`, `Sources/MakoshTasks/TasksService.swift`
- Test: `Tests/MakoshTasksTests/TasksWorkspaceModelTests.swift`

**Interfaces:**
- Produces: `public actor TasksService { init(store: TaskStore, vault: JiraTokenVault, adapterFactory: @Sendable (JiraConnection, String) -> any JiraAdapter = { JiraCloudAdapter(credential: …) }); func open(configuration: ContactWorkspaceConfiguration) async throws; snapshot() async -> TasksSnapshot; journal: TaskJiraAttemptJournal; time: TaskTimeService; mirrors: [UUID: JiraMirror]; func startPolling(); func stopPolling(); func syncNow(connectionID:) }` — поллинг по `pollInterval` каждого подключения, уважая `deferredUntil`; `resume()` журнала при `open`.
- Produces: `public struct TasksSnapshot: Sendable { tasks: [Task]; observations: [UUID: TaskProviderObservation]; attempts: [UUID: [TaskJiraAttempt]]; entries: [UUID: [TaskTimeEntry]]; timer: TaskTimer?; connections: [JiraConnection]; projectStatuses: [UUID: [String: [JiraStatus]]] }`.
- Produces: `@MainActor public final class TasksWorkspaceModel: ObservableObject` — `@Published` `space: TasksSpace (.mine, .jira(connectionID))`, `filter: TasksFilter (.today, .tomorrow, .week, .month, .overdue, .status(TaskStatus), .list(String), .tag(String), .all)`, `sort: TasksSort`, `search: String`, `visible: [Task]`, `board: [JiraBoardColumn]` (`{status: JiraStatus, tasks: [Task]}` по `projectStatuses` проекта или по категориям, когда статусов > 8), `selected: UUID?`, `timer`, `timerElapsed: Int`, `drafts: TaskTimeDraft?`, `error: String?`, `quickEntryPreview: TaskQuickEntry?`; методы `refresh()`, `create(quickEntry: String)`, `cycleStatus(id:)`, `set(status:id:)`, `set(priority:id:)`, `postpone(id:)`, `delete(id:)`, `undo()` (Task 6 правило), `addDependency(id:on:)`, `jira(_ action: JiraAction, id:)` (`enum JiraAction { transition(id, fields), comment(text), fields(JiraIssuePatch), assign(accountID?) }` → `journal.submit`), `resolveAttempt(id:)`, `dismissAttempt(id:)`, `startTimer(id:)`, `stopTimer()`, `confirmDraft(_:)`, `logManual(id:startedAt:seconds:note:)`, `keep(id:)`/`unkeep(id:)` (membership `kept`/`none`); фильтры и сортировка сохраняются через `savePreferences`.
- Фильтр `.mine`: `membership != .none` или `source == nil`, `deletedAt == nil`; `.jira(c)`: `membership != .none` и источник подключения `c`.

- [ ] **Step 1: Write the failing tests** (модель над `TasksService` с фейковым адаптером и `TasksTestDatabase`): `testMineHidesNoneMembershipAndDeleted`, `testQuickEntryCreatesTaskWithTokens`, `testCycleStatusRespectsBlocking` (ошибка «ждёт: …» в `error`), `testUndoRestoresPreviousTaskAndStopsAfterLaterEdit`, `testUndoIsClearedByMirrorApply`, `testJiraTransitionGoesThroughJournal`, `testBoardColumnsFollowProjectStatuses`, `testBoardFallsBackToCategoriesWhenManyStatuses`, `testTimerElapsedTicks` (инъекция часов), `testPreferencesPersistAcrossModels`.

- [ ] **Step 2: Run** `scripts/test.sh --filter TasksWorkspaceModelTests` — Expected: FAIL.
- [ ] **Step 3: Implement** — по образцу `FilesWorkspaceModel`; никаких SQL/сетевых вызовов в модели, только `TasksService`.
- [ ] **Step 4: Run** — Expected: PASS, 10 тестов.
- [ ] **Step 5: Commit** — `git commit -m "Add the tasks workspace model and service"`.

---

### Task 14: QA-изоляция и синтетическая Jira

**Files:**
- Create: `Sources/MakoshTasks/TasksQAIsolation.swift`, `Sources/MakoshTasks/JiraSyntheticAdapter.swift`, `scripts/run-tasks-qa.py`
- Test: `Tests/MakoshTasksTests/TasksQAIsolationTests.swift`, `Tests/MakoshTasksTests/JiraSyntheticAdapterTests.swift`

**Interfaces:**
- Produces: `public enum TasksQAIsolation { static let flag = "--tasks-synthetic-preview"; static let schemaPrefix = "qa_tasks_"; static func validate(configuration:arguments:) throws }` — те же правила, что `FilesQAIsolation` (loopback, префикс, длина ≤ 63); `TasksSyntheticSeed.seed(store: TaskStore) async throws` — 12 локальных задач (просроченная, заблокированная, с зависимостью, с тегами и списками), подключение «Синтетическая Jira» с `JiraKeychainAccess.memory()`.
- Produces: `public actor JiraSyntheticAdapter: JiraAdapter` — 6 задач двух проектов (`QA`, `OPS`), статусы `To Do → In Progress → Done` с переходом `Done`, требующим `resolution`; одна задача с таблицей в описании; одна с упоминанием; `addWorklog`/`addComment`/`transition`/`updateFields`/`assign` меняют состояние и возвращают id; настраиваемый `failNext: JiraAdapterError?` для показа `unknown`.
- Produces: `scripts/run-tasks-qa.py` — копия `run-files-qa.py` с `qa_tasks_`, `CFBundleIdentifier org.makosh.tasks.qa`, флагом `--tasks-synthetic-preview`.

- [ ] **Step 1: Write the failing tests** — `testValidateRequiresLoopbackAndPrefix`, `testSeedCreatesBlockedAndOverdueTasks`, `testSyntheticTransitionRequiresResolution`, `testSyntheticWorklogAppearsInIssueWorklogs`, `testFailNextProducesTheErrorOnce`.
- [ ] **Step 2: Run** `scripts/test.sh --filter "TasksQAIsolationTests|JiraSyntheticAdapterTests"` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — Expected: PASS, 5 тестов.
- [ ] **Step 5: Commit** — `git commit -m "Add tasks QA isolation and a synthetic Jira"`.

---

### Task 15: Раздел в приложении — хост, витрины, карточка, таймер, настройки

**Files:**
- Create: `Sources/MakoshApp/Tasks/{TasksHost,TasksViews,TasksSidebar,TaskListView,JiraBoardView,TaskDetailView,TaskQuickEntryField,TaskTimerBar,TaskTimeDraftSheet,TasksSettingsView,TasksSyntheticPreview}.swift`
- Modify: `Sources/MakoshApp/Workspace/WorkspaceView.swift` (`Destination.tasks = "Задачи"`, символ `checklist`, `sectionDetail`), `Sources/MakoshApp/MakoshApp.swift` (хост в окружении, вкладка Настройки «Задачи» с тегом `MakoshSettingsTab.tasks`, ветка `--tasks-synthetic-preview` как у Files/Telemost)
- Test: сборка; `Tests/MakoshTasksTests/TasksSyntheticTests.swift` (сид + модель: витрина «Мои» 12 + зеркальные, доска 3 колонки)

**Interfaces:**
- Consumes: `TasksWorkspaceModel`, `TasksService`, `TasksQAIsolation` (Task 13–14); образцы `FilesHost` (окружение `\.tasksHost`), `FilesDetailView` (правая колонка), `FilesSettingsView`, `FilesSyntheticPreview`.
- Produces: `@MainActor final class TasksHost: ObservableObject { let model: TasksWorkspaceModel; let service: TasksService; func open(configuration:) async; var pendingTimeDraft: TaskTimeDraft? ; func logTime(taskID: UUID?, title: String, notes: String, meetingID: UUID) ; func offerTimer(title: String, notes: String) -> UUID? }` — две последние для Telemost (Task 17): ключ Jira по регулярному выражению спеки в `title`/`notes` → задача по `TaskStore.task(source:)` через наблюдение с таким `key`.
- Представление: слева фильтры и подключения (счётчики), середина — `TaskListView` (строка: чекбокс, код, приоритет цветом 1 красный / 2 оранжевый / 3 синий / 4 серый, название, список, теги, срок с просрочкой, замок для заблокированных с причиной во всплывающей подсказке, значок Jira с ключом) или `JiraBoardView` (колонки, карточки с ключом и названием); сверху `TaskQuickEntryField` с предпросмотром токенов; внизу `TaskTimerBar` (идущий таймер, сводка дня/недели, «Отменить» `⌘Z`); справа `TaskDetailView` (локальный слой + время) с верхней частью `JiraIssueCard` для задач Jira (Task 16). Клавиши референса: `Space` done/reopen, `S` цикл, `1–4` приоритет, `⇧P` отложить, `⌫` удалить, `⌘N` быстрый ввод, `⌘Z` undo.
- Настройки → Задачи: список подключений, «Добавить» (название, адрес, почта, токен `SecureField`), «Проверить» (`myself` → имя), период опроса, «Искать упоминания», «Предлагать worklog».

- [ ] **Step 1: Write the failing test** — `TasksSyntheticTests.testSeedFillsBothSpaces` (сид → модель: `visible.count == 12 + 6` в «Мои» после `sync`, доска подключения — 3 колонки).
- [ ] **Step 2: Run** `scripts/test.sh --filter TasksSyntheticTests` — Expected: FAIL.
- [ ] **Step 3: Implement views, host and wiring; build** — `swift build --product Makosh`.
- [ ] **Step 4: Run** `scripts/test.sh --filter TasksSyntheticTests` и `swift build --product Makosh` — Expected: PASS; сборка без ошибок и новых предупреждений.
- [ ] **Step 5: Commit** — `git commit -m "Add the Tasks section with local and Jira spaces"`.

---

### Task 16: Карточка Jira — пять действий

**Files:**
- Create: `Sources/MakoshApp/Tasks/JiraIssueCard.swift`, `Sources/MakoshApp/Tasks/JiraTransitionSheet.swift`, `Sources/MakoshApp/Tasks/JiraAssignSheet.swift`, `Sources/MakoshApp/Tasks/JiraAttemptRow.swift`
- Modify: `Sources/MakoshApp/Tasks/TaskDetailView.swift`
- Test: `Tests/MakoshTasksTests/JiraActionsModelTests.swift` (модельные проверки на синтетике)

**Interfaces:**
- Consumes: `TasksWorkspaceModel.jira(_:id:)`, `JiraFieldSupport`, `JiraADF.isSimple`, `TaskJiraAttempt.State`.
- Produces: карточка — ключ со ссылкой «Открыть в Jira», статус и кнопки переходов (переход с полями → `JiraTransitionSheet`: текст, число, дата, одиночный выбор, resolution; неподдерживаемое обязательное поле → строка «заполняется только в Jira» и ссылка, кнопка отправки выключена), исполнитель с «Передать…» (`JiraAssignSheet`: поиск `assignableUsers` от 2 символов, «Снять назначение»), приоритет (меню из `priorities()`), срок, метки, описание (редактор только при `isSimple`, иначе текст и «Открыть в Jira»), комментарии (последние 20, поле ответа, `⌘↩` отправить), мои worklog; строка попытки `JiraAttemptRow` со состояниями «Отправляется / Принято / Отклонено: причина / Неизвестно: Проверить · Отказаться».

- [ ] **Step 1: Write the failing tests** — `testTransitionRequiringResolutionIsSentWithField`, `testUnsupportedRequiredFieldBlocksSubmit` (модель помечает действие `blocked` без вызова журнала), `testRichDescriptionIsNotEditable`, `testAssignUnassignSendsNil`, `testUnknownAttemptShowsResolveAndDismiss`.
- [ ] **Step 2: Run** `scripts/test.sh --filter JiraActionsModelTests` — Expected: FAIL.
- [ ] **Step 3: Implement; build.**
- [ ] **Step 4: Run** tests + `swift build --product Makosh` — Expected: PASS, 5 тестов; сборка чистая.
- [ ] **Step 5: Commit** — `git commit -m "Add the Jira issue card with its five actions"`.

---

### Task 17: Время встречи Telemost

**Files:**
- Create: `Sources/MakoshTasks/TaskMeetingLink.swift`
- Modify: `Sources/MakoshApp/Telemost/TelemostViews.swift`, `Sources/MakoshApp/Tasks/TasksHost.swift`
- Test: `Tests/MakoshTasksTests/TaskMeetingLinkTests.swift`

**Interfaces:**
- Produces: `public enum TaskMeetingLink { static let keyPattern = #"(?<![A-Z0-9])[A-Z][A-Z0-9_]{1,19}-[1-9][0-9]{0,9}(?![0-9])"#; static func keys(in text: String) -> [String]` (уникальные, в порядке появления).
- `TelemostViews`: рядом с «Открыть встречу» — «Списать время…» (`tasksHost.logTime(taskID: nil, title: meeting.localTitle, notes: meeting.notes, meetingID: meeting.id)` → черновик `source: .meeting` с подставленной задачей, если ключ один и найден; иначе выбор задачи поиском); «Открыть встречу» после успешного открытия вызывает `tasksHost.offerTimer(title:notes:)` и при найденной задаче показывает подтверждение «Запустить таймер по ABC-123?» (кнопки «Запустить» / «Нет»; «Нет» ничего не делает). Без `tasksHost` в окружении кнопок нет.

- [ ] **Step 1: Write the failing tests** — `testKeysAreUniqueAndOrdered` («OPS-7 и QA-12, снова OPS-7» → `["OPS-7","QA-12"]`), `testKeyInsideWordIsIgnored` («XOPS-7», «OPS-70a»), `testHostFindsTaskByKey` (сид синтетики: `logTime` с `title: "Созвон QA-1"` → черновик с `taskID` задачи `QA-1`), `testTwoKeysLeaveTaskUnset`.
- [ ] **Step 2: Run** `scripts/test.sh --filter TaskMeetingLinkTests` — Expected: FAIL.
- [ ] **Step 3: Implement; build.**
- [ ] **Step 4: Run** — Expected: PASS, 4 теста; `swift build --product Makosh` чистая.
- [ ] **Step 5: Commit** — `git commit -m "Log meeting time into tasks from Telemost"`.

---

### Task 18: Документы, полные проверки, синтетический осмотр

**Files:**
- Create: `docs/tasks.md`
- Modify: `docs/architecture.md` (ADR-018 «Задачи: локальный домен и провайдеры»), `docs/development-status.md` (раздел сверху с реальными результатами), `docs/reference-interface.md` (строка «Задачи: референс — бизнес-логика TaskOrchestrator, интерфейс свой»), `AGENTS.md` (абзац «Tasks decisions»: локальный слой не пишет в Jira; `unknown` не повторяется; `qa_tasks_`; живая Jira только по команде; worklog ≥ 60 с), `docs/service-integration.md` (раздел «Jira»)

- [ ] **Step 1: Write `docs/tasks.md`** — назначение, две витрины, правила домена, пять действий и журнал попыток, время, встречи, настройки, QA (`scripts/run-tasks-qa.py`), ограничения и вторая очередь.
- [ ] **Step 2: Run the full gates**

Run: `scripts/dev-db.sh up && scripts/test.sh > .local/tasks-full.log 2>&1; echo $?` затем `scripts/build-app.sh > .local/tasks-build.log 2>&1; echo $?` и `scripts/format.sh HEAD`
Expected: оба `0`; все бандлы XCTest `passed`; после формата — повторная сборка `0`, если формат что-то менял.

- [ ] **Step 3: Synthetic QA** — собрать отладочный бандл (как у «Файлов»: `.build/Makosh.app` с бинарём `.build/debug/Makosh`, переподпись), `python3 scripts/run-tasks-qa.py --bundle … --launch`; осмотреть обе витрины, быстрый ввод, переход с `resolution`, worklog, комментарий, передачу, `unknown` через `failNext`, таймер и черновик; скриншоты в `.local/`.
Expected: всё перечисленное видно; расхождения — в `docs/development-status.md`.

- [ ] **Step 4: Update the ledger and commit**

```bash
git add docs AGENTS.md
git commit -m "Document the Tasks section and record its checks"
```

---

## Self-review

- Покрытие спеки: цели 1–8 → Task 3–5 (домен, хранилище), 4 (ввод), 7–11 (Jira, зеркало, подключения), 15–16 (витрины, действия), 12 (время), 17 (встречи), 14 (синтетика); анти-цели закрыты тестами Task 9–10, 12; «Мои решения» спеки отражены в Task 10 (kept/none), 12 (блокировка подтверждённой записи, 60 с), 8 (простой ADF, поля перехода), 11 (токен удаляется первым), 5 (схема приложения).
- Типы согласованы: `JiraIssue`/`JiraStatus`/`JiraTransition`/`JiraField` определяются в Task 2 и 5, используются в 7–10, 13, 16; `TaskJiraAttempt.Payload.worklog(entryID:)` связывает Task 9 и 12; `TasksHost.logTime/offerTimer` — Task 15 и 17.
- Review Focus: каждая строка привязана к тесту в Task 4, 8, 10, 12.
- Пропорция: тел функций нет, только сигнатуры, имена тестов и ожидания.
