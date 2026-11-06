# Файлы, часть 3: пересылка и карточка «файл» для ИИ — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Карточка «файл» в беседах ИИ (архив Макоша, Paperless, временная копия) с извлечением текста на Mac и диапазоном страниц; бюджет контекста от модели вместо константы; «Отправить в чат/письмом…», «Спросить ИИ…» и «Из Файлов…» в составителях.

**Architecture:** `MakoshAI` получает бюджет токенов роли, карточку `.file` и материал-документ; `MakoshFiles` — актор извлечения текста (PDFKit/Vision/NSAttributedString), стейджинг закрытых копий и чистые поисковики адресатов и файлов; приложение связывает их в `AIContextBridge`, `FileActionsMenu`, листах пересылки/выбора и трёх составителях. Защищённый контент Telegram получает признак в презентации.

**Tech Stack:** Swift 6, SwiftUI/AppKit, PDFKit, Vision, XCTest с фикстурами, созданными в тесте; реальный PostgreSQL для существующих хранилищ.

**Spec:** `docs/superpowers/specs/2026-11-06-files-forwarding-ai-design.md`

## Global Constraints

- MainActor только для состояния UI; извлечение, OCR, скачивание, стейджинг — акторы/`BackgroundWork`.
- Бюджет беседы = 85 % от `contextTokens` роли «чат» (nil → 128 000); оценка: кириллица 2,5 символа/токен, прочее 4; превышение — `AIFailure.contextTooLarge(tokens:budget:)`, ничего не обрезается и не отправляется.
- OCR: Vision, языки `ru-RU`, `es-ES`, `en-US`, точный режим, 150 dpi, не более 200 страниц; непагинированный текст — части по ~3 000 символов на границах абзацев.
- Файлы без записи архива — `AIFileSource.staged(id:)` в `FileHandoffStage` (0700/0600), живут до выхода; после перезапуска — «копия недоступна — прикрепите заново».
- Правила доступа как у чатов/писем (`AIContextAccess.requireOpen`); защищённый контент Telegram (`CopyProtected`, секретные медиа) и WhatsApp (`details?.protected == true`) не получает пунктов пересылки/ИИ/Paperless.
- Пересылка — только в составитель; отправляет пользователь.
- Извлечённый текст живёт в памяти процесса; на диск/в PostgreSQL не пишется.
- Строки UI по-русски; `accessibilityIdentifier` с префиксами `ai.`/`files.`; коммиты с `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`; форматировать только изменённые файлы.

## Review Focus

1. PDF со смешанными страницами (часть с текстовым слоем, часть сканы): текстовые берутся из слоя, сканы — из OCR, порядок страниц сохраняется (тест в Задаче 3).
2. Карточка удалена во время долгого OCR: задача отменяется, превью других карточек продолжают, в контекст ничего не идёт (тест в Задаче 5).
3. Старая беседа с карточками до появления `.file`/`contextTokens` открывается без ошибок декодирования (тесты в Задачах 1 и 2).
4. Файл из Paperless, где локальный разбор пуст, а `content` Paperless есть — запасной текст делится на части и помечается источником «Paperless» (тест в Задаче 5).
5. Перезапуск с карточкой `.staged` в сохранённой беседе — карточка не падает, показывает «копия недоступна», отправка блокируется с понятным текстом (тест в Задаче 5).

---

### Task 1: Бюджет контекста от модели

**Files:**
- Modify: `Sources/MakoshAI/AIModels.swift` (`AIRoleAssignment.contextTokens: Int?`, `AIFailure.contextTooLarge(tokens:budget:)` вместо `(characters:limit:)`)
- Create: `Sources/MakoshAI/AITokenEstimate.swift`
- Modify: `Sources/MakoshAI/AIContext.swift` (`AIContextBuilder.turn(_:history:budgetTokens:)`, удалить `defaultLimit`), `Sources/MakoshAI/AIWorker.swift` (`contextTurn` берёт бюджет роли), `Sources/MakoshAI/Presentation/AISettingsModel.swift` (`assign(_:connectionID:model:contextTokens:)`), `Sources/MakoshApp/AI/AISettingsView.swift` (поле «Контекст модели, токенов» в `AIRoleRow` для `.chat`), `Sources/MakoshApp/AI/AIHost.swift` (текст ошибки)
- Test: `Tests/MakoshAITests/AITokenEstimateTests.swift`, `Tests/MakoshAITests/AIContextBuilderTests.swift`, `Tests/MakoshAITests/AIContextModelTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum AITokenEstimate {
      public static let defaultContextTokens = 128_000
      public static let answerReserve = 0.15
      public static func tokens(in text: String) -> Int           // ceil(cyrillic/2.5) + ceil(other/4), пробелы считаются «прочим»
      public static func budget(contextTokens: Int?) -> Int        // Int(Double(contextTokens ?? default) * (1 - answerReserve))
  }
  public struct AIRoleAssignment { …; public var contextTokens: Int?; init(role:connectionID:model:contextTokens: Int? = nil) }
  public enum AIContextBuilder { public static func turn(_ materials: [AIContextMaterial], history: [AIChatTurn], budgetTokens: Int) throws -> AIChatTurn? }
  case contextTooLarge(tokens: Int, budget: Int)   // message: "Контекст беседы — \(tokens) токенов при бюджете \(budget). Сузьте период или страницы карточек либо увеличьте контекст модели в настройках."
  ```

- [ ] **Step 1: Падающие тесты**

```swift
func testCyrillicAndLatinEstimates() {
    XCTAssertEqual(AITokenEstimate.tokens(in: "привет"), 3)          // 6/2.5 → 3
    XCTAssertEqual(AITokenEstimate.tokens(in: "hello world"), 3)     // 11/4 → 3
    XCTAssertEqual(AITokenEstimate.tokens(in: ""), 0)
    XCTAssertEqual(AITokenEstimate.budget(contextTokens: nil), 108_800)
    XCTAssertEqual(AITokenEstimate.budget(contextTokens: 200_000), 170_000)
}
func testBuilderThrowsWithTokenNumbers() throws {
    // материал из 1 000 кириллических символов ≈ 400 токенов; бюджет 100 → contextTooLarge(tokens: >400, budget: 100)
}
func testRoleAssignmentDecodesWithoutContextTokens() throws {
    let json = #"{"role":"chat","connectionID":"5A0B5C46-0000-4000-8000-000000000001","model":"m"}"#
    XCTAssertNil(try JSONDecoder().decode(AIRoleAssignment.self, from: Data(json.utf8)).contextTokens)
}
```

- [ ] **Step 2: Убедиться, что падают** — Run: `scripts/test.sh --filter "AITokenEstimateTests|AIContextBuilderTests|AIContextModelTests"` — Expected: FAIL (типы/параметры не найдены).
- [ ] **Step 3: Реализовать**; в `AIWorker.contextTurn` бюджет = `AITokenEstimate.budget(contextTokens: roles().first { $0.role == .chat }?.contextTokens)`.
- [ ] **Step 4: Прогнать** — Run: `scripts/test.sh --filter MakoshAITests` — Expected: PASS.
- [ ] **Step 5: Коммит** — `git commit -m "Size the AI context by the model's token budget"`.

### Task 2: Карточка «файл» и материал-документ

**Files:**
- Modify: `Sources/MakoshAI/AIContext.swift` (`AIFileSource`, `AIContextCard.file`, `AIContextDocument`, `AIContextMaterial.document`, печать в `turn`, `heading`)
- Modify: `Sources/MakoshAI/AIContextSuggestion.swift` (без изменений API; подпись «Файл · …» задаёт приложение)
- Test: `Tests/MakoshAITests/AIContextModelTests.swift`, `Tests/MakoshAITests/AIContextBuilderTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum AIFileSource: Codable, Hashable, Sendable {
      case archive(recordID: UUID); case paperless(connectionID: UUID, documentID: Int); case staged(id: UUID)
  }
  case file(source: AIFileSource, title: String, pages: ClosedRange<Int>?)   // id: "file:archive:<uuid-lower>" | "file:paperless:<conn-lower>:<doc>" | "file:staged:<uuid-lower>"
  public struct AIContextDocument: Sendable, Equatable {
      public let pages: [String]           // только выбранные
      public let pageCount: Int
      public let selected: ClosedRange<Int>
      public let paginated: Bool           // false → «часть»
      public let recognized: Bool          // хотя бы одна страница из OCR
      public let truncatedOCR: Bool        // распознаны первые 200
      public let source: String            // "archive" | "paperless" | "paperless-content" | "staged"
  }
  public struct AIContextMaterial { …; public let document: AIContextDocument?; init(..., document: AIContextDocument? = nil) }
  public static func document(_ card: AIContextCard, _ document: AIContextDocument) -> AIContextMaterial   // lines: [], available: pageCount
  ```
  Печать: `=== Файл «T» (страницы a–b из N, распознано со скана) ===` / `(части a–b из N)`; перед каждой — `--- стр. k ---` / `--- часть k ---`; при `truncatedOCR` — строка `(распознаны первые 200 страниц)`. Вводный текст системного хода расширяется: «…переписка, письма и файлы…».

- [ ] **Step 1: Падающие тесты** — `testFileCardIDsIgnorePages`, `testFileCardRoundTripsAndOldConversationsDecode` (JSON беседы без `.file` и с ней), `testDocumentMaterialPrintsPagesAndFlags` (строки `=== Файл «Договор» (страницы 2–3 из 5, распознано со скана) ===`, `--- стр. 2 ---`), `testUnpaginatedDocumentPrintsParts`.
- [ ] **Step 2: Убедиться, что падают** — Run: `scripts/test.sh --filter "AIContextModelTests|AIContextBuilderTests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать.**
- [ ] **Step 4: Прогнать** — Run: `scripts/test.sh --filter MakoshAITests` — Expected: PASS.
- [ ] **Step 5: Коммит** — `git commit -m "Add the file context card and document material"`.

### Task 3: Извлечение текста на Mac

**Files:**
- Create: `Sources/MakoshFiles/FileTextExtractor.swift`
- Modify: `Sources/MakoshFiles/FilesFailure.swift` (`.unsupportedText(String)` → «Текст из файлов «\(kind)» не извлекается.»)
- Test: `Tests/MakoshFilesTests/FileTextExtractorTests.swift`, `Tests/MakoshFilesTests/Fixtures.swift` (создание PDF через PDFKit/`NSPrintOperation`-free путь: `PDFDocument` + `PDFPage(image:)` для скана и `NSAttributedString → PDF` через `NSTextView.dataWithPDF(inside:)` для текстового слоя; DOCX через `NSAttributedString.data(from:documentAttributes: [.documentType: .officeOpenXML])`; PNG с текстом через `NSImage`/Core Text)

**Interfaces:**
- Produces:
  ```swift
  public struct ExtractedText: Sendable, Equatable {
      public let pages: [String]; public let pageCount: Int; public let paginated: Bool
      public let recognizedPages: Set<Int>; public let truncatedOCR: Bool
  }
  public struct ExtractionProgress: Sendable, Equatable { public let done: Int; public let total: Int }   // MakoshFiles; мост переводит в AIExtractionProgress
  public actor FileTextExtractor {
      public static let ocrPageLimit = 200, renderDPI = 150, partCharacters = 3_000, textLayerThreshold = 20   // символов на страницу
      public init(languages: [String] = ["ru-RU", "es-ES", "en-US"])
      /// Pages are 1-based; nil = all. Progress is reported per finished page.
      public func extract(_ file: URL, name: String, pages: ClosedRange<Int>?, progress: (@Sendable (ExtractionProgress) -> Void)? = nil) async throws -> ExtractedText
      public static func parts(_ text: String, size: Int = partCharacters) -> [String]   // по абзацам (\n\n), иначе по строкам, иначе жёстко
      public func cached(key: String) -> ExtractedText?; public func store(_ value: ExtractedText, key: String); public func clear()
  }
  ```
  Категории: `FileCategory.classify` → `.document` pdf → PDFKit; docx/doc/rtf/odt → `NSAttributedString(url:options:documentAttributes:)`; txt/md/csv → UTF-8, иначе CP1251; `.image` → Vision; остальное → `unsupportedText`. Проверка `Task.checkCancellation()` между страницами.

- [ ] **Step 1: Падающие тесты** — `testPDFTextLayerIsReadPerPage`, `testScannedPageFallsBackToOCRAndIsMarked` (PDF из картинки с крупным текстом «СЧЁТ 1234»; `recognizedPages == [1]`, текст содержит «1234»), `testMixedPDFKeepsPageOrder` (стр. 1 текст, стр. 2 скан), `testPageRangeLimitsWork`, `testOCRLimitMarksTruncation` (`ocrPageLimit` временно внедряется через init-параметр `ocrPageLimit: Int = 200` → 2), `testDOCXAndRTFBecomeParts`, `testCP1251TextIsDecoded`, `testUnsupportedKindIsRefused` (`.zip`), `testPartsSplitOnParagraphs`, `testCancellationStopsBetweenPages`.
- [ ] **Step 2: Убедиться, что падают** — Run: `scripts/test.sh --filter FileTextExtractorTests` — Expected: FAIL.
- [ ] **Step 3: Реализовать** (`VNRecognizeTextRequest`: `.accurate`, `recognitionLanguages`, `usesLanguageCorrection = true`; рендер страницы `PDFPage.thumbnail(of:for:)` при 150 dpi по `bounds(for: .mediaBox)`).
- [ ] **Step 4: Прогнать** — Run: `scripts/test.sh --filter FileTextExtractorTests` — Expected: PASS (OCR-тесты могут занимать секунды).
- [ ] **Step 5: Коммит** — `git commit -m "Extract document text on the Mac with PDFKit and Vision"`.

### Task 4: Стейджинг, документ Paperless, поиск адресатов и файлов

**Files:**
- Create: `Sources/MakoshFiles/FileHandoffStage.swift`, `Sources/MakoshFiles/FileSearches.swift`
- Modify: `Sources/MakoshFiles/PaperlessSender.swift` (`PaperlessServing.document(id:)`), `Sources/MakoshFiles/PaperlessClient.swift` (`GET /api/documents/{id}/` → `PaperlessDocumentDetail { id, title, content, originalFileName, pageCount: Int? }`), `Sources/MakoshFiles/FilesQAIsolation.swift` (синтетический `document(id:)`)
- Test: `Tests/MakoshFilesTests/FileHandoffStageTests.swift`, `Tests/MakoshFilesTests/FileSearchesTests.swift`, `Tests/MakoshFilesTests/PaperlessClientTests.swift` (+`testDocumentDetailParsesContent`)

**Interfaces:**
- Produces:
  ```swift
  public actor FileHandoffStage {
      public init(root: URL)                                   // Application Support/Makosh/FileHandoffStage
      public func stage(_ handoff: FileHandoff) async throws -> StagedFile    // { id: UUID, url: URL, name: String }
      public func url(id: UUID) -> URL?                        // nil после release/перезапуска
      public func release(id: UUID)
      public func clearAll()                                   // при старте приложения
  }
  public struct FileDestination: Identifiable, Equatable, Sendable {
      public enum Kind: Equatable, Sendable { case telegram(accountID: String, chatID: Int64), whatsapp(accountID: UUID, chatID: String), mail(address: String, contactID: UUID?) }
      public let kind: Kind; public let title: String; public let subtitle: String; public var id: String
  }
  public enum FileDestinationSearch { public static func rank(_ items: [FileDestination], query: String, limit: Int) -> [FileDestination] }   // как AIContextRanking (префикс > слово > подстрока; ё/е)
  public struct FilePick: Identifiable, Equatable, Sendable { public enum Kind { case archive(FileCatalogueItem), paperless(connectionID: UUID, document: PaperlessDocument) }; … }
  @MainActor public final class FilePickerSearch: ObservableObject {
      @Published public private(set) var results: [FilePick]
      public init(catalogue: @escaping () -> [FileCatalogueItem], paperless: @escaping (UUID, String) async throws -> [PaperlessDocument], connections: @escaping () -> [UUID], debounce: Duration = .milliseconds(400))
      public func update(query: String)     // каталог сразу; Paperless при ≥3 символах после задержки, поздний ответ отбрасывается по поколению
  }
  ```

- [ ] **Step 1: Падающие тесты** — стейджинг: права 0700/0600, `url(id:)` после `release` nil, `clearAll` удаляет всё, имя файла — `stagingBasename`; поиск адресатов: ранжирование и лимит; `FilePickerSearch`: каталог без задержки, Paperless после 3 символов и задержки (инъекция `debounce: .zero`), поздний ответ прежнего запроса отброшен; клиент: `document(id:)` читает `content`.
- [ ] **Step 2: Убедиться, что падают** — Run: `scripts/test.sh --filter "FileHandoffStageTests|FileSearchesTests|PaperlessClientTests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать.**
- [ ] **Step 4: Прогнать** — Run: `scripts/test.sh --filter MakoshFilesTests` — Expected: PASS.
- [ ] **Step 5: Коммит** — `git commit -m "Add file staging, Paperless document detail and the destination and file searches"`.

### Task 5: Материал файла в мосте ИИ: источники, доступ, ход извлечения

**Files:**
- Modify: `Sources/MakoshApp/AI/AIContextBridge.swift` (`.file` → `fileMaterial`), `Sources/MakoshApp/AI/AIHost.swift` (`extractor: FileTextExtractor`, `stage: FileHandoffStage`, `files: FilesHost` в `start`, прогресс), `Sources/MakoshAI/Presentation/AIWorkspaceModel.swift` (`@Published extraction: [String: ExtractionProgress]`, отмена задачи превью при `remove`), `Sources/MakoshApp/Files/FilesHost.swift` (`record(id:) -> FileCatalogueItem?`, `downloadPaperless(connectionID:documentID:to:)`)
- Modify: `Sources/MakoshAI/AIContext.swift` (`AIContextDocument.assemble`, `AIExtractionProgress`)
- Test: `Tests/MakoshAITests/AIWorkspacePanelTests.swift` (+ отмена при удалении), `Tests/MakoshAITests/AIFileMaterialTests.swift` (чистая сборка документа + запасной текст)

**Interfaces:**
- Produces (всё в `MakoshAI`, который не зависит от `MakoshFiles`; мост в приложении переливает поля `ExtractedText`):
  ```swift
  public struct AIExtractionProgress: Sendable, Equatable { public let done: Int; public let total: Int }
  extension AIContextDocument {
      public static let fallbackThreshold = 50   // символов на страницу
      public static func assemble(pages: [String], pageCount: Int, paginated: Bool, recognizedPages: Set<Int>, truncatedOCR: Bool,
                                  selected: ClosedRange<Int>?, fallback: String?, source: String) throws -> (document: AIContextDocument, usedFallback: Bool)
      // selected вне 1...pageCount → AIFailure.contextUnavailable("В файле N страниц — выберите страницы в этих пределах.")
      // средняя длина страниц < fallbackThreshold и fallback != nil → части fallback, source + "-content", usedFallback = true
  }
  // AIWorkspaceModel
  @Published package private(set) var extraction: [String: AIExtractionProgress]
  package func reportExtraction(cardID: String, progress: AIExtractionProgress?)
  ```
  `AIContextBridge.fileMaterial`: `.archive` → `files.record(id:)` (nil → «Файл больше не в архиве»), доступ: идентичность автора записи из `archive_events` (`authorID` сообщения, сервис и аккаунт из identity) через `requireOpen(…, what: "файл")` для личных чатов и писем; `.paperless` → скачать оригинал в стейдж; `.staged` → `stage.url(id:)` (nil → «Копия недоступна — прикрепите файл заново»); извлечь с прогрессом (`extractor.extract(..., progress:)` → `AIExtractionProgress` → `reportExtraction`) → `AIContextDocument.assemble(...)` → `AIContextMaterial.document(card, document)`; `truncated: false`.

- [ ] **Step 1: Падающие тесты** — `testFallbackUsedWhenLocalTextIsThin`, `testFallbackIgnoredWhenLocalTextIsEnough`, `testPagesOutsideDocumentAreRejected`; `testRemovingACardCancelsItsPreview` (провайдер с удерживаемой продолжением задачей: удаление карточки → задача отменена, `previews` без неё).
- [ ] **Step 2: Убедиться, что падают** — Run: `scripts/test.sh --filter "AIFileMaterialTests|AIWorkspacePanelTests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать.**
- [ ] **Step 4: Прогнать** — Run: `scripts/test.sh --filter "MakoshAITests|MakoshFilesTests"` затем `scripts/build-app.sh` — Expected: PASS; сборка успешна.
- [ ] **Step 5: Коммит** — `git commit -m "Attach files to AI conversations with local text extraction"`.

### Task 6: Карточка файла в UI и поиск файлов в «+»/«@»

**Files:**
- Modify: `Sources/MakoshApp/AI/AIContextCardsView.swift` (чип `.file`: «страницы a–b из N», «распознано со скана», прогресс «извлекается k из N» + «Отменить» (= удалить карточку), меню диапазона `AIFilePagesPicker` по образцу `AIContextRangePicker`; подсказка при `contextTooLarge` — «выберите страницы»), `Sources/MakoshAI/Presentation/AIWorkspaceModel.swift` (`setPages(_:for:)`), `Sources/MakoshApp/AI/AIContextSearch.swift` (`files: FilePickerSearch?` → предложения `.file` с подписями «Файл · Почта/…» и «Paperless»), `Sources/MakoshApp/Workspace/WorkspaceView.swift` (`openAICard(.file)` → раздел «Файлы», выбор строки/хранилища; `AIContextSearch` получает `FilePickerSearch` из `files`)
- Test: `Tests/MakoshAITests/AIWorkspacePanelTests.swift` (+`testSetPagesKeepsCardIdentity`), `Tests/MakoshAITests/AIContextSearchRankingTests.swift` (+ файл с подписью)

- [ ] **Step 1: Падающие тесты** — `setPages` меняет `pages`, id карточки прежний, превью перечитывается.
- [ ] **Step 2: Убедиться, что падают** — Run: `scripts/test.sh --filter AIWorkspacePanelTests` — Expected: FAIL.
- [ ] **Step 3: Реализовать.**
- [ ] **Step 4: Прогнать** — Run: `scripts/test.sh --filter MakoshAITests` и `scripts/build-app.sh` — Expected: PASS; сборка успешна.
- [ ] **Step 5: Коммит** — `git commit -m "Show file cards with page ranges and offer files in the AI context search"`.

### Task 7: Меню действий файла, «Спросить ИИ…» и защищённый контент

**Files:**
- Modify: `Sources/MakoshTelegram/Model/TelegramModelTypes.swift` (`TelegramMessage.isProtected: Bool = false`), `Sources/MakoshTelegram/Presentation/TelegramMapping.swift` (`isProtected = message.flags.contains(.CopyProtected) || message.containsSecretMedia || чат с copyProtectionEnabled`), `Sources/MakoshTelegram/Presentation/TelegramAttachments.swift` (`TelegramAttachment.isProtected` из сообщения)
- Rename: `Sources/MakoshApp/Files/FileSendMenu.swift` → `FileActionsMenu.swift` (`FileActionsMenu(handoff:, protected: Bool = false, ask: Bool = true, forward: Bool = true, present:)`: пункты «Отправить в Paperless…», «Отправить в чат…», «Отправить письмом…», «Спросить ИИ…»; при `protected` — ничего)
- Modify: `Sources/MakoshApp/Files/FilesHost.swift` (`pendingForward: FileSendRequest?`, `pendingAsk: FileSendRequest?`), `Sources/MakoshApp/Workspace/WorkspaceView.swift` («Спросить ИИ…»: стейджинг → `AIContextCard.file(.staged…)` или `.archive`/`.paperless`, `destination = .ai`, `ai.workspace.newConversation()`, `ai.workspace.add(card)`), точки встраивания из части 1 (`MailViews`, `TelegramAttachmentActions` с `attachment.isProtected`, `WhatsAppDetailView` с `message.details?.protected`, `TeamsFilePreview`, `FilesDetailView`, `PaperlessDocumentsView`)
- Test: `Tests/MakoshTelegramTests/TelegramMappingProtectedTests.swift` (сообщение с `CopyProtected` → `isProtected`, вложение наследует), `Tests/MakoshFilesTests/FileActionsTests.swift` (чистая `FileActions.available(protected:hasPaperless:) -> [FileAction]`)

- [ ] **Step 1: Падающие тесты** — mapping и `FileActions.available` (защищённый → `[]`; без Paperless → без «В Paperless…», но с чатом/письмом/ИИ).
- [ ] **Step 2: Убедиться, что падают** — Run: `scripts/test.sh --filter "TelegramMappingProtectedTests|FileActionsTests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать.**
- [ ] **Step 4: Прогнать** — Run: `scripts/test.sh --filter "MakoshTelegramTests|MakoshFilesTests"` и `scripts/build-app.sh` — Expected: PASS; сборка успешна.
- [ ] **Step 5: Коммит** — `git commit -m "Offer Ask AI on files and hide file actions for protected content"`.

### Task 8: Пересылка в чат и письмом

**Files:**
- Create: `Sources/MakoshApp/Files/FileForwardSheet.swift` (поиск адресата из `FileDestinationSearch` над `telegram.aiContextChats`, `whatsapp.chats`, контактами с `emails`; выбор → стейджинг → переход)
- Modify: `Sources/MakoshMail/Presentation/MailWorkspaceModel.swift` (`@Published package var composerAttachments: [URL] = []`; `compose(to: String? = nil, attachments: [URL] = [])`), `Sources/MakoshApp/Mail/MailComposeSheet.swift` (`attachments` инициализируется из `model.composerAttachments`, которые обнуляются при открытии), `Sources/MakoshApp/Workspace/WorkspaceView.swift` (`.sheet(item: $files.pendingForward)`; Telegram: `telegram.selectedChatID = id`, затем, когда `telegram.uploadTarget != nil` (ожидание до 5 с через `Task` с `yield`), `telegram.prepareUpload(source:mode: .file,target:caption: "",contextID: telegram.uploadContextID)`; WhatsApp: `await whatsapp.selectChat(id)` → `whatsapp.composer.attach([url], asFiles: true, targetAccount:, targetChat:)`; почта: `mail.compose(to:attachments:)`), `Sources/MakoshApp/Files/FilesHost.swift` (`stage`)
- Test: `Tests/MakoshMailTests/MailComposeAttachmentsTests.swift` (`compose(to:attachments:)` создаёт черновик с адресом и выкладывает `composerAttachments`)

- [ ] **Step 1: Падающий тест** — `testComposeWithAttachmentsAndAddress`.
- [ ] **Step 2: Убедиться, что падает** — Run: `scripts/test.sh --filter MailComposeAttachmentsTests` — Expected: FAIL.
- [ ] **Step 3: Реализовать.**
- [ ] **Step 4: Прогнать** — Run: `scripts/test.sh --filter "MakoshMailTests|MakoshFilesTests"` и `scripts/build-app.sh` — Expected: PASS; сборка успешна.
- [ ] **Step 5: Коммит** — `git commit -m "Forward files into chat and mail composers"`.

### Task 9: «Из Файлов…» в составителях

**Files:**
- Create: `Sources/MakoshApp/Files/FilePickerSheet.swift` (поиск `FilePickerSearch`, список каталога и Paperless, выбор → `FileHandoff` → стейджинг → `onPick([URL])`)
- Modify: `Sources/MakoshApp/Telegram/TelegramUploadView.swift` (`MakoshMenuItem("Из Файлов…", systemImage: "folder")` → `prepareUpload(sources: urls.map { .init(source: $0, mode: .file) }, …)`), `Sources/MakoshApp/WhatsApp/WhatsAppComposeView.swift` (`MakoshMenuItem("Из Файлов…")` → `model.attach(urls, asFiles: true, …)`), `Sources/MakoshApp/Mail/MailComposeSheet.swift` (кнопка рядом с «Добавить файлы» → `attachments.append`)
- Test: `Tests/MakoshFilesTests/FileSearchesTests.swift` (уже), сборка

- [ ] **Step 1–2:** тестов UI нет; контракт — Задача 4. Run: `scripts/build-app.sh` — Expected: сборка успешна.
- [ ] **Step 3: Коммит** — `git commit -m "Pick files from the Files section in every composer"`.

### Task 10: QA и документация

**Files:**
- Modify: `Sources/MakoshApp/AI/AISyntheticPreview.swift` (подставной файл: стейджинг PDF с текстом, карточка `.staged` в беседе; `FileTextExtractor` настоящий), `Sources/MakoshApp/Files/FilesSyntheticPreview.swift` (меню с «Отправить в чат…» показывает лист без адресатов — «нет подключённых чатов»), `docs/files.md`, `docs/architecture.md` (ADR-017), `docs/reference-interface.md`, `docs/development-status.md`, `docs/superpowers/plans/2026-11-05-ai-chat-panel.md` (пометка о замене лимита), `AGENTS.md` (одна строка: файлы к ИИ только явной карточкой; извлечение на Mac)
- Test: `Tests/MakoshAITests/AIQAIsolationTests.swift` (+ `testSyntheticPreviewStagesAFileCard`)

- [ ] **Step 1: Падающий тест** — синтетический посев кладёт файл в стейдж и карточку в беседу.
- [ ] **Step 2: Убедиться, что падает** — Run: `scripts/test.sh --filter AIQAIsolationTests` — Expected: FAIL.
- [ ] **Step 3: Реализовать; документация.**
- [ ] **Step 4: Проверка** — Run: `scripts/test.sh` (всё), `scripts/build-app.sh`; QA ИИ: `python3 scripts/run-ai-qa.py --bundle <debug-бандл> --launch` — карточка файла видна со страницами, вопрос по файлу отвечает подставной сервис; QA «Файлы» — меню с новыми пунктами; результат в `docs/development-status.md`.
- [ ] **Step 5: Коммит** — `git commit -m "Add the file card QA and document forwarding and AI files"`.

### Task 11: Живая проверка (только по команде пользователя)

- [ ] Договор из Paperless → «Спросить ИИ…» → вопрос о стоимости услуги; проверить страницы/диапазон и ответ.
- [ ] Форма автономо из Paperless → «Отправить в чат…» → выбранный пользователем чат → составитель с файлом; отправляет пользователь.
- [ ] Итог в `docs/development-status.md`; коммит `Record the live file forwarding and AI check`.
