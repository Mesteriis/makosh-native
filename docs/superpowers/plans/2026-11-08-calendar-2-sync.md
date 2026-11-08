# Календарь, план 2: Google, CalDAV, подписки и сервис обхода Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Адаптеры Google Calendar API v3 (OAuth для настольного приложения), CalDAV и подписок по ссылке, синтетический адаптер, встроенный OAuth-клиент Google из приватного входа сборки и актор `CalendarService`, который обходит календари, ставит и откатывает плашки через журнал попыток, проверяет конфликты и выдаёт снимок для интерфейса.

**Architecture:** Один протокол `CalendarAdapter` за тремя реальными адаптерами и синтетическим. Транспорт — собственный `URLSession` без кеша и cookies, подменяемый `URLProtocol` в тестах. `CalendarService` — актор: обход по учётной записи, сверка плашек `BusyEngine` с лимитом записей за проход, команды пользователя с конфликтами и попытками. Сеть не трогается без явного действия пользователя (подключение, обход подключённой учётной записи).

**Tech Stack:** Swift 6, Foundation `URLSession`, `Network` (`NWListener` для loopback), CryptoKit (PKCE S256), `AppKit.NSWorkspace` только в приложении (открытие браузера передаётся замыканием), XCTest со стабом `URLProtocol`.

**Spec:** `docs/superpowers/specs/2026-11-08-calendar-design.md`; ядро — `docs/superpowers/plans/2026-11-08-calendar-1-core.md`.

## Global Constraints

- Всё из Global Constraints плана 1.
- Google: REST v3 `https://www.googleapis.com/calendar/v3`; OAuth `https://accounts.google.com/o/oauth2/v2/auth` и `https://oauth2.googleapis.com/token`; области `https://www.googleapis.com/auth/calendar openid email`; PKCE S256; loopback `http://127.0.0.1:<случайный порт>`; `access_type=offline`, `prompt=consent` при первом входе; `include_granted_scopes=true`.
- Ошибки согласия `admin_policy_enforced`, `org_internal`, `access_denied` → `CalendarAccountState.adminBlocked` с показом идентификатора клиента Makosh; `invalid_grant` при обновлении → `needsSignIn`, данные не удаляются.
- Клиент Google компилируется из приватного входа; сборка без него не падает, вход Google выключен с надписью «Вход Google не настроен в этой сборке».
- Разрешение Google — общее для будущей почты: Keychain-сервис `org.makosh.google.grants.v1`, аккаунт — `sub` из ID-токена.
- CalDAV-пароль — Keychain-сервис `org.makosh.calendar.caldav.v1`, аккаунт — `accountID`.
- Плашки в Google: `summary: "Занято"`, `visibility: private`, `transparency: opaque`, `reminders.useDefault: false`, `extendedProperties.private.makoshBusy = "<sourceEventID>;<ISO8601 occurrenceKey>"`, `sendUpdates=none`. События с участниками — `sendUpdates=all`.
- Подписка: только `https` (`webcal` → `https`), редиректы только на тот же хост, лимит 10 MiB, `ETag`/`Last-Modified`, обход раз в час.
- Обход Google/CalDAV раз в 120 с и по «Обновить»; не больше 50 записей наружу за проход на календарь.
- Ошибки HTTP: 4xx кроме 408/409/429 → `rejected(code:stage:)`; обрыв, таймаут, 5xx, 408 → `unknown`; 429 и 503 с `Retry-After` — пауза учётной записи; 412 (ETag) → перечит и повтор сверки в следующем проходе, не `rejected`.
- Ни тела ответов, ни URL с параметрами, ни токены не попадают в ошибки, логи и UI.
- Живые Google и CalDAV — только по команде пользователя; тесты — только стабы и синтетика.

## Review Focus

1. **Отзыв доступа посреди прохода** — `401`/`invalid_grant` на третьей записи: проход останавливается, применённые записи остаются подтверждёнными, учётная запись — `needsSignIn`, плашки её календарей помечаются «не обновляются». Тест в задаче 9.
2. **`410 Gone` на `syncToken`** — полный перечит без потери локальных `taskID` и без удаления событий, которые просто не попали в страницу. Тест в задаче 4.
3. **CalDAV-сервер без `sync-collection`** — сравнение ETag по `calendar-query` находит изменённые и удалённые события. Тест в задаче 6.
4. **Порт loopback занят или пользователь закрыл браузер** — вход завершается ошибкой по таймауту 5 минут, слушатель закрыт, учётная запись не создана. Тест в задаче 3.
5. **Неизвестный исход создания события с участниками** — повтор сам не происходит; «Проверить» находит событие по `iCalUID` и подтверждает попытку без второй рассылки. Тест в задаче 9.

---

### Task 1: Встроенный OAuth-клиент Google из приватного входа сборки

**Files:**
- Create: `scripts/prepare-google-oauth-config.py`, `scripts/test-google-oauth-config.py`
- Modify: `scripts/test.sh`, `scripts/build-app.sh`, `scripts/run.sh` (вызов подготовки рядом с `prepare-telegram-build-config.py`), `Package.swift` (`MakoshCalendar` зависит от `MakoshBuildConfiguration`)
- Generated (ignored): `.local/build-configuration/GoogleOAuthConfiguration.swift`

**Interfaces:**
- Produces: `public enum MakoshGoogleOAuthConfiguration { public static let clientID: String?; public static let clientSecret: String? }`.

Вход: переменные окружения `MAKOSH_GOOGLE_OAUTH_CLIENT_ID` и `MAKOSH_GOOGLE_OAUTH_CLIENT_SECRET` (CI) или файл `.local/google-oauth.env` (права 0600, владелец — пользователь) со строкой `MAKOSH_GOOGLE_OAUTH_CLIENT_CONFIG_PATH=/абсолютный/путь.json`; JSON — тип `installed`, `client_id` по `^[A-Za-z0-9._-]{1,4096}$`, `client_secret` непустой, `redirect_uris` — только loopback (`http://localhost`, `http://127.0.0.1`). Сам JSON остаётся у пользователя вне репозитория. Нет входа → `nil`/`nil` и сообщение «Google OAuth: не настроен». Неверный вход → файл `#error("Google OAuth build configuration rejected; rerun preparation")` и выход с ошибкой без показа значений. Публикация — как `publish` в `prepare-telegram-build-config.py` (атомарно, 0600, отказ при символических ссылках).

- [ ] **Step 1: Write the failing tests** в `scripts/test-google-oauth-config.py` (unittest, временные каталоги): `test_missing_input_writes_nil`, `test_valid_installed_client_writes_constants`, `test_web_client_rejected`, `test_non_loopback_redirect_rejected`, `test_world_readable_env_rejected`, `test_rejection_overwrites_previous_constants_with_error`, `test_values_never_printed` (stdout/stderr без `client_id`).
- [ ] **Step 2: Run** `python3 scripts/test-google-oauth-config.py` → FAIL.
- [ ] **Step 3: Implement** скрипт; добавить вызов в три сценария и `python3 scripts/test-google-oauth-config.py` в `scripts/test.sh`.
- [ ] **Step 4: Run** → PASS; `swift build --target MakoshCalendar` собирается и без входа.
- [ ] **Step 5: Commit** — `git commit -m "Compile the Google OAuth client from private build input"`

### Task 2: HTTP-транспорт календаря и протокол адаптера

**Files:**
- Create: `Sources/MakoshCalendar/CalendarHTTP.swift`, `Sources/MakoshCalendar/CalendarAdapter.swift`
- Test: `Tests/MakoshCalendarTests/CalendarHTTPTests.swift`, `Tests/MakoshCalendarTests/StubURLProtocol.swift`

**Interfaces:**
- Produces:
  - `public struct CalendarHTTP: Sendable { public init(session: URLSession = .calendarEphemeral, timeout: TimeInterval = 30); public func send(_ request: URLRequest, stage: String, limit: Int = 10 << 20) async throws -> (Data, HTTPURLResponse) }` — классификация ошибок по Global Constraints; `Retry-After` → `CalendarFailure.unreachable` с `retryAfter` в `CalendarHTTPError.retryAfter(TimeInterval)` (внутренний тип, наружу — `unreachable`).
  - `extension URLSession { public static var calendarEphemeral: URLSession }` — без кеша, cookies и хранения учётных данных; делегат запрещает редиректы на другой хост.
  - `public struct RemoteCollection: Equatable, Sendable { externalID: String; name: String; color: String?; access: CalendarAccess }`
  - `public struct RemoteChangeSet: Sendable { events: [CalendarEvent]; removedExternalIDs: [String]; busyCopies: [ObservedBusyCopy]; cursor: Data?; full: Bool }`
  - `public struct RemoteEventRef: Equatable, Sendable { externalID: String; etag: String? }`
  - `public protocol CalendarAdapter: Sendable { func collections() async throws -> [RemoteCollection]; func changes(collection: CalendarCollection, cursor: Data?, window: DateInterval) async throws -> RemoteChangeSet; func create(_ event: CalendarEvent, in collection: CalendarCollection, notify: Bool) async throws -> RemoteEventRef; func update(_ event: CalendarEvent, ref: RemoteEventRef, in collection: CalendarCollection, notify: Bool) async throws -> RemoteEventRef; func delete(ref: RemoteEventRef, in collection: CalendarCollection, notify: Bool) async throws; func respond(_ response: CalendarResponse, ref: RemoteEventRef, in collection: CalendarCollection) async throws -> RemoteEventRef; func find(uid: String, in collection: CalendarCollection) async throws -> CalendarEvent?; func createBusyCopy(_ copy: DesiredBusyCopy, in collection: CalendarCollection) async throws -> RemoteEventRef; func moveBusyCopy(ref: RemoteEventRef, to time: CalendarEventTime, marker: CalendarBusyMarker, in collection: CalendarCollection) async throws -> RemoteEventRef; var schedulesInvitations: Bool { get async } }`

- [ ] **Step 1: Tests** `testClassifies4xxAsRejectedAnd5xxAsUnknown`, `testRetryAfterPausesAsUnreachable`, `testCrossHostRedirectRefused`, `testOversizedBodyRejected`, `testErrorsCarryNoBodyOrURL` (`String(describing:)` ошибки не содержит тела и запроса).
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Add the calendar HTTP transport and adapter contract"`

### Task 3: OAuth Google для настольного приложения и хранилище разрешений

**Files:**
- Create: `Sources/MakoshCalendar/GoogleOAuth.swift`, `Sources/MakoshCalendar/CalendarCredentialVault.swift`
- Test: `Tests/MakoshCalendarTests/GoogleOAuthTests.swift`, `Tests/MakoshCalendarTests/CalendarCredentialVaultTests.swift`

**Interfaces:**
- Produces:
  - `public struct GoogleOAuthClient: Sendable { clientID: String; clientSecret: String; public static var embedded: GoogleOAuthClient? }` (из `MakoshGoogleOAuthConfiguration`).
  - `public struct GoogleGrant: Codable, Equatable, Sendable { subject: String; email: String; scopes: Set<String>; refreshToken: String }` (в Keychain), `public struct GoogleAccessToken: Sendable { value: String; expiresAt: Date }`.
  - `public actor GoogleOAuth { public init(client: GoogleOAuthClient, http: CalendarHTTP, openBrowser: @escaping @Sendable (URL) -> Void, timeout: TimeInterval = 300); public func signIn(loginHint: String?) async throws -> GoogleGrant; public func accessToken(for grant: GoogleGrant) async throws -> GoogleAccessToken }` — `signIn` поднимает `NWListener` на `127.0.0.1:0`, строит URL с `state` (32 байта) и `code_challenge`, ждёт один GET с совпадающим `state`, отвечает простой страницей «Можно вернуться в Makosh», меняет код на токены, читает `sub`/`email` из `id_token` (подпись не проверяется: токен получен напрямую от Google по TLS) и закрывает слушатель в любом исходе. Ошибки согласия → `CalendarFailure.adminBlocked` для `admin_policy_enforced`, `org_internal`, `access_denied`; `invalid_grant` в `accessToken` → `signInRequired`. Кеш токена доступа в памяти до `expiresAt − 60 с`.
  - `public struct CalendarKeychainAccess: Sendable` — образец `JiraKeychainAccess` (`system`, `memory()`), ключ — `(service, account)`.
  - `public actor CalendarCredentialVault { public init(access: CalendarKeychainAccess = .system); func saveGrant(_:) throws; func grant(subject:) throws -> GoogleGrant?; func removeGrant(subject:) throws; func savePassword(_:accountID:) throws; func password(accountID:) throws -> String?; func removePassword(accountID:) throws }`.

- [ ] **Step 1: Tests** (стаб токен-эндпоинта и браузер-замыкание, которое само делает GET на loopback): `testSignInExchangesCodeWithPKCEAndReadsSubject`, `testStateMismatchIsIgnoredUntilTimeout`, `testListenerClosedOnTimeout` (таймаут 0,5 с в тесте), `testAdminPolicyMapsToAdminBlocked`, `testInvalidGrantMapsToSignInRequired`, `testAccessTokenCachedUntilExpiry`, `testVaultRoundTripsAndKeepsSecretsOutOfDescriptions`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Sign in to Google with PKCE on loopback and keep grants in the Keychain"`

### Task 4: Адаптер Google Calendar API v3

**Files:**
- Create: `Sources/MakoshCalendar/GoogleCalendarAdapter.swift`, `Sources/MakoshCalendar/GoogleCalendarMapping.swift`
- Test: `Tests/MakoshCalendarTests/GoogleCalendarAdapterTests.swift`

**Interfaces:**
- Consumes: `CalendarHTTP`, `GoogleOAuth.accessToken`, `CalendarAdapter`.
- Produces: `public struct GoogleCalendarAdapter: CalendarAdapter { public init(grant: GoogleGrant, oauth: GoogleOAuth, http: CalendarHTTP) }`; `schedulesInvitations == true`.

Отображение (`GoogleCalendarMapping`): `calendarList` → `RemoteCollection` (`accessRole` `owner|writer` → `.write`, иначе `.read`; `backgroundColor`); событие → `CalendarEvent` (`start.date` → весь день, `start.dateTime`+`timeZone` → timed; `recurrence` строки `RRULE:`/`EXDATE:`; `recurringEventId`+`originalStartTime` → переопределение; `attendees[].responseStatus`, `self`, `organizer.email`; `reminders.overrides` или `useDefault` → значения календаря; `hangoutLink`/`conferenceData.entryPoints[video]`/ссылка Telemost в `location`/`description` → `meetingURL`; `transparency`; `status`; `extendedProperties.private.makoshBusy` → `busyMarker` и в `busyCopies`, `makoshTask` → `taskID`). Чтение: `events.list?singleEvents=false&showDeleted=true&maxResults=250` по страницам `pageToken`; первый раз — `timeMin = window.start − 30 дней`, курсор — `nextSyncToken`; `410` → полный перечит (`full: true`). Запись: `insert/patch/delete` с `sendUpdates`, `If-Match` по `etag`; ответ — `patch` только своего участника; `find(uid:)` — `events.list?iCalUID=`.

- [ ] **Step 1: Tests** на JSON-фикстурах Google в стабе: `testListsCollectionsWithAccess`, `testMapsTimedAllDayRecurringOverrideAttendeesAndMeeting`, `testPagesAndStoresSyncToken`, `testGoneTriggersFullResync`, `testBusyCopyBodyHasOnlyBusyFields` (тело запроса: ключи только `summary`, `start`, `end`, `transparency`, `visibility`, `reminders`, `extendedProperties`), `testInviteSendsUpdatesAllAndCopyNone`, `testRespondPatchesOnlySelfAttendee`, `testFindByICalUID`, `testPreconditionFailedIsNotRejected`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Read and write Google calendars through the REST API"`

### Task 5: Адаптер CalDAV — обнаружение и чтение

**Files:**
- Create: `Sources/MakoshCalendar/CalDAVAdapter.swift`, `Sources/MakoshCalendar/CalDAVXML.swift`, `Sources/MakoshCalendar/CalDAVProviders.swift`
- Test: `Tests/MakoshCalendarTests/CalDAVDiscoveryTests.swift`

**Interfaces:**
- Produces:
  - `public struct CalDAVAdapter: CalendarAdapter { public init(server: URL, login: String, password: String, http: CalendarHTTP) }`; `public static func probe(server: URL, login: String, password: String, http: CalendarHTTP) async throws -> (principal: URL, home: URL, schedules: Bool)`.
  - `public enum CalDAVProviders { public static func suggestion(email: String, imapHost: String?) -> URL? }` — `yandex.ru|ya.ru|yandex.com|imap.yandex.*` → `https://caldav.yandex.ru`, `icloud.com|me.com|mac.com|imap.mail.me.com` → `https://caldav.icloud.com`, `fastmail.*` → `https://caldav.fastmail.com`, `gmail.com|googlemail.com` → `nil` (Gmail ведёт на вход Google).

Обнаружение: `GET/PROPFIND /.well-known/caldav` (редирект на тот же хост), `current-user-principal`, `calendar-home-set`, `PROPFIND Depth: 1` дома → коллекции с `resourcetype calendar`, `displayname`, `calendar-color`, `current-user-privilege-set` (`write` → `.write`), `supported-calendar-component-set` с `VEVENT`. `OPTIONS` дома → `DAV: calendar-auto-schedule` → `schedules`. Разбор XML — `XMLParser` с пространствами имён, без внешних сущностей. Базовая авторизация только по HTTPS.

- [ ] **Step 1: Tests** на XML-фикстурах: `testDiscoversPrincipalHomeAndCollections`, `testDetectsAutoSchedule`, `testReadOnlyCollectionHasReadAccess`, `testRefusesPlainHTTP`, `testProviderSuggestions`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Discover CalDAV calendars and server scheduling"`

### Task 6: Адаптер CalDAV — изменения и запись

**Files:**
- Modify: `Sources/MakoshCalendar/CalDAVAdapter.swift`
- Test: `Tests/MakoshCalendarTests/CalDAVSyncTests.swift`

Чтение: если коллекция объявляет `sync-token` — `REPORT sync-collection` (RFC 6578) с курсором `sync-token`; иначе `REPORT calendar-query` по окну `[window.start − 30 дней, window.end]` и сравнение `getetag` с прошлым курсором (курсор — JSON `{href: etag}`), затем `calendar-multiget` изменённых. `403/409` на `sync-token` → полный перечит. Объект ресурса `href` → `externalID`. Запись: `PUT <home>/<uuid>.ics` с `If-None-Match: *` (создание) или `If-Match: <etag>`; `DELETE` с `If-Match`; ответ на приглашение — `PUT` с изменённым `PARTSTAT` своего `ATTENDEE`; участники пишутся с `ORGANIZER` только если `schedules == true`, иначе событие сохраняется без `ATTENDEE`, а участники остаются в локальных полях (решение пользователя: предупреждение, без рассылки письмами). `find(uid:)` — `calendar-query` с фильтром `UID`.

- [ ] **Step 1: Tests:** `testSyncCollectionAppliesChangesAndRemovals`, `testETagDiffWithoutSyncSupport`, `testInvalidSyncTokenFallsBackToFull`, `testCreateUsesIfNoneMatchAndUpdateIfMatch`, `testAttendeesOmittedWithoutServerScheduling`, `testRespondChangesOnlyOwnPartstat`, `testBusyCopyICSHasOnlyBusyFields`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Sync and write CalDAV events with ETag preconditions"`

### Task 7: Подписка по ссылке и синтетический адаптер

**Files:**
- Create: `Sources/MakoshCalendar/SubscriptionAdapter.swift`, `Sources/MakoshCalendar/CalendarSyntheticAdapter.swift`
- Test: `Tests/MakoshCalendarTests/SubscriptionAdapterTests.swift`, `Tests/MakoshCalendarTests/CalendarSyntheticAdapterTests.swift`

**Interfaces:**
- Produces:
  - `public struct SubscriptionAdapter: CalendarAdapter { public init(url: URL, http: CalendarHTTP) throws }` — `webcal` → `https`, иначе `invalidInput`; одна коллекция `read`; курсор — `{etag, lastModified}`; `304` → пустые изменения; полный файл → все события и `removedExternalIDs` для пропавших `UID`; любая запись → `CalendarFailure.invalidInput("read only")`.
  - `public actor CalendarSyntheticAdapter: CalendarAdapter { public init(collections: [RemoteCollection], events: [String: [CalendarEvent]], schedules: Bool = true); public func failNext(_ failure: CalendarFailure); public func tamper(externalID: String, collectionExternalID: String, shiftMinutes: Int); public func externalEvents(collectionExternalID: String) -> [CalendarEvent]; public var sentInvitations: [String] { get } }` — в памяти, курсор — номер ревизии; `failNext(.unknownOutcome)` применяет запись и бросает (для проверки сверки после неизвестного исхода).

- [ ] **Step 1: Tests:** `testWebcalBecomesHTTPS`, `testNotModifiedYieldsNoChanges`, `testMissingUIDsBecomeRemovals`, `testSubscriptionIsReadOnly`, `testSyntheticAppliesThenFailsOnUnknown`, `testSyntheticTamperShiftsCopy`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Read link subscriptions and add the synthetic calendar adapter"`

### Task 8: `CalendarService` — подключения, обход и снимок

**Files:**
- Create: `Sources/MakoshCalendar/CalendarService.swift`, `Sources/MakoshCalendar/CalendarSnapshot.swift`
- Test: `Tests/MakoshCalendarTests/CalendarServiceSyncTests.swift`

**Interfaces:**
- Consumes: `CalendarStore` (план 1), `CalendarAdapter`, `CalendarCredentialVault`, `GoogleOAuth`.
- Produces:
  - `public struct CalendarSnapshot: Sendable { accounts: [CalendarAccount]; collections: [CalendarCollection]; groups: [CalendarGroup]; occurrences: [CalendarOccurrence]; events: [UUID: CalendarEvent]; openAttempts: [CalendarAttempt]; externalConflicts: [CalendarConflict]; staleCollectionIDs: Set<UUID>; window: DateInterval; googleAvailable: Bool }`
  - `public actor CalendarService { public typealias AdapterFactory = @Sendable (CalendarAccount, CalendarCredentialVault) async throws -> any CalendarAdapter; public init(store: CalendarStore, vault: CalendarCredentialVault, adapterFactory: @escaping AdapterFactory, google: GoogleOAuth?, now: @escaping @Sendable () -> Date = Date.init); public func open() async throws; public func close() async; public func snapshot(window: DateInterval) async throws -> CalendarSnapshot; public func addGoogleAccount(loginHint: String?) async throws -> CalendarAccount; public func addCalDAVAccount(name: String, server: URL, login: String, password: String) async throws -> CalendarAccount; public func addSubscription(name: String, url: URL) async throws -> CalendarAccount; public func reauthorize(accountID: UUID) async throws; public func disconnect(accountID: UUID) async throws; public func refreshCollections(accountID: UUID) async throws; public func sync(accountID: UUID) async; public func syncAll() async; public func startPolling(); public func stopPolling() }`
  - `public static func defaultAdapterFactory(oauth: GoogleOAuth?, http: CalendarHTTP) -> AdapterFactory`

Обход учётной записи: для каждой включённой коллекции — `changes` → `observe`/`observeRemoval` в одной транзакции, затем курсор; наблюдённые плашки уходят в сверку (не в события-источники); ошибки по таблице Global Constraints меняют `CalendarAccount.state`; `needsSignIn`/`adminBlocked`/`unreachable` добавляют коллекции учётной записи в `staleCollectionIDs`. Полный перечит не удаляет события, отсутствующие в странице, а только отмеченные сервером удалёнными или пропавшие по итогам полного прохода всех страниц. Таймер опроса — `pollSeconds` и `subscriptionPollSeconds` из предпочтений; учётные записи обходятся параллельно, внутри — последовательно.

- [ ] **Step 1: Tests** (синтетический адаптер, реальный PostgreSQL): `testConnectDiscoversCollectionsAndFirstSyncStoresEvents`, `testIncrementalSyncAppliesRemovalsKeepingHistory`, `testFullResyncKeepsTaskLinks`, `testRevokedGrantMarksNeedsSignInAndStale`, `testAdminBlockedStateIsDistinct`, `testSubscriptionPolledHourly` (часы подменены), `testSnapshotExpandsOccurrencesInWindow`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Add the calendar service with account sync and snapshot"`

### Task 9: `CalendarService` — команды пользователя, плашки и попытки

**Files:**
- Create: `Sources/MakoshCalendar/CalendarService+Commands.swift`, `Sources/MakoshCalendar/CalendarService+Busy.swift`
- Test: `Tests/MakoshCalendarTests/CalendarServiceCommandsTests.swift`, `Tests/MakoshCalendarTests/CalendarServiceBusyTests.swift`

**Interfaces:**
- Produces:
  - `public enum CalendarEditScope: String, Sendable { case occurrence, series }`
  - `public struct CalendarDraft: Sendable { collectionID: UUID; title: String; notes: String; location: String; time: CalendarEventTime; recurrence: CalendarRecurrence?; attendees: [String]; reminders: [Int]?; meetingURL: URL?; transparency: CalendarTransparency; taskID: UUID? }`
  - `public enum CalendarWriteOutcome: Sendable { case saved(CalendarEvent), conflicts([CalendarConflict]), attemptOpen(CalendarAttempt) }`
  - `public func create(_ draft: CalendarDraft, ignoringConflicts: Bool) async throws -> CalendarWriteOutcome`, `public func move(eventID: UUID, to time: CalendarEventTime, scope: CalendarEditScope, ignoringConflicts: Bool) async throws -> CalendarWriteOutcome`, `public func update(eventID: UUID, draft: CalendarDraft, scope: CalendarEditScope, ignoringConflicts: Bool) async throws -> CalendarWriteOutcome`, `public func delete(eventID: UUID, scope: CalendarEditScope) async throws`, `public func respond(eventID: UUID, _ response: CalendarResponse) async throws`, `public func check(attemptID: UUID) async throws -> CalendarAttemptState`, `public func dismiss(attemptID: UUID) async throws`, `public func nearestFree(length: TimeInterval, after: Date, collectionID: UUID) async throws -> Date?`
  - Группы: `public struct BusyPreview: Equatable, Sendable { create: [UUID: Int]; remove: [UUID: Int] }` (по календарю-получателю), `public func previewGroupChange(collections: [CalendarCollection], groups: [CalendarGroup]) async throws -> BusyPreview`, `public func applyGroupChange(collections: [CalendarCollection], groups: [CalendarGroup]) async throws` — сохраняет и запускает сверку.
  - `func reconcileBusy() async` — вызывается после каждого прохода и каждой команды: `BusyEngine.desired` + `reconcile`, не больше `maxWritesPerPass` действий на календарь-получатель, каждое — попытка `createCopy|moveCopy|deleteCopy`; `unknown` по плашке закрывается следующей сверкой (`adopt` → `confirmed`; отсутствие на сервере → `rejected`, затем новое `create`).

Правила команд: оригинал в локальном календаре пишется только в хранилище; во внешнем — попытка `createEvent|updateEvent|deleteEvent` (`notify = !attendees.isEmpty`); перед записью — `CalendarConflictFinder.conflicts`, при непустом и `ignoringConflicts == false` → `.conflicts`. `unknown` по оригиналу с участниками ждёт `check` (`find(uid:)`) или `dismiss`; без участников — сверка находит по `uid` сама. Участники в локальном календаре отбрасываются с `invalidInput("local calendar has no attendees")`. Запрет записи в плашку: `move/update/delete` события с `busyMarker` → `invalidInput("busy copy")`.

- [ ] **Step 1: Tests:**

```swift
func testDentistInPersonalPlacesBusyInBothWorkCalendars() async throws {
    let outcome = try await service.create(draft(in: personal, 14, 15), ignoringConflicts: false)
    guard case .saved = outcome else { return XCTFail() }
    await service.reconcileBusy()
    for work in [workA, workB] {
        let copies = await adapter.externalEvents(collectionExternalID: work.externalID).filter { $0.busyMarker != nil }
        XCTAssertEqual(copies.map(\.title), ["Занято"]); XCTAssertTrue(copies[0].notes.isEmpty && copies[0].location.isEmpty)
    }
}
func testMovingOriginalMovesCopiesAndDeletingRemovesThem() async throws { }
func testTamperedCopyIsRestoredOnNextPass() async throws { /* adapter.tamper(...shiftMinutes: 30) → после sync время совпадает с оригиналом */ }
func testConflictReturnedBeforeWriteAndIgnoringWrites() async throws { }
func testRespondDeclinedRemovesBusyAndCopies() async throws { }
func testUnknownCopyIsAdoptedNotDuplicated() async throws { /* failNext(.unknownOutcome) → после сверки на сервере ровно одна плашка */ }
func testUnknownInviteWaitsForCheckAndFindsByUID() async throws { XCTAssertEqual(adapter.sentInvitations.count, 1) }
func testWritesCappedPerPass() async throws { /* 60 вхождений → 50, затем остальные */ }
func testGroupPreviewCountsWithoutWriting() async throws { }
func testBusyCopyCannotBeEdited() async throws { }
func testLocalCalendarRefusesAttendees() async throws { }
func testRevokedMidPassKeepsConfirmedWrites() async throws { }
```

- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Полная проверка плана** — `scripts/test.sh --filter MakoshCalendarTests` → PASS; `python3 scripts/test-google-oauth-config.py` → PASS; `scripts/format.sh HEAD`.
- [ ] **Step 6: Commit** — `git commit -m "Write calendar events, busy copies and replies through journaled attempts"`
