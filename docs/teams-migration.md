# Teams — нативный перенос, 2026-10-16

Реализован отдельный `MakoshTeams` на Swift в общем workspace. Основа — публичные
Graph/OAuth-контракты MIT teams-cli `9c8a72c32369f9d9bd15b793099522a80070a063`.
Точный продуктовый pin, сохранённые исходники auth/graph и notices находятся в
`Dependencies/Teams.lock.json`, `Dependencies/Teams/`, `LICENSES/Teams-cli-MIT.txt`.
Rust/CLI/TUI и чужие client ID/токены в продукт не включены. Сборка, тесты и запуск
не используют исследовательские клоны. Статус доказательств — [development-status](development-status.md).

## Возможности и границы

- Несколько рабочих/учебных аккаунтов, чаты, команды, каналы и отдельные ветки.
- Явный вход PKCE через системный браузер или device code, отмена, reconnect,
  обновление токенов с сохранением предыдущего сеанса при неудачном новом входе.
- Полная постраничная синхронизация каталогов, корней и ответов; сохранённая
  переписка доступна без подключения. Отсутствие сообщения в странице не означает удаление.
- Текст и ответы, до10 файлов за отправку, до100MiB каждый. Сначала выбор папки
  и обзор конкретных читателей; перед публикацией состав участников проверяется повторно.
- Постоянный архив всех полученных версий, поиск по тексту/названиям файлов,
  страницы истории и полный JSONL-экспорт. Контент, никогда не полученный клиентом,
  восстановить невозможно. Нет TTL, purge, автоматического удаления или replay.
- Общие/аккаунтные/по беседе правила уведомлений, локальная отметка прочтения,
  S3 по беседе и связь автора с общим досье. Локальное прочтение не является
  подтверждением прочтения в Microsoft.

Личные Microsoft-аккаунты, звонки, screen sharing, календарь, создание чатов,
исходящие edit/delete/reaction, tenant administration и выпуск/notarization
не входят в утверждённый перенос. Используется глобальное облако Microsoft;
национальные облака требуют отдельной проверки.

## Собственная регистрация Microsoft Entra

Создайте public client для рабочих/учебных аккаунтов: single tenant с его GUID
или multitenant с `organizations`. В Макош вводятся название, собственный
Application (client) ID, authority и режим только чтения. Пароли Microsoft и
client secret Макош не принимает. Подключение не начинается при создании модели
или простом просмотре настроек.

Для PKCE используется HTTP loopback `127.0.0.1`, динамический порт и точный path
`/callback`. Зарегистрируйте native/public-client redirect для этого пути.
Microsoft отдельно описывает добавление HTTP `127.0.0.1` через manifest, если
поле портала его не принимает, и правила loopback port matching:
[официальные ограничения redirect URI](https://learn.microsoft.com/en-us/entra/identity-platform/reply-url).
Проверка конкретной регистрации/tenant и фактическое сопоставление динамического
порта остаются частью живой приёмки. Device code требует разрешённого public
client flow, redirect для него не нужен. Условия tenant/Conditional Access могут
запретить один из способов; клиент не обходит отказ.

Разрешения запрашиваются отдельно, без автоматического расширения:

| Выбор в Макоше | Delegated scopes |
| --- | --- |
| Профиль и чтение чатов | openid, profile, offline_access, User.Read, Chat.Read |
| Команды/каналы | Team.ReadBasic.All, Channel.ReadBasic.All |
| История каналов | ChannelMessage.Read.All |
| Полный состав канала | ChannelMember.Read.All |
| Отправка в чат | ChatMessage.Send |
| Публикация в канал/ветку | ChannelMessage.Send |
| Свои файлы | Files.Read |
| Доступные общие файлы | Files.Read.All |
| Поиск файла по sharing URL | Files.ReadWrite |
| Загрузка в свой OneDrive | Files.ReadWrite |
| Общие хранилища | Files.ReadWrite.All |

Grant exchange/install и refresh имеют общую PostgreSQL `.refresh` lease;
refresh перечитывает vault после её получения. Занятая lease не допускает новую
установку токена: повтор входа выполняется явно после завершения владельца.

Дополнительное согласие администратора/лицензии оцениваются для конкретного
tenant. `/shares` требует write scope даже для lookup; без него файл отображается
как недоступный. `redeemSharingLink` не используется. Отказ/отмена дополнительного
согласия сохраняет старый сеанс и архив. ID token проверяется по подписи RS256,
trusted issuer/JWKS, audience, nonce, времени и tenant/user; access token непрозрачен.
Graph `/me` должен совпасть с проверенной личностью. Секретные токены остаются
в checked Keychain API сервисного actor; UI получает только безопасные состояния.

## Хранение, синхронизация и восстановление

Идентичность включает service/account/tenant и byte-exact внешний ID. Thread
сохраняет собственную идентичность; политика файлов наследуется от канала.
Приватный журнал сервиса хранит encrypted текущие записи, append-only версии,
каталоги, checkpoints, события, preferences и outbox в PostgreSQL. Стабильные
lookup tokens выведены отдельными ключами. Full source identity/payload зашифрованы.
Core conversation key — SHA256 canonical scope, полный scope не теряется.

Сервисная транзакция сохраняет полученную страницу, версии, checkpoint и durable
Core projection jobs. Замороженные observation UUID/даты обеспечивают идемпотентный
повтор после сбоя; acknowledgement идёт только после Core commit. Это два
соединения, а не одна межбазовая транзакция. Metadata-only изменения sourcePayload
тоже создают версии. Старые nil-payload события Core совместимы без переписывания.

Следующая страница привязана к точной коллекции/аккаунту/tenant/path; cross-origin,
циклический или повреждённый курсор не отбрасывает уже полученную страницу и
оставляет явное incomplete состояние. Истёкший курсор перезапускает сканирование
с сохранением истории и baseline уведомлений. Read retries ограничены; Retry-After
обслуживается отменяемыми частями. POST/PUT/invite не повторяются автоматически.
Sync/refresh/dispatch защищены held PostgreSQL session advisory locks между окнами
и процессами, а publication — поколениями аккаунта/контекста.

Порядок истории сохраняет порядок страниц провайдера через отдельный operational
индекс scan epoch/page offset; старые строки используют порядок получения. Это
не гарантия абсолютной хронологии по createdAt. Расширенная история не сбрасывается
поллингом; «К новым сообщениям» явно возвращает актуальную страницу. Поиск включает
сохранённые старые/удалённые версии, поэтому одно messageID может встречаться
несколько раз с разными version sequence.

Отсутствующий ключ/ошибка открытия не создаёт новый ключ поверх populated journal,
не очищает кэш и не выполняет logout. Неопределённый COMMIT блокирует все
дальнейшие запросы, включая прямые setters; только внутренний ROLLBACK разрешён
для release. Занятая sync lease возвращает capture drain к очередному poll без spin. Disconnect/shutdown сохраняют данные и асинхронно дожидаются уже принятой
мутации, чтобы известное подтверждение не потерялось из-за закрытия окна.

## Отправка и файлы

До удалённого запроса сохраняются destination, content, unique attempt и admission.
Состояния: prepared → dispatching → accepted/notSent/unknown. Graph201 признаётся
только с проверенным message/resource body. Потерянный/неоднозначный ответ остаётся
unknown после restart; автоматический повтор запрещён. «Уточнить результат»
записывает выбор пользователя, отдельно от Graph receipt, и не отправляет сообщение.
Живой владелец/поздняя попытка не могут быть перезаписаны ручным решением.
Definitive notSent сохраняет черновик и показывает отказ. Accepted/unknown снимают
только исходный неизменённый черновик, даже после перехода в другую беседу;
последующие ручные правки сохраняются.

S3: личный one-to-one default ON, group/meeting/channel/unknown OFF. Выключение
запрещает все новые S3-копии, включая исходящую подготовку/recovery/retry. Старые
объекты и история остаются. Локальные подготовки зашифрованы в private spool;
последующее ON не переносит их в S3 автоматически. PostgreSQL хранит только
метаданные/ключи/receipts, никогда payload bytes вложений.

Перед загрузкой фиксируются все файлы/размеры/hash, затем неизменяемый план папки
и аудитории. Ресурсы загружаются потоковым Graph PUT с уникальными именами и
`conflictBehavior=fail`; затем direct read grants конкретным same-tenant участникам для ownDrive;
для channel — только проверка полного inherited read ACL от точной родительской
папки, без `/invite`. Group/partial/unprovable ACL отвергается. Затем message POST. Каждый этап сохраняется отдельно. Частичный/неизвестный этап
блокирует публикацию и replay. Нет anonymous/org-wide links, приглашений по почте,
автоматического удаления загруженных файлов или расширения доступа. Выбранная
папка должна иметь доказуемую полную owner/coowner ACL без посторонних/широких
разрешений; неподтверждённая или nonowner папка отвергается. Это ограничение может
потребовать другой папки, а не согласия на более широкий доступ.

Скачивание использует owned drive/version/hosted ID, а не произвольный URL из
сообщения. Current eTag проверяется до/после; известная старая версия не заменяется
последней. Допускается один Graph-issued credential-free redirect только к
проверенным Microsoft файловым семействам хостов с public-address preflight;
это не DNS/endpoint pinning. Дополнительный легитимный CDN пока может быть отвергнут.
Accepted attachments привязаны к точной версии и существующей encrypted
preparation/receipt, включая раннее deduplicated серверное эхо. Они открываются
offline и после restart без новой S3-копии или local promotion.
Quick Look получает private plaintext lease; после закрытия lease удаляется.
Экспорт JSONL также private lease и не зависит от S3 ON.

## Уведомления и досье

Первичная история/новый baseline не создают баннеры. Новые unread events и правила
сохраняются/потребляются атомарно; mute не даёт replay после включения. Глобальные,
аккаунтные, parent-channel и exact-thread правила ограничивают друг друга. Один
application delegate обслуживает все сервисы; Teams имеет opaque HMAC routes.
Проверки аккаунта, policy/content, lock privacy и owning-window повторяются после
consent/add/callback; устаревшие previews отзываются. Достаточно key+visible+
nonminimized owning window вместе с active app для foreground suppression.
QA использует fake center и не подтверждает настоящий баннер обычного bundle.

Досье получает tenant/user identity и provenance конкретного аккаунта. Неизвестный
remote tenant не угадывается. Ручные значения сохраняют приоритет. Workspace/request generation проверяется до привязки, до выбора контакта, после
загрузки snapshot и перед навигацией. Поздний результат не переключает пользователя
на досье после смены сервиса/беседы; durable source link сохраняется. PostgreSQL regression
проверен; визуальное открытие досье ограничено повторным native-pipe сбоем CUA.

## Проверка и продолжение

Обычный процесс разработки:

```sh
scripts/dev-db.sh up
scripts/test.sh
scripts/build-app.sh
python3 scripts/verify-teams-dependencies.py
```

Изолированная native QA после сборки:

```sh
python3 scripts/run-teams-qa.py --launch
```

Launcher создаёт свежий bundle `org.makosh.teams.qa`, оба `qa_teams_` schemas,
private config/spool/fixtures/exports под `.local/teams-qa/<UUID>`, строгую подпись
и проверяет совпадение ARM64 executable text с обычной сборкой. Старые QA данные
не перезаписываются. Оба PostgreSQL schemas обязательны, hostaddr pinned loopback,
S3 loopback, fake keys/Graph/vault/notifications; подготовка только из fixtures.
Other-service hosts не запускаются. QA marker без правильных аргументов fail-closed.
`--teams-synthetic-preview` — debug-only. Не копируйте fake keys в реальные schemas.

В QA002 до финального обзора нативно проверены два аккаунта, chat/channel/thread, история65/поиск за первой
страницей, архив/export65, QuickLook/save, два подготовленных файла/папка/читатели,
синтетическая отправка текста, outboxunknown/manual resolution, настройки чата и
общие, обычное и zoom окно. Файлы в Microsoft не отправлялись. После dossier tool failure приложение оставалось живо; затем owned QA002 остановлен
для свежей QA003, данные сохранены. QA003 после исправлений повторно проверяет
оба аккаунта, текст/очистку, явные состояния исходящих, search65, channel/thread,
S3OFF/settings и обычное/zoom окно. Его executable text совпадает с финальным
обычным bundle. Визуальная приёмка досье не объявляется пройденной.

Открытая приёмка: собственная Entra registration, tenant consent/Conditional Access,
реальная авторизация/refresh/reconnect, история/доставка/права/файлы в Microsoft,
обычные macOS banners/Keychain/TCC, clean-machine/minimum-OS/release. Все живые
проверки остаются на паузе до инструкции пользователя и выбора тестового аккаунта.

## Независимый обзор и исправления

Один свежий read-only reviewer проверил94 snapshot hashes до/после обзора,
0 расхождений; нашёл0Critical/8Important/0Minor. Одним проходом исправлены:
ложный accepted для403; повторно доступный отправленный draft после перехода;
grant/refresh race; прямые channel invites; offline reopen своего файла; capture
spin; поздняя dossier navigation; direct writes после failedCOMMIT.108 Teams tests
прошли после исправлений. Missing API/fixture compile ошибки отделены от behavioral
RED. Общие окончательные результаты указаны в development-status.md. Второго обзора
не было. Новые поля operational bindings совместимы с отсутствующим optional полем;
старые pre-release QA receipts автоматически не переписываются, опубликованных
Teams данных до переноса не существовало.

Подробные решения и цена ограничений: [teams-migration-decisions.md](teams-migration-decisions.md).
