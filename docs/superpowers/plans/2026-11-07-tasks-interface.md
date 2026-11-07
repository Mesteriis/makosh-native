# Раздел «Задачи»: интерфейс по референсу — план реализации — 2026-11-07

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Перенести в раздел «Задачи» интерфейс и механику референса TaskOrchestrator целиком: компоновку, клавиатуру и выделение, строку и меню, календарь и панель деталей, диалог правки, быстрый ввод с чипами, планер дня, цепочки с графом, повторы, персоны, фокус-панель поверх таймера, строку состояния, тосты, гид и настройки.

**Architecture:** Домен и хранилище расширяются в `MakoshTasks` (новые поля задачи, таблицы цепочек/планов/слотов/фокуса, правила закрытия в транзакции хранилища, чистые типы выделения, фильтров, повторов, планера и фокуса), модель раздела `TasksWorkspaceModel` получает сочетаемые фильтры, выделение, массовые действия, планер, цепочки и очередь черновиков. Приложение (`Sources/MakoshApp/Tasks`) перестраивает экран по референсу: шапка, сворачиваемая боковая панель в колонке рабочего пространства, список с курсором и рамкой, планер, правая колонка, строка состояния, диалоги, фокус-панель на `NSPanel`, гид. Витрина «Jira» и карточка Jira не меняются.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI/AppKit, macOS 26+, PostgreSQL через `MakoshCore.PostgresConnection`, XCTest, `scripts/test.sh --filter …`, `scripts/build-app.sh`, `scripts/run-tasks-qa.py`.

**Spec:** `docs/superpowers/specs/2026-11-07-tasks-interface-design.md`

## Global Constraints

- Native SwiftUI/AppKit, macOS 26+, Swift 6, строгая изоляция; MainActor — модель, курсор, выделение, фокус-состояние; SQL — в акторе `TaskStore`; фокус-панель — `NSPanel`.
- Внутри `MakoshTasks` и `Sources/MakoshApp/Tasks` Swift-овский `Task` пишется `_Concurrency.Task`; `MakoshApp.swift` и `WorkspaceView.swift` не импортируют `MakoshTasks`.
- Локальный слой не пишет в Jira; записи времени появляются только из черновика; фокус-сессии и слоты не пишут `tasks_time_entries`.
- Правила закрытия (активация, повтор, снятие экземпляра) живут в транзакции `TaskStore` и действуют для любого актора и пути.
- Undo: шаг недоступен при изменившейся ревизии; история сбрасывается при внешних изменениях; массовое действие и перенос слота — один шаг.
- Клавиши референса с `Ctrl` → `⌘`; `S`/`P` также `ы`/`з`; горячие клавиши действуют только при фокусе в списке раздела.
- Размеры: левая колонка раздела 280–390 pt (сворачивается в 0), правая 256 pt (360 pt при задаче Jira), планер 40 % (20–60 %), час планера 60 pt, шаг 30 мин, день 9–17.
- Таблицы — схема приложения, префикс `tasks_`; старые JSONB-записи читаются терпимо (`notes` строка → одна заметка; отсутствующие поля → умолчания); тесты — `MAKOSH_TEST_DATABASE_URL`, схемы `makosh_test_`; QA — `qa_tasks_<suffix>`.
- Тексты по-русски. Коммиты заканчиваются `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`; форматировать только изменённые файлы (`scripts/format.sh HEAD`).
- Сборка и тесты не читают `.references/`; живая Jira — только по команде пользователя; план не содержит живых шагов.
- `swift test` собирает и исполняемую цель `MakoshApp`, поэтому после каждой задачи приложение собирается: доменная задача, меняющая API модели, в том же коммите минимально правит места вызова в `Sources/MakoshApp/Tasks` (без новой разметки — её дают задачи 11–16).

## Review Focus

1. Space на смешанном выделении (две свободные, одна заблокированная): свободные закрываются, заблокированная остаётся, тост «Пропущено заблокированных: 1», один шаг undo возвращает обе — Task 3 `testBulkDoneSkipsBlockedAndUndoesAsOneStep`.
2. Повторяющаяся задача закрыта, открыта заново и закрыта снова (Space дважды через undo): ровно один живой экземпляр, воскрешённый, а не второй — Task 2 `testReopenAndCloseAgainResurrectsTheSpawn`.
3. Бросок двух задач по часу в планер за 30 минут до конца дня: первая сдвигается назад на 16:00–17:00, вторая не ставится, ни один слот не выходит за конец дня, тост «Не поместилось: 1» — Task 7 `testDropNearDayEndPlacesWhatFitsAndStops`.
4. Зеркало Jira закрывает задачу активной фокус-сессии, пока на экране уже открыт черновик другой записи: второй черновик встаёт в очередь и показывается после первого, время не теряется — Task 8 `testMirrorClosingFocusedTaskQueuesDraft`.
5. Поиск «ghbdtn» (английская раскладка) находит «Привет», а `to:7K3MZ` — задачу по коду — Task 4 `testSearchSwapsKeyboardLayoutAndAcceptsRefs`.

## File Structure

- `Sources/MakoshTasks/`
  - `TaskModels.swift` — `Task` (+ `personas`, `recurrence`, `flowID`, `notes: [TaskNote]`), `TaskNote`, терпимый `init(from:)`.
  - `TaskStoreSchema.swift`, `TaskStore.swift` — новые таблицы; `apply(_:expectedRevision:actor:) -> TaskWriteResult`; `changedFields` расширен.
  - `TaskPreferences.swift` (новый) — предпочтения v2 (вынести из `TaskStore.swift`).
  - `TaskRecurrence.swift` (новый) — нормализация, текст, следующий срок, `spawnID`.
  - `TaskClosing.swift` (новый) — правила закрытия внутри транзакции (`TaskCloseEffects`).
  - `TaskUndo.swift` — шаг над набором изменений и слотами.
  - `TaskSelection.swift` (новый) — чистое состояние курсора/выделения.
  - `TasksFilters.swift` (новый) — `TasksFilters`, `TasksAgenda`, `TasksSortState`, раскладка EN↔RU, `TaskReference` (`to:КОД`).
  - `TaskQuickEntry.swift` — новые токены; `TaskQuickEntryChips.swift` (новый) — чипы и подсказки.
  - `TaskFlow.swift` (новый) — `TaskFlow`, прогресс, готовность, `TaskFlowLayout`.
  - `TaskPlanner.swift` (новый) — `TaskDayPlan`, `TaskPlanSlot`, `TaskPlannerRules`, store-расширение.
  - `TaskFocus.swift` (новый) — `TaskFocusState` и переходы; `TaskFocusService.swift` (новый) — связь с таймером, очередь черновиков.
  - `TaskTimeService.swift` — `stopKeepingTime()`, `draft(session:)`.
  - `Presentation/TasksWorkspaceModel.swift` — фильтры, выделение, массовые действия, тосты, планер, цепочки, фокус; `Presentation/TasksWorkspaceModel+Bulk.swift`, `+Planner.swift`, `+Focus.swift` (новые расширения).
  - `TasksQAIsolation.swift`, `JiraSyntheticAdapter.swift` — расширенный сид.
- `Sources/MakoshApp/Workspace/WorkspaceSplitView.swift` — `collapsed`.
- `Sources/MakoshApp/Tasks/` — `TasksViews.swift` (шапка, колонки, строка состояния, тосты), `TaskListView.swift` (строки, клавиши, рамка, меню, панель массовых действий), `TasksSidebar.swift`, `TaskFilterBar.swift` (новый: сортировка и чипы фильтров), `TaskCalendarPanel.swift` (новый), `TaskDetailView.swift` (панель деталей по клику), `TaskEditDialog.swift` (новый), `TaskQuickEntryField.swift` (новый, чипы и подсказки; вынести из `TasksViews.swift`), `TaskPlannerView.swift` (новый), `TaskFlowView.swift` (новый), `TaskFocusPanel.swift` (новый, `NSPanel` + SwiftUI), `TasksGuideOverlay.swift` (новый), `TasksSettingsView.swift`, `TasksHost.swift`, `TasksSyntheticPreview.swift`.
- `scripts/run-tasks-qa.py`; `docs/tasks.md`, `docs/reference-interface.md`, `docs/development-status.md`, `docs/architecture.md`.

---

### Task 1: Поля задачи, заметки, предпочтения и новые таблицы

**Files:**
- Modify: `Sources/MakoshTasks/TaskModels.swift`, `Sources/MakoshTasks/TaskStoreSchema.swift`, `Sources/MakoshTasks/TaskStore.swift`, `Sources/MakoshTasks/TasksQAIsolation.swift` (сид: `notes:` списком)
- Create: `Sources/MakoshTasks/TaskPreferences.swift`
- Modify (минимально, чтобы собиралось): `Sources/MakoshApp/Tasks/TaskDetailView.swift` — заметки через `task.notesText` на чтение и одну заметку на запись; `Sources/MakoshTasks/Presentation/TasksWorkspaceModel.swift` — старые `sort`/`filter`/`showCompleted` читают и пишут поля v2 (`sortState`, `filters.agenda`/`status`…, `!filters.actualOnly`) до Task 4
- Test: `Tests/MakoshTasksTests/TaskModelsTests.swift`, `Tests/MakoshTasksTests/TaskStoreTests.swift`

**Interfaces:**
- Produces: `public struct TaskNote: Codable, Equatable, Identifiable, Sendable { id: UUID; content: String; createdAt: Date }`; `Task.personas: [String]`, `Task.recurrence: String?`, `Task.flowID: String?`, `Task.notes: [TaskNote]` (инициализатор получает `personas: [String] = []`, `recurrence: String? = nil`, `flowID: String? = nil`, `notes: [TaskNote] = []`); `Task.notesText: String` (абзацы заметок через пустую строку, только чтение).
- Produces: `public struct TaskPreferences` v2: `filters: TasksFiltersSnapshot` (строковые поля `status`, `agenda`, `list`, `tag`, `persona`, `flow`, `day` (yyyy-MM-dd) — все `String?`; `actualOnly`, `groupByFlow: Bool`), `sort: TasksSort?`, `sortDescending: Bool`, `showCompleted: Bool` (остаётся для совместимости чтения), `condense`, `showSidebar`, `showRightPanel`, `showCalendar`, `showPlanner: Bool`, `plannerWidthPercent: Int` (40), `collapsedSections: [String]`, `guideCompleted: Bool`, `dateFormat: TaskDateFormat` (`.iso`, `.dmy` по умолчанию, `.short`, `.long`), `firstWeekday: Int` (2 = понедельник), `showBulkBar: Bool` (true), `extractURLs: Bool` (true), `newTaskActiveToday: Bool` (false), `plannerDayStart: Int` (9), `plannerDayEnd: Int` (17), `plannerStep: Int` (30), `focus: TaskFocusConfig`. `TaskFocusConfig { enabled: Bool; compact: Bool; modules: Set<TaskFocusModule>; presets: [Int]; breakMinutes: Int }`, `TaskFocusModule: String, CaseIterable` (`timer, presets, controls, waiting, counter, nextSlot, clock`). Старый JSON `{sort: "priority", filter: "overdue", showCompleted: false}` декодируется: `sort = .priority`, `sortDescending = false`, `filters.agenda = "overdue"`, `filters.actualOnly = !showCompleted`.
- Produces: таблицы `tasks_flows(name TEXT PRIMARY KEY, data JSONB NOT NULL)`, `tasks_day_plans(id UUID PRIMARY KEY, date DATE NOT NULL UNIQUE, data JSONB NOT NULL)`, `tasks_day_plan_slots(id UUID PRIMARY KEY, plan_id UUID NOT NULL, task_id UUID, start_time TEXT NOT NULL, end_time TEXT NOT NULL, data JSONB NOT NULL)` + индекс `tasks_day_plan_slots_plan(plan_id, start_time)`, `tasks_focus(id SMALLINT PRIMARY KEY CHECK(id = 1), data JSONB NOT NULL)`.
- Produces: `TaskStore.changedFields` учитывает `personas`, `recurrence`, `flowID`, `notes`.

- [ ] **Step 1: Write the failing tests**

```swift
// TaskModelsTests
func testLegacyNotesStringDecodesAsOneNote() throws {
    let json = #"{"id":"7A5B0ABD-0000-4000-8000-000000000001","code":"ABCDE","title":"x","status":"inbox","priority":4,"tags":[],"postponed":0,"dependsOn":[],"notes":"старая заметка","createdAt":"2026-11-07T10:00:00.000Z","updatedAt":"2026-11-07T10:00:00.000Z","revision":1}"#
    let task = try TaskStore.testDecoder.decode(Task.self, from: Data(json.utf8))
    XCTAssertEqual(task.notes.map(\.content), ["старая заметка"])
    XCTAssertEqual(task.personas, []); XCTAssertNil(task.recurrence); XCTAssertNil(task.flowID)
}
func testEmptyLegacyNotesDecodeAsNoNotes()  // "notes":"" → []
func testLegacyPreferencesDecode() throws {
    let json = #"{"sort":"due","filter":"status:done","showCompleted":false}"#
    let value = try JSONDecoder().decode(TaskPreferences.self, from: Data(json.utf8))
    XCTAssertEqual(value.sort, .due); XCTAssertFalse(value.sortDescending)
    XCTAssertEqual(value.filters.status, "done"); XCTAssertTrue(value.filters.actualOnly)
    XCTAssertEqual(value.plannerDayStart, 9); XCTAssertEqual(value.focus.presets, [15, 30, 45, 60])
}
// TaskStoreTests
func testNewFieldsRoundTripAndAppearInChangedFields() async throws {
    // insert with personas ["Боб"], recurrence "weekly", flowID "Релиз", two notes; update each → versions.last.changedFields contains the field
}
func testNewTablesExistAfterOpen() async throws {
    // query "SELECT to_regclass('\"<schema>\".tasks_flows')" and the other three → not empty
}
```

`TaskStore.testDecoder` — `static` JSONDecoder с той же стратегией дат, доступный тестам (`@testable`).

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh --filter 'TaskModelsTests|TaskStoreTests'`
Expected: FAIL — `TaskNote` не определён, `personas` отсутствует, `TaskPreferences.filters` отсутствует.

- [ ] **Step 3: Implement**

`TaskNote`; расширить `Task` с ручным `init(from:)` (`decodeIfPresent` для новых полей; `notes` — попытка `[TaskNote]`, затем `String`); `replacing(code:createdAt:)` копирует новые поля; `TaskPreferences.swift` с ручным `init(from:)` для старого формата; схема и `changedFields`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh --filter 'TaskModelsTests|TaskStoreTests|TaskTimeServiceTests|TasksWorkspaceModelTests'`
Expected: PASS; существующие тесты остаются зелёными, приложение собирается.

- [ ] **Step 5: Commit**

```bash
git add Sources/MakoshTasks Tests/MakoshTasksTests
git commit -m "Extend tasks with personas, recurrence, flows, notes and the planner tables"
```

---

### Task 2: Повторы и правила закрытия в транзакции

**Files:**
- Create: `Sources/MakoshTasks/TaskRecurrence.swift`, `Sources/MakoshTasks/TaskClosing.swift`
- Modify: `Sources/MakoshTasks/TaskStore.swift`, `Sources/MakoshTasks/TaskDomain.swift`, `Sources/MakoshTasks/Presentation/TasksWorkspaceModel.swift`, `Sources/MakoshTasks/JiraMirror.swift`
- Test: `Tests/MakoshTasksTests/TaskRecurrenceTests.swift` (новый), `Tests/MakoshTasksTests/TaskClosingTests.swift` (новый), `Tests/MakoshTasksTests/JiraMirrorTests.swift`

**Interfaces:**
- Produces: `public enum TaskRecurrence { static func normalize(_ raw: String) -> String? /* daily|weekly|biweekly|monthly|yearly|FREQ=… */; static func humanText(_ value: String) -> String?; static func nextDue(_ value: String, today: Date, calendar: Calendar) -> Date?; static func spawnID(for parent: UUID) -> UUID /* UUID v5, namespace 5D3F1B2C-8E6A-4C1F-9A7B-2E4D6F8A0C1E, name = parent.uuidString */ }`.
- Produces: `public struct TaskCloseEffects: Equatable, Sendable { activated: [UUID]; spawned: Task?; resurrected: Bool; removedSpawn: UUID? }`; `public struct TaskWriteResult: Sendable { task: Task; effects: TaskCloseEffects }`; `TaskStore.apply(_ task: Task, expectedRevision: Int64, actor: TaskActor) throws -> TaskWriteResult` — `update` вызывает `apply` и возвращает `task`. Внутри транзакции после записи: переход `!done → done` активирует зависимые `inbox` без открытых блокеров (актор записи, changed `["status","activated-after:<code>"]`) и порождает/воскрешает экземпляр (`insert`/`update`, changed `["spawn-of:<code>"]`, `source: nil`, новый `code`); переход `done → не done` мягко удаляет нетронутый экземпляр (`active`, `deletedAt == nil`, `updatedAt == createdAt`).
- Consumes: Task 1 поля.
- Изменяет: `TasksWorkspaceModel.set(status:id:)` больше не вызывает `activateDependents` (метод удаляется); `JiraMirror.apply` использует `store.apply` — эффекты не нужны, но путь общий.

- [ ] **Step 1: Write the failing tests**

```swift
// TaskRecurrenceTests
func testNormalizeAcceptsSimpleAndRRule()      // "Weekly " → "weekly"; "FREQ=MONTHLY;INTERVAL=2" → as is; "каждый" → nil
func testHumanTextRussian()                    // "daily" → "Каждый день"; "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE" → "Каждые 2 недели: Пн, Ср"; "FREQ=MONTHLY;BYDAY=1MO" → "Первый Пн каждого месяца"; "FREQ=YEARLY;BYMONTH=1" → "Каждый год (янв)"
func testNextDueCountsFromTodayNotFromDue()    // today 2026-11-07, "weekly" → 2026-11-14 regardless of due 2026-10-01
func testSpawnIDIsDeterministic()              // spawnID(for: a) == spawnID(for: a); != spawnID(for: b)
// TaskClosingTests (PostgreSQL)
func testClosingSpawnsNextOccurrenceOnce() async throws {
    // recurrence "daily", due today → apply(status: .done) → effects.spawned?.due == tomorrow, status .active, dependsOn [], postponed 0, source nil
    // apply again with status .done on the (already done) task → no second spawn, versions unchanged count
}
func testReopenAndCloseAgainResurrectsTheSpawn() async throws {
    // done → effects.spawned S; apply(status: .inbox) → effects.removedSpawn == S.id, S.deletedAt != nil
    // apply(status: .done) → effects.resurrected == true, spawned.id == S.id, tasks(includeDeleted: false) has exactly one spawn
}
func testEditedSpawnSurvivesReopen() async throws  // edit spawn's title → reopen parent → removedSpawn == nil
func testClosingByProviderActivatesDependents() async throws {
    // blocker + dependent inbox; store.apply(blocker done, actor: .provider) → dependent .active, its last version actor == .provider and changedFields contains "activated-after:<blockerCode>"
}
func testUndoPathGoesThroughTheSameRules() async throws  // model.set(.done) then model.undo() → spawn removed (uses model + store)
// JiraMirrorTests
func testDoneCategoryActivatesLocalDependents() async throws  // mirror sets done on a Jira task that blocks a local inbox task → local task active
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh --filter 'TaskRecurrenceTests|TaskClosingTests|JiraMirrorTests'`
Expected: FAIL — `TaskRecurrence`/`apply` не определены; активация у зеркала отсутствует.

- [ ] **Step 3: Implement**

`TaskRecurrence` (парсер RRULE по `;`/`=`, плюрализация как в `TaskStyle`), `TaskClosing.effects(before:after:store:actor:)` вызываемая из `apply` внутри `transaction`, `TaskDomain.dependentsToActivate` переиспользуется. UUID v5: SHA-1 от namespace + name, версия/вариант по RFC 4122 (`CryptoKit.Insecure.SHA1`). Удалить `activateDependents` из модели; `undo()` использует `apply`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh --filter 'MakoshTasksTests'`
Expected: PASS, включая `testCycleStatusRespectsBlocking` (активация теперь в хранилище).

- [ ] **Step 5: Commit**

```bash
git add Sources/MakoshTasks Tests/MakoshTasksTests
git commit -m "Add recurrence and run the closing rules inside the store transaction"
```

---

### Task 3: Выделение, массовые действия и undo набором

**Files:**
- Create: `Sources/MakoshTasks/TaskSelection.swift`, `Sources/MakoshTasks/Presentation/TasksWorkspaceModel+Bulk.swift`
- Modify: `Sources/MakoshTasks/TaskUndo.swift`, `Sources/MakoshTasks/TaskDomain.swift`, `Sources/MakoshTasks/Presentation/TasksWorkspaceModel.swift`
- Test: `Tests/MakoshTasksTests/TaskSelectionTests.swift` (новый), `Tests/MakoshTasksTests/TaskUndoTests.swift`, `Tests/MakoshTasksTests/TasksWorkspaceModelTests.swift`

**Interfaces:**
- Produces: `public struct TaskSelection: Equatable, Sendable { cursor: Int?; selected: Set<UUID>; anchor: Int?; mutating func click(index: Int, id: UUID, shift: Bool, command: Bool, visible: [UUID]); mutating func move(by delta: Int, extend: Bool, visible: [UUID]); mutating func jump(toStart: Bool, extend: Bool, visible: [UUID]); mutating func selectAll(visible: [UUID]); mutating func clear(); mutating func clamp(to visible: [UUID]); func targets(visible: [UUID]) -> [UUID] /* selected in visible order, else cursor task */ }`.
- Produces: `TaskUndoStep` становится `public struct TaskUndoStep { changes: [TaskChange]; slots: [TaskSlotChange]; at: Date }`, `public struct TaskChange { before: Task; after: Task }`, `public struct TaskSlotChange { before: TaskPlanSlot?; after: TaskPlanSlot? }`. `TaskPlanSlot` создаётся здесь, в новом `Sources/MakoshTasks/TaskPlanner.swift`, и Task 7 его дополняет: `public struct TaskPlanSlot: Codable, Equatable, Identifiable, Sendable { id: UUID; planID: UUID; taskID: UUID?; title: String?; start: Int /* минуты от полуночи */; end: Int; kind: Kind; recurrence: Recurrence? }`, `enum Kind: String, Codable { task, blocked }`, `enum Recurrence: String, Codable { daily, weekly, biweekly }`.
- Produces: `TasksWorkspaceModel.selected: UUID?` остаётся вычисляемым мостом над `selection` (единственная выделенная или `nil`; установка — одиночное выделение), пока представления Task 12 не перейдут на `selection`. После `refresh()`, когда `outsideChanges` сдвинулся, модель даёт тост «Обновлено извне».
- Produces (модель): `@Published public var selection = TaskSelection()`; `public var targets: [UUID]`; `@Published public private(set) var toasts: [TasksToast]`, `@Published public private(set) var lastAction: String?`, `public struct TasksToast: Identifiable { id: UUID; text: String; at: Date }`, `public func toast(_ text: String)` (держит до 5, снимает через `toastLifetime` = 3 с средствами вызывающего — модель только хранит; `dismissToast(id:)`); `public struct TaskBulkResult { changed: Int; activated: [String]; skippedBlocked: Int; spawned: Int }`; `bulk(status: TaskStatus, ids: [UUID]) async -> TaskBulkResult` (заблокированные при `active`/`done` пропускаются); `bulkToggleDone(ids:) async` (все `done` → `active`, иначе → `done`; все заблокированы → тост «Заблокировано: сначала закройте зависимости»); `bulkCycle(ids:)`, `bulkPriority(_:ids:)`, `bulkDelete(ids:)`, `bulkPostpone(ids:)` (только со сроком; иначе тост «Нет срока для переноса»), `bulkSnooze(ids:days:months:)`, `bulkSnooze(ids:until:)`, `bulkToday(ids:)`, `duplicate(id:) async`, `rename(id:title:) async`, `referencesText(ids:) -> String` («to:КОД Название» по строкам в видимом порядке), `TaskDomain.snoozed(_:days:months:today:calendar:)`, `TaskDomain.nextWeekday(_ weekday: Int, after today: Date, calendar:) -> Date` (следующая неделя, никогда сегодня). Каждое массовое действие — одна транзакция `performInTransaction` и один `TaskUndoStep`; тосты по спеке.
- `undo()` откатывает все изменения шага (каждое — проверка ревизии `after`; при первой несовпавшей — ошибка «Задача менялась — отменить нельзя.», ничего не пишется).

- [ ] **Step 1: Write the failing tests**

```swift
// TaskSelectionTests
func testClickShiftAndCommandBuildSelection()   // click 1; shift-click 3 → {1,2,3}; cmd-click 2 → {1,3}; cursor 2
func testArrowsMoveAndShiftExtendsFromAnchor()  // move +1 twice, then extend −1 → range anchor..cursor
func testClampDropsHiddenAndKeepsCursorInRange()
func testTargetsPreferSelectionOverCursor()
// TaskUndoTests
func testStepWithSeveralChangesPopsAsOne()
// TasksWorkspaceModelTests
func testBulkDoneSkipsBlockedAndUndoesAsOneStep() async throws {
    // A, B free; C blocked by D. bulkToggleDone([A,B,C]) → A,B done, C inbox, result.skippedBlocked == 1, lastAction == "Выполнено: 2 задачи"
    // undoCount == 1; undo() → A,B back to previous status
}
func testSnoozeUntilMondayNeverPicksToday() async throws   // clock on a Monday → due == +7 days, postponed +1
func testDuplicateCopiesFieldsButNotNotesOrSource() async throws
func testReferencesTextUsesVisibleOrder() async throws     // "to:AAAAA Первая\nto:BBBBB Вторая"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh --filter 'TaskSelectionTests|TaskUndoTests|TasksWorkspaceModelTests'`
Expected: FAIL — типы и методы не определены.

- [ ] **Step 3: Implement**

`TaskSelection` как чистая структура; `TaskUndoStep` новый вид (существующие `write`/`edit` модели оборачивают одно изменение); массовые действия в расширении модели через `service.store.performInTransaction` с `apply` на каждой задаче, сбор эффектов в `TaskBulkResult`; тосты.

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh --filter 'MakoshTasksTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MakoshTasks Tests/MakoshTasksTests
git commit -m "Add multi-selection, bulk actions and set-wide undo to the tasks model"
```

---

### Task 4: Сочетаемые фильтры, сортировка, поиск, всплытие просроченных

**Files:**
- Create: `Sources/MakoshTasks/TasksFilters.swift`
- Modify: `Sources/MakoshTasks/Presentation/TasksWorkspaceModel.swift`, `Sources/MakoshTasks/TaskStore.swift` (чтение/запись `TaskPreferences` v2)
- Modify (минимально, чтобы собиралось): `Sources/MakoshApp/Tasks/TasksSidebar.swift` — строки ставят поля `filters` через `toggle`, счётчики из `agendaCounts`/`statusCounts`/`listCounts`/`tagCounts`; `Sources/MakoshApp/Tasks/TasksViews.swift` — вместо `Picker` сортировки и `Toggle` «Сделанные» временный `Picker` над `sortState?.field` и `Toggle` над `filters.actualOnly`
- Test: `Tests/MakoshTasksTests/TasksFiltersTests.swift` (новый), `Tests/MakoshTasksTests/TasksWorkspaceModelTests.swift`

**Interfaces:**
- Produces: `public enum TasksAgenda: String, CaseIterable, Sendable { today, tomorrow, week, month, overdue }`; `public struct TasksFilters: Equatable, Sendable { status: TaskStatus?; agenda: TasksAgenda?; list: String?; tag: String?; persona: String?; flow: String?; day: Date?; actualOnly: Bool; groupByFlow: Bool; var isFiltering: Bool /* без actualOnly/groupByFlow, actualOnly считается */; mutating func toggle(status:)… (клик по активному снимает); mutating func clearFilters() /* оставляет groupByFlow */; var chips: [TasksFilterChip] }`, `public struct TasksFilterChip: Identifiable { id: String; title: String; kind }`; `public struct TasksSortState: Equatable, Sendable { field: TasksSort; descending: Bool; static func toggled(_ current: TasksSortState?, field:) -> TasksSortState? /* nil→asc→desc→nil */ }`; `public enum KeyboardLayout { static func swapped(_ text: String) -> String }`; `public enum TaskReference { static func normalize(_ input: String) -> String? /* strips to:, uppercases, O→0, I/L→1, Crockford only, 4…5 chars */; static func text(code:title:) -> String }`.
- Produces (модель): `@Published public var filters = TasksFilters()` (didSet → applyFilters, save), `@Published public var sortState: TasksSortState?`, `@Published public var condense`, `showSidebar`, `showRightPanel`, `showCalendar`, `showPlanner`, `plannerWidthPercent`, `collapsedSections: Set<String>` — все сохраняются в `TaskPreferences`; `public private(set) var overdueCount: Int` (сколько первых строк `visible` просрочены); `public var agendaCounts: [TasksAgenda: Int]`, `statusCounts: [TaskStatus: Int]`, `listCounts`, `tagCounts`, `personaCounts`, `flowCounts: [String: Int]` (по `mineTasks`, повестка включает просроченные, как в референсе); `public var totalCount`, `doneCount`, `foundCount` (= `visible.count` когда `filters.isFiltering || !search.isEmpty`); `func clearAll()` (фильтры, день, поиск); `func escape()` → каскад: выделение → поиск → фильтры (возвращает что сделал: `enum EscapeResult { selection, search, filters, nothing }`); `public private(set) var flowGroups: [TasksFlowGroup]` — порядок `visible` с группами (`struct TasksFlowGroup { flow: String?; tasks: [Task] }`) для списка. Старые `filter`, `sort`, `showCompleted` удаляются; `TasksFilter` enum заменяется (боковая панель переписывается в Task 12).
- Сортировка: без `sortState` — по названию; с ним — поле и направление, вторично название. Поиск: по названию, тегам, списку, коду, ключу Jira; с `KeyboardLayout.swapped`; первое слово как `TaskReference`.

- [ ] **Step 1: Write the failing tests**

```swift
// TasksFiltersTests
func testToggleSameValueClears()
func testSortToggleCycles()           // nil → (priority, asc) → (priority, desc) → nil; other field restarts asc
func testKeyboardLayoutSwap()         // "ghbdtn" → "привет"; "привет" → "ghbdtn"
func testTaskReferenceNormalize()     // "to:7k3mz" → "7K3MZ"; "to:7K3ML" → "7K3M1"; "hello!" → nil
// TasksWorkspaceModelTests
func testFiltersCombineAndCountsIncludeOverdue() async throws
    // overdue task + today task; filters.agenda = .today → both visible; agendaCounts[.today] == 2; add filters.tag → narrows
func testOverdueFloatToTopUnderDivider() async throws   // sortState priority asc, overdue P4 task appears first; overdueCount == 1
func testSearchSwapsKeyboardLayoutAndAcceptsRefs() async throws
    // "Привет" found by "ghbdtn"; "to:<code>" finds by code
func testEscapeCascade() async throws        // selection → search → filters → nothing
func testPreferencesV2RoundTrip() async throws
    // set filters/sort/condense/showPlanner/plannerWidthPercent/collapsedSections → new model reads them back
func testGroupByFlowClustersAtFirstOccurrence() async throws
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh --filter 'TasksFiltersTests|TasksWorkspaceModelTests'`
Expected: FAIL — типы не определены.

- [ ] **Step 3: Implement**

`TasksFilters.swift`; `applyFilters` в модели переписывается по `useFilteredTasks.ts` (фильтр → сортировка → всплытие просроченных → группировка); предпочтения через `TaskPreferences` v2 (debounce не нужен — запись в `_Concurrency.Task` как сейчас). Обновить существующие тесты (`testPreferencesPersistAcrossModels` → v2, `testMineHidesNoneMembershipAndDeleted` без `filter`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh --filter 'MakoshTasksTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MakoshTasks Tests/MakoshTasksTests
git commit -m "Make task filters combinable with tri-state sort, layout-aware search and overdue floating"
```

---

### Task 5: Быстрый ввод: новые токены, чипы, подсказки, подстановка

**Files:**
- Modify: `Sources/MakoshTasks/TaskQuickEntry.swift`, `Sources/MakoshTasks/Presentation/TasksWorkspaceModel.swift`
- Create: `Sources/MakoshTasks/TaskQuickEntryChips.swift`
- Test: `Tests/MakoshTasksTests/TaskQuickEntryTests.swift`, `Tests/MakoshTasksTests/TaskQuickEntryChipsTests.swift` (новый), `Tests/MakoshTasksTests/TasksWorkspaceModelTests.swift`

**Interfaces:**
- Produces: `TaskQuickEntry.Kind` + `persona`, `recurrence`, `flow`; поля `personas: [String]`, `recurrence: String?` (нормализованный; нераспознанный остаётся в названии с `resolved: false`), `flowID: String?`; токены `/имя`, `*повтор`, `>>цепочка`; `parse(_:today:calendar:resolveDependency:extractURLs: Bool = true)`.
- Produces: `public struct TaskQuickEntryChips: Equatable, Sendable { chips: [Chip]; text: String; struct Chip { kind: TaskQuickEntry.Kind; raw: String }; mutating func typed(_ newText: String, extractURLs: Bool) /* пробел в конце → попытка зафиксировать последнее слово; список только один */; mutating func backspaceOnEmpty() -> Bool; mutating func remove(at:); mutating func accept(_ suggestion: TaskQuickEntrySuggestion); func composed() -> String /* чипы + текст одной строкой для parse */; var isEmpty }`; `public struct TaskQuickEntrySuggestion: Equatable, Identifiable { kind; label; replace; detail: String? }`; `public enum TaskQuickEntrySuggestions { static func make(for text: String, lists: [String], tags: [String], personas: [String], flows: [String], hasList: Bool, today: Date, calendar: Calendar) -> [TaskQuickEntrySuggestion] }` (по `getSuggestions` референса: `^` даёт распознанную дату первой с подписью «→ 20 апреля, пн» и подсказки `^сегодня ^завтра ^пн…^вс`; `!` — четыре с названиями; `*` — четыре повтора).
- Produces (модель): `@Published public var quickEntry = TaskQuickEntryChips()`; `public var quickEntrySuggestions: [TaskQuickEntrySuggestion]`; `func create(fromQuickEntry: Void) async` использует `quickEntry.composed()` + подстановку из `filters` (срок по повестке, статус `active` при `filters.status == .active` или `newTaskActiveToday` и срок сегодня, список/тег/персона/цепочка) + `pendingSlotStart: Int?` (минуты; Task 7 ставит слот); тост «Создана: … · дата · P1 · #список»; `previewQuickEntry` работает от `composed()`.

- [ ] **Step 1: Write the failing tests**

```swift
// TaskQuickEntryTests
func testPersonaRecurrenceAndFlowTokens()      // "Позвонить /Боб *weekly >>Релиз" → personas ["Боб"], recurrence "weekly", flowID "Релиз", title "Позвонить"
func testUnknownRecurrenceStaysInTitle()       // "*каждый" unresolved
// TaskQuickEntryChipsTests
func testSpaceCommitsTokenIntoChip()           // typed("Счёт @Работа ") → chips [list @Работа], text "Счёт "
func testSecondListStaysText()
func testBackspaceOnEmptyPopsChipBackToText()
func testSuggestionsForEachPrefix()            // "@Ра" → @Работа; "!" → 4; "^за" → ^завтра with detail; "*" → 4; "/б" → /Боб; ">>Р" → >>Релиз
func testAcceptSuggestionCommitsChip()
// TasksWorkspaceModelTests
func testQuickEntryPrefillsFromFilters() async throws   // filters.agenda = .tomorrow, filters.list = "Работа", filters.persona = "Боб" → created due tomorrow, list, personas
func testQuickEntryToastNamesTheTask() async throws     // lastAction hasPrefix "Создана: Счёт"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh --filter 'TaskQuickEntryTests|TaskQuickEntryChipsTests|TasksWorkspaceModelTests'`
Expected: FAIL.

- [ ] **Step 3: Implement**

Токены и чипы по `quickEntry.ts`/`QuickEntry.tsx`; `create(quickEntry:)` сохраняется для тестов и Telemost, новая `create()` поверх чипов.

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh --filter 'MakoshTasksTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MakoshTasks Tests/MakoshTasksTests
git commit -m "Add chips, suggestions and filter prefill to task quick entry"
```

---

### Task 6: Цепочки и персоны в домене и модели

**Files:**
- Create: `Sources/MakoshTasks/TaskFlow.swift`
- Modify: `Sources/MakoshTasks/TaskStore.swift` (расширение в `TaskFlow.swift`), `Sources/MakoshTasks/Presentation/TasksWorkspaceModel.swift`
- Test: `Tests/MakoshTasksTests/TaskFlowTests.swift` (новый), `Tests/MakoshTasksTests/TasksWorkspaceModelTests.swift`

**Interfaces:**
- Produces: `public struct TaskFlow: Codable, Equatable, Identifiable, Sendable { name: String (id); description: String; color: String? /* #hex из палитры */; deadline: Date? }`, `TaskFlow.palette: [String]` (десять цветов референса); `TaskStore.flows() -> [TaskFlow]`, `saveFlow(_:)`, `removeFlow(name:)` (удаляет карточку и снимает `flowID` с задач одной транзакцией через `apply`, actor `.user`).
- Produces: `public struct TaskFlowProgress { total: Int; done: Int; percent: Int }`; `public enum TaskFlowRules { static func progress(_ tasks: [Task]) -> TaskFlowProgress; static func isReady(_ task: Task, resolve:) -> Bool /* inbox без открытых блокеров */; static func nextReady(_ tasks: [Task], resolve:) -> Task? }`; `public struct TaskFlowLayout { struct Node { id: UUID; x: CGFloat; y: CGFloat }; struct Edge { from: UUID; to: UUID }; nodes; edges; size: CGSize; static func make(_ tasks: [Task], nodeSize: CGSize = CGSize(width: 200, height: 76), gap: CGSize = CGSize(width: 80, height: 20)) -> TaskFlowLayout /* ранг = длиннейший путь от истоков по dependsOn внутри цепочки; порядок в ранге — среднее положение предков, затем название */ }`.
- Produces (модель): `public var personas: [String]`, `flows: [String]` (из задач и карточек), `flowMeta: [String: TaskFlow]`, `func flowProgress(_ name: String) -> TaskFlowProgress`, `func saveFlow(_:) async`, `func deleteFlow(name:) async` (снимает фильтр), `func startNext(inFlow:) async` (первая готовая → `active`, тост «Задача запущена»), `func setFlow(id:name:) async`, `func setPersonas(id:_:) async`, `activeFlow: String?` (= `filters.flow`), `flowTasks: [Task]`.

- [ ] **Step 1: Write the failing tests**

```swift
// TaskFlowTests
func testProgressCountsDone()
func testReadyIsInboxWithoutOpenBlockers()
func testLayoutRanksByLongestPathAndHasNoOverlaps()   // chain A→B→C, D→C: ranks 0,1,2 / D rank 0; no two nodes share x and overlapping y
func testFlowsRoundTripInStore() async throws
func testRemoveFlowClearsTasksButKeepsThem() async throws
// TasksWorkspaceModelTests
func testStartNextActivatesFirstReady() async throws
func testPersonaCountsAndFilter() async throws
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh --filter 'TaskFlowTests|TasksWorkspaceModelTests'`
Expected: FAIL.

- [ ] **Step 3: Implement**

Раскладка: топологические ранги (Kahn), барицентр, координаты `x = rank * (w + gap.w)`, `y` по порядку в ранге; `size` — максимум.

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh --filter 'MakoshTasksTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MakoshTasks Tests/MakoshTasksTests
git commit -m "Add task flows with progress, readiness and a layered graph layout"
```

---

### Task 7: Планер дня

**Files:**
- Modify: `Sources/MakoshTasks/TaskPlanner.swift` (из Task 3: добавить план, правила, хранилище)
- Create: `Sources/MakoshTasks/Presentation/TasksWorkspaceModel+Planner.swift`
- Test: `Tests/MakoshTasksTests/TaskPlannerTests.swift` (новый), `Tests/MakoshTasksTests/TasksWorkspaceModelTests.swift`

**Interfaces:**
- Produces: `public struct TaskDayPlan: Codable, Equatable, Identifiable, Sendable { id: UUID; day: Date (начало дня); dayStart: Int /* часы */; dayEnd: Int }`; `TaskPlanSlot` (Task 3) + `var minutes: Int`, `static func time(_ minutes: Int) -> String /* "09:30" */`, `static func minutes(_ text: String) -> Int?`.
- Produces: `public enum TaskPlannerRules { static func snap(_ minutes: Int, step: Int) -> Int; static func estimateMinutes(_ task: Task) -> Int /* nil → 60; минимум 15 */; static func freeStart(_ start: Int, duration: Int, occupied: [ClosedRange<Int>], dayStart: Int, dayEnd: Int, step: Int) -> Int?; static func placements(taskIDs: [UUID], estimates: [UUID: Int?], at start: Int, occupied: [ClosedRange<Int>], dayStart: Int, dayEnd: Int, step: Int) -> [(taskID: UUID, start: Int, end: Int, fittedEstimate: Int?)] /* подряд; задача без оценки в промежутке < 60 берёт промежуток и возвращает fittedEstimate; не влезающие — пропускаются и цикл прерывается */; static func blockedDuration(at start: Int, occupied:, dayEnd:) -> Int; static func weekDays(containing day: Date, calendar:) -> [Date] /* пн–вс */; static func recurs(_ slot: TaskPlanSlot, from sourceDay: Date, on targetDay: Date, calendar:) -> Bool; static func summary(slots: [TaskPlanSlot], dayStart: Int, dayEnd: Int) -> (plannedMinutes: Int, availableMinutes: Int) }`.
- Produces (store): `plan(for day: Date, defaults: (start: Int, end: Int)) throws -> TaskDayPlan` (создаёт; обновляет часы до умолчаний из настроек), `effectiveSlots(for day: Date, planID: UUID) throws -> [TaskPlanSlot]` (свои + повторяющиеся занятые других дней с исходным id, без дублей по (title,start,end); слоты удалённых задач удаляются), `insertSlot(_:)`, `updateSlot(_:)`, `removeSlot(id:)`, `plannedTaskIDs() -> Set<UUID>`, `slots(for day:) -> [TaskPlanSlot]` (без создания плана).
- Produces (модель): `@Published public var plannerDay: Date` (сегодня; в полночь переходит на новый день, если показывался «сегодня» — таймер модели `tick()` проверяет смену дня), `@Published public private(set) var plan: TaskDayPlan?`, `slots: [TaskPlanSlot]`, `plannedTaskIDs: Set<UUID>`; `func loadPlanner() async`; `func dropTasks(_ ids: [UUID], at minutes: Int) async` (пишет оценку при `fittedEstimate`; тост «Не поместилось: N» для пропущенных); `moveSlot(id:to start: Int) async`, `resizeSlot(id:end: Int) async` (пишет оценку задачи), `removeSlot(id:) async`, `blockSlot(at:) async`, `unblockSlot(id:)` (= remove), `updateSlot(id:title:recurrence:) async`, `createTaskHere(at minutes:)` (ставит `pendingSlotStart`, UI фокусирует быстрый ввод; `create()` после вставки ставит слот), `plannerSummary: (planned: Int, available: Int)`, `currentSlot(now:) -> TaskPlanSlot?`, `nextSlot(now:) -> TaskPlanSlot?`. Переносы/растяжения/удаления — `TaskUndoStep.slots`.

- [ ] **Step 1: Write the failing tests**

```swift
// TaskPlannerTests
func testFreeStartPushesPastOccupiedThenBeforeIt()
func testPlacementsFitGapAndWriteEstimate()         // gap 30 min before a slot, task without estimate → end == slot.start, fittedEstimate 30
func testDropNearDayEndPlacesWhatFitsAndStops()     // dayEnd 17:00, start 16:30, two tasks with estimate 60: placements == [(first, 16:00, 17:00)] (the reference clamps to dayEnd − duration), the second is skipped; no end > 17:00
func testWeeklyBlockedSlotRecursOnSameWeekday()
func testBiweeklyRecursEveryOtherWeek()
func testSummaryExcludesBlockedFromAvailable()
func testEffectiveSlotsDropDeletedTasksAndDedupe() async throws
func testSlotsRoundTripWithTimeStrings() async throws
// TasksWorkspaceModelTests
func testMoveSlotIsUndoable() async throws
func testCreateHereSchedulesTheNewTask() async throws    // createTaskHere(at: 600) then create("Задача") → slot 10:00–11:00
func testPlannerDayAdvancesAtMidnightOnlyWhenOnToday() async throws
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh --filter 'TaskPlannerTests|TasksWorkspaceModelTests'`
Expected: FAIL.

- [ ] **Step 3: Implement**

По `dayPlanner.ts`, `useDayPlanner.ts`, `usePlannerOps.ts`. Хранение `start_time`/`end_time` как «ЧЧ:ММ».

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh --filter 'MakoshTasksTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MakoshTasks Tests/MakoshTasksTests
git commit -m "Add the day planner: plans, slots, placement rules and undoable moves"
```

---

### Task 8: Фокус-сессии поверх таймера и очередь черновиков

**Files:**
- Create: `Sources/MakoshTasks/TaskFocus.swift`, `Sources/MakoshTasks/TaskFocusService.swift`, `Sources/MakoshTasks/Presentation/TasksWorkspaceModel+Focus.swift`
- Modify: `Sources/MakoshTasks/TaskTimeService.swift`, `Sources/MakoshTasks/TasksService.swift`, `Sources/MakoshTasks/Presentation/TasksWorkspaceModel.swift`
- Test: `Tests/MakoshTasksTests/TaskFocusTests.swift` (новый), `Tests/MakoshTasksTests/TaskFocusServiceTests.swift` (новый), `Tests/MakoshTasksTests/TasksWorkspaceModelTests.swift`

**Interfaces:**
- Produces: `public struct TaskFocusSession: Codable, Equatable, Sendable { taskID: UUID; state: State (active|waiting); accumulatedSeconds: Int; activeSince: Date?; waitingSince: Date? }`; `public struct TaskPomodoro: Codable, Equatable, Sendable { phase: Phase (idle|work|`break`); startedAt: Date?; plannedMinutes: Int; pausedAt: Date?; pausedSeconds: Int }`; `public struct TaskFocusState: Codable, Equatable, Sendable { sessions; pomodoro; counts: [String: Int]; savedAt: Date?; var active: TaskFocusSession?; var waiting: [TaskFocusSession]; mutating func focus(taskID:now:); mutating func park(now:); mutating func remove(taskID:now:); mutating func startPomodoro(minutes:now:); mutating func pause(now:); mutating func resume(now:); mutating func stop(now:); mutating func completePhase(now:breakMinutes:) -> Phase?; func remaining(now:) -> TimeInterval; func workSeconds(of taskID: UUID, now:) -> Int; func waitingSeconds(of:now:) -> Int; func todayCount(now:calendar:) -> Int; mutating func restoreOnLaunch(now:) /* истёкший помидор → idle без зачёта; сессии остаются */ }` — порт `focusSession.ts` c поправкой перезапуска по спеке; `TaskStore.focusState() -> TaskFocusState?`, `saveFocusState(_:)`.
- Produces: `TaskTimeService.stopKeepingTime() async throws -> (taskID: UUID, seconds: Int)?` (снимает таймер без черновика, возвращает целые секунды), `draft(session taskID: UUID, startedAt: Date, seconds: Int, note: String) async -> TaskTimeDraft` (source `.timer`, `sendToJira` по подключению).
- Produces: `public actor TaskFocusService { init(store:, time:, now:); func state() -> TaskFocusState; func focus(taskID:) async throws -> TaskFocusState /* предыдущая активная: таймер снимается, секунды → accumulated, в ждущие; новая: таймер стартует */; func park() async throws; func remove(taskID:) async throws -> TaskTimeDraft? /* ждущая с накопленным ≥ 60 с → черновик */; func done(taskID:) async throws -> TaskTimeDraft? /* сессия завершается, черновик при ≥ 60 с; статус задачи ставит модель */; func stopActive() async throws -> TaskTimeDraft? /* «■» */; func pomodoro(_ command: PomodoroCommand) async throws /* start(minutes)/pause/resume/stop: pause/break снимают таймер в accumulated, resume/idle запускают */; func tickPhase(breakMinutes:) async throws -> TaskPomodoro.Phase? /* истечение */; func tasksClosed(_ ids: [UUID]) async throws -> [TaskTimeDraft] /* сессии закрытых задач → черновики */; func adoptRunningTimer() async throws /* включение панели при идущем таймере */; func restoreOnLaunch() async throws }`. Сервис подключён в `TasksService` как `public let focus: TaskFocusService`.
- Produces (модель): `@Published public private(set) var focusState = TaskFocusState()`, `focusEnabled: Bool` (из `preferences.focus.enabled`), `func focus(id:) async`, `park() async`, `removeFromFocus(id:) async`, `focusDone(id:) async` (черновик + `set(status: .done)`), `pomodoro(_:) async`, `setFocusEnabled(_:) async`; очередь: `private var draftQueue: [TaskTimeDraft]`, `func enqueue(_ draft: TaskTimeDraft, reason: String?)` → `draft` если пусто; `confirmDraft`/`discardDraft` подхватывают следующий; `TaskTimeDraft` получает `var reason: String?` («задача закрыта в Jira»). После каждого `refresh()` модель сверяет сессии с задачами: закрытые/удалённые → `focus.tasksClosed` → очередь (с `reason` когда последняя версия задачи от `provider`). `startTimer(id:)` при включённой панели = `focus(id:)`. `tick()` раз в секунду двигает помидор (`tickPhase`) и тосты «Интервал завершён»/«Перерыв окончен».

- [ ] **Step 1: Write the failing tests**

```swift
// TaskFocusTests (pure)
func testFocusSwitchesActiveToWaitingAndAccumulates()
func testPauseFreezesCountdownAndAttribution()
func testCompleteWorkPhaseCountsAndStartsBreak()      // breakMinutes 5 → phase break; 0 → idle
func testRestoreOnLaunchResetsExpiredPomodoroKeepsSessions()
// TaskFocusServiceTests (PostgreSQL)
func testFocusStartsTimerAndSwitchKeepsPreviousTime() async throws
    // focus(A) → timer A; advance 300; focus(B) → timer B, state.waiting A accumulated 300, no entry written
func testDoneYieldsDraftWithAccumulatedPlusRunning() async throws
func testWaitingUnderAMinuteIsRemovedWithoutDraft() async throws
func testPausePomodoroStopsTimerResumeRestarts() async throws
func testTasksClosedReturnsDraftsForTheirSessions() async throws
func testAdoptRunningTimerMakesItTheActiveSession() async throws
// TasksWorkspaceModelTests
func testMirrorClosingFocusedTaskQueuesDraft() async throws {
    // focus Jira task T (timer running 10 min); open a manual draft D1 (model.draft == D1)
    // mirror returns T with done category → after syncNow: model.draft still D1; after confirmDraft → model.draft.taskID == T, reason == "задача закрыта в Jira", seconds >= 600
}
func testFocusDoneMarksTaskDoneAndOpensDraft() async throws
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh --filter 'TaskFocusTests|TaskFocusServiceTests|TasksWorkspaceModelTests'`
Expected: FAIL.

- [ ] **Step 3: Implement**

Порт переходов; сервис держит инвариант «активная сессия ⇔ таймер на её задаче» и пишет состояние после каждого перехода; `restoreOnLaunch` зовётся в `TasksService.open()`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh --filter 'MakoshTasksTests'`
Expected: PASS, включая старые тесты таймера (`testStartPersistsTimerAcrossReopen`, `testDiscardedTimerDraftKeepsTheTimer`).

- [ ] **Step 5: Commit**

```bash
git add Sources/MakoshTasks Tests/MakoshTasksTests
git commit -m "Add focus sessions on top of the task timer with a queue of time drafts"
```

---

### Task 9: Календарь и правка значений в деталях

**Files:**
- Create: `Sources/MakoshTasks/TaskCalendar.swift`, `Sources/MakoshTasks/TaskFieldInput.swift`
- Modify: `Sources/MakoshTasks/Presentation/TasksWorkspaceModel.swift`
- Test: `Tests/MakoshTasksTests/TaskCalendarTests.swift` (новый), `Tests/MakoshTasksTests/TaskFieldInputTests.swift` (новый)

**Interfaces:**
- Produces: `public struct TaskCalendarMonth { year: Int; month: Int; cells: [Date?] /* 7 × n, первый день недели из настроек */; static func make(year:month:firstWeekday:calendar:) -> TaskCalendarMonth; func next()/previous() }`; `public enum TaskCalendarRules { static func dueDays(_ tasks: [Task], calendar:) -> Set<Date>; static func agendaRange(_ agenda: TasksAgenda?, today: Date, calendar:) -> ClosedRange<Date>? /* today, tomorrow(1), week(7), month(30); overdue → nil */ }`; `TaskDateFormat.string(_ date: Date, calendar:) -> String` (`iso` 2026-04-20, `dmy` 20.04.2026, `short` 20 апр, `long` 20 апреля 2026).
- Produces: `public enum TaskFieldInput { static func url(_ raw: String) -> URL? /* добавляет https://, отбрасывает неверные */; static func estimateMinutes(_ raw: String) -> Int? /* "1 hour", "1.5h", "30 min", "45", "2 ч", "30 мин" */; static func estimateText(_ minutes: Int) -> String /* "1,5 ч" / "30 мин" */; static func date(_ raw: String, today:calendar:) -> Date? /* TaskDateParser + dmy/iso */; static func personas(_ raw: String) -> [String] }`.
- Produces (модель): `@Published public var calendarMonth: TaskCalendarMonth`, `func selectDay(_ day: Date?)` (ставит `filters.day`, снимает повестку; повестка снимает день — в `TasksFilters`), `dueDays: Set<Date>`, `agendaRange`.

- [ ] **Step 1: Write the failing tests**

```swift
func testMonthCellsStartOnConfiguredWeekday()     // November 2026, Monday-first → leading nils 6 (1 Nov 2026 is Sunday)
func testAgendaRangeWeekIsSevenDays()
func testDateFormats()
func testURLNormalization()                        // "example.com/a" → https://example.com/a; "not a url" → nil
func testEstimateParsing()                         // "1.5h" → 90; "30 мин" → 30; "2 ч" → 120; "45" → 45; "x" → nil
func testEstimateText()                            // 90 → "1,5 ч"; 30 → "30 мин"; 120 → "2 ч"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh --filter 'TaskCalendarTests|TaskFieldInputTests'`
Expected: FAIL.

- [ ] **Step 3: Implement**

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh --filter 'MakoshTasksTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MakoshTasks Tests/MakoshTasksTests
git commit -m "Add the month calendar model and field input normalisation for tasks"
```

---

### Task 10: QA-сид и синтетика для новых возможностей

**Files:**
- Modify: `Sources/MakoshTasks/TasksQAIsolation.swift`, `Sources/MakoshTasks/JiraSyntheticAdapter.swift`
- Test: `Tests/MakoshTasksTests/TasksSyntheticTests.swift`

**Interfaces:**
- Produces: сид добавляет персоны («Боб», «Алиса») к трём задачам, `recurrence: "weekly"` к «Разобрать почту», две цепочки («Релиз»: задачи 3→4→5 с карточкой цвета `#f472b6` и сроком через 10 дней; «Ремонт»: две новые задачи с зависимостью), заметки списком, план на сегодня: слот задачи 2 (10:00–11:00), занятый «Обед» 12:30–13:00 с повтором `daily`, фокус-состояние с ждущей сессией на задаче 8 (`accumulatedSeconds: 420`), предпочтения с `focus.enabled = false`. Сид идемпотентен.

- [ ] **Step 1: Write the failing test**

```swift
func testSeedAddsFlowsPlanAndFocus() async throws {
    // after seed: flows().map(\.name) == ["Релиз", "Ремонт"]; slots(for: today).count == 2; focusState()?.waiting.count == 1; seeding twice changes nothing
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter 'TasksSyntheticTests'`
Expected: FAIL.

- [ ] **Step 3: Implement**

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh --filter 'TasksSyntheticTests|TasksQAIsolationTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MakoshTasks Tests/MakoshTasksTests
git commit -m "Seed flows, personas, recurrence, a day plan and a focus session for tasks QA"
```

---

### Task 11: Компоновка раздела: сворачиваемая колонка, шапка, колонки, строка состояния, тосты

**Files:**
- Modify: `Sources/MakoshApp/Workspace/WorkspaceSplitView.swift`, `Sources/MakoshApp/Workspace/WorkspaceView.swift`, `Sources/MakoshApp/Tasks/TasksViews.swift`, `Sources/MakoshApp/Tasks/TasksSyntheticPreview.swift`, `Sources/MakoshApp/Tasks/TaskDetailView.swift` (минимально: `notes` как список, чтобы собиралось; полная панель — Task 13)
- Test: сборка `scripts/build-app.sh`; модельные тесты уже покрывают состояние колонок.

**Interfaces:**
- Produces: `WorkspaceSplitView.init(width:minimum:maximum:minimumDetail:collapsed: Binding<Bool> = .constant(false), sidebar:detail:)` — при `collapsed` колонка 0 pt и ручка скрыта. `WorkspaceView` передаёт `collapsed` из `tasks.model?.showSidebar == false` для `.tasks`.
- Produces: `TasksContentView` по спеке «Компоновка»: `TasksHeaderBar` (кнопка панели, раскрывающийся поиск ⌘E с Esc, счётчики с кликами, «K найдено», переключатели планера ⌘D/календаря/компактного/правой колонки), `HStack`: `TaskListColumn` (быстрый ввод — пока текущий `TaskQuickEntryField`; `TaskFilterBar` — Task 13; список — Task 12; граф — Task 15; панель массовых действий — Task 12), разделитель-ручка планера (20–60 %, сохраняется) и `TaskPlannerView` (Task 14, пока заглушка `EmptyView`), правая колонка (`TaskCalendarPanel` Task 13 + `TaskDetailView`) 256/360 pt; `TasksStatusBar` (дата, счётчики, прогресс, «Jira: обновлено …»/«Обновить», сводка планера, последнее действие, «⌘Z — отменить», переключатель фокус-панели, таймер и сводка времени — объединяет `TaskTimerBar`); `TasksToastStack` справа внизу колонки списка, 3 с, стопкой. Витрина «Jira» — без правой колонки деталей, доска и карточка как сейчас.
- `TaskStyle` получает цвета референса: `priority(_:)` → `#ef4444 #fb923c #60a5fa #6b7280`, `status(_:)` фон/текст, `chip(kind:)` из `CHIP_STYLE`.

- [ ] **Step 1: Implement**

Разметка без новых правил: всё состояние уже в модели (Task 4, 7, 8); представления только привязываются к нему.

- [ ] **Step 2: Build**

Run: `scripts/build-app.sh 2>&1 | tail -3`
Expected: exit 0.

- [ ] **Step 3: Synthetic smoke** — `scripts/run-tasks-qa.py --bundle .build/Makosh.app --launch`, окно открывается, боковая панель сворачивается кнопкой, планер/календарь/правая колонка переключаются; закрыть окно QA.

- [ ] **Step 4: Commit**

```bash
git add Sources/MakoshApp
git commit -m "Lay out the tasks section as the reference: header, columns, status bar and toasts"
```

---

### Task 12: Список: строки, курсор, клавиши, рамка, меню, панель массовых действий

**Files:**
- Modify: `Sources/MakoshApp/Tasks/TaskListView.swift`, `Sources/MakoshApp/Tasks/TasksSidebar.swift` (переход на `filters`, секции, счётчики, персоны, цепочки с прогрессом, горячие клавиши, сворачивание всех, кнопка настроек)
- Test: сборка; модельные тесты Task 3–4.

**Interfaces:**
- Produces: `TaskListView` на собственном `ScrollView`/`LazyVStack` (не `List`), строки по спеке «Строка» (`TaskRowView`: чекбокс с `ConfirmDialog`, значки, бейджи `TaskStatusBadge` (клик — `cycleStatus`) и `TaskPriorityBadge`, персоны, код/ключ, название/переименование `F2` (`TextField` с commit по Enter/blur, Esc отмена), подписи блокировки, теги/срок/повтор/цепочка/заметки/таймер, полоса, курсор, компактный режим), заголовок «Просрочено N» (клик выделяет), группы цепочек скобкой, пустые состояния. Клавиатура через `.onKeyPress` на фокусируемом контейнере (`@FocusState`): таблица спеки; `⌘C` через `FocusedValue` `copyTaskReferences` и `TaskSelectionCommands: Commands` в `MakoshApp` (как `TelegramSelectionCommands`); `Tab` переводит фокус по кольцу (`FocusState` enum `TasksFocusTarget { search, quickEntry, list }` в модели представления). Рамка мышью: `DragGesture` на фоне колонки с `PreferenceKey` рамок строк → `selection.selected`. Контекстное меню `TaskContextMenu` по спеке (с «Выбрано N»). `TaskBulkBar` под списком. Перетаскивание строк в планер — `draggable` с `TaskDragPayload` (`Transferable`, список id) — используется в Task 14.
- `TasksSidebarView` по спеке «Боковая панель»: `Section` сворачиваемые (`collapsedSections`), «Свернуть все/Развернуть все», `FilterItem` c счётчиками, цепочки с полосой прогресса, «Горячие клавиши» (свёрнута), внизу «Настройки» (открывает окно настроек на вкладке «Задачи» через `SettingsLink`/`NSApp.sendAction(Selector(("showSettingsWindow:")))` как в других разделах) и «Jira» с подключениями.

- [ ] **Step 1: Implement**

Боковая панель уже минимально переведена на `filters` в Task 4; здесь она доводится до спеки вместе со списком.

- [ ] **Step 2: Build**

Run: `scripts/build-app.sh 2>&1 | tail -3`
Expected: exit 0.

- [ ] **Step 3: Synthetic check** — в QA-окне: ↑/↓, ⇧↓, ⌘⇧A, Space, S, 1–4, ⇧P, F2, Enter (пока открывает карточку; диалог — Task 13), ⌫, Esc-каскад, рамка мышью, контекстное меню «Выбрано N», панель массовых действий, «Просрочено N».

- [ ] **Step 4: Commit**

```bash
git add Sources/MakoshApp
git commit -m "Rebuild the task list with the reference's rows, cursor, keys, rubber band and bulk bar"
```

---

### Task 13: Сортировка и чипы фильтров, календарь, панель деталей, диалог правки, быстрый ввод с чипами

**Files:**
- Create: `Sources/MakoshApp/Tasks/TaskFilterBar.swift`, `Sources/MakoshApp/Tasks/TaskCalendarPanel.swift`, `Sources/MakoshApp/Tasks/TaskEditDialog.swift`, `Sources/MakoshApp/Tasks/TaskQuickEntryField.swift`
- Modify: `Sources/MakoshApp/Tasks/TaskDetailView.swift`, `Sources/MakoshApp/Tasks/TasksViews.swift`
- Test: сборка; модельные тесты Task 5, 9.

**Interfaces:**
- `TaskFilterBar`: чипы сортировки (три состояния), строка чипов фильтров с «×», флажки «Только актуальные» и «Группировать по цепочкам» по правилам видимости спеки.
- `TaskCalendarPanel`: по спеке «Календарь» на `TaskCalendarMonth`.
- `TaskDetailView`: пусто / несколько / одна — строки `DetailRow(icon:label:)` с `EditableValue` (текст, выбор, комбобокс `TaskCombobox`, дата через `TaskFieldInput.date` + `DatePicker` popover), ссылка, заметки карточками с окном правки (⌘⏎), карточка Jira сверху (без изменений), блок «Время» внизу; ширина задаёт родитель.
- `TaskEditDialog` (sheet 520 pt) по спеке «Диалог правки»; `TaskChipsField` (теги/персоны/зависимости) с `TaskCombobox`; подвал с `to:КОД` и кнопками; Enter сохраняет вне многострочных полей.
- `TaskQuickEntryField`: `TaskQuickEntryChips` + `ChipPill`, выпадающие подсказки (↑/↓/Tab/Enter), Backspace, Enter создаёт; `⌘N` фокус. Карточка больше не открывается по выделению — по Enter/двойному клику (диалог), панель деталей показывает выделение.

- [ ] **Step 1: Implement**

- [ ] **Step 2: Build**

Run: `scripts/build-app.sh 2>&1 | tail -3`
Expected: exit 0.

- [ ] **Step 3: Synthetic check** — чипы сортировки/фильтров, календарь (точки, диапазон, день), панель деталей с правкой по клику, диалог правки со всеми полями, быстрый ввод с чипами и подсказками.

- [ ] **Step 4: Commit**

```bash
git add Sources/MakoshApp
git commit -m "Add the filter bar, calendar, click-to-edit details, the edit dialog and chip quick entry"
```

---

### Task 14: Планер дня в приложении

**Files:**
- Create: `Sources/MakoshApp/Tasks/TaskPlannerView.swift`
- Modify: `Sources/MakoshApp/Tasks/TasksViews.swift`, `Sources/MakoshApp/Tasks/TaskListView.swift` (drag source)
- Test: сборка; модельные тесты Task 7.

**Interfaces:**
- `TaskPlannerView` по спеке «Планер дня»: вкладки недели, сетка (60 pt/час, подписи, линия «сейчас»), `dropDestination(for: TaskDragPayload.self)` с пересчётом y → минуты, слоты (`TaskSlotView`: компакт < 36 pt, полоса приоритета, перетаскивание по вертикали с предпросмотром и удалением при выходе, ручка растяжения), контекстные меню слота/пустого места, двойные клики, модальная правка занятого (название, повтор), пустое состояние. Ширина — доля из модели; ручка между списком и планером.

- [ ] **Step 1: Implement**

- [ ] **Step 2: Build**

Run: `scripts/build-app.sh 2>&1 | tail -3`
Expected: exit 0.

- [ ] **Step 3: Synthetic check** — бросок одной и трёх задач, подгонка под промежуток, перемещение, растяжение (оценка меняется в деталях), удаление наружу, занятый промежуток с повтором, «Создать задачу здесь», сводка в строке состояния, значок часов в строке.

- [ ] **Step 4: Commit**

```bash
git add Sources/MakoshApp
git commit -m "Add the day planner column with drag-in, move, resize and blocked slots"
```

---

### Task 15: Граф цепочки в приложении

**Files:**
- Create: `Sources/MakoshApp/Tasks/TaskFlowView.swift`
- Modify: `Sources/MakoshApp/Tasks/TasksViews.swift`
- Test: сборка; модельные тесты Task 6.

**Interfaces:**
- `TaskFlowView(model:flow:)` под списком при `filters.flow`: шапка (имя цветом, «Запустить следующую», карандаш, корзина с подтверждением), карточка цепочки (описание, срок, палитра), прогресс, холст `Canvas` + узлы `TaskFlowNodeView` 200×76 по `TaskFlowLayout`, стрелки (`Path` с наконечником), ручки соединения (drag от правой к левой → `addDependency` с тостом при цикле), контекстное меню узла, клик/двойной клик.

- [ ] **Step 1: Implement**

- [ ] **Step 2: Build**

Run: `scripts/build-app.sh 2>&1 | tail -3`
Expected: exit 0.

- [ ] **Step 3: Synthetic check** — фильтр «Релиз»: граф 3→4→5, «готова к запуску», «Запустить следующую», добавление зависимости протяжкой, отказ цикла, удаление цепочки.

- [ ] **Step 4: Commit**

```bash
git add Sources/MakoshApp
git commit -m "Draw task flows as a dependency graph with inline flow editing"
```

---

### Task 16: Фокус-панель, Настройки → Задачи, гид

**Files:**
- Create: `Sources/MakoshApp/Tasks/TaskFocusPanel.swift`, `Sources/MakoshApp/Tasks/TasksGuideOverlay.swift`
- Modify: `Sources/MakoshApp/Tasks/TasksSettingsView.swift`, `Sources/MakoshApp/Tasks/TasksHost.swift`, `Sources/MakoshApp/Tasks/TasksViews.swift`, `Sources/MakoshApp/Tasks/TaskListView.swift` («В фокус» в меню)
- Test: сборка; модельные тесты Task 8.

**Interfaces:**
- `TaskFocusPanelController` (`@MainActor`, владеет `NSPanel`: `.nonactivatingPanel`, `.borderless`, `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, геометрия по экрану главного окна: ширина экрана, высота 26 или `clamp(screen.height/33, 26, 52)`, у верхнего края под строкой меню; `show()/hide()`, переразмер при смене экрана через `NSApplication.didChangeScreenParametersNotification`); содержимое `TaskFocusBarView(model:)` по спеке «Окно» (три зоны, модули, пресеты, «до конца слота», счётчик, «Далее», часы, «×», полоса прогресса); `TasksHost` создаёт контроллер и следит за `model.focusEnabled`.
- Настройки: секции «Отображение» (формат даты, первый день недели, компактный режим, панель массовых действий, извлекать ссылки, «новая задача на сегодня — сразу активна»), «Планер» (начало, конец, шаг), «Фокус-панель» (включена, компактно, модули, пресеты, перерыв), «Гид» («Показать гид снова»); пишут `TaskPreferences` через модель (`func updatePreferences(_ change: (inout TaskPreferences) -> Void)`).
- `TasksGuideOverlay` по спеке «Гид»: цели через `PreferenceKey` рамок (`TasksGuideAnchor` модификатор на боковой панели, поиске, быстром вводе, панели фильтров, первой строке, панели деталей), затемнение с вырезом (`Canvas` + `blendMode(.destinationOut)`), подсказка 320 pt с умным размещением, «Назад/Далее/Готово/Пропустить», пропуск шагов без цели; показ при `!preferences.guideCompleted`.

- [ ] **Step 1: Implement**

- [ ] **Step 2: Build**

Run: `scripts/build-app.sh 2>&1 | tail -3`
Expected: exit 0.

- [ ] **Step 3: Synthetic check** — включить панель в Настройках: окошко у верхнего края; «В фокус» из меню; пресет 15′, пауза, стоп, «Сделано» → черновик в главном окне; ждущая из сида с минутами; «×» прячет; гид проходит шесть шагов и больше не показывается; «Показать гид снова» работает.

- [ ] **Step 4: Commit**

```bash
git add Sources/MakoshApp
git commit -m "Add the focus panel, the tasks settings sections and the onboarding guide"
```

---

### Task 17: Документы, полные проверки, синтетический осмотр

**Files:**
- Modify: `docs/tasks.md`, `docs/reference-interface.md`, `docs/development-status.md`, `docs/architecture.md` (ADR-018 дополнение: правила закрытия в хранилище, фокус поверх таймера), `AGENTS.md` («Tasks decisions»: правила закрытия в транзакции; время сессий только через черновик), `scripts/run-tasks-qa.py` (если нужны новые аргументы)

- [ ] **Step 1: Полные проверки**

Run: `scripts/dev-db.sh up && scripts/test.sh 2>&1 | tail -15 && scripts/build-app.sh 2>&1 | tail -3 && scripts/format.sh HEAD`
Expected: все бандлы exit 0; форматирование без изменений или зафиксировать их.

- [ ] **Step 2: Синтетический осмотр** — `scripts/run-tasks-qa.py --bundle … --launch`; пройти по спеке «Проверка»; сверить с `img/main_window.png`; расхождения (ширина колонки 280–390 вместо 224, правая колонка 360 при Jira, отсутствие тем/языка) — в `docs/reference-interface.md`.

- [ ] **Step 3: Документы** — `docs/tasks.md`: разделы «Интерфейс» (компоновка, клавиши), «Планер», «Цепочки», «Повторы», «Персоны», «Фокус», «Настройки»; «Вторая очередь» без перенесённого; статус в `docs/development-status.md` с реальными результатами и пропусками.

- [ ] **Step 4: Commit**

```bash
git add docs AGENTS.md scripts
git commit -m "Document the tasks interface and record its checks"
```
