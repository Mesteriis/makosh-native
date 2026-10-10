# Интерфейс из выбранных референсов

Макош переносит подтверждённые компоновки и сценарии выбранных клиентов. Новый
экран не является поводом придумывать другую навигацию или постоянные панели.
Для Telegram исходный референс — TelegramSwift, revision
`579cebbf0c01fd41b712eff3647fa7f69db9665d` из `references.lock.json`.

Внешний UI TelegramSwift имеет отдельную GPLv2-границу, описанную в
`THIRD_PARTY_NOTICES.md`. Его исходники и TGUIKit не копируются в комбинированное
GPLv3-приложение. Компоновка и сценарии воспроизводятся собственным SwiftUI/AppKit
кодом. Research checkout нужен только для сверки; build/run/test от него не зависят.

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
| `ChatMessageMenuItems.swift:1005–1011`; `ChatPresentationInterfaceState.swift:1684–1694,1702–1718`; `ChatController.swift:9753–9788`; `ChatInputView.swift:638–658`; `MessageActionsPanelView.swift:61–118`; `SenderController.swift:492–523`: меню Select, native IDs, лимит 100, панель вместо input, AND разрешений и native порядок пересылки | Собственные typed frozen selection/revision, строки с индикатором, count/cancel/forward вместо composer. Пагинация и смена сервиса сохраняют выбор; Cancel возвращает ordinary/reply/edit без изменения. Picker фиксирует revision и только staging recipient composer. Chat/account change очищает выбор — ограниченная адаптация lifecycle. AX маскирует spoilers и не использует raw fallback. Shift-range, album selection, selected copy/delete и Saved Messages exception ещё открыты |
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
операциями. Saved Messages immediate exception, остальные selection actions, темы,
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
