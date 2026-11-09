# OSINT-модуль, план 1: ядро `MakoshOSINT` — модели, хранилище, секреты, клиент flowsint, SSH, установщик, отображение графа Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Новый модуль `MakoshOSINT`, который умеет: хранить настройки, запуски, попытки и установки в своих таблицах; держать секреты в Keychain; ходить в REST flowsint через `FlowsintAPI`; держать SSH-сессию с проверкой хост-ключа, exec-каналами и туннелем к `127.0.0.1:5173`; идемпотентно ставить flowsint закреплённой версии; превращать граф скетча в предложенные наблюдения. Без интеграции с персонами (план 2) и без интерфейса (план 3).

**Architecture:** Чистые части (`OSINTGraphMapping`, `FlowsintPin`) отдельно от акторов `OSINTStore` (PostgreSQL), `OSINTCredentialVault` (Keychain), `OSINTSSHSession` (swift-nio-ssh) и `FlowsintInstaller`. Протокол `FlowsintAPI` имеет две реализации: `FlowsintClient` (HTTP через туннель) и `FlowsintSynthetic` (память, для тестов и QA). Все внешние записи — попытки `queued → sent → confirmed | rejected | unknown`; `unknown` закрывает чтение.

**Tech Stack:** Swift 6 strict concurrency, `swift-nio-ssh` 0.15.1 (+ `swift-crypto`, `swift-nio` 2.100.0 уже закреплён), CryptoKit (HMAC), Foundation `URLSession` (стаб `URLProtocol` в тестах), `MakoshGoogle.ServiceHTTP`/`KeychainAccess`, `MakoshCore.PostgresConnection`, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-09-persons-osint-design.md`.

## Global Constraints

- `MakoshOSINT` зависит от `MakoshCore`, `MakoshGoogle` (только `KeychainAccess` и `ServiceHTTP` — моё уточнение спеки: Keychain-доступ уже живёт там и не дублируется), `CPostgres`, `NIOSSH`, `NIO`, `NIOPosix`; не импортирует `MakoshPersons` и модули каналов.
- Таблицы модуля — `persons_osint_*` в схеме приложения; версия в `persons_osint_meta`; `PersonsStoreSchema` их не знает.
- Секреты только в Keychain `org.makosh.osint.v1`: `ssh-password`, `service-password`, `payload-hmac`, `env.AUTH_SECRET`, `env.MASTER_VAULT_KEY_V1`, `env.NEO4J_PASSWORD`, `env.POSTGRES_PASSWORD`, `key.<ИМЯ>`. В PostgreSQL, журнале, ошибках и логах секретов, адресов, телефонов и URL с параметрами нет.
- Ошибки `OSINTFailure`: `disabled`, `notInstalled`, `sshUnreachable`, `sshAuthFailed`, `hostKeyMismatch`, `dockerMissing`, `gitMissing`, `installFailed(stage)`, `healthTimeout`, `serviceAuthFailed`, `apiRejected(code, stage)`, `unknownOutcome(stage)`, `invalidResponse(stage)`, `tooLarge`, `storage`.
- HTTP: 4xx кроме 408/429 → `apiRejected(code:stage:)`; обрыв, таймаут, 5xx, 408 → `unknownOutcome(stage:)`; 429 → `unknownOutcome` (повтор не автоматический); нечитаемый JSON → `invalidResponse(stage:)`; тело больше 10 МБ → `tooLarge`.
- Пин flowsint: репозиторий `https://github.com/reconurge/flowsint`, тег `v1.2.13`, SHA `4c05849bc6ca5055ad187d056ef26e61b3bc2fea`, базовые образы `python:3.12-slim`, `node:24-alpine`, `nginx:1.29-alpine`; образы собираются на сервере из этого коммита; `latest` из GHCR не используется.
- Установщик идемпотентен: шаг пропускается, если состояние уже нужное; `.env` никогда не перезаписывается; sudo на сервере нет; пользователь `makosh` в группе `docker`; каталог `/opt/flowsint` его.
- SSH: аутентификация паролем; хост-ключ при первом подключении подтверждает пользователь (отпечаток `SHA256:<base64>`), дальше сверяется; расхождение — `hostKeyMismatch` без единой команды. Туннель слушает только `127.0.0.1:0`; обратных переадресаций нет.
- Значения в `payload` попыток — только HMAC-SHA256 с ключом `payload-hmac`; без ключа `valueHMAC` отсутствует.
- Ничего не работает на MainActor; обратные вызовы NIO не наследуют изоляцию.

## Review Focus

1. **Хост-ключ сменился между подключениями** — `connect()` бросает `hostKeyMismatch`, ни одна команда не выполнена, пароль не отправлен. Тест `testChangedHostKeyRefusesBeforeAuth` в задаче 5.
2. **Повторный запуск установщика на живой установке** — `.env` не перезаписан, `register` пропущен (вход удался), `build` пропущен (образы есть), все шаги `skipped`/`done`, ничего не сломано. Тест `testRerunOnInstalledServerSkipsEverything` в задаче 6.
3. **Сырые адреса и телефоны в журнале** — JSON любой попытки и установки не содержит исходного значения, даже когда ключа HMAC нет. Тест `testAttemptPayloadNeverStoresRawValues` в задаче 1 и `testEnvStepLeavesNoSecretInSteps` в задаче 6.
4. **Граф с чужими узлами** — узел того же скетча, не связанный ребром с входными узлами персоны, в наблюдения не попадает. Тест `testUnlinkedNodesAreIgnored` в задаче 7.
5. **Сервер отвечает 401 на устаревший токен** — клиент входит заново один раз и повторяет запрос; второй 401 подряд — `serviceAuthFailed`. Тест `testExpiredTokenReloginsOnce` в задаче 3.

---

### Task 1: Модуль, модели, пин и хранилище

**Files:**
- Modify: `Package.swift` (пакет `https://github.com/apple/swift-nio-ssh.git` ревизией тега 0.15.1; цель `MakoshOSINT` с зависимостями `MakoshCore`, `MakoshGoogle`, `CPostgres`, `.product(name: "NIOSSH", package: "swift-nio-ssh")`, `.product(name: "NIO", …)`, `.product(name: "NIOPosix", …)`; тестовая цель `MakoshOSINTTests`: `MakoshOSINT`, `MakoshCore`, `MakoshGoogle`, `CPostgres`)
- Create: `Sources/MakoshOSINT/OSINTModels.swift`, `Sources/MakoshOSINT/OSINTFailure.swift`, `Sources/MakoshOSINT/FlowsintPin.swift`, `Sources/MakoshOSINT/OSINTStore.swift`, `Sources/MakoshOSINT/OSINTStoreSchema.swift`, `Dependencies/Flowsint.lock.json`, `scripts/test-flowsint-pin.py`
- Modify: `references.lock.json` (запись `flowsint`: upstream URL, тег, SHA, роль «исследовательский референс OSINT-модуля»), `THIRD_PARTY_NOTICES.md` (раздел «OSINT module — swift-nio-ssh and the external flowsint server»: `swift-nio-ssh` и `swift-crypto` Apache-2.0 линкуются; flowsint Apache-2.0 не копируется и не линкуется, ставится на отдельный сервер по пину), `scripts/test.sh` (строка `python3 scripts/test-flowsint-pin.py`)
- Test: `Tests/MakoshOSINTTests/OSINTTestDatabase.swift` (копия `PersonsTestDatabase` с `@testable import MakoshOSINT`), `Tests/MakoshOSINTTests/OSINTStoreTests.swift`, `Tests/MakoshOSINTTests/FlowsintPinTests.swift`

**Interfaces:**
- Produces:
  - `public struct FlowsintPin: Codable, Equatable, Sendable { repository: String; tag: String; sha: String; baseImages: [String]; static let current: FlowsintPin }` — константы из Global Constraints; `Dependencies/Flowsint.lock.json` — тот же JSON (`schemaVersion: 1`, `repository`, `tag`, `sha`, `baseImages`, `notes`); `scripts/test-flowsint-pin.py` читает lock и регулярным выражением сверяет `tag`/`sha` со строками `FlowsintPin.swift` (exit 1 при расхождении).
  - `public enum FlowsintNodeType: String, Codable, Sendable, CaseIterable { case email = "Email", phone = "Phone", username = "Username", individual = "Individual", organization = "Organization", socialAccount = "SocialAccount", gravatar = "Gravatar", breach = "Breach", device = "Device", domain = "Domain" }` с `var primaryField: String` (`email`, `number`, `value`, `full_name`, `name`, `id`, `hash`, `name`, `device_id`, `domain`).
  - `public enum OSINTEnricher: String, Codable, Sendable, CaseIterable { case emailToGravatar = "email_to_gravatar", emailToHudsonRock = "email_to_device_hudsonrock", emailToBreaches = "email_to_breaches", phoneToInfos = "phone_to_infos", phoneToCarrier = "phone_to_carrier", usernameToMaigret = "username_to_socials_maigret", individualToUsernameCandidates = "individual_to_username_candidates", orgToDomains = "org_to_domains" }` с `inputType: FlowsintNodeType`, `requiredKey: String?` (`HIBP_API_KEY`, `VERIPHONE_API_KEY`, `WHOXY_API_KEY`, иначе nil), `title: String` (русские названия), `isSlow: Bool` (только Maigret); `static let manualDefault: Set<OSINTEnricher>` (все, кроме требующих ключ), `static let automaticDefault: Set<OSINTEnricher>` (`emailToGravatar`, `emailToHudsonRock`, `phoneToInfos`, `individualToUsernameCandidates`); `static let knownKeys = ["HIBP_API_KEY", "VERIPHONE_API_KEY", "WHOXY_API_KEY"]`.
  - `public struct OSINTSettings: Codable, Equatable, Sendable { enabled: Bool (= false); host: String (= ""); port: Int (= 22); login: String (= ""); hostKeyFingerprint: String?; serverID: UUID; serviceEmail: String (= "makosh-osint@sh-inc.dev"); investigationID: String?; installedTag: String?; installedSHA: String?; installedAt: Date?; imageIDs: [String: String]; envBackupAvailable: Bool (= true); manualEnrichers: Set<OSINTEnricher> (= manualDefault); automaticEnrichers: Set<OSINTEnricher> (= automaticDefault); automaticRunsPerHour: Int (= 20); hmacKeyAvailable: Bool (= true) }`; `init(serverID: UUID = UUID())`.
  - `public enum OSINTRunTrigger: Codable, Equatable, Sendable { case manual; case book(ImportSource) }` с `var key: String` (`manual` / `book:<service>/<accountID>`).
  - `public enum OSINTRunState: String, Codable, Sendable { case queued, running, completed, failed, unknown; var isOpen: Bool }`
  - `public struct OSINTRun: Codable, Equatable, Identifiable, Sendable { id: UUID; personID: UUID; trigger: OSINTRunTrigger; enrichers: Set<OSINTEnricher>; state: OSINTRunState; failure: OSINTFailure?; found: Int (= 0); truncated: Bool (= false); createdAt: Date; startedAt: Date?; finishedAt: Date? }`
  - `public enum OSINTAttemptKind: String, Codable, Sendable { case createSketch, addNode, launch, createKey, deleteKey, deleteSketch }`, `public enum OSINTAttemptState: String, Codable, Sendable { case queued, sent, confirmed, rejected, unknown; var isOpen: Bool }`
  - `public struct OSINTAttemptPayload: Codable, Equatable, Sendable { sketchID: String?; nodeType: FlowsintNodeType?; valueHMAC: String?; enricher: OSINTEnricher?; inputNodeID: String?; keyName: String? }`, `public struct OSINTAttemptResponse: Codable, Equatable, Sendable { sketchID: String?; nodeID: String?; scanID: String?; keyID: String? }`
  - `public struct OSINTAttempt: Codable, Equatable, Identifiable, Sendable { id: UUID; runID: UUID?; personID: UUID?; kind: OSINTAttemptKind; state: OSINTAttemptState; payload: OSINTAttemptPayload; response: OSINTAttemptResponse?; failure: OSINTFailure?; createdAt: Date; updatedAt: Date; resolvedAt: Date?; static func allows(_ from: OSINTAttemptState, _ to: OSINTAttemptState) -> Bool }` — разрешены `queued→sent`, `sent→confirmed|rejected|unknown`, `unknown→confirmed|rejected`, `queued→rejected`.
  - `public enum OSINTInstallStepKind: String, Codable, Sendable, CaseIterable { case connect, docker, checkout, env, override, build, up, register, investigation, record }`, `public enum OSINTInstallStepState: String, Codable, Sendable { case pending, running, done, skipped, failed }`, `public struct OSINTInstallStep: Codable, Equatable, Sendable { kind; state; message: String?; failure: OSINTFailure?; finishedAt: Date? }`
  - `public enum OSINTInstallState: String, Codable, Sendable { case running, completed, failed }`, `public struct OSINTInstall: Codable, Equatable, Identifiable, Sendable { id: UUID; state; targetTag: String; targetSHA: String; steps: [OSINTInstallStep]; createdAt: Date; finishedAt: Date? }`
  - `public struct OSINTSketchLink: Codable, Equatable, Sendable { personID: UUID; sketchID: String; createdAt: Date; deletedAt: Date? }`
  - `public enum OSINTFailure: Error, Codable, Equatable, Sendable` — случаи из Global Constraints; `var code: String` (имя случая для UI).
  - `public actor OSINTStore { init(connectionString: String, schema: String); open() throws; close(); settings() throws -> OSINTSettings; saveSettings(_:) throws; sketch(personID:) throws -> OSINTSketchLink?; sketches() throws -> [OSINTSketchLink]; saveSketch(_:) throws; runs(open: Bool) throws -> [OSINTRun]; run(id:) throws -> OSINTRun?; lastRun(personID:) throws -> OSINTRun?; saveRun(_:) throws; attempts(open: Bool) throws -> [OSINTAttempt]; attempts(runID:) throws -> [OSINTAttempt]; attempt(id:) throws -> OSINTAttempt?; saveAttempt(_:) throws (проверяет `allows`; иначе `OSINTFailure.storage`); markSentAsUnknownOnOpen() throws (попытки `sent` → `unknown`, запуски `running` → `unknown`); installs() throws -> [OSINTInstall]; saveInstall(_:) throws; automaticRunCount(since: Date) throws -> Int; performInTransaction<T>(_:) throws -> T }` — таблицы `persons_osint_meta(id=1, version)`, `persons_osint_settings(id=1, data JSONB)`, `persons_osint_sketches(person_id UUID PK, data JSONB)`, `persons_osint_runs(id UUID PK, person_id UUID, state TEXT, created_at TIMESTAMPTZ, data JSONB)` с индексом `(person_id, created_at)`, `persons_osint_attempts(id UUID PK, run_id UUID NULL, state TEXT, created_at TIMESTAMPTZ, data JSONB)` с индексом `(state, created_at)`, `persons_osint_installs(id UUID PK, created_at TIMESTAMPTZ, data JSONB)`; одна транзакция на метод под `pg_advisory_xact_lock(hashtext('makosh-osint'), hashtext(schema))`; по образцу `PersonsStore`/`PersonsStoreSchema`.

- [ ] **Step 1: Write the failing tests** — `OSINTStoreTests`: `testOpenCreatesTablesAndMeta` (шесть таблиц, `version = 1`), `testSettingsDefaultsAndRoundTrip` (порт 22, `manualEnrichers == manualDefault`, `automaticEnrichers == automaticDefault`, `automaticRunsPerHour == 20`, после `saveSettings` читается то же), `testAttemptTransitionsAreRestricted` (`queued → confirmed` бросает `storage`), `testSentBecomesUnknownOnOpen` (попытка `sent` и запуск `running` после `markSentAsUnknownOnOpen` — `unknown`), `testAttemptPayloadNeverStoresRawValues` (сохранить `addNode` с `valueHMAC = "abc"`; `SELECT data::text FROM persons_osint_attempts` не содержит `"+79990000000"` и `"anna@example.test"` — значения известны только тесту), `testAutomaticRunCountSinceCountsOnlyBookTriggers`, `testLastRunPerPerson`; `FlowsintPinTests`: `testPinMatchesGlobalConstraints` (`FlowsintPin.current.tag == "v1.2.13"`, `sha == "4c05849bc6ca5055ad187d056ef26e61b3bc2fea"`, три базовых образа).
- [ ] **Step 2: Run** — `scripts/test.sh --filter MakoshOSINTTests` → FAIL (цели нет). Также `python3 scripts/test-flowsint-pin.py` → exit 1 (файлов нет).
- [ ] **Step 3: Implement** — `Package.swift`, модели, `FlowsintPin`, `Dependencies/Flowsint.lock.json`, `scripts/test-flowsint-pin.py`, `OSINTStore`, запись в `references.lock.json`, раздел в `THIRD_PARTY_NOTICES.md`, строка в `scripts/test.sh`.
- [ ] **Step 4: Run** — `scripts/test.sh --filter MakoshOSINTTests` → PASS; `python3 scripts/test-flowsint-pin.py` → exit 0; `swift build` → без ошибок (резолв `swift-nio-ssh` и `swift-crypto` удался).
- [ ] **Step 5: Commit** — `git commit -m "Add the MakoshOSINT module with models, the flowsint pin and the store"`

### Task 2: Секреты и HMAC значений

**Files:**
- Create: `Sources/MakoshOSINT/OSINTCredentialVault.swift`
- Test: `Tests/MakoshOSINTTests/OSINTCredentialVaultTests.swift`

**Interfaces:**
- Consumes: `MakoshGoogle.KeychainAccess` (`.system`, `.memory()`).
- Produces: `public actor OSINTCredentialVault { static let service = "org.makosh.osint.v1"; init(access: KeychainAccess = .system); func saveSSHPassword(_:) throws; sshPassword() throws -> String?; saveServicePassword(_:) throws; servicePassword() throws -> String?; saveEnvSecret(name: String, _ value: String) throws; envSecret(name:) throws -> String?; saveKey(name: String, _ value: String) throws; key(name:) throws -> String?; removeKey(name:) throws; ensureHMACKey() throws (создаёт 32 случайных байта в `payload-hmac`, если их нет); hmac(_ value: String) throws -> String? (HMAC-SHA256 через CryptoKit над `value` в нижнем регистре без пробелов; nil, если ключа нет; hex); removeAll() throws }`; пустое значение или управляющие символы — `OSINTFailure.storage`; лимит 16 КБ.

- [ ] **Step 1: Write the failing tests** — `testRoundTripsEachKind` (SSH, служебный, env, ключ API), `testHMACIsStableAndKeyed` (один ключ — одинаковый вывод для `"Anna@Example.test"` и `"anna@example.test"`; другой экземпляр с другим Keychain в памяти даёт другой вывод), `testHMACWithoutKeyIsNil`, `testRejectsControlCharacters`, `testRemoveAllClearsEverything`.
- [ ] **Step 2–4:** FAIL → implement → PASS (`scripts/test.sh --filter MakoshOSINTTests.OSINTCredentialVaultTests`).
- [ ] **Step 5: Commit** — `git commit -m "Keep OSINT secrets in the Keychain and hash journal values with a keyed HMAC"`

### Task 3: Протокол `FlowsintAPI` и REST-клиент

**Files:**
- Create: `Sources/MakoshOSINT/FlowsintAPI.swift` (протокол и модели ответов), `Sources/MakoshOSINT/FlowsintClient.swift`
- Test: `Tests/MakoshOSINTTests/FlowsintClientTests.swift`, `Tests/MakoshOSINTTests/StubURLProtocol.swift` (копия стаба из `MakoshPersonsTests`)

**Interfaces:**
- Produces:
  - `public struct FlowsintSketch: Codable, Equatable, Sendable { id: String; title: String; investigationID: String }`, `public struct FlowsintInvestigation: Codable, Equatable, Sendable { id: String; name: String }`, `public struct FlowsintNode: Codable, Equatable, Sendable { id: String; type: String; label: String; properties: [String: JSONValue]; metadata: [String: JSONValue] }` (`JSONValue` — `public enum JSONValue: Codable, Equatable, Sendable { case string(String), number(Double), bool(Bool), null, array([JSONValue]), object([String: JSONValue]) }` с `var stringValue: String?`), `public struct FlowsintEdge: Codable, Equatable, Sendable { source: String; target: String; label: String }`, `public struct FlowsintGraph: Codable, Equatable, Sendable { nodes: [FlowsintNode]; edges: [FlowsintEdge] }`, `public enum FlowsintScanStatus: String, Codable, Sendable { case pending = "PENDING", running = "RUNNING", completed = "COMPLETED", failed = "FAILED" }`, `public struct FlowsintKey: Codable, Equatable, Sendable { id: String; name: String }`.
  - `public protocol FlowsintAPI: Sendable { func health() async throws -> Bool; func register(email: String, password: String) async throws -> Bool /* false, если уже есть */; func login(email: String, password: String) async throws; func investigations() async throws -> [FlowsintInvestigation]; func createInvestigation(name: String) async throws -> FlowsintInvestigation; func sketches(investigationID: String) async throws -> [FlowsintSketch]; func sketch(id: String) async throws -> FlowsintSketch? /* nil при 404 */; func createSketch(title: String, investigationID: String) async throws -> FlowsintSketch; func deleteSketch(id: String) async throws; func graph(sketchID: String) async throws -> FlowsintGraph; func addNode(sketchID: String, type: FlowsintNodeType, value: String) async throws -> String; func enrichers() async throws -> [String]; func launch(enricher: OSINTEnricher, sketchID: String, nodeIDs: [String]) async throws -> String; func scan(id: String) async throws -> FlowsintScanStatus; func keys() async throws -> [FlowsintKey]; func createKey(name: String, value: String) async throws -> FlowsintKey; func deleteKey(id: String) async throws }`
  - `public final class FlowsintClient: FlowsintAPI, Sendable { init(baseURL: URL, http: ServiceHTTP = ServiceHTTP(), credentials: @escaping @Sendable () async throws -> (email: String, password: String)?) }` — маршруты из спеки (`/api/auth/register`, `/api/auth/token` form-urlencoded `username`/`password`, `/api/investigations`, `/api/investigations/create`, `/api/sketches/create`, `/api/sketches/{id}`, `/api/sketches/{id}/graph`, `/api/sketches/{id}/nodes/add` с телом `{"id": "", "nodeType": type.rawValue, "nodeLabel": value, "nodeProperties": {primaryField: value}, "nodeSize": 1, "nodeColor": null, "nodeIcon": null, "nodeImage": null, "nodeFlag": null, "nodeShape": null, "nodeMetadata": {}, "x": 0, "y": 0}`, `/api/enrichers`, `/api/enrichers/{name}/launch`, `/api/scans/{id}`, `/api/keys`, `/api/keys/create`, `/api/keys/{id}`; `/health` для `health()`); токен в памяти актора-хранителя внутри клиента; 401 → один повторный вход через `credentials` и повтор запроса, второй 401 → `serviceAuthFailed`; `register` при 400/409 с телом про «already» → `false`; стадии — имя операции (`register`, `token`, `createSketch`, `addNode`, `launch`, `scan`, `graph`, `keys`, …); ошибки без тел и URL.

- [ ] **Step 1: Write the failing tests** — `testLoginSendsFormAndStoresBearer` (следующий запрос несёт `Authorization: Bearer …`), `testExpiredTokenReloginsOnce` (401 → `/token` → повтор → 200; при трёх 401 подряд — `serviceAuthFailed`), `testAddNodeBodyUsesPrimaryField` (`Email` → `nodeProperties.email`), `testLaunchReturnsTaskID`, `testScanMapsStatuses`, `testSketch404IsNil`, `testRegisterConflictIsFalse`, `testServerErrorsAreUnknownOutcomeWithStage` (503 на `launch` → `unknownOutcome(stage: "launch")`), `testClientErrorsAreRejectedWithoutBody` (422 с телом `{"detail": "secret"}` → `apiRejected(code: 422, stage:)`, описание ошибки не содержит `secret`), `testGraphOver10MBIsTooLarge`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Talk to flowsint through a typed REST client"`

### Task 4: Синтетический flowsint

**Files:**
- Create: `Sources/MakoshOSINT/FlowsintSynthetic.swift`
- Test: `Tests/MakoshOSINTTests/FlowsintSyntheticTests.swift`

**Interfaces:**
- Produces: `public actor FlowsintSynthetic: FlowsintAPI { public struct Finding: Sendable { enricher: OSINTEnricher; inputType: FlowsintNodeType; inputValue: String; outputType: FlowsintNodeType; outputValue: String; properties: [String: JSONValue]; edgeLabel: String }; init(findings: [Finding] = [], installed: Bool = true); var isInstalled: Bool { get set } (через `setInstalled(_:)`); func failNext(_ failure: OSINTFailure, stage: String) (следующий вызов этой стадии бросает, но действие выполняется, когда `failure` — `unknownOutcome`); func hangScan(id: String) (статус остаётся `RUNNING`); var recordedLaunches: [(enricher: OSINTEnricher, nodeIDs: [String])] { get }; var users: [String] { get } }` — `health()` = `isInstalled`; `launch` ставит задачу `PENDING`, первый `scan(id:)` переводит её в `COMPLETED` и дописывает в граф узлы и рёбра по `findings`, чьи `inputValue` совпадают с входным узлом; узлы с одинаковым типом и первичным полем сливаются; `graph` возвращает всё; `deleteSketch` удаляет; `keys` хранит имена без значений (значения не читаются никем).

- [ ] **Step 1: Write the failing tests** — `testLaunchThenScanAppendsFindings` (Gravatar и утечка для адреса, соцаккаунты для username, ребро от входного узла), `testFailNextUnknownStillApplies` (`createSketch` бросил `unknownOutcome`, а `sketches()` его содержит), `testHungScanStaysRunning`, `testDuplicateNodesMerge`, `testHealthFollowsInstalled`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Add an in-memory flowsint for tests and QA"`

### Task 5: SSH-сессия, туннель и синтетический SSH-сервер

**Files:**
- Create: `Sources/MakoshOSINT/OSINTSSHSession.swift`, `Sources/MakoshOSINT/OSINTTunnel.swift`, `Sources/MakoshOSINT/OSINTSyntheticSSHServer.swift`
- Test: `Tests/MakoshOSINTTests/OSINTSSHSessionTests.swift`

**Interfaces:**
- Produces:
  - `public struct OSINTExecResult: Equatable, Sendable { status: Int32; stdout: String; stderr: String }`
  - `public actor OSINTSSHSession { init(host: String, port: Int, login: String, password: @escaping @Sendable () async throws -> String?, expectedFingerprint: String?, group: EventLoopGroup = .singletonMultiThreadedEventLoopGroup); func connect(onUnknownHostKey: @Sendable (String) async -> Bool) async throws -> String /* отпечаток SHA256:<base64> */; func exec(_ command: String, stdin: Data? = nil, timeout: Duration = .seconds(60), onOutput: (@Sendable (String) -> Void)? = nil) async throws -> OSINTExecResult; func openTunnel(toPort remotePort: Int) async throws -> OSINTTunnel; func close() async; var isConnected: Bool }` — `NIOSSHClientUserAuthenticationDelegate` с паролем; `NIOSSHClientServerAuthenticationDelegate` сверяет отпечаток: при `expectedFingerprint == nil` зовёт `onUnknownHostKey` и продолжает только при `true`, при несовпадении — `hostKeyMismatch` до аутентификации; обрыв/таймаут подключения → `sshUnreachable`; отказ аутентификации → `sshAuthFailed`; exec — дочерний канал `session` с `ExecRequest`, `stdin` пишется и закрывается `EOF`; код завершения из `ExitStatus`.
  - `public final class OSINTTunnel: Sendable { let localPort: Int; var baseURL: URL { http://127.0.0.1:<localPort> }; func close() async }` — локальный `ServerBootstrap` на `127.0.0.1:0`; на каждое соединение — канал `directTCPIP` к `127.0.0.1:<remotePort>` с двусторонней пересылкой байтов; закрытие сессии закрывает слушатель.
  - `public actor OSINTSyntheticSSHServer { public struct Request: Equatable, Sendable { command: String; stdin: String? }; init(login: String, password: String, script: @escaping @Sendable (Request) -> OSINTExecResult, forwardPort: Int? = nil); func start() async throws -> (host: String, port: Int, fingerprint: String); func stop() async; var requests: [Request] { get }; func rotateHostKey() async }` — сервер `swift-nio-ssh` на loopback с ключом Ed25519 (`NIOSSHPrivateKey(ed25519Key:)`), отказ при другом пароле, `directTCPIP` пересылается на `forwardPort` или отклоняется.

- [ ] **Step 1: Write the failing tests** — `testFirstConnectAsksForHostKeyAndReturnsFingerprint` (замыкание получило `SHA256:…`, вернуло `true`, сессия подключена), `testDeclinedHostKeyIsMismatch`, `testChangedHostKeyRefusesBeforeAuth` (подключились, сохранили отпечаток, `rotateHostKey`, новая сессия с `expectedFingerprint` → `hostKeyMismatch`, `requests` пусты, сервер не видел попытки аутентификации), `testWrongPasswordIsAuthFailed`, `testExecReturnsStatusAndStreams` (скрипт: `echo hi` → `hi`, статус 0; `false` → статус 1), `testExecStdinReachesServer` (`install -m 600 /dev/stdin …` получает `stdin`), `testTunnelForwardsHTTP` (локальный `URLSession` через `tunnel.baseURL` доходит до тестового HTTP-слушателя за `forwardPort` и получает его ответ), `testTunnelListensOnLoopbackOnly`, `testUnreachableHostIsSSHUnreachable` (порт без слушателя).
- [ ] **Step 2–4:** FAIL → implement → PASS (`scripts/test.sh --filter MakoshOSINTTests.OSINTSSHSessionTests`).
- [ ] **Step 5: Commit** — `git commit -m "Hold a password SSH session with host-key pinning, exec and a loopback tunnel"`

### Task 6: Установщик

**Files:**
- Create: `Sources/MakoshOSINT/FlowsintInstaller.swift`, `Sources/MakoshOSINT/OSINTScriptedServerState.swift` (под `#if DEBUG`; сценарий команд, изображающий LXC 164, общий для тестов и QA: `public actor OSINTScriptedServerState { var hasDocker, hasGit: Bool; var checkoutSHA: String?; var hasEnv, hasOverride: Bool; var builtSHA: String?; var up: Bool; var envWrites: Int; init(hasDocker: Bool = true, hasGit: Bool = true); func respond(_ request: OSINTSyntheticSSHServer.Request) -> OSINTExecResult }` — `request → result` по префиксу команды; меняет состояние на `git clone`/`checkout`, `install … .env` (считает `envWrites`), `compose build`, `compose up`; `onUp: @Sendable () async -> Void` для перевода синтетики в `installed`)
- Test: `Tests/MakoshOSINTTests/FlowsintInstallerTests.swift`

**Interfaces:**
- Consumes: `OSINTSSHSession.exec`, `FlowsintAPI` (health, register, login, investigations, createInvestigation), `OSINTCredentialVault` (служебный пароль, секреты `.env`), `OSINTStore` (settings, installs), `FlowsintPin.current`.
- Produces: `public actor FlowsintInstaller { init(session: OSINTSSHSession, api: any FlowsintAPI, vault: OSINTCredentialVault, store: OSINTStore, pin: FlowsintPin = .current, now: @escaping @Sendable () -> Date = Date.init, healthTimeout: Duration = .seconds(300)); func run(progress: @escaping @Sendable (OSINTInstall) -> Void) async -> OSINTInstall }` — шаги и команды:
  - `connect`: сессия уже подключена — `skipped`.
  - `docker`: `docker version --format '{{.Server.Version}}' && docker compose version --short`; статус ≠ 0 → `dockerMissing`; `git --version` ≠ 0 → `gitMissing`.
  - `checkout`: `git -C /opt/flowsint rev-parse HEAD`; равно `pin.sha` → `skipped`; нет каталога → `git clone --branch <tag> --depth 1 <repository> /opt/flowsint && git -C /opt/flowsint rev-parse HEAD`; иначе `git -C /opt/flowsint fetch --depth 1 origin tag <tag> && git -C /opt/flowsint checkout --detach <sha>`; итоговый SHA ≠ пину → `installFailed("checkout")`.
  - `env`: `test -f /opt/flowsint/.env` → `skipped` (и, если в Keychain нет `env.AUTH_SECRET`, `settings.envBackupAvailable = false`); иначе сгенерировать `AUTH_SECRET` (32 байта hex), `MASTER_VAULT_KEY_V1` (`base64:` + 32 байта base64), `NEO4J_PASSWORD`, `POSTGRES_PASSWORD` (по 24 символа `[A-Za-z0-9]`), сохранить в Keychain **до** отправки, затем `install -m 600 /dev/stdin /opt/flowsint/.env` со stdin `NODE_ENV=production\nAUTH_SECRET=…\nMASTER_VAULT_KEY_V1=…\nNEO4J_USERNAME=neo4j\nNEO4J_PASSWORD=…\nPOSTGRES_USER=flowsint\nPOSTGRES_PASSWORD=…\nPOSTGRES_DB=flowsint\nFLOWSINT_VERSION=<tag>\n`; сообщение шага — только «записан», без значений.
  - `override`: `cat /opt/flowsint/docker-compose.makosh.yml` равен ожидаемому → `skipped`; иначе `install -m 644 /dev/stdin /opt/flowsint/docker-compose.makosh.yml` с текстом `services:\n  api:\n    image: flowsint-api:<sha>\n    build: {context: ./flowsint-api, dockerfile: Dockerfile, target: production}\n  celery:\n    image: flowsint-api:<sha>\n  app:\n    image: flowsint-app:<sha>\n    build: {context: ./flowsint-app, dockerfile: Dockerfile}\n`.
  - `build`: `docker image inspect flowsint-api:<sha> flowsint-app:<sha> --format '{{.Id}}'` статус 0 → `skipped`; иначе `cd /opt/flowsint && docker compose -f docker-compose.prod.yml -f docker-compose.makosh.yml build` (таймаут 30 минут, `onOutput` — в `message` последняя строка), затем `… pull postgres redis neo4j`.
  - `up`: `cd /opt/flowsint && docker compose -f docker-compose.prod.yml -f docker-compose.makosh.yml up -d --remove-orphans`; затем опрос `api.health()` каждые 5 с до `healthTimeout` → иначе `healthTimeout`.
  - `register`: `api.login(serviceEmail, servicePassword)` удался → `skipped`; пароля в Keychain нет → сгенерировать 32 символа, сохранить, `api.register` (`true` → `done`; `false` → `login`, провал → `serviceAuthFailed`).
  - `investigation`: `settings.investigationID` есть и `investigations()` его содержит → `skipped`; иначе найти по имени `Makosh` или `createInvestigation(name: "Makosh")`.
  - `record`: `settings.installedTag/installedSHA/installedAt`, `imageIDs` из `docker image inspect … --format '{{.Repository}}:{{.Tag}} {{.Id}}'`, `saveSettings`.
  - Каждый шаг пишет `saveInstall` и зовёт `progress`; любой отказ → `install.state = .failed`, остальные шаги `pending`.

- [ ] **Step 1: Write the failing tests** — `testFreshServerRunsEverySteps` (все шаги `done`, кроме `connect` `skipped`; сервер получил clone, env, override, build, up; `users` синтетики содержит `serviceEmail`; `investigationID` сохранён), `testRerunOnInstalledServerSkipsEverything` (второй `run` — все шаги `skipped`, кроме `record`; `.env` не записывался второй раз: в `requests` нет второго `install … .env`; `register` не звал `api.register`), `testMissingDockerStopsEarly` (`dockerMissing`, нет `git clone`), `testMissingGitIsGitMissing`, `testWrongShaAfterCheckoutFails`, `testEnvStepLeavesNoSecretInSteps` (JSON установки не содержит ни одного значения, записанного в Keychain), `testExistingEnvWithoutKeychainMarksBackupUnavailable`, `testHealthTimeoutFailsUp` (синтетика `installed = false`, таймаут 1 с), `testExistingUserWithWrongPasswordIsServiceAuthFailed`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Install and update flowsint on the server idempotently"`

### Task 7: Отображение графа в наблюдения

**Files:**
- Create: `Sources/MakoshOSINT/OSINTGraphMapping.swift`
- Test: `Tests/MakoshOSINTTests/OSINTGraphMappingTests.swift`

**Interfaces:**
- Consumes: `MakoshCore.Person`, `Observation`, `SourceStamp`, `ServiceIdentity`, `PersonMatching` (нормализация телефонов и адресов).
- Produces: `public enum OSINTGraphMapping { public static let service = "osint"; public static func identity(serverID: UUID, sketchID: String) -> ServiceIdentity (`osint` / `serverID.uuidString` / `sketchID`); public static func observations(graph: FlowsintGraph, inputNodeIDs: Set<String>, sketchID: String, serverID: UUID, person: Person, now: Date, limit: Int = 200) -> (observations: [Observation], truncated: Bool) }` — берутся узлы, связанные ребром с входным узлом (в любую сторону), и сами входные `Phone` с `carrier`/`country`/`line_type`; поля и значения по таблице спеки (`emails`, `phones`, `phone.info`, `usernames`, `social.<platform в нижнем регистре>`, `avatar`, `breach`, `leak.device`, `domain`, `organization.suggested`); `metadata["enricher"]` (если есть) добавляется в `externalID` как суффикс `/<enricher>`; дубли текущих значений, уже предложенных и одинаковых в выдаче отбрасываются; `SocialAccount` без `profile_url` → `platform:username`; `Breach` без `breachdate` → только название; статус всегда `.proposed`.

- [ ] **Step 1: Write the failing tests** — `testEmailNeighborsBecomeProposedEmails`, `testSocialAccountUsesProfileURLOrPlatformHandle`, `testBreachAndGravatarAndDeviceFormats` (`breach` = `«Adobe, 2013-10-04»`, `avatar` = `src`, `leak.device` = `«Windows 10, 2024-05-01»`), `testInputPhoneCarrierBecomesPhoneInfo`, `testUnlinkedNodesAreIgnored`, `testCurrentAndAlreadyProposedValuesAreSkipped`, `testLimitTruncates` (201 узел → 200 наблюдений, `truncated == true`), `testIdentityAndStatus` (`identity == osint/<server>/<sketch>`, все `.proposed`).
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Map a flowsint graph into proposed dossier observations"`

### Task 8: Проверка плана

- [ ] **Step 1:** `scripts/test.sh --filter MakoshOSINTTests` → PASS; `scripts/test.sh --filter MakoshPersonsTests` → PASS (ничего не сломано); `scripts/format.sh HEAD` → без изменений.
- [ ] **Step 2:** `scripts/build-app.sh` → exit 0 (новый пакет в сборке приложения).
- [ ] **Step 3:** Запись в `docs/development-status.md`: раздел «OSINT-модуль — план 1» с числом тестов и фактом, что сервер и сеть не использовались.
- [ ] **Step 4: Commit** — `git commit -m "Record the OSINT core plan results"`
