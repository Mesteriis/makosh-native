# Последовательный перенос Макоша

Цель пользователя: продолжать, пока выбранные направления не перенесены по
порядку. Завершение одного участка не означает завершения всей цели. Рабочий
порядок: Telegram → MMail/Aether → WhatsApp Zen → teams-cli → Телемост → общая
проверка досье, хранения, сборки и публикации. Источники закреплены в
`references.lock.json`; зависимости продукта должны иметь собственные lock и
подготовку без чтения `.references/`.

## Порядок и критерии

| Этап | Перенос и ожидаемый результат | Проверка / текущий пробел |
| --- | --- | --- |
| 1. Telegram | Нативная авторизация/сеанс; полный доступ к диалогам, архиву и истории; поиск; чтение/отправка медиа и файлов; независимое постоянное сохранение полученных сообщений и версий; ответы, редактирование, удаление и пересылка; состояния доставки/прочтения; данные собеседника и связь с досье; настройки/сеансы и остальные подтверждённые возможности выбранного клиента | Реальное ядро, текстовый UI, пагинация, поиск, загрузка фото/файлов, предпросмотр, native Save panel, подготовка/отправка файлов/фото и локальное audio/video реализованы. Добавлен отдельный зашифрованный архив текста/версий с журналом Postbox. Полностью загруженные вложения сохраняются зашифрованными в S3 с метаданными в PostgreSQL. Typed reply/edit/forward/delete проверяют исходник и сохраняют черновики с форматированием; ответы с файлами/фото фиксируют сообщение и thread. Topic/secret/paid пробелы остаются открытыми. Live-account acceptance ещё не выполнен; компиляция и локальная очередь не доказывают серверную доставку |
| 2. MMail + Aether UX | Аккаунты, IMAP папки/синхронизация/поиск, MIME plain/HTML/вложения, SMTP отправка, черновики/Sent, флаги/перемещение/удаление, offline-состояние и досье. Функциональная основа остаётся MMail | Подтверждены исходники IMAP/SMTP/MIME и MIT. Впереди отдельный SwiftPM transport, полный transitive lock/license audit, scripted IMAP/SMTP servers и нативные формы. Автоматический retry APPEND, неоднозначность SMTP после DATA и небезопасные credential/cache wrappers требуют адаптации |
| 3. WhatsApp Zen | Выбранное Swift/Rust ядро, версия C/JSON ABI, собственный session lifecycle, вход, диалоги/история/сообщения/медиа, статусы и идентичности досье | Исследован публичный ABI; перенос, сборка Rust и owned-memory/cancellation tests ещё впереди. Вход и живые данные отдельно авторизуются |
| 4. teams-cli | Microsoft Graph/OAuth библиотечные части, собственный SwiftUI, чаты/история/отправка/вложения и источник идентичностей | Public library API подтверждён. Впереди точный dependency audit, native bridge, OAuth/token lifecycle и scripted Graph checks. Терминал CLI не является UI продукта |
| 5. Телемост | Подтверждённые возможности официального API: встречи/list/create/ссылки и досье; затем исследование выбранного Linux/WebRTC референса для native функциональности | Сейчас работает официальный browser handoff. Нужны eligible business account/API acceptance и подтверждение переносимости media stack. Неподтверждённые reverse-engineered endpoints не считаются интеграцией |
| 6. Общая проверка | Работа всех перенесённых модулей в одном приложении, account isolation, источник/время сведений, досье/заметки, транзакционный импорт/merge/undo, экспорт/backup и упаковка зависимостей | Контактный core и PostgreSQL уже работают; GUI edit/note acceptance имеет записанный пробел. Нужны единый regression run, UI/OS matrix, current-head CI и проверенная документация/публикация |

## Правила выполнения

- Сначала инвентаризировать выбранный исходник через свежий XERJ и чтение кода;
  неизвестную возможность не отмечать реализованной.
- Изолировать переносимые части от upstream app entrypoint, credentials,
  личных баз и необязательных backend/AI/desktop-shell компонентов.
- Каждую работающую часть завершать содержательными проверками и фиксировать
  результат в `development-status.md`, затем продолжать следующий участок.
- Live-account acceptance остаётся отдельным незавершённым критерием. Пока
  авторизация отсутствует, продолжать независимую реализацию и scripted/
  synthetic проверки; не открывать личную переписку по косвенному разрешению.
- Не заменять выбранные основы более удобными клиентами. Подтверждённые
  технические ограничения фиксировать с исходником и способом адаптации.

## Текущий исполнимый участок

1. Пагинация/архив реализованы; API anchors/holes подтверждены source и XERJ,
   navigation/state и нативный UI проверены на явно синтетических данных.
   Server pagination/holes остаются отдельным непроверенным критерием.
2. Поиск прошёл hosted CI для `13b5d90` (run 38057972256). Загрузка фото/файлов,
   отмена/повтор, image preview и native Save panel проверены в изолированном
   синтетическом приложении. Фактические проверки — в development-status.
   Server search/download acceptance остаётся отдельно непроверенным.
3. Отправка файлов/фото и локальное audio/video реализованы и проверяются отдельно
   от серверной доставки и работы реального аккаунта.
4. По дополнительному требованию сообщения должны оставаться в Макоше после
   удаления собеседником. Перед действиями сообщений добавлен отдельный
   зашифрованный PostgreSQL-архив текста и версий с транзакционным журналом
   Postbox. Полностью загруженные файлы сохраняются зашифрованными в S3;
   PostgreSQL хранит метаданные, ссылки и подтверждения. Сохранённые копии
   просматриваются через native Quick Look из S3, независимо от кеша Telegram;
   обычное закрытие удаляет временный расшифрованный файл. Backfill и backup
   ключа/архива ещё впереди. Удалённое до получения клиентом
   содержимое восстановить нельзя. Добавлены typed reply/edit/forward/delete
   с повторной проверкой Postbox, сохранением черновиков и явным выбором
   получателя/объёма удаления. Rich-text и ответы с фото/файлами добавлены;
   темы, secret/paid возможности и live acceptance ещё открыты; затем связь с досье.
   UI сверяется с TelegramSwift: [карта переноса](reference-interface.md).
   Обычный composer сохраняет точный текст, entities и UTF16-выделение в account
   Postbox между перезапусками;
   поздние чтения и подтверждения отправки защищены revision/request guards.
   Typed reply target сохраняется с полным input одной revision, включая
   reply-only draft, и заново разрешается из текущего Postbox. Недоступный
   источник блокирует отправку до retry/явной отмены; поздний ACK не очищает
   новый target, форматирование или выделение. Schema 4 читает legacy 1/2/3;
   native undo/redo и rich input/reply проверены в общем окне после restart.
   Ordinary/reply отправка передаёт native entities и проверяет text mentions
   по текущему Postbox; inline custom emoji требует отдельного media registry.
   Режим edit после restart сбрасывается и в референсе. Внутри процесса отдельная
   per-chat session восстанавливает source, typed text/entities и выделение при
   смене диалога/сервиса, сохраняя ordinary/reply отдельно. Session/revision guards
   защищают новый ввод от позднего applied ACK. Native QA приняла две независимые
   правки, rich selection после смены чата/сервиса, cancel/source reopen и restart
   без edit при сохранённом ordinary/reply. Account stop очищает временный кеш.
   Topic navigation, quote и серверные drafts ещё впереди. Настройка
   Enter / ⌘Enter подключена к ordinary/reply, edit и caption через guarded submit;
   modifier/persistence tests и full gates пройдены. В synthetic общем окне
   проверены оба варианта, Return/keypad Enter reply, ⌘Enter edit/caption,
   newline/undo, настройка после restart и смена при открытом редакторе.
   Actual IME/server acceptance ещё впереди. Подготовка фото/файла сохраняет typed
   подпись и выделение, очередь передаёт native entities и проверяет упоминания;
   точный revision ACK защищает новый ввод. Modal preview показывает документ
   или нормализованное фото, переносит полный input/selection и временно скрывает
   ordinary/reply. Cancel/Escape возвращает исходный draft; edited-caption ACK
   очищает только его revision. Durable original переживает завершение процесса.
   Pending-caption/file restart подключён к runtime/UI: точные bytes в
   зашифрованном S3, метаданные в PostgreSQL, typed caption/original/reply/state в
   отдельном account/chat Postbox key с CAS и cancellation tombstone. Initial
   save блокирует отправку; latest caption + submissionStarted сохраняются до
   provider, accepted — до ACK исходной revision. Prepared reply разрешается
   заново; восстановление/ошибка блокируют обычную отправку и действия. Неизвестный
   результат восстанавливается без автоматической отправки. Recipe 6 проверяет
   owned pointer перед native enqueue и сохраняет accepted receipt в той же
   Postbox transaction, что и сообщение. Receipt требует существующее outgoing
   Local сообщение с точной подписью/entities. Потерянный UI callback восстанавливается
   по receipt без повторного enqueue. Старые submissionStarted не сопоставляются
   по тексту; live local-to-cloud reconciliation ещё впереди.
   Нативно проверены file/photo restart, rich caption/
   selection, отмена без resurrection, synthetic ACK и переключатель сервисов.
   Failed cancellation имеет видимый storage-only retry; отмена сохраняет
   immutable S3 copy. Дополнительно проверены synthetic lost-ACK modal без Send,
   restart с тем же Postbox/receipt, отсутствие повторного modal и сохранение
   нового черновика при следующем restart. Account/server, power-loss и disk-failure
   acceptance, inline media, albums и premium
   caption limits остаются открытыми.
   Индикаторы отправки/ошибки и одна/две галочки рядом со временем следуют
   `ChatRightView`; прочтение берётся из native history entry. Видимая граница
   обычной cloud-истории отмечается через native interactive read только в
   активном окне без modal/sheet; поиск и устаревшие наблюдения исключены.
   Read-state и pending sync проверены после reopen Postbox; подтверждение
   сервером, secret/topic read handling и полный crosspost UI ещё впереди.
   Чтение исходных rich entities, спойлеры и подтверждение скрытых ссылок добавлены
   в историю/поиск; в истории добавлены блоки кода с заголовком/копированием и
   цитаты со сворачиванием по правилам референса. Copy protection применяется
   к reader/action preview. Syntax highlighting, непрерывное выделение между
   блоками, архивные entities/capabilities, custom emoji и pointer acceptance
   ещё открыты.
   Из заголовка открывается карточка собеседника по сценарию TelegramSwift;
   добавлена явная связь с новым/существующим PostgreSQL-досье с сохранением
   ручных полей и источников. Native create/link/restart проверены; переход
   в полный dossier снова ограничен сбоем UI-автоматизации. Карточки групп,
   супергрупп, каналов и ботов показывают доступное описание и счётчики;
   native peer-view обновляет карточку, а связь с досье ограничена человеком.
   Статические native-аватары добавлены в список/заголовок/карточку, cached
   presence — в заголовок/карточку с expiry timer, privacy buckets и календарными
   часами/«вчера»/датами. В списке есть отдельные online badges из native presence,
   включая реактивный локальный поиск, expiry и selected variant. Аватар карточки открывает статическую галерею native фото
   с мышью/клавиатурой, датой, неполным total count и повтором загрузки. Галерея
   теперь использует borderless окно размером с экран, реальные миниатюры,
   zoom/pan/rotation и Save исходного скачанного representation. Клавиши работают
   при русской раскладке; Save panel сохраняет собственный фокус. Переход из
   аватара, точная тема/hover/анимации, дополнительный F-режим, public fallback
   фото и видеоаватары ещё впереди, как и
   списки участников, управление и остальные профильные действия. Реальные
   server refresh/presence/photo fetch отдельно не приняты.
   Почтовая инвентаризация выполняется
   независимо заранее; переключение на следующий сервис не закрывает пробелы
   Telegram и не меняет общий порядок.

## Пересылка в composer

Пересылка теперь проходит через выбор получателя и его обычный composer в общем
окне. Сохраняются rich comment/selection/reply, source IDs/fingerprints и опции;
Cancel убирает только пересылку. Schema4 совместима с legacy1/2/3. Полный batch
comment+forwards проходит повторную transaction admission; локальный accepted
receipt и storage-only consume защищают от автоматического resend после restart.
Неизвестный исход и недоступный источник сохраняют черновик. Новое вложение при
активной пересылке пока явно недоступно. Saved Messages immediate exception,
остальные selection actions, темы, paid/secret и live-account acceptance остаются впереди.
Окончание этого участка не завершает Telegram или общий последовательный перенос.

## Текущий участок: выбор нескольких сообщений

Меню «Выбрать» включает typed selection до 100 сообщений. Панель count/cancel/forward
временно заменяет composer без изменения ordinary/reply/edit; выбор переживает
пагинацию и переключение сервисов в общем окне. Пересылка фиксирует revision,
native порядок и все source fingerprints; picker только открывает recipient
composer с batch. Защищённый или изменённый source блокирует весь batch. Cancel,
поиск, смена чата/account очищают выбор; restart его не сохраняет. AX использует
маскирование spoilers и безопасный fallback при недоступном formatting.
Shift-click добавляет сохранённый диапазон через границы страниц: endpoint
переключается первым, затем cached Cloud/Local IDs добавляются по убыванию до
лимита 100. Shift-deselect снимает только endpoint; anchor сохраняется.
Recipe 7 использует ограниченный native ID index без перебора пропущенных чисел
или сетевой загрузки. Поздний ответ требует прежние session/revision/account/
window; смена страницы отменяет только pending range, сохраняя уже выбранное.
Forward блокируется до завершения; изменённая off-page версия инвалидирует frozen
source. Scheduled/topic/migrated-peer ranges, album individual/group selection,
copy/delete выбранных сообщений и Saved Messages immediate exception ещё впереди.
Общий порядок переноса сохранён.
