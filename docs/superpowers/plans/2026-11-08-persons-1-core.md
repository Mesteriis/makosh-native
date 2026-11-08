# Персоны, план 1: ядро (переименование, модель персоны, хранилище v3, организации, склейка) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Нынешнее досье контактов в `MakoshCore` становится хранилищем персон: вид (человек/организация), структурное имя, признак «адресная книга», прежние значения, ручные значения списков, членства в организациях, индекс нормализованных значений, автосклейка с «отделить источник» и «не склеивать», мягкое удаление и скрытие спама — с переходом хранилища 2 → 3 в месте, без сети и без UI.

**Architecture:** Переименование `Contact*` → `Person*` ведёт компилятор; затем модель расширяется полями с умолчаниями при декодировании, а `PersonRecordRepository` поднимает версию `contact_store_meta` до 3 одной транзакцией под advisory lock схемы. Правила provenance остаются чистыми функциями в `PersonReconciliation`; новые таблицы (членства, значения, пары «не склеивать», почтовые счётчики) — обычные колонки с индексами рядом с JSONB-записями. Автосклейка — функция хранилища, которую вызывает коллектор плана 2.

**Tech Stack:** Swift 6 strict concurrency, Foundation, `MakoshCore.PostgresConnection`, XCTest на реальном PostgreSQL (`PostgresTestDatabase`, `MAKOSH_TEST_DATABASE_URL`).

**Spec:** `docs/superpowers/specs/2026-11-08-persons-design.md`

Планы 2 (`2026-11-08-persons-2-sync.md`) и 3 (`2026-11-08-persons-3-interface.md`) строятся на интерфейсах этого плана.

## Global Constraints

- macOS 26+, Apple Silicon, Swift 6 strict concurrency; `swift-tools-version: 6.2`.
- Identity — `ServiceIdentity(service, accountID, externalID)`, равенство по точным байтам UTF-8; ключ хранения — base64 компонентов через `.`.
- Нынешние таблицы остаются с именами `contact_records`, `contact_merges`, `contact_source_fetches`, `contact_store_meta`; версия хранилища — 3; версии 1 и ≥ 4 отвергаются на открытии и в каждой операции, как сейчас.
- Каждая мутация — одна транзакция под `pg_advisory_xact_lock(hashtext('makosh-contacts'), hashtext(schema))`; запись трогает только изменённые строки.
- Наблюдения, заметки, события — append-only; значения не стираются, а переходят в `former`; источники только добавляют.
- Ручные скаляры блокируют источник целиком (`manualFields`); ручные значения списков — поштучно (`manualValues`); убранное пользователем значение источник не возвращает.
- Автосклейка: только человек с человеком и организация с организацией; только по точному нормализованному телефону или адресу; не по ролевым адресам и не по значению у трёх и более персон; не для пар «не склеивать»; не для удалённых и скрытых; одно слияние на персону за вызов.
- Общие домены (встроенный стоп-список) организацией не становятся; домен становится организацией только при двух и более разных собранных адресах.
- Ошибки хранилища — `StoreError` без DSN, паролей и путей.
- UI-строки и документация — по-русски; код, имена файлов и типов — по-английски.
- Форматировать только изменённые файлы: `scripts/format.sh HEAD`.
- Коммиты заканчиваются строкой `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Review Focus

1. **Переход 2 → 3 на реальных записях** — запись v2 с `manualFields = {phones}` и двумя телефонами после открытия v3 имеет оба телефона в `manualValues`, `phones` отсутствует в `manualFields`, `kind = .person`, `addressBook = false`; повторное открытие ничего не меняет. Тест в задаче 3.
2. **Источник присылает убранное значение** — телефон, убранный пользователем, после повторного импорта остаётся в `former`, наблюдение записано, `phones` без него. Тест в задаче 4.
3. **Отделение после правки** — персона отредактирована после автосклейки; «Отделить источник» всё равно работает и создаёт пару «не склеивать», так что следующий `autoMergeCandidate` их не предлагает. Тест в задаче 5.
4. **Ролевой адрес у двух персон** — `info@firm.ru` у двух разных людей не даёт `autoMergeCandidate`, но даёт `duplicateCandidates` с причиной «Совпадает email». Тест в задаче 7.
5. **Удалённая персона получает письмо** — наблюдение по её identity пишется в неё, новая персона не создаётся, в списке живых её нет. Тест в задаче 8.

---

### Task 1: Переименование Contact → Person

**Files:**
- Rename: `Sources/MakoshCore/ContactStore.swift` → `PersonStore.swift`, `ContactReconciliation.swift` → `PersonReconciliation.swift`, `ContactRecordRepository.swift` → `PersonRecordRepository.swift`, `ContactWorkspaceWorker.swift` → `PersonWorkspaceWorker.swift`
- Rename: `Sources/MakoshApp/Contacts/` → `Sources/MakoshApp/Persons/`
- Modify: все файлы `Sources/` и `Tests/`, где встречаются переименованные типы (15 исходных файлов вне Core, тесты `Tests/MakoshCoreTests/Contact*`, `Tests/MakoshTelegramTests/WorkspaceModelTests.swift` и др.)
- Rename tests: `Tests/MakoshCoreTests/ContactStoreTests.swift` → `PersonStoreTests.swift`, `ContactIdentityLinkTests.swift` → `PersonIdentityLinkTests.swift`, `ContactAIAccessTests.swift` → `PersonAIAccessTests.swift`, `ContactWorkspaceWorkerTests.swift` → `PersonWorkspaceWorkerTests.swift`

**Interfaces:**
- Produces (только имена, поведение прежнее):
  - `Contact` → `Person`, `ContactDraft` → `PersonDraft`, `ContactNote` → `PersonNote`, `ContactEvent` → `PersonEvent`, `ImportedContact` → `ImportedPerson`, `ContactStore` → `PersonStore`, `ContactReconciliation` → `PersonReconciliation`, `ContactRecordRepository` → `PersonRecordRepository`, `ContactWorkspaceConfiguration/Snapshot/Opened/Command/WriteResult/Error/Persistence/Worker` → `PersonWorkspace…`, `StoreError.missingContact` → `.missingPerson`.
  - Методы: `contacts()` → `persons()`, `contact(id:)` → `person(id:)`, `createContact` → `createPerson`, `updateContact` → `updatePerson`, `linkImportedContact` → `linkImportedPerson`, `contacts(owning:)` → `persons(owning:)`, `contacts(owningNote:)` → `persons(owningNote:)`; `WorkspaceModel.contacts` → `persons`, `selectContact` → `selectPerson`; `dossierContact` в каналах → `dossierPerson`.
  - Не переименовываются: `AIContactAccess` (термин политики ИИ), JSON-ключ `contacts` в `ImportDocument` (совместимость с `docs/import-format.md`), имена таблиц, строки UI (их меняет план 3), `ImportDocument.contacts` остаётся свойством с тем же JSON-ключом, но типа `[ImportedPerson]`.

- [ ] **Step 1: Run the current suite as the baseline** — `scripts/test.sh --filter MakoshCoreTests` → PASS (записать число тестов).
- [ ] **Step 2: Rename** файлы через `git mv`, типы и методы — поиском по слову с границами (`\bContact\b`, `\bContactDraft\b`, …), затем сборка `swift build` до нуля ошибок. Временных `typealias` не оставлять.
- [ ] **Step 3: Run** — `scripts/test.sh` → то же число тестов PASS, без падений.
- [ ] **Step 4: Format and commit** — `scripts/format.sh HEAD`; `git add -A Sources Tests && git commit -m "Rename the dossier contact types to persons"`

### Task 2: Модель персоны v3

**Files:**
- Modify: `Sources/MakoshCore/Models.swift`
- Test: `Tests/MakoshCoreTests/PersonModelTests.swift`

**Interfaces:**
- Produces:
  - `public enum PersonKind: String, Codable, Sendable { case person, organization }`
  - `public enum AddressBookOrigin: Codable, Equatable, Sendable { case user, sourceAccount(ImportSource) }`
  - `public enum FormerReason: Codable, Equatable, Sendable { case removedByUser, removedInBook(ImportSource), replacedByMerge }`
  - `public struct FormerValue: Codable, Equatable, Sendable { field: String; value: String; since: Date; reason: FormerReason }`
  - `public struct ManualValue: Codable, Hashable, Sendable { field: String; value: String }`
  - `public enum ObservationStatus: String, Codable, Sendable { case observed, proposed, confirmed }`; `Observation.status: ObservationStatus` (умолчание `.observed` при декодировании старых строк).
  - `Person` получает: `kind: PersonKind` (умолчание `.person`), `givenName`, `familyName`, `middleName: String` (умолчание `""`), `usernames: [String]` (умолчание `[]`), `manualValues: Set<ManualValue>` (умолчание `[]`), `former: [FormerValue]` (`[]`), `addressBook: Bool` (`false`), `addressBookOrigin: AddressBookOrigin?` (`nil`), `deletedAt: Date?`, `hiddenAsSpam: Bool` (`false`). Вычисляемые: `isActive: Bool { deletedAt == nil && !hiddenAsSpam }`, `nameParts: (given: String, family: String)` — структурное имя, если задано, иначе `displayName` делится по первому пробелу (до пробела — given, остальное — family; одно слово — given).
  - `PersonDraft` получает `kind`, `givenName`, `familyName`, `middleName`, `usernames`.
  - `ImportedPerson` получает `givenName`, `familyName`, `middleName: String?`, `usernames: [String]` (все опциональны при декодировании).
  - `public struct PersonSummary: Codable, Equatable, Identifiable, Sendable { id: UUID; kind: PersonKind; displayName: String; organization: String; jobTitle: String; firstEmail: String?; firstPhone: String?; addressBook: Bool; isActive: Bool; revision: Int }` и `Person.summary`.
  - Списочные поля перечислены один раз: `public enum PersonListField: String, CaseIterable, Sendable { case phones, emails, usernames, tags }`, `Person.values(_ field: PersonListField) -> [String]` и `Person.setValues(_:for:)`.

- [ ] **Step 1: Write the failing tests**

```swift
func testOldPayloadDecodesWithDefaults() throws {
    let json = Fixture.contactV2JSON  // запись v2: без kind/former/manualValues/addressBook
    let person = try JSONDecoder().decode(Person.self, from: json)
    XCTAssertEqual(person.kind, .person); XCTAssertFalse(person.addressBook); XCTAssertTrue(person.former.isEmpty)
    XCTAssertEqual(person.observations.first?.status, .observed); XCTAssertTrue(person.isActive)
}
func testNamePartsFallBackToDisplayName() {
    XCTAssertEqual(Person(displayName: "Иванов Пётр").nameParts.given, "Иванов")
    XCTAssertEqual(Person(displayName: "Иванов Пётр").nameParts.family, "Пётр")
    XCTAssertEqual(Person(displayName: "Анна").nameParts.family, "")
    var person = Person(displayName: "x"); person.givenName = "Пётр"; person.familyName = "Иванов"
    XCTAssertEqual(person.nameParts.given, "Пётр")
}
func testSummaryCarriesListFirsts() { /* emails ["a@x","b@x"] → firstEmail "a@x"; kind и addressBook совпадают */ }
func testListFieldAccessorsRoundTrip() { /* setValues(["+7"], for: .phones) → values(.phones) == ["+7"] для всех четырёх полей */ }
func testPersonRoundTripsThroughJSON() throws { /* все новые поля заданы → encode → decode → XCTAssertEqual */ }
```

- [ ] **Step 2: Run** — `scripts/test.sh --filter MakoshCoreTests.PersonModelTests` → FAIL (нет полей).
- [ ] **Step 3: Implement** в `Models.swift` (ручной `init(from:)` с `decodeIfPresent` для новых полей, как сейчас для `aiAccess`).
- [ ] **Step 4: Run** → PASS; `scripts/test.sh --filter MakoshCoreTests` → прежние тесты PASS.
- [ ] **Step 5: Commit** — `git commit -m "Extend the person model with kind, former values and the address-book flag"`

### Task 3: Хранилище v3 и переход 2 → 3

**Files:**
- Modify: `Sources/MakoshCore/PersonRecordRepository.swift` (версия 3, новые таблицы, переход), `Sources/MakoshCore/PersonStore.swift` (`persons()` только активные, `allPersons(includingInactive:)`, `summaries(matching:limit:)`)
- Test: `Tests/MakoshCoreTests/PersonStoreMigrationTests.swift`, `Tests/MakoshCoreTests/PostgresTestSupport.swift` (снимок включает новые таблицы)

**Interfaces:**
- Produces:
  - `PersonRecordRepository.schemaVersion = 3`. Открытие при версии 2 выполняет в той же транзакции под `pg_advisory_xact_lock(hashtext('makosh-schema'), …)`: для каждой записи `contact_records` — декодировать (умолчания задачи 2), для каждого поля из `PersonListField`, присутствующего в `manualFields`, перенести все текущие значения в `manualValues` и удалить поле из `manualFields`; записать обратно; `UPDATE contact_store_meta SET schema_version=3`. Версия 1 → `StoreError.unsupportedSchema(1)`; ≥ 4 — как сейчас.
  - Новые таблицы (создаются в той же инициализации):
    - `person_memberships (id UUID PK, organization_id UUID NOT NULL, person_id UUID NOT NULL, payload JSONB NOT NULL)` + индексы по `organization_id` и `person_id`;
    - `person_values (person_id UUID, field TEXT, normalized TEXT, raw TEXT, PRIMARY KEY (person_id, field, normalized))` + индекс `(field, normalized)`;
    - `person_no_merge (first_id UUID, second_id UUID, PRIMARY KEY (first_id, second_id))` — `first_id < second_id` по строке UUID;
    - `person_mail_evidence (account_id TEXT, address TEXT, clean_count INTEGER NOT NULL, spam_count INTEGER NOT NULL, PRIMARY KEY (account_id, address))`.
  - `PersonStore.persons() -> [Person]` — только `isActive`, сортировка прежняя; `allPersons(includingInactive: Bool) -> [Person]`; `summaries(matching query: String, limit: Int) -> [PersonSummary]` — активные, фильтр по имени, компании, должности, адресам, телефонам, username без учёта регистра (`query` пустой — все), сортировка по имени, `limit` ≤ 2000.
  - `PostgresTestDatabase.contactStoreSnapshot()` включает `person_memberships`, `person_values`, `person_no_merge`, `person_mail_evidence`.

- [ ] **Step 1: Write the failing tests**

```swift
func testOpeningVersionTwoUpgradesManualListsAndVersion() throws {
    try database.execute("UPDATE contact_store_meta SET schema_version=2 WHERE id=1")
    try database.execute("INSERT INTO contact_records (id, payload) VALUES ('\(id)', '\(Fixture.contactV2JSON(manualFields: ["phones","displayName"], phones: ["+7 1","+7 2"]))')")
    let store = try database.makeStore()
    let person = try XCTUnwrap(try store.person(id: id))
    XCTAssertEqual(person.manualValues, [ManualValue(field: "phones", value: "+7 1"), ManualValue(field: "phones", value: "+7 2")])
    XCTAssertEqual(person.manualFields, ["displayName"])
    XCTAssertEqual(try database.execute("SELECT schema_version::text FROM contact_store_meta").first?.first, "3")
    let before = try database.contactStoreSnapshot(); _ = try database.makeStore(); XCTAssertEqual(try database.contactStoreSnapshot(), before)
}
func testVersionOneIsRefused() throws { /* set 1 → makeStore throws unsupportedSchema(1) */ }
func testFutureSchemaFailsClosedWithoutWritingState() throws { /* перенести из PersonStoreTests с версией 4 */ }
func testPersonsHidesInactiveButAllPersonsShowsThem() throws { /* deletedAt у одной → persons() без неё, allPersons(includingInactive: true) с ней */ }
func testSummariesMatchAcrossFields() throws { /* "sidorov" находит по адресу, "менедж" — по должности, пустой запрос — все; limit соблюдается */ }
```

- [ ] **Step 2: Run** — `scripts/test.sh --filter MakoshCoreTests.PersonStoreMigrationTests` → FAIL.
- [ ] **Step 3: Implement** переход, таблицы, `summaries`.
- [ ] **Step 4: Run** → PASS; `scripts/test.sh --filter MakoshCoreTests` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Upgrade the person store to version 3 in place"`

### Task 4: Правила provenance v3: ручные значения, прежние значения, статус наблюдения

**Files:**
- Modify: `Sources/MakoshCore/PersonReconciliation.swift`, `Sources/MakoshCore/PersonStore.swift`
- Test: `Tests/MakoshCoreTests/PersonReconciliationTests.swift`

**Interfaces:**
- Produces:
  - `PersonReconciliation.absorb(_ incoming: ImportedPerson, source: SourceStamp, into person: inout Person)`: скаляры — как сейчас (`manualFields`), плюс `givenName`/`familyName`/`middleName`; списки (`PersonListField`) — каждое значение становится наблюдением со `status = .observed`; значение добавляется в текущие, если его нет среди `former` с причиной `.removedByUser` или `.removedInBook`; `manualValues` не трогаются; `usernames` обрабатываются как остальные списки.
  - `PersonReconciliation.apply(_ draft: PersonDraft, to person: inout Person)` и `recordManualChanges(from:person:)` — для списков: значения, которых не было в `before`, становятся `manualValues`; значения, исчезнувшие из списка, уходят в `former(.removedByUser)` и удаляются из `manualValues`; `manualFields` для списков не ставится.
  - `PersonStore.createPerson(draft:) -> UUID` — `manualFields` = скаляры (`displayName`, `givenName`, `familyName`, `middleName`, `organization`, `jobTitle`), все значения списков — `manualValues`; `kind` из черновика.
  - `PersonStore.updatePerson(id:draft:)` — по правилам выше; событие `edited`.
  - `PersonStore.removeValue(personID: UUID, field: PersonListField, value: String, reason: FormerReason) throws` — переносит значение в `former` (повтор для уже прежнего — без изменений), убирает из `manualValues`; событие `valueRemoved`.
  - `PersonStore.restoreValue(personID: UUID, field: PersonListField, value: String) throws` — из `former` обратно в текущие как ручное значение; событие `valueRestored`.
  - `PersonStore.setObservationStatus(personID: UUID, observationID: UUID, status: ObservationStatus) throws` — `proposed → confirmed` переносит значение в текущие (списки) или ставит скаляр, если поле не ручное; `proposed → observed` не допускается (`StoreError.invalid`); отклонение — удаление наблюдения `proposed` через `rejectProposedObservation(personID:observationID:)`.

- [ ] **Step 1: Write the failing tests**

```swift
func testImportAddsToManuallyEditedListInsteadOfBeingBlocked() throws {
    let id = try store.createPerson(draft: .init(displayName: "A", phones: ["+7 1"]))
    _ = try store.linkImportedPerson(.init(externalID: "x", displayName: "A", phones: ["+7 2"]), source: src, fetchedAt: t1, contactID: id)
    let person = try XCTUnwrap(try store.person(id: id))
    XCTAssertEqual(person.phones, ["+7 1", "+7 2"]); XCTAssertEqual(person.manualValues, [.init(field: "phones", value: "+7 1")])
}
func testRemovedValueIsNotReturnedBySource() throws {
    // import +7 2 → removeValue(.removedByUser) → import again (t2 > t1) → phones без +7 2, former содержит его, наблюдение с fetchedAt t2
}
func testRemovedInBookKeepsHistoryAndDropsCurrent() throws { /* reason .removedInBook(book) → former.reason == .removedInBook(book) */ }
func testRestoreValueMakesItManual() throws { /* restoreValue → phones содержит, former без него, manualValues содержит */ }
func testDraftRemovingAValueRecordsFormer() throws { /* updatePerson с phones без одного значения → former(.removedByUser) */ }
func testScalarManualFieldsStillBlockImports() throws { /* displayName ручное → импорт не меняет displayName, наблюдение записано */ }
func testProposedObservationIsNotCurrentUntilConfirmed() throws {
    // observation(status: .proposed, field: "emails", value: "p@x") добавлено напрямую через repository.update
    // emails без p@x; setObservationStatus(.confirmed) → emails содержит; rejectProposedObservation удаляет
}
```

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — `scripts/test.sh --filter MakoshCoreTests` → PASS (старые тесты про блокировку списков переписать под новое правило: `PersonStoreTests`, `PersonIdentityLinkTests`).
- [ ] **Step 5: Commit** — `git commit -m "Track manual values and former values per list entry"`

### Task 5: Слияние, принудительное слияние, отделение источника, пары «не склеивать»

**Files:**
- Modify: `Sources/MakoshCore/PersonReconciliation.swift` (`merged` с `former`, `manualValues`, структурным именем, `addressBook`), `Sources/MakoshCore/PersonStore.swift`, `Sources/MakoshCore/PersonRecordRepository.swift` (`person_no_merge`)
- Test: `Tests/MakoshCoreTests/PersonMergeTests.swift`

**Interfaces:**
- Produces:
  - `PersonReconciliation.merged(_ survivor: Person, absorbing removed: Person) -> Person`: как сейчас, плюс объединение `manualValues`, `former` (без дублей), `usernames`; структурное имя — выжившего, пустое берётся у поглощённого; `addressBook = survivor.addressBook || removed.addressBook`, `addressBookOrigin` — выжившего, иначе поглощённого; `kind` — выжившего; `deletedAt = nil`, `hiddenAsSpam = false`, если хотя бы один активен.
  - `PersonStore.merge(survivorID: UUID, removedID: UUID) throws -> UUID` — отказывает при разных `kind` (`StoreError.invalid("Нельзя объединить человека с организацией.")`); иначе без условий (это и есть «принудительно»); членства поглощённого переносятся на выжившего (организации — её члены); событие `merge`.
  - `PersonStore.detachIdentity(personID: UUID, identity: ServiceIdentity) throws -> UUID` — создаёт новую персону того же `kind` с `displayName` из последнего наблюдения `displayName` этого источника (иначе из `identity.externalID`), переносит identity, наблюдения и заметки с этим `source.identity`; значения списков, оставшиеся без наблюдений и не ручные у исходной, уходят из её текущих в новую; исходная сохраняет `manualFields`, `manualValues`, `addressBook`; записывает пару в `person_no_merge`; события `identityDetached` у обеих. Отказ, если identity единственная и у исходной нет ручных полей и других identity (`StoreError.invalid("Нечего отделять: это единственный источник персоны.")`).
  - `PersonStore.noMergePairs() throws -> Set<NoMergePair>`, `public struct NoMergePair: Hashable, Codable, Sendable { first: UUID; second: UUID; init(_ a: UUID, _ b: UUID) }` — упорядочивает по `uuidString`.
  - `PersonStore.undoMerge(id:)` — как сейчас; дополнительно не трогает `person_no_merge`.

- [ ] **Step 1: Write the failing tests**

```swift
func testMergeRefusesDifferentKinds() throws { /* person + organization → StoreError.invalid */ }
func testMergeUnionsFormerManualValuesAndFlag() throws { /* removed.addressBook true → merged true; former обоих; manualValues обоих */ }
func testMergeMovesMembershipsToSurvivor() throws { /* membership(removed → org) → после merge membership(survivor → org) */ }
func testDetachAfterEditMovesSourceAndRecordsNoMerge() throws {
    // две identity (mail, telegram) слиты; updatePerson меняет displayName (ревизия растёт)
    let newID = try store.detachIdentity(personID: id, identity: telegram)
    XCTAssertEqual(try store.person(id: newID)?.identities, [telegram])
    XCTAssertFalse(try store.person(id: id)!.identities.contains(telegram))
    XCTAssertTrue(try store.noMergePairs().contains(NoMergePair(id, newID)))
    XCTAssertEqual(try store.person(id: newID)?.phones, ["+7 tg"])   // значение только телеграм-наблюдения ушло
    XCTAssertEqual(try store.person(id: id)?.phones, ["+7 manual"])  // ручное осталось
}
func testDetachRefusesTheOnlySource() throws { /* одна identity, нет ручных полей → StoreError.invalid */ }
func testUndoMergeStillRequiresUnchangedRevision() throws { /* перенести из PersonStoreTests */ }
```

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Merge any two persons of one kind and detach a source into its own person"`

### Task 6: Организации и членства

**Files:**
- Create: `Sources/MakoshCore/PersonMembership.swift`
- Modify: `Sources/MakoshCore/PersonStore.swift`, `Sources/MakoshCore/PersonRecordRepository.swift`
- Test: `Tests/MakoshCoreTests/PersonMembershipTests.swift`

**Interfaces:**
- Produces:
  - `public enum MembershipOrigin: Codable, Equatable, Sendable { case manual, companyField(ImportSource), emailDomain(String), ai }`
  - `public enum MembershipState: String, Codable, Sendable { case suggested, confirmed, removed }`
  - `public struct PersonMembership: Codable, Equatable, Identifiable, Sendable { id: UUID; organizationID: UUID; personID: UUID; role: String; origin: MembershipOrigin; state: MembershipState; createdAt: Date; updatedAt: Date }`
  - `PersonStore.createOrganization(name: String) throws -> UUID` — `kind = .organization`, `displayName` ручное; событие `created`.
  - `PersonStore.organizations() throws -> [Person]` — активные организации по имени; `organization(named name: String) throws -> Person?` — без учёта регистра и пробелов по краям.
  - `PersonStore.memberships(of personID: UUID) throws -> [PersonMembership]`, `members(of organizationID: UUID) throws -> [PersonMembership]` — без `removed`, если не передан `includingRemoved: true`.
  - `PersonStore.suggestMembership(personID: UUID, organizationID: UUID, role: String, origin: MembershipOrigin) throws -> PersonMembership?` — `nil`, если уже есть членство той же пары в любом состоянии (в том числе `removed` с той же `origin` — «не предлагается снова»); ручная `origin` даёт сразу `confirmed`; организация и персона должны быть `kind` `organization`/`person` соответственно, иначе `StoreError.invalid`.
  - `PersonStore.setMembershipState(id: UUID, state: MembershipState) throws` — `suggested → confirmed | removed`, `confirmed → removed`, `removed → confirmed` (ручное возвращение); иное — `StoreError.invalid`.
  - `PersonStore.setMembershipRole(id: UUID, role: String) throws`.
  - События у персоны: `membershipSuggested`, `membershipConfirmed`, `membershipRemoved` с именем организации в `detail`.

- [ ] **Step 1: Write the failing tests**

```swift
func testManualMembershipIsConfirmedAtOnce() throws { /* origin .manual → state .confirmed; members(of:) содержит */ }
func testSuggestedMembershipIsNotRepeatedAfterRemoval() throws {
    let m = try XCTUnwrap(try store.suggestMembership(personID: p, organizationID: o, role: "", origin: .emailDomain("sidorov.ru")))
    try store.setMembershipState(id: m.id, state: .removed)
    XCTAssertNil(try store.suggestMembership(personID: p, organizationID: o, role: "", origin: .emailDomain("sidorov.ru")))
}
func testMembershipRequiresOrganizationKind() throws { /* organizationID — человек → StoreError.invalid */ }
func testPersonMayBelongToTwoOrganizations() throws { /* две организации → memberships(of:).count == 2 */ }
func testIllegalStateMoveIsRefused() throws { /* confirmed → suggested → invalid */ }
func testOrganizationLookupIgnoresCaseAndSpaces() throws { /* "ИП Сидоров" ↔ " ип сидоров " */ }
```

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Add organizations and memberships to the person store"`

### Task 7: Индекс значений, нормализация и автосклейка

**Files:**
- Create: `Sources/MakoshCore/PersonMatching.swift`
- Modify: `Sources/MakoshCore/PersonStore.swift`, `Sources/MakoshCore/PersonRecordRepository.swift` (`person_values` поддерживается в `insert`/`update`/`delete` записи)
- Test: `Tests/MakoshCoreTests/PersonMatchingTests.swift`

**Interfaces:**
- Produces:
  - `public enum PersonMatching { public static func normalizedPhone(_ value: String) -> String; public static func normalizedEmail(_ value: String) -> String; public static let roleLocalParts: Set<String>; public static func isRoleAddress(_ email: String) -> Bool }` — телефон: только цифры; ведущая `8` при 11 цифрах → `7`; ведущий `+` отбрасывается; меньше 7 цифр → `""` (не индексируется). Адрес: обрезка пробелов, нижний регистр; без `@` → `""`. `roleLocalParts` = `info, office, support, sales, admin, hello, contact, mail, help, team, noreply, no-reply, donotreply, postmaster, mailer-daemon, notifications, bounce`.
  - `person_values` заполняется из `phones` (`field = "phones"`) и `emails` (`field = "emails"`) каждой активной персоны при каждой записи; удалённые/скрытые персоны строк не имеют.
  - `PersonStore.duplicateCandidates() throws -> [DuplicateCandidate]` — переписан на `person_values`: пары активных персон одного `kind` с общим `(field, normalized)`, причины как сейчас; пары «не склеивать» исключаются; результат отсортирован по `firstID`, `secondID`.
  - `PersonStore.autoMergeCandidate(for personID: UUID) throws -> UUID?` — другая активная персона того же `kind`, делящая хотя бы одно `(field, normalized)`, где это значение есть не более чем у двух персон всего, адрес не ролевой, пара не в `person_no_merge`; при нескольких — старшая по `createdAt` события `created` (иначе по `id`); `nil`, если нет.
  - `PersonStore.autoMerge(personID: UUID) throws -> UUID?` — одна попытка: находит кандидата, выживает старшая (по тому же правилу), выполняет `merge`, добавляет событие `autoMerged` с `detail` «Склеено автоматически: совпал телефон +7…» / «…адрес a@x»; возвращает id выжившей или `nil`.

- [ ] **Step 1: Write the failing tests**

```swift
func testPhoneNormalization() {
    XCTAssertEqual(PersonMatching.normalizedPhone("8 (916) 000-00-00"), "79160000000")
    XCTAssertEqual(PersonMatching.normalizedPhone("+7 916 000-00-00"), "79160000000")
    XCTAssertEqual(PersonMatching.normalizedPhone("12345"), "")
}
func testRoleAddressDoesNotAutoMergeButIsADuplicateCandidate() throws {
    // две персоны с info@firm.ru → autoMergeCandidate nil, duplicateCandidates содержит пару с «Совпадает email»
}
func testSharedValueOfThreePersonsDoesNotAutoMerge() throws { /* три персоны с +7 916 0000000 → nil для каждой */ }
func testExactMatchAutoMergesIntoTheOlder() throws {
    let older = try store.createPerson(draft: .init(displayName: "A", phones: ["+7 916 000-00-00"]))
    let newer = try store.linkImportedPerson(.init(externalID: "tg", displayName: "A tg", phones: ["8 916 000 00 00"]), source: tg, fetchedAt: t, contactID: nil)
    XCTAssertEqual(try store.autoMerge(personID: newer), older)
    XCTAssertNil(try store.person(id: newer)); XCTAssertEqual(try store.person(id: older)?.identities.count, 1)
    XCTAssertEqual(try store.person(id: older)?.events.last?.kind, "autoMerged")
}
func testNoMergePairBlocksAutoMerge() throws { /* detachIdentity → совпадение телефона → autoMergeCandidate nil */ }
func testKindMismatchNeverAutoMerges() throws { /* организация и человек с одним адресом → nil */ }
func testValuesIndexFollowsWritesAndDeletion() throws { /* person_values после update/removeValue/deletePerson (задача 8 — здесь проверка только после update) */ }
```

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS (включая прежние тесты `duplicateCandidates`).
- [ ] **Step 5: Commit** — `git commit -m "Index normalized values and merge exact matches automatically"`

### Task 8: Мягкое удаление, скрытие спама, почтовые счётчики, признак

**Files:**
- Modify: `Sources/MakoshCore/PersonStore.swift`, `Sources/MakoshCore/PersonRecordRepository.swift`
- Test: `Tests/MakoshCoreTests/PersonLifecycleTests.swift`

**Interfaces:**
- Produces:
  - `PersonStore.deletePerson(id: UUID) throws` — `deletedAt = now`, `addressBook` не меняется, `person_values` очищаются; событие `deleted`. `restorePerson(id:)` — обратно; событие `restored`.
  - `PersonStore.setHiddenAsSpam(id: UUID, _ hidden: Bool) throws` — то же для `hiddenAsSpam`; событие `hiddenAsSpam` / `unhidden`; при `hidden` все `suggested` членства персоны → `removed`.
  - `PersonStore.recordMailEvidence(accountID: String, address: String, spam: Bool) throws -> (clean: Int, spam: Int)` — инкремент счётчика; `mailEvidence(address: String) throws -> (clean: Int, spam: Int)` — сумма по учётным записям.
  - `PersonStore.setAddressBook(personID: UUID, _ on: Bool, origin: AddressBookOrigin) throws` — `on` ставит флаг и `origin` (пользовательская `origin` перекрывает `sourceAccount`; `sourceAccount` не перекрывает `.user`); `off` снимает флаг и `origin`; отказ для `hiddenAsSpam` (`StoreError.invalid("Персона скрыта как спам.")`); событие `addressBookOn`/`addressBookOff`.
  - `PersonStore.clearAddressBook(fromSource source: ImportSource) throws -> [UUID]` — снимает флаг у персон с `addressBookOrigin == .sourceAccount(source)`; возвращает их id.
  - `linkImportedPerson` и `importDocument`: если identity принадлежит удалённой или скрытой персоне, наблюдение пишется в неё (запись обновляется, `isActive` не меняется); новая персона не создаётся.

- [ ] **Step 1: Write the failing tests**

```swift
func testDeletedPersonKeepsIdentityAndAbsorbsNewObservations() throws {
    try store.deletePerson(id: id)
    let owner = try store.linkImportedPerson(.init(externalID: "a@x", displayName: "A", emails: ["a@x"]), source: mail, fetchedAt: t2, contactID: nil)
    XCTAssertEqual(owner, id); XCTAssertNotNil(try store.person(id: id)?.deletedAt); XCTAssertFalse(try store.persons().contains { $0.id == id })
}
func testDeletedPersonHasNoValueRowsAndNoAutoMerge() throws { /* person_values пусты; другая персона с тем же телефоном → autoMergeCandidate nil */ }
func testHidingAsSpamRemovesSuggestedMembershipsAndBlocksFlag() throws { /* suggested → removed; setAddressBook(true) → invalid */ }
func testMailEvidenceCountsPerAccountAndSumsAcross() throws { /* два аккаунта → (clean 2, spam 1) */ }
func testUserFlagOutlivesSourceFlag() throws {
    try store.setAddressBook(personID: id, true, origin: .sourceAccount(google))
    try store.setAddressBook(personID: id, true, origin: .user)
    XCTAssertEqual(try store.clearAddressBook(fromSource: google), [])          // пользовательский признак не снимается
    XCTAssertTrue(try store.person(id: id)!.addressBook)
}
func testRestoreBringsValuesBack() throws { /* deletePerson → restorePerson → person_values снова заполнены */ }
```

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Soft-delete persons, hide spam-only persons and own the address-book flag"`

### Task 9: Команды и снимок воркера

**Files:**
- Modify: `Sources/MakoshCore/PersonWorkspaceWorker.swift`, `Sources/MakoshApp/Workspace/WorkspaceModel.swift` (только новые методы-обёртки; UI — план 3)
- Test: `Tests/MakoshCoreTests/PersonWorkspaceWorkerTests.swift`, `Tests/MakoshTelegramTests/WorkspaceModelTests.swift`

**Interfaces:**
- Produces:
  - `PersonWorkspaceCommand` получает: `setAddressBook(personID: UUID, on: Bool)` (origin `.user`), `removeValue(personID: UUID, field: PersonListField, value: String)`, `restoreValue(personID:field:value:)`, `detachIdentity(personID: UUID, identity: ServiceIdentity)`, `createOrganization(name: String)`, `suggestMembership(personID: UUID, organizationID: UUID, role: String)` (origin `.manual`), `setMembershipState(id: UUID, state: MembershipState)`, `setMembershipRole(id: UUID, role: String)`, `delete(personID: UUID)`, `restore(personID: UUID)`, `confirmObservation(personID: UUID, observationID: UUID)`, `rejectObservation(personID: UUID, observationID: UUID)`. `merge` остаётся (теперь любое слияние одного вида).
  - `PersonWorkspaceWriteResult.Value` получает соответствующие случаи: `flagSet`, `valueRemoved`, `valueRestored`, `detached(UUID)`, `organizationCreated(UUID)`, `membershipChanged`, `deleted`, `restored`, `observationResolved`.
  - `PersonWorkspaceSnapshot` получает `memberships: [PersonMembership]` (все не-`removed`) и `inactiveCount: Int`; `persons` — активные.
  - `PersonWorkspacePersistence` расширяется новыми методами; `PersonStore` им соответствует.
  - `PersonWorkspaceWorker.summaries(matching: String, limit: Int) throws -> [PersonSummary]`, `person(id: UUID) throws -> Person?`, `persons(owning: ServiceIdentity) throws -> [Person]` — чтение без мутации.
  - `WorkspaceModel`: `setAddressBook(_:personID:) async -> Bool`, `removeValue/restoreValue`, `detachIdentity`, `createOrganization(name:) async -> UUID?`, `suggestMembership`, `setMembershipState`, `deletePerson`, `restorePerson`; `@Published var memberships: [PersonMembership]`.

- [ ] **Step 1: Write the failing tests** — для каждой новой команды в `PersonWorkspaceWorkerTests`: команда проходит до `PersonWorkspacePersistence` (пробник из `WorkspaceModelTests` расширяется записью вызовов), значение результата совпадает, после `database`-ошибки `writesBlocked`; `testSnapshotCarriesMembershipsAndInactiveCount`; в `WorkspaceModelTests` — `testSetAddressBookPublishesSnapshot`, `testDetachSelectsNewPerson`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — `scripts/test.sh` целиком → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Expose person commands and memberships through the workspace worker"`
