# Интерфейс из выбранных референсов

Макош переносит подтверждённые компоновки и сценарии выбранных клиентов. Новый
экран не является поводом придумывать другую навигацию или постоянные панели.
Для Telegram исходный референс — TelegramSwift, revision
`579cebbf0c01fd41b712eff3647fa7f69db9665d` из `references.lock.json`.

Внешний UI TelegramSwift имеет отдельную GPLv2-границу, описанную в
`THIRD_PARTY_NOTICES.md`. Его исходники и TGUIKit не копируются в комбинированное
GPLv3-приложение. Компоновка и сценарии воспроизводятся собственным SwiftUI/AppKit
кодом. Research checkout нужен только для сверки; build/run/test от него не зависят.

Для отправки нескольких вложений подтверждены
`PreviewSenderController.swift:1823–1832,1890–1898` и
`SenderController.swift:647–704`: отдельная отправка переносит подпись в первое
текстовое сообщение; группы делятся по десять элементов и повторяют подпись,
которая относится к первому визуальному или последнему файловому вложению.
Собственный batch provider повторяет этот план, готовит все ресурсы и сохраняет
полный список native Local IDs одной транзакцией. Пустые подписи получают пустой
список entities вместо reference ranges вне текста — намеренная адаптация.
Multi-picker, batch controller/recovery и интерфейс подготовки ещё не подключены;
реальная доставка Account/network и runtime референса не проверены.

Подготовка вложения по-прежнему следует modal-сценарию
`PreviewSenderController.swift:1524–1543,2169–2180`; новая постоянная панель не
добавлена. Собственный restart lifecycle теперь сохраняет accepted receipt
в транзакции native enqueue. В явно синтетическом общем окне проверена потеря
UI ACK: неопределённый modal не предлагает Send, restart того же Postbox
убирает уже принятое вложение и очищает только исходную revision; новый черновик
переживает следующий restart и переключение Почта → Telegram. Это собственное
хранение Макоша; server delivery и старые uncertain записи отдельно не приняты.

В общем synthetic окне также приняты настройки Enter/⌘Enter: две строки выбора,
сохранение после завершения процесса, применение к открытому редактору, guarded
reply/edit/caption и newline/undo. Return и keypad Enter проверены на ответе;
черновик сохранён при переключении Почта → Telegram. Реальный IME и серверная
отправка остаются отдельными непроверенными критериями.

| Подтверждено в TelegramSwift | Реализация Макоша |
| --- | --- |
| `ChatMessageMenuItems.swift:1005–1011`; `ChatPresentationInterfaceState.swift:1684–1694,1702–1718`; `ChatController.swift:9753–9788`; `ChatInputView.swift:638–658`; `MessageActionsPanelView.swift:61–118`; `SenderController.swift:492–523`: меню Select, native IDs, лимит 100, панель вместо input, AND разрешений и native порядок пересылки | Собственные typed frozen selection/revision, строки с индикатором, delete/count/forward и Cancel/Escape вместо composer. Пагинация и смена сервиса сохраняют выбор; Cancel возвращает ordinary/reply/edit без изменения. Picker фиксирует revision; ordinary recipient открывает composer, initial Saved branch пересылает сразу (см. отдельную строку). Chat/account change очищает выбор — ограниченная адаптация lifecycle. AX маскирует spoilers и не использует raw fallback. Album selection описан отдельно ниже; Shift описан отдельно ниже |
| `ChatController.swift:6531–6577`; `ChatPresentationInterfaceState.swift:1684–1738`: endpoint-first Shift, cached half-open numeric IDs, Cloud/Local fallback, descending additions до 100, Shift сохраняет anchor | Собственный bounded Postbox ID lookup (recipe 7) без network/history-hole fetch или integer-gap scan. Range работает через страницы, сохраняет protected/Local и frozen versions; changed off-page source блокирует batch. Request/session/revision/account/window guards и timeout защищают callback; Forward ждёт завершения. Ordinary-deselect выбирает deterministic minimum native greater anchor вместо произвольного Set.first. Scheduled/topics/migrated-peer открыты; album group action описан ниже |
| `ShareModalController.swift:1296–1314,1315–1335`: own peer immediately enqueues and clears selection; ordinary peer stages composer | Initial history/selection picker закрепляет «Избранное» первым и по явному клику пересылает без navigation/recipient composer. Отдельный account Postbox intent/receipt сохраняет ordinary Saved input/reply/forward; fresh wholebatch admission, exact selection clearing, uncertain без resend и restart без enqueue. DEBUG native destination 10000 относится только к изолированному account -1. Accessory re-targeting описан отдельной строкой; live-account acceptance ещё открыт |
| `ChatInputAccessory.swift:227–242`; `ShareModalController.swift:1296–1335`; `SenderController.swift:492`; `ChatInterfaceState.swift:1397–1398`: свежий picker из accessory, own-peer enqueue с default options и удаление только forward IDs | «Другой получатель…» фиксирует context/chat/revision/intent и закрепляет «Избранное» первым. Явный full-row click ставит отдельную Saved operation с default author/caption, не отправляя старый comment/reply и не меняя чат. Native transaction объединяет Local receipt с CAS removal только исходного forward; rich input/selection/reply сохраняются, legacy originless schema1 читается. Unknown блокирует повтор/исходный composer; unreadable recovery блокирует prepared forwards до reconciliation. Cancel до dispatch сохраняет forward — адаптация вместо раннего reference clearing. Native QA проверяет ordinary re-target, cancel, Saved, loss-ACK, Mail→Telegram и restart. Specialized option parity и live-account acceptance открыты |
| `ChatInputAccessory.swift:244–294`: явный выбор автора, default coupling с подписью, отметки и unique author/caption counts; `ChatInterfaceState.swift:1178–1179,1310–1318,1348`: flags сохраняются, temp preference после decode отсутствует; `SenderController.swift:504–505`: native hideNames OR hideCaptions | Четыре отмечаемых пункта с counts из native author IDs и captioned previews. Typed action проверяет captured context/chat/intent/revision; выбор уже отмеченного Show фиксирует explicit false. Подпись меняет автора только до явного выбора. Optional schema4 field сохраняет explicit preference при ordinary retarget/restart — собственная адаптация; legacy без поля читается. Заголовок показывает preference, transport сохраняет native OR. AX/native проверяет fresh checked Show, оба выбора, caption cycle, restart и retarget; full specialized option parity/live-account остаются открыты |
| `ForwardMessagesObject.multipleSelection` (`ShareModalController.swift:1232–1234`), presentation `2015–2027`, notify `1611`, caption setter `239–244`: ordinary forward picker скрывает comment input | Комментарий вводится в composer выбранного получателя; отдельное поле в forward picker не добавляется. Generic perform(comment:) не доказывает наличие этого UI. Ранее записанный picker-comment gap снят после проверки видимости |
| `MessageActionsPanelView.swift:60–64,112–118,140–145`; `ChatSelectText.swift:110–140`; `TextUtils.swift:27–180`; `ChatController.swift:4411–4490`: delete/count/forward, ⌘C через responder, masked text и whole-selection delete scope | Собственные ⌘C с all-or-nothing cached lookup и exact revision guard; spoilers/service codes скрыты, typed photo/file/voice/video summaries. Delete подтверждается явно, Saved Messages everyone скрыт; fresh permissions и exact-ID native delete в одной transaction (recipe 8), без album expansion. PG/S3 archive не удаляется. Cancel/Escape рядом с count — адаптация общего окна. Exhaustive media localization/music metadata, special moderation/scheduled/topics/secret/paid и live-account QA открыты |
| `ChatHistoryEntry.swift:1184–1212,1294–1307`; `GroupedLayout.swift:52–59`; `ChatGroupedItem.swift:43–52,625–652,753–783,901–916`: native UI groupInfo, visual/file groups, first visual caption, точный tile и whole-group toggle | Собственная проекция только текущего окна без дополнительной загрузки. Мозаика фото/видео с отступом 4; файлы идут отдельными карточками внутри альбома. Tile/context action относится к одному ID; outer whitespace/author/caption/metadata — ко всему видимому альбому. Partial добавляет missing, full снимает всех; cap100 и frozen revisions сохраняются. Shift выбирает first newly added input member вместо reference Set.first. Все исходные captions/IDs остаются в модели. Полная pixel parity и серверное принятие открыты |
| `CoreExtension.swift:565–571`; `ChatInteractiveContentView.swift:481–486,853–863`: media spoiler сначала раскрывается, затем открывается | Native spoiler attribute сохраняется в descriptor; visual album и ordinary history/search показывают отдельное Reveal, прячут image/preview/play от AX и открытия до явного раскрытия. Состояние привязано к context и точному descriptor. Загрузка явная; thumbnail ограничен 512px и заимствует живой файл на время декодирования. Ready photo имеет отдельный native Button. Явное full-file download/save доступно до раскрытия; preview/player — после. Полный specialized renderer остаётся открытым |
| `ChatLayoutUtils.swift:16–32,76–114`; `ChatMediaItem.swift:600–610,774–777`: photo fit/minimums, portrait caption width, video bounds и отдельная invertMedia-вариация | Собственная bounded геометрия ordinary photo/video, aspect-fit вместо album fill, caption по умолчанию под media в history/search; placement описан следующей строкой. Native QA проверяет hidden search129 → Reveal → preview, свежий Reveal в history, exact selection129, video115 и portrait126. DEBUG поиск получает тот же album descriptor/version, что history. Сужение ниже reference minimum и min1px pathological video — собственные адаптации. Autoload, special renderers и exhaustive pixel parity открыты |
| `ChatRowItem.swift:114–121,1766–1767,1788`; `ChatGroupedItem.swift:43–52,1169–1172`; `ChatMediaItem.swift:774–777`; `CoreExtension.swift:307–320,1534–1539`: invertMedia, первый media member и первая непустая подпись | Native InvertMediaMessageAttribute сохраняется для полученных фото/обычного видео; тот же rich renderer переносит подпись выше media в history/search. Visual album берёт placement первого member и первую непустую подпись. Default остаётся ниже; WebM и nonvisual cards исключены. Native QA принимает search129 → Reveal → preview, focused history129, album129/130 и portrait126, caption group toggle exact129/130, Mail→Telegram/restart с черновиком и новым Reveal. New-media preparation placement, animation/map/paid/secret parity открыты; outer UI/TGUIKit не копировались |
| `GeneralSettingsViewController.swift:234–241,419–422`: две selectable строки; `FastSettings.swift:246–280`: app-wide Enter/⌘Enter, default Enter; `ObjcUtils.m:1329–1341`: обе Return-клавиши и modifier predicate | Native Settings с двумя взаимоисключающими вариантами; собственный `TelegramSendKey`, `@AppStorage` и существующий AppKit editor. Ordinary/reply, edit и caption явно передают guarded submit; rejected Command/Shift Return вставляет newline. Marked text остаётся в native input; реальный IME пока не принят |
| `PeersListController.swift:1864–1879`: заголовок 50 и дополнительная строка поиска 40; `1725–1731`: отступ поиска 10; `834–917`: названия «Диалоги»/«Архив» | Компактный заголовок и поиск этих размеров вместо большой панели Telegram, segmented picker и постоянного footer подключения |
| `PeersListController.swift:3278–3279`: архив открывается из строки списка; `1326–1337`: возврат отменяет поиск | «Архив» — первая прокручиваемая строка inbox; отдельный заголовок архива с возвратом, который очищает запрос. Пустой inbox также оставляет доступ к архиву |
| `Telegram-Mac/ChatListRowItem.swift:2245–2260`: обычный диалог высотой 70; `ChatListRowView.swift:908`: аватар 50×50 | Строки списка высотой 70, static native-фото 50×50 с инициалами при отсутствии/ошибке |
| `ChatListRowItem.swift:729–739,1134–1139`, `PresenceStrings.swift:60–84`: native presence, исключения self/CloudUser 777000, inclusive integer seconds и expiry; `ChatListRowView.swift:1974–1990`, `Appearance.swift:1248–1258,2953–2954`: круг 12×12 с внутренним 8×8, справа −3 и снизу 0, selected variant | Собственный online badge поверх аватара списка, отдельно от текстового статуса шапки. Обычный список использует готовый native presence; поиск — одну наблюдаемую выборку из кэша Postbox с отменой при замене запроса/папки/аккаунта. Таймер снимает значок без нового события; device clock/wake/activation пересчитывают его. Нет дополнительных bot/support исключений из header policy |
| `ChatTitleBarView.swift:195,377`: аватар заголовка 36×36 | Компактный заголовок с native-фото 36×36 и cached peer status, отдельно от состояния подключения |
| `ChatTitleBarView.swift:347–351,590`: лупа справа включает/выключает поиск; `ChatSearchHeader.swift:1021–1024,1183–1190`: отдельная строка высотой 44 и отмена с очисткой запроса; `ChatController.swift:9321–9330`: повторный ⌘F фокусирует существующее поле | Постоянное поле из заголовка убрано. Лупа открывает отдельную строку с фокусом, крестик/Escape очищает запрос и возвращает историю. ⌘F открывает/фокусирует поиск, сохраняя запрос; команда доступна только в окне с выбранным Telegram-диалогом. Смена диалога закрывает поиск. Фильтры по автору/дате и upstream-навигация по найденным сообщениям ещё не перенесены |
| `ChatTitleBarView.swift:475–522`: нажатие заголовка открывает peer info; `UserInfoEntries.swift:2279–2409`: профиль, затем телефон и username | Заголовок открывает нативную карточку пользователя, бота, группы, супергруппы или канала с доступными полями native peer/cache. Для человека ниже — явная связь с новым/существующим PostgreSQL-досье и переход в уже существующий экран досье |
| `ChatRowItem.swift:2988–3000`: внутренний отступ пузыря 11 | Отступ 11 вместо прежних 14; полный upstream renderer ещё не перенесён |
| `ChatRightView.swift:114–184`: ошибка, часы и одна/две галочки рядом со временем; `ChatRowItem.swift:2030–2034`: отдельное обозначение bot/self | Компактное время и индикатор в истории/поиске. Read берётся из native history entry; поиск без этого контекста не выдумывает прочтение. Bot/self обозначены отдельно от фактического read; у обычных публикаций каналов галочек нет |
| `ChatController.swift:3445–3491`: активное окно без modal; `7640–7648,7849–7851`: последнее видимое сообщение при высоте видимой части не меньше высоты строки минус 10; `AccountContext.swift:1362`: native interactive read | Геометрия реальных строк/viewport и небольшой AppKit gate допускают видимую границу только из текущей истории аккаунта/диалога/запроса. Сохранённые outgoing строки также читают предшествующие incoming. Поиск, неактивное/скрытое/свёрнутое окно и sheet не отправляют отметку. Native peer сохраняется и для связанной старой истории мигрированной группы |
| `ChatRowItem.swift:3809`, `ChatRowView.swift:1628`: контекстное меню сообщения | Ответ/правка/пересылка/удаление через правый клик; отдельные кнопки с многоточием убраны |
| `ChatInputView.swift:982–1030`: вложения слева, ввод посередине, действие справа | Одна скрепка с меню поддержанных фото/файлов, поле ввода и отправка справа |
| `ChatInputAccessory.swift:180–188,385–389`, `EditMessageModel.swift:70–83`: компактная полоса исходника над тем же полем ввода | Ответ и правка встроены в нижний composer с исходником и отменой; отдельный sheet правки убран |
| `ChatInputAccessory.swift:194–206`; `ChatInterfaceState.swift:1040–1043`; `ChatController.swift:3827–3849`; `ChatPresentationInterfaceState.swift:1163–1185`; prepared `RequestEditMessage.swift:185–195`: raw invert preference, menu и placement-only edit | Вся полоса правки открывает Up/Down menu для media; raw native placement независимо от текста/entities/selection и display. Exact session/revision/context guards; text/chat/service сохраняют выбор, cancel/source reopen и restart сбрасывают temporary edit. Fresh Postbox content сохраняет raw flag даже для legacy defaults; explicit override передаётся в engine, reconciliation сравнивает flag+text/entities. Native QA проверила whole-band menu, placement-only confirmation, input/chat/Mail transitions, cancel, synthetic ACK и restart. Новая подготовка media и live-server acceptance остаются открыты |
| InputView `ChatInputTextView`: форматирование выделенного текста через контекстное меню и сочетания клавиш; `UIInputView.swift:292–318`: ввод ссылки | AppKit NSTextView, меню форматирования, сочетания клавиш, диалог ссылки, native undo; постоянной панели форматирования нет |
| `ChatInterfaceState.swift:356–376,478–495,1168–1177,1213–1237`: точный ввод, attributes, selection и reply subject, включая пустой текст ответа; `1343`: editState при чтении сбрасывается | Текст, typed entities, scalar-safe UTF16-выделение и reply target сохраняются одной revision в зашифрованном Postbox, включая ответ без текста. Schema 4 читает legacy 1/2/3. Нативно проверены стили, undo/redo, переключение раздела/диалога и restart с выделением/ответом. Источник заново читается из текущего Postbox; недоступный источник блокирует отправку до retry/отмены. Edit теперь хранит отдельную per-chat session в памяти account context; смена диалога/сервиса восстанавливает полный input и выделение. Restart сбрасывает режим. Pending-caption restart подключён к runtime/UI; quote и серверные drafts ещё открыты |
| `AccountContext.swift:490,1198–1207`; `ChatInterfaceInteraction.swift:1014–1045`; `ChatController.swift:9084`; `ChatInterfaceState.swift:1143–1163,1343,1355–1371`: временная per-peer правка отдельно от ordinary/reply, без restart | Собственная per-chat session в текущем account context с исходной версией сообщения, полным typed input/selection и session/revision guards. Явная отмена сбрасывает edit/cache и возвращает ordinary/reply; applied ACK закрывает только захваченную revision. Новая версия source не получает старый кеш; account stop очищает временное состояние. Native QA приняла independent chats, rich selection через чат/сервис, cancel/source reopen, ⌘Enter и restart без edit при сохранённом ordinary/reply. Topics и server acceptance открыты |
| `SenderController.swift:606–617`: caption input → native entities; `PreviewSenderController.swift:1524–1543,2169–2180`: temporary input переносится в preview, обычное поле очищается, отмена возвращает original | Фото/файл открывает modal preview с карточкой документа или ограниченным предпросмотром нормализованного фото. Полный input/UTF16 selection переходит в подпись, обычное поле/reply временно скрываются; отмена/Escape возвращает исходный draft и reply. Durable original остаётся резервной копией. Edited-caption ACK очищает только исходную revision; новый ввод и несовпавший picker capture сохраняются. Очередь передаёт entities и проверяет mentions/reply. Runtime/UI восстанавливает pending file/photo, edited rich caption/selection и original revision из S3/PG + account Postbox. Нативно проверены file/photo restart, отмена без resurrection и synthetic ACK; submissionStarted восстанавливается uncertain без автоматического resend (regressions). Reconciliation живой очереди, native fault injection и premium limits открыты; дополнительная долговременная копия является адаптацией политики хранения Макоша, а не доказанной возможностью референса |
| `ChatInputView.swift:175–220`: отправка через `FastSettings.checkSendingAbility` и обработка Return | Настройка Enter/⌘Enter применяется к ordinary/reply, edit и caption; Return/keypad Enter, newline/undo и persistence проверены синтетически. Marked text остаётся нативному редактору; реальный IME ещё не принят |
| `ChatMessageItem.swift:814–819,969–1010`: комбинируемые стили; `844–871`: моноширинный код и блоки | История и поиск отображают исходные UTF16 entities; в истории блок кода имеет заголовок языка и копирование с сохранением пробелов/переносов. Syntax highlighting и копирование inline code ещё впереди |
| `ChatMessageItem.swift:928–930`, `FoldingTextView.swift:47–56,125–132`: выделенная цитата, сворачивание длиннее трёх строк до двух | Цитаты имеют цветную полосу/фон; флаг сворачивания и измерение визуальных строк управляют раскрытием. Состояние связано с точной версией сообщения и контекстом |
| `ChatMessageItem.swift:411`: selection ограничен copy protection | Отдельный canCopy учитывает сообщение и защиту группы/канала; выделение текста, копирование блока кода и action preview используют эту возможность независимо от пересылки |
| `ChatMessageItem.swift:785–813`: видимые URL/email и подтверждение TextUrl при отличающейся подписи | Безопасные HTTP(S)/mailto-ссылки; скрытая ссылка показывает фактический адрес перед открытием. Telegram deep links пока остаются обычным текстом |
| `packages/TGUIKit/Sources/TextView.swift:3115–3126`: первый клик раскрывает spoiler до обработки ссылки | Собственное состояние раскрытия на точную версию сообщения; доступное действие macOS проверено, прямое нажатие мышью пока не подтверждено |

Пересылка следует `ShareModalController.swift:1296–1359` и
`ChatInputAccessory.swift:227–302`: picker → recipient chat → forward accessory
и optional rich comment → явная Send. Cancel сохраняет ordinary input/reply;
опции и typed IDs/fingerprints хранятся в schema4 с черновиком. Another recipient
сохраняет комментарий в исходном чате. Native enqueue содержит comment + forwards
одним batch с полной повторной transaction admission и accepted receipt — это
собственная адаптация, тогда как reference отправляет их последовательными
операциями. Initial и accessory Saved Messages exceptions описаны в таблице; остальные selection actions, темы,
paid/secret и совмещение нового вложения с forward ещё открыты.

Telegram находится внутри общего `WorkspaceView`: выбор сервисов слева, список
выбранного сервиса посередине, переписка справа. Проверка постоянных черновиков
также использует общее окно; отдельный synthetic preview остаётся для старых QA.
Переключение сервиса сохраняет TelegramModel,
выбранный диалог и текущий черновик. Наличие остальных пунктов навигации не
означает, что их подключения уже реализованы.

Локальный PostgreSQL/S3-архив — собственная функция Макоша, отдельная от папки
архивных диалогов Telegram. Вместо постоянной полосы над перепиской он открывается
кнопкой `lock.doc` в заголовке списка. Ошибка/занятость видны на кнопке, полные
статусы и повтор — в существующем окне архива. Глобальное состояние подключения
перенесено в popover «О подключении»; оно больше не выдаётся за присутствие
собеседника под его именем. В заголовке отображается cached native presence;
реальная аккаунтная проверка остаётся отдельной задачей.

По отдельному требованию пользователя в шапке переписки добавлено меню
**Сохранять файлы в S3**. Это собственная настройка архива Макоша: личные cloud
чаты включены по умолчанию, группы и каналы выключены. Выбор хранится отдельно
для аккаунта и чата; старое меню не может изменить другой чат после переключения.
Неизвестное состояние блокирует изменение и предлагает повторить загрузку.
Отключение не удаляет текст и уже сохранённые объекты, но запрещает любые новые
копии в S3, включая подготовку отправки, оригиналы фото и обложки видео.
Подготовка восстанавливается из зашифрованных локальных файлов и не попадает
в очередь S3 после последующего включения. Сценарий не приписывается TelegramSwift.

Просмотр файлов следует проверенному сценарию `ChatFileContentView.swift:79–99`
и `QuickLookPreview.swift:68–145`: загруженный файл получает native Quick Look.
Для собственной функции локального архива Макош читает сохранённую копию из
S3 и показывает её в Quick Look sheet с отдельным временем жизни временного
файла. Это собственная реализация на SwiftUI/QuickLookUI; код внешнего GPLv2 UI
не переносился. Архивный просмотр не вызывает внешний запуск файла; сохранение
через native Save panel остаётся отдельным действием.

Карточка также сверена с `PeerInfoController.swift:1035`: подписка
`viewTracker.peerView(updateData: true)` сохраняет обновления после первого
значения. `PeerInfoHeadItem.swift:750–781` использует тип и счётчик участников;
`ChannelInfoEntries.swift:1474–1476`, `GroupInfoEntries.swift:2292–2299` и
`UserInfoEntries.swift:2374` задают описание и его скрытие для scam/fake.
Собственная SwiftUI-карточка показывает доступные поля и предупреждения,
различает неизвестный счётчик и ноль. Только Sendable DTO поступает на MainActor;
досье человека недоступно группам/каналам/ботам. Списки участников,
управление и остальные профильные действия ещё не перенесены. Синтетическая
проверка общего окна не устанавливает успешный server refresh.

Статические фото сверены с `AvatarContentView.swift:41,187` и
`PeerInfoHeadItem.swift:739–746`: список/заголовок используют small, карточка —
large representation. Собственный provider наблюдает native peer/resource,
использует `.avatar` reference и отменяет старую загрузку при смене фото.
Собственный bounded decoder и SwiftUI-круг заменяют initials только после
валидного изображения; внешний GPLv2 UI/decoder не копируется.
`PresenceStrings.swift:87–181`, `PeerPresenceStatusManager.swift:28–43`,
`TextUtils.swift:1354–1439` и `ChatTitleBarView.swift:869–897` подтверждают expiry,
approximate buckets, self/bot/support и optional counts. Макош использует
immutable DTO, проверенный native server offset и отменяемый timer; отсутствие
presence явно обозначено. `PresenceStrings.swift:104–137` также задаёт часы
в текущем календарном дне, «вчера в HH:mm» и даты с годом для прошлых лет.
Макош повторяет эти формулировки и обновляет их на границе часа, полуночи и года;
календарные дни учитывают timezone/DST. Native Unix timestamp не сдвигается
на server offset. Live presence отдельно не принято.

Нажатие аватара карточки следует `PeerInfoHeadItem.swift:1734–1778` и
`PeerPhotos.swift`: native список фото, приоритет cached personal/photo и fallback
текущего аватара. `MGalleryPeerPhotoItem.swift:27,58,117` подтверждает representation
1280 и avatar-list reference для исторического фото. Собственная SwiftUI-галерея
показывает статический кадр, имя, доступную дату, позицию и неполный total count;
стрелки мышью/клавиатурой следуют `GalleryViewer.swift:411–412`.
Отдельные list/image retry не выдают ошибку RPC за доказанное отсутствие фото.
Галерея теперь открывает отдельное borderless окно размером с экран родителя:
`GalleryViewer.swift:268–284` подтверждает уровень popup, чёрный фон 0.9 и footer
95 pt. `GalleryThumbsControl` задаёт полосу 400×80; Макош показывает реальные
ленивые миниатюры с отдельными native leases. `MGalleryItem.swift:534–542` и
`MagnifyView.swift:93–100` задают масштаб 0.25–8 с шагом 0.5. Добавлены drag/pinch,
поворот Cmd-R, Save As Cmd-S исходного скачанного representation, Escape/Space
и Cmd-W; команды окна работают также при русской раскладке. Файл сохраняется
независимо от трансформаций предпросмотра. `GalleryViewer.canShare` отключает
share при nil chatMode; для profile gallery такой кнопки тоже нет.
Внешний GPLv2 UI/decoder не копируется. Переход из аватара, точная тема/hover
и анимации миниатюр, дополнительный режим F, public fallback фото, stories,
видеовоспроизведение ещё не перенесены. Native API
возвращает первую ограниченную страницу; полная история фотографий не заявлена.

Это сверка конкретных элементов, не заявление о полном визуальном совпадении.
Собственная явная локальная пагинация пока видна отдельно. Полный перенос тем,
оставшегося sidebar/header chrome,
видеоаватаров/галереи, syntax highlighting, непрерывного выделения через несколько блоков,
custom emoji, предпросмотра отправляемых медиа и
остальных экранов Telegram остаётся в плане. Почта сохраняет выбранные роли:
MMail для функций, Aether Courier для визуального решения; другие каналы также
начинаются со своих референсов.

Маска spoiler используется также в AX-тексте, копировании и кратких исходниках
ответа/правки/пересылки/удаления/вложения. Это собственная адаптация: upstream
`TextView.swift:3323–3324,3361–3377` читает исходную строку для AX/copy, поэтому
защита этих путей не приписывается референсу. Архивный viewer пока хранит и
показывает plain text без entities; это ограничение сохраняется отдельно.
Неоднозначные вложенные code/quote entities и ссылки через границы блоков
сохраняют единый rich-text fallback: исходный текст и скрытые цели не меняются.
Language hint не показывается до раскрытия спойлера в коде. Защита копирования
относится к текущему Telegram reader/action preview; исторический архив пока
не хранит эти capabilities и не считается проверенным по этому критерию.
Правый клик по заголовку пузыря проверен; меню именно выделяемого текста требует
повторной native acceptance. Код размещает его непосредственно на Text, но
источник и успешная сборка не заменяют эту проверку.

Для сообщений с `SourceReferenceMessageAttribute` пока консервативно скрыта
вторая галочка. Полное правило `ChatRowItem.hasSource` зависит также от режима
экрана и crosspost-контекста; совпадение этих специальных случаев не заявлено.
Одна галочка означает наличие сообщения в Telegram, а не доставку устройству
адресата; read-state группы не является списком прочитавших.

Результаты сборки, регрессий и фактической native QA фиксируются в
[development-status](development-status.md), ограничения Telegram — в
[telegram](telegram.md).

## Подготовка нового фото: положение подписи

Telegram остаётся внутри общего окна Макош: выбор сервиса → диалоги →
переписка/досье. Проверены PreviewSenderController.swift:62–66, 388–394,
544–560 и 1893–1897: действие доступно в media-режиме даже для пустой подписи,
эффективный file-режим оставляет её снизу, leadingText передаётся при отправке.
Код перемещения поля ввода в reference закомментирован; Макош также оставляет
поле под preview и меняет положение только в отправляемом сообщении.
SenderController.swift:643–644 подтверждает native InvertMediaMessageAttribute.

Собственная SwiftUI-подготовка фото содержит нативное меню действий и контекстное
меню всей шапки с «Переместить подпись вверх/вниз». Для обычного файла пункта нет.
Выбор независим от текста/entities/selection, сохраняется с pending draft и
восстанавливается вместе с JPEG из S3. Контекст и revision защищают старые меню;
начатая/неопределённая отправка блокирует изменения. Введение schema2
явно сохраняет placement Bool; текущая schema3 добавляет spoiler (см. ниже).
Legacy schema1 восстанавливает положение снизу.

Фактическая native QA на собственной synthetic Postbox и отдельной схеме
PostgreSQL/S3 подтверждает оба меню, сохранение выбора при редактировании текста
и перезапуске, synthetic queue acknowledgement, отсутствие пункта для файла,
сброс новой подготовки, отмену с сохранением обычного черновика и переход
Почта → Telegram. Реальная авторизация/отправка в Telegram не проверялась.
Видео-подготовка описана в следующем разделе; playback/cover/альбомы и прочие media options остаются открытыми.
GPLv2 UI/ассеты не копировались; остальная визуальная parity не заявлена.

## Подготовка фото: скрытие под спойлером

Проверены PreviewSenderController.swift:381–386,1701–1705,1893–1897 и
MediaPreviewRowItem.swift:48,212: переключатель в меню, ordinary media eligibility
без secret/paid, forceSpoiler в preview и отдельный send flag. Собственная
SwiftUI-подготовка повторяет toggle через меню действий и контекстное меню всей
шапки: «Скрыть под спойлером» / «Отключить спойлер». Он независим от подписи и её
положения; для файла пункт отсутствует. Preview использует blur/material cover,
AX скрывает image. Анимация MediaDustView пока не перенесена; полная pixel parity
остаётся открытой. One-shot Send as Spoiler описан ниже.

Native QA подтверждает enable/disable, оба меню, masked preview, изменение текста
и placement без сброса spoiler, перезапуск с восстановлением всех трёх значений,
synthetic queue acknowledgement, reset новой подготовки и отмену с сохранением
обычного черновика. PostgreSQL/S3 retention и общая боковая панель не меняются.
Schema3 хранит explicit Bool; legacy1/2 восстанавливают false. Rebind сохраняет
latest tuple в исходном store; epoch, захваченный до load, отвергает старый
снимок даже после завершения записи. Held-export model regression проверяет отказ,
удаление временного экспорта и повторную загрузку актуального черновика.
Storage-only retry проверен controller regression;
нативная инъекция ошибки этой записи не выполнялась. Подготовка видео описана
ниже; playback/cover/альбомы, остальные media options и реальная отправка Telegram
остаются открытыми.

## Подготовка фото: разовая отправка под спойлером

PreviewSenderController.swift:1212–1244,1316–1324,1378–1380,1787,1893–1897
подтверждает RightDown/LongMouseDown на send button, команду
send(false, asSpoiler: true) и override asSpoiler ?? state.isSpoiler без изменения
preview toggle. Собственный SwiftUI Menu(primaryAction:) и contextMenu дают
обычный click для отправки и secondary/held menu «Отправить под спойлером».
Для обычного файла пункта нет; captured preparation/revision отвергает старое
меню. Подпись и placement замораживаются вместе с одноразовым true.

Native QA подтверждает правый и800ms held click, выбор команды и ordinary
primary click через synthetic queue; Escape оставляет подготовку, отмена
сохраняет ordinary draft, Mail→Telegram и restart его восстанавливают без
отменённого фото. Реальная сеть Telegram не использовалась. Остальные пункты
reference send menu (silent/schedule/online/effects), playback/cover/альбомы и
визуальная parity остаются открытыми. Подготовка видео описана ниже. GPLv2 UI/ассеты не копировались.

## Видео: общий выбор, первый кадр и воспроизведение

Общая боковая панель сервисов сохраняется. ChatInputAttachView.swift:105–122
задаёт общий выбор «Фото или видео». Собственная NSOpenPanel теперь принимает
изображение или видео; отдельный «Файл» сохраняет MP4 обычным документом.
Выбор пока одиночный; альбомы и отдельные ограничения канала ещё не перенесены.
Modal показывает фото либо первый кадр видео, переносит обычный rich draft в
подпись и предлагает прежние placement/spoiler/one-shot действия для обоих видов.
SenderController.swift:79–139 задаёт первый кадр, preferred transform и предел
320px; собственный AVFoundation decoder соблюдает эти параметры и проверяет
принадлежность/неизменность stage. Видео не перекодируется.

Native QA на отдельном synthetic Postbox и PostgreSQL/S3 проверила MOV/MP4,
портретную ориентацию кадра, маску и скрытие изображения из accessibility,
edited caption/placement/spoiler после restart, one-shot synthetic ACK и Escape
без отправки. PNG сохраняет photo normalization; MP4 через «Файл» остаётся
документом без media actions. Отмена фото/файла возвращает ordinary draft;
Mail→Telegram и restart не воскрешают отменённые вложения. Полный shared native
enqueue отдельно проверен real MediaBox/Postbox fixtures; UI synthetic provider
по-прежнему использует обозначенные StoreMessage fixtures, а не Account/network.

SenderController.swift:426–442,378–382 задаёт Video/supportsStreaming,
stem.mp4, video/mp4 и условный Animated. CoreExtension.swift:2953–3015 и
PreviewSenderController.swift:1743–1754 подтверждают inCollage=true даже для
свежего одиночного видео; финальный nil groupingKey не меняет этот выбор.
FetchVideoMediaResource.swift:50–72 сохраняет исходные байты; активной
перекодировки нет. Эти условия зафиксированы в metadata и тестах.

Первый кадр также кодируется в JPEG quality0.3, как SenderController.swift:104–127,
и сохраняется отдельным LocalFileMediaResource в native MediaBox. Ровно один
previewRepresentation передаётся исходящему видео. Общая подготовка проверяет
complete оригинал и точные байты JPEG до enqueue, удерживая оба ресурса. Первый
snapshot читается на native FIFO очереди после записей; incomplete даёт отказ,
а Void запись не считается подтверждением. Receipt проверяет ID, размер, dimensions
и все флаги явно: native equality часть полей игнорирует. Real MediaBox/shared
native enqueue/reopen проверяют миниатюру отдельно от synthetic StoreMessage UI.
Native CUA подтверждает MOV и локальное принятие через общую подготовку.
Воспроизведение в подготовке теперь следует MediaPreviewRowItem.swift:46–55,212
и ChatInteractiveContentView.swift:26–39,566–577,758–770,1136–1174: тихий цикл
в видимом key window, пауза вне него и отсутствие проигрывателя под спойлером.
Собственный AVPlayerView сохраняет aspect ratio и прежнее окно/меню. Только
проверенный owned stage доступен декодеру; MIME hint задаётся из проверенного
имени, а inode/stat сверяются после readiness. Перед submit/release/rebind
проигрыватель синхронно отсоединяется. Старый native view не может остановить
новый player. Ошибка открытия видна рядом с fallback первого кадра.
Четыре real AVPlayer regression проверяют MOV/MP4, mute, visibility, loop,
replacement, spoiler/cancel/rebind/send и отказ повреждённой подготовки.
Финальная native CUA проверила animated portrait MOV, accessibility видео,
скрытие под спойлером, Escape и ordinary draft после restart. Native key/occlusion
notifications отдельно через CUA не проверялись; события контроллера проверены.
Базовое меню/editor custom cover описано ниже; album/multiple selection, dust mask
и полная визуальная parity остаются открытыми.
Реальная отправка/доставка видео и полная Account pipeline не проверены.

## Обложка видео: хранение, передача и восстановление

SenderController.swift:130–165,374–382 задаёт отдельный JPEG quality1.0 и
native videoCover, сохраняя первый кадр в previewRepresentations. Собственная
реализация обрезает ориентированное изображение, ограничивает обе стороны320px
и проверяет dimensions/SHA256 owned stage. Обложка хранится отдельным encrypted
S3 object с PostgreSQL metadata. Schema5 переносит ссылку через caption/options,
submission и atomic receipt; старые schema1–4 без обложки читаются как прежде.
MediaBox удерживает три отдельных ресурса и сверяет complete оригинал и точные
байты обеих JPEG до enqueue. Receipt проверяет каждый native cover flag и
representation; предыдущие S3 объекты сохраняются.

ChatInteractiveContentView.swift:758–770 отключает autoplay при videoCover.
В существующем modal обложка заменяет preview первого кадра; проигрыватель не
открывается. Спойлер скрывает её из accessibility. Native CUA на заранее
сохранённой synthetic подготовке проверила обложку, spoiler, edited caption,
restart и local synthetic acceptance. Read-only Postbox/S3 проверка подтвердила
accepted receipt и сохранённые байты; следующий restart не открыл подготовку
повторно. Real native MediaBox/enqueue/reopen tests проверяют отдельный cover,
первый кадр и оригинал. Account/network/server delivery остаются непроверенными.

PreviewSenderController.swift:318–382,1575–1583 задаёт Upload/Change/Remove,
single photo picker и crop editor. Эти действия теперь доступны в прежнем меню
подготовки: одиночный NSOpenPanel, вложенный редактор, «Отмена» слева и «Готово»
справа. Собственная рамка перемещается, меняет размер четырьмя углами и сохраняет
фиксированное соотношение сторон. Стрелки и accessibility adjustment доступны
без мыши. SelectionRectView.swift:53–112 выбирает точный preset; при отсутствии
совпадения остаётся Original, то есть aspect самого изображения. Это не выбор
ближайшего preset. Замена сериализована и привязана к account/preparation;
повтор после неизвестного ACK сохраняет тот же S3 object. Удаление обложки
снимает её с текущей подготовки, сохраняя все предыдущие версии в архиве.

Native CUA проверила выбор RGB-образца, resize/стрелку/перетаскивание угла,
Cancel/Done, замену, снятие обложки, перезапуски и synthetic acceptance в общей
оболочке. Ошибка открытия меню после восстановления воспроизведена тестом и
исправлена. Postbox/S3 readback проверяет исходное видео, подпись, receipt и три
сохранённые версии; accepted подготовка повторно не открывается.

Редактор теперь сохраняет исходные байты и полную ориентированную геометрию
изображения (до20MiB,8192px и40M pixels), а не предварительно пережатый JPEG.
«Повернуть» (⌘R) и «Отразить по горизонтали» расположены между «Отмена» и «Готово»,
как операции в EditImageControls.swift:230–285. Оригинальный файл не изменяется;
Apply сверяет SHA256 того же snapshot и формирует отдельный JPEG≤320px quality1.0.
Обычная подготовка фотографий сохраняет прежнюю нормализацию.

Extensions.swift:1481–1570 и EditImageControls.swift:96–123 подтверждают CCW
quarter turns и horizontal mirror результата. При включённом зеркале следующий
поворот выглядит CW. Crop переносится CCW независимо от mirror, как в
EditImageModalController.swift:1068–1113/Extensions.swift:1882–1926. Это особенность
референса: одинаковый raster state может иметь разные crop paths при разном
порядке операций. Размеры preview, рамки и экспорта учитывают поворот.

Повторная сверка исправила прежние утверждения о gaps: у crop четыре угла;
восемь handles относятся к inserted image overlays.200×200.aspectFitted(canvas)
увеличивает квадрат до floor(min(canvas.width,canvas.height)), а не ограничивает
его200pt. Текущая нормализованная начальная геометрия уже совпадает с основной
формулой референса. Последующие изменения fitted geometry, resize и double-click
описаны ниже. Inserted images остаются открыты; Draw/eraser/undo перенесены ниже.
Outer GPLv2 UI/asset не копируется; общий sidebar и подготовка сохраняют прежнее
окно. Account/network/server delivery остаётся непроверенным.


## Рисование на обложке видео

EditImageModalController.swift:880–935 открывает отдельный canvas по полному
повёрнутому/отражённому изображению без crop, принимает список штрихов только
при Save и сохраняет прежний рисунок при Cancel. Эти переходы перенесены в
существующий cover editor Макоша. Снизу: «Отмена», undo/redo, переключаемые
кисть/стрелка, ластик, «Готово»; над ними непрерывная палитра с круглым индикатором.
Рисунок можно отменять целыми штрихами, включая принятые до повторного открытия.
Новый штрих очищает redo; цвет и толщина не меняют прежние штрихи.

EditImageCanvasController.swift:52–103 задаёт round cap/join, mean(sx,sy) для
толщины, clear только в отдельном paint layer, прямую стрелку first→last с
width×0.7, порогом abs(dx)>width×1.5 OR abs(dy)>width×1.5 и головкой2.5×width/45°.
Одиночный клик остаётся undoable действием без отдельной dot/erase primitive.
Собственный renderer сохраняет эти свойства; normalized original coordinates
и inverse transform удерживают рисунок при последующих поворотах/отражениях.

EditImageCanvasColorPicker.swift:151–169,235–299,342–403,430–452 задаёт девять
RGB-опор градиента, случайный первый цвет с последующим сохранением, weight0.22
(5pt), strip click (4pt), увеличение до18pt движением вверх, zoom knob и
округление толщины. UI повторяет эту палитру и жест, включая половину pt
у zoom knob на Retina и обводку только почти белого цвета. Маленькие исходники
в draw canvas не увеличиваются. ⌘D открывает Draw, как EditImageModalController.swift:933–943.
A/E/L используют физические
клавиши, как reference controller:488–512; Cmd+Z/Shift+Cmd+Z, Return/Escape
проверены в собственном окне. AppKit bridge ограничен этим sheet и не ставит
глобальных event monitors. Outer GPLv2 code/assets не копировались.

Native CUA подтвердила инструменты и отмену/принятие/поворот; отдельный readback
из encrypted S3 проверил320×160 JPEG с четырьмя цветными и двумя чёрными samples,
точную подпись, исходное видео и receipt после restart/local synthetic acceptance.
Это не runtime-проверка upstream UI или Telegram Account/network delivery.
Оставшиеся fitted/source-pixel различия описаны ниже; inserted images,
album/multiple selection и остальные Telegram flows остаются открыты.

## Геометрия и жесты обрезки обложки

SelectionRectView.swift:247–278,282–294,360–384 подтверждает отдельное ceil
позиций при перемещении, absolute ceil/clamp указателя для угла, resize по ширине
и double-click внутри selectedRect. EditImageModalController.swift:516–519,
1197–1204 сохраняет preset в данных и возвращает его через условный feedback.
Макош использует те же pointer правила и четыре собственных20pt L-захвата.
Двойной щелчок и доступное действие выбирают максимальную центрированную область
с сохранённым aspect. Parent SpatialTapGesture охватывает угловые hit targets.
Corner drag начинается после1pt движения: нативная проверка показала, что
minimumDistance0 менял рамку уже при обычном щелчке и ломал portrait double-click.
После исправления проверены оба угла, неподвижные щелчки и реальный drag.

Extensions.swift:1172–1185 задаёт shrink-only fitting: сначала width с ceil
height, затем height с ceil width. В crop и draw применяется общий helper и8pt
padding из modal.40×80 source не увеличивается;1001×601 в552×352 даёт552×332.
Минимальная ширина crop40pt относится к fitted canvas, не к исходным пикселям.
Opposite corner сохраняется; изображение ограничивает максимальную область.

Отличия остаются явными. Макош сохраняет bounded anchored aspect geometry и
детерминированно центрирует maximum. В reference applyRect сначала применяет
minimum40×40, а correction ratio зависит от active corner/force; возможны
промежуточные выходы за bounds и иная anchor-позиция. Upstream callback timing
не запускался. Следующий этап ниже исправляет initial fitted-point precision и
округление source x/y/width/height. Это прогресс переноса, не заявление полной
parity. Outer GPLv2 code/assets по-прежнему не копируются.

## Начальная рамка и пиксельная обрезка

EditImageModalController.swift:861–877 и Extensions.swift:1226–1228 задают
начальный квадрат floor(min(fittedCanvas)), затем aspect correction. Макош
применяет это один раз при первом появлении crop canvas.1001×601→552×332,
16:9 теперь даёт332×186.75pt вместо прежних331.420579×186.75pt. Original
следует fitted aspect; возврат из рисования не сбрасывает изменённую рамку.

Modal selectedRect:495–499, NSRect.apply:1860–1861 независимо округляют
source-pixel x/y/width/height. EditImageControls.swift:145–156 передаёт этот rect
в CGImage.cropping(to:). Собственный bounded renderer теперь использует эти
округлённые компоненты и пересечение с правой/нижней границей. Положительная
normalized область с нулевой округлённой осью отклоняется. Тесты проверяют
реальный staged JPEG, первый цветной пиксель во всех восьми ориентациях и
CoreGraphics intersection на half-pixel boundary. Native/S3 проверка1001×601
даёт320×192 cover с четырьмя ожидаемыми цветами и неизменным исходным видео.
Paint использует прежний CTM и bounded output; схема архива не меняется.
Inserted-image overlays перенесены следующим этапом; остальные Telegram flows
и полная parity остаются открыты.

## Вставленные изображения в обложке

EditImageModalController.swift:1033–1046,1142–1152 задаёт вставку, fitted-point
rect, захваченный multiplier и snapshot до смены выделения. Его восемь ручек
и Shift-геометрия сверены с256–384; Extensions.swift:864–872,1226–1228,
1860–1861 подтверждает fit/floor/центр и независимое округление source pixels.
EditImageControls.swift:70–154 рисует вставки после основного изображения.
Макош реализует это собственным SwiftUI/CoreGraphics кодом: файл/явная Paste,
перемещение, восемь ручек, порядок, Copy/Delete, whole-action undo/redo.
Пакетная вставка атомарна и отменяется одним действием. Draw sheet редактирует
фон и paint; вставки сохраняются в основном редакторе над ними. Итоговый JPEG
через существующий CAS попадает в S3; рабочие слои после закрытия не сохраняются.

Native проверка выявила и исправила потерю предыдущего выделения при drag/Undo
и сброс crop двойным щелчком по ручке вне bitmap rect. Capture выполняется до
выделения; parent double-click исключает реальные12pt hit regions восьми ручек.
Повторная проверка всех восьми ручек, Cmd+C/V, Delete/Undo/Redo, pointer resize/
Undo и возврата из Draw проходит. Borderless Menu доступен в AX. Prepared/accepted
readbacks и restart подтверждают320×192 обложку с четырьмя цветами и белой рамкой,
точную подпись, неизменное видео и сохранённый cover digest/receipt.

Собственные ограничения:20MiB/8192px/40M pixels на декодирование,16 живых слоёв,
40M сохранённых в текущем состоянии/undo decoded pixels и64 шага истории. Это
не точная гарантия peak RSS. Детерминированный центр заменяет random jitter;
новая правка очищает redo, no-op не добавляет undo. Вставки сохраняются при
unrotated mirror, где reference early return их пропускает. PNG Copy переносит
immutable bitmap, без исходного URL. Captured point rect/multiplier не меняются
при повороте/новом fit фона, как в reference; после refit возможна разница preview
и export. Release-only Shift, прерванные drag/import и край clipped hit testing
нативно не приняты; upstream callback runtime не запускался. Outer GPLv2 code/
assets не копируются, build/run/test остаются независимыми от research checkout.

## Несколько вложений: исследование и хранение подготовки

Сверены11 файлов TelegramSwift на закреплённом revision, включая
`ChatController.swift:5457–5543,5643–5656`, `PanelUtils.swift:22–50`,
`Extensions.swift:2158–2177`, `ThumbUtils.swift:222–260`,
`CoreExtension.swift:2953–3015`, `PreviewSenderController.swift` и
`MediaGroupPreviewRowItem.swift`. Оба picker используют multiple selection;
порядок `panel.urls` сохраняется с удалением повторов по первому вхождению.
Это не доказательство порядка щелчков внутри системной панели.

Режим media/file выбирается для всего набора. Initial media требует ровно
options `[.media]`; обычные документы могут отправляться группой, хотя preview
показывает их отдельными строками. Initial grouping берётся из eligibility,
а не из временного значения FastSettings. Группы ограничены10 элементами.
Точный классификатор учитывает music/voice/WebP и зависит от native attributes;
его полная реализация ещё впереди. Обложка выбирается в меню при одном видео,
но ранее выбранная обложка явно не очищается после добавления других файлов.

Source подтверждает три upstream особенности, которые нельзя скрыть под
заявлением о полном совпадении: caption передаётся заново в каждый chunk;
entity attributes повторяются даже на media без текста; локальные индексы второй
группы используются против общей URL-коллекции, поэтому действие над11-м файлом
может попасть на первый. Runtime референса не запускался. Для действий Макош
использует постоянные item UUID; caption повторяется на chunk, а media без текста получают пустые entities
по явно принятой send policy в telegram-album-migration.md. Точная preview mosaic-геометрия остаётся отдельным
неисследованным helper boundary.

Первый шаг в Макош — schema6 подготовки с ordered items, grouping и отдельными
S3-оригиналами/обложками на каждый ID. Pointer публикуется целиком, старые схемы
читаются, поздний сбой не заменяет прежнюю подготовку. Реальные Postbox/PG/S3
tests принимают порядок/байты/cover после restart и cleanup при ошибке третьего
объекта. Batch provider теперь поддерживает все native сообщения и полный
receipt. Существующий picker теперь принимает несколько файлов; controller и
recovery protocol сохраняют весь ordered schema6 набор. Preview показывает
visual chunks до10 элементов либо отдельные file rows. Перестановка, удаление,
выбор и восстановленная обложка привязаны к item UUID; устаревшие drag/context
actions отклоняются. Native QA подтверждает выбор трёх документов, перестановку,
удаление одного, separate grouping и точное восстановление двух IDs/подписи после
restart. Проверка очереди выявила DEBUG account sentinel `-1`, ошибочно переданный
в native PeerId; отдельный реальный Postbox regression воспроизвёл assertion и
проходит после отделения synthetic native author от archive account identity.
Native QA теперь проверяет visual10+1, перенос11-го ID в первую группу,
восстановление всех11 IDs/порядка/подписи после restart и принятие локальной
очередью. В отдельном наборе удаляется именно11-й ID; оставшиеся10 тоже приняты.
После restart принятые подготовки не воскресают, а прежний crashed submission
восстанавливается uncertain без повторной отправки. Context-menu действия
проверены мышью; сам drag/drop жест пока не проверен. Полная whole-list
классификация и archive остаются открытыми.
Telegram остаётся в общем WorkspaceView; live Telegram sending не проверялся.

Новые photo preparations из picker, включая одиночный выбор, сохраняют исходный файл отдельно от JPEG, как
требует граница `PreviewSenderController.swift:1617–1622` /
`SenderController.swift:331–360,390–391`: media/file строятся из текущего source URL,
а JPEG — отдельный ресурс. Макош сначала делает собственную неизменяемую копию
исходника и генерирует JPEG из неё. Schema7 связывает оба durable-ресурса с item UUID;
legacy JPEG-only подготовки не получают выдуманный оригинал. Schema8 добавляет переключатель
media/file; archive остаётся открытым. Референсные image edits отдельно заменяют текущий
URL; перенос этой операции не следует из сохранения raw source. Runtime референса
не запускался; GPLv2 UI/ассеты не копировались.

Schema8 хранит media/file choice всего набора. Сверены
`PreviewSenderController.swift:275–287,1743–1784`, `ThumbUtils.swift:222–260`,
`CoreExtension.swift:2953–3015` и `SenderController.swift:404–458` на том же pin.
Существующее меню подготовки предлагает оба режима и показывает текущий выбор.
File rows используют исходные имена/размеры; mixed list начинает с File,
переключение в Media снимает недопустимую группировку. Caption placement,
spoiler и cover сохраняются; File принудительно отправляет подпись снизу.

Static photo admission теперь использует размер исходного `NSImage` в points,
как `ThumbUtils.swift:227–236`, отдельно от безопасных pixel/byte/frame limits.
Нативная проверка в общей форме: PNG64×64@144DPI остаётся файлом354bytes;
PNG32×32@36DPI получает JPEG795bytes и сохраняет исходный PNG267bytes. File/Media
и подпись переживают удаление выбранного файла и restart при выключенном S3.
GIF, ordinary music, WebP и explicit recorded-voice path описаны ниже. Полный source contract,
включая order-dependent WebP options и отдельные native kinds, записан в
`telegram-album-migration.md`; это не заявление о полном совпадении с референсом.
Mode write меняет только Postbox metadata, сохраняет исходные local/S3 IDs и блокирует
Send до подтверждения. Native PNG regression проверяет настоящий FileName,
точные исходные байты MediaBox и complete receipt после восстановления.

Оставшиеся различия классификации явные: WebP сохраняет исходные байты с native sticker attributes. Static-photo admission уже использует
NSImage logical size. Полный ordered classifier, обычный OGG/Opus и recorder UI ещё
открыты, как Archive и image edits.

Сверены также `PreviewSenderController.swift:1690–1705,388–393`: mixed Media
допускает spoiler/placement, а grouping требует all-visual eligibility. Макош
разделяет эти условия. Regression удерживает actual mode CAS до rebind, затем
роняет запись до commit и проверяет original-store retry, запрет stale restore,
cancel/newer-pointer guards. Native UI evidence для текущего payload приведено
в development-status.md. GPLv2 UI/ассеты не копировались.

Removing the final visual item from mixed Media normalizes the remaining list to
File in one guarded metadata write, retaining captions and authenticated resources.
Strict schema8 decoding still rejects document-only Media. Frozen original-store
list/mode writes preserve retry and the latest caption/options after rebind,
including removal of the final visual item; a caption-only save cannot hide an
unconfirmed list change.

Обычная музыка сверена с `SenderController.swift:404–424` и
`packages/ObjcUtils/Sources/ObjcUtils/ObjcUtils.m:1260–1306` на том же pin.
Собственная реализация сохраняет исходные байты, целую длительность и оба тега,
включая пустые строки, и передаёт `Audio(isVoice:false)` перед `FileName` даже в
File. Schema9 строго хранит эти данные; неизвестные kind/fields, явные null и
конфликтующие video/cover/original поля отвергаются. Legacy generic files остаются
без аудиоатрибутов. Переключение presentation не теряет тип; смешанная группировка
проверяет frozen typed metadata. Обычное audio-only вложение использует имеющийся
экран File; новый экран или внешняя Telegram-форма не добавлены.

CoreAudio определяет container MIME по owned bytes; AVFoundation проверяет
длительность, короткий PCM-фрагмент и теги. MIME hint необходим для непрозрачного
локального имени и не берётся из расширения. Synthetic WAV/M4A/MP3 доказаны
тестами; полный decode и все кодеки не заявлены. В ObjC helper некоторые
iTunes/QuickTime Identifier сравниваются с Key constants; их runtime equality
не доказана. Макош использует native Identifier и проверенные теги M4A, поэтому
буквальное runtime совпадение с этой особенностью upstream не заявлено.


WebP сверено с `SenderController.swift:288–292,327–330,390–391,466–474`,
`CoreExtension.swift:2987–2988` и pinned `submodules/libwebp` helper. В обоих
режимах исходные байты получают `ImageSize`, `FileName`, `Sticker("",nil,nil)`
в этом порядке, MIME `image/webp`; Animated/Video не выводятся из анимации.
Собственный Apple ImageIO probe работает по содержимому owned payload, включая
обманчивые `.jpg`, `.wav`, `.bin`. Schema9 строго хранит только width/height.
Подготовка остаётся в имеющемся экране File общего service/sidebar окна;
группировка запрещена по frozen kind независимо от имени. Legacy generic WebP
не становится sticker при восстановлении только из расширения.

Нативные синтетические static lossless/lossy, animated и partial first-frame
fixtures подтверждают canvas dimensions320×160 и неизменность исходных байтов.
20-point WebP остаётся допустимым для typed probe: upstream40-point/aspect option
rules относятся к ещё открытому ordered classifier. Exact RIFF length,
20MiB/8192-axis/40M-pixel/256-frame limits и отказ вместо upstream512×512 fallback
— явные safety differences. Проба проверяет размеры frame0 и bounded thumbnail
256px; exhaustive frame/stream integrity не заявлена. Проверки текущего host27
не подменяют runtime macOS26.

`SenderController.swift:131–164` также включает WebP в optional JPEG transport
preview320px/quality0.7. Собственный ImageIO helper переносит этот контракт:
первый transformed frame, без увеличения маленького источника, отдельный JPEG
до1MiB. Frozen digest сверяется с теми же held-fd bytes до кодирования; исходный
WebP не меняется. `webPPreview` отделён от videoThumbnail; точный MediaBox readback,
уникальные IDs и strict native receipt сохраняют роль, размеры и все флаги.
Codec/encode failure допускает отсутствие превью; ошибки ownership/hash/cancel
остаются ошибками. Превью пересоздаётся после restart и хранится только в MediaBox,
без новых S3 objects или PostgreSQL payload bytes. В composer File пока остаётся
прежняя иконка файла; новый JPEG относится к transport representation.
Полный ordered option fold, Archive и image edits остаются открыты. GPLv2 UI/helper/ассеты не копировались,
новая codec dependency не добавлялась.

GIF converter сверено с pinned
`packages/TGGifConverter/Sources/TGGifConverter/TGGifConverter.m:18–254` и
`SenderController.swift:383–387,448–453`: canvas из GIF header, unclamped Float
delay с fallback0.1, порог0.011, cumulative PTS с timescale600 и повтор последнего
кадра при promoted Float delay>0.33. Собственный ImageIO/AVFoundation
leaf настроен на H.264 High4.0/512kbps. Native readback подтверждает H.264 без
audio/resize, timing и RGB,
частичные кадры, disposal2/3 и один кадр. Исходный GIF сохраняется неизменным;
выходной MP4 имеет отдельный owned ID и положительную измеренную длительность.
Schema10 теперь сохраняет raw GIF и MP4 отдельными encrypted local/S3 records,
с canvas/Float delays и SHA256 именно исходных байтов. Обе копии проверяются до
первого сохранения и после восстановления; retry и File/Media меняют metadata,
не создавая новых копий. При S3 OFF оба ресурса локальные, без последующей
автоматической загрузки после включения флага. Legacy generic files не получают
новый тип по расширению; узнаваемый небезопасный GIF остаётся исходным файлом.

Media выбирает MP4 с точными Video(duration0, flags[]), FileName и Animated
только вне collage; измеренная положительная MP4 duration остаётся в recovery.
File выбирает исходные байты с image/gif, ImageSize и исходным FileName даже
под .bin. Отдельный optional JPEG из raw frame0 имеет max320 без увеличения,
quality0.7 и cap1MiB; создаётся в MediaBox, не как новый S3/archive record.
FIFO readback проверяет его байты; native admission/ACK проверяют отдельный ID,
все representation flags и отсутствие лишних/переупорядоченных attributes.

На том же pin сверены PreviewSenderController.swift:316–318 и
SenderController.swift:383–386: upstream допускает меню cover для GIF через
media.isVideo, но GIF generator игнорирует customPreview. Макош отключает
действие cover для GIF; это явное отличие, без сохранения неиспользуемой обложки.
Image edit/paint применяются к TelegramMediaImage, не этому GIF-file mapping.
Существующие Media spoiler/caption controls сохранены. Нативная синтетическая
форма проверена с одним GIF под .bin в File и Media, подписью и restart после
удаления выбранного source path; точные gate/readback результаты — в development-status.md.

BGRA/sRGB с явным чёрным фоном, отключённый frame reordering, offline input,
строгие caps20MiB/4096-axis/16M-canvas/256frames/256M-work/600s и output128MiB —
собственные решения. Writer находится на отдельном actor; блокирующая native
отмена не выполняется в вызывающем UI cancellation handler. In-flight cancel,
transparency и odd-axis runtime остаются отдельными непроверенными случаями.
Внешний GPLv2 UI и helper code не копировались; Apple SDK не становится
зависимостью от `.references/`. Используется существующая форма общей оболочки Макош.


### Recorded voice: codec and durable native boundary

Сверены pinned `AudioRecorder.swift:285–345`, iOS
`OpusBinding/Sources/opusenc/opusenc.m:115–135,157–174,214–280` и
`SenderController.swift:295–312`. Внутренний кодек уже кодирует48kHz mono Int16
в Ogg/Opus:960 samples,30×1024bit/s, APPLICATION_AUDIO,16-bit depth и dynamic
pre-skip. Независимый decoder/CRC regression подтверждает точный PCM trim.
Собственные one-packet/page, vendor Makosh, отсутствие comment padding и
600s/20MiB limits отличаются от writer референса. GPL recorder/OpusBinding/
libogg code не скопирован. Отдельный explicit prepare(samples:) теперь сохраняет
schema11 с sampleCount/SHA256/nullable waveform, восстанавливает запись через
encrypted local/S3 и передаёт только native Audio(isVoice:true), audio/ogg,
nil media size, без FileName/preview/cover — как SenderController:295–312.
Schema1–10 не принимают voice; внутренний File payload не означает File-интерфейс
записи. Нет caption/group/spoiler/above. S3 OFF запрещает и подготовительные копии,
локальные записи не загружаются после включения. Bytes/count/digest проверяются
повторным decode при capture/restore/MediaBox. Файлы из picker не переопределяются
как voice по имени или MIME.

Новые explicit recordings теперь формируют100 значений по5 bit в63 bytes из
исходного PCM. Сверены AudioRecorder:594–745 и AudioWaveform:67–85: полные960-sample
пакеты, continuous100-sample peak windows, saturation Int16.min, виртуальные
zero/peak позиции, сумма running maxima ×1.8/100 с floor2500 и LSB packing.
Хвосты packet/window не входят в waveform; точный partial PCM сохраняется в Opus
как уже зафиксированное отличие кодека. Реализация использует100 bins без
pointer-overrun референсного helper. GPLv2 helper/recorder UI не копировались.
Waveform рассчитан из исходного PCM и не пересчитывается при restore; старый null
schema11 остаётся null. Native pulse regression подтверждает original12/decoded15,
exact frozen bytes и оба storage режима.

На историческом этапе кодека интерфейс не менялся: кнопка, recording/locked/preview-состояния и
live waveform/playback ещё открыты. Общая оболочка/чат сохраняются. Реальный
микрофон, live Account/server и minimum26 runtime ещё не проверены.

### Подготовка записанного голоса через controller

Свежий XERJ/source review подтверждает desktop-сценарий выбранного pin:
`ChatInputActionsView.swift:126–143` различает Click (смена voice/video) и
LongMouseDown (начало записи); `ChatRecorderOverlayWindow.swift:241–274,281–348`
отправляет при отпускании внутри, отменяет снаружи, фиксирует запись после
движения вверх более100 points и подтверждает отмену в fixed-состоянии.
`ChatPresentationInterfaceState.swift:284–291` допускает только duration >0.5s.
Отдельный desktop preview этими участками не подтверждён; прежнее слово preview
в плане не является доказательством референсного поведения. Перед внедрением
его нужно подтвердить отдельным текущим source/UI исследованием.

Source trace `AudioRecorder.swift:594–641,690–741` и отдельно pinned iOS
`OpusBinding/Sources/opusenc/opusenc.m:516–528,636–639` подтверждает порог через
complete960-sample packets и total_samples/coding_rate. XERJ encodedDuration дал
no match: этот iOS helper находится за пределами desktop submodule scope и
подтверждён исходником/commit/hash, а не заявлен как результат XERJ.

Новый внутренний controller entry принимает только explicit48kHz PCM с более25
полными пакетами (первый count24,960), сохраняет один schema11 Voice без caption/grouping и
требует durable batch перед отправкой. Кодек и restore исторических коротких
записей сохраняют свои существующие границы. Изменение caption запрещено также
до публикации staged item; cancellation снимает это ограничение. Реальные
controller/native queue regressions подтверждают ON/OFF, exact bytes/attributes,
accepted-pointer reopen и отсутствие повторной отправки. На историческом этапе
controller admission GUI и layout не менялись. Захват микрофона, hold/lock/cancel/one-time/round-video controls,
live waveform/playback и peer/slow-mode gates остаются открытыми. GPLv2 UI/helper
код и assets не копировались.

### Нативный recorder в общей форме Telegram — исторический этап обычного голоса

На том же desktop pin579cebbf0c01fd41b712eff3647fa7f69db9665d сверены
`ChatInputActionsView.swift:126–143`, `ChatRecorderOverlayWindow.swift:241–348`,
`ChatInputRecordingView.swift` (14-point dot и centisecond timer) и
`ChatController.swift:3536–3640` (privacy/slow-mode/media/fee gates).
Независимый NSButton/SwiftUI control теперь реализует hold300ms, release внутри
для отправки, снаружи для отмены, upward >100points для фиксации и подтверждение
отмены fixed-записи. Native peer/cache eligibility проверяется до/после разрешения
микрофона и перед отправкой. Оплата не подтверждается автоматически.

Кнопка остаётся в существующем common-window composer; приложение не зависит
от reference checkout. UI QA на синтетическом звуке подтверждает hold/release →
локальную очередь, locked timer/Continue/Cancel и прекращение записи при
Mail→Telegram. Первый UI run выявил устаревшую доступность NSViewRepresentable
во время восстановления черновика; явные value inputs исправлены и перепроверены.
Drag-инструмент возвращает noWindowsAvailable: реальный жест вверх и отпускание
снаружи визуально ещё не подтверждены, хотя state regressions проходят.

Оставшиеся отличия: нет reference floating70-point overlay/его точной анимации,
short click пока не переключает voice/video, round-video и one-time отсутствуют.
Доступное/клавиатурное действие явно фиксирует запись. При600s запись переходит
в durable preparation без автоматической отправки. Нет live waveform/playback
или отдельно доказанного desktop preview-сценария; generic caption/file sheet
для voice скрыт. Missing user cache (включая Saved Messages), secret/monoforum
и платный контекст консервативно отказывают. No-follow/CAF bounds и собственный
600s cap — решения Макош. Реальный микрофон, server delivery и minimum26 runtime
не проверены. GPLv2 UI/helper code/assets не копировались.


### Одноразовый голос в locked recorder

Desktop pin579cebbf0c01fd41b712eff3647fa7f69db9665d:
ChatRecorderOverlayWindow.swift:74–113,226–250,299–340 —36-point SingleTimeControl,
скрытый до lock, false по умолчанию, выбранное значение передаётся перед stop/send.
ChatPresentationInterfaceState.swift:265–312 и SenderController.swift:52–60,573–575
проводят его через VoiceSenderContainer в AutoremoveTimeout(viewOnceTimeout,0).
Свежие XERJ hits подтверждены исходниками; outer GPLv2 UI/helper/assets не копировались.

На native iOS pin a24bbe45f9861f736a79916a50898512f751e0dc отдельно сверены
ChatTextInputPanelNode.swift:2827–2833,2975 и ChatControllerContentData.swift:792–803,994:
другой TelegramUser без botInfo и sendPaidMessageStars; даже explicit zero
сохраняет nonnil paid context. Desktop control сам не фильтрует получателя.
Макош применяет поддержанный нативный gate; обычные голосовые в группах/каналах
сохраняют прежние правила. EnqueueMessage.swift:653–666 нормализует media TTL в
Autoclear(max,nil), сохраняя отдельный chat-wide Autoremove.

Независимая36-point SF Symbol кнопка в существующей recording line доступна
после lock и имеет явное selected accessibility value. Значение фиксируется
до async stop, проходит strict schema12 и не теряется при восстановлении.
Retained/restored preparation явно показывает одноразовый режим; переключателя
для downgrade после фиксации нет. Настройка S3 остаётся настройкой каждого чата;
OFF не имеет исключения для одноразового голоса. Результаты actual UI QA указаны
в development-status.md.

Открытые отличия: точный floating70-point overlay/анимации и жесты на actual UI,
short-click voice/video, round-video, live waveform/playback и отдельно доказанный
desktop preview. Текущий контроль расположен в общей строке composer и использует
системный SF Symbol вместо reference assets. Нет входящего once playback,
реального microphone/route, live Account/server/recipient или minimum26 runtime
доказательства. Это не полное визуальное совпадение с reference.
