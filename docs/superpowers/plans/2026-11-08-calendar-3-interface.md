# Календарь, план 3: раздел, настройки, напоминания, фон, связи и QA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Раздел «Календарь» в общем рабочем пространстве по варианту C (неделя по центру, календари слева, задачи справа), Настройки → Календарь, напоминания Makosh, работа в фоне при закрытом окне, планер «Задач» на событиях календаря, «Добавить Telemost» и «Написать организатору», синтетический QA-бандл на схеме `qa_calendar_` и документация.

**Architecture:** `CalendarWorkspaceModel` (`@MainActor`, `MakoshCalendar/Presentation`, `package`) держит состояние раздела и вызывает `CalendarService`; раскладка сетки и план напоминаний — чистые функции с тестами. `CalendarHost` в `AppDelegate` живёт дольше окна. Связь с «Задачами» — протокол `TaskPlannerBackend` в `MakoshTasks`, который реализует приложение; `MakoshCalendar` не импортирует `MakoshTasks`.

**Tech Stack:** SwiftUI/AppKit, `UserNotifications`, `ServiceManagement` (`SMAppService.mainApp`), XCTest, Python для QA-скрипта.

**Spec:** `docs/superpowers/specs/2026-11-08-calendar-design.md`; планы 1 и 2 — `docs/superpowers/plans/2026-11-08-calendar-1-core.md`, `docs/superpowers/plans/2026-11-08-calendar-2-sync.md`.

## Global Constraints

- Всё из Global Constraints планов 1 и 2.
- Общая оболочка: `WorkspaceSplitView`, `WorkspaceStyle`, `WorkspaceBackdrop`, тёмная матово-стеклянная тема; раздел в выпадающем списке разделов называется «Календарь», символ `calendar`.
- В сводном виде — только оригиналы; плашки — только в виде конкретного календаря, штриховкой с подписью «Занято · <календарь-источник>» (подпись только локально).
- Рабочий день — серая подсветка в виде календаря его учётной записи; занятости не создаёт.
- Напоминания — через единый `ApplicationSystemNotificationRouter` с префиксом идентификатора `makosh.calendar.`; плашки и отклонённые не напоминают; пропущенные за время выключения не показываются; по умолчанию за 10 минут.
- Закрытие последнего окна не завершает приложение; «Открывать Makosh при входе» по умолчанию выключено.
- Доступ к окнам QA через computer-use пользователь отклонил: осмотр экрана делает пользователь; в статусе это записывается как непроверенное мной.
- QA: бандл `org.makosh.calendar.qa`, флаг `--calendar-synthetic-preview`, схема `qa_calendar_<suffix>` только на loopback PostgreSQL, синтетические адаптеры, Keychain в памяти.
- Внутри `MakoshTasks` и `Sources/MakoshApp/Tasks` Swift-овский `Task` пишется `_Concurrency.Task`; `MakoshApp.swift` и `WorkspaceView.swift` не импортируют `MakoshTasks`.

## Review Focus

1. **Перетаскивание задачи на занятое время** — бросок сам сдвигается в ближайший свободный промежуток; окно конфликта — только когда места нет до конца дня. Тест в задаче 2.
2. **Пересекающиеся события в колонке** — три события 10:00–11:00, 10:30–12:00, 11:00–11:30 ложатся в две колонки без наложения. Тест в задаче 1.
3. **Напоминание после правки времени** — перенос события снимает старое запланированное уведомление и ставит новое; удалённое — снимает. Тест в задаче 3.
4. **Повторный перенос слотов планера** — перенос старых `tasks_day_plan_slots` в календарь идёт один раз и не дублирует события при втором запуске. Тест в задаче 5.
5. **Окно закрыто, приложение работает** — обход и напоминания продолжаются (хост не зависит от окна). Тест в задаче 6.

---

### Task 1: Раскладка сетки и периоды

**Files:**
- Create: `Sources/MakoshCalendar/Presentation/CalendarGridLayout.swift`, `Sources/MakoshCalendar/Presentation/CalendarPeriod.swift`
- Test: `Tests/MakoshCalendarTests/CalendarGridLayoutTests.swift`

**Interfaces:**
- Produces:
  - `package struct CalendarPeriod: Equatable, Sendable { mode: CalendarViewMode; anchor: Date; package func interval(calendar: Foundation.Calendar) -> DateInterval; package func days(calendar:) -> [Date]; package func moved(by steps: Int, calendar:) -> CalendarPeriod }` — неделя начинается с `firstWeekday` предпочтений.
  - `package struct CalendarGridItem: Equatable, Identifiable, Sendable { id: String; occurrence: CalendarOccurrence; column: Int; columns: Int; startMinute: Int; endMinute: Int; clippedTop: Bool; clippedBottom: Bool }`
  - `package enum CalendarGridLayout { package static func layout(day: Date, occurrences: [CalendarOccurrence], calendar: Foundation.Calendar) -> [CalendarGridItem]; package static func allDay(days: [Date], occurrences: [CalendarOccurrence], calendar:) -> [[CalendarOccurrence]] }` — жадные колонки по кластерам пересечений; события через полночь режутся по дням.

- [ ] **Step 1: Tests** `testOverlapsShareColumns` (три события из Review Focus → колонки 0,1,0 при `columns == 2`), `testMidnightSplit`, `testWeekStartsOnPreference`, `testMoveByMonthClampsDay`, `testAllDaySpansDays`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Lay out calendar days and periods"`

### Task 2: Модель раздела `CalendarWorkspaceModel`

**Files:**
- Create: `Sources/MakoshCalendar/Presentation/CalendarWorkspaceModel.swift`, `Sources/MakoshCalendar/Presentation/CalendarTaskFeed.swift`
- Test: `Tests/MakoshCalendarTests/CalendarWorkspaceModelTests.swift`

**Interfaces:**
- Consumes: `CalendarService` (план 2), `CalendarGridLayout`.
- Produces:
  - `package struct CalendarTaskItem: Equatable, Identifiable, Sendable { id: UUID; title: String; estimateMinutes: Int?; due: Date?; overdue: Bool }`
  - `package protocol CalendarTaskFeed: Sendable { func tasks(agenda: CalendarTaskAgenda) async -> [CalendarTaskItem]; func dueMarks(in interval: DateInterval) async -> [Date: [CalendarTaskItem]]; func setEstimate(taskID: UUID, minutes: Int) async }`, `package enum CalendarTaskAgenda: String, CaseIterable, Sendable { case today, week, overdue, all }`
  - `@MainActor package final class CalendarWorkspaceModel: ObservableObject` с `@Published package private(set) var snapshot: CalendarSnapshot?`, `period: CalendarPeriod`, `selectedCollectionID: UUID?` (nil — сводный), `conflict: CalendarConflictPrompt?`, `groupPreview: BusyPreview?`, `error: String?`, `tasks: [CalendarTaskItem]`, `agenda: CalendarTaskAgenda`; методы `refresh() async`, `syncNow() async`, `go(_ steps: Int)`, `today()`, `setMode(_:)`, `select(collectionID: UUID?)`, `visibleOccurrences(day: Date) -> [CalendarGridItem]` (сводный: оригиналы показанных календарей; вид календаря: его события и его плашки), `workingHours(day: Date) -> [ClosedRange<Int>]` (только в виде календаря), `create(_ draft: CalendarDraft) async`, `move(eventID:to:scope:) async`, `dropTask(_ item: CalendarTaskItem, at start: Date) async`, `resolveConflict(_ choice: CalendarConflictChoice) async`, `respond(eventID:_:) async`, `check(attemptID:) async`, `dismiss(attemptID:) async`, `stage(collections:groups:) async` / `confirmGroupChange() async`, `undoLastMove() async` (⌘Z: новая запись прежнего времени последнего переноса или растяжения; для события с участниками сначала `undoNeedsConfirmation == true`, запись — после `confirmUndo()`).
  - `package struct CalendarConflictPrompt: Identifiable, Sendable { id: UUID; pending: CalendarPendingWrite; conflicts: [CalendarConflict]; suggestion: Date? }`, `package enum CalendarConflictChoice: Sendable { case writeAnyway, pickTime(Date), writeToOrganizer(CalendarConflict), decline(CalendarConflict) }`, `package enum CalendarPendingWrite: Sendable { case create(CalendarDraft), move(eventID: UUID, time: CalendarEventTime, scope: CalendarEditScope) }`
  - Замыкание `package var writeToOrganizer: (@MainActor (String, String?) -> Void)?` (адрес, тема) задаёт приложение.

`dropTask`: календарь — `preferences.lastCollectionID` или локальный; длина — оценка или 60 мин; начало прижимается к шагу 15 мин; при занятости — `service.nearestFree` в пределах того же дня; нет места → `conflict` с исходным временем. `decline` — `respond(.declined)` у пересекающегося приглашения, затем запись без повторного вопроса об этом пересечении. Ошибки показываются текстом без деталей ответа сервера.

- [ ] **Step 1: Tests** (синтетический адаптер + PostgreSQL): `testSummaryHidesBusyCopiesCalendarViewShowsThem`, `testWorkingHoursOnlyInCalendarView`, `testDropOntoBusyShiftsToFreeSlot`, `testDropWithNoRoomRaisesConflict`, `testWriteAnywayWrites`, `testDeclineRespondsThenWrites`, `testWriteToOrganizerCallsClosure`, `testGroupChangeNeedsConfirmation`, `testLastCollectionRemembered`, `testUndoMoveWritesPreviousTime`, `testUndoWithAttendeesAsksFirst`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Add the calendar workspace model"`

### Task 3: План напоминаний и уведомления

**Files:**
- Create: `Sources/MakoshCalendar/CalendarReminderPlanner.swift`, `Sources/MakoshApp/Calendar/CalendarSystemNotifications.swift`
- Modify: `Sources/MakoshApp/Telegram/TelegramSystemNotificationRouter.swift` (реестр `calendarRegistry`, ветки `makosh.calendar.` в `willPresent`, `didReceive`, `systemIdentifiers`)
- Test: `Tests/MakoshCalendarTests/CalendarReminderPlannerTests.swift`

**Interfaces:**
- Produces:
  - `public struct CalendarReminder: Hashable, Sendable { identifier: String /* "<eventID>.<key epoch>.<minutes>" */; eventID: UUID; fireAt: Date; title: String; start: Date }`
  - `public enum CalendarReminderPlanner { public static func reminders(snapshot: CalendarSnapshot, now: Date, lookahead: TimeInterval = 86400) -> Set<CalendarReminder> }` — только оригиналы с `givesBusy` или `.free` без отказа, не плашки, `fireAt > now`; минуты — `event.reminders`, иначе `collection.defaultReminderMinutes`.
  - `@MainActor final class CalendarSystemNotifications` — сверяет план с запланированными `UNNotificationRequest` (`UNTimeIntervalNotificationTrigger`) по идентификаторам: лишние снимает, новые ставит; `canPresent(_:)` — событие ещё существует и не отклонено; `activate(_:)` — открыть окно и событие. Разрешение — через общий `beginAuthorizationRequest()` роутера, один раз.

- [ ] **Step 1: Tests** `testPlansFromEventOrCalendarDefault`, `testSkipsCopiesDeclinedAndPast`, `testMovingEventChangesIdentifier` (старый идентификатор уходит, новый появляется), `testDeletedEventDropsReminder`.
- [ ] **Step 2–4:** FAIL → implement → PASS (класс приложения проверяется сборкой и QA).
- [ ] **Step 5: Commit** — `git commit -m "Plan and deliver calendar reminders through the shared notification router"`

### Task 4: Хост приложения, раздел и работа в фоне

**Files:**
- Create: `Sources/MakoshApp/Calendar/CalendarHost.swift`
- Modify: `Sources/MakoshApp/MakoshApp.swift` (`lazy var calendar = CalendarHost()` в `AppDelegate`; `applicationShouldTerminateAfterLastWindowClosed` → `false`; среда `\.calendarHost`; вкладка Настроек; QA-ветка), `Sources/MakoshApp/Workspace/WorkspaceView.swift` (`Destination.calendar = "Календарь"`, символ `calendar`; старт хоста с конфигурацией рядом с `tasks.start`; боковая колонка и деталь)
- Test: `Tests/MakoshTelemostTests/ApplicationLifetimeTests.swift` (тестовая цель с `MakoshApp` уже есть)

**Interfaces:**
- Produces: `@MainActor final class CalendarHost: ObservableObject { @Published private(set) var model: CalendarWorkspaceModel?; @Published private(set) var failure: String?; func start(configuration: ContactWorkspaceConfiguration, taskFeed: (any CalendarTaskFeed)?, seed: ((CalendarStore) async throws -> Void)? = nil) async; static let qaFlag: String; init(); init(synthetic adapter: CalendarSyntheticAdapter) /* DEBUG */ }` — создаёт `CalendarStore` в схеме приложения, `CalendarService` с `defaultAdapterFactory`, `GoogleOAuth` с `GoogleOAuthClient.embedded` и `openBrowser = NSWorkspace.shared.open`, запускает опрос и напоминания; повторный `start` ничего не делает.
- `LoginItemSetting` — `@MainActor enum` с `isEnabled`, `set(_:) throws` поверх `SMAppService.mainApp`.

- [ ] **Step 1: Test** `testAppDelegateKeepsRunningAfterLastWindowClosed` (`XCTAssertFalse(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))`), `testCalendarHostOutlivesWindow` (хост принадлежит делегату: один экземпляр на два обращения).
- [ ] **Step 2–4:** FAIL → implement → PASS; `scripts/build-app.sh` → exit 0.
- [ ] **Step 5: Commit** — `git commit -m "Host the calendar section and keep Makosh running without windows"`

### Task 5: Планер «Задач» на событиях календаря

**Files:**
- Create: `Sources/MakoshTasks/TaskPlannerBackend.swift`, `Sources/MakoshApp/Calendar/CalendarPlannerBridge.swift`
- Modify: `Sources/MakoshTasks/Presentation/TasksWorkspaceModel+Planner.swift` (чтение и запись слотов через `plannerBackend`), `Sources/MakoshTasks/Presentation/TasksWorkspaceModel.swift` (свойство `public var plannerBackend: (any TaskPlannerBackend)?`), `Sources/MakoshApp/Tasks/TasksHost.swift` (передать мост, когда календарь открыт)
- Test: `Tests/MakoshTasksTests/TaskPlannerBackendTests.swift`, `Tests/MakoshCalendarTests/CalendarPlannerBridgeLogicTests.swift`

**Interfaces:**
- Produces:
  - В `MakoshTasks`: `public protocol TaskPlannerBackend: Sendable { func slots(for day: Date, calendar: Foundation.Calendar) async throws -> [TaskPlanSlot]; func plannedTaskIDs() async throws -> Set<UUID>; func insert(_ slot: TaskPlanSlot, day: Date) async throws -> TaskPlanSlot; func update(_ slot: TaskPlanSlot, day: Date) async throws; func remove(slotID: UUID) async throws }` и `public struct TaskStorePlannerBackend: TaskPlannerBackend` поверх существующих таблиц (поведение без календаря не меняется).
  - В `MakoshCalendar`: `public struct CalendarPlannerMapping { public static func slot(from occurrence: CalendarOccurrence, event: CalendarEvent, planID: UUID, calendar: Foundation.Calendar) -> TaskPlanSlotValue; public static func migrationKey(slotID: UUID) -> String }`, где `TaskPlanSlotValue` — нейтральная пара (taskID, title, start, end, recurrence) без зависимости от `MakoshTasks`; блок задачи → слот `.task`, прочие события → `.blocked` только для показа.
  - `CalendarService.migratePlannerSlots(_ slots: [(id: UUID, day: Date, value: TaskPlanSlotValue)]) async throws -> Int` — создаёт события в локальном календаре с `uid = "makosh-slot-<id>"`; повторный вызов находит их по `uid` и ничего не создаёт; `daily|weekly|biweekly` → `RRULE:FREQ=DAILY` / `FREQ=WEEKLY` / `FREQ=WEEKLY;INTERVAL=2`.
  - Растяжение блока задачи пишет оценку задачи (`CalendarTaskFeed.setEstimate`); ⌘Z в планере — новая запись прежнего времени, для события с участниками — с подтверждением (решение автора в спецификации).

- [ ] **Step 1: Tests** `testStoreBackendKeepsLegacyBehaviour` (существующие тесты `TaskPlannerTests` проходят через бэкенд), `testMappingTaskBlockAndForeignEvent`, `testMigrationIsIdempotent`, `testRecurringSlotBecomesRRule`.
- [ ] **Step 2–4:** FAIL → implement → PASS; весь `MakoshTasksTests` PASS.
- [ ] **Step 5: Commit** — `git commit -m "Back the tasks planner with calendar events"`

### Task 6: Виды раздела

**Files:**
- Create: `Sources/MakoshApp/Calendar/CalendarSidebar.swift` (мини-месяц, учётные записи и календари с цветом, флажком, бейджами групп, значками состояния; клик по имени — вид календаря; «Группы»), `CalendarHeader.swift` (Сегодня, ← →, период, День/Неделя/Месяц, «Сводный / <календарь>», «Обновить», счётчик внешних пересечений, кнопка колонки задач), `CalendarWeekGrid.swift` (дни, полоса «весь день» с метками сроков задач, сетка часов, рабочий день серым, протяжка — создание, перетаскивание и растяжение, штриховка плашек), `CalendarMonthGrid.swift`, `CalendarTaskColumn.swift` (список с повесткой, перетаскивание), `CalendarEventCard.swift` (поповер и лист: поля из спецификации, «Подключиться», «Добавить Telemost», «Приду / Возможно / Не приду», строки попыток с «Проверить»/«Отказаться»; для плашки — «Занято, источник: …» с переходом), `CalendarConflictSheet.swift` (список пересечений, четыре действия), `CalendarGroupPreviewSheet.swift` («Будет поставлено N плашек в …, убрано M»), `CalendarViews.swift` (сборка раздела)
- Modify: `docs/reference-interface.md`

Клавиши: ←/→ — период, T — сегодня, 1/2/3 — день/неделя/месяц, Enter — открыть выбранное, ⌫ — удалить выбранное (с вопросом «только это / вся серия» для повторов). Тексты кнопок — ровно как в спецификации.

- [ ] **Step 1:** Собрать виды поверх модели задачи 2; `scripts/build-app.sh` → exit 0.
- [ ] **Step 2:** Снимок макета варианта C из `.superpowers/brainstorm/*/content/layout-v3.html` сохранить в `docs/design/calendar-variant-c.png` (снимок встроенного браузера) и описать вариант C и расхождения с Morgen/Amie в `docs/reference-interface.md`.
- [ ] **Step 3: Commit** — `git commit -m "Add the calendar section views"`

### Task 7: Настройки → Календарь

**Files:**
- Create: `Sources/MakoshApp/Calendar/CalendarSettingsView.swift`
- Modify: `Sources/MakoshApp/MakoshApp.swift` (вкладка «Календарь», `MakoshSettingsTab.calendar = "calendar"`)

Содержимое: учётные записи (Добавить Google — недоступно с надписью «Вход Google не настроен в этой сборке», если клиента нет; Добавить CalDAV — выбор почтовой учётной записи подставляет `CalDAVProviders.suggestion` и логин, пароль отдельно; Добавить по ссылке; «Войти снова»; «Отключить»; для `adminBlocked` — «Администратор Google Workspace запретил Makosh доступ к этому аккаунту. Попросите администратора разрешить приложение с идентификатором <clientID>.»; для CalDAV без серверной рассылки — «Сервер не рассылает приглашения сам: участники сохранятся только в Makosh»), календари (цвет, показ, право записи только для чтения, напоминание по умолчанию), группы (создать, переименовать, состав; изменение — через предпросмотр), рабочий день каждой учётной записи (интервалы по дням недели), окно плашек и период обхода, раздел «Фон»: «Makosh продолжает обновлять календари при закрытом окне; если приложение завершено, плашки не обновляются» и переключатель «Открывать Makosh при входе» (`LoginItemSetting`). Общей вкладки в Настройках нет, поэтому переключатель живёт здесь (отклонение от спецификации, записать в `docs/calendar.md`).

- [ ] **Step 1:** Реализовать; `scripts/build-app.sh` → exit 0.
- [ ] **Step 2: Commit** — `git commit -m "Add calendar settings with accounts, groups and working hours"`

### Task 8: Telemost, почта и контакты

**Files:**
- Modify: `Sources/MakoshApp/Calendar/CalendarHost.swift`, `Sources/MakoshApp/Workspace/WorkspaceView.swift`, `Sources/MakoshApp/Calendar/CalendarEventCard.swift`
- Test: `Tests/MakoshCalendarTests/CalendarMeetingLinkTests.swift`

**Interfaces:**
- Produces:
  - `public enum CalendarMeetingLink { public static func telemost(in text: String) -> URL? }` (общая с разбором iCalendar и Google; проверка через `TelemostMeetingURL` на стороне приложения перед открытием).
  - «Подключиться» — существующая HTTPS-передача Telemost (`TelemostMeetingURL` → `NSWorkspace.open`).
  - «Добавить Telemost» — только в календаре CalDAV-учётной записи Яндекса и при подключённой учётной записи «Встреч»: `TelemostWorker.create(accountID:request:)`, ожидание ссылки в снимке «Встреч» до 30 с, вставка в `meetingURL`; без ссылки — сообщение «Встреча создаётся, ссылка появится в разделе „Встречи“».
  - «Написать организатору» — `writeToOrganizer(адрес, тема)` в `WorkspaceView` переключает раздел на «Почта» и вызывает `MailWorkspaceModel.compose(to:attachments: [])`; письмо не уходит само.
  - Участники — подсказки из `WorkspaceModel.contacts` по адресам почты; запись в досье — заглушка: `// Dossier projection is the next stage (spec 2026-11-08)` без вызова.

- [ ] **Step 1: Tests** `testFindsTelemostLinks`, `testIgnoresLookalikeHosts` (`telemost.yandex.ru.evil.test` → nil).
- [ ] **Step 2–4:** FAIL → implement → PASS; `scripts/build-app.sh` → exit 0.
- [ ] **Step 5: Commit** — `git commit -m "Link calendar events with Telemost, mail and contacts"`

### Task 9: Синтетический QA

**Files:**
- Create: `Sources/MakoshCalendar/CalendarQAIsolation.swift` (образец `TasksQAIsolation`: флаг `--calendar-synthetic-preview`, префикс `qa_calendar_`, только loopback), `Sources/MakoshCalendar/CalendarSyntheticSeed.swift`, `Sources/MakoshApp/Calendar/CalendarSyntheticPreview.swift`, `scripts/run-calendar-qa.py` (образец `scripts/run-tasks-qa.py`: `org.makosh.calendar.qa`, `MakoshCalendarQA.app`, «Макош · Календарь QA», `MakoshSyntheticService = "calendar"`), `scripts/test-calendar-qa.py`
- Modify: `Sources/MakoshApp/MakoshApp.swift` (ветки QA, исключение регистрации системного делегата и `permitsOrdinaryReleaseLaunch`), `scripts/test.sh` (`python3 scripts/test-calendar-qa.py`)
- Test: `Tests/MakoshCalendarTests/CalendarQAIsolationTests.swift`, `Tests/MakoshCalendarTests/CalendarSyntheticSeedTests.swift`

Сид (фиксированные id, повторный сид ничего не меняет): локальный «Личный (Makosh)»; синтетический Google «Личный» и «Работа A» (две учётные записи, рабочий день 9–15); синтетический CalDAV «Работа B» (Яндекс, рабочий день 15–18, `schedules: false`); подписка «Праздники» из встроенной ICS-строки; одна группа «Все» из четырёх записываемых календарей; «Стоматолог» в личном Google, «Созвон A» в работе A, «Telemost · B» со ссылкой в работе B, «Планёрка» по будням, приглашение без ответа, внешний созвон поверх плашки в работе A, `failNext(.unknownOutcome)` на первой записи в работу B, задачи для правой колонки через синтетическую ленту.

- [ ] **Step 1: Tests** `testIsolationRequiresFlagLoopbackAndPrefix`, `testSeedIsIdempotent`, `testSeedProducesBusyCopiesInBothWorkCalendars`; в `scripts/test-calendar-qa.py` — `test_qa_info_rewrites_identity`, `test_schema_prefix`, `test_refuses_remote_host`, `test_refuses_private_resources`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** `scripts/build-app.sh && python3 scripts/run-calendar-qa.py --launch` — окно QA запускается; осмотр экрана — пользователем.
- [ ] **Step 6: Commit** — `git commit -m "Add the isolated calendar QA bundle"`

### Task 10: Документация и полные проверки

**Files:**
- Create: `docs/calendar.md`
- Modify: `docs/architecture.md` (ADR-019: календарь — модуль, хранилище, занятость, Google REST + CalDAV, общий вход Google, фон), `AGENTS.md` (раздел «Calendar decisions»: группы и плашки, только «Занято», откат чужих правок, попытки, QA `qa_calendar_`, живые аккаунты только по команде, клиент Google только из приватного входа), `docs/development-status.md` (реальные результаты проверок, неподтверждённое: живой Google, CalDAV-рассылка Яндекса и iCloud, осмотр экрана), `docs/reference-interface.md`, `docs/tasks.md` (планер на событиях календаря, перенос слотов), `docs/xerj.md` (если индексировались новые пути)

- [ ] **Step 1:** Написать документы по фактическому коду.
- [ ] **Step 2:** `scripts/dev-db.sh up`, `scripts/test.sh` → exit 0 (записать число тестов по бандлам), `scripts/build-app.sh` → exit 0, `scripts/format.sh HEAD`.
- [ ] **Step 3:** Независимый обзор ветки свежей моделью (`superpowers:requesting-code-review`), находки — тестами RED→GREEN, мелочи — в `docs/calendar.md` «Отложенные мелочи обзора».
- [ ] **Step 4: Commit** — `git commit -m "Document the calendar section and record its checks"`
