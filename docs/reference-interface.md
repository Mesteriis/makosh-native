# Интерфейс из выбранных референсов

Макош переносит подтверждённые компоновки и сценарии выбранных клиентов. Новый
экран не является поводом придумывать другую навигацию или постоянные панели.
Для Telegram исходный референс — TelegramSwift, revision
`579cebbf0c01fd41b712eff3647fa7f69db9665d` из `references.lock.json`.

Внешний UI TelegramSwift имеет отдельную GPLv2-границу, описанную в
`THIRD_PARTY_NOTICES.md`. Его исходники и TGUIKit не копируются в комбинированное
GPLv3-приложение. Компоновка и сценарии воспроизводятся собственным SwiftUI/AppKit
кодом. Research checkout нужен только для сверки; build/run/test от него не зависят.

Десятый блок (2026-10-13) добавляет уведомления внутри тех же настроек общего
окна. Сверены `NotificationPreferencesController.swift:274–296,340–364,383–391`:
общий выключатель, предпросмотр, звук, привлечение внимания Dock, счётчик с
группами/каналами и выбор сообщений/чатов, подавление при активном окне.
`SharedNotificationManager.swift:390–403,581–609,697–716` подтверждает отдельный
поток новых уведомлений, скрытие содержимого секретных чатов/при блокировке,
беззвучные сообщения и проверку активности окна. Собственный UserNotifications
adapter использует современный API macOS. GPLv2-only UI, звуки и assets не копируются.

Категории и исключения на этом Mac добавлены отдельными собственными формами.
Строка уведомлений в карточке сверена с `UserInfoEntries.swift:2238–2243`;
вместо переключателя серверного mute она открывает явно локальное исключение.
Серверные mute/previews/sound/read/topic ограничения повторно разрешаются native
Postbox перед показом; локальное разрешение не отменяет серверный запрет.
Сброс касается только локальных настроек выбранного аккаунта, с подтверждением;
это отличие от полного server reset референса. Запрос разрешения macOS выполняется
только по кнопке. Звук пока системный/без звука; каталоги облачных/встроенных
Telegram-звуков, joined-contact toggle, реакции, истории, scheduled reminders,
ответ/прочтение из баннера и полное визуальное совпадение остаются открытыми.
Счётчик берётся из полного filtered native root unread state, не из страницы
списка; архив не включён. Уведомления не меняют постоянный архив или S3-политику.
Текущая локальная/native UI проверка записывается в development-status.md.

Девятый блок (2026-10-13) переносит двухэтапную аутентификацию внутри той же
приватности общего окна сервисов. Сверены `PrivacyAndSecurityViewController.swift:572`
и `TwoStepVerificationUnlockController.swift:66–119,232–334,704,976,1187`
на закреплённом SHA: текущий пароль/подсказка, управление паролем и почтой,
ожидание подтверждения адреса, ввод/повтор/подсказка/почта/код, восстановление
и назначенная сервером дата сброса с отменой. Собственный SwiftUI воспроизводит
эти состояния и порядок шагов. Смена пароля сохраняет подтверждённую почту.
Код подтверждения адреса и код восстановления отправляются разными typed RPC.
Пароль в обзоре не показывается; пропуск почты требует отдельного предупреждения.

Явное подтверждение каждой записи, предупреждение о защищённых данных Telegram
Passport, повторное чтение перед записью,30с deadline и требование обновить
неизвестный результат — адаптации Макоша. Проверенный текущий пароль действует
не более5минут в памяти; обновление, закрытие, отправка операции и повторная
проверка отзывают старое подтверждение. Поля и черновики очищаются при смене
контекста. Это не обещание криптографического обнуления Swift String.

Нативно проверены синтетические установка с почтой/без почты, смена пароля с
сохранённым адресом, неверный/верный код новой почты, повтор кода/отмена ожидания,
восстановление, ожидание/отмена сброса, отмена/выполнение отключения, закрытие и
повторное требование пароля. Финальная проверка клавиатуры проходит текущий
пароль по Enter и шаги новый/повтор/подсказка/обзор без мыши; после замены поля
фокус назначается только после его монтирования с отменой устаревшей задачи.
Сохранена общая боковая панель сервисов.
Form/вложенные sheets и дополнительный обзор отличаются от upstream InputData
navigation; полное визуальное совпадение, локализация всех ошибок и динамическая
подсказка длины кода после повторного открытия остаются открытыми.
`TwoStepVerificationUnlockController.swift:766–770` пересчитывает entries раз
в секунду. Собственный TimelineView теперь пересчитывает доступность кнопки
завершения сброса с той же частотой; после даты «Обновить» не требуется. Поля и
контекст сохраняются, сервер читается при явном подтверждении операции. Смена
доступности, отмена подтверждения и явное завершение проверены нативно на20с
синтетическом ожидании. До поправки тот же UI-assertion воспроизводит выключенную
кнопку после истечения срока. Реальные
аккаунты и серверная смена credentials не проверялись. GPLv2-only UI/assets
не копируются; собственная форма не зависит от research checkout.

Восьмой блок (2026-10-13) переносит блокировки пользователей. Сверены
`PrivacyAndSecurityViewController.swift:344–353,572,778–781`,
`BlockedPeersViewController.swift:110–137,249–265,294–300` и
`UserInfoEntries.swift:660–690` на том же закреплённом SHA. Список открывается
из приватности; блокировка выполняется из карточки пользователя, без новой
кнопки добавления в списке настроек. Own SwiftUI сохраняет список и отдельное
действие разблокировки. Подтверждения обоих действий — адаптация Макоша.
GPLv2-only код и assets не копируются.

Загрузка проходит все серверные страницы до показа полного списка: смещение
считает исходные записи, включая пользователей без имени. Это явное отличие
от дозагрузки референса при прокрутке. Предел —10000 записей и30с; повторённые,
меняющие общий размер, неполные, неподдерживаемые non-user страницы дают ошибку,
без усечения или разрешения записи. Имя заменяется подписью недоступности;
разблокировка требует пригодной identity из свежего ответа Telegram, даже если
пользователя нет в Postbox. Отсутствующий/min hash оставляет действие невыполненным.
Новые блокировки используют личную identity свежего кэша выбранного аккаунта.
Открытие диалога из строки списка, аватары и отдельный Edit-режим референса
пока не перенесены. Настоящая account acceptance остаётся отдельной проверкой.

Седьмой блок (2026-10-12) добавляет состав пользовательских и групповых
исключений. Сверены `SelectivePrivacySettingsController.swift:533–565,982–1060`
и `SelectivePrivacySettingsPeersController.swift:82–114,257–320` на том же SHA.
Сохраняются строки «Всегда/Никогда», зависящие от аудитории, отдельный список,
удаление записи и «Добавить пользователя или группу» с множественным выбором.
Выбор переносит запись из противоположного списка. Изменения списка и аудитории
объединяются в один черновик и одно подтверждённое правило. Редактор захватывает
account/context до открытия и отклоняет старый выбор даже после обновления с
идентичными правилами; черновик другого context не подмешивается. Вложенные «Готово»
только подготавливают черновик. Сохранение специальных Premium/bot/close-friend/
deny-contact правил остаётся неизменным; их переключатели не добавлены.

Поиск пока охватывает контакты и чаты, уже известные аккаунту в Postbox:
без запроса — контакты, с запросом — контакты и чаты. Возвращаются первые200
подходящих записей с явным предложением уточнить запрос; выбранные записи
сохраняются между запросами. Глобальный remote search из референса не перенесён.
Broadcast/secret/left/migrated группы и пользователи без пригодной identity
не предлагаются для добавления; существующую недоступную запись можно удалить.
Имена, отсутствующие в локальном кеше, имеют явную подпись недоступности.
Это ограничение первого переноса, не заявление полного selective-privacy parity.
Нативная синтетическая проверка и настоящий зашифрованный Postbox fixture
не подтверждают запись в реальный аккаунт Telegram.

Шестой блок (2026-10-12) продолжает настройки страницами приватности.
Сверены `PrivacyAndSecurityViewController.swift:599–610`,
`SelectivePrivacySettingsController.swift:413–465,508–565,1156–1228` на закреплённом
TelegramSwift SHA. Сохраняются список категорий, отдельные три варианта аудитории,
блок исключений и явное сохранение. Поиск по номеру имеет только Все/Мои контакты;
он открывается из номера телефона, P2P — из звонков, отдельными дочерними страницами.
Это адаптация для независимого подтверждения одного серверного правила за раз.
Переход к дочернему правилу требует сохранить или отменить текущий черновик: иначе
обновление после дочернего ACK сбрасывало несохранённый выбор родителя.
Подтверждение с повторной проверкой и отказ от автоматической записи при выходе —
явные адаптации Макоша. Существующие пользовательские, групповые и специальные
исключения сохраняются; их состав пока показан счётчиками и не редактируется.
Нестандартные серверные базы доступны только для просмотра. Подмены внешней
GPLv2-only реализации или её assets нет. Voice-message/Premium/global privacy,
блокировки, 2FA и удаление аккаунта не перенесены; настоящая account acceptance
не следует из синтетической проверки.

Пятый блок (2026-10-12) переносит собственным кодом основные настройки,
локальные темы/акценты и устройства выбранного аккаунта. Сверены
`AccountViewController.swift:387–414,609`, `RecentSessionsController.swift:250–305,358–409`,
`SessionModalController.swift:62–98,133–149`,
`AppAppearanceViewController.swift:382–403,468–477`, `AppDelegate.swift:1210–1220` на том же закреплённом SHA.
Настройки открываются из Telegram внутри общего окна сервисов; системное окно
Settings содержит общие локальные настройки и оформление. Сохраняются группы
текущего устройства, незавершённых входов и остальных активных сеансов,
карточка приложения/IP/местоположения, отдельные разрешения секретных чатов и
звонков, завершение одного/всех других сеансов и варианты7/31/93/186дней.
Текущий сеанс нельзя завершить этим экраном. Вместо изменения сразу из меню
срока используется явная кнопка применения и подтверждение: нативный macOS
picker иначе закрывал меню без показа alert. Все мутации требуют подтверждения,
свежего серверного списка и того же account/context. Это адаптация Макоша.

Оформление содержит системную, классическую, дневную и ночную локальные темы,
ряд из четырёх акцентов и предпросмотр переписки; выбор сохраняется локально.
Оно применяется к Telegram в общем окне, а после перехода к другому сервису
снова используется системное оформление. Узкий AppKit observer отслеживает
effectiveAppearance приложения: возврат передаёт явную системную схему, поскольку
preferredColorScheme(nil) в проверке оставлял предыдущее светлое оформление. Точные upstream palettes/assets,
облачные/custom темы, обои, расписание ночного режима, размер текста, переключение
bubble/list mode, animated device icons, QR linking и web sessions не перенесены.
Privacy/2FA/notifications и data/storage/proxy продолжены последующими блоками;
пределы переноса описаны ниже и в docs/telegram.md.
Локальная проверка с синтетическим аккаунтом не подтверждает действия над
реальными устройствами Telegram; они входят в отдельную account acceptance.

Второй блок (2026-10-12) заменяет прежние отметки ниже об открытых selected quote,
server drafts, syntax highlighting, custom emoji и обычных forum topics.
Сохраняются общая боковая панель сервисов, список диалогов/тем и область переписки;
новая отдельная оболочка Telegram не добавляется.

- `ChatMessageMenuItems.swift:382–397`: действие цитирования текущего выделения,
  `quote_length_max` (1024 по умолчанию), trimmed text/entities, nil offset и
  исходное media. Собственный AppKit reading view передаёт точное выделение;
  Model наблюдает текущий лимит, native enqueue повторно проверяет источник.
- `PreviewSenderController.swift:1545–1558`: обычные и animated emoji вставляются
  в тот же caption input. Собственный picker работает в ordinary composer и
  modal caption, сохраняет UTF16 selection/Undo и остаётся открытым после своей
  вставки. Смена input/context/catalog закрывает устаревший picker. Старые
  подготовки без frozen policy и recorded media намеренно не получают его.
- `ChatListRowItem.swift:2245–2262`: темы используют тот же ряд списка (обычно70pt),
  а не дополнительную постоянную колонку. Собственный список заменяет диалоги
  внутри Telegram: All Messages, General, название, иконка, draft/unread/mute/pin/
  closed состояния, возврат к диалогам и выбранная тема в заголовке переписки.
  Topic management, monoforums, scheduled и migrated-peer parity остаются открыты.
- `SecretChatKeyViewController.swift:37–99`:264px identicon, четыре строки
  fingerprint и пояснение сравнения. Собственный renderer использует публичный
  fingerprint и проверенный порядок битов, без копирования UI/assets. Полный
  secret handshake/media/TTL интерфейс не перенесён; доступен active plain text.
- `ChatController.swift:3608–3634,3959–3980`: подтверждение destination/count/Stars.
  Собственный modal показывает unit price и точный total, требует явной кнопки
  и не принимает Return как оплату. «Всегда платить», покупка баланса, purchase
  paid media и анонимная/send-as платная отправка не подключены.

Code header/copy/selection/spoiler layout сохранён; цвета добавляет независимо
закреплённый Prisma/Boost, перечисленный в THIRD_PARTY_NOTICES. WebP/TGS/WebM
custom emoji воспроизводятся только в видимых местах, с Unicode fallback для
неподдерживаемого профиля или превышенных лимитов. Это не полная sticker parity.
Конфликт server drafts использует собственные две явные кнопки выбора и сохраняет
текущий ввод до подтверждения native CAS; такая защита — адаптация хранения Макоша.
Фактические автоматические и native UI результаты записаны в development-status;
само наличие экранов или успешная компиляция не доказывает их runtime-приёмку.
В upload preview пока показано имя чата без названия выбранной темы; target,
восстановление и native admission сохраняют и проверяют её идентификатор.
Сверка полного secret/paid-media интерфейса отложена вместе с неподдержанными
key-agreement/media/purchase сценариями, перечисленными в `telegram.md`.

Текущий медиаблок (2026-10-12) заменяет прежние отметки об открытых premium
limits, Markdown, drag/drop и предпросмотре файлов. Подтверждены
`PreviewSenderController.swift:1091–1107,1171–1187,1213–1238,1261–1280,1824–1837,2001–2010`,
`SenderController.swift:327–369,455–474,610–617`, `ChatInterfaceState.swift:590–851`
и `PremiumLimitConfig.swift:110–111`. Новые подготовки имеют schema19: лимит
текущего пользователя и native caption-capability каждого File заморожены;
Markdown/cloud hashtags преобразуются перед отправкой. Старые схемы не меняются.

Во время drag в переписке появляются зоны «Файлы/Медиа», в открытом modal —
«Добавить файлы». Асинхронная загрузка проверяет прежний account/chat/input и
revision; Send остаётся явным действием. Добавление сохраняет исходные ресурсы,
при активном Archive пересобирает ZIP до атомарного подтверждения всего набора.
Вместо reference Shift-autosend сохраняется явная Send — адаптация Макоша.

FileContent/MusicContent и `ChatLayoutUtils.swift:157–175` задают отдельные
строки: graphic/PDF70pt, music40pt, static typed WebP208pt aspect fit. WebP с
выбранным JPEG MIME в File остаётся обычной graphic-строкой. Музыка играет только
по нажатию из отдельной локальной копии, которую отмена/таймаут освобождают.
Полная анимация стикеров и смешанный reference collage остаются различиями.

Floating recorder повторяет120pt/80pt круг,350ms/2pt hold и strict100pt lock,
контур замка и outside-cancel confirmation. Prepared round preview сохраняет
постер после остановки capture session. Собственный gradient заменяет GPLv2 UI
assets; на лимите длительности требуется явная Send. Автоматические проверки
жестов и синтетическое AX-действие не доказывают физический timed hold или
запись камерой/микрофоном. Фактические UI/gate результаты — в development-status.

Для отправки нескольких вложений подтверждены
`PreviewSenderController.swift:1823–1832,1890–1898` и
`SenderController.swift:647–704`: отдельная отправка переносит подпись в первое
текстовое сообщение; группы делятся по десять элементов и повторяют подпись,
которая относится к первому визуальному или последнему файловому вложению.
Собственный batch provider повторяет этот план, готовит все ресурсы и сохраняет
полный список native Local IDs одной транзакцией. Пустые подписи получают пустой
список entities вместо reference ranges вне текста — намеренная адаптация.
Multi-picker, batch controller/recovery и интерфейс подготовки подключены;
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
| `ChatTitleBarView.swift:347–351,590`: лупа справа включает/выключает поиск; `ChatSearchHeader.swift:1021–1024,1183–1190`: отдельная строка высотой44 и отмена с очисткой запроса; `ChatController.swift:9321–9330`: повторный ⌘F фокусирует существующее поле | Лупа открывает отдельную строку с фокусом; Отмена/Escape очищает запрос и возвращает историю. ⌘F открывает/фокусирует поиск, сохраняя запрос; команда доступна только в окне с выбранным Telegram-диалогом. Смена диалога/темы закрывает поиск. Расширение строки и оставшиеся отличия описаны ниже |
| `ChatSearchHeader.swift:1147–1161,1183–1209`: Up — старее, Down — новее; ввод30pt, навигация слева, From/Calendar/Cancel справа | Собственная SwiftUI-строка44pt сохраняет запрос, фильтр и список при переходе к сообщению; номер результата возвращает список. Переход старее догружает следующую страницу, новее не зацикливается. Контекст запроса отвергает устаревшие клики и callbacks. Нативная QA подтверждает130 результатов → история130 → старее, сохранённый запрос и видимую строку |
| `ChatSearchHeader.swift:743–750`; `ChatInterfaceStateContextQueries.swift:386–451`: From для групп, участники и100 последних авторов, собственный аккаунт первым | Выбор автора через native members/recent authors с отдельным cancellable запросом и deadline. Нативная QA выбирает собеседника и получает65/50 совпадений. Пустой запрос участников супергруппы ограничен кэшем engine; полная директория участников и отдельный reference suggestion-row renderer ещё не перенесены |
| `ChatController.swift:3736` и native `searchMessageIdByTimestamp` → `downloadMessage`: переход к дате в истории | Календарь использует местную полночь и точный Int32 timestamp, сохраняет запрос/черновик/тему. Нативная QA открывает15.11.2023 и переходит к первому сообщению дня. Это переход по календарю; произвольный диапазон дат не заявляется. SwiftUI DatePicker заменяет собственную reference calendar-view |
| `PeersListController.swift:2111–2117`: global tags40pt; `SearchController.swift:825–880,1353`: области all/private/groups/channels и general/peer locations | В существующей боковой панели общие категории Все/Фото/Видео/Ссылки/Музыка/Голосовые/GIF/Файлы, область и ограничение конкретным диалогом. Голосовые включают voiceOrInstantVideo. Нативная QA подтверждает6 фото →1 канал →2 группы, точную тему Разработка при открытии результата и поиск внутри выбранного диалога. Локальные совпадения диалогов остаются ограничены выбранным кэшем; remote peer discovery, Saved-tag suggestions, remote hashtag/Stars search и полный reference renderer результатов ещё не перенесены |
| Native `SearchMessages.swift` и Postbox global FTS | Общий поиск исключает секретные сообщения из групп/каналов и применяет media tag до объединения/подсчёта. Секретный поиск с автором или пустым текстом+media явно недоступен; global media-only показывает ограничение в применимых областях. Поиск внутри мигрировавшей группы сохраняет выбранный современный диалог и точный старый MessageIndex. Пустой Secret FTS+tag не заменяется неограниченным сканированием истории. Полная Secret media parity остаётся открыта |
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
| `PreviewSenderController.swift:934–970,1263–1277`; `CoreExtension.swift:323–337`: один preview entry с caption-capable media или одна группа → Caption, иначе Comment | Подсказка, счётчик и native AX label следуют режиму: Media-альбом до 10 → подпись; несколько альбомов/отдельных строк и WebP File → комментарий; Archive → подпись к одному ZIP. Изменение роли сохраняет редактор, rich input и UTF16 selection. Отправка/схемы/политика S3 остаются прежними. Mixed Media использует reference entry-count, но его текущий list renderer ещё отличается от reference collage; exhaustive classifiers, premium limits и pixel parity открыты |
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
редактирование и права описаны ниже. Синтетическая
проверка общего окна не устанавливает успешный server refresh.

### Профили, управление и общие медиа — блок 4

Проверена та же закреплённая ревизия TelegramSwift; исходники найдены через
актуальный XERJ и подтверждены чтением. Внешний GPLv2 UI не копируется.

| Проверенный reference | Собственная реализация Макоша и границы |
| --- | --- |
| `GroupInfoEntries.swift:100–215,2247–2267`; `ChannelInfoEntries.swift:1330–1332`: редактирование названия/описания, переходы к участникам, администраторам и разрешениям | Переходы внутри существующей карточки общего рабочего окна. Отдельное сохранение названия и описания, предел255 UTF16. Текущее наблюдение управления обновляет отображаемые поля; ACK не выдаётся за полный server refresh |
| `ChannelAdminController.swift:210`; `PeerInfoUtils.swift:33–121`: должность16 символов, собственные доступные права, защита владельца | Категории участники/администраторы/ограниченные/исключённые, поиск, страницы64 с raw offset. Подтверждение изменения роли/ограничений; свежий native participant и Postbox-права проверяются перед RPC. Для basic group — boolean admin и удаление без отзыва истории |
| `ChannelPermissionsController.swift:614`: разрешения участников по умолчанию | Собственные разрешающие переключатели поверх запрещающих native flags; запрет чтения всему чату исключён. Проверяется исходное значение и право блокировки; подтверждение отдельное |
| `PeerMediaController.swift:375–420`: панель50pt, медиа/файлы/ссылки/музыка/голосовые/GIF | Независимый поиск общих медиа всего чата, включая исходные темы; сетка3 колонки, список файлов, пагинация, существующая загрузка/просмотр/сохранение. «В переписке» открывает точный native index и thread, сохраняя независимые черновики |
| `GalleryViewer.swift:268–284`: затемнение0.9, нижняя панель95pt | Собственный sheet900×650, фото/видео, предыдущий/следующий, дата/счётчик, сохранение и исходное сообщение. Нативная QA подтвердила фото→видео→сообщение127. Полноэкранное borderless-окно, лента миниатюр, zoom/rotation, календарь, месячные секции и массовое выделение ещё открыты |

Добавление участников, ссылки приглашений, заявки на вступление, журнал
администратора, передача владения, статистика, изменение аватара, истории и
общие/похожие группы пока не перенесены. Настоящие server-side права и RPC
проверяются отдельно в блоке6 с явно выбранным аккаунтом. Синтетические ACK
подтверждают UI-переходы, а не изменение реального Telegram-чата.

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
новая schema14 реализация описана ниже, exhaustive MIME parity ещё открыта. Обложка выбирается в меню при одном видео,
но ранее выбранная обложка явно не очищается после добавления других файлов.

Source подтверждает три upstream особенности, которые нельзя скрыть под
заявлением о полном совпадении: caption передаётся заново в каждый chunk;
entity attributes повторяются даже на media без текста; локальные индексы второй
группы используются против общей URL-коллекции, поэтому действие над11-м файлом
может попасть на первый. Runtime референса не запускался. Для действий Макош
использует постоянные item UUID; caption повторяется на chunk, а media без текста получают пустые entities
по явно принятой send policy в telegram-album-migration.md. На этом историческом
этапе preview mosaic ещё не был исследован; последующий перенос обычного visual
набора записан в разделе «Геометрия Media-предпросмотра» ниже.

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
проверены мышью; сам drag/drop жест пока не проверен. Новая whole-list
классификация описана ниже; archive остаётся открытым.
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

Оставшиеся различия классификации явные: WebP сохраняет исходные байты с native sticker attributes. Static-photo payload admission использует
transformed ImageIO pixels отдельно от NSImage logical source options. Ordered classifier использует отдельные schema14
source facts; exhaustive MIME/Ogg/Vorbis и полная recorder visual/gesture parity
ещё открыты, как Archive и image edits.

Новый static photo/File payload сверяется с `SenderController.swift:333–368`:
height≥40px и width/10≤height после transformation. Width<40px и tall aspect
сами по себе не запрещают photo. Probe и staging используют один выбранный1280/2560px maximum;
orientation/non-square DPI проверены по настоящему JPEG. Source options остаются
симметричными logical40-point/10:1. Существующие frozen File/photo подготовки
не переклассифицируются. Новый source-only Media допуск соответствует initial
state в `PreviewSenderController.swift:1744–1745`, который выбирается только по
options. Он включён только в новых schema17/18; прежние1–16 сохраняют visual-payload
требование, включая retry/edits/restore. Cached ZIP сохраняет ту же policy family;
переходы15→18 и17→16 через guarded install/capture запрещены. Default1280/large2560
setting теперь следует `FastSettings.swift:301–315` и SenderController; ImageIO
получает quality.75. `ImageCompression.swift:53–75` сначала использует Mozjpeg75,
затем ImageIO fallback. Основной codec теперь закреплён отдельно: Mozjpeg4.1.4,
portable scalar C, FASTEST defaults, integer DCT, optimized Huffman, quality75,
simple progression. Собственный CGContext с белым фоном и RGBX/C boundary
заменяет не скопированную ObjC обёртку. ImageIO fallback и cover path сохранены.
Универсальная побайтная эквивалентность native builds не утверждается; source/
license/preparation provenance записаны в THIRD_PARTY_NOTICES.md.
Один preference доступен в существующих Settings и Media-preview menu, как в
`GeneralSettingsViewController.swift:198–201,402` и `PreviewSenderController.swift:404–411`.
Reference handler не перегенерирует текущие media; Makosh также меняет только
параметр новых подготовок. Старые2560/.85 ресурсы восстанавливаются побайтно.
Native Settings адаптирует switch к SwiftUI Form; reference modal-text feedback
заменён подсказкой о следующих подготовках. Полная Settings parity ещё открыта.
Предыдущий native picker QA размера2026-10-12 подтверждает общий ON/OFF в меню и Settings и его
сохранение после перезапуска. При S3 OFF новый PNG3000×1500 даёт large2560×1280/.75
и standard1280×640/.75. После удаления исходного picker path final app показывает
фото и emoji captions; readback сохраняет точные прежние2560/.85 и large pointer/
payload/UUID. Все шесть текущих photo/raw ресурсов local,32 retained records,
без receipt/pending/S3 objects и promotion после enable/resume. AX predicate
наличия menu control воспроизводит RED→GREEN; checked state подтверждён Settings
AX и screenshot. Это подготовка/восстановление, не отправка на сервер Telegram.
Native picker QA основного Mozjpeg2026-10-12 при S3 OFF даёт progressive
quality75 JPEG1280×640 из того же PNG3000×1500. После удаления picker path
restart показывает фото и emoji caption. Три прежних ImageIO preparation
сохраняют точные pointer/payload/UUID; восемь текущих photo/raw ресурсов local,
34 retained encrypted records, без receipt/pending/S3 objects и promotion
после enable/resume. Кодировщик не меняет layout; universal byte parity с
native reference build остаётся не подтверждена.
Typed WebP под исходным .jpg теперь сохраняет Media с unchanged document bytes;
его grouping всё ещё запрещён и требует отдельной сверки с reference workflows.

Native picker QA новой policy 2026-10-12: два PNG32×32@36DPI при S3 OFF.
Предыдущая сборка показывает File; новая — Media с теми же document rows и
исходными байтами. Один AX predicate воспроизводит RED→GREEN. Media→Archive→
Media и exact restart без исходных picker paths сохраняют оба UUID и emoji
caption. Reopened readback подтверждает cached18, два encrypted local файла
плюс ZIP,26 retained records с прежними/cancelled preparations, отсутствие
receipt/pending/S3 objects и отсутствие promotion после enable/resume.
Native queue original bytes/grouping/caption/receipt отдельно покрыты regression
под обеими storage policies; Account/server delivery не утверждается.

Native picker QA 2026-10-12 на final built payload: S3 OFF, PNG39×48 и PNG40×80.
До изменения narrow PNG — File row; после — два JPEG/photo в mosaic. Screenshot
и AX predicate воспроизводят RED→GREEN; exact restart без прежних picker paths
сохраняет оба UUID, изображения и emoji caption. Reopened readback подтверждает
четыре encrypted local photo/raw ресурса и21 retained record с прежними/cancelled
подготовками, отсутствие receipt/pending/S3 objects и отсутствие promotion после
enable/resume. Это проверка подготовки/восстановления; native queue отдельно
покрыт synthetic integration regression, Account/server delivery не утверждается.

Для новых ordinary picker preparations сверены `ThumbUtils.swift:222–260`,
`CoreExtension.swift:2953–3015`, `PreviewSenderController.swift:1743–1788` и
`SenderController.swift:455–460,659–664` на том же reference pin. Ordered fold
сохраняет порядок вкладов и WebP removal: PNG→WebP даёт File; WebP→PNG возвращает
Media. Не прошедшее logical image gate изображение не добавляет File и не снимает
ранее накопленную Media. File пункт меню существует независимо от Media;
recorded preparations и legacy photo без raw source сохраняют свои ограничения.

Schema14 связывает исходные факты с item UUID, raw role/name/size/SHA256 отдельно
от canonical payload. Reorder/remove атомарно нормализуют mode/grouping без
автоматического включения и новых копий. Schema1–13 не получают новых фактов.
Native File image использует logical ImageSize с безопасным Int32 преобразованием;
смешанный Media chunk отдаёт caption первому actual visual, иначе последнему file.
Реальные PG/Postbox/S3 OFF/native queue tests проверяют этот путь и отказ при
подмене фактов; это не доказательство Account/server delivery.

На финальном payload 2026-10-12 проверены AX и screenshots в общей форме:
одиночный WebP показывает видимую кнопку меню и только File; PNG→WebP даёт
File/disabled grouping. Перестановка в WebP→PNG сохраняет File и открывает Media;
явный Media работает, обратная перестановка возвращает File. Смешанный набор
small PNG/JPEG/small PNG сохраняет Media/grouping/подпись и те же три UUID после
restart без исходного пути, при S3 OFF. Recovery подтверждён AX; screenshot
восстановленной sheet вернул маленькое чёрное изображение и не считается visual
proof. Явный Send достигает только synthetic queue. Mail→Telegram сохраняет
чат/OFF и предупреждение о возможной очереди без auto-resend. Physical drag и
initial reverse-picker sequence отдельно не проверены; проверены row menu actions.
Исходные synthetic fixtures восстановлены с проверкой всех семи hashes.

Остаются различия: bounded ImageIO admission вместо unbounded reference,
неполная MIME table (UTType fallback и явный local Opus alias), отдельное правило
static payload geometry, оставшаяся mixed/special-media и gesture геометрия,
Archive и caption gaps ниже. Перенос обычного visual mosaic записан отдельно.
Полное визуальное совпадение с референсом не заявлено.

Сверены также `PreviewSenderController.swift:1690–1705,388–393`: mixed Media
допускает spoiler/placement; legacy schema8 grouping требует all-visual eligibility. Макош
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

Обычный Ogg/Opus сохраняет тот же экран File общего окна. Отдельная byte-probe
через проверенные BSD3 libogg/libopusfile исправляет ошибочную native длительность
13s для1.25s файла и отсутствие TITLE/ARTIST. Это собственная адаптация: длительность
берётся из trimmed PCM/granules, теги — первые соответствующие комментарии первого
link, с сохранением whitespace. Суффикс не создаёт Voice; исходные байты остаются
неизменными, native MIME audio/ogg и Audio(false)/FileName сохраняются после restart.
Полное metadata enumeration референса, все Ogg codecs и whole-stream PCM decode
не заявлены. Boundaries и актуальная UI QA записаны в development-status.md.


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
rules теперь относятся к отдельным source facts/schema14 выше. Exact RIFF length,
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
Ordered option fold реализован для новых schema14 preparations; exhaustive MIME
parity, Archive и image edits остаются открыты. GPLv2 UI/helper/ассеты не копировались,
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
Telegram-bundled libogg code не скопирован. Отдельный explicit prepare(samples:) теперь сохраняет
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

### Основа отправки круглого видео: encoded MP4

Desktop pin579cebbf0c01fd41b712eff3647fa7f69db9665d сверён через свежие
XERJ hits и исходники: ChatInputActionsView.swift:126–142 переключает voice/video
коротким нажатием, ChatController.swift:3536–3684 отдельно применяет
banSendInstantVideos и запрашивает camera+audio. ChatPresentationInterfaceState.swift:235–247
фиксирует once перед finish; SenderController.swift:312–325 передаёт только
Video(ceil duration,200x200,instantRoundVideo), size:nil, без FileName/streaming.
Нативный pin a24bbe45f9861f736a79916a50898512f751e0dc отдельно подтверждает
protocol round bit0 и независимый streaming bit1 в PendingMessageUploadedContent.

VideoRecorderPipeline.swift и TGVideoCameraMovieRecorder.m используют MP4/H264 и
mono AAC44.1kHz. Фактический fallback vmSide равен300 и допускает UserDefaults
override; parsed config384/12MiB здесь не применяются. Machine override не читался.
Renderer делает центральный квадрат, mirror/portrait и белый круговой край через
shader. GPLv2-only helper/renderer/shader/assets не копируются.
Reference videoDuration — audio-end timestamp минус writer session start;
это не обязательно duration готового AVAsset. previewForFile:100–127 делает
transformed first-frame JPEG<=320px quality0.3 и допускает отсутствие preview.

Независимый encoded entry Макош теперь проверяет полный MP4/H264/AAC payload,
сохраняет исходные байты и отдельные physical/native facts в strict schema13.
Native200x200 не подменяет физический размер. Ceil вычисляется до Float32, но по
raw full-asset duration: точное совпадение с capture-clock reference пока не
установлено. Собственные bounds side<=1024,128MiB,0.5...60s и decode work limits
описаны в telegram.md; это не утверждение о лимитах сервера. Durable path требует
успешный ordinary320px JPEG probe, хотя mapper и reference допускают отсутствие.

Explicit MP4 теперь подключён к upload controller: durable schema13 prepare,
restore и явный Send. Подпись, группировка, spoiler/above, cover, File conversion,
редактирование набора и generic video preview для round закрыты. Восстановленный
prepared record ждёт Send; accepted/uncertain не запускают повторную отправку.
Отдельный recording kind применяет banSendInstantVideos независимо от voice/video
ban, сохраняя privacy/cache/access/fee/slow-mode и once ограничения. Native admission
проверяет свежий snapshot до вставки в той же Postbox transaction, с network time
offset. ACK не сканирует pending повторно, чтобы не учитывать собственную вставку.

### Общая запись круглого видео

Тот же desktop pin проверен в VideoRecorderModalController.swift:38 и
VideoRecorderModalView.swift:25–54: modal300pt, capture circle264pt,
progress281pt/line4, aspect-fill и mirrored preview. Макош независимо реализует
эту геометрию в центральном overlay общей Telegram-панели; common composer
сохраняет hold/lock/cancel/once и таймер. Короткий клик переключает voice/video,
300ms hold начинает запись, вверх>100pt закрепляет. Accessibility custom action
переключает тип, Press начинает закреплённую запись. Начальный тип остаётся Voice.

Camera→audio permission проверяет контекст после каждого prompt. Асинхронный
start ждёт оба формата, warmup остаётся authorizing и допускает отмену; timeout
не ждёт зависший источник. Native capture queue отделена от sample writer queue.
Собственный writer кодирует300x300 H264/mono AAC44.1, делает central square,
горизонтальное отражение и белый круговой край. Проверки декодированных пикселей
относятся к этому writer, а не к физической ориентации камеры. Capture clock
использует audio end−first video, но готовый MP4 дополнительно проходит прежнюю
full-asset schema13 политику. В ней сохраняется описанное выше отличие duration.

Model handoff сохраняет обычный/once режим в local/S3 подготовке, применяет fresh
round ACL перед Send и оставляет подготовку при отказе. Prepared/restored UI
показывает frozen режим, статус восстановления и явный Send/Cancel. OFF запрещает
любые новые S3 копии, local record после включения не повышается в S3.

Оставшиеся отличия: overlay вместо reference modal, системные символы вместо
GPLv2-only placeholder/shadow/assets и отсутствие полного
визуального/gesture совпадения. На60s Макош готовит запись и ждёт Send; reference
runTimer вызывает отправку. Синтетическая камера явно обозначена и не открывает
устройства. Текущие actual UI результаты записаны в development-status.md;
кодирование/очередь/синтетический экран не доказывают server acceptance, recipient
playback, реальную камеру, route/orientation/throughput или minimum26 runtime.

### Предпросмотр готового круглого видео

На том же desktop pin `VideoRecorderModalView.swift:65–89` передаёт готовый путь
в GIFPlayerView, убирает capture layer и progress ring. Проверенный
`packages/TelegramMedia/Sources/GIFPlayerView.swift:193–310` читает только video
sample buffers и повторяет готовый файл; audio output отсутствует. Это источник
поведения и геометрии, а не скопированный GPLv2-only код.

В общей панели Макош готовая/восстановленная запись теперь использует тот же
центральный300pt overlay с264pt кругом, aspect-fill и без ring. Собственный
AVPlayer проигрывает проверенный owned stage без звука, повторяет его только в
видимом key window и отключает external playback. Второе отражение не применяется:
оно уже записано в байтах. Локальный просмотр не меняет frozen once, Send/Cancel
или S3 policy и не создаёт копий. Generic video entry остаётся закрытым для round.

Modal, placeholder/shadow assets, переходы/fade и полная visual/gesture parity
остаются открыты. Cap60s по-прежнему готовит запись с явным Send. Actual UI
результаты и ограничения записаны в development-status.md; это не доказательство
реальной камеры, Account/server/recipient или minimum26 runtime.

## Caption projection continuation — 2026-10-12

Сверены pinned `PreviewSenderController.swift:1214,1824`, `UIInputView.swift:87–88`,
`ChatInterfaceState.swift:380–383,596–793`, TGUIKit `Extensions.swift:70–99,214–225`
и `CoreExtension.swift:323–337,1599–1605`. Attributed helper вызывается всегда:
он заменяет U+2028/U+FFFC и обрезает whitespace; отдельный String preflight не
заменяет U+FFFC. Это исправляет прежнее предположение о сохранении formatted
padding при отправке. Raw editor input сохраняется независимо от send projection.

Собственная schema15 projection сохраняет explicit entities с UTF16 clipping/
shift, отбрасывает пустые пересечения и не допускает laundering unsupported
entities. Whitespace-only не создаёт отдельного текста. Single File WebP, включая
нетипизированный image/webp, получает leading text и пустую media caption.
Legacy1–14 не меняются после reorder/mode/cover. Recorded raw caption проверяется
до любых копий. Полная MIME parity не заявлена: typed GIF/music с WebP selection
может получить лишний leading text при последующем native MIME override.

Actual AX/screenshots существующей File sheet проверяют два ordered файла,
padded caption/counter12, whitespace/counter0 и native bold. После rename source
folder/restart восстановлены padding/formatting/selection и два прежних UUID с
S3 OFF; восстановленный screenshot действителен. Send только synthetic queue,
Mail→Telegram сохраняет chat11/OFF и no-auto-resend uncertainty. Три synthetic
fixtures восстановлены/hash-checked. Emoji selectText не сработал; select-all/bold
проверен. Full Account/server/hardware/minimum26 не выполнялись.

Открыты markdown/detected entities, resolved custom emoji, premium2048 limit,
placeholder/comment переключение и полная visual/gesture parity. Conservative
1024 limit и generic caption UI остаются явными адаптациями. Архивная отправка
ещё не реализована; совпадение с upstream ZIP wrapper не заявляется.

Внутренний ZIP writer/inspector теперь реализован независимо через системный
zlib. Он сохраняет порядок, скрытые и пустые файлы; совпадающие имена получают
суффиксы без потери исходников. Это исправляет проверенные проблемы reference
copy/enumeration, но не меняет видимое окно и не добавляет кнопку Archive.
Schema16 с N originals + ZIP, policy-aware хранение и восстановление всего
набора теперь реализованы на внутреннем уровне. S3 OFF запрещает любые новые
копии, включая ZIP для подготовки; локальные записи не продвигаются в S3.
Отдельная установка уже сохранённого ZIP теперь аутентифицирует весь набор,
сохраняет raw editor/canonical ресурсы и меняет schema15→16 через Postbox CAS.
Отмена проверяется в той же native транзакции, что compare/set; владелец попытки
обязан инвалидировать её token при смене контекста. Установка не создаёт новых
записей файлов. После успешного CAS поздняя отмена не скрывает результат записи.
Отдельный native plan/receipt теперь связывает один ZIP с descriptor ID/name/size/
digest, нормализует одну подпись и сохраняет один accepted ID в той же транзакции
очереди. Исходные ресурсы/raw input остаются в pointer; потерянный ACK не разрешает
повторную вставку. Проверено в изолированной native очереди при обоих S3 policy,
без новых S3 копий. ZIP отклоняет подмену media TTL/view-once; обычный chat
auto-delete остаётся отдельным native атрибутом. Видимое окно не изменено.
Провайдеры Account и изолированной native очереди теперь принимают весь recovered
bundle. Перед одной ZIP-копией в MediaBox проверяются canonical/original/cover
ресурсы, порядок и сохранённые имена членов, raw bytes и digest ZIP; кэш проверяется
повторно перед enqueue. Старый array-путь не принимает16. Отмена до admission
не ставит сообщение в очередь; lifetime набора остаётся у вызывающего кода.
Новых file records/S3 копий этот путь не создаёт. Account/server send не проверен.
Модель и контроллер теперь восстанавливают весь bundle: окно показывает один ZIP
и raw подпись, а canonical ресурсы сохраняются до подтверждения или очистки.
`PreviewSenderController.swift:480–488` задаёт отдельный заголовок Archive;
исправлены заголовок «Отправить архив» и доступное название режима «Архив».
В отдельном синтетическом общем окне реально проверены восстановленный ZIP,
подпись и исправленный заголовок. Изменённая подпись и ZIP пережили перезапуск;
явная имитация отправки закрыла modal. Отдельное чтение того же Postbox подтвердило
один accepted ID, два canonical ресурса, ZIP и изменённую подпись; три локальные
записи остались без S3 receipts. Личные аккаунты и сеть не использовались.
Восстановленный started pointer остаётся uncertain без повторной отправки;
подтверждение ZIP сравнивает точные encoded bytes, включая NFC/NFD имена членов.
Отмена/смена привязки/закрытие освобождают весь временный набор. Редактирование
состава/обложки/режима восстановленного Archive пока заблокировано.
Новая Session теперь подтверждает точную уже committed установку после lost ACK:
отдельный native receipt связывает исходную revision с хешем всего candidate;
последующая правка, включая A→B→A, или отсутствие receipt запрещают replay.
Обычная изменяющая запись сбрасывает receipt, поэтому возврат старого UUID
не возвращает право повторного подтверждения; точный no-op сохраняет его.
Существующие schema16 без нового receipt сохраняют восстановление/отправку.
Экран и его действия этим внутренним retry не меняются.
После проверки сохранённого набора Session удерживает точный candidate в отдельном
зашифрованном native receipt до переключения указателя. При сбое установки или
потере ACK этого receipt новая Session читает descriptor/revision из Postbox и
повторяет явную установку без новых файлов/S3-копий. Обычный указатель15 до успеха
не меняется. Позднейшая изменяющая запись, включая отмену и возврат старого UUID,
сбрасывает receipt. Экран и его действия этим внутренним путём не меняются.
Меню существующего preview теперь добавляет «Отправить как архив» рядом с Media/File
для нескольких источников, по PreviewSenderController:281–293. ZIP создаётся из
аутентифицированных сохранённых оригиналов; переключение обратно в File/Media
сохраняет тот же ZIP cache и отправляет выбранные оригиналы/медиа. Повторное
включение Archive не создаёт новых записей файлов. Native AX/скриншоты подтверждают
Media→Archive→File в общем окне, восстановление File и изменённой подписи после
перезапуска, затем Media→Archive с тем же ZIP. Явная синтетическая очередь принята
при S3 OFF; повторное чтение Postbox подтверждает один ZIP и пять локальных
зашифрованных записей без S3 receipts/pending. Личный аккаунт и сеть не использованы.
После возврата в File/Media доступны прежние действия удаления/перестановки.
Изменение состава/порядка атомарно сбрасывает ZIP cache; следующий Archive
создаёт только новый ZIP из оставшихся сохранённых оригиналов. Старый ZIP
остаётся в неизменяемом архиве. Группировка и обложка не меняют raw-источники
и сохраняют действующий cache. Активный Archive остаётся одной строкой без
редактирования состава, по PreviewSenderController:867–872. Native AX/скриншоты
подтверждают группировку Media с сохранением прежнего ZIP, затем File с
перестановкой/удалением, восстановление двух оставшихся файлов и изменённой
подписи после перезапуска. Следующий Archive создаёт новый ZIP ID; явная
синтетическая очередь закрывает modal при S3 OFF. Повторное чтение Postbox
подтверждает один accepted ID, члены third.jpg/first.jpg и восемь локальных
зашифрованных записей без S3 receipts/pending. Личный аккаунт и сеть не использованы.
Сохранение cache при замене canonical video-cover проверено на уровне Session.
Кнопки обложки доступны только для одного вложения Media, как в
PreviewSenderController:315–378 (`totalCount == 1`); отсутствие таких действий
в наборе соответствует выбранному референсу. Прежняя запись о недостающих
кнопках набора была ошибочной. Новое внутреннее резервирование ZIP до capture
не меняет экран: повторная явная попытка использует тот же объект даже без
committed candidate receipt. Остаются визуальные различия. Отмена/смена привязки
при удержанной установке Archive теперь проверены интеграционно с настоящими
Postbox/PostgreSQL/S3: до native commit и при задержке его успешного ACK, для
обоих значений флага. Обычная
первичная подготовка по-прежнему отклоняет Archive без полного сохранённого набора.
Последняя совместимость проверена в существующем общем окне: Media→Archive,
изменённая подпись, перезапуск с тем же ZIP ID, затем явная синтетическая очередь
при видимом флаге S3 «Выключено». Повторное чтение Postbox подтверждает один
accepted ZIP и пять локальных зашифрованных записей без S3 receipts/pending.
Это UI-проверка обычного пути; сбой до commit candidate receipt проверен
отдельно интеграционным тестом, без подмены UI доказательства.
Отдельная нативная UI-проверка закрывает подготовку ZIP кнопкой отмены, меняет
диалог и возвращается без повторного открытия ZIP. После перезапуска отменённый
ZIP также не появляется; черновик другого чата остаётся прежним. Native readback
подтверждает cancelled, точную подпись, прежний ZIP ID и пять локальных
зашифрованных записей без S3 receipts/pending; ZIP читается из локального архива.
Это обычный UI-путь. Удержание callback проверено отдельно интеграционно.
Пределы и точный внутренний профиль записаны в telegram-album-migration.md;
полное визуальное совпадение и готовность архивной отправки не заявляются.

### Геометрия Media-предпросмотра — 2026-10-12

Проверены `MediaGroupPreviewRowItem.swift:28–50,154–200` и
`GroupedLayout.swift:18–26,97–333,391–404` в закреплённом TelegramSwift:
preview использует квадратные пропорции, отдельные формы для2–4 элементов,
оценку рядов для5–10, промежутки4pt, округление к пикселям и центрирование
полученной области. Макош независимо реализует эти правила отдельно от
раскладки истории. Одиночный остаток использует существующие bounded-размеры
photo/video по `ChatLayoutUtils.swift:16–32,76–114`, максимум320pt.
Исходники внешнего GPLv2-only интерфейса и его assets не копируются.

Смешанный набор пока остаётся списком: reference `GroupedLayout.swift:52–59`
отфильтровывает неинтерактивные media. Такой фильтр без отдельного разбора
состава скрыл бы выбранные файлы. Полное совпадение mixed/special-media,
жестов и пиксельной геометрии остаётся открытым.

### Отдельный и одиночный Media-предпросмотр — 2026-10-12

`MediaPreviewRowItem.swift:66–114,195–235` получает размеры ordinary media из
`ChatLayoutUtils.swift:16–32,76–114`. Фото ограничено320pt, маленькие фото имеют
особое увеличение/minimums; ordinary video использует420pt для landscape и320pt
для portrait с нормализацией малых dimensions. Макош применяет уже существующий
bounded helper также к отдельным строкам и одиночному предпросмотру. Их прежние
фиксированные высоты200/240pt сняты; loading/error имеют ту же высоту. Singleton
в коллаже сохраняет собственную границу320pt, File и recorded-round — свои пути.
Нативно проверены portrait/wide/square, отдельные строки, группировка, одиночное
видео, удаление только выбранного элемента и restart с теми же ID/локальными
ресурсами. Внешняя форма modal, padding/карточки, special-media, жесты и полная
pixel parity остаются открытыми; outer GPLv2-only код/assets не копируются.

Уточнение mixed-границы: `ThumbUtils.swift:222–260` пропускает decoded image
с любой стороной меньше40 либо aspect ratio больше10 при выборе options, но
`SenderController.swift:331–369` переводит static payload в File только при
width/10 > height или height <40. Поэтому width39 сам по себе не доказывает File.
`CoreExtension.swift:307–320` не считает generic image File интерактивным;
`GroupedLayout.swift:52–59` удаляет такие members из photoOrVideo layout.
Например,40×39 рядом с обычным фото требует отдельного разбора. Текущий mixed
список сохраняет видимость всех файлов; такое фильтрование не перенесено.

Повтор video preview теперь ждёт завершения native seek, оставаясь на паузе.
Поздний callback проверяет visibility/generation/player/seek identity; hidden EOF
не начинает новую перемотку. Детерминированные held-completion проверки используют
настоящий AVPlayer и immutable stage; обычные native integration tests сохраняют
проверку реальных циклов. Это исправление собственного AVFoundation transport,
а не заимствование reference player.


### Данные и память — 2026-10-13

Закреплённый TelegramSwift исследован через свежий XERJ и подтверждён исходниками:
DataAndStorageViewController.swift:425–493 задаёт порядок storage usage,
automatic master/photo/video/files/reset, затем proxy;
packages/InAppSettings/Sources/InAppSettings/AutomaticMediaDownloadCategoryPeers.swift:149 задаёт reference defaults;
ProxyListController.swift:317–355,445–479 задаёт список, выбор и добавление;
StorageUsageController.swift:64–110,1341–1378 — категории и отдельное
подтверждение очистки. Макош независимо использует этот порядок в существующей
общей форме с боковой панелью сервисов. Внешний GPLv2-only код и assets не копируются.

Own SwiftUI включает отдельные category/cache/proxy editors. Категории имеют
четыре peer toggles и явное сохранение размера. Прокси включает SOCKS5/MTProto,
выбор, добавление/редактирование/удаление, secure password/secret и отдельное
подтверждение применения/Direct. Кэш показывает проверенные облачные копии по
четырём категориям и повторно проверяет их перед очисткой. Постоянный архив,
S3, исходники отправки и используемые ресурсы сохраняются.

Явные отличия: master автозагрузки исходно OFF, фото ограничены10MiB, контакты
выделены отдельно. Автозагрузка относится к видимой истории активного окна,
максимум три файла одновременно; неизвестный размер требует ручного действия.
Новые автозагрузки резервируют три отдельных места передачи в архив, включая
ожидающие FD; ручные восемь мест сохраняются. Очередь ждёт освобождения места,
а уже принятый файл сохраняет захваченный FD после ухода из окна.
Нет background auto-download, network-usage view, download-folder picker,
autoplay preferences и sensitive-content controls. Кэш ограничен подтверждёнными
cloud-media ID; нет полного disk inventory, pie chart, keep-media TTL/size,
per-chat storage browser и широкого other/temp clear. Прокси глобален для окон
Макоша и хранится в собственном Keychain; нет ссылок/QR, latency probes/calls.
Локальные grouped forms/modals и геометрия отличаются от upstream table/navigation;
полное визуальное совпадение не заявляется. Проверки и реальная UI-приёмка
фиксируются в docs/development-status.md; синтетическая проверка не означает
реальную доставку Telegram, доступность сервера прокси или Keychain acceptance.

## Telegram block12: extended privacy reference

Verified reference SHA579cebbf0c01fd41b712eff3647fa7f69db9665d:
PrivacyAndSecurityViewController.swift:600-621 orders gifts before birthday,
voice/video after forwarding, and Messages last. SelectivePrivacySettingsController.swift:505-529
gates voice editing/exceptions by Premium;587-612 locates read-time
hiding and gift-type controls;987 admits Premium for group invitations and bots
for gifts. SelectivePrivacySettingsPeersController.swift:224-231 represents those
categories separately. MessagesPrivacyController.swift:45-145 contains incoming
Everybody/Contacts-and-Premium/Stars choices, account/configuration availability,
fee limit and exemptions. Source localization confirms read-time hiding applies to
people who cannot see last-seen, and gift filters govern which gifts may be sent.
The independently pinned engine/API confirms native flags/optional fields and
three distinct selective keys; no outer GPLv2 UI code/assets are copied.

Makosh extends its existing common privacy forms in this order. Separate child
editors for global read-time/gift fields and separate save confirmations replace
the reference's inline/global-on-disappear writes. A parent draft must be saved or
discarded first. Paid exemptions keep their existing Contacts base; special
Premium/bot categories use explicit switches in Always Allow. Monetary values are
Stars only; no reference USD estimate, subscription purchase or upsell is copied.
Group, selector and modal geometry still differ from upstream; pixel parity is not
claimed. Whole-server snapshots/fresh conditional admission replace optimistic
cached updates and automatic retries. Unknown wire bits/fees and local permanent
archives are preserved. Actual acceptance evidence belongs to development-status.


## Telegram block13 task1: remote discovery

Pinned SearchController.swift:1055–1110 admits ordinary root queries through
contacts.searchRemotePeers, excludes #/$ and active global tags, deduplicates
local/my/remote peers and retains local matches first. Makosh adds that grouping
inside its existing common search form. Its own typed contacts.search boundary
shows network errors explicitly instead of the reference engine's empty fallback.
Activation revalidates account/context and current native identity before opening.
Ordinary usernames, error/retry, successful zero, filters and opening are checked
in native synthetic QA; no real account/remote-server acceptance is inferred.
Advertising, the full reference row renderer and historical geometry/animation
gaps remain separate. No outer GPLv2 UI code or assets are copied.

## Telegram block13 task2: static avatars and public photo

Verified TelegramSwift579cebbf: EditAccountInfoController433 and
GroupInfoEntries522 use native selection, square/circular crop, upload progress
and cancellation; SelectivePrivacySettingsController579/749/1082 places the
public fallback photo within profile-photo privacy and confirms its removal.
Makosh follows those workflows inside existing common settings/profile editors.
Its existing crop/rotation/flip canvas adds a circular guide; an immutable decoded
selection produces a bounded640px square JPEG with metadata removed. Explicit pre-commit upload cancellation preserves the draft. Separate
confirmation and fresh full native photo/rights checks precede writes; explicit
ACK and reread precede success. Near-square reference canvas rounding is snapped
to an integer square so rotation does not produce a401x400 rejected avatar.

Photo history viewing/export is unchanged. Native fixture acceptance and actual
limits are recorded in development-status. Main/fallback share one account-bound
editor; stale/rebound/uncertain contexts require fresh admission. Current-photo
header thumbnails, animated/video avatars, decorations and the complete upstream
editor styling remain block14 reference polish. No full pixel parity is claimed;
no outer GPLv2 UI or assets are copied. No S3 or PostgreSQL file-byte path is added.

## Telegram block13 task3: invitations, requests and history

На закреплённом TelegramSwift SHA сверены отдельные пункты
`GroupInfoEntries.swift:2119–2124,2253–2269`, права `PeerInfoUtils.swift`,
активные/отозванные ссылки и владельцы `InviteLinksController.swift`,
заявки `RequestJoinMemberListController.swift:270–298,336`, события и поиск
`ChannelEventLogController.swift:415`. Они перенесены отдельными страницами
существующей карточки в общей оболочке; внешний GPLv2-only UI/assets не копируются.
Это завершает функциональные пункты приглашений/заявок/журнала, которые в описании
раннего этапа карточки выше ещё перечислялись как будущие.

Создание ссылки сохраняет предел названия32 и положительный Int32 usage limit;
одобрение исключает лимит. Создатель выбирает владельца ссылок, остальные
управляют своими. Публичный маркер заявок остаётся readonly. Ссылки никогда
не отправляются автоматически. Запросы и события допускают поиск; страницы
используют собственные native cursors, включая короткую непустую страницу.
Явные подтверждения точных целей, свежие права/typed ACK/post-read, полный
bounded scan отсутствия заявки и барьер неизвестного результата — адаптации
Макоша вместо оптимистических NoError-комплитов.

Собственные Form/sheets, кнопка дозагрузки и системные подтверждения отличаются
от reference InputData/table навигации. Подробные media/декоративные карточки
admin events, их thumbnails, полная фильтрация по типам/администраторам и точная
визуальная parity остаются в блоке14. Тексты прав, выбранные участники, ссылки и
наблюдённые edit/delete message bodies сохраняются; CopyProtected запрещает
выделение содержимого события. Native UI исходы/обнаруженный scroll crash и
его повторная проверка фиксируются в development-status.md без заявления
реальной записи в личный аккаунт.


## Блок13: секретные чаты

Проверены текущие `UserInfoEntries.swift:601` и `ChatController.swift:8678`:
создание из карточки обычного пользователя с именованным подтверждением,
Premium/ошибки и переход в отдельный секретный чат; текущий TTL, стандартные
значения и ввод другого таймера. Макош использует эти входы в общей оболочке
сервисов, существующее сравнение ключа и состояния ожидания/активного/завершённого
чата. Реализация собственная SwiftUI, внешний GPLv2 UI не скопирован.

Отличия: создание размещено внутри страницы карточки, таймер — в отдельном
sheet под заголовком диалога, подтверждение показывает прежнее/новое значение;
времена показаны в секундах. Квитанция очереди явно отделена от доставки.
Постоянный архив и переключатель S3 — требования Макоша. Неподдерживаемые
слоем entities, cloud quotes/обложки/spoiler media не теряются молча. Отдельная
карточка самого секретного чата и полное визуальное совпадение с reference
остаются в блоке14; создание, обмен состояниями, контент и TTL относятся к13.


## Блок13: личные звонки

Сверены PhoneCallWindowController.swift:19,601–602,747–812,909–925,1212–1255,
CallNavigationHeaderView.swift, ApplicationContext.swift:256–285 и PCallSession.swift
выбранной ревизии TelegramSwift. CallHeader у референса принадлежит правому
контроллеру; полоса Макоша также размещена в колонке содержимого, над её экраном.
Воспроизведены отдельное немодальное окно358×477, имя/статус, центральное круглое
представление без видео, удалённое видео с локальным превью, круглые кнопки
микрофона/камеры/завершения и явные принять/отклонить. ChatTitleBarView.swift:362–374,
673–686 подтверждает вход из заголовка личного диалога. Компактная полоса общего
окна сохраняет доступ к звонку при переходе между сервисами и закрытии окна звонка.
SwiftUI владеет состоянием; AppDelegate-owned AppKit edge только управляет окном.
Внешние GPLv2-only UI/assets/звуки/код не копируются.

Оставшиеся визуальные отличия записаны явно: собственные SF Symbols и спокойный
фон вместо фотографического фона/анимации волны; отпечаток native32байта показан
hex вместо набора emoji; нет выбора отдельных аудиоустройств, перетаскивания
превью, анимации/автоскрытия контролов и встроенного Recall в завершённом окне.
Повторный звонок доступен из заголовка диалога. Рингтоны и точная визуальная
доводка относятся к отдельному блоку14; видеогруппы/демонстрация экрана вне
утверждённого объёма личных звонков13. Отдельная реальная проверка устройств и
собеседника не подменяется синтетическим окном.

## Telegram block14 task5: profiles, history and calls

Reference579cebbf: UserInfoEntries2433–2435 exposes the secret key in the user
card; ChannelEventLogController455–468 opens event/admin filters;
PhoneCallWindowController988–998 and1295–1300 exposes Recall. These sources
were confirmed against current source after fresh XERJ retrieval. Existing
72px contact-profile photos remain; settings now uses the same account-bound
AvatarStore. Secret chats open their own current-session card with native key
and TTL entries, pending/terminated states and permanent archive/S3 explanation.
Current-session admission is shared with the composer; TTL confirmations still
freeze and revalidate native session/context.

Admin filters select all18 pinned event categories and up to100 observed actors.
The author picker lists up to1000 actors already observed by this view, rather
than the complete current administrator roster. Filtering starts a fresh cursor/
context and keeps the query; missing native personal hashes fail visibly.
Unexpected actor responses fail before journal publication. Protected bodies
remain visible where actually supplied, without copy selection.

The call window uses account-bound avatar thumbnails and a blurred photo
background, plus explicit audio/video Recall after capture release for the still
selected peer. Settings and the call window expose input/output selection for
the next call. CoreAudio inventory reads properties only; synthetic QA uses its
own inventory. Frozen UIDs cross the versioned own C ABI. The ADM wrapper chooses
the concrete macOS entry instead of its duplicate default alias and refuses
missing/changed devices; no automatic fallback from an explicit selection.
Legacy ABI1 does not read the new tail. No new third-party sources/assets/sounds.

Remaining aesthetic differences: static avatar rendering, no video avatars or
decorations, no wave/ringtone, native32-byte hex verification instead of the
reference emoji presentation, fixed local video position and no control auto-hide.
Audio selection affects subsequent calls; changing devices during an existing
call is unavailable. Actual changed UI and physical hot-plug/capture acceptance
are pending; focused/source tests do not establish those outcomes.
