# OSINT-модуль, план 2: интеграция — `MakoshCore`, флажок книги, сервис `OSINTService`, сверка, модель раздела Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Досье принимает предложенные наблюдения OSINT и умеет их принимать/отклонять без автослияния; книги получают флажок «обогащать автоматически»; актор `OSINTService` держит соединение, запускает установщик, выполняет запуски обогащения через журналируемые попытки, закрывает `unknown` чтением, сверкой удаляет скетчи удалённых и поглощённых персон и ставит автоматические запуски с лимитом; `OSINTWorkspaceModel` на MainActor только координирует.

**Architecture:** `OSINTService` — актор с одним последовательным раннером запусков; соединение (`OSINTSSHSession` + `OSINTTunnel` + `FlowsintAPI`) создаётся фабриками, чтобы тесты и QA подставляли синтетику. Сверка — одна функция `reconcile(autoSources:)`, которую зовёт приложение после прохода коллектора и по таймеру; наблюдателей в `MakoshPersons` нет. Ядро расширяется минимально: статус `rejected`, добавление предложенных наблюдений, принятие с проверкой дублей.

**Tech Stack:** Swift 6, `MakoshCore.PersonStore`, `MakoshOSINT` из плана 1, XCTest на реальном PostgreSQL (`makosh_test_` схемы).

**Spec:** `docs/superpowers/specs/2026-11-09-persons-osint-design.md`; ядро модуля — `docs/superpowers/plans/2026-11-09-persons-osint-1-core.md`.

## Global Constraints

- Всё из Global Constraints плана 1.
- Наблюдения OSINT — только `.proposed`; принятие — действие пользователя: адрес, телефон или username становятся ручным значением списка и `confirmed`, остальные поля — `confirmed` на месте; `rejected` скрыто и больше не предлагается для той же пары (поле, значение). Автослияние по OSINT не срабатывает: точное совпадение принимаемого значения с другой персоной возвращает `duplicateOf`, значение не применяется.
- Входные данные запуска — текущие значения досье (адреса, телефоны, username, отображаемое имя или название организации); заметки, метки, должность, организация человека не отправляются.
- Один запуск одновременно; автоматические не обгоняют ручной; не больше 200 новых наблюдений за запуск; опрос задачи каждые 3 с, не дольше 10 мин → `unknown`; тело графа до 10 МБ.
- `unknown` закрывается только чтением (`sketches`, `graph`, `sketch(id:)`, `keys`) или «Отказаться»; повторный `launch` — только новой командой пользователя.
- Автоматический режим: только люди (`kind == .person`), активные, не спам, из источников книг с флажком; персона со скетчем или с запуском за последние 24 ч повторно не ставится; набор — `automaticEnrichers`; лимит `automaticRunsPerHour` (по умолчанию 20); `org_to_domains` и обогатители с ключом автоматически никогда, если пользователь сам не добавил их в автоматический набор.
- Слияние: скетч поглощённой удаляется попыткой `deleteSketch`; удаление персоны и «Удалить везде» — то же; identity `osint/…` не отделяется.
- `MakoshPersons` не импортирует `MakoshOSINT`; `MakoshOSINT` не импортирует `MakoshPersons`.

## Review Focus

1. **Запуск `launch` ушёл, ответа нет, а граф уже пополнился** — после `unknown` сверка читает граф, видит соседей ожидаемого типа и подтверждает попытку; повторного `launch` нет. Тест `testUnknownLaunchIsConfirmedByGraphRead` в задаче 5.
2. **Предложенный адрес совпадает с другой персоной** — «Принять» возвращает `duplicateOf`, адрес не добавлен, персоны не склеены. Тест `testAcceptDuplicateEmailDoesNotMerge` в задаче 1.
3. **Отправитель письма из книги с флажком** — персона только с identity `mail` автоматически не обогащается; персона из CardDAV-книги с флажком — обогащается, организация из той же книги — нет. Тест `testReconcileQueuesOnlyBookPeople` в задаче 5.
4. **Перезапуск Makosh посреди запуска** — запуск `running` и попытки `sent` становятся `unknown`; сверка закрывает их чтением, второй скетч не создаётся. Тест `testRestartMidRunSettlesWithoutDuplicates` в задаче 5.
5. **Персона удалена, пока шёл её запуск** — попытки запуска завершаются, затем сверка удаляет скетч; наблюдения к удалённой персоне не добавляются. Тест `testDeletedPersonGetsNoObservationsAndLosesSketch` в задаче 5.

---

### Task 1: Ядро — статус `rejected`, предложенные наблюдения, принятие

**Files:**
- Modify: `Sources/MakoshCore/Models.swift` (`ObservationStatus.rejected`; `public var isApplied: Bool` у `Observation` — `status == .observed || status == .confirmed`), `Sources/MakoshCore/PersonStore.swift`, `Sources/MakoshCore/PersonReconciliation.swift` (фильтры `status != .proposed` → `isApplied`)
- Test: `Tests/MakoshCoreTests/PersonOSINTObservationTests.swift`

**Interfaces:**
- Produces:
  - `ObservationStatus { observed, proposed, confirmed, rejected }`; `Observation.isApplied`.
  - `PersonStore.addProposedObservations(personID: UUID, _ observations: [Observation]) throws -> Int` — добавляет только те, чьей пары (поле, значение) нет среди `proposed`/`rejected`/применённых наблюдений и текущих значений; добавляет identity наблюдения в `identities`, если её нет; возвращает число добавленных; ревизия растёт.
  - `public enum PersonAcceptOutcome: Equatable, Sendable { case applied, duplicateOf(UUID) }`; `PersonStore.acceptObservation(personID: UUID, observationID: UUID) throws -> PersonAcceptOutcome` — для `emails`/`phones`/`usernames`: нормализованное значение (`PersonMatching`) у другой активной персоны → `.duplicateOf(id)` без изменений; иначе значение добавляется в список как `ManualValue`, статус → `confirmed`, `.applied`; для прочих полей — статус `confirmed`, `.applied`; не `.proposed` → `StoreError.invalid`.
  - `PersonStore.setObservationStatus(... .rejected)` — разрешено из `.proposed` (существующий метод; `rejectProposedObservation` остаётся для прежних вызовов).
  - `PersonStore.removeObservations(personID: UUID, service: String) throws -> Int` — удаляет `proposed` и `rejected` наблюдения с `source.identity.service == service`, `confirmed` не трогает; identity этого сервиса уходит в `former` (причина `.detached`, как у `detachIdentity`).
  - `PersonStore.attachIdentity(personID: UUID, _ identity: ServiceIdentity) throws` — добавляет identity, если её нет (no-op иначе), ревизия растёт; сервис зовёт её сразу после подтверждённого `createSketch`, чтобы identity `osint/<сервер>/<скетч>` была и у персоны без находок.
  - `PersonStore.detachIdentity` для `service == "osint"` → `StoreError.invalid("Источник OSINT не отделяется.")`.
  - `merge` не меняется: наблюдения и identity переезжают как сейчас.

- [ ] **Step 1: Write the failing tests** — `testAddProposedSkipsCurrentAndKnownPairs` (текущий адрес, уже предложенный, отклонённый — не добавляются; новый — добавляется, identity появилась), `testAttachIdentityIsIdempotent`, `testAcceptEmailBecomesManualAndConfirmed`, `testAcceptDuplicateEmailDoesNotMerge` (вторая персона с тем же адресом; результат `.duplicateOf`, списки обеих без изменений, `persons()` по-прежнему две), `testAcceptSocialStaysObservationConfirmed`, `testRejectedIsNotReproposed` (после `setObservationStatus(.rejected)` `addProposedObservations` с той же парой возвращает 0), `testReconciliationIgnoresRejected` (значение источника с `rejected` наблюдением не становится текущим само), `testRemoveObservationsKeepsConfirmed`, `testDetachOSINTIdentityIsRefused`, `testOldRowsDecodeWithoutStatus` (JSON без `status` → `.observed`).
- [ ] **Step 2–4:** FAIL → implement → PASS (`scripts/test.sh --filter MakoshCoreTests`; прежнее число тестов ядра сохранено).
- [ ] **Step 5: Commit** — `git commit -m "Let the dossier hold, accept and reject proposed OSINT observations"`

### Task 2: Флажок книги «обогащать автоматически»

**Files:**
- Modify: `Sources/MakoshPersons/PersonsModels.swift` (`PersonBook.enrichAutomatically: Bool`, в `init` параметр `enrichAutomatically: Bool = false`, только для `kind.isBook`; декодирование без поля → `false`), `Sources/MakoshPersons/PersonsService.swift` (`setBookOptions(... enrichAutomatically: Bool? = nil)`), `Sources/MakoshPersons/Presentation/PersonsWorkspaceModel.swift` (тот же параметр у `setBookOptions`)
- Test: `Tests/MakoshPersonsTests/PersonBookEnrichFlagTests.swift`

**Interfaces:**
- Produces: `PersonBook.enrichAutomatically`; `PersonsService.setBookOptions(id:collectConversations:readBook:isAddressBookSource:acceptsAddressBook:enrichAutomatically:)`; `PersonsSnapshot.books` несёт флажок.

- [ ] **Step 1: Write the failing tests** — `testFlagDefaultsFalseAndDecodesOldJSON`, `testChannelBooksNeverCarryFlag` (`mail` с `enrichAutomatically: true` → `false`), `testSetBookOptionsPersistsFlag`.
- [ ] **Step 2–4:** FAIL → implement → PASS (`scripts/test.sh --filter MakoshPersonsTests`).
- [ ] **Step 5: Commit** — `git commit -m "Add the automatic enrichment flag to person books"`

### Task 3: `OSINTService` — соединение, настройки, установка

**Files:**
- Create: `Sources/MakoshOSINT/OSINTService.swift`, `Sources/MakoshOSINT/OSINTService+Connection.swift`
- Test: `Tests/MakoshOSINTTests/OSINTServiceConnectionTests.swift`, `Tests/MakoshOSINTTests/OSINTServiceHarness.swift` (поднимает `OSINTTestDatabase`, `PersonStore`, `OSINTStore`, `OSINTCredentialVault(.memory())`, `OSINTSyntheticSSHServer` со `ScriptedServer` из плана 1, `FlowsintSynthetic`; собирает `OSINTService` с синтетическими фабриками)

**Interfaces:**
- Consumes: план 1 целиком.
- Produces:
  - `public struct OSINTConnectionReport: Equatable, Sendable { fingerprint: String; trusted: Bool; dockerPresent: Bool?; checkedOutSHA: String?; healthy: Bool? }`
  - `OSINTService.setServicePassword(_ password: String) async throws` (сохраняет в Keychain и проверяет `api.login`; провал → `serviceAuthFailed`, пароль всё равно сохранён) и `registerNewServiceUser() async throws` (новый адрес `makosh-osint+<6 hex>@<домен из serviceEmail>`, новый пароль, `register`, `saveSettings`) — восстановление доступа с другого Мака.
  - `public actor OSINTService { public typealias SessionFactory = @Sendable (OSINTSettings, @escaping @Sendable () async throws -> String?) -> OSINTSSHSession; public typealias APIFactory = @Sendable (OSINTTunnel) -> any FlowsintAPI; init(persons: PersonStore, store: OSINTStore, vault: OSINTCredentialVault, sessionFactory: @escaping SessionFactory, apiFactory: @escaping APIFactory, pin: FlowsintPin = .current, scanTimeout: Duration = .seconds(600), pollInterval: Duration = .seconds(3), now: @escaping @Sendable () -> Date = Date.init); static func liveFactories() -> (SessionFactory, APIFactory) (сессия к `settings.host:port`, клиент `FlowsintClient(baseURL: tunnel.baseURL, credentials: служебный пользователь из vault)); func open() async throws (store.open, `markSentAsUnknownOnOpen`, `vault.ensureHMACKey`, `hmacKeyAvailable` в настройки); func close() async; func settings() async throws -> OSINTSettings; func saveSettings(_:) async throws; func saveConnection(host: String, port: Int, login: String, password: String?) async throws (новый хост или логин сбрасывают `hostKeyFingerprint` и закрывают сессию; пароль `nil` сохраняет прежний); func testConnection(onUnknownHostKey: @escaping @Sendable (String) async -> Bool) async throws -> OSINTConnectionReport (подключается; принятый отпечаток сохраняется; `docker version`, `git -C /opt/flowsint rev-parse HEAD`, `api.health()` — каждое отдельно, ошибки в поля `nil`); func install(progress: @escaping @Sendable (OSINTInstall) -> Void) async throws -> OSINTInstall (требует `enabled` и доверенный отпечаток; `FlowsintInstaller`); func servicePassword() async throws -> String? }`
  - Внутреннее `ensureConnected() async throws -> (session: OSINTSSHSession, api: any FlowsintAPI)` — при отсутствии доверенного отпечатка → `hostKeyMismatch`; `!enabled` → `disabled`; `installedSHA == nil` → `notInstalled` (кроме `testConnection` и `install`); туннель на порт 5173 один на сессию; обрыв → пересоздание при следующем вызове.

- [ ] **Step 1: Write the failing tests** — `testSaveConnectionStoresPasswordInVaultOnly` (в `persons_osint_settings` пароля нет, `vault.sshPassword()` есть), `testTestConnectionSavesAcceptedFingerprint`, `testTestConnectionWithDeclinedKeyLeavesNothing`, `testChangedHostResetsFingerprint`, `testInstallRequiresTrustedKeyAndEnabled` (`hostKeyMismatch`, затем `disabled`), `testInstallRecordsVersion` (после `install` `settings.installedSHA == pin.sha`), `testEnrichBeforeInstallIsNotInstalled`, `testOpenMarksSentUnknownAndEnsuresHMAC`, `testSetServicePasswordVerifiesLogin`, `testRegisterNewServiceUserChangesEmail`.
- [ ] **Step 2–4:** FAIL → implement → PASS (`scripts/test.sh --filter MakoshOSINTTests.OSINTServiceConnectionTests`).
- [ ] **Step 5: Commit** — `git commit -m "Manage the OSINT server connection, settings and installation"`

### Task 4: `OSINTService` — запуски обогащения

**Files:**
- Create: `Sources/MakoshOSINT/OSINTService+Runs.swift`
- Test: `Tests/MakoshOSINTTests/OSINTServiceRunTests.swift`

**Interfaces:**
- Produces:
  - `public struct OSINTInput: Codable, Hashable, Sendable { type: FlowsintNodeType; value: String }`
  - `OSINTService.inputs(personID: UUID) async throws -> [OSINTInput]` — из текущих значений: `emails` → `.email` (нижний регистр), `phones` → `.phone` (нормализация `PersonMatching`), `usernames` → `.username`, `displayName` → `.individual` (человек) или `.organization` (организация), пусто — пропуск; порядок стабильный.
  - `OSINTService.enrich(personID: UUID, enrichers: Set<OSINTEnricher>, inputs: [OSINTInput], trigger: OSINTRunTrigger = .manual) async throws -> UUID` — проверяет `enabled`, `installedSHA`, активность персоны (`isActive`, иначе `invalidInput`), ставит `OSINTRun(.queued)` и будит раннер; `inputs` остаются в памяти раннера (в строке запуска их нет).
  - `OSINTService.settled() async` — ждёт пустой очереди (тесты).
  - Раннер (один `Task` на актор): берёт запуски по `createdAt`, `manual` раньше `book`; для каждого: `running` → `createSketch` (если нет `OSINTSketchLink` без `deletedAt`: попытка `queued → sent → confirmed` с `response.sketchID`, `saveSketch`, `persons.attachIdentity(personID, OSINTGraphMapping.identity(serverID:sketchID:))`) → читает граф один раз, строит карту «тип+HMAC → nodeID» → `addNode` на каждый вход, которого нет в карте (попытка с `payload.nodeType`, `valueHMAC`) → `launch` на каждую пару (узел, совместимый обогатитель из `enrichers`; обогатители с `requiredKey` пропускаются, если имени ключа нет в последнем `keys()`), попытка с `payload.enricher`, `inputNodeID`, ответ `scanID` → опрос `scan(id:)` всех задач раз в `pollInterval` до `completed`/`failed`/`scanTimeout` (`failed` → `rejected` попытки; таймаут → `unknown`) → `graph(sketchID:)` → `OSINTGraphMapping.observations(…)` → `persons.addProposedObservations` → `run.found`, `truncated`, `state = completed` (если все попытки `confirmed`/`rejected`) или `unknown` (есть `unknown`); любая `apiRejected`/`invalidResponse`/`tooLarge` на этапе до `launch` → `run.failed` с кодом; `unknownOutcome` на записи → попытка `unknown`, запуск продолжает остальные входы и завершается `unknown`.
  - `OSINTService.lastRun(personID:)`, `attempts(runID:)` — чтение для модели.

- [ ] **Step 1: Write the failing tests** (синтетика с находками для Анны: адрес → Gravatar и утечка, username → два соцаккаунта, телефон → оператор) — `testInputsComeFromCurrentValuesOnly` (прежние и предложенные значения не входят; заметки нет), `testManualRunCreatesSketchNodesLaunchesAndProposes` (один `createSketch`, по `addNode` на вход, `launch` только для совместимых пар, у Анны пять предложенных наблюдений со статусом `.proposed` и identity `osint/<server>/<sketch>`, `run.completed`, `found == 5`), `testSecondRunReusesSketchAndNodes` (второй запуск: `createSketch` нет, `addNode` только для нового телефона), `testKeyedEnricherSkippedWithoutKey` (`emailToBreaches` без `HIBP_API_KEY` не запускается; с ключом в `keys()` — запускается), `testFailedScanRejectsAttemptRunCompletes`, `testHungScanTimesOutToUnknown` (`scanTimeout` 1 с → попытка и запуск `unknown`, повторного `launch` нет), `testUnknownOutcomeOnAddNodeKeepsGoing`, `testManualRunsPrecedeBookRuns`, `testLimitTruncatesTo200AndFlags`, `testNoRawValuesInRunOrAttemptRows` (строки таблиц не содержат адреса и телефона Анны).
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Run OSINT enrichment through journaled attempts and propose the findings"`

### Task 5: `OSINTService` — закрытие `unknown`, сверка, автоматический режим, удаление

**Files:**
- Create: `Sources/MakoshOSINT/OSINTService+Reconcile.swift`
- Test: `Tests/MakoshOSINTTests/OSINTServiceReconcileTests.swift`

**Interfaces:**
- Produces:
  - `OSINTService.settle(attemptID: UUID) async throws` — по виду: `createSketch` → `sketches(investigationID:)` с `title == personID` → `confirmed` + `saveSketch`; `addNode` → `graph` и узел с `nodeType` и `hmac(primary) == valueHMAC` (без ключа HMAC — остаётся `unknown`); `launch` → `graph`: у `inputNodeID` есть сосед типа, который даёт этот обогатитель → `confirmed`; `deleteSketch` → `sketch(id:) == nil` → `confirmed` и `deletedAt` у ссылки; `createKey`/`deleteKey` → `keys()`; ничего не найдено — остаётся `unknown`. После закрытия всех попыток запуска он становится `completed` (и, если `readGraph` ещё не делался, выполняется) или остаётся `unknown`.
  - `OSINTService.dismiss(attemptID: UUID) async throws` — `unknown → rejected`; запуск без открытых попыток → `failed(unknownOutcome)`.
  - `OSINTService.reconcile(autoSources: [ImportSource]) async` — (0) `queued` запуски `.book(source)` с `source ∉ autoSources` → `failed(disabled)`; (1) `settle` для каждой открытой `unknown` попытки; (2) для каждой ссылки без `deletedAt`: персоны нет или `deletedAt != nil` → попытка `deleteSketch` (если открытой такой нет); (3) если `enabled` и `installedSHA`: активные люди с identity из `autoSources`, без ссылки и без запуска за 24 ч → `enrich(trigger: .book(source), enrichers: automaticEnrichers, inputs: inputs(personID:))`, пока `automaticRunCount(since: now − 1 ч) < automaticRunsPerHour`; ошибки сверки не бросаются, пишутся в `lastFailure` снимка.
  - `OSINTService.deleteOSINTData(personID: UUID) async throws` — попытка `deleteSketch` (если ссылка есть) и `persons.removeObservations(personID:, service: "osint")`.
  - `OSINTService.cancelQueuedAutomaticRuns()` — зовётся при выключении модуля или флажка: `queued` запуски с `trigger: .book` → `failed(disabled)`.

- [ ] **Step 1: Write the failing tests** — `testUnknownLaunchIsConfirmedByGraphRead` (`failNext(unknownOutcome, "launch")`: попытка `unknown`, `recordedLaunches.count == 1`; `reconcile` → `confirmed`, наблюдения добавлены, `recordedLaunches.count == 1`), `testUnknownCreateSketchFoundByTitle`, `testUnknownAddNodeWithoutHMACStaysUnknown`, `testDismissRejectsAndFailsRun`, `testRestartMidRunSettlesWithoutDuplicates` (закрыть сервис после `sent`; новый сервис на той же схеме: `open` → `unknown`; `reconcile` → один скетч, `sketches().count == 1`), `testDeletedPersonGetsNoObservationsAndLosesSketch` (`persons.deletePerson` во время опроса; запуск завершается без `addProposedObservations`; `reconcile` → `deleteSketch` подтверждена, `deletedAt` у ссылки), `testMergedPersonSketchIsDeleted` (`persons.merge`; у выжившей свой скетч остаётся), `testReconcileQueuesOnlyBookPeople` (три персоны: человек из `carddav/acc`, организация из `carddav/acc`, человек только из `mail/acc`; `autoSources = [carddav/acc]` → один запуск `book`, набор `automaticDefault`, без `orgToDomains`), `testReconcileRespectsHourlyLimit` (лимит 2, пять кандидатов → два запуска; через час — ещё два), `testReconcileSkipsPersonsWithRecentRun`, `testReconcileCancelsQueuedRunsOfUnflaggedBooks`, `testDeleteOSINTDataRemovesProposedKeepsConfirmed`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Settle unknown OSINT attempts by reading and reconcile sketches and automatic runs"`

### Task 6: `OSINTService` — ключи, принятие, снимок, ссылка на граф

**Files:**
- Create: `Sources/MakoshOSINT/OSINTService+Keys.swift`, `Sources/MakoshOSINT/OSINTSnapshot.swift`
- Test: `Tests/MakoshOSINTTests/OSINTServiceKeysTests.swift`

**Interfaces:**
- Produces:
  - `public struct OSINTSnapshot: Equatable, Sendable { settings: OSINTSettings; connected: Bool; openAttempts: [OSINTAttempt]; lastRuns: [UUID: OSINTRun]; sketches: [UUID: OSINTSketchLink]; serverKeyNames: Set<String>; lastInstall: OSINTInstall?; installing: Bool; lastFailure: OSINTFailure? }`
  - `OSINTService.snapshot() async throws -> OSINTSnapshot`; `refreshKeys() async throws` (читает `keys()` и кэширует имена); `setKey(name: String, value: String) async throws` (имя из `OSINTEnricher.knownKeys`, иначе `invalidInput`; `vault.saveKey`; если имя уже на сервере — попытка `deleteKey` по id, затем попытка `createKey`; `unknown` закрывает `settle`); `removeKey(name:) async throws` (попытка `deleteKey` + `vault.removeKey`); `acceptObservation(personID:observationID:) async throws -> PersonAcceptOutcome`; `rejectObservation(personID:observationID:) async throws` (`setObservationStatus(.rejected)`); `graphURL(personID: UUID) async throws -> URL?` (`tunnel.baseURL` + путь скетча во фронтенде flowsint — исполнитель берёт его из `flowsint-app/src/routeTree.gen.ts` архива; nil без ссылки или без соединения).

- [ ] **Step 1: Write the failing tests** — `testSetKeyStoresValueInVaultAndNameOnServer` (значение в `vault.key(name:)`, в таблицах и снимке только имя), `testSetKeyReplacesExisting` (`deleteKey` затем `createKey`), `testUnknownKeyNameIsInvalidInput`, `testRemoveKeyDeletesBoth`, `testAcceptAndRejectPassThrough`, `testSnapshotCarriesOpenAttemptsAndLastRuns`, `testGraphURLNilWithoutSketch`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Manage flowsint API keys and expose the OSINT snapshot"`

### Task 7: Модель раздела `OSINTWorkspaceModel`

**Files:**
- Create: `Sources/MakoshOSINT/Presentation/OSINTWorkspaceModel.swift`, `Sources/MakoshOSINT/Presentation/OSINTCardGrouping.swift`
- Test: `Tests/MakoshOSINTTests/OSINTWorkspaceModelTests.swift`, `Tests/MakoshOSINTTests/OSINTCardGroupingTests.swift`

**Interfaces:**
- Produces:
  - `public enum OSINTCardGroup: String, CaseIterable, Sendable { case contacts, social, breaches, phone, domains, avatar, organizations }` с `title: String` («Адреса и телефоны», «Соцсети», «Утечки», «Телефон», «Домены», «Аватар», «Организации»); `public struct OSINTCardItem: Identifiable, Equatable, Sendable { id: UUID; group: OSINTCardGroup; title: String; value: String; status: ObservationStatus; fetchedAt: Date; formerlyRemoved: Bool }`; `public enum OSINTCardGrouping { static func items(for person: Person) -> [OSINTCardItem] }` — только наблюдения с `source.identity.service == "osint"` и статусом `proposed`/`confirmed`; группа по полю (`emails`/`phones`/`usernames` → `contacts`, `social.*` → `social`, `breach` → `breaches`, `phone.info` → `phone`, `domain` → `domains`, `avatar` → `avatar`, `organization.suggested` → `organizations`); `formerlyRemoved` — пара (поле, значение) есть в `person.former`.
  - `@MainActor public final class OSINTWorkspaceModel: ObservableObject { public init(service: OSINTService); @Published public private(set) var snapshot: OSINTSnapshot?; @Published public private(set) var busy: Bool; @Published public var error: String?; @Published public private(set) var installLog: [String] (строки `«<шаг>: <состояние> — <сообщение>»`); @Published public private(set) var pendingFingerprint: String? (ждёт «Доверять»); public func load() async; public func saveConnection(host:port:login:password:) async; public func testConnection() async -> OSINTConnectionReport? (при неизвестном ключе заполняет `pendingFingerprint` и ждёт `trustPendingKey()`/`declinePendingKey()` через `CheckedContinuation`); public func install() async; public func enrich(personID:enrichers:inputs:) async -> Bool; public func inputs(personID:) async -> [OSINTInput]; public func accept(personID:observationID:) async -> PersonAcceptOutcome?; public func reject(personID:observationID:) async; public func settle(attemptID:) async; public func dismiss(attemptID:) async; public func deleteOSINTData(personID:) async; public func setKey(name:value:) async; public func removeKey(name:) async; public func setEnabled(_:) async (при `false` зовёт `cancelQueuedAutomaticRuns()`); public func setEnricherSets(manual:automatic:) async; public func setServicePassword(_:) async -> Bool; public func registerNewServiceUser() async -> Bool; public func graphURL(personID:) async -> URL?; public func servicePassword() async -> String? }` — все вызовы сервиса через `await`, ошибки → `error` русским текстом по `OSINTFailure.code`.

- [ ] **Step 1: Write the failing tests** — `OSINTCardGroupingTests`: `testGroupsByFieldPrefix`, `testRejectedAndForeignObservationsExcluded`, `testFormerlyRemovedFlag`; `OSINTWorkspaceModelTests`: `testLoadFillsSnapshot`, `testTestConnectionWaitsForTrustDecision` (ключ появляется в `pendingFingerprint`, после `trustPendingKey()` отчёт `trusted == true`), `testInstallAppendsLogLines`, `testErrorsAreHumanReadable` (`notInstalled` → «Модуль не установлен…»).
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Add the OSINT workspace model and card grouping"`

### Task 8: Проверка плана

- [ ] **Step 1:** `scripts/test.sh --filter MakoshOSINTTests`, `--filter MakoshCoreTests`, `--filter MakoshPersonsTests` → PASS; `scripts/format.sh HEAD`.
- [ ] **Step 2:** `scripts/build-app.sh` → exit 0.
- [ ] **Step 3:** `docs/development-status.md`: раздел «OSINT-модуль — план 2» с числами тестов.
- [ ] **Step 4: Commit** — `git commit -m "Record the OSINT service plan results"`
