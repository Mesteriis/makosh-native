# OSINT-модуль, план 3: приложение — связывание в `PersonsHost`, Настройки, карточка, синтетический QA, документация Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Пользователь из Makosh настраивает SSH-доступ к LXC 164, разворачивает и обновляет flowsint, вводит ключи API, включает автообогащение книг, запускает обогащение из карточки персоны, принимает и отклоняет находки; синтетический QA показывает всё это без сервера; документация и решения записаны.

**Architecture:** `PersonsHost` (делегат приложения) создаёт `OSINTService` и `OSINTWorkspaceModel` рядом с сервисом персон, зовёт `reconcile(autoSources:)` после каждого прохода коллектора и по таймеру. Представления только читают модели и отдают команды. В режиме `--persons-synthetic-preview` хост получает `FlowsintSynthetic` и `OSINTSyntheticSSHServer`.

**Tech Stack:** SwiftUI/AppKit, `MakoshOSINT` (планы 1–2), `MakoshPersons`, существующие `PersonsSettingsForm`, `PersonCardView`, `PersonsSyntheticPreview`, `scripts/run-persons-qa.py`.

**Spec:** `docs/superpowers/specs/2026-11-09-persons-osint-design.md`; планы 1–2 рядом.

## Global Constraints

- Всё из Global Constraints планов 1–2.
- Без включённого модуля кнопка «Обогатить (OSINT)…» неактивна с подсказкой; без доверенного отпечатка и установки — тоже.
- Диалог запуска показывает значения, которые уйдут, обогатители с пометкой «нужен ключ <имя>», текст о передаче данных на сервер `<хост>` и сторонним сервисам и строку об ответственности; «Запустить» только с хотя бы одним значением и одним обогатителем.
- «Скопировать пароль веб-интерфейса» — единственное место, где секрет уходит пользователю (в буфер обмена, по клику).
- Кнопка «Отделить источник…» не показывается для identity `osint/…`.
- Тексты интерфейса на русском; расхождения с эталоном — в `docs/reference-interface.md`.
- Живой сервер (LXC 164) и живые обогатители — только по команде пользователя; в этом плане их нет.

## Review Focus

1. **Модуль выключен, а флажок книги включён** — сверка не ставит автоматических запусков; включение модуля без доверенного ключа тоже. Тест `testReconcileSourcesEmptyWhenDisabled` в задаче 1.
2. **Диалог без ключа HIBP** — обогатитель виден, недоступен, с подписью «нужен ключ HIBP_API_KEY»; «Запустить» не включает его. Тест `testDialogRulesDisableKeyedEnrichersWithoutKey` в задаче 3.
3. **Хост меняется в Настройках после установки** — отпечаток сброшен, статус «проверьте соединение», кнопка «Обновить» неактивна до проверки. Тест `testSettingsRulesAfterHostChange` в задаче 2.
4. **QA-сид воспроизводим** — повторный запуск сида на той же схеме не создаёт второго скетча и второго запуска для Анны. Тест `testSeedIsIdempotent` в задаче 4.
5. **Пароль веб-интерфейса в QA** — кнопка копирует значение из Keychain в памяти, в журнале установки и снимке его нет. Проверка по базе в задаче 4.

---

### Task 1: Связывание в `PersonsHost`

**Files:**
- Modify: `Sources/MakoshApp/Persons/PersonsHost.swift` (свойства `osint: OSINTService?`, `@Published osintModel: OSINTWorkspaceModel?`; в `configure` после `PersonsService`: `OSINTStore(connectionString:schema:)`, `OSINTCredentialVault(access: keychain)`, фабрики `OSINTService.liveFactories()` или синтетические, `OSINTService`, `open()`, модель, `load()`; `autoSources()` — книги с `enrichAutomatically` → `ImportSource`; `collect` после `service.collect` зовёт `osint.reconcile(autoSources:)`; таймер каждые 600 с (`startReconciling()` при не-синтетике); `init(synthetic:osint:ssh:)` в `#if DEBUG`), `Sources/MakoshApp/Persons/PersonsSyntheticPreview.swift` (передаёт синтетику; см. задачу 4), `Package.swift` (`MakoshApp` зависит от `MakoshOSINT`)
- Create: `Sources/MakoshOSINT/Presentation/OSINTAutoSources.swift` (`public enum OSINTAutoSources { static func sources(flaggedBookSources: [ImportSource], settings: OSINTSettings) -> [ImportSource] }` — правило живёт в модуле, потому что тесты `MakoshOSINTTests` не видят `MakoshApp`; `PersonsHost` передаёт `books.filter(\.enrichAutomatically).map(\.source)`)
- Test: `Tests/MakoshOSINTTests/OSINTAutoSourcesTests.swift`

**Interfaces:**
- Produces: `OSINTAutoSources.sources(...)` — пусто, если `!settings.enabled || settings.hostKeyFingerprint == nil || settings.installedSHA == nil`; `PersonsHost.osintModel`.

- [ ] **Step 1: Write the failing test** — `testReconcileSourcesEmptyWhenDisabled` (три варианта: выключен, без отпечатка, без установки → `[]`; всё есть → источники флажков).
- [ ] **Step 2–4:** FAIL → implement (`OSINTAutoSources`, связывание в `PersonsHost`, `Package.swift`) → PASS; `swift build` приложения проходит.
- [ ] **Step 5: Commit** — `git commit -m "Wire the OSINT service into the persons host"`

### Task 2: Настройки → Персоны → «OSINT-модуль (flowsint)»

**Files:**
- Create: `Sources/MakoshApp/Persons/OSINTSettingsSection.swift` (секция формы; поля хост/порт/логин/`SecureField` пароль с кнопкой «Сохранить»; «Проверить соединение» с листом отпечатка «Доверять»/«Отмена»; статусная строка; «Развернуть модуль» / «Обновить до <тег>» с `ProgressView` и списком строк `installLog`; «Открыть веб-интерфейс» (`NSWorkspace.shared.open(graphRootURL)`), «Скопировать пароль веб-интерфейса» (`NSPasteboard`); «Ввести пароль служебного пользователя…» (лист с `SecureField` → `setServicePassword`) и «Зарегистрировать нового служебного пользователя» (`registerNewServiceUser`) — показываются при статусе `serviceAuthFailed`; переключатель «OSINT-модуль включён»; ключи `OSINTEnricher.knownKeys` строками «задан / не задан», «Задать…» (лист с `SecureField`), «Удалить»; чекбоксы ручного и автоматического наборов; «Открытые попытки OSINT» с «Проверить» / «Отказаться»), `Sources/MakoshOSINT/Presentation/OSINTSettingsRules.swift` (`public enum OSINTSettingsRules { static func status(_ s: OSINTSettings, connected: Bool) -> String; static func canInstall(_ s: OSINTSettings) -> Bool (enabled && отпечаток есть && хост и логин не пусты); static func installButtonTitle(_ s: OSINTSettings, pin: FlowsintPin) -> String («Развернуть модуль» без `installedSHA`, «Обновить до <tag>» при другом SHA, «Переустановить <tag>» при совпадении); static func keyState(name: String, serverKeyNames: Set<String>) -> String }`)
- Modify: `Sources/MakoshApp/Persons/PersonsSettingsView.swift` (`osintSection` после `attemptsSection`; в `bookRow` для `book.kind.isBook` — `Toggle("Обогащать автоматически", …)` с подписью «только при включённом модуле»), `Sources/MakoshApp/Persons/PersonsSettingsView.swift` получает `osint: OSINTWorkspaceModel?` через `host.osintModel`
- Test: `Tests/MakoshOSINTTests/OSINTSettingsRulesTests.swift`

- [ ] **Step 1: Write the failing tests** — `testStatusTexts` («не настроен», «проверьте соединение», «установлен v1.2.13», «не отвечает»), `testSettingsRulesAfterHostChange` (`hostKeyFingerprint == nil` → `canInstall == false`), `testInstallButtonTitles`, `testKeyState`.
- [ ] **Step 2–4:** FAIL → implement (правила и представления) → PASS; `swift build`.
- [ ] **Step 5: Commit** — `git commit -m "Add the OSINT module section to the persons settings"`

### Task 3: Карточка персоны — раздел «OSINT» и диалог запуска

**Files:**
- Create: `Sources/MakoshApp/Persons/PersonOSINTSection.swift` (строка состояния по `lastRuns[person.id]`: «не обогащалась» / «обогащена <дата>, <n> находок» / «идёт запуск…» / «ошибка: <код>» / «есть попытка без ответа» с «Проверить»/«Отказаться»; кнопка «Обогатить (OSINT)…» (`disabled` с `help` по `OSINTDialogRules.disabledReason`); ссылка «Открыть граф»; меню «Удалить данные OSINT…» с подтверждением; группы `OSINTCardGrouping.items(for:)` по `OSINTCardGroup`, у `proposed` кнопки «Принять»/«Отклонить», подпись «ранее убрано» при `formerlyRemoved`; при `duplicateOf` — алерт «Совпадает с персоной <имя>» с кнопкой «Склеить с…» (открывает существующий `merging`)), `Sources/MakoshApp/Persons/OSINTEnrichSheet.swift` (чекбоксы значений `inputs`, чекбоксы обогатителей с подписями `requiredKey`, текст `OSINTDialogRules.disclosure(host:enrichers:)`, «Запустить»), `Sources/MakoshOSINT/Presentation/OSINTDialogRules.swift` (`public enum OSINTDialogRules { static func disabledReason(settings: OSINTSettings, person: Person) -> String? (nil — можно; «Включите модуль в Настройках → Персоны», «Проверьте соединение…», «Модуль не установлен», «Персона удалена или скрыта»); static func availableEnrichers(selected: Set<OSINTEnricher>, inputs: [OSINTInput], serverKeyNames: Set<String>) -> [(enricher: OSINTEnricher, enabled: Bool, note: String?)] (совместимые с типами входов; с `requiredKey` без ключа — `enabled: false`, `note: "нужен ключ <имя>"`); static func canLaunch(inputs: Set<OSINTInput>, enrichers: Set<OSINTEnricher>) -> Bool; static func disclosure(host: String, enrichers: Set<OSINTEnricher>) -> String (упоминает хост и сторонние сервисы: Gravatar, HudsonRock, Have I Been Pwned, Veriphone, Maigret-сайты, Whoxy — по выбранным) }`)
- Modify: `Sources/MakoshApp/Persons/PersonCardView.swift` (вставить `PersonOSINTSection` после прежних значений; скрыть «Отделить источник…» для `identity.service == OSINTGraphMapping.service`; подпись источника `osint` → «OSINT» в `PersonCardText.service`)
- Test: `Tests/MakoshOSINTTests/OSINTDialogRulesTests.swift`

- [ ] **Step 1: Write the failing tests** — `testDisabledReasons` (четыре причины и nil), `testDialogRulesDisableKeyedEnrichersWithoutKey`, `testIncompatibleEnrichersHidden` (без телефона `phoneToInfos` не в списке), `testCanLaunchNeedsValueAndEnricher`, `testDisclosureNamesHostAndServices`.
- [ ] **Step 2–4:** FAIL → implement → PASS; `swift build`.
- [ ] **Step 5: Commit** — `git commit -m "Show OSINT findings in the person card and launch enrichment from it"`

### Task 4: Синтетический QA

**Files:**
- Create: `Sources/MakoshOSINT/OSINTSyntheticSeed.swift` (`public enum OSINTSyntheticSeed { static func findings() -> [FlowsintSynthetic.Finding] (адрес Анны → Gravatar `https://www.gravatar.com/avatar/<hash>` и утечка «Adobe, 2013-10-04»; username Анны → два соцаккаунта `github`, `twitter`; телефон Анны → `carrier: "МТС", country: "RU", line_type: "mobile"`); static func scriptedServer(synthetic: FlowsintSynthetic) -> (OSINTSyntheticSSHServer, OSINTScriptedServerState) (состояние из плана 1 с `onUp` → `synthetic.setInstalled(true)`); static func seed(service: OSINTService, persons: PersonStore, annaID: UUID, hostPort: (String, Int), fingerprintTrust: Bool = true) async throws }` — сохраняет соединение `login: "makosh"`, доверяет ключу через `testConnection`, `setEnabled(true)`, `install`, один ручной запуск для Анны с `manualDefault`, затем `failNext(unknownOutcome, "launch")` и второй запуск для Бориса (username) — одна попытка остаётся `unknown`; идемпотентно: при существующей ссылке на скетч Анны запуск не повторяется), `Sources/MakoshOSINT/OSINTQAIsolation.swift` (`public enum OSINTQAIsolation { static func validate(settings: OSINTSettings, synthetic: Bool) throws }` — в синтетическом режиме `host` обязан быть `127.0.0.1`, иначе `invalidConfiguration`)
- Modify: `Sources/MakoshApp/Persons/PersonsSyntheticPreview.swift` (создаёт `FlowsintSynthetic(findings:)`, `OSINTSyntheticSSHServer`, передаёт в `PersonsHost(synthetic:osint:ssh:)`; сид OSINT после `PersonsSyntheticSeed.seed`), `Sources/MakoshApp/Persons/PersonsHost.swift` (синтетические фабрики: сессия к серверу-фикстуре, API — `FlowsintSynthetic`)
- Test: `Tests/MakoshOSINTTests/OSINTSyntheticSeedTests.swift`

- [ ] **Step 1: Write the failing tests** — `testSeedInstallsAndEnrichesAnna` (установка `completed`, у Анны 5 предложенных наблюдений, одна попытка `unknown` у Бориса), `testSeedIsIdempotent` (второй `seed`: `sketches().count` и число запусков не изменились), `testQAIsolationRefusesRemoteHost`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Собрать и запустить QA** — `swift build` (debug), `python3 scripts/run-persons-qa.py --bundle .build/debug/Makosh --launch` (как в прошлой работе: бандл из debug с переподписью, схема `qa_persons_…`); проверка по базе `psql`: `SELECT count(*) FROM <схема>.persons_osint_sketches` = 2, `… persons_osint_runs` = 2, `… persons_osint_attempts WHERE state = 'unknown'` = 1, `… persons_osint_installs` = 1 со всеми шагами `done`/`skipped`; `SELECT data::text FROM <схема>.persons_osint_attempts` и `persons_osint_installs` не содержат адреса Анны, телефона и паролей; окно оставить пользователю (доступ к окнам QA не запрашивать).
- [ ] **Step 6: Commit** — `git commit -m "Seed the persons QA with a synthetic OSINT server and findings"`

### Task 5: Документация, решения и полная проверка

**Files:**
- Modify: `docs/persons.md` (раздел «OSINT-модуль (flowsint)»: что, согласие, запуск, находки, попытки, сверка, установка, ключи, секреты, QA, границы), `docs/architecture.md` (ADR-021 «Persons OSINT — external flowsint server over one SSH tunnel with proposed observations»), `AGENTS.md` (в «Persons decisions»: OSINT — явное согласие и флажок книг, только `proposed`, принятие без автослияния, один SSH-туннель и пин flowsint с сборкой на сервере, секреты в `org.makosh.osint.v1`, `unknown` закрывает чтение; живой сервер LXC 164 — только по команде; `MakoshOSINT` не импортирует каналы и `MakoshPersons`), `docs/reference-interface.md` (раздел «OSINT-модуль — 2026-11-09»: секция настроек и раздел карточки, расхождения), `docs/development-status.md` (итог: тесты, сборка, QA, что не проверено: живой LXC 164, живые обогатители, второй Мак), `THIRD_PARTY_NOTICES.md` (сверить раздел из плана 1 с фактическими версиями), `docs/superpowers/specs/2026-11-09-persons-osint-design.md` (сноска «реализация: identity `osint/<сервер>/<скетч>`, обогатитель и задача — в попытках запуска», если так вышло)
- Also: `pve_spain/history.md` и карточка LXC 164 в VEDA — **не в этом плане**: после живой установки по команде пользователя.

- [ ] **Step 1:** Написать документацию; `scripts/format.sh HEAD`.
- [ ] **Step 2:** `scripts/test.sh` целиком → exit 0 (записать числа бандлов); `scripts/build-app.sh` → exit 0.
- [ ] **Step 3:** Обновить `docs/development-status.md` фактическими результатами, включая пропущенные проверки.
- [ ] **Step 4: Commit** — `git commit -m "Document the persons OSINT module and record its checks"`
- [ ] **Step 5:** Свежий обзор ветки (по образцу прошлых разделов) и исправления RED→GREEN — отдельным коммитом; слияние в `main` — только по команде пользователя.
