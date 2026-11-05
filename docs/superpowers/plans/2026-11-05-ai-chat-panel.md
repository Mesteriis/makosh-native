# Панель ИИ в чате и контекст беседы — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** справа от открытой переписки Telegram — панель беседы ИИ, чьим контекстом служат явно прикреплённые карточки (текущий чат, чаты, письма, контакты через «+»/«@»), без эмбеддингов.

**Architecture:** `MakoshAI` получает модель карточек контекста, протокол поставщика материала и сборщик контекста; `AIWorker` собирает контекст по карточкам беседы при каждой отправке. Чтение истории — в сервисах на их исполнителях (Telegram — Postbox, WhatsApp — его воркер, почта — `MailRepository`, контакты — `ContactWorkspaceWorker`); мост в `MakoshApp/AI` склеивает их, не протаскивая типы сервисов в `MakoshAI`. UI — правая колонка в `TelegramDetailView` и фильтр бесед в разделе «ИИ».

**Tech Stack:** Swift 6, SwiftUI/AppKit (macOS 26), SwiftPM, PostgreSQL (зашифрованные записи `ai_records`), XCTest.

**Spec:** `docs/superpowers/specs/2026-11-05-ai-chat-panel-design.md` (утверждён 2026-11-05).

## Global Constraints

- MainActor только оркестрирует; чтение истории, расшифровка, сборка контекста — на исполнителях сервисов/воркеров; публикация на main после проверки аккаунта/чата/поколения (`docs/main-thread-boundaries.md`).
- Явная карточка не требует флага «Доступно для ИИ»; флаг контакта «Запрещено» сильнее карточки.
- Секретные чаты Telegram не прикрепляются; сообщения с запретом пересылки исключаются со счётчиком.
- Личный чат с запрещённым контактом и его досье не прикрепляются совсем.
- Ничего не обрезается молча: превышение лимита блокирует отправку.
- Лимит по умолчанию — 100 000 символов (история беседы + карточки).
- Период по умолчанию — последние 200 сообщений; варианты: последние 200, за неделю, за месяц, «с … по …».
- Тексты источников не копируются в хранилище беседы; хранится только состав карточек.
- Никаких логов с текстом сообщений; QA только синтетический (`run-ai-qa.py`, схема `qa_ai_`).
- Старые беседы (без новых полей) читаются без ошибок.
- Форматирование `scripts/format.sh HEAD`; проверки `scripts/test.sh`, `scripts/build-app.sh`; после проверок чистить сборки.

## Review Focus

1. Беседа, созданная до этого изменения, открывается и отвечает (обратная совместимость `AIConversation`/`AIMessageVersion`).
2. Карточка снята между вопросом и «Перегенерировать» — повтор использует состав из сохранённого вопроса, не текущий ряд карточек.
3. Пользователь переключил чат в Telegram, пока собирался контекст — результат прошлого чата не попадает в новую панель.
4. Контакт стал «Запрещено» после прикрепления карточки — следующий вопрос уже без его сообщений.
5. Чат с тысячами локальных сообщений и период «с … по …» за год — сборка не блокирует ленту и упирается в лимит с понятной ошибкой.

---

### Task 1: Карточки контекста и обратная совместимость моделей

**Files:**
- Create: `Sources/MakoshCore/AIContextRange.swift` (период — в `MakoshCore`, чтобы `MakoshTelegram` не зависел от `MakoshAI`)
- Create: `Sources/MakoshAI/AIContext.swift`
- Modify: `Sources/MakoshAI/AIModels.swift` (`AIConversation`, `AIMessageVersion`, `AIFailure`)
- Test: `Tests/MakoshAITests/AIContextModelTests.swift`

**Interfaces:**
- Produces:
  - `MakoshCore`: `public enum AIContextRange: Codable, Hashable, Sendable { case latest(Int), lastDays(Int), between(Date, Date); public static let standard = AIContextRange.latest(200) }`
  - `public enum AIContextCard: Codable, Hashable, Sendable, Identifiable { case chat(service: String, accountID: String, chatID: String, title: String, range: AIContextRange); case letter(id: String, title: String); case contact(id: UUID, title: String); public var id: String; public var title: String }`
  - `AIConversation.anchor: AIContextCard?` (чат, к которому привязана беседа; только `.chat`), `AIConversation.cards: [AIContextCard]`
  - `AIMessageVersion.context: [AIContextCard]` (состав карточек, с которым задан вопрос / получен ответ)
  - `AIFailure.contextTooLarge(characters: Int, limit: Int)`, `AIFailure.contextUnavailable(String)`

- [ ] **Step 1: Write the failing tests**

```swift
func testLegacyConversationDecodesWithoutCards() throws {
    let json = #"{"id":"5A0B5C46-0000-4000-8000-000000000001","title":"t","createdAt":0,"updatedAt":0}"#
    let value = try JSONDecoder().decode(AIConversation.self, from: Data(json.utf8))
    XCTAssertNil(value.anchor)
    XCTAssertEqual(value.cards, [])
    XCTAssertTrue(value.searchMyData)
}
func testLegacyVersionDecodesWithoutContext() throws {
    let json = #"{"id":"5A0B5C46-0000-4000-8000-000000000002","text":"x","state":"complete","createdAt":0}"#
    XCTAssertEqual(try JSONDecoder().decode(AIMessageVersion.self, from: Data(json.utf8)).context, [])
}
func testCardRoundTripsAndHasStableID() throws {
    let card = AIContextCard.chat(service: "telegram", accountID: "1", chatID: "2", title: "Мария", range: .standard)
    let again = try JSONDecoder().decode(AIContextCard.self, from: JSONEncoder().encode(card))
    XCTAssertEqual(again, card)
    XCTAssertEqual(card.id, "chat:telegram:1:2")
    XCTAssertEqual(AIContextCard.letter(id: "L", title: "Тема").id, "letter:L")
}
```

- [ ] **Step 2: Run** `swift test --filter MakoshAITests.AIContextModelTests` — Expected: FAIL (типы не определены).
- [ ] **Step 3: Implement** типы в `AIContext.swift`; поля `anchor`/`cards` и `context` с `decodeIfPresent(...) ?? nil/[]` по образцу `searchMyData`/`sources`. `id` карточки не включает период (смена периода — та же карточка).
- [ ] **Step 4: Run** тот же фильтр — Expected: PASS; затем `swift test --filter MakoshAITests` — все зелёные.
- [ ] **Step 5: Commit** `git add Sources/MakoshAI Tests/MakoshAITests && git commit -m "Add AI context cards to conversations"`

### Task 2: Материал карточки и сборщик контекста

**Files:**
- Modify: `Sources/MakoshAI/AIContext.swift`
- Test: `Tests/MakoshAITests/AIContextBuilderTests.swift`

**Interfaces:**
- Consumes: Task 1 типы.
- Produces:
  - `public struct AIContextLine: Sendable, Equatable { public let author: String; public let isOutgoing: Bool; public let date: Date; public let text: String }`
  - `public struct AIContextMaterial: Sendable, Equatable { public let card: AIContextCard; public let lines: [AIContextLine]; public let hiddenForbidden: Int; public let hiddenProtected: Int; public let available: Int; public let requested: Int? }`
  - `public protocol AIContextProvider: Sendable { func material(for card: AIContextCard) async throws -> AIContextMaterial }` — бросает `AIFailure.contextUnavailable(причина)` для секретного чата, личного чата/досье запрещённого контакта, удалённого источника.
  - `public enum AIContextBuilder { public static let defaultLimit = 100_000; public static func turn(_ materials: [AIContextMaterial], historyCharacters: Int, limit: Int) throws -> AIChatTurn? }` — `nil` для пустого списка; `.system`-ход с заголовком на карточку (название, сервис, период) и строками `[дата] Автор: текст`; бросает `.contextTooLarge` если `historyCharacters + символы хода > limit`.

- [ ] **Step 1: Write the failing tests**

```swift
func testTurnListsEveryCardWithItsLines() throws {
    let card = AIContextCard.chat(service: "telegram", accountID: "1", chatID: "2", title: "Мария", range: .standard)
    let material = AIContextMaterial(card: card, lines: [.init(author: "Мария", isOutgoing: false, date: Date(timeIntervalSince1970: 0), text: "привет")],
        hiddenForbidden: 0, hiddenProtected: 0, available: 1, requested: 200)
    let turn = try XCTUnwrap(AIContextBuilder.turn([material], historyCharacters: 0, limit: 100_000))
    XCTAssertEqual(turn.author, .system)
    XCTAssertTrue(turn.text.contains("Мария"))
    XCTAssertTrue(turn.text.contains("привет"))
}
func testOverLimitThrowsInsteadOfTruncating() {
    let long = AIContextLine(author: "A", isOutgoing: false, date: .now, text: String(repeating: "x", count: 600))
    let material = AIContextMaterial(card: .letter(id: "L", title: "T"), lines: [long], hiddenForbidden: 0, hiddenProtected: 0, available: 1, requested: nil)
    XCTAssertThrowsError(try AIContextBuilder.turn([material], historyCharacters: 500, limit: 1_000)) { error in
        guard case .contextTooLarge(let characters, 1_000)? = error as? AIFailure else { return XCTFail("\(error)") }
        XCTAssertGreaterThan(characters, 1_000)
    }
}
func testNoCardsMeansNoTurn() throws { XCTAssertNil(try AIContextBuilder.turn([], historyCharacters: 0, limit: 10)) }
```

- [ ] **Step 2: Run** `swift test --filter MakoshAITests.AIContextBuilderTests` — Expected: FAIL.
- [ ] **Step 3: Implement** `AIContextBuilder.turn`; формат заголовка карточки — по образцу `AIRetrieval.context`.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Build AI context from attached cards"`

### Task 3: Воркер собирает контекст по карточкам беседы

**Files:**
- Modify: `Sources/MakoshAI/AIWorker.swift`
- Test: `Tests/MakoshAITests/AIWorkerContextTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces (в `AIWorker`):
  - `public func attachContext(_ provider: any AIContextProvider)`
  - `public func createConversation(anchor: AIContextCard?) async throws -> AIConversation` — `anchor` заносится и в `cards`; старый `createConversation()` вызывает её с `nil`.
  - `public func setCards(_ cards: [AIContextCard], conversationID: UUID) async throws`
  - `public func conversations(anchoredTo card: AIContextCard?) async throws -> [AIConversation]` — `nil` → все; сравнение по `card.id`.
  - `public func preview(conversationID: UUID) async throws -> [AIContextMaterial]` — для счётчиков на карточках.
- Поведение `prepareSend`: материалы по `conversation.cards` (параллельно, каждая карточка — через провайдер); `AIContextBuilder.turn(..., historyCharacters: история+вопрос, limit: defaultLimit)`; при ошибке вопрос **не** сохраняется и ничего не уходит провайдеру. В версии вопроса и ответа — `context = cards`. RAG-ход `retrieve` добавляется как сейчас (после контекста карточек).
- `prepareRegenerate` берёт `context` из версии вопроса, а не текущие карточки.

- [ ] **Step 1: Write the failing tests** (фейковые `AIFakeService`, `AIFakeVault` из существующих тестов; `AIFakeContextProvider` — актор со словарём `card.id → material/ошибка` и счётчиком вызовов)

```swift
func testSendIncludesCardMaterialAndRecordsComposition() async throws
// после send: service.lastTurns.first?.author == .system, текст содержит строку материала;
// messages(conversationID) — у вопроса current?.context == [card].
func testTooLargeContextSavesNothingAndSendsNothing() async throws
// провайдер отдаёт 200_000 символов → поток завершается .contextTooLarge,
// messages(conversationID).isEmpty, service.requests.isEmpty.
func testRegenerateUsesQuestionCompositionNotCurrentCards() async throws
// send с [A]; setCards([B]); regenerate → провайдер вызван для A, не для B.
func testUnavailableCardBlocksSend() async throws
// провайдер бросает .contextUnavailable("secret") → поток бросает её же, ничего не сохранено.
func testConversationsFilterByAnchor() async throws
// две беседы: с anchor A и без; conversations(anchoredTo: A).map(\.id) == [первая].
```

- [ ] **Step 2: Run** `swift test --filter MakoshAITests.AIWorkerContextTests` — Expected: FAIL.
- [ ] **Step 3: Implement** по Interfaces. Сборка — до `repository.save(question)`.
- [ ] **Step 4: Run** `swift test --filter MakoshAITests` — Expected: все PASS (включая существующие `AIWorkerTests`).
- [ ] **Step 5: Commit** `git commit -m "Send attached card context with each AI question"`

### Task 4: Чтение истории Telegram для контекста

**Files:**
- Create: `Sources/MakoshTelegram/Engine/TelegramAIContextReader.swift`
- Create: `Sources/MakoshTelegram/Messages/TelegramAIContextProjection.swift`
- Test: `Tests/MakoshTelegramTests/TelegramAIContextProjectionTests.swift`

**Interfaces:**
- Produces:
  - `public struct TelegramAIContextMessage: Sendable, Equatable { public let authorID: Int64; public let authorName: String; public let isOutgoing: Bool; public let date: Date; public let text: String; public let isProtected: Bool }`
  - `public struct TelegramAIContextPage: Sendable, Equatable { public let isSecret: Bool; public let isPrivate: Bool; public let peerID: Int64; public let messages: [TelegramAIContextMessage]; public let available: Int }`
  - `public enum TelegramAIContextProjection { public static func select(_ all: [TelegramAIContextMessage], range: AIContextRange, now: Date) -> [TelegramAIContextMessage] }` — `.latest(n)` → последние n по дате; `.lastDays(d)` → `date >= now - d дней`; `.between(a, b)` → включительно; результат по возрастанию даты; пустой текст (только медиа) → подпись вида «[фото]».
  - `@MainActor public protocol TelegramAIContextReading { func page(accountID: Int64, chatID: Int64, range: AIContextRange) async throws -> TelegramAIContextPage }`; реализация на `Account.postbox.transaction` с `deliverOn` очереди аккаунта (не main), публикует только значение. `isProtected` — флаг сообщения/пира «запрет пересылки»; `isSecret` — пространство имён секретного чата.
  - `TelegramModel.aiContextReader: TelegramAIContextReading?` (nil до `.ready`; синтетический превью отдаёт фикстуру).

- [ ] **Step 1: Write the failing tests** для `TelegramAIContextProjection.select`: `testLatestTakesNewestInDateOrder`, `testLastDaysCutsOlder`, `testBetweenIsInclusive`, `testMediaOnlyGetsPlaceholder`.
- [ ] **Step 2: Run** `swift test --filter MakoshTelegramTests.TelegramAIContextProjectionTests` — Expected: FAIL.
- [ ] **Step 3: Implement** проекцию; затем ридер на Postbox (чтение не более 5 000 последних сообщений пира за одну транзакцию; `available` — сколько реально прочитано локально).
- [ ] **Step 4: Run** тесты Telegram-фильтра — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Read local Telegram history for AI context"`

### Task 5: Мост поставщика контекста и правила доступа

**Files:**
- Create: `Sources/MakoshApp/AI/AIContextBridge.swift`
- Modify: `Sources/MakoshApp/AI/AIHost.swift` (подключить мост через `worker.attachContext`)
- Create: `Sources/MakoshAI/AIContextAccess.swift` (правила — чистая функция; тестовой цели для `MakoshApp` нет)
- Test: `Tests/MakoshAITests/AIContextAccessTests.swift`

**Interfaces:**
- Consumes: Task 2 протокол, Task 4 ридер, `WhatsAppWorker.messages(accountID:chat:before:)`, `MailRepository.letter(_:)`, `ContactWorkspaceWorker`, `AIAccessProvider.snapshot()`.
- Produces:
  - `final class AIContextBridge: AIContextProvider` — по сервису карточки читает историю, применяет правила, отдаёт `AIContextMaterial`.
  - `public enum AIContextAccess { public static func apply(_ lines: [(author: ServiceIdentity?, line: AIContextLine, protected: Bool)], isPrivateWith forbiddenAuthor: Bool, snapshot: AIAccessSnapshot) throws -> (lines: [AIContextLine], hiddenForbidden: Int, hiddenProtected: Int) }` в `MakoshAI`.
- Правила (из спеки): личный чат, где собеседник «Запрещено» → `.contextUnavailable` (включая свои сообщения); в группе — исключить строки запрещённых авторов (`hiddenForbidden`); защищённые сообщения — исключить (`hiddenProtected`); секретный чат → `.contextUnavailable`; досье запрещённого контакта → `.contextUnavailable`; письмо — целиком (тема, отправитель, дата, последняя версия текста), отправитель «Запрещено» → `.contextUnavailable`. Ключ автора — тот же `ServiceIdentity`, что в индексе (`MessageArchiveIndexSource.item`) и досье.

- [ ] **Step 1: Write the failing tests** для `AIContextAccess.apply`: `testPrivateChatWithForbiddenContactIsUnavailable`, `testGroupHidesForbiddenAuthorsWithCount`, `testProtectedMessagesHiddenWithCount`, `testInheritAndAllowedPass`.
- [ ] **Step 2: Run** — Expected: FAIL.
- [ ] **Step 3: Implement** `AIContextAccess`, затем мост для Telegram, WhatsApp (страницы до лимита периода), почты, контактов. Teams — `.contextUnavailable("Teams пока не поддерживается")`.
- [ ] **Step 4: Run** `swift test --filter MakoshAITests` — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Provide chat, letter and contact context to the AI"`

### Task 6: Поиск источников для «+» и «@»

**Files:**
- Create: `Sources/MakoshApp/AI/AIContextSearch.swift`
- Test: `Tests/MakoshAITests/AIContextSearchRankingTests.swift` (ранжирование — чистая функция в `MakoshAI`)

**Interfaces:**
- Produces:
  - `public struct AIContextSuggestion: Sendable, Equatable, Identifiable { public let card: AIContextCard; public let subtitle: String; public var id: String { card.id } }`
  - `public enum AIContextRanking { public static func rank(_ items: [AIContextSuggestion], query: String, limit: Int) -> [AIContextSuggestion] }` — без учёта регистра и ё/е; префикс слова выше вхождения; стабильный порядок.
  - `@MainActor final class AIContextSearch: ObservableObject { @Published private(set) var suggestions: [AIContextSuggestion]; func update(query: String) }` — собирает кандидатов из известных чатов Telegram, чатов WhatsApp, тем писем (`MailRepository` поиск по заголовкам, вне main), контактов; дебаунс 150 мс; поколение запроса отбрасывает устаревшие ответы.

- [ ] **Step 1: Write the failing tests:** `testPrefixBeatsSubstring`, `testCaseAndYoInsensitive`, `testLimitRespected`.
- [ ] **Step 2: Run** — Expected: FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `git commit -m "Search chats, letters and contacts for AI context"`

### Task 7: Панель ИИ в Telegram

**Files:**
- Create: `Sources/MakoshApp/AI/AIChatPanelView.swift` (панель: беседы этого чата, лента, ряд карточек, поле ввода с «+» и «@»)
- Create: `Sources/MakoshApp/AI/AIContextCardsView.swift` (карточка: название, сервис, период-пикер, «доступно N», «скрыто N», крестик)
- Modify: `Sources/MakoshAI/Presentation/AIWorkspaceModel.swift` (режим панели: `package func open(anchor: AIContextCard)`, `package func setCards(_:)`, `package var previews: [AIContextMaterial]`, `package var filter: AIConversationFilter`)
- Modify: `Sources/MakoshApp/Telegram/TelegramDetailView.swift` (кнопка в шапке чата, правая колонка с `AIChatPanelView`, ширина 300–440, состояние открытия в `UserDefaults` ключ `makosh.aiPanel.telegram`)
- Test: `Tests/MakoshAITests/AIWorkspacePanelTests.swift`

**Interfaces:**
- Consumes: Tasks 3, 5, 6.
- Produces: `package enum AIConversationFilter { case all, unanchored, anchored }`; `AIWorkspaceModel.open(anchor:)` — выбирает последнюю беседу этого якоря или создаёт новую с карточкой текущего чата (`range: .standard`); смена чата в Telegram вызывает `open(anchor:)` заново, ответы старого якоря отбрасываются по поколению.

- [ ] **Step 1: Write the failing tests** (`AIWorkspaceModel` с фейковым воркером/провайдером):
  - `testOpenAnchorReusesLatestConversationOfThatChat`
  - `testOpenAnchorCreatesConversationWithCurrentChatCard`
  - `testSwitchingAnchorDropsLateResultsOfPreviousChat`
  - `testRemovingCardUpdatesConversationCards`
- [ ] **Step 2: Run** `swift test --filter MakoshAITests.AIWorkspacePanelTests` — Expected: FAIL.
- [ ] **Step 3: Implement** модель, затем SwiftUI. Переключатель «Искать в моих данных» в панели скрыт. Ответ: под текстом — список `context` карточек версии; клик по карточке чата открывает чат (через существующую навигацию `WorkspaceView`), письма — письмо, контакта — досье.
- [ ] **Step 4: Run** — PASS; `scripts/build-app.sh` — exit 0.
- [ ] **Step 5: Commit** `git commit -m "Add the AI panel beside Telegram conversations"`

### Task 8: Раздел «ИИ»: привязка и фильтр, подпись флага, документация

**Files:**
- Modify: `Sources/MakoshApp/AI/AIWorkspaceViews.swift` (значок чата у привязанных бесед, фильтр «Все / Без привязки / По чатам», клик по значку открывает чат)
- Modify: `Sources/MakoshApp/AI/AIAccessBridge.swift` (подпись: флаг открывает чат для фонового поиска и будущего детектора; явная карточка в панели работает без него)
- Modify: `docs/reference-interface.md`, `docs/development-status.md`

- [ ] **Step 1:** тест фильтра в `AIWorkspacePanelTests`: `testFilterSeparatesAnchoredConversations` — Expected FAIL → implement → PASS.
- [ ] **Step 2:** обновить подпись и документацию (что сделано, что не проверено).
- [ ] **Step 3: Commit** `git commit -m "Show chat-bound AI conversations in the AI section"`

### Task 9: Синтетическая проверка и полные гейты

**Files:**
- Modify: `scripts/run-ai-qa.py` (если нужно: засеять синтетический чат Telegram-превью и якорную беседу)
- Modify: `docs/development-status.md`

- [ ] **Step 1:** `scripts/format.sh HEAD`; `scripts/dev-db.sh up`; `scripts/test.sh` — Expected exit 0; `scripts/build-app.sh` — exit 0.
- [ ] **Step 2:** QA-бандл `python3 scripts/run-ai-qa.py --launch` с офлайн-провайдером: открыть панель в синтетическом чате, увидеть карточку текущего чата и счётчик, добавить источник через «+» и «@», снять карточку, получить блок по объёму. Скриншоты/результаты — в `docs/development-status.md`; визуальная проверка, если окно недоступно, помечается как не выполненная.
- [ ] **Step 3:** удалить QA-схему и папки запуска; почистить `.build` и подготовленные кэши `.local` (по правилу пользователя).
- [ ] **Step 4: Commit** `git commit -m "Record AI panel verification"`

После Telegram (следующие шаги того же плана, отдельные задачи после рабочей панели): панель в WhatsApp, панель в почте, Teams как источник.
