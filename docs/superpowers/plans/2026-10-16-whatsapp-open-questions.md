# WhatsApp Open Questions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Закрыть WA-OQ-01/02/03/05/06/07/08 в существующем Макоше: rich presentation, фотографии профилей, пакет файлов, фоторедактор Zen и групповые аудио/видеозвонки.

**Architecture:** Существующие WhatsAppWorker/Repository/Files и отдельный AGPLv3 Rust-процесс сохраняют протокол, хранение и media ownership. Новые bounded компоненты отвечают за presentation, avatar cache, durable batch, photo recipes/render и participant-aware calls. MainActor проводит scoped commands и публикует только актуальные immutable результаты.

**Tech Stack:** macOS26+, Apple Silicon, Swift6, SwiftUI/AppKit, Foundation/URLSession, ImageIO/CoreGraphics/VideoToolbox/AVFoundation, CryptoKit, PostgreSQL/S3; Rust1.97.0, pinned whatsapp-rust0.7.0 и Opus1.6.1. Новых внешних зависимостей нет.

**Spec:** [утверждена пользователем 2026-10-16](../specs/2026-10-16-whatsapp-open-questions-design.md).

**Status:** Пользователь утвердил план и native inline исполнение в этом чате 2026-10-16 с одним свежим независимым финальным обзором текущей моделью. Реализация Tasks1–10 и разрешённые локальные проверки завершены. Один финальный обзор выполнен; все 6 Important исправлены RED→GREEN с повторными полными gates, 2 Minor документированы отдельно. Живые проверки остаются на паузе. Exact raw exits/hash checkpoints и task ledger сохраняются в ignored workspace.

## Global Constraints

- Сохранить текущий feature checkout и dirty baseline; не переключать ветку, не stage/commit/merge/push/publish. Root записывает точные raw exits и hash checkpoints в ignored .local/whatsapp-open-questions/ и task ledger вместо commit ranges. План не разрешает очистку старых QA данных.
- Reference Zen790066aa411d395562a572101a74057147af67db MIT; SDK=0.7.0/VCSf8165f282008935732e0b26d6f5cca5038ecd222, отдельный AGPLv3 worker, Opus1.6.1. Build/run/test не зависят от .references/ или прежнего проекта.
- Не править generated engine/registry cache. Необходимый SDK fix проходит regression и reviewed preparation patch/hashes/source archive. Не расширять dependency/feature graph ради удобства; notices/source artifact обязательны.
- Worker/executors владеют protocol/SQL/Keychain/crypto/files/JSON/image/media. Конструкторы не начинают account IO. Actor checks включены; native callbacks не наследуют MainActor. Shutdown/drain асинхронны.
- Identity: service/account/sourceID. После каждого await проверять account/chat/editor/call epoch. PG только encrypted records/metadata/keys/receipts/recipes; bytes файлов не в PG. Retained history без TTL/pruning/reset/rebind.
- S3 OFF запрещает каждую новую копию, включая originals/preview/edited/normalized/recovery. Enabling не продвигает старую локальную подготовку. Avatar cache всегда encrypted local, без S3.
- Files:≤10, каждый≤100MiB, сумма≤1000MiB. Batch — отдельные последовательные сообщения; caption/reply только у первого. Atomic admission всех children до первого dispatch; stop на rejected/unknown, никакого автоматического replay/restart-send.
- Photos:1600/4096px, JPEGquality0.82, no upscale; source≤40MP, recipe≤256 operations/32768 points; crop/rotate/pen/arrow/rectangle/palette/undo/reset по Zen. Video editor/filters/text-stickers не добавляются.
- Avatar: HTTPS pps.whatsapp.net/его поддомены, без redirects/cookies/credentials,≤4MiB/20s/16MP/512px; concurrency2; encrypted local64MiB/account и decoded8MiB/window. Другой CDN fail closed до отдельной проверки.
- Group calls:2..31 remote targets,≤32 total; accept/reject/start/invite/ring/leave, roster, mute/video.≤9 видимых remote tiles/decoders;≤4 frames/exchange по≤256KiB, суммарно≤1MiB raw; request≤2MiB/reply≤8MiB JSON; decode≤1920×1080/tile640×480. Не добавлять call links/screenshare/waiting-room admin/hand/reactions.
- Один active call/account, callID+epoch/source проверяется до control/media публикации. Leave относится к себе. Unknown offer/invite не повторяется и не возобновляется после restart.
- Live QR/account/provider/Keychain/TCC/microphone/camera/OS checks остаются на паузе. QA — обе qa_whatsapp_ schemas, pinned loopback PG/S3, fake provider/vault/keys/opener/media, остальные service hosts не стартуют. WA-OQ-04 visual dossier остаётся отдельным незакрытым критерием, если CUA снова откажет.

## File Structure

Все перечисленные новые имена ниже — предлагаемые интерфейсы, а не уже существующие symbols.

- Service presentation: новые WhatsAppContactPresentation.swift/WhatsAppMessagePresentation.swift; App WhatsAppContactCard.swift, существующие Views/HistoryModel/WorkspaceModel.
- Avatars: новые service WhatsAppAvatars.swift/WhatsAppAvatarHTTP.swift и App WhatsAppAvatarView.swift; native avatars.rs; existing Commands/Models/Worker/NativeSession/protocol.
- Batch: новые WhatsAppOutgoingBatch.swift/WhatsAppWorkerBatch.swift; existing Postgres/Outbox/Commands/ComposerModel/ComposeView; новый App WhatsAppOutgoingBatchView.swift.
- Photo: новые WhatsAppPhotoRecipe.swift/WhatsAppPhotoPreparation.swift/WhatsAppPhotoRenderer.swift и App WhatsAppPhotoEditorModel.swift/WhatsAppPhotoEditorView.swift; существующий Files/Composer.
- Calls: новые service WhatsAppGroupCallModels.swift/WhatsAppGroupCallMedia.swift, App WhatsAppGroupCallPicker.swift/WhatsAppGroupCallGrid.swift, Rust calls_group.rs/calls_media.rs; existing calls.rs/commands/jobs/CallController/CallMedia/H264Codec.
- Tests: scoped Swift tests рядом с существующими WhatsApp tests; Rust module tests рядом с новым native code. Новые scripts/run-whatsapp-qa.py и scripts/test-whatsapp-qa.py воспроизводят существующий QA-подход Teams/Telemost без импорта их runtime.
- Root-owned integration: Package.swift только если действительно нужен additive resource; scripts/test.sh/build-app.sh/prepare-whatsapp.py, notices/pins при фактическом изменении reviewed inputs; docs/status/reference/spec/plan/ledger.

## Review Focus

1. Недоверенные vCard/фото/URLs: ограничить размер/число полей/декодирование, не исполнить URI/redirect и сохранить исходник — Tasks1/2/5.
2. Сбой после части пакета, live owner другого процесса, поздний NACK и restart: уже отправленное не повторяется, unknown не обходится — Tasks3/4.
3. Смена окна/аккаунта/чата/recipe во время await: чужой draft/cache/preview/call не очищается и не публикуется — Tasks2/4/6/9.
4. Multi-device/pid/rekey/уход участника: кадров/PCM нет у другого пользователя, старый roster или call не оживает — Tasks7/8/9.
5. Максимальные фото/пакеты/видеопотоки и отмена: лимиты одинаковы на всех границах, bounded очереди и drain без блокировки UI — Tasks3/5/8/10.

Общие типы параметров интерфейсов ниже: accountID/id/sourceID/fileID/batchID —UUID;
chat/jid/groupJID/callID —String; epoch/rosterRevision/photo revision —UInt64;
participants/visibleStreams —массивы объявленных source IDs; content —WhatsAppOutgoingContent;
recipe —WhatsAppPhotoRecipe; mode —WhatsAppPhotoMode; refresh/ringOnly/video —Bool.
Photo expectedRevision —UInt64. Compose expectedRevision —UInt64?: nil допускает
только создание отсутствующего draft, число требует точного совпадения. Child
index —Int, file size —Int64, created —Date; byte equality scope сохраняется.

## Task 1: Читаемые контакты, опрос и список статусов

**Files:** Create Sources/MakoshWhatsApp/WhatsAppContactPresentation.swift, WhatsAppMessagePresentation.swift; Sources/MakoshApp/WhatsAppContactCard.swift. Modify WhatsAppViews.swift/WhatsAppHistoryModel.swift/WhatsAppWorkspaceModel.swift. Test Tests/MakoshWhatsAppTests/WhatsAppContactPresentationTests.swift, WhatsAppRichPresentationTests.swift.

**Interfaces:** `WhatsAppContactPresentation` содержит name/fields/isMalformed; `WhatsAppContactField` — kind/label/value/stableID. `WhatsAppContactParser.parse(_:fallbackName:) -> WhatsAppContactPresentation`. `WhatsAppMessagePresentation.make(_ message: WhatsAppMessage) -> WhatsAppMessagePresentation` содержит contact/bodyText/pollOptions, где option.id — source index, а не label. `WhatsAppChatListProjection.visible(_ chats: [WhatsAppChat]) -> [WhatsAppChat]` исключает exact status@broadcast. Parser/make выполняются через BackgroundWork в history model с прежней generation-проверкой; raw message не меняется.

- [x] Execution preflight: прочитать текущий статус/spec/plan/AGENTS, сохранить HEAD/branch/index/dirty baseline и полные hashes/backup всех затрагиваемых regular files. Проверить свежесть project/reference XERJ и scopedqueries→source. Запустить scripts/dev-db.sh up и baseline scripts/test.sh; сохранить raw exit/skips, не запускать ordinary app/real account. Root-only docs/manifests/Git, никаких новых веток/коммитов.
- [x] Добавить `testVCardFoldedEscapedAndMultiplePhonesRetainsRawSource`, `testMalformedAndOversizedCardHasSafeFallback`, `testPollQuestionOnceButDifferentBodyRetained`, `testDuplicatePollLabelsHaveDistinctIDs`, `testStatusFilteredFromListCountsAndRecipientsButArchiveRetained`. Assertions:256KiB/2048lines/128fields; FN/N/TEL/EMAIL/ORG читаемы, PHOTO/URI не запрашиваются; sourcePayload прежний; NFC+trim одинакового вопроса скрывает только повтор; обычный чат с именем «Статусы» остаётся.
- [x] `scripts/test.sh --filter 'WhatsApp(ContactPresentation|RichPresentation)Tests'` — записать meaningful behavioral RED, отличить compiler error от проверки поведения.
- [x] Реализовать parser/projection и native contact card; чтение исходного vCard через явное раскрытие/копирование. Не использовать Contacts framework/import или менять source history; current/history используют одну presentation boundary.
- [x] Повторить focused command; require0failures. Записать checkpoint/source hashes; проверить обычные text/poll voting/status tests.

## Task 2: Scoped аватары, безопасное скачивание и UI cache

**Files:** Create Sources/MakoshWhatsApp/WhatsAppAvatars.swift, WhatsAppAvatarHTTP.swift; Sources/MakoshApp/WhatsAppAvatarView.swift; Dependencies/WhatsApp/src/avatars.rs. Modify WhatsAppCommands.swift/WhatsAppModels.swift/WhatsAppWorkerSettings.swift/WhatsAppNativeSession.swift/WhatsAppViews.swift and native lib.rs/commands.rs/profile.rs/protocol.rs. Test WhatsAppAvatarTests.swift/WhatsAppAvatarModelTests.swift и native avatars module.

**Interfaces:** `WhatsAppAvatarScope(accountID: UUID, jid: String)`; descriptor `{pictureID: String, url: URL}` — worker-only protocol DTO; `WhatsAppAvatarImage` — bounded encoded preview/width/height/pictureID. `WhatsAppAvatars.image(scope:refresh:) async throws -> WhatsAppAvatarImage?`, `invalidate(scope:) async`, `close() async`. HTTP protocol `fetch(_ url: URL, maximumBytes: Int, timeout: TimeInterval) async throws -> Data` с production ephemeral no-redirect implementation и fake tests. `WhatsAppServing.avatar(accountID:jid:refresh:) async throws -> WhatsAppAvatarImage?` defaults unavailable; `WhatsAppPeerInfo.avatar` optional, native read op `avatar`, без durable outgoing mutation.

- [x] RED: `testAvatarIsolationAndLateCompletion`, `testHTTPSHostRedirectAndSizeFailClosed`, `testMissingPhotoDoesNotLoopRequests`, `testEncryptedCacheReopenAndBoundedEviction`, `testAvatarNeverWritesS3OrPGBytes`. Assert same JID/two accounts разные keys; refresh/invalidation отменяет старую публикацию;4MiB/20s/16MP/512px/concurrency2;64MiB cache и8MiB decoded cache; eviction не удаляет messages. Native test descriptor берётся из SDK response, sensitive URL не логируется.
- [x] Запустить `scripts/test.sh --filter 'WhatsAppAvatar'` и `python3 scripts/prepare-whatsapp.py --test`; сохранить RED до реализации.
- [x] Реализовать read-only descriptor в native worker через `contacts().get_profile_picture`, checked linked/account generation; actor HTTPS/crypto/ImageIO/cache. Конструкторы pure; существующий keyProvider используется с отдельным HKDF domain/account binding, missing key не сбрасывает cache. Persistent metadata encrypted, payload — приватный encrypted file, owner-only modes.
- [x] Вставить scoped avatar view в list/header/profile; bounded image decode вне MainActor, initiалы при no photo/forbidden. Picture notification инвалидирует точный scope, ручной refresh доступен. View.body не делает IO.
- [x] Focused Swift/native GREEN; rerun existing WhatsApp model/settings/native lifecycle tests. Записать actual checks/hashes/notices для заимствованной MIT части.

## Task 3: Durable batch admission и владение в PostgreSQL

**Files:** Create Sources/MakoshWhatsApp/WhatsAppOutgoingBatch.swift. Modify WhatsAppPostgres.swift/WhatsAppOutbox.swift. Test WhatsAppOutgoingBatchTests.swift.

**Interfaces:** `WhatsAppOutgoingBatch` содержит id/accountID/chat/created/orderedChildren; child `{index, outgoingID, reservedAttemptID, fileID}`. `WhatsAppBatchSnapshot` содержит batch/children:[WhatsAppOutgoing]/blocked. `WhatsAppComposeItem.file(UUID)/photo(UUID)`, `WhatsAppComposeAdmission.outgoing(UUID)/batch(UUID)` и `WhatsAppComposeDraft` — accountID/chat/revision/text/reply/orderedItems/admitted?. Repository `saveComposeDraft(_:expectedRevision:) throws -> WhatsAppComposeDraft`, `composeDraft(accountID:chat:) throws -> WhatsAppComposeDraft?`; source file/photo IDs — opaque scoped references, Task5 adds photo receipt validation. Add optional `WhatsAppOutgoingContent.composeRevision` with defaultnil. `prepareOutgoing`/new `prepareOutgoingBatch(accountID:chat:content:) throws -> WhatsAppBatchSnapshot` атомарно проверяют эту persisted revision и отмечают её admitted reference в той же transaction, что создаёт outgoing/batch. Child content не повторно потребляет compose revision. `batch(id:accountID:) throws -> WhatsAppBatchSnapshot`, `claimBatch(id:accountID:) throws -> WhatsAppBatchLease`, `releaseBatch(_:) throws`. Lease — opaque nonce+batch+account, хранится owner map и проверяется на каждом следующем child. Existing claimOutgoing сохраняет зарезервированный attempt для never-dispatched prepared child; старые single rows с nil получают новый UUID как прежде. Batch/compose SQL additive/encrypted; источник истины child state, не расходящийся aggregate state.

- [x] RED: `testBatchAdmissionAtomicBeforeAnyDispatch`, `testTenFiles100MiBAnd1000MiBBoundaries`, `testDuplicateAndCrossAccountFileRejected`, `testBatchLeaseBlocksSecondProcessAndStaleRelease`, `testReservedAttemptSurvivesRestart`, `testComposeAdmissionAndCrashCannotRecreateBatch`, `testLateNACKStopsContinuation`, `testLegacySingleOutgoingReadable`. Assert all child rows/file references и reserved attempts создаются одной transaction; injected COMMIT failure не даёт usable admission; caption/reply только index0; duplicate IDs/order стабильны. Persisted draft CAS и admitted ID фиксируются атомарно; повторное admission той же revision возвращает существующую точную ссылку либо conflict без нового outgoing. Foreign/live owner нельзя resolve/reclaim.
- [x] `scripts/dev-db.sh up`, затем `scripts/test.sh --filter WhatsAppOutgoingBatchTests`; RED на настоящем isolated PG. Separate subprocess проверяет session lock, не только actor interleaving.
- [x] Реализовать owned-table transaction, session advisory lease и in-process reentrancy guard. Вынести общую row validation/insert в internal primitive, чтобы batch не вызывал вложенный BEGIN через prepareOutgoing. Compose admission требует source text/reply/order и exact revision; subsequent manual edit/discard increments revision, старый callback не очищает новую. Existing outgoing stanza/resource/NACK/late-attempt checks сохраняются.
- [x] Повторить focused command и WhatsAppOutboxTests/WhatsAppOutgoingFilesTests; GREEN, source/hash checkpoint. Не удалять данные для исправления открытия старой schema.

## Task 4: Последовательная отправка пакета и composer

**Files:** Create Sources/MakoshWhatsApp/WhatsAppWorkerBatch.swift; Sources/MakoshApp/WhatsAppOutgoingBatchView.swift. Modify WhatsAppCommands.swift/WhatsAppWorker.swift/WhatsAppComposerModel.swift/WhatsAppComposeView.swift/WhatsAppFiles.swift. Test WhatsAppBatchDispatchTests.swift/WhatsAppBatchComposerTests.swift.

**Interfaces:** `WhatsAppServing.sendBatch(accountID:chat:content:) async throws -> WhatsAppBatchSnapshot`, `continueBatch(accountID:id:) async throws -> WhatsAppBatchSnapshot`, `batch(accountID:id:) async throws -> WhatsAppBatchSnapshot`. Synthetic returns admitted prepared children only. Worker uses Task3 lease plus existing single-child sendContent/submit as internal primitive; batch child cannot bypass batch lease through public resumeOutgoing. Composer `attach(_ files: [URL], asFiles: Bool, targetAccount: UUID?, targetChat: String?) async`, `moveAttachment(from:to:)`, `removeAttachment(id:)` и captured revision; old one-file API remains compatible.

- [x] RED: `testThreeFileBatchStopsAfterUnknownSecondWithoutReplayingFirst`, `testRejectedOrLateNACKBlocksRemainingChildren`, `testExplicitContinuationSendsOnlyPreparedChildren`, `testRestartNeverDispatchesBatch`, `testLateBatchAdmissionDoesNotClearNewDraft`, `testMultiSelectionOrderedAndCancellationPreservesPrepared`. Assert protocol count/order, identical reserved attempt for never-sent child, no first-file duplicate, caption/reply index0; unknown resolution не является network action.
- [x] `scripts/test.sh --filter 'WhatsAppBatch(Dispatch|Composer)Tests'` — meaningful RED.
- [x] Реализовать sequential loop под batch lease; каждый раз перечитывать children/NACK/account generation перед новым child. Never await provider while holding SQL transaction. Cancel/drain сохраняет точный dispatched receipt; rejected/unknown/closed останавливает loop, prepared remainder остаётся. Late NACK останавливает только ещё не допущенные children; уже in-flight запрос не отзывается и не повторяется автоматически.
- [x] Multiple picker/list/reorder/remove + явные лимиты/точный per-file status. Никакого «весь пакет отправлен» по одному ACK. Один file использует прежний сценарий; несколько — batch. Draft clear только после durable matching admission, если UI изменился — сохранить текущий draft.
- [x] Focused GREEN + существующие composer/outbox/files/S3 policy tests; проверить policyOFF до подготовки, между файлами и перед recovery. Plaintext leases освобождаются после завершения соответствующего child, файлы обрабатываются последовательно.

## Task 5: Photo recipes, worker render и encrypted restart

**Files:** Create Sources/MakoshWhatsApp/WhatsAppPhotoRecipe.swift/WhatsAppPhotoRenderer.swift/WhatsAppPhotoPreparation.swift. Modify WhatsAppFiles.swift/WhatsAppRepository.swift/WhatsAppPostgres.swift/WhatsAppWorkerFiles.swift. Test WhatsAppPhotoRecipeTests.swift/WhatsAppPhotoRendererTests.swift/WhatsAppPhotoRecoveryTests.swift.

**Interfaces:** `WhatsAppPhotoRecipe` — ordered `[WhatsAppPhotoOperation]`; operations crop(unitRect),rotate90,mark(kind,points,RGBA,widthFraction); `WhatsAppPhotoMode.standard/hd`. `WhatsAppPhotoDraft` — id/accountID/chat/sourceID/recipe/revision/optional exportedFileID+exportedRevision+mode, ни исходных bytes. `WhatsAppPhotoPreview` — encodedPreview/width/height; `WhatsAppPhotoRenderResult` — finalJPEG/width/height, только in-memory worker result, не SQL payload. Actor `WhatsAppPhotoPreparation.capture(file:accountID:chat:) async throws -> WhatsAppPhotoDraft`, `saveRecipe(id:accountID:chat:expectedRevision:recipe:) async throws -> WhatsAppPhotoDraft`, `preview(id:accountID:chat:expectedRevision:) async throws -> WhatsAppPhotoPreview`, `render(id:accountID:chat:expectedRevision:mode:) async throws -> WhatsAppPreparedFile`, `drafts(accountID:chat:) async throws -> [WhatsAppPhotoDraft]`. `WhatsAppPhotoRenderer.render(source: URL, recipe: WhatsAppPhotoRecipe, mode: WhatsAppPhotoMode) throws -> WhatsAppPhotoRenderResult` — off-main pure file/image preparation; durable upload/prepared receipt принадлежит PhotoPreparation/Files, не renderer.

- [x] RED: `testEXIFRotateCropMarksOrderAndNoUpscale`, `testStandardHDAndJPEGMetadataRemoval`, `testInvalidFiniteCropPointAndOperationBounds`, `testRecipeRestartUsesSameSourceAndExportReceipt`, `testPhotoOFFNeverPutsAnyDerivative`, `testLateRenderCannotReplaceNewRecipe`. Synthetic pixels verify geometry; assert1600/4096/quality0.82,40MP/256ops/32768points, unchanged source and removed GPS; ошибки не отправляют оригинал как fallback.
- [x] `scripts/test.sh --filter 'WhatsAppPhoto(Recipe|Renderer|Recovery)Tests'`; RED с injected keys и настоящим isolated PG/S3 где нужен receipt.
- [x] Реализовать encrypted local source+recipe storage, ImageIO orientation/downsample и CoreGraphics pipeline по Zen; preview≤1600, final mode bound, no all-images full decode. Рендер одного source одновременно; операции сохраняют normalized coordinates и порядок bake/crop/rotate. Send-as-file не вызывает renderer.
- [x] Сохранять recipe revision CAS; экспорт текущего recipe/mode idempotent по receipt. Task3 compose admission с photo item проверяет его current revision/exportedFileID/ordered mapping в той же storage transaction; старый экспорт после новой правки не проходит admission. Перед любым Files.prepare/S3 admission проверять текущую policy; existing local preparation не продвигается послеON. Все new JPEG leases/temporary files приватные и scoped; SQL без bytes, actor cancellation не удаляет source/history.
- [x] Focused GREEN + WhatsAppFilesTests и existing file recovery; записать hashes для MIT-adapted recipe/reference source и соответствующий notice.

## Task 6: PhotoSendSheet в общем workspace и восстановление draft

**Files:** Create Sources/MakoshApp/WhatsAppPhotoEditorModel.swift/WhatsAppPhotoEditorView.swift. Modify WhatsAppComposerModel.swift/WhatsAppComposeView.swift/WhatsAppViews.swift; extend service PhotoPreparation/Repository для compose metadata. Test WhatsAppPhotoEditorModelTests.swift/WhatsAppComposeDraftRecoveryTests.swift.

**Interfaces:** Compose metadata/admission consumes Task3 types/repository, photo data consumes Task5. Serving delegates к Task5 `capturePhoto/savePhotoRecipe/photoPreview/renderPhoto/photoDrafts`, плюс Task3 `saveComposeDraft/composeDraft`; defaults unavailable. Editor model `open(drafts: [WhatsAppPhotoDraft], accountID: UUID, chat: String) async`, `apply(_:) async`, `undo() async`, `reset() async`, `prepare(mode:) async -> [WhatsAppPreparedFile]?`, `cancel()`. Composer passes captured persisted composeRevision in outgoing content; exact admitted reference suppresses stale editable draft on reopen and opens existing queue. Model onlyconducts worker commands; image decode/EXIF/export не MainActor.

- [x] RED: `testLatePreviewAndExportRejectChangedAccountChatRecipe`, `testUndoRestoresCropRotateAndMarks`, `testCancelNeverSendsAndKeepsExistingDraft`, `testComposeRestartRestoresOrderCaptionRecipeWithoutSend`, `testFileModeByteExactAndPhotoModeEdited`. Suspended worker proves old result не заменяет новый preview, не очищает другой draft, и stale save conflicts rather than overwrites.
- [x] `scripts/test.sh --filter 'WhatsApp(PhotoEditorModel|ComposeDraftRecovery)Tests'`; RED.
- [x] Реализовать native Zen layout/tools/palette/strip/caption/HD/crop apply-cancel/undo-reset, accessibility names/keyboard cancel/undo. Подготовка через Task5; после успешного matching export передать ordered prepared IDs в Task4 без скрытой отправки. Повторный Send не экспортирует старую revision.
- [x] Сохранять ordered compose metadata зашифрованно; discard/manual edits — явные scoped CAS команды, никакой очистки из late completion. Reopen показывает editable draft только без admitted reference; принятый draft ведёт в уже существующую очередь, не создаёт дубль. Чтение не начинает provider/network/автоматическую отправку.
- [x] Focused GREEN + Tasks4/5 suites. Native визуальные geometry/tool/restart проверки входят Task10, unit passing не объявляет UI parity.

## Task 7: Групповой протокол, состав и command admission

**Files:** Create Dependencies/WhatsApp/src/calls_group.rs; Sources/MakoshWhatsApp/WhatsAppGroupCallModels.swift. Modify native calls.rs/commands.rs/jobs.rs/session.rs/protocol.rs; Swift WhatsAppCommands.swift/WhatsAppCallModels.swift/WhatsAppWorker.swift. Test Rust child-module tests; WhatsAppGroupCallCommandTests.swift/WhatsAppGroupCallSnapshotTests.swift.

**Interfaces:** Native calls.rs подключает `#[path="calls_group.rs"] mod group;` — дочерний модуль использует существующий private Calls/State, не global state. Swift `WhatsAppGroupCallSnapshot` — groupJID?,rosterRevision,participants:[WhatsAppCallParticipant],participantLimit; participant — jid/state?/devices:[WhatsAppCallDeviceIdentity(jid,pid?)]. Existing CallSnapshot.group optional with backward nil. New Action ops call_group_start/call_invite/call_ring и optional callEpoch (native serde rename/default); start использует options=targets,on=video, chat=groupJID; invite/ring target=callID,to=sourceJID,callEpoch=epoch. `WhatsAppServing.startGroupCall(accountID:groupJID:participants:video:) async throws -> WhatsAppOutgoing`, `inviteCallParticipant(accountID:callID:epoch:jid:ringOnly:) async throws -> WhatsAppOutgoing` проводят существующий durable admission, без resumable call replay.

- [x] RED: `testGroupTargetsTwoThrough31AndOwnAliasesRejected`, `testGroupOfferAndAdHocOfferRingsWithoutClobberingPersonalCall`, `testOfferNoticeAloneCannotBeAccepted`, `testStaleRosterAndLateAcceptCannotReviveCall`, `testInviteRingAndLeaveBoundToCallEpoch`, `testLegacySnapshotDecodeAndNoRelaySecrets`. Native fixtures используют IncomingCall.group и настоящий pinned CallAction; assert no key/relay/capability bytes в сериализации. Duplicate/own targets не превращаются в другого адресата.
- [x] `python3 scripts/prepare-whatsapp.py --test` и `scripts/test.sh --filter 'WhatsAppGroupCall(Command|Snapshot)Tests'`; RED до implementation.
- [x] Реализовать group_call(targets).group(groupJID).audio/video.start и accept текущего Offer с registry-owned group snapshot. OfferNotice informational only до настоящего Offer. Sanitized authoritative group_state обновляет DTO; неизвестные states observable, не silently active. invite_participant/ring_participant используют SDK; leaving вызывает hangup local endpoint.
- [x] Сохранить existing during/epoch/end_signal ownership и terminal-priority jobs. Group start включить в existing callRevision admission/cancel fence; invite/ring обязаны иметь exact callEpoch. Group/личные команды имеют одинаковые generation/restart/no-replay guards; ring запрещён для отсутствующего authoritative участника. Invite failure/unknown не означает новый автоматический вызов.
- [x] Native/Swift focused GREEN + all existing Calls/Command/CallController tests; source/feature graph unchanged. Тест fake/injected events не объявляется actual WhatsApp group connection.

## Task 8: Participant-aware media и ограниченный native decode

**Files:** Create Dependencies/WhatsApp/src/calls_media.rs; Sources/MakoshWhatsApp/WhatsAppGroupCallMedia.swift. Modify calls.rs, WhatsAppCallModels.swift/WhatsAppCallMedia.swift/WhatsAppH264Codec.swift. Test native media module и WhatsAppGroupCallMediaTests.swift.

**Interfaces:** `WhatsAppCallStreamID` — sender/device/pid с exact equality. `WhatsAppParticipantVideo` — stream/keyframe/orientation/bytes. Existing `WhatsAppCallOutput.videos` optional/default[]; Exchange.visibleStreams defaultnil для old1:1. `WhatsAppGroupCallMedia.setVisibleStreams(_:callID:epoch:) async`, `receive(_:callID:epoch:roster:) async`, `stop() async`; ≤9 per-stream codecs, callback `(stream, immutable decoded frame)` scope fenced. Rust media child module сохраняет source metadata VideoFrame, latest-per-visible-stream bounded queues и fair4-frame round-robin.

- [x] RED: `testTwoParticipantsNeverShareDecoderOrLastFrame`, `testPidMigrationAndDepartedStreamFlush`, `testGroupFramesBoundedFairAndRequireKeyframeOnReturn`, `testMalformedNALDimensionsAndJSONLimits`, `testGroupPCMUsesParticipantMixerWithoutForeignFallbackCrossTalk`, `testStopDrainsWithoutMainThreadWait`. Assert9decoders,4×256KiB/1MiB raw,2/8MiB framing,1920×1080 max; rekey/epoch/source mismatch не публикует frame. PCM fixture проверяет simultaneous speakers, silence/DTX, saturation и уход участника.
- [x] `python3 scripts/prepare-whatsapp.py --test`, `scripts/test.sh --filter WhatsAppGroupCallMediaTests`; сохранить behavioral RED.
- [x] Разделить onlymedia responsibilities текущего calls.rs в child module; SDK participant-aware PCM output для групп, личный ForeignAudio fallback не смешивает источники группы. Encoded frame/video routing сохраняет sender/device/pid; raw secrets не уходят в IPC.
- [x] Реализовать Swift stream codec manager, H264 validation до allocation, pixel bounds/downscale для tile640×480, asynchronous retired-codec drain. Roster removal/visible-page change очищает точный decoder; old keyframe из прежнего generation не начинает новый stream.
- [x] Focused GREEN + all WhatsAppCallMediaTests/CallControllerTests/PCM native tests; verify personal one-video JSON still decodes. Не собирать сырое аудио/видео реальных устройств.

## Task 9: Group picker, call grid и окна

**Files:** Create Sources/MakoshApp/WhatsAppGroupCallPicker.swift/WhatsAppGroupCallGrid.swift. Modify WhatsAppCallController.swift/WhatsAppCallView.swift/WhatsAppViews.swift and narrow WhatsAppCallMedia adapter. Test WhatsAppGroupCallControllerTests.swift/WhatsAppGroupCallPickerTests.swift.

**Interfaces:** Controller `startGroup(accountID:groupJID:participants:video:)`, `invite(jid:ringOnly:) async`, `setVisibleStreams(_:)`, `leave() async`; existing accept/end/mute/video сохраняются. Picker consumes existing `info(accountID:chat:operation:.groupInfo) -> WhatsAppPeerInfo` и member list, выводит selected2..31 remotes. UI group snapshot/tiles используют Tasks2/7/8; local preview отдельно от remote roster. QA-only preview labels synthetic и injected permissions/media, production permission flow unchanged.

- [x] RED: `testDelayedRosterOrPermissionRejectsNewContext`, `testIncomingGroupAcceptCancelAndLeaveFenced`, `testParticipantSelectionExcludesSelfAndDeduplicates`, `testInviteDuringEndCannotStartNewCall`, `testNineVisibleStreamsPagingAndPinnedTile`. Assert конкретный account/group/targets после каждого suspension; personal start по-прежнему работает, empty/oversized choice не dispatch. Preview не вызывает AVFoundation/TCC/provider.
- [x] `scripts/test.sh --filter 'WhatsAppGroupCall(Controller|Picker)Tests'`; RED.
- [x] Реализовать явный participant picker перед group start, no automatic all-members ring. Roster/state/avatars + pageable/pinnable grid≤9, mute/local video, invite/ring, «Покинуть звонок». Labels не обещают конец у остальных. Native window coordinator сохраняет ownership/cancel во время setup и не создаёт второй звонок на account.
- [x] Сохранить ownership проверки после permission/roster/media awaits; leave отзывает call/media generation до asynchronous teardown. Account/service/window change не пересвязывает уже допущенный вызов; late callback не открывает новое окно.
- [x] Focused GREEN + existing WhatsApp personal call/window/composer tests. Actual enlarged-window/native UI matrix — Task10, provider/hardware lane paused.

## Task 10: Изолированная QA, reproducible source/build и один обзор

**Files:** Create scripts/run-whatsapp-qa.py/scripts/test-whatsapp-qa.py, Sources/MakoshApp/WhatsAppOpenQuestionsPreview.swift и service WhatsAppQAIsolation.swift; Test WhatsAppQAIsolationTests.swift. Modify MakoshApp.swift/WorkspaceView.swift/test.sh/build-app.sh and docs/development-status.md/whatsapp-migration.md/reference-interface.md/main-thread-boundaries.md/architecture.md; approved spec/plan/ledger. Notices/source preparation changes only when required by actual inputs.

**Interfaces:** `WhatsAppQAIsolation.validate(configuration: ContactWorkspaceConfiguration, arguments: [String]) throws` требует both qa_whatsapp_ schemas, explicit config, pinned loopback DSN/storage, owner-only roots и marker. Runner `python3 scripts/run-whatsapp-qa.py --launch` creates fresh ignored run/bundle/config/fixtures, exact executable-text hash и fake service/media; ordinary launch не может случайно войти в marked QA.

- [x] RED: `testQARejectsEitherUnprefixedSchemaAndRealBoundaries`, `testMarkedBundleRequiresExplicitConfigurationBeforeIO`, Python `test_fresh_owned_run_and_matching_code`/`test_source_notices_and_no_private_resources`. Assert no real keys/provider/opener/mic/camera/OS notification request и no other channel hosts.
- [x] Реализовать fake fixtures: two accounts, malformed/полный contact, poll duplicate labels, retained status, scoped avatar/delayed invalidation,10 mixed files, photo recipes, partial batch unknown/restart,32-member sanitized roster/9streams/mixed PCM. Label synthetic, не real connected/sent/call active. Raw fixtures не копируют личные данные.
- [x] Повторить `scripts/test.sh --filter WhatsAppQAIsolationTests` и `python3 scripts/test-whatsapp-qa.py` до GREEN/0failures, включить Python QA checks в canonical test.sh. Не переходить к actual UI, если schema/endpoint/fake-boundary guard не доказан.
- [x] `scripts/dev-db.sh up`, full `scripts/test.sh`, `scripts/build-app.sh`; native clippy в exact prepared environment `--all-targets -- -D warnings`. Raw exits сохранить до сокращения. Skip и warnings назвать отдельно отPASS; тесты требуют real local PG/S3.
- [x] `python3 scripts/prepare-whatsapp.py --test --sources`; подготовленный corresponding-source archive извлечь в новую private directory и собрать standalone offline с reviewed public Cargo/Opus inputs в fresh target, без reference/legacy/account stores. Проверить current worker/src/patch/notices hashes, ARM64/helper/runtime inventory, strict signatures и отсутствие Swift→Rust linkage. Подпись ad-hoc не доказывает notarization.
- [x] Ordinary build без .references: временно переименовать clone в уникальный backup, гарантировать restoration в finally, не удалять. QA bundle содержит публичные provenance/source/notices, никаких private configs/API pair input/keys/session files.
- [x] Native CUA inspect actual fresh QA: cards/polls/status/avatars, selection/reorder10/max errors, crop/rotate/marks/HD/undo/restart/cancel, batch partial outcomes and explicit continuation, group picker/grid/paging/roster/invite/leave, old personal call preview. Обычное1200×800 и увеличенное окно. При CUA failure сохранить process/artifact/data и UNVERIFIED; не обходить ограничения. WA-OQ-04 досье не закрывать без действительного visual proof.
- [x] Refresh/check project/ref XERJ и actualqueries→source; freeze exact owned diff vs dirty baseline и supporting context. После выбора native execution — один свежий inherited-model read-only reviewer, без multimodel/quorum/override, Git и личных аккаунтов. Concrete findings воспроизвести regression и исправить одним проходом; повторить affected/full gates proportionately, без второго reviewer. Если выбран subagent workflow, использовать его полный task-review порядок с inherited model и максимум двумя агентами; root-only manifests/docs/Git.
- [x] Обновить docs/plan/ledger только фактическими results, разделить implemented/compile/synthetic UI/provider, сохранить паузу. Семь WA-OQ закрыть только по owning acceptance; лимиты/отдельные неподтверждённые возможности и отсутствующий real account перечислить. No automatic publication/cleanup.

Task10 acceptance limits: crop/mark drag and WA-OQ-04 visual proof remain
UNVERIFIED under the documented CUA restriction; current QA005 group inspection
has AX proof, with QA004 pixels for its unchanged layout. Provider/device/OS and
release/clean-machine/distribution lanes remain paused or unrun. Checked steps
record their execution and explicit limitations, not proof of those lanes.

## Execution, rollback and self-review

Задачи1/2 дают самостоятельные presentation/cache improvements;3→4 batch;
5→6 photo preparation/editor;7→8→9 group protocol/media/UI;10 интегрирует все.
Это один согласованный existing-service блок: composer/file policy общие у
batch/photo, а avatar/call roster/media сходятся в одном окне. Native inline
уменьшает одновременные правки общих типов; публикация ошибки partial-send или
source routing дорогая, поэтому один независимый final review обязателен.

Каждый checked task требует actual RED/GREEN или конкретного documented failure,
source/hash checkpoint и сохранённого raw exit; не заменять fail словомPASS.
При двух одинаковых отказах изменить подход. User pause/runtime permission
границы не обходятся, но independent static/unit/synthetic работа продолжается.

Rollback выключает новые UI commands/worker paths с сохранением additive PG
rows/recipes/cache/attempts/session keys; не reset checkout/schema/volumes и не
воспроизводит unknown call/send. Удалять только owned temporary plaintext leases
после drain; постоянная история и существующие S3 objects сохраняются.

Self-review: все семь выбранных WA-OQ имеют owning tasks; WA-OQ-04/live acceptance
отделены. ReviewFocus1→1/2/5,2→3/4,3→2/4/6/9,4→7/8/9,5→3/5/8/10. New interfaces
определены до consumers; batch использует existing child settlement, photo render
не пишетSQL/S3, group media сохраняет identity. План не обновляет backend/pin,
не обещает fake connection,2GB или видеоредактор. Tasks1–9 implemented and regression-checked; Task10 final gates/review are in progress.
The user approved inline execution; live acceptance remains paused.
