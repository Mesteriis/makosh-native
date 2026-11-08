# Персоны, план 2: модуль `MakoshPersons` — книги, коллектор, организации, движок записи, адаптеры, сервис Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Новый модуль `MakoshPersons` над `MakoshCore`: учётные записи-книги с переключателями, коллектор наблюдений собеседников и карточек книг с автосклейкой и правилами организаций, vCard, движок «персоны с признаком × книги → карточки» с журналом попыток, адаптеры CardDAV, Google Contacts, книги macOS, синтетический и мост Telegram, сервис-актор с одним последовательным раннером записи и модель раздела. Общий код Google и HTTP выезжает из `MakoshCalendar` в модуль `MakoshGoogle`.

**Architecture:** Чистые правила (фильтр почты, организации по домену и полю, желаемые карточки и сверка) отдельно от актора `PersonsStore` (таблицы `persons_*` в схеме приложения) и актора `PersonsService`. Каналы не импортируются: приложение отдаёт коллектору `PersonSourceObservation`, а Telegram-книга работает через протокол `TelegramContactsBridge`, который реализует приложение. Все внешние записи — попытки `queued → sent → confirmed | rejected | unknown`; `unknown` закрывает чтение по метке.

**Tech Stack:** Swift 6, Foundation `URLSession` (стаб `URLProtocol` в тестах), `Contacts.framework` (только адаптер книги macOS), `MakoshCore.PostgresConnection`, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-08-persons-design.md`; ядро — `docs/superpowers/plans/2026-11-08-persons-1-core.md`.

## Global Constraints

- Всё из Global Constraints плана 1.
- Таблицы модуля — `persons_*` в схеме приложения; версия модуля в `persons_meta`.
- `MakoshPersons` зависит только от `MakoshCore`, `MakoshGoogle`, `CPostgres` и системного `Contacts`; не импортирует `MakoshMail`, `MakoshTelegram`, `MakoshWhatsApp`, `MakoshTeams`, `MakoshCalendar`.
- Попытки: одна открытая на (персона, книга); `queued → sent → confirmed | rejected | unknown`; после перезапуска `sent → unknown`; `unknown` закрывается только чтением (поиск по метке) или «Отказаться»; журнал хранит отпечаток карточки, не телефоны и адреса.
- Запись наружу: не больше 50 попыток на книгу за проход; один последовательный раннер; пользовательская команда пишет свою персону сразу и запускает коалесцированный проход.
- Карточка наружу — плоская: структурное имя, телефоны, адреса, организация (текст), должность. Ни меток, ни заметок, ни `former`, ни вложенности.
- Метка своей карточки: vCard `X-MAKOSH-PERSON:<uuid>`; Google `clientData[{key: "makosh-person", value: uuid}]`; книга macOS — только привязка по `identifier`; Telegram — привязка по peer.
- Усыновление карточки без метки — только если она источник этой же персоны в этой же книге. Чужие карточки не правятся и не удаляются.
- Удаление снаружи — только командой «Удалить везде», и только карточек с привязкой.
- CardDAV: RFC 6352, vCard 3.0, `If-None-Match: *` / `If-Match`; Google: People API v1, область `https://www.googleapis.com/auth/contacts`, инкрементально к существующему разрешению; Telegram: `addContactInteractively` / `importContact` / `deleteContactPeerInteractively` через мост.
- Ошибки HTTP: 4xx кроме 408/409/412/429 → `rejected(code:stage:)`; обрыв, таймаут, 5xx, 408 → `unknownOutcome`; 412 → перечит и повтор сверки в следующем проходе; 429/503 с `Retry-After` — пауза книги. Ни тел, ни URL с параметрами, ни токенов в ошибках.
- Пароли CardDAV — Keychain `org.makosh.persons.carddav.v1`; разрешения Google — `org.makosh.google.grants.v1` (общий).
- Обход книг — по умолчанию раз в 600 с и по «Обновить»; книга macOS читается только когда включена пользователем и доступ выдан.
- Живые книги — только по команде пользователя; тесты — стабы и синтетика.

## Review Focus

1. **Один аккаунт — и источник, и получатель** — персона пришла из карточки Google X, получила признак: движок усыновляет X (привязка к `resourceName` X), не создаёт вторую. Тест в задаче 7.
2. **Неизвестный исход создания** — после `unknown` следующий проход находит карточку по метке и подтверждает; не найдена при полном чтении — создаёт заново; второй карточки нет. Тест в задаче 8.
3. **Убрали телефон во внешней книге** — чтение книги видит карточку с привязкой без телефона → `removeValue(.removedInBook)`, отпечаток меняется, в другие книги уходит обновление без этого телефона, обратно в первую книгу он не возвращается. Тест в задаче 9.
4. **Спам задним числом** — персона из одного письма; письмо помечено спамом → `hiddenAsSpam`, её адрес не считается в правиле «два адреса» домена; новое нормальное письмо возвращает её. Тест в задаче 5.
5. **Письмо с `List-Id` от двух адресов домена** — не собирается, организация по домену не создаётся. Тест в задаче 4.

---

### Task 1: Модуль `MakoshGoogle` — общий OAuth, разрешения и HTTP

**Files:**
- Create: `Sources/MakoshGoogle/GoogleOAuth.swift` (перенос из `MakoshCalendar`), `Sources/MakoshGoogle/GoogleGrantVault.swift` (часть `CalendarCredentialVault` про разрешения + `KeychainAccess`), `Sources/MakoshGoogle/ServiceHTTP.swift` (перенос `CalendarHTTP`, `CalendarHTTPError`, `CalendarRedirectGuard`, `URLSession.calendarEphemeral`)
- Modify: `Package.swift` (цель `MakoshGoogle` с зависимостями `MakoshCore`, `MakoshBuildConfiguration`; `MakoshCalendar` и `MakoshPersons` зависят от неё; тестовая цель `MakoshGoogleTests`), `Sources/MakoshCalendar/*.swift` (импорт `MakoshGoogle`; `CalendarCredentialVault` хранит только пароли CalDAV и делегирует разрешения `GoogleGrantVault`)
- Move tests: тесты `GoogleOAuth`/`CalendarHTTP` из `Tests/MakoshCalendarTests` → `Tests/MakoshGoogleTests` (`StubURLProtocol` — копия в обоих тестовых пакетах или общий файл через `exclude`/symlink не используется: копия).

**Interfaces:**
- Produces:
  - `public struct KeychainAccess: Sendable` — прежний `CalendarKeychainAccess` (`system`, `memory()`); в `MakoshCalendar` остаётся `public typealias CalendarKeychainAccess = KeychainAccess`.
  - `public struct ServiceHTTP: Sendable` — прежний `CalendarHTTP` с тем же API (`raw`, `send`), `public enum ServiceHTTPError` — прежний `CalendarHTTPError` без свойства `failure` (его даёт расширение в `MakoshCalendar`); `URLSession.serviceEphemeral`. В `MakoshCalendar`: `public typealias CalendarHTTP = ServiceHTTP`, `CalendarHTTPError = ServiceHTTPError`, `URLSession.calendarEphemeral` — расширение, возвращающее `serviceEphemeral`.
  - `public actor GoogleOAuth` — как сейчас, но `init` принимает `scopes: String` (умолчание — прежняя строка календаря) и `http: ServiceHTTP`; `public func signIn(scopes: String) async throws -> GoogleGrant` для инкрементального расширения (`include_granted_scopes=true`, `login_hint` — e-mail существующего разрешения через параметр `loginHint: String?`); `accessToken(for grant:)` как сейчас.
  - `public actor GoogleGrantVault { init(access: KeychainAccess = .system); saveGrant(_:); grant(subject:); removeGrant(subject:); grants() -> [GoogleGrant] }` — сервис `org.makosh.google.grants.v1`; `grants()` перечисляет сохранённые (через список `subjects` в отдельном элементе `org.makosh.google.grants.v1/index`, моё решение для «один вход — много разделов»).
  - `GoogleGrant` без изменений; `GoogleGrant.has(scope: String) -> Bool`.
  - `CalendarFailure` остаётся в календаре; `GoogleOAuth` бросает `public enum GoogleOAuthFailure: Error, Equatable, Sendable { case notConfigured, adminBlocked, cancelled, timeout, invalidGrant, transport(stage: String), rejected(code: Int, stage: String) }`, который календарь отображает в свой `CalendarFailure` в одном месте (`CalendarService`).

- [ ] **Step 1: Run the baseline** — `scripts/test.sh --filter MakoshCalendarTests` → PASS (число тестов записать).
- [ ] **Step 2: Move** файлы `git mv`, завести цель, перенести тесты, добавить typealias-ы и отображение ошибок; добавить тест `testGrantIndexListsSavedGrants` в `Tests/MakoshGoogleTests/GoogleGrantVaultTests.swift` и `testIncrementalSignInSendsIncludeGrantedScopesAndLoginHint` в `GoogleOAuthTests` (стаб проверяет параметры запроса авторизации).
- [ ] **Step 3: Run** — `scripts/test.sh --filter MakoshGoogleTests` и `--filter MakoshCalendarTests` → PASS, прежнее число тестов календаря сохранено (перенесённые считаются в новом пакете).
- [ ] **Step 4: Commit** — `git commit -m "Move Google OAuth, grants and HTTP into MakoshGoogle"`

### Task 2: Модуль `MakoshPersons`, модели книг и хранилище

**Files:**
- Modify: `Package.swift` (цель `MakoshPersons`: `MakoshCore`, `MakoshGoogle`, `CPostgres`; тестовая цель `MakoshPersonsTests`: `MakoshPersons`, `MakoshCore`, `MakoshGoogle`, `CPostgres`)
- Create: `Sources/MakoshPersons/PersonsModels.swift`, `Sources/MakoshPersons/PersonsStore.swift`, `Sources/MakoshPersons/PersonsStoreSchema.swift`
- Test: `Tests/MakoshPersonsTests/PersonsStoreTests.swift`, `Tests/MakoshPersonsTests/PersonsTestDatabase.swift` (по образцу `PostgresTestDatabase`, схема `makosh_test_…`, открывает `PersonStore` ядра и `PersonsStore` модуля в одной схеме)

**Interfaces:**
- Produces:
  - `public enum PersonBookKind: String, Codable, Sendable { case telegram, carddav, googleContacts, macContacts, synthetic, mail, whatsapp, teams }` с `service: String` (`telegram`, `carddav`, `google-contacts`, `macos-contacts`, `synthetic`, `mail`, `whatsapp`, `teams`) и `var isBook: Bool` (`mail`, `whatsapp`, `teams` — каналы-источники без книги: у них только сбор собеседников и курсоры; `readBook`, `isAddressBookSource`, `acceptsAddressBook` для них всегда `false`).
  - `public enum PersonBookState: String, Codable, Sendable { case connected, needsSignIn, noAccess, unreachable, disabled }`
  - `public struct PersonBook: Codable, Equatable, Identifiable, Sendable { id: UUID; kind: PersonBookKind; name: String; accountID: String; collectConversations: Bool (= true, имеет смысл для `telegram`, `mail`, `whatsapp`, `teams`); readBook: Bool (= true); isAddressBookSource: Bool (= false); acceptsAddressBook: Bool (= true); state: PersonBookState; lastError: PersonsFailure?; cursor: Data?; caldavServer: URL?; caldavLogin: String?; googleSubject: String?; pausedUntil: Date?; var source: ImportSource { .init(service: kind.service, accountID: accountID) } }`
  - `public enum PersonBookEntryState: String, Codable, Sendable { case managed, duplicate, notManaged, removed }`
  - `public struct PersonBookEntry: Codable, Equatable, Identifiable, Sendable { id: UUID; personID: UUID; bookID: UUID; externalID: String; etag: String?; fingerprint: String; state: PersonBookEntryState; updatedAt: Date }`
  - `public enum PersonAttemptKind: String, Codable, Sendable { case create, update, delete }`, `public enum PersonAttemptState: String, Codable, Sendable { case queued, sent, confirmed, rejected, unknown; var isOpen: Bool }`
  - `public struct PersonAttempt: Codable, Equatable, Identifiable, Sendable { id: UUID; personID: UUID; bookID: UUID; entryID: UUID?; kind: PersonAttemptKind; state: PersonAttemptState; fingerprint: String; failure: PersonsFailure?; createdAt: Date; updatedAt: Date; resolvedAt: Date? }`
  - `public enum PersonsFailure: Error, Codable, Equatable, Sendable { case invalidSchema, notOpen, notFound, storage(String?), invalidInput(String), rejected(code: Int, stage: String), unknownOutcome(stage: String), preconditionFailed, retryAfter(Int), signInRequired, noAccess, unreachable, noPhoneOrPeer, notInTelegram }` — без тел ответов и URL.
  - `public struct PersonsPreferences: Codable, Equatable, Sendable { pollIntervalSeconds: Int (= 600); domainRuleEnabled: Bool (= true); companyRuleEnabled: Bool (= true); extraStopDomains: [String]; extraRoleLocalParts: [String]; expandedOrganizations: Set<UUID>; filter: String (= "all"); showAddressBookOnly: Bool }`
  - `public struct PersonCollectionCursor: Codable, Equatable, Sendable { source: ImportSource; scope: String; value: Data?; updatedAt: Date }` — курсор сбора (учётная запись почты и папка, аккаунт Telegram).
  - `public actor PersonsStore { init(connectionString: String, schema: String) throws; open() throws; close(); books(); saveBook(_:); removeBook(id:); entries(personID:) / entries(bookID:) / entry(bookID:externalID:); saveEntry(_:); attempts(open: Bool) / attempt(id:); saveAttempt(_:) (проверяет допустимые переходы, как `TaskJiraAttempt.allows`); markSentAsUnknownOnOpen(); preferences() / savePreferences(_:); cursor(source:scope:) / saveCursor(_:) }` — таблицы `persons_meta`, `persons_books`, `persons_book_entries` (уникальность `(book_id, external_id)` и `(person_id, book_id)` для `managed`), `persons_attempts`, `persons_cursors`, `persons_preferences`; одна транзакция на метод под `pg_advisory_xact_lock(hashtext('makosh-persons'), hashtext(schema))`.

- [ ] **Step 1: Write the failing tests** — `testOpenCreatesTablesAndMeta`, `testBookRoundTripHidesNothingButSecrets` (пароль в книге не хранится — поля нет), `testEntryUniquenessPerBookAndExternalID`, `testAttemptTransitionsAreRestricted` (`queued → confirmed` отвергается), `testSentBecomesUnknownOnOpen`, `testCursorPerSourceAndScope`, `testPreferencesDefaults`.
- [ ] **Step 2: Run** — `scripts/test.sh --filter MakoshPersonsTests.PersonsStoreTests` → FAIL (модуля нет).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Add the MakoshPersons module with books, entries and attempts"`

### Task 3: vCard и плоская карточка

**Files:**
- Create: `Sources/MakoshPersons/PersonCard.swift`, `Sources/MakoshPersons/VCard.swift`
- Test: `Tests/MakoshPersonsTests/VCardTests.swift`, `Tests/MakoshPersonsTests/PersonCardTests.swift`

**Interfaces:**
- Produces:
  - `public struct PersonCard: Codable, Equatable, Sendable { makoshID: UUID; kind: PersonKind; displayName: String; givenName: String; familyName: String; middleName: String; phones: [String]; emails: [String]; organization: String; jobTitle: String; public var fingerprint: String }` — SHA-256 канонической формы (поля в фиксированном порядке, списки отсортированы, строки обрезаны) в hex.
  - `public enum PersonCardBuilder { public static func card(for person: Person, memberships: [PersonMembership], organizations: [UUID: Person]) -> PersonCard }` — `organization` = `person.organization`, если непусто, иначе имя первой `confirmed` организации по дате; `jobTitle` = роль того же членства, если непуста, иначе `person.jobTitle`; имя — `person.nameParts`; у организации `givenName/familyName` пустые, `displayName` — имя.
  - `public struct RemoteCard: Equatable, Sendable { externalID: String; etag: String?; makoshID: UUID?; imported: ImportedPerson; kind: PersonKind }`
  - `public enum VCard { public static func serialize(_ card: PersonCard) -> String; public static func parse(_ text: String) throws -> (imported: ImportedPerson, makoshID: UUID?, kind: PersonKind, uid: String?) }` — vCard 3.0: `BEGIN/END`, `VERSION:3.0`, `UID`, `FN`, `N:family;given;middle;;`, `ORG`, `TITLE`, `TEL;TYPE=CELL` (все телефоны `TYPE=CELL,VOICE`, моё решение), `EMAIL;TYPE=INTERNET`, `X-MAKOSH-PERSON:<uuid>`, `KIND:org` → `X-ADDRESSBOOKSERVER-KIND:group` не используется; организация — `X-ABShowAs:COMPANY` (Apple/iCloud) плюс `KIND:org` (4.0-совместимое поле, принимается серверами как расширение). Разбор: сворачивание строк, экранирование `\,` `\;` `\n`, параметры игнорируются кроме `TYPE`, `N` даёт структурное имя, `NOTE` → `notes`, `X-MAKOSH-PERSON` → `makoshID`, `X-ABShowAs:COMPANY` или `KIND:org` → `.organization`; `externalID` задаёт вызывающий (href).

- [ ] **Step 1: Write the failing tests**

```swift
func testSerializeRoundTrips() throws { /* card → serialize → parse: imported.displayName/givenName/familyName/phones/emails/organization/jobTitle, makoshID == card.makoshID */ }
func testEscapesAndFoldsLongLines() throws { /* FN с ",;\n" → экранировано; строка > 75 октетов свёрнута; parse восстанавливает */ }
func testOrganizationCardIsMarked() throws { /* kind .organization → X-ABShowAs:COMPANY и KIND:org; parse → .organization */ }
func testParseIgnoresUnknownPropertiesAndPhoto() throws { /* PHOTO;ENCODING=b:... и X-FOO пропущены */ }
func testFingerprintIgnoresOrderAndWhitespace() { /* phones ["b","a"] == ["a","b"]; " x " == "x" */ }
func testBuilderPrefersConfirmedMembership() { /* organization пусто, два членства: suggested и confirmed → имя confirmed; роль из него */ }
```

- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Build flat person cards and read and write vCard 3.0"`

### Task 4: Чистые правила: фильтр почты и организации

**Files:**
- Create: `Sources/MakoshPersons/MailCollectionRule.swift`, `Sources/MakoshPersons/OrganizationRules.swift`, `Sources/MakoshPersons/PersonSourceObservation.swift`
- Test: `Tests/MakoshPersonsTests/MailCollectionRuleTests.swift`, `Tests/MakoshPersonsTests/OrganizationRulesTests.swift`

**Interfaces:**
- Produces:
  - `public struct MailParticipant: Equatable, Sendable { address: String; name: String }`
  - `public enum MailFolderRole: String, Sendable { case inbox, sent, junk, trash, other }`
  - `public struct MailLetterFacts: Equatable, Sendable { accountID: String; folder: MailFolderRole; from: MailParticipant?; to: [MailParticipant]; cc: [MailParticipant]; bcc: [MailParticipant]; ownAddresses: Set<String>; hasListHeaders: Bool; precedenceBulk: Bool; autoSubmitted: Bool; markedSpam: Bool; observedAt: Date }`
  - `public struct MailEvidence: Equatable, Sendable { accountID: String; address: String; spam: Bool }`
  - `public enum PersonSourceEvidence: Equatable, Sendable { case book, conversation, mail(MailEvidence) }`
  - `public struct PersonSourceObservation: Equatable, Sendable { source: ImportSource; person: ImportedPerson; observedAt: Date; evidence: PersonSourceEvidence }`
  - `public enum MailCollectionRule { public static func observations(_ facts: MailLetterFacts) -> [PersonSourceObservation]; public static func isRobot(_ address: String) -> Bool }` — правила: `junk`/`trash` или `markedSpam` → для каждого участника-кандидата наблюдение **не** создаётся, но возвращается отдельным списком `spamEvidence(_ facts:) -> [MailEvidence]` (адреса From для входящего), чтобы коллектор поднял счётчик спама; `hasListHeaders || precedenceBulk || autoSubmitted` → пусто; `inbox`/`other` → только `from` (если не свой адрес и не робот); `sent` → `to + cc + bcc` без своих и роботов; `externalID` = адрес в нижнем регистре; `displayName` = имя или адрес; `evidence = .mail(MailEvidence(spam: false))`.
  - `public enum OrganizationRules { public static let builtInStopDomains: Set<String>; public static func domain(of email: String) -> String?; public static func isPublicDomain(_ domain: String, extra: Set<String>) -> Bool (с поддоменами); public static func suggestions(for person: Person, domainAddressCounts: [String: Int], existing: [Person], preferences: PersonsPreferences) -> [OrganizationSuggestion] }`
  - `public struct OrganizationSuggestion: Equatable, Sendable { organizationName: String; existingOrganizationID: UUID?; origin: MembershipOrigin; role: String }` — по `companyField`: `person.organization` непусто → имя как есть (обрезка); по `emailDomain`: для каждого домена адресов персоны, не публичного, с `domainAddressCounts[domain] >= 2` → имя = домен; `existingOrganizationID` — организация с тем же именем без учёта регистра; правило выключено в `preferences` → пропуск.

- [ ] **Step 1: Write the failing tests**

```swift
func testIncomingLetterCollectsOnlySender() { /* inbox, from a@x, to me, cc b@x → один a@x */ }
func testSentLetterCollectsRecipientsWithoutSelf() { /* sent to [a, me], cc [b], bcc [c] → a, b, c */ }
func testListHeadersBlockCollection() { /* hasListHeaders → [] даже при двух адресах домена */ }
func testRobotsAreSkipped() { XCTAssertTrue(MailCollectionRule.isRobot("noreply@shop.ru")); XCTAssertTrue(MailCollectionRule.isRobot("mailer-daemon@x")); XCTAssertFalse(MailCollectionRule.isRobot("ivan@x")) }
func testSpamGivesEvidenceNotObservations() { /* junk → observations [], spamEvidence [from] */ }
func testPublicDomainsAreNotOrganizations() { XCTAssertTrue(OrganizationRules.isPublicDomain("mail.gmail.com", extra: [])); XCTAssertFalse(OrganizationRules.isPublicDomain("sidorov.ru", extra: [])) }
func testDomainNeedsTwoAddresses() { /* counts ["sidorov.ru": 1] → нет; 2 → предложение emailDomain("sidorov.ru") с именем "sidorov.ru" */ }
func testCompanyFieldSuggestsExisting() { /* organization "ИП Сидоров", existing содержит "ип сидоров" → existingOrganizationID */ }
func testDisabledRulesReturnNothing() { /* preferences.domainRuleEnabled false → только companyField */ }
```

- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Decide which mail participants and organizations to collect"`

### Task 5: Коллектор

**Files:**
- Create: `Sources/MakoshPersons/PersonCollector.swift`
- Test: `Tests/MakoshPersonsTests/PersonCollectorTests.swift` (реальный PostgreSQL через `PersonsTestDatabase`)

**Interfaces:**
- Produces:
  - `public struct CollectResult: Equatable, Sendable { created: Int; updated: Int; merged: [(survivor: UUID, removed: UUID)]; suggestedMemberships: Int; hidden: [UUID]; restored: [UUID] }` (с `Equatable` через массивы пар как `[UUID: UUID]`).
  - `public actor PersonCollector { public init(persons: PersonStore, store: PersonsStore, now: @Sendable () -> Date = Date.init); public func collect(_ observations: [PersonSourceObservation], spam: [MailEvidence] = []) async throws -> CollectResult }` — для каждого наблюдения: `persons.linkImportedPerson(person, source:, fetchedAt:, contactID: nil)`; `evidence == .mail` → `recordMailEvidence(spam: false)` и, если персона была `hiddenAsSpam`, `setHiddenAsSpam(false)`; затем `autoMerge(personID:)` один раз; затем организации: `domainAddressCounts` — число **активных** персон с адресами этого домена (запрос по `person_values`, `PersonsStore` не нужен), `OrganizationRules.suggestions` → `createOrganization` при отсутствии и `suggestMembership`; для `spam`: `recordMailEvidence(spam: true)`, и если у персоны-владельца адреса `clean == 0` и нет других identity кроме `mail` с этого адреса → `setHiddenAsSpam(true)`. Наблюдение из книги с `isAddressBookSource` (решает вызывающий через параметр `addressBookSource: ImportSource?` в `collect`) → `setAddressBook(true, origin: .sourceAccount(source))`.
  - `PersonStore` ядра получает `domainAddressCounts(domains: Set<String>) throws -> [String: Int]` (добавить в план 1 задачи 7 как часть этой задачи: мелкое расширение).

- [ ] **Step 1: Write the failing tests**

```swift
func testConversationObservationCreatesPersonOnce() async throws { /* дважды одно наблюдение → created 1, updated ≤ 1 */ }
func testPhoneMatchAutoMergesTelegramIntoMailPerson() async throws { /* mail person с телефоном в ручных; tg наблюдение с тем же → merged == [(mail, tg)] */ }
func testDomainOrganizationAppearsAtSecondAddress() async throws { /* a@sidorov.ru → нет организации; b@sidorov.ru → организация "sidorov.ru", два suggested членства */ }
func testSpamOnlyPersonIsHiddenAndReturns() async throws {
    _ = try await collector.collect([mailObs("s@x")])
    _ = try await collector.collect([], spam: [.init(accountID: "m", address: "s@x", spam: true)])
    XCTAssertTrue(try persons.person(id: id)!.hiddenAsSpam)
    _ = try await collector.collect([mailObs("s@x")])        // нормальное письмо
    XCTAssertFalse(try persons.person(id: id)!.hiddenAsSpam)
}
func testHiddenPersonDoesNotCountForDomainRule() async throws { /* две персоны домена, одна скрыта → организации нет */ }
func testBookSourceSetsFlagWithOrigin() async throws { /* addressBookSource: google → addressBook true, origin .sourceAccount(google) */ }
```

- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Collect persons from conversations and books with auto-merge and organizations"`

### Task 6: Протокол адаптера книги и синтетическая книга

**Files:**
- Create: `Sources/MakoshPersons/PersonBookAdapter.swift`, `Sources/MakoshPersons/PersonSyntheticBook.swift`
- Test: `Tests/MakoshPersonsTests/PersonSyntheticBookTests.swift`

**Interfaces:**
- Produces:
  - `public struct RemoteCardRef: Equatable, Sendable { externalID: String; etag: String? }`
  - `public struct RemoteCardChanges: Sendable { cards: [RemoteCard]; removedExternalIDs: [String]; cursor: Data?; full: Bool }`
  - `public struct PersonBookCapabilities: Equatable, Sendable { acceptsOrganizations: Bool; requiresPhoneOrPeer: Bool; supportsMarker: Bool }`
  - `public protocol PersonBookAdapter: Sendable { var capabilities: PersonBookCapabilities { get async }; func changes(cursor: Data?) async throws -> RemoteCardChanges; func create(_ card: PersonCard) async throws -> RemoteCardRef; func update(externalID: String, etag: String?, card: PersonCard) async throws -> RemoteCardRef; func delete(externalID: String, etag: String?) async throws; func find(makoshID: UUID) async throws -> RemoteCardRef? }`
  - `public actor PersonSyntheticBook: PersonBookAdapter { public init(cards: [RemoteCard] = [], capabilities: PersonBookCapabilities = .init(acceptsOrganizations: true, requiresPhoneOrPeer: false, supportsMarker: true)); public func failNext(_ failure: PersonsFailure, applying: Bool = true); public func editRemotely(externalID: String, _ change: (inout ImportedPerson) -> Void); public func removeRemotely(externalID:); public private(set) var writes: [String] }` — ETag растёт при каждой записи; `update` с чужим `etag` → `PersonsFailure.preconditionFailed`.

- [ ] **Step 1: Tests** — `testCreateUpdateDeleteAndFind`, `testFailNextAppliesThenThrows` (карточка создана, брошено `unknownOutcome`, `find(makoshID:)` её находит), `testStaleEtagIsPreconditionFailed`, `testChangesAfterCursorAreIncremental`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Define the person book adapter and a synthetic book"`

### Task 7: Движок адресной книги (чистый)

**Files:**
- Create: `Sources/MakoshPersons/AddressBookEngine.swift`
- Test: `Tests/MakoshPersonsTests/AddressBookEngineTests.swift`

**Interfaces:**
- Produces:
  - `public struct DesiredCard: Equatable, Sendable { personID: UUID; bookID: UUID; card: PersonCard; bookExternalID: String? }` — `bookExternalID` — `externalID` identity персоны в этой книге (для Telegram — peer), заполняется из `sourceIdentities`.
  - `public enum PersonWrite: Equatable, Sendable { case create(DesiredCard); case adopt(DesiredCard, externalID: String, etag: String?); case update(DesiredCard, entry: PersonBookEntry); case none }`
  - `public enum AddressBookEngine { public static func desired(persons: [Person], memberships: [PersonMembership], books: [PersonBook], capabilities: [UUID: PersonBookCapabilities], sourceIdentities: [UUID: [ServiceIdentity]]) -> [DesiredCard]; public static func reconcile(desired: [DesiredCard], entries: [PersonBookEntry], remote: [UUID: [RemoteCard]], sourceIdentities: [UUID: [ServiceIdentity]]) -> [PersonWrite]; public static func blockedReasons(persons:, books:, capabilities:) -> [UUID: [UUID: PersonsFailure]] }` — `desired`: активные персоны с `addressBook` × книги `acceptsAddressBook && state == .connected`; организация только в книги с `acceptsOrganizations`; книга с `requiresPhoneOrPeer` — только персоны с телефоном или identity этой книги (иначе причина `noPhoneOrPeer` в `blockedReasons`). `reconcile`: привязка `managed` с тем же `fingerprint` → `.none`; с другим → `.update`; нет привязки → если среди `remote[bookID]` есть карточка с `makoshID == personID` → `.adopt`; иначе если среди `sourceIdentities[personID]` есть identity этой книги (`service == book.kind.service && accountID == book.accountID`) и карточка с `externalID == identity.externalID` есть в `remote` → `.adopt` её; иначе `.create`. Персоны без признака и привязки `notManaged/duplicate/removed` не трогаются.

- [ ] **Step 1: Write the failing tests**

```swift
func testDesiredSkipsOrganizationsForTelegramAndPersonsWithoutPhone() { /* capabilities telegram: requiresPhoneOrPeer, !acceptsOrganizations */ }
func testSourceCardIsAdoptedInsteadOfCreated() {
    // persona identities [google-contacts/subj/people/c1], remote[book] содержит RemoteCard(externalID "people/c1", makoshID nil)
    XCTAssertEqual(writes, [.adopt(desired, externalID: "people/c1", etag: "e1")])
}
func testMarkedCardIsAdoptedByMakoshID() { /* remote card makoshID == personID → adopt */ }
func testChangedFingerprintUpdates() { /* entry.fingerprint != card.fingerprint → .update */ }
func testUnmanagedEntryIsLeftAlone() { /* entry.state == .duplicate → .none, без create */ }
func testBlockedReasonsNamePhoneless() { /* persona без телефона и без telegram identity → [person: [tgBook: .noPhoneOrPeer]] */ }
```

- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Compute desired address-book cards and reconcile them with books"`

### Task 8: Журнал попыток и раннер записи в `PersonsService`

**Files:**
- Create: `Sources/MakoshPersons/PersonsService.swift`, `Sources/MakoshPersons/PersonsService+Writes.swift`
- Test: `Tests/MakoshPersonsTests/PersonsServiceWriteTests.swift`

**Interfaces:**
- Produces:
  - `public actor PersonsService { public typealias AdapterFactory = @Sendable (PersonBook, PersonsCredentialVault) async throws -> any PersonBookAdapter; public init(persons: PersonStore, store: PersonsStore, vault: PersonsCredentialVault, adapterFactory: AdapterFactory, google: GoogleOAuth?, grants: GoogleGrantVault, now: …); public func open() async throws; public func close() async }`
  - `public actor PersonsCredentialVault { init(access: KeychainAccess = .system); savePassword(bookID: UUID, _: String); password(bookID:) -> String?; removePassword(bookID:) }` — сервис `org.makosh.persons.carddav.v1`.
  - `PersonsService.writePass(limitPerBook: Int = 50) async -> PersonsPassReport` — один раннер (`writeTask`, флаг `writeAgain`): собирает `desired` (задача 7) по всем книгам, читает `entries`, для `adopt` использует `remote` из последнего чтения книги (кэш `lastRemote[bookID]`), для каждой `PersonWrite` создаёт попытку `queued`, переводит в `sent`, вызывает адаптер, `confirmed` + `saveEntry(managed, externalID, etag, fingerprint)`; `rejected(code:stage:)` → `rejected`, персона получает событие `bookRejected`; `unknownOutcome` → `unknown`; `preconditionFailed` → попытка `rejected` с причиной `precondition`, книга помечается на перечит; `retryAfter` → `pausedUntil` книги; `signInRequired/noAccess/unreachable` → состояние книги, проход книги останавливается, остальные книги продолжаются. Не больше `limitPerBook` попыток на книгу за проход.
  - `PersonsService.settleUnknown(bookID: UUID) async throws` — для каждой `unknown` попытки книги: `adapter.find(makoshID:)` → найдена → `confirmed` + привязка; не найдена и книга прочитана полностью (`changes(cursor: nil).full`) → попытка `rejected(reason: "not found")`, следующий проход создаст заново; не найдена при неполном чтении — остаётся `unknown`.
  - `PersonsService.dismissAttempt(id: UUID) async throws` — `unknown → rejected` вручную.
  - `PersonsService.deleteEverywhere(personID: UUID) async throws -> [PersonAttempt]` — для каждой привязки `managed`/`duplicate`: попытка `delete`; успех → привязка `removed`; `notFound` у адаптера → тоже `removed` и `confirmed`.
  - `PersonsService.deleteDuplicateEntry(id: UUID) async throws` — одна попытка `delete` для привязки `duplicate`.
  - `PersonsService.mergePersons(survivorID: UUID, removedID: UUID) async throws` — `persons.merge(...)`, затем привязки поглощённой: в книге, где у выжившей уже есть `managed`, → `duplicate` с `personID = survivorID` и `mergedFromPersonID = removedID` (добавить поле в `PersonBookEntry`); где нет — переходят к выжившей как `managed` (карточка будет обновлена отпечатком). `undoMerge(id: UUID) async throws` — `persons.undoMerge`, затем привязки с `mergedFromPersonID` возвращаются к прежней персоне как `managed`. Автосклейка коллектора проходит через `PersonsService.collect` (задача 9), которая делает то же для пар `CollectResult.merged`.
  - `PersonsService.requestWritePass()` — коалесцирует.
  - `public struct PersonsPassReport: Equatable, Sendable { attempted: Int; confirmed: Int; rejected: Int; unknown: Int; deferredBooks: [UUID] }`

- [ ] **Step 1: Write the failing tests**

```swift
func testMergeKeepsOneManagedEntryAndMarksTheOtherDuplicate() async throws { /* обе персоны записаны в книгу → mergePersons → одна managed, одна duplicate с mergedFromPersonID; writePass не создаёт карточек */ }
func testUndoMergeReturnsEntries() async throws { /* undoMerge → обе managed со своими personID */ }
func testFlagCreatesCardsInAcceptingBooksOnly() async throws { /* две книги, одна acceptsAddressBook false → одна попытка confirmed, одна привязка */ }
func testUnknownIsSettledByFindNotResend() async throws {
    await book.failNext(.unknownOutcome(stage: "put"))          // применено, но брошено
    _ = await service.writePass(); XCTAssertEqual(open.first?.state, .unknown)
    try await service.settleUnknown(bookID: id); XCTAssertEqual(attempt.state, .confirmed); XCTAssertEqual(await book.writes.filter { $0.hasPrefix("create") }.count, 1)
}
func testUnknownNotFoundAfterFullReadIsRecreated() async throws { /* failNext(applying: false) → settle → rejected → writePass → create → всего одна карточка */ }
func testLimitPerBookDefersTheRest() async throws { /* 60 персон → 50 попыток, deferredBooks содержит книгу; второй проход — 10 */ }
func testRestartTurnsSentIntoUnknown() async throws { /* saveAttempt(sent) → open() → unknown */ }
func testDeleteEverywhereRemovesOnlyManagedEntries() async throws { /* managed + duplicate удаляются, notManaged — нет */ }
func testSignInRequiredStopsOneBookOnly() async throws { /* книга A failNext(.signInRequired) → state needsSignIn, книга B записана */ }
```

- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Write address-book cards through journaled attempts"`

### Task 9: Чтение книг, обход и внешние правки

**Files:**
- Create: `Sources/MakoshPersons/PersonsService+Books.swift`
- Test: `Tests/MakoshPersonsTests/PersonsServiceReadTests.swift`

**Interfaces:**
- Produces:
  - `PersonsService.readBook(id: UUID) async throws -> CollectResult` — `adapter.changes(cursor:)`; каждая карточка → `PersonSourceObservation(source: book.source, person: imported(externalID), evidence: .book)` в коллектор (`addressBookSource` = `book.source`, если `isAddressBookSource`); карточки с `makoshID` или привязкой `managed`: сравнить `imported` с текущей персоной — значения списков, которых нет в карточке, но есть у персоны и которые были в последней отправленной карточке (отпечаток хранится вместе с набором отправленных значений в `PersonBookEntry.sentValues: [String: [String]]`, добавить поле), → `removeValue(.removedInBook(book.source))`; `removedExternalIDs` с привязкой `managed` → привязка `notManaged`, событие `bookCardRemoved` (карточка снаружи удалена пользователем; Makosh не пересоздаёт, пока пользователь не нажмёт «Отправить снова» — моё решение в духе «убранное снаружи — ваша правка»); сохранить `cursor`, `lastRemote[bookID]`; затем `requestWritePass()`.
  - `PersonsService.readAll() async`, `startPolling()` / `stopPolling()` по `preferences.pollIntervalSeconds`, пропуская книги с `pausedUntil` в будущем и `state != .connected`.
  - `PersonsService.connectCardDAV(name: String, server: URL, login: String, password: String) async throws -> PersonBook` (обнаружение `/.well-known/carddav` → principal → `addressbook-home-set`, первая адресная книга), `connectGoogle(openBrowser:) async throws -> PersonBook` (существующее разрешение без области контактов → `signIn(scopes: contacts, loginHint:)`), `connectMacContacts() async throws -> PersonBook`, `connectTelegram(accountID: String, name: String) -> PersonBook`, `connectSynthetic(...)`; `removeBook(id:)` (пароль удаляется первым; привязки → `notManaged`); `setBookOptions(id:, readBook:, isAddressBookSource:, acceptsAddressBook:)` — снятие `isAddressBookSource` → `persons.clearAddressBook(fromSource:)`.
  - `PersonsService.collect(_ observations: [PersonSourceObservation], spam: [MailEvidence] = []) async throws -> CollectResult` — вызывает коллектор (с `addressBookSource` по книге наблюдения), обрабатывает привязки для `merged` (как в `mergePersons`), затем `requestWritePass()`.
  - `PersonsService.resend(entryID: UUID) async throws` — для привязки `notManaged` (карточку удалили снаружи): привязка → `removed`, следующий проход создаёт карточку заново.
  - `PersonsService.snapshot() async throws -> PersonsSnapshot`: `public struct PersonsSnapshot: Equatable, Sendable { books: [PersonBook]; entries: [PersonBookEntry]; openAttempts: [PersonAttempt]; blocked: [UUID: [UUID: PersonsFailure]]; preferences: PersonsPreferences; googleAvailable: Bool }`.

- [ ] **Step 1: Write the failing tests**

```swift
func testBookReadCollectsAndFlagsFromSourceBook() async throws { /* isAddressBookSource → персоны с addressBook true и origin книги */ }
func testPhoneRemovedInBookBecomesFormerAndLeavesOtherBooks() async throws {
    // персона с признаком записана в книги A и B; в A телефон удалён снаружи (editRemotely)
    _ = try await service.readBook(id: a)
    XCTAssertEqual(person.former.map(\.reason), [.removedInBook(bookA.source)])
    _ = await service.writePass()
    XCTAssertFalse(await bookB.card(for: person.id)!.phones.contains("+7…")); XCTAssertEqual(await bookA.writes.count, 1) // в A обратно не пишется
}
func testExternalNameChangeIsAdoptedWhenNotManual() async throws { /* displayName не ручное → меняется → уходит в книгу B */ }
func testRemovedCardBecomesNotManagedWithoutRecreate() async throws { /* removeRemotely → entry.notManaged, writePass не создаёт */ }
func testPollingSkipsPausedAndDisconnectedBooks() async throws { /* reads счётчик синтетики */ }
func testTurningOffSourceFlagClearsOnlyItsPersons() async throws { /* две книги-источника → снятие у одной → флаг остаётся у персон второй и у ручных */ }
```

- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Read address books, adopt external edits and poll"`

### Task 10: Адаптеры CardDAV и Google Contacts

**Files:**
- Create: `Sources/MakoshPersons/CardDAVAdapter.swift`, `Sources/MakoshPersons/CardDAVXML.swift` (копия разборщика `CalDAVXML` с пространством `urn:ietf:params:xml:ns:carddav`), `Sources/MakoshPersons/GoogleContactsAdapter.swift`, `Sources/MakoshPersons/GoogleContactsMapping.swift`
- Test: `Tests/MakoshPersonsTests/CardDAVAdapterTests.swift`, `Tests/MakoshPersonsTests/GoogleContactsAdapterTests.swift`, `Tests/MakoshPersonsTests/StubURLProtocol.swift`

**Interfaces:**
- Produces:
  - `public struct CardDAVAdapter: PersonBookAdapter { init(collection: URL, login: String, password: String, http: ServiceHTTP); static func discover(server: URL, login: String, password: String, http: ServiceHTTP) async throws -> [RemoteCollection] }` — `PROPFIND` `current-user-principal` → `addressbook-home-set` → коллекции с `resourcetype addressbook`; `changes`: `sync-collection` (`sync-token` в `cursor`), иначе `addressbook-query` + сравнение ETag; `create`: `PUT <collection>/<uuid>.vcf` с `If-None-Match: *`; `update`: `PUT` с `If-Match`; `delete`: `DELETE` с `If-Match`; `find(makoshID:)`: `addressbook-query` с фильтром `X-MAKOSH-PERSON` (`prop-filter` + `text-match`), при неподдержке — полный перечит и поиск локально. Capabilities: организации — да, телефон не обязателен, метка — да.
  - `public struct GoogleContactsAdapter: PersonBookAdapter { init(grant: GoogleGrant, oauth: GoogleOAuth, http: ServiceHTTP) }` — `people/me/connections` с `personFields=names,emailAddresses,phoneNumbers,organizations,clientData,metadata`, `requestSyncToken`, `syncToken` в `cursor`, `410` → полный; `createContact`, `updateContact` (`updatePersonFields` тот же список, `etag` в теле), `deleteContact`; `find(makoshID:)` — `people:searchContacts` недоступен для `clientData`, поэтому полный `connections.list` и поиск по `clientData` (моё решение). `GoogleContactsMapping.remoteCard(_ json:) -> RemoteCard`, `body(for card:) -> Data` с `clientData` метки. Capabilities: организации — да (`organizations[0].name`, а для `kind == .organization` — `names.unstructuredName` и тип `organizations.type = "company"`), телефон не обязателен, метка — да.

- [ ] **Step 1: Write the failing tests** (стабы ответов): `testDiscoveryFindsAddressBooks`, `testSyncCollectionUpdatesCursor`, `testFallbackToEtagComparison`, `testCreateUsesIfNoneMatch`, `testUpdateSendsIfMatchAnd412IsPrecondition`, `testFindByMarkerUsesPropFilter`, `testGoogleListMapsCardsAndMarker`, `testGoogle410ForcesFullRead`, `testGoogleCreateSendsClientData`, `testGoogle401IsSignInRequired`, `testErrorsCarryNoBodyOrURL`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Add CardDAV and Google Contacts book adapters"`

### Task 11: Книга macOS и мост Telegram

**Files:**
- Create: `Sources/MakoshPersons/MacContactsAdapter.swift`, `Sources/MakoshPersons/TelegramBookAdapter.swift`
- Test: `Tests/MakoshPersonsTests/TelegramBookAdapterTests.swift`, `Tests/MakoshPersonsTests/MacContactsMappingTests.swift` (только отображение `CNContact` ↔ `PersonCard` на объектах `CNMutableContact` в памяти, без `CNContactStore`)

**Interfaces:**
- Produces:
  - `public protocol TelegramContactsBridge: Sendable { func contacts(accountID: String) async throws -> [RemoteCard]; func addContact(accountID: String, peerID: String?, phone: String?, givenName: String, familyName: String) async throws -> String; func deleteContact(accountID: String, peerID: String) async throws }`
  - `public struct TelegramBookAdapter: PersonBookAdapter { init(accountID: String, bridge: any TelegramContactsBridge) }` — `changes`: полный список всегда (`full: true`, `cursor: nil`), `externalID = peerID`; `create`: по `card` — `peerID` берётся из `card` через расширение `PersonCard.telegramPeerID: String?` (заполняет движок из identity персоны в этой книге; добавить поле `bookExternalID: String?` в `DesiredCard`), иначе телефон → `importContact`; `nil` от моста → `PersonsFailure.notInTelegram`; `update` — тот же `addContactInteractively` (меняет имя); `delete` — `deleteContact`; `find(makoshID:)` → `nil` (без метки; усыновление только по identity). Capabilities: организации — нет, телефон или peer — обязателен, метка — нет.
  - `public struct MacContactsAdapter: PersonBookAdapter { init(store: CNContactStore = CNContactStore()); static func requestAccess() async -> Bool; static var authorizationStatus: CNAuthorizationStatus }` — `changes`: `enumerateContacts` с ключами имени, телефонов, адресов, организации, должности (`full: true`); `externalID = identifier`; `create/update/delete` через `CNSaveRequest`; `find` → `nil`. `public enum MacContactsMapping { static func card(_ contact: CNContact) -> (ImportedPerson, PersonKind); static func apply(_ card: PersonCard, to contact: CNMutableContact) }` — организация → `contactType = .organization`, `organizationName`.
  - `AppDelegate`/бандл: ключ `NSContactsUsageDescription` добавляет план 3.

- [ ] **Step 1: Tests** — `testTelegramCreateUsesPeerWhenKnownElsePhone`, `testTelegramNilPeerIsNotInTelegram`, `testTelegramChangesAreAlwaysFull`, `testMacMappingRoundTripsPersonAndOrganization`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Add the macOS Contacts adapter and the Telegram book bridge"`

### Task 12: Модель раздела

**Files:**
- Create: `Sources/MakoshPersons/Presentation/PersonsWorkspaceModel.swift`, `Sources/MakoshPersons/Presentation/PersonsTree.swift`
- Test: `Tests/MakoshPersonsTests/PersonsTreeTests.swift`, `Tests/MakoshPersonsTests/PersonsWorkspaceModelTests.swift`

**Interfaces:**
- Produces:
  - `package enum PersonsFilter: String, Codable, Sendable { case all, addressBook, deleted, hidden, notSynced, suggested }`
  - `package struct PersonsTreeNode: Identifiable, Equatable, Sendable { id: String; kind: Kind (organization(UUID, count: Int) | person(PersonSummary) | section(String)); children: [PersonsTreeNode] }`
  - `package enum PersonsTree { static func build(summaries: [PersonSummary], organizations: [PersonSummary], memberships: [PersonMembership], expanded: Set<UUID>, filter: PersonsFilter, blocked: Set<UUID>, suggestedPersonIDs: Set<UUID>) -> [PersonsTreeNode] }` — организации по имени, внутри люди по имени (только `confirmed` и `suggested` членства), человек в нескольких организациях показан в каждой, внизу `section("Без организации")`; `addressBook` → только с признаком; `notSynced` → `blocked`; `suggested` → с предложенными членствами.
  - `@MainActor package final class PersonsWorkspaceModel: ObservableObject { init(service: PersonsService, persons: PersonWorkspaceWorker); @Published snapshot: PersonsSnapshot?; @Published tree: [PersonsTreeNode]; @Published filter: PersonsFilter; @Published search: String; @Published selectedID: UUID?; @Published error: String?; func load() async; func refresh() async; func setFilter/search; func toggleExpanded(organizationID:); func setAddressBook(personID:on:) async; func deleteEverywhere(personID:) async; func settle(bookID:) async; func dismiss(attemptID:) async; func bookStates(for personID: UUID) -> [(PersonBook, PersonBookEntry?, PersonAttempt?, PersonsFailure?)]; func mailCount(address: String) async -> Int; func mergePersons(survivorID:removedID:) async; func undoMerge(id:) async; func resend(entryID:) async; func connectCardDAV/connectGoogle/connectMacContacts/removeBook/setBookOptions; func savePreferences }` — читает `summaries(matching:limit: 2000)` и членства через воркер ядра, снимок — через сервис; никакого SQL/сети на главном акторе.

- [ ] **Step 1: Tests** — `testTreeGroupsByOrganizationAndLeavesRest`, `testPersonInTwoOrganizationsAppearsTwice`, `testAddressBookFilterKeepsOrganizationsWithFlaggedMembersOnly`, `testNotSyncedFilterUsesBlocked`; модель: `testLoadBuildsTreeFromWorkerAndService`, `testBookStatesJoinEntriesAttemptsAndBlocked`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Add the persons workspace model and tree"`
