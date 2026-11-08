# Персоны, план 3: раздел «Персоны», мосты каналов, Настройки, QA и документация Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Раздел «Персоны» по варианту C вместо «Контактов» (список-дерево слева, полное досье справа с признаком, прежними значениями, организациями, отделением источника и «Удалить везде»), мосты каналов к коллектору (почта с заголовками рассылок, Telegram с контактами аккаунта, WhatsApp, Teams), Telegram-мост книги на движке, книга macOS с системным согласием, Настройки → Персоны, подсказка адресов в редакторе письма, синтетический QA-бандл на схеме `qa_persons_` и документация.

**Architecture:** `PersonsHost` принадлежит делегату приложения (как `CalendarHost`), создаёт `PersonsService`, `PersonCollector` и `PersonsWorkspaceModel`, и реализует протоколы-мосты: наблюдения каналов приходят из моделей каналов через `WorkspaceView`-модификатор `PersonsWorkspaceLinks`, Telegram-контакты — через провайдер в `MakoshTelegram`. `WorkspaceModel` остаётся издателем персон для остальных разделов, но список раздела читает сводки постранично. UI — SwiftUI в общей оболочке.

**Tech Stack:** SwiftUI/AppKit, `Contacts.framework`, XCTest, Python для QA-скрипта.

**Spec:** `docs/superpowers/specs/2026-11-08-persons-design.md`; планы 1 и 2 — `docs/superpowers/plans/2026-11-08-persons-1-core.md`, `docs/superpowers/plans/2026-11-08-persons-2-sync.md`.

## Global Constraints

- Всё из Global Constraints планов 1 и 2.
- Раздел в выпадающем списке называется «Персоны», символ `person.2`; строки UI: «персона», «человек», «организация», «адресная книга», «прежний», «предложено Makosh», «Отделить источник…», «Склеить с…», «Удалить везде…».
- Общая оболочка: `WorkspaceSplitView`, `WorkspaceStyle`, `WorkspaceBackdrop`; карточка — колонка справа, как сейчас у досье.
- Нынешние возможности досье сохраняются: заметки с источником и ссылкой Телемоста, «Доступ для ИИ», источники и наблюдения, история, слияния с отменой, импорт JSON, «Дубли».
- Каналы отдают коллектору только то, что уже прошло через Makosh: письма из сохранённого кэша и новые, личные диалоги и контакты подключённого аккаунта Telegram, личные чаты WhatsApp, людей Teams. Никаких новых запросов к серверам каналов ради сбора, кроме контактов Telegram (`contactPeerIdsView` — локальное представление движка).
- Книга macOS: `NSContactsUsageDescription` в бандле; включение — только переключателем в Настройках; отказ → состояние `noAccess` с «Открыть Настройки системы», без повторных запросов; QA-бандл её не трогает.
- Доступ к окнам QA через computer-use пользователь отклонил: осмотр экрана делает пользователь; в статусе это записывается как непроверенное мной.
- QA: бандл `org.makosh.persons.qa`, флаг `--persons-synthetic-preview`, схема `qa_persons_<suffix>` только на loopback PostgreSQL, синтетические книги, Keychain в памяти.
- Внутри `Sources/MakoshApp/Tasks` и `MakoshTasks` Swift-овский `Task` пишется `_Concurrency.Task`; `MakoshApp.swift` и `WorkspaceView.swift` не импортируют `MakoshTasks`.

## Review Focus

1. **Письмо в «Спаме» в сохранённой истории** — начальный проход по кэшу писем не создаёт персону из отправителя письма папки `junk` и поднимает счётчик спама. Тест в задаче 3.
2. **Свой адрес учётной записи** — письма от себя и себе не создают персону «я». Тест в задаче 3.
3. **Удаление персоны в UI** — удаляется мягко, снаружи ничего не происходит, в фильтре «Удалённые» есть «Восстановить». Тест в задаче 2 (модель) и в QA-сиде.
4. **Перетаскивание человека на организацию в дереве** — создаёт ручное `confirmed` членство; повторный бросок на ту же организацию ничего не меняет. Тест в задаче 1.
5. **Подсказка адреса в письме** — ввод двух букв предлагает адреса активных персон, скрытые как спам и удалённые не предлагаются. Тест в задаче 6.

---

### Task 1: Раздел «Персоны»: боковая колонка-дерево

**Files:**
- Create: `Sources/MakoshApp/Persons/PersonsHost.swift`, `Sources/MakoshApp/Persons/PersonsSidebarView.swift`, `Sources/MakoshApp/Persons/PersonsTreeRow.swift`
- Modify: `Sources/MakoshApp/Workspace/WorkspaceView.swift` (`Destination.contacts` → `.persons = "Персоны"`; `sectionSidebar` для `.persons` — `PersonsSidebarView`; `filteredContacts` удаляется), `Sources/MakoshApp/MakoshApp.swift` (`lazy var persons = PersonsHost(...)` у делегата, в окружение `.environmentObject(delegate.persons).environment(\.personsHost, …)`), `Package.swift` (`MakoshApp` зависит от `MakoshPersons`, `MakoshGoogle`)
- Test: `Tests/MakoshTelegramTests/PersonsSidebarTests.swift` (тесты действий модели/хоста без рендера)

**Interfaces:**
- Produces:
  - `@MainActor final class PersonsHost: ObservableObject { nonisolated static let qaFlag = PersonsQAIsolation.flag; @Published private(set) var model: PersonsWorkspaceModel?; @Published private(set) var failure: String?; private(set) var service: PersonsService?; private(set) var collector: PersonCollector?; func configure(workspace: WorkspaceModel) async — создаёт `PersonsStore`/`PersonsService`/`PersonCollector` на конфигурации воркера досье (`workspace.mailConfiguration`), открывает, стартует обход; `func collect(_ observations: [PersonSourceObservation], spam: [MailEvidence] = []) async` (через `service.collect`); `func ensureChannelSource(kind: PersonBookKind, accountID: String, name: String) async` — заводит строку-источник (`mail`, `whatsapp`, `teams`, `telegram`) для переключателя «Собирать собеседников», если её нет; `var telegramBridge: (any TelegramContactsBridge)?` — выставляет приложение; `init()` для продукта, `#if DEBUG init(synthetic books: [String: PersonSyntheticBook])` }`.
  - `PersonsSidebarView(host: PersonsHost, workspace: WorkspaceModel, newPerson: (PersonKind) -> Void)`: заголовок «Персоны · N», меню «+» (Человек / Организация), сегмент «Все / Адресная книга», меню фильтра (Удалённые, Скрытые, Не ушли наружу, Предложено Makosh), поиск (`model.search` → `summaries(matching:)`), `List` по `model.tree` с раскрытием организаций, бейдж «книга», значок состояния (`blocked` → «не ушла», открытая попытка `unknown` → «?»), перетаскивание `PersonSummary.id` (`.draggable`/`.dropDestination`) на организацию → `workspace.suggestMembership(personID:organizationID:role: "", origin manual)`; внизу «Дубли · n» (нынешний `MergeReviewView`, слияние и отмена — через `host.model.mergePersons` / `undoMerge`, чтобы привязки книг следовали за персонами) и «Книги · k» (лист состояния книг задачи 5). Accessibility-идентификаторы: `persons.create`, `persons.search`, `persons.filter`, `person.row.<id>`, `persons.duplicates`, `persons.books`.
  - `WorkspaceModel` публикует `persons` (активные, как сейчас) для остальных разделов; дерево читает `host.model.tree`.

- [ ] **Step 1: Write the failing tests** — `testDropOnOrganizationCreatesManualMembershipOnce` (через `WorkspaceModel` с пробником: второй бросок не даёт второй команды), `testHostConfiguresOnWorkspaceConfiguration` (синтетический хост поднимает модель после `configure`), `testDestinationTitleIsPersons` (`Destination.persons.rawValue == "Персоны"` — вынести `Destination` в `internal` для теста).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS; `swift build` приложения.
- [ ] **Step 5: Commit** — `git commit -m "Replace the contacts sidebar with the persons tree"`

### Task 2: Карточка персоны и организации, редактор

**Files:**
- Modify: `Sources/MakoshApp/Persons/DossierView.swift` (переименовать в `PersonCardView.swift`), `Sources/MakoshApp/Persons/MergeReviewView.swift`
- Create: `Sources/MakoshApp/Persons/PersonAddressBookSection.swift`, `Sources/MakoshApp/Persons/PersonContactsSection.swift`, `Sources/MakoshApp/Persons/PersonOrganizationsSection.swift`, `Sources/MakoshApp/Persons/OrganizationMembersSection.swift`, `Sources/MakoshApp/Persons/PersonEditor.swift` (замена `ContactEditor`), `Sources/MakoshApp/Persons/PersonPicker.swift`
- Test: `Tests/MakoshTelegramTests/PersonCardModelTests.swift`

**Interfaces:**
- Produces:
  - `PersonCardView(person: Person, workspace: WorkspaceModel, host: PersonsHost, openMeeting:, edit:)` — шапка (имя, должность · организация, бейдж «человек»/«организация», «Изменить»); `PersonAddressBookSection` (Toggle признака → `workspace.setAddressBook`; строки книг из `host.model.bookStates(for:)`: «Telegram ✓», «Google ✓», «Яндекс ?» с «Проверить»/«Отказаться», «не ушла: нет телефона», «удалена снаружи» с «Отправить снова» (`host.model.resend(entryID:)`), «дубль в книге» с «Удалить дубль»; кнопка «Удалить везде…» с подтверждением, перечисляющим книги; недоступна для скрытых); `PersonContactsSection` (телефоны, адреса, username с источником — сервис первого наблюдения и число писем из `host.model.mailCount(address:)` через `PersonStore.mailEvidence`; контекст «Убрать» → `removeValue(.removedByUser)`; прежние — зачёркнуты, «прежний · с даты», «Вернуть» → `restoreValue`; наблюдения `proposed` — с «Принять / Отклонить»); `PersonOrganizationsSection` (членства с ролью и происхождением: «вручную», «по полю «компания»», «по домену sidorov.ru»; «Принять / Снять» для `suggested`; «Добавить в организацию…» → `PersonPicker(kind: .organization)`); для организации — `OrganizationMembersSection` (члены с ролями, переход к карточке, «Добавить человека…» → `PersonPicker(kind: .person)`); далее нынешние блоки «ИИ», «Заметки», «Источники и аккаунты» (у каждой identity — «Отделить источник…» с подтверждением → `workspace.detachIdentity`, после — выбор новой персоны), «История»; меню карточки: «Склеить с…» → `PersonPicker(kind: person.kind)` → `host.model.mergePersons(survivorID: person.id, removedID:)` с последующим `workspace.reload()`; «Удалить» → `deletePerson`; для удалённой — «Восстановить».
  - `PersonEditor(person: Person?, kind: PersonKind, workspace: WorkspaceModel)` — поля: вид (только при создании), имя (отображаемое), имя/фамилия/отчество (для человека), компания (текст), должность, телефоны, почта, username, метки; подсказка «Изменённые значения будут сохранены как ручные».
  - `PersonPicker(kind: PersonKind, exclude: UUID, workspace: WorkspaceModel, onPick: (UUID) -> Void)` — поиск по `summaries(matching:)`.

- [ ] **Step 1: Write the failing tests** — через `WorkspaceModel` с пробником: `testDeleteIsSoftAndRestoreReturns` (команды `delete`/`restore`, снаружи — ни одной попытки: пробник сервиса пуст), `testDetachSelectsNewPerson`, `testRemoveValueGoesThroughCommand`, `testMergePickerFiltersByKindAndExcludesSelf` (чистая функция фильтра `PersonPicker.candidates(summaries:kind:exclude:)`).
- [ ] **Step 2–4:** FAIL → implement → PASS; `swift build`.
- [ ] **Step 5: Commit** — `git commit -m "Show the person card with address-book state, former values and organizations"`

### Task 3: Мосты каналов к коллектору

**Files:**
- Create: `Sources/MakoshApp/Persons/PersonsWorkspaceLinks.swift`, `Sources/MakoshApp/Persons/MailPersonSource.swift`, `Sources/MakoshApp/Persons/TelegramPersonSource.swift`
- Modify: `Sources/MakoshMail/MailTypes.swift` (`MailLetter.listHeaders: Bool?`, `precedenceBulk: Bool?`, `autoSubmitted: Bool?` — опциональные, умолчание `nil` при декодировании), `Sources/MakoshMail/IMAPService.swift` (в выборку конвертов добавить `BODY.PEEK[HEADER.FIELDS (List-Id List-Unsubscribe Precedence Auto-Submitted)]` и разобрать в три флага), `Sources/MakoshMail/MailRepository.swift` (`public func letters(accountID: String, folder: String, afterSequence: Int64, limit: Int) throws -> [MailLetter]` для начального прохода), `Sources/MakoshApp/Workspace/WorkspaceView.swift` (модификатор `PersonsWorkspaceLinks`)
- Test: `Tests/MakoshMailTests/MailBulkHeadersTests.swift`, `Tests/MakoshTelegramTests/MailPersonSourceTests.swift`, `Tests/MakoshTelegramTests/TelegramPersonSourceTests.swift`

**Interfaces:**
- Produces:
  - `enum MailPersonSource { static func facts(_ letter: MailLetter, folders: [MailFolder], account: MailAccount) -> MailLetterFacts? }` — папка по `letter.key.folder` → `MailFolderRole` (`inbox/sent/junk/trash/other`), `ownAddresses = [account.email]` (нижний регистр), участники из `sender/senderName`, `recipient`, `cc`, `bcc` через `MailAddress.recipients`, флаги заголовков (`nil` → `false`), `markedSpam = folder == .junk`.
  - `PersonsWorkspaceLinks(host: PersonsHost, workspace: WorkspaceModel, mail: MailWorkspaceModel, telegram: TelegramModel, whatsapp: WhatsAppWorkspaceModel, teams: TeamsWorkspaceModel)`: `onChange(mail.letters)` — новые письма (по `id`, множество уже отданных в памяти хоста) → `facts` → `MailCollectionRule.observations` и `spamEvidence` → `host.collect`; начальный проход — при `configure` хоста по каждой учётной записи и папке через `MailRepository.letters(afterSequence:)` страницами по 200 с курсором `PersonCollectionCursor(source: mail/account, scope: folder)`, вне главного актора; `onChange(telegram.chats)` — личные диалоги текущего аккаунта → `TelegramPersonSource.observations(chats:, profiles:)` (имя из `title`, `externalID = String(id)`, только `id` пользователей — namespace по `telegramContactProfile` недоступен из сводки, поэтому хост запрашивает профиль через существующий `telegramPeerProfileSignal` в фоне и отдаёт только `kind == .person`, не бот, не scam/fake); `onChange(whatsapp.chats)` — `dossierPerson` личных чатов; `onChange(teams.people)` — `dossierPerson`. Каждое наблюдение — `evidence: .conversation`. Перед сбором хост вызывает `ensureChannelSource` для учётной записи и пропускает её, если у строки-источника `collectConversations == false`.
  - Собственные адреса учётной записи (`account.email`) персоной не становятся.

- [ ] **Step 1: Write the failing tests**

```swift
// MakoshMailTests
func testHeaderFieldsFetchSetsBulkFlags() async throws { /* стаб IMAP: List-Id присутствует → listHeaders true; Precedence: bulk → precedenceBulk true; Auto-Submitted: auto-generated → true; "no" → false */ }
func testLettersAfterSequencePages() throws { /* 250 писем → две страницы по 200 и 50, порядок по cacheSequence */ }
// MakoshTelegramTests (приложение)
func testJunkFolderLetterGivesSpamEvidenceOnly() { /* facts folder .junk → observations [], spamEvidence [sender] */ }
func testOwnAddressIsNotCollected() { /* sender == account.email → observations [] */ }
func testTelegramSourceSkipsBotsAndGroups() { /* профили: person, bot, group → одно наблюдение */ }
func testAlreadyCollectedLettersAreNotRepeated() { /* множество id хоста */ }
```

- [ ] **Step 2–4:** FAIL → implement → PASS; `scripts/test.sh --filter MakoshMailTests` → PASS целиком.
- [ ] **Step 5: Commit** — `git commit -m "Feed mail, Telegram, WhatsApp and Teams conversations into the person collector"`

### Task 4: Книга Telegram на движке и книга macOS в приложении

**Files:**
- Create: `Sources/MakoshTelegram/Engine/TelegramEngineContactsProvider.swift`, `Sources/MakoshTelegram/Synthetic/TelegramSyntheticContactsProvider.swift`, `Sources/MakoshApp/Persons/TelegramContactsBridgeAdapter.swift`
- Modify: `Sources/MakoshTelegram/Model/TelegramModel.swift` (`public func contactsProvider() -> (any TelegramContactsProvider)?` для текущего аккаунта), `scripts/build-app.sh` (`NSContactsUsageDescription`: «Макош читает и дополняет Контакты macOS только после вашего включения книги macOS в Настройках → Персоны.»), `Sources/MakoshApp/Persons/PersonsHost.swift` (фабрика адаптеров: `telegram` → `TelegramBookAdapter(bridge:)`, `macContacts` → `MacContactsAdapter` после `requestAccess`)
- Test: `Tests/MakoshTelegramTests/TelegramEngineContactsProviderTests.swift` (на синтетическом провайдере и чистых функциях разбора), `Tests/MakoshTelegramTests/TelegramContactsBridgeAdapterTests.swift`

**Interfaces:**
- Produces:
  - `public protocol TelegramContactsProvider: Sendable { var accountID: Int64 { get }; func contacts() async throws -> [TelegramContactProfile]; func addContact(peerID: Int64?, phone: String?, firstName: String, lastName: String) async throws -> Int64; func deleteContact(peerID: Int64) async throws }` и `public enum TelegramContactsError: Error, Equatable, Sendable { case notFound, failed, notReady }`.
  - `TelegramEngineContactsProvider` (внутри `MakoshTelegram`): `contacts()` — `account.postbox.contactPeerIdsView()` → профили через `telegramContactProfile(peer:accountID:observedAt:)`; `addContact` — `TelegramEngine(account:).contacts.addContactInteractively(peerId:firstName:lastName:phoneNumber:addToPrivacyExceptions: false)` при `peerID`, иначе `importContact(firstName:lastName:phoneNumber:)` (`nil` → `.notFound`); `deleteContact` — `deleteContactPeerInteractively`. Сигналы ждутся через существующий мост Signal → async (как в других провайдерах), вне MainActor, с проверкой поколения аккаунта.
  - `TelegramContactsBridgeAdapter: TelegramContactsBridge` (приложение) — отображает `TelegramContactProfile` → `RemoteCard(externalID: String(peerID), imported: profile.dossierImport, kind: .person)`; `accountID` строкой ↔ `Int64`.
  - `TelegramSyntheticContactsProvider` — в памяти, для QA.

- [ ] **Step 1: Tests** — `testSyntheticProviderRoundTrip`, `testBridgeMapsProfilesToRemoteCards`, `testAddWithoutPeerUsesPhone`, `testNotFoundBecomesNotInTelegram`.
- [ ] **Step 2–4:** FAIL → implement → PASS; `scripts/build-app.sh` собирает бандл с новым ключом.
- [ ] **Step 5: Commit** — `git commit -m "Back the Telegram book with the engine and add the macOS Contacts usage description"`

### Task 5: Настройки → Персоны и лист «Книги»

**Files:**
- Create: `Sources/MakoshApp/Persons/PersonsSettingsView.swift`, `Sources/MakoshApp/Persons/PersonsBooksSheet.swift`, `Sources/MakoshApp/Persons/CardDAVBookSheet.swift`
- Modify: `Sources/MakoshApp/MakoshApp.swift` (`MakoshSettingsTab.persons = "persons"`, вкладка «Персоны», символ `person.2`)
- Test: `Tests/MakoshTelegramTests/PersonsSettingsModelTests.swift`

**Interfaces:**
- Produces:
  - `PersonsSettingsView()` (через `@EnvironmentObject PersonsHost`): таблица книг и каналов-источников (имя, вид, переключатели «Собирать собеседников» — для Telegram, почты, WhatsApp, Teams, «Читать адресную книгу», «Её контакты — моя адресная книга», «Принимать адресную книгу», состояние, последняя ошибка без секретов, «Повторный вход» для `needsSignIn`, «Отключить»); «Подключить CardDAV…» (`CardDAVBookSheet`: подсказка из почтовых учётных записей по домену/IMAP-хосту — Яндекс `carddav.yandex.ru`, iCloud `contacts.icloud.com`, Fastmail `carddav.fastmail.com`; логин и пароль приложения), «Подключить Google…» (нет клиента → «Вход Google не настроен в этой сборке»; есть разрешение без области контактов → «Разрешить контакты»), «Книга macOS» (переключатель; при включении `MacContactsAdapter.requestAccess()`; `noAccess` → «Открыть Настройки системы» через `x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts`; предупреждение, если включены запись и в macOS, и в CardDAV iCloud); правила организаций (по полю «компания», по домену, стоп-список доменов — редактируемый список), период обхода, открытые попытки с «Проверить / Отказаться».
  - `PersonsBooksSheet` — тот же список состояния книг и попыток, открывается из «Книги · k» в боковой колонке.
  - `enum CardDAVHints { static func suggestion(email: String, imapHost: String) -> (server: URL, login: String)? }` — чистая функция.

- [ ] **Step 1: Tests** — `testCardDAVHintsByDomainAndHost` (яндекс/icloud/fastmail/неизвестный → nil), `testICloudDoubleWriteWarning` (чистая функция `PersonsSettingsRules.warnsDoubleICloud(books:)`), `testSourceFlagOffClearsFlagsThroughService` (пробник сервиса).
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "Add the Persons settings and the books status sheet"`

### Task 6: Подсказка адресов в редакторе письма и остальные связи

**Files:**
- Modify: `Sources/MakoshApp/Mail/MailComposeSheet.swift` (подсказки адресатов), `Sources/MakoshApp/Calendar/CalendarWorkspaceLinks.swift` (адреса из активных персон), `Sources/MakoshApp/Telegram/TelegramWorkspaceDossier.swift`, `Sources/MakoshApp/Telegram/TelegramContactProfileView.swift`, `Sources/MakoshApp/Mail/MailViews.swift`, `Sources/MakoshApp/Telemost/TelemostViews.swift`, `Sources/MakoshApp/AI/*.swift` (строки «контакт» → «персона», `persons(owning:)` через воркер вместо фильтра по всему списку)
- Create: `Sources/MakoshApp/Persons/PersonAddressSuggestions.swift`
- Test: `Tests/MakoshTelegramTests/PersonAddressSuggestionsTests.swift`

**Interfaces:**
- Produces: `enum PersonAddressSuggestions { static func suggestions(typed: String, persons: [PersonSummary], emails: [UUID: [String]]) -> [(address: String, name: String)] }` — от двух символов, по имени или адресу, только `isActive`, до 6; редактор письма показывает их под полем «Кому» и подставляет `Имя <адрес>`.

- [ ] **Step 1: Tests** — `testSuggestsByNameAndAddressFromTwoCharacters`, `testInactivePersonsAreNotSuggested`, `testLimitSix`.
- [ ] **Step 2–4:** FAIL → implement → PASS; `swift build`.
- [ ] **Step 5: Commit** — `git commit -m "Suggest person addresses in the mail composer and rename dossier strings"`

### Task 7: Изолированный QA-бандл

**Files:**
- Create: `Sources/MakoshPersons/PersonsQAIsolation.swift`, `Sources/MakoshPersons/PersonsSyntheticSeed.swift`, `Sources/MakoshApp/Persons/PersonsSyntheticPreview.swift`, `scripts/run-persons-qa.py`, `scripts/test-persons-qa.py`
- Modify: `Sources/MakoshApp/MakoshApp.swift` (ветка `MakoshSyntheticService == "persons"` и флаг `PersonsHost.qaFlag` в `permitsOrdinaryReleaseLaunch`), `scripts/test.sh` (`python3 scripts/test-persons-qa.py`)
- Test: `Tests/MakoshPersonsTests/PersonsQAIsolationTests.swift`, `Tests/MakoshPersonsTests/PersonsSyntheticSeedTests.swift`

**Interfaces:**
- Produces:
  - `public enum PersonsQAIsolation { static let flag = "--persons-synthetic-preview"; static let schemaPrefix = "qa_persons_"; static func validate(configuration: PersonWorkspaceConfiguration, arguments: [String]) throws }` — как `TasksQAIsolation`.
  - `public enum PersonsSyntheticSeed { static func books() -> [String: PersonSyntheticBook]; static func seed(persons: PersonStore, service: PersonsService, collector: PersonCollector) async throws }` — фиксированные UUID; наблюдения: три письма с `sidorov.ru` (входящие) → организация «sidorov.ru» с тремя `suggested` членствами; письмо в `junk` от `spam@evil.test` → персоны нет, счётчик спама 1; Telegram-контакты с телефоном, совпадающим с почтовой персоной → автосклейка; синтетический CardDAV «Яндекс» как источник признака с двумя карточками → персоны с признаком; синтетический Google как получатель; синтетическая «книга macOS»; персона с признаком без телефона → «не ушла в Telegram»; `failNext(.unknownOutcome)` у Google на первом проходе → одна попытка `unknown`; пара персон с общим ролевым адресом `info@sidorov.ru` → только «Дубли»; удалённая персона в фильтре «Удалённые».
  - `PersonsSyntheticPreview` — `WorkspaceSplitView` с `PersonsSidebarView` и `PersonCardView`, тулбар «СИНТЕТИЧЕСКАЯ ПРОВЕРКА», кнопка «Настройки персон» (лист с `PersonsSettingsView`), хост `PersonsHost(synthetic:)` и `WorkspaceModel(requireExplicitDatabaseConfiguration: true, syntheticSchemaPrefix: "qa_persons_")`.
  - `scripts/run-persons-qa.py` — копия `run-tasks-qa.py` с `qa_persons_`, `org.makosh.persons.qa`, `MakoshPersonsQA`, флагом; `scripts/test-persons-qa.py` — тесты `isolated_configuration`, `qa_info`, `launch_command`, отказ не-loopback.

- [ ] **Step 1: Tests** — `testValidateRejectsForeignFlagsAndSchemas`, `testSeedIsIdempotentAndMatchesExpectations` (после сида: организаций 1, скрытых 0 и персоны `spam@evil.test` нет, `mailEvidence("spam@evil.test").spam == 1`, одна `unknown` попытка, одна `blocked` причина `noPhoneOrPeer`, одна пара дублей), Python-тесты.
- [ ] **Step 2–4:** FAIL → implement → PASS; `scripts/build-app.sh` → exit 0; собрать QA-бандл из `.build/debug/Makosh` с переподписью (как для календаря) и запустить `scripts/run-persons-qa.py --bundle … --launch`; проверить по базе: число персон, организаций, привязок, попыток.
- [ ] **Step 5: Commit** — `git commit -m "Add the isolated persons QA bundle"`

### Task 8: Документация и статус

**Files:**
- Create: `docs/persons.md`
- Modify: `docs/architecture.md` (ADR-020 «Персоны», ссылка из ADR-002), `AGENTS.md` (раздел «Persons decisions»; строка таблицы «Contacts/dossier» → «Persons/dossier»; правило `MakoshPersons` не импортирует модули каналов), `docs/development-status.md` (новый верхний раздел с фактическими результатами проверок, пропущенными проверками и открытыми вопросами: живые книги не проверены), `docs/reference-interface.md` (вариант C, расхождения с 900CRM/Orbit), `docs/service-integration.md` (коллектор как общий контракт каналов, Google-модуль), `docs/calendar.md` (переезд `GoogleOAuth` в `MakoshGoogle`), `docs/import-format.md` (новые необязательные поля `givenName`, `familyName`, `middleName`, `usernames`), `docs/design/persons-variant-c.jpg` (уже сохранён)

- [ ] **Step 1: Write** `docs/persons.md` по образцу `docs/calendar.md`: что это, модули, правила (источники, спам, автосклейка, организации, признак, запись наружу, попытки, удаление), учётные записи-книги, интерфейс (вариант C), QA, известные границы, следующая очередь.
- [ ] **Step 2: Update** остальные документы; в статусе — точные числа тестов и коды выхода `scripts/test.sh`, `scripts/build-app.sh`, QA-скрипта; осмотр окна — за пользователем.
- [ ] **Step 3: Verify** — `scripts/format.sh HEAD`; `scripts/test.sh` → exit 0; `scripts/build-app.sh` → exit 0.
- [ ] **Step 4: Commit** — `git commit -m "Document the Persons section and record its checks"`
