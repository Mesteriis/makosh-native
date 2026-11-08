# Календарь, план 1: ядро (модель, iCalendar, повторы, занятость, хранилище) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Модуль `MakoshCalendar` с моделью календарей, разбором и сборкой iCalendar, раскрытием повторов, движком плашек «Занято», поиском конфликтов, PostgreSQL-хранилищем и журналом попыток — всё без сети.

**Architecture:** Чистые типы-значения и чистые функции (повторы, занятость, конфликты) поверх актора `CalendarStore` с таблицами `calendar_*` в схеме приложения. Приватные поля событий (описание, место, участники, организатор, ссылка) шифруются AES-GCM ключом архивного хранилища, как в Telemost. Внешних зависимостей нет.

**Tech Stack:** Swift 6 strict concurrency, Foundation, CryptoKit, `MakoshCore.PostgresConnection`, XCTest на реальном PostgreSQL.

**Spec:** `docs/superpowers/specs/2026-11-08-calendar-design.md`

Планы 2 (`2026-11-08-calendar-2-sync.md`) и 3 (`2026-11-08-calendar-3-interface.md`) строятся на интерфейсах этого плана.

## Global Constraints

- macOS 26+, Apple Silicon, Swift 6 strict concurrency; `swift-tools-version: 6.2`.
- Таблицы — в схеме приложения с префиксом `calendar_`; схема проверяется `PostgresConnection.isValidSchemaName`.
- Наблюдения внешних событий и версии локальных — append-only; удаление у источника помечает событие, не стирает его и историю.
- Плашка показывает наружу только «Занято», начало и конец; статус «занят»; ни названия, ни описания, ни места, ни участников.
- Плашка никогда не становится источником занятости (ни своей, ни чужой установки Makosh).
- Окно плашек — от «сейчас» до 90 дней вперёд, по вхождениям, не серией; прошедшие плашки не трогаются.
- Занятость дают: оригинал, не `free`, не `cancelled`, не отклонённый пользователем; неотвеченное приглашение и «возможно» — дают.
- Попытки: `queued → sent → confirmed | rejected | unknown`; `unknown` не повторяется сам; после перезапуска `sent → unknown`; одна открытая попытка на (событие, календарь, вид).
- Секреты — только в общем Keychain-элементе через `MakoshSecretStore`; ключ шифрования — `MessageArchiveKeychain.open`.
- UI и документация — по-русски; код, имена файлов и типов — по-английски.
- Swift-тип `Calendar` не переопределять: доменные типы называются `CalendarAccount`, `CalendarCollection`, `CalendarEvent`, `CalendarGroup`.
- Форматировать только изменённые файлы: `scripts/format.sh HEAD`.
- Коммиты заканчиваются строкой `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Переход на летнее время внутри серии** — еженедельное событие 10:00 Europe/Berlin остаётся 10:00 местного времени после перевода часов, а не сдвигается на час. Тест в задаче 3.
2. **Событие на весь день у получателя в другом часовом поясе** — плашка весь день ставится датами, не моментами UTC, и не «съезжает» на соседний день. Тест в задаче 5.
3. **Оригинал перекрывает границу окна 90 дней** — вхождение, начавшееся до конца окна, получает плашку целиком; вхождение после окна — нет. Тест в задаче 5.
4. **Два календаря в двух разных группах** — личный в группах {A} и {B}: событие в A даёт плашку в личном, но не в B. Тест в задаче 5.
5. **Перезапуск посреди отправки** — попытка в `sent` после `CalendarStore.open()` становится `unknown` и не исчезает. Тест в задаче 8.

---

### Task 1: Модуль и доменная модель

**Files:**
- Modify: `Package.swift` (продукт `MakoshCalendar`, цель `MakoshCalendar` с зависимостями `MakoshCore`, `CPostgres`; тестовая цель `MakoshCalendarTests` с `MakoshCalendar`, `MakoshCore`, `CPostgres`)
- Create: `Sources/MakoshCalendar/CalendarModels.swift`
- Test: `Tests/MakoshCalendarTests/CalendarModelsTests.swift`

**Interfaces:**
- Produces:
  - `public enum CalendarAccountKind: String, Codable, Sendable { case local, google, caldav, subscription }`
  - `public struct CalendarWorkingHours: Codable, Equatable, Sendable { public var days: [Int: [ClosedRange<Int>]] }` — ключ — день недели 1…7 (1 = понедельник), значения — минуты от полуночи; `func contains(weekday: Int, minute: Int) -> Bool`.
  - `public struct CalendarAccount: Codable, Equatable, Identifiable, Sendable { id: UUID; kind; name: String; workingHours: CalendarWorkingHours; googleGrantID: String?; caldavServer: URL?; caldavLogin: String?; subscriptionURL: URL?; serverSchedules: Bool?; state: CalendarAccountState; lastError: CalendarFailure? }`
  - `public enum CalendarAccountState: String, Codable, Sendable { case connected, needsSignIn, adminBlocked, unreachable, disabled }`
  - `public struct CalendarCollection: Codable, Equatable, Identifiable, Sendable { id: UUID; accountID: UUID; externalID: String; name: String; color: String; access: CalendarAccess; shown: Bool; defaultReminderMinutes: Int; groupIDs: Set<UUID> }`, `public enum CalendarAccess: String, Codable, Sendable { case read, write }`
  - `public struct CalendarGroup: Codable, Equatable, Identifiable, Sendable { id: UUID; name: String }`
  - `public enum CalendarTransparency: String, Codable, Sendable { case busy, free }`, `public enum CalendarEventStatus: String, Codable, Sendable { case confirmed, tentative, cancelled }`, `public enum CalendarResponse: String, Codable, Sendable { case needsAction, accepted, tentative, declined }`
  - `public struct CalendarAttendee: Codable, Equatable, Sendable { email: String; name: String?; response: CalendarResponse; isSelf: Bool; isOrganizer: Bool }`
  - `public struct CalendarRecurrence: Codable, Equatable, Sendable { rrule: String; exdates: [Date] }`
  - `public enum CalendarEventTime: Codable, Equatable, Sendable { case timed(start: Date, end: Date, timeZone: String?), allDay(start: CalendarDay, endExclusive: CalendarDay) }`, где `public struct CalendarDay: Codable, Hashable, Comparable, Sendable { year: Int; month: Int; day: Int }`.
  - `public struct CalendarBusyMarker: Codable, Equatable, Sendable { sourceEventID: UUID; occurrenceStart: Date }` — метка плашки Makosh.
  - `public struct CalendarEvent: Codable, Equatable, Identifiable, Sendable { id: UUID; collectionID: UUID; externalID: String?; uid: String; title: String; notes: String; location: String; time: CalendarEventTime; recurrence: CalendarRecurrence?; recurrenceID: Date?; masterID: UUID?; attendees: [CalendarAttendee]; organizerEmail: String?; reminders: [Int]; meetingURL: URL?; transparency; status; taskID: UUID?; busyMarker: CalendarBusyMarker?; etag: String?; revision: Int64; updatedAt: Date; deletedAt: Date? }` и вычисляемые `isBusyCopy: Bool`, `selfResponse: CalendarResponse?`, `givesBusy: Bool`.
  - `public enum CalendarFailure: Error, Codable, Equatable, Sendable { case invalidSchema, notOpen, notFound, staleRevision, keyUnavailable, storage(String?), invalidInput(String), rejected(code: Int, stage: String), unknownOutcome(stage: String), signInRequired, adminBlocked, unreachable }` — без тел ответов, URL и токенов.

- [ ] **Step 1: Write the failing tests**

```swift
func testGivesBusyFollowsTransparencyStatusResponseAndCopy() {
    var event = CalendarEvent.fixture(start: 10, end: 11)
    XCTAssertTrue(event.givesBusy)
    event.transparency = .free; XCTAssertFalse(event.givesBusy); event.transparency = .busy
    event.status = .cancelled; XCTAssertFalse(event.givesBusy); event.status = .tentative; XCTAssertTrue(event.givesBusy)
    event.attendees = [.init(email: "me@x", name: nil, response: .declined, isSelf: true, isOrganizer: false)]
    XCTAssertFalse(event.givesBusy)
    event.attendees[0].response = .needsAction; XCTAssertTrue(event.givesBusy)
    event.busyMarker = .init(sourceEventID: UUID(), occurrenceStart: Date()); XCTAssertFalse(event.givesBusy)
}
func testWorkingHoursContains() {
    let hours = CalendarWorkingHours(days: [1: [540...900]])
    XCTAssertTrue(hours.contains(weekday: 1, minute: 600)); XCTAssertFalse(hours.contains(weekday: 2, minute: 600))
    XCTAssertFalse(hours.contains(weekday: 1, minute: 901))
}
func testEventRoundTripsThroughJSON() throws { /* encode/decode fixture with allDay and timed times; XCTAssertEqual */ }
func testCalendarDayOrdering() { XCTAssertLessThan(CalendarDay(year: 2026, month: 11, day: 8), CalendarDay(year: 2026, month: 11, day: 9)) }
```

`CalendarEvent.fixture(start:end:)` — помощник в `Tests/MakoshCalendarTests/CalendarFixtures.swift` (часы сегодня по UTC, коллекция `UUID()`).

- [ ] **Step 2: Run to verify failure** — `scripts/test.sh --filter MakoshCalendarTests.CalendarModelsTests` → ошибка компиляции (типов нет).
- [ ] **Step 3: Implement** `CalendarModels.swift` с перечисленными типами; `givesBusy = busyMarker == nil && transparency == .busy && status != .cancelled && selfResponse != .declined && deletedAt == nil`.
- [ ] **Step 4: Run** — те же тесты PASS.
- [ ] **Step 5: Commit** — `git add Package.swift Sources/MakoshCalendar Tests/MakoshCalendarTests && git commit -m "Add the calendar module and domain model"`

### Task 2: iCalendar — разбор и сборка

**Files:**
- Create: `Sources/MakoshCalendar/ICalendar.swift`
- Test: `Tests/MakoshCalendarTests/ICalendarTests.swift`

**Interfaces:**
- Produces:
  - `public enum ICalendar { public static func parse(_ text: String, collectionID: UUID) throws -> [CalendarEvent]; public static func serialize(_ event: CalendarEvent, overrides: [CalendarEvent] = []) -> String; public static func serializeBusyCopy(uid: String, time: CalendarEventTime, marker: CalendarBusyMarker) -> String }`
  - Свойства Makosh: `X-MAKOSH-BUSY:<sourceEventID>;<occurrenceStart ISO8601 UTC>`, `X-MAKOSH-TASK:<taskID>`.

Решения: развёртка строк (RFC 5545 §3.1), экранирование `\, \; \n`, параметры `TZID`, `VALUE=DATE`; `TZID` — имя IANA (`TimeZone(identifier:)`), неизвестное имя → UTC; `DTEND` отсутствует → `DURATION`, иначе 1 час (весь день — 1 день); `RRULE`, `EXDATE` (несколько строк и списки через запятую), `RECURRENCE-ID` (вхождение-исключение — отдельное `CalendarEvent` с `recurrenceID` и тем же `uid`), `ATTENDEE` с `PARTSTAT`/`CN`, `ORGANIZER`, `TRANSP`, `STATUS`, `VALARM` с `TRIGGER:-PT<n>M` (минуты), ссылка встречи — `URL` или первая ссылка `https://telemost.yandex.ru/…`/`https://telemost.360.yandex.ru/…` в `LOCATION`/`DESCRIPTION`. Сборка плашки: `SUMMARY:Занято`, `TRANSP:OPAQUE`, `CLASS:PRIVATE`, без `DESCRIPTION`, `LOCATION`, `ATTENDEE`, `VALARM`.

- [ ] **Step 1: Write the failing tests**

```swift
func testParsesFoldedTimedEventWithTZIDAttendeesAndAlarm() throws {
    let events = try ICalendar.parse(Fixture.ics("timed-berlin"), collectionID: id)
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events[0].title, "Созвон, по плану; ок")
    guard case .timed(let start, let end, let zone) = events[0].time else { return XCTFail() }
    XCTAssertEqual(zone, "Europe/Berlin"); XCTAssertEqual(end.timeIntervalSince(start), 1800)
    XCTAssertEqual(events[0].attendees.map(\.response), [.accepted, .needsAction])
    XCTAssertEqual(events[0].reminders, [15])
}
func testParsesAllDayAndDefaultsMissingEnd() throws { /* VALUE=DATE без DTEND → endExclusive = следующий день */ }
func testOverrideBecomesSeparateEventWithRecurrenceID() throws { /* мастер с RRULE + VEVENT с RECURRENCE-ID → 2 события, у второго recurrenceID != nil, тот же uid */ }
func testExdateListAndRepeatedLines() throws { /* две строки EXDATE, одна со списком из двух → 3 даты */ }
func testFindsTelemostLinkInDescription() throws { XCTAssertEqual(events[0].meetingURL?.host, "telemost.yandex.ru") }
func testBusyCopyCarriesOnlyBusyFields() {
    let text = ICalendar.serializeBusyCopy(uid: "u1", time: .timed(start: a, end: b, timeZone: nil), marker: marker)
    XCTAssertTrue(text.contains("SUMMARY:Занято")); XCTAssertTrue(text.contains("TRANSP:OPAQUE"))
    for forbidden in ["DESCRIPTION", "LOCATION", "ATTENDEE", "VALARM"] { XCTAssertFalse(text.contains(forbidden)) }
    XCTAssertEqual(try ICalendar.parse(text, collectionID: id).first?.busyMarker, marker)
}
func testSerializeRoundTripsEvent() throws { /* serialize → parse → те же title/time/recurrence/attendees/reminders/taskID */ }
```

Фикстуры — строки в `Tests/MakoshCalendarTests/ICalendarFixtures.swift` (не файлы ресурсов).

- [ ] **Step 2: Run** — `scripts/test.sh --filter MakoshCalendarTests.ICalendarTests` → FAIL.
- [ ] **Step 3: Implement** `ICalendar` по решениям выше.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Parse and write iCalendar events and busy copies"`

### Task 3: Раскрытие повторов

**Files:**
- Create: `Sources/MakoshCalendar/CalendarRecurrenceExpander.swift`
- Test: `Tests/MakoshCalendarTests/CalendarRecurrenceExpanderTests.swift`

**Interfaces:**
- Produces:
  - `public struct CalendarOccurrence: Equatable, Sendable { public let eventID: UUID; public let collectionID: UUID; public let time: CalendarEventTime; public let key: Date; public var start: Date { get }; public var end: Date { get } }` — `key` — начало вхождения по серии до переопределений; для весь день `start`/`end` — полночь в `TimeZone.current`.
  - `public enum CalendarRecurrenceExpander { public static func occurrences(of master: CalendarEvent, overrides: [CalendarEvent], in window: DateInterval) -> [CalendarOccurrence] }` — для события без повтора — одно вхождение, если пересекает окно.

Поддержка: `FREQ=DAILY|WEEKLY|MONTHLY|YEARLY`, `INTERVAL`, `COUNT`, `UNTIL`, `BYDAY` (с номером для `MONTHLY`/`YEARLY`, например `-1FR`), `BYMONTHDAY`, `BYMONTH`, `WKST` (по умолчанию `MO`); `EXDATE` и вхождения, переопределённые `overrides` (отменённое переопределение не даёт вхождения; сдвинутое даёт своё время с прежним `key`). Арифметика — в часовом поясе события (`Calendar(identifier: .gregorian)` с `timeZone`), чтобы местное время сохранялось через смену летнего времени. Предохранитель — не больше 5000 вхождений на серию за вызов. Неподдерживаемое правило (`BYSETPOS`, `BYWEEKNO`, `BYYEARDAY`, частоты меньше дня) → только первое вхождение и флаг `CalendarRecurrenceExpander.unsupported(rrule:) -> Bool` для показа в карточке.

- [ ] **Step 1: Write the failing tests**

```swift
func testWeeklyKeepsLocalTimeAcrossDST() {
    // Берлин: 2026-10-25 переход на зимнее время. Серия по понедельникам 10:00 с 2026-10-19.
    let occ = CalendarRecurrenceExpander.occurrences(of: weekly(berlin, "FREQ=WEEKLY;BYDAY=MO"), overrides: [], in: oct19toNov10)
    XCTAssertEqual(occ.map { berlinHour($0.start) }, [10, 10, 10, 10])
}
func testCountUntilInterval() { /* FREQ=DAILY;INTERVAL=2;COUNT=3 → 3; UNTIL включительно */ }
func testMonthlyLastFriday() { /* FREQ=MONTHLY;BYDAY=-1FR → 2026-11-27, 2026-12-25 */ }
func testExdateAndOverridesReplaceOccurrences() { /* EXDATE убирает; сдвинутое переопределение даёт новое время с тем же key; cancelled-переопределение убирает */ }
func testAllDayYearly() { /* весь день, FREQ=YEARLY → CalendarDay без сдвига */ }
func testUnsupportedRuleYieldsFirstOnly() { XCTAssertEqual(occ.count, 1); XCTAssertTrue(CalendarRecurrenceExpander.unsupported(rrule: "FREQ=MONTHLY;BYSETPOS=-1;BYDAY=MO,TU")) }
func testSafetyCap() { /* FREQ=DAILY без конца в окне 20 лет → 5000 */ }
```

- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Expand recurring calendar events in the event's time zone"`

### Task 4: Конфликты и свободное время

**Files:**
- Create: `Sources/MakoshCalendar/CalendarConflicts.swift`
- Test: `Tests/MakoshCalendarTests/CalendarConflictsTests.swift`

**Interfaces:**
- Consumes: `CalendarOccurrence`, `CalendarCollection`, `CalendarEvent`.
- Produces:
  - `public enum CalendarNeighbours { public static func of(_ collectionID: UUID, in collections: [CalendarCollection]) -> Set<UUID> }` — календари с хотя бы одной общей группой, без самого календаря.
  - `public struct CalendarConflict: Equatable, Identifiable, Sendable { id: String /* eventID+key */; eventID: UUID; collectionID: UUID; start: Date; end: Date; isBusyCopy: Bool; isInvitation: Bool /* у события есть self-участник не организатор */ }`
  - `public enum CalendarConflictFinder { public static func conflicts(start: Date, end: Date, collectionID: UUID, excluding eventID: UUID?, occurrences: [CalendarOccurrence], events: [UUID: CalendarEvent], collections: [CalendarCollection]) -> [CalendarConflict]; public static func nearestFree(length: TimeInterval, after: Date, collectionID: UUID, occurrences: [CalendarOccurrence], events: [UUID: CalendarEvent], collections: [CalendarCollection], step: TimeInterval = 900, horizon: TimeInterval = 7 * 86400) -> Date? }`

Правило: проверяются вхождения выбранного календаря и всех соседей (оригиналы и плашки — то есть фактическая занятость), только те, у которых `givesBusy` или `isBusyCopy`; касание границ (конец = начало) — не конфликт; вхождение того же события (`excluding`) пропускается.

- [ ] **Step 1: Write the failing tests**

```swift
func testNeighboursShareAnyGroup() { /* личный {A,B}, работаA {A}, работаB {B}, праздники {} → соседи личного = {A-кал, B-кал}; соседи работыA = {личный} */ }
func testOverlapInNeighbourIsConflictButTouchingIsNot() { /* 10–11 vs 11–12 → []; 10–11 vs 10:30–11:30 → 1 */ }
func testFreeAndDeclinedDoNotConflict() { }
func testConflictMarksInvitation() { XCTAssertTrue(result[0].isInvitation) }
func testNearestFreeSkipsBusy() { /* занято 10–12 и 12:15–13 → свободный час после 10:00 = 13:00 */ }
```

- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Find calendar conflicts across busy groups"`

### Task 5: Движок плашек

**Files:**
- Create: `Sources/MakoshCalendar/BusyEngine.swift`
- Test: `Tests/MakoshCalendarTests/BusyEngineTests.swift`

**Interfaces:**
- Consumes: `CalendarNeighbours.of`, `CalendarRecurrenceExpander.occurrences`.
- Produces:
  - `public struct DesiredBusyCopy: Hashable, Sendable { sourceEventID: UUID; occurrenceKey: Date; targetCollectionID: UUID; time: CalendarEventTime }`
  - `public struct BusyCopyRecord: Codable, Equatable, Identifiable, Sendable { id: UUID; sourceEventID: UUID; occurrenceKey: Date; targetCollectionID: UUID; externalID: String?; etag: String?; time: CalendarEventTime; state: BusyCopyState }`, `public enum BusyCopyState: String, Codable, Sendable { case pending, placed, removing, orphaned }` (`orphaned` — получатель недоступен, плашку убрать нельзя).
  - `public struct ObservedBusyCopy: Equatable, Sendable { externalID: String; marker: CalendarBusyMarker; time: CalendarEventTime; collectionID: UUID }` — плашка, прочитанная с сервера.
  - `public enum BusyAction: Equatable, Sendable { case create(DesiredBusyCopy), move(record: BusyCopyRecord, to: CalendarEventTime), remove(BusyCopyRecord), adopt(record: DesiredBusyCopy, observed: ObservedBusyCopy), deleteStray(ObservedBusyCopy) }`
  - `public enum BusyEngine { public static let horizon: TimeInterval = 90 * 86400; public static func desired(events: [CalendarEvent], collections: [CalendarCollection], now: Date) -> Set<DesiredBusyCopy>; public static func reconcile(desired: Set<DesiredBusyCopy>, records: [BusyCopyRecord], observed: [ObservedBusyCopy], now: Date) -> [BusyAction] }`

Правила `desired`: источник — коллекция, которая читается (любой доступ, включая подписку); получатель — сосед с `access == .write`, не сам источник; только события с `givesBusy`; вхождения, пересекающие окно `[now, now + horizon]`; плашка весь день копирует `CalendarDay` без перевода в моменты. Правила `reconcile` (наблюдённые сопоставляются с записями по `externalID`, с желаемым — по метке):
1. Запись без желаемого → `remove`, если её `end > now`; прошедшие не трогаются.
2. Желаемое без записи: есть наблюдённая плашка с той же меткой (осталась после `unknown`) → `adopt`; нет → `create`.
3. Запись с желаемым: наблюдённая плашка на сервере отсутствует, а `state == .placed` → `create` (плашку удалили вручную); наблюдённое время ≠ желаемого или запись не совпадает с желаемым временем → `move`.
4. Наблюдённая плашка, которой нет ни в записях, ни в желаемом → `deleteStray`; несколько наблюдённых с одной меткой → одна сопоставляется, остальные `deleteStray`.

- [ ] **Step 1: Write the failing tests**

```swift
func testOriginalReplicatesToEveryWritableNeighbourButNotItself() {
    // личный, A, B, подписка — одна группа; подписка read
    let d = BusyEngine.desired(events: [dentist(in: personal)], collections: all, now: now)
    XCTAssertEqual(Set(d.map(\.targetCollectionID)), [workA.id, workB.id])
}
func testBusyCopiesAreNeverSources() { /* событие с busyMarker в A → desired пуст */ }
func testTwoGroupsDoNotLeakAcross() { /* личный {G1,G2}, A {G1}, B {G2}; событие в A → только личный */ }
func testSubscriptionIsSourceNotTarget() { }
func testRecurringWithinHorizonOnly() { /* ежедневно → 90 или 91 вхождение, ни одного после now+90д; вхождение, начавшееся до границы и пересекающее её, — есть */ }
func testAllDayCopyKeepsDays() { guard case .allDay(let s, _) = copy.time else { return XCTFail() }; XCTAssertEqual(s, CalendarDay(year: 2026, month: 11, day: 20)) }
func testReconcileCreatesMovesRemovesAndLeavesPast() { }
func testReconcileRestoresTamperedCopy() { /* наблюдённое время ≠ записи → move; наблюдённой нет → create */ }
func testReconcileAdoptsCopyFoundAfterUnknown() { }
func testReconcileDeletesStraysAndDuplicates() { }
```

- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Compute and reconcile busy copies for calendar groups"`

### Task 6: Хранилище — схема, учётные записи, календари, группы

**Files:**
- Create: `Sources/MakoshCalendar/CalendarStoreSchema.swift`, `Sources/MakoshCalendar/CalendarStore.swift`
- Test: `Tests/MakoshCalendarTests/CalendarStoreTests.swift`, `Tests/MakoshCalendarTests/CalendarTestSupport.swift` (копия образца `Tests/MakoshTasksTests/TasksTestSupport.swift`: схема `makosh_test_<uuid>`, `calendarStore(_:)` с ключом в памяти)

**Interfaces:**
- Produces:
  - `public actor CalendarStore { public init(connectionString: String, schema: String, keyProvider: @escaping @Sendable (UUID, Bool) throws -> Data = MessageArchiveKeychain.open, now: @escaping @Sendable () -> Date = Date.init); public func open() throws; public func close() }`
  - Учётные записи: `accounts() throws -> [CalendarAccount]`, `saveAccount(_:) throws`, `removeAccount(id:) throws` (помечает `disabled`, календари скрывает; события остаются).
  - Календари: `collections() throws -> [CalendarCollection]`, `saveCollection(_:) throws`.
  - Группы: `groups() throws -> [CalendarGroup]`, `saveGroup(_:) throws`, `removeGroup(id:) throws` (снимает id группы со всех календарей в той же транзакции).
  - `localAccount() throws -> (CalendarAccount, CalendarCollection)` — создаёт при первом вызове одну учётную запись `local` «Makosh» и календарь «Личный» (`access: .write`).
  - `performInTransaction<T: Sendable>(_ body: @Sendable (isolated CalendarStore) throws -> T) throws -> T` — как в `TaskStore`.

Таблицы (`CalendarStoreSchema.statements(schema:)`): `calendar_metadata(id=1, version, vault UUID)`, `calendar_accounts(id, data JSONB)`, `calendar_collections(id, account_id, data JSONB)`, `calendar_groups(id, data JSONB)`, `calendar_events(id UUID PK, collection_id, uid, external_id, master_id, recurrence_id TIMESTAMPTZ, starts_at, ends_at, busy_source UUID, task_id UUID, deleted_at, revision, data JSONB, sealed TEXT)`, `calendar_event_versions(seq BIGSERIAL, event_id, revision, actor, data JSONB, sealed TEXT, at)`, `calendar_cursors(collection_id PK, data JSONB)`, `calendar_busy_copies(id PK, source_event_id, occurrence_key, target_collection_id, data JSONB, UNIQUE(source_event_id, occurrence_key, target_collection_id))`, `calendar_attempts(id PK, event_id, collection_id, kind, state, data JSONB, created_at, updated_at, resolved_at)`, `calendar_preferences(id=1, data JSONB)`; индексы по `(collection_id, starts_at)`, `(event_id, seq)`, `(event_id, created_at)`. Открытие под `pg_advisory_xact_lock(hashtext('makosh-calendar-schema'), hashtext(schema))`; `vault` создаётся, только если таблицы событий пусты (иначе `keyUnavailable`), как в `TelemostPostgres.open`.

- [ ] **Step 1: Write the failing tests**

```swift
func testOpenCreatesLocalCalendarOnce() async throws {
    let store = try await calendarStore(try calendarDatabase())
    let first = try await store.localAccount(), second = try await store.localAccount()
    XCTAssertEqual(first.1.id, second.1.id); XCTAssertEqual(first.1.access, .write); XCTAssertEqual(first.0.kind, .local)
}
func testRemovingGroupDetachesCollections() async throws { }
func testRemoveAccountKeepsEvents() async throws { }
func testReopenWithMissingKeyFailsClosed() async throws { /* keyProvider бросает → open() бросает keyUnavailable, данные не тронуты */ }
func testInvalidSchemaRejected() async throws { }
```

- [ ] **Step 2–4:** FAIL → implement → PASS (интеграционные — на реальном PostgreSQL: `scripts/dev-db.sh up` до запуска).
- [ ] **Step 5: Commit** — `git commit -m "Store calendar accounts, collections and groups in PostgreSQL"`

### Task 7: Хранилище — события, версии, наблюдения, шифрование

**Files:**
- Modify: `Sources/MakoshCalendar/CalendarStore.swift`
- Create: `Sources/MakoshCalendar/CalendarStore+Events.swift`
- Test: `Tests/MakoshCalendarTests/CalendarStoreEventsTests.swift`

**Interfaces:**
- Produces:
  - `public enum CalendarActor: String, Codable, Sendable { case user, remote, engine }`
  - `insert(_ event: CalendarEvent, actor: CalendarActor) throws -> CalendarEvent` (revision 1, версия), `update(_ event: CalendarEvent, expectedRevision: Int64, actor:) throws -> CalendarEvent` (`staleRevision` при несовпадении), `markDeleted(id:expectedRevision:actor:) throws`
  - `observe(_ remote: CalendarEvent, collectionID: UUID) throws -> CalendarEvent` — вставка или обновление по `(collection_id, external_id)`, всегда версия с `actor: .remote`; локальные поля (`taskID`) сохраняются.
  - `observeRemoval(externalID: String, collectionID: UUID) throws` — `deleted_at`, версия.
  - `event(id:) throws -> CalendarEvent?`, `events(collectionIDs: Set<UUID>, from: Date, to: Date, includeCopies: Bool) throws -> [CalendarEvent]` — мастеры повторов отдаются всегда (их раскрывает вызывающий), разовые — по пересечению интервала.
  - `versions(eventID:) throws -> [CalendarEventVersion]` (`revision`, `actor`, `event`, `at`).
  - Курсоры: `cursor(collectionID:) throws -> Data?`, `saveCursor(_ data: Data?, collectionID:) throws`.

Поля `notes`, `location`, `attendees`, `organizerEmail`, `meetingURL` пишутся в `sealed` (AES-GCM, ключ из `keyProvider(vault, allowCreation)`, привязка к `vault + event id`), в `data` — пустые значения. Ограничение размера записи — 1 MiB, превышение → `invalidInput("event too large")`.

- [ ] **Step 1: Write the failing tests**

```swift
func testInsertUpdateKeepsAppendOnlyVersions() async throws { /* insert → update → versions.count == 2, revisions [1,2] */ }
func testStaleRevisionRefused() async throws { }
func testObserveUpsertsByExternalIDAndKeepsTaskLink() async throws { }
func testObserveRemovalMarksButKeepsHistory() async throws { /* event(id:).deletedAt != nil; versions сохранены */ }
func testPrivateFieldsAreNotStoredInClear() async throws {
    _ = try await store.insert(eventWith(notes: "секрет-описание", location: "Клиника"), actor: .user)
    let raw = try db.execute("SELECT data::text || coalesce(sealed,'') FROM \"\(db.schema)\".calendar_events")
    XCTAssertFalse(raw[0][0].contains("секрет-описание")); XCTAssertFalse(raw[0][0].contains("Клиника"))
    XCTAssertEqual(try await store.event(id: id)?.notes, "секрет-описание")
}
func testEventsWindowReturnsMastersAndOverlaps() async throws { }
```

- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Store calendar events with versions, observations and sealed fields"`

### Task 8: Плашки и журнал попыток в хранилище

**Files:**
- Create: `Sources/MakoshCalendar/CalendarAttempt.swift`, `Sources/MakoshCalendar/CalendarStore+Busy.swift`
- Test: `Tests/MakoshCalendarTests/CalendarAttemptJournalTests.swift`

**Interfaces:**
- Produces:
  - `public enum CalendarAttemptKind: String, Codable, Sendable { case createEvent, updateEvent, deleteEvent, respond, createCopy, moveCopy, deleteCopy }`
  - `public enum CalendarAttemptState: String, Codable, Sendable { case queued, sent, confirmed, rejected, unknown }`
  - `public struct CalendarAttempt: Codable, Equatable, Identifiable, Sendable { id: UUID; eventID: UUID?; copyID: UUID?; collectionID: UUID; kind; state; payload: Data /* значение для повтора сверки, без секретов */; failure: CalendarFailure?; createdAt: Date; updatedAt: Date; resolvedAt: Date? }`
  - В `CalendarStore`: `busyCopies(targetCollectionID: UUID?) throws -> [BusyCopyRecord]`, `saveBusyCopy(_:) throws`, `removeBusyCopy(id:) throws`; `beginAttempt(kind:eventID:copyID:collectionID:payload:) throws -> CalendarAttempt` (бросает `CalendarFailure.invalidInput("attempt open")`, если открыта попытка того же вида для того же события/плашки и календаря), `markSent(_ id: UUID) throws`, `settle(_ id: UUID, state: CalendarAttemptState, failure: CalendarFailure?) throws` (разрешены только `queued|sent → confirmed|rejected|unknown`, `unknown → confirmed|rejected`), `openAttempts() throws -> [CalendarAttempt]`, `attempts(eventID:) throws -> [CalendarAttempt]`.
  - `open()` переводит все `sent` в `unknown` с `failure: .unknownOutcome(stage: "restart")`.

- [ ] **Step 1: Write the failing tests**

```swift
func testLifecycleAndForbiddenTransitions() async throws { /* queued→sent→confirmed ок; confirmed→unknown бросает; unknown→rejected ок */ }
func testOneOpenAttemptPerKindEventAndCalendar() async throws { }
func testSentBecomesUnknownAfterReopen() async throws {
    let a = try await store.beginAttempt(kind: .createEvent, eventID: e, copyID: nil, collectionID: c, payload: Data())
    try await store.markSent(a.id); await store.close()
    let reopened = try await calendarStore(db)
    XCTAssertEqual(try await reopened.openAttempts().first?.state, .unknown)
}
func testBusyCopyUniquePerSourceOccurrenceTarget() async throws { }
```

- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Journal calendar write attempts and track busy copies"`

### Task 9: Предпочтения раздела и проверка плана

**Files:**
- Create: `Sources/MakoshCalendar/CalendarPreferences.swift`
- Test: `Tests/MakoshCalendarTests/CalendarPreferencesTests.swift`

**Interfaces:**
- Produces: `public struct CalendarPreferences: Codable, Equatable, Sendable { var view: CalendarViewMode = .week; var showTasks = true; var lastCollectionID: UUID?; var horizonDays = 90; var pollSeconds = 120; var subscriptionPollSeconds = 3600; var defaultReminderMinutes = 10; var maxWritesPerPass = 50; var firstWeekday = 2 }`, `public enum CalendarViewMode: String, Codable, Sendable { case day, week, month }`; в `CalendarStore` — `preferences() throws -> CalendarPreferences` (по умолчанию при отсутствии строки; неизвестные ключи игнорируются при чтении), `savePreferences(_:) throws`.

- [ ] **Step 1: Test** `testDefaultsAndRoundTrip`, `testUnknownKeysAreTolerated` (JSON с лишним полем читается).
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Полная проверка плана** — `scripts/dev-db.sh up && scripts/test.sh --filter MakoshCalendarTests` → все PASS; `scripts/format.sh HEAD`.
- [ ] **Step 6: Commit** — `git commit -m "Persist calendar section preferences"`
