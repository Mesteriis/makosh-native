# WhatsApp: закрытие открытых вопросов

Дата: 2026-10-16. Статус: спецификация утверждена пользователем.
Пользователь поручил реализовать WA-OQ-01/02/03/05/06/07/08, затем явно
утвердил эту письменную спецификацию. Implementation plan и выбор исполнения
проверяются отдельно перед началом продуктовых изменений.
Продуктовый код этим документом не изменён. Живые проверки остаются на паузе.

## Результат и границы

Продолжить существующие MakoshWhatsApp, SwiftUI workspace и отдельный AGPLv3
Rust-процесс: читаемые карточки контактов, опрос без повтора вопроса, обычный
список без технической строки статусов, фотографии профилей, несколько
вложений с явными лимитами, редактор фотографий по Zen и групповые аудио/
видеозвонки на уже закреплённом движке. Существующие личные звонки, сеансы,
постоянная история, неизвестные результаты отправки и S3 OFF сохраняют контракт.

WA-OQ-04 (финальная визуальная проверка досье) остаётся отдельным критерием:
новый запрос перечисляет остальные семь вопросов. Проверки переходов досье
можно повторить в изолированной QA, но сбой CUA нельзя объявить успешной приёмкой.
Нет разрешения возобновлять QR/account/provider/Keychain/TCC/микрофон/камеру.
Код-пароль, автоблокировка и переключение устройств активного звонка исключены.

## Проверенная основа

- HEAD: 76c43e63fc37bc9254cc163d6a0a2e46acab6a42; текущий checkout содержит
  ранее выполненную, ещё не опубликованную работу. Не переключать ветку, не
  откатывать чужие изменения и не смешивать этот блок с публикацией.
- Zen: 790066aa411d395562a572101a74057147af67db, MIT. Макош использует свой
  independently pinned whatsapp-rust =0.7.0 и отдельный AGPLv3 worker.
  Исходники crate указывают VCS f8165f282008935732e0b26d6f5cca5038ecd222.
  Исследовательские пути ниже нужны только разработчику, не build/run/test.
- XERJ project-v23 и whatsapp-zen проверены fresh перед исследованием;
  реальные запросы сохранены в ignored .local/whatsapp-open-questions/ и
  подтверждены чтением соответствующих исходников.
- Zen PhotoEditor.swift: EditablePhoto/PhotoSendSheet, crop/rotate/pen/arrow/
  rectangle, палитра, отмена штриха/reset, подпись, полоса фотографий и HD.
  Images.swift: длинная сторона 1600/4096, итоговый JPEG quality0.82.
- Zen Store.swift attach([URL]): подготовка нескольких фотографий/файлов,
  отправка по одному сообщению в исходном порядке; File сохраняет оригинал.
- Makosh: WhatsAppViews.swift сейчас печатает сырой vCard и повторяет текст
  опроса; ComposerModel.send и Worker.sendContent запрещают files.count>1;
  низкоуровневый outbox допускает до10 IDs. Swift/Rust file cap —100MiB.
- Закреплённый SDK уже имеет Voip.group_call, group_call_by_id,
  OutgoingGroupCall.group/start, accept, CallHandle.group_state/
  invite_participant/ring_participant. GroupCallState хранит состав, а
  VideoFrame содержит sender/device/pid. Лимит SDK —32 участника, включая себя.
  OutgoingGroupCall требует минимум двух удалённых участников. Это наличие
  API и исходников, а не доказательство реального группового соединения.
- Сейчас wrapper calls.rs отбрасывает group_jid, start запрещает group peer,
  snapshot не имеет состава, MediaQueues.exchange оставляет один video frame
  без sender. Swift controller также запрещает @g.us. Их нужно расширить.
- SDK group_audio.rs содержит ограниченный participant-aware PCM mixer.
  Нельзя передавать все групповые видеопакеты одному декодеру или смешивать
  непомеченные ForeignAudio разных участников личным fallback-декодером.

Публичные первичные источники для перепроверки:
[Zen PhotoEditor](https://github.com/mdenizay/whatsapp-zen/blob/790066aa411d395562a572101a74057147af67db/app/Sources/WhatsAppZen/PhotoEditor.swift),
[SDK facade точного VCS](https://github.com/oxidezap/whatsapp-rust/blob/f8165f282008935732e0b26d6f5cca5038ecd222/src/voip/facade.rs),
[SDK group types](https://github.com/oxidezap/whatsapp-rust/blob/f8165f282008935732e0b26d6f5cca5038ecd222/wacore/src/types/group_call.rs).
Текущий README SDK подтверждает групповой API, но реализация связывается с
проверенным локальным crate/pin, а не с плавающим main. Сайт media API не
открылся через web-инструмент; его содержимое не используется как доказательство.

## Варианты

1. Рекомендуемый: расширить текущий закреплённый стек одним согласованным
   блоком с отдельными частями presentation, avatars, batch, photo editor,
   group calls. Нет новой внешней зависимости или альтернативного backend.
   Цена: нужно расширить IPC/media DTO и проверить групповые потоки.
2. Сначала только presentation/файлы, групповые звонки вынести в следующий
   блок. Меньше изменений за проход, но перечисленный пользователем объём
   не будет завершён целиком.
3. Обновить движок до более нового upstream. Потребуются новый аудит API,
   лицензий и воспроизводимой сборки; уже закреплённый0.7.0 имеет нужный API,
   поэтому обновление без выявленного конкретного дефекта не предлагается.

## Карточки контактов, опросы и статусы

WA-OQ-01: service-side чистый ограниченный parser vCard3/4 преобразует
FN/N/TEL/EMAIL/ORG в immutable presentation DTO. Поддержать folded lines,
escaped separators/newlines и TYPE, несколько телефонов/адресов. Исходный
vCard сохраняется в прежней encrypted version без перезаписи; malformed поля
дают безопасное отображение имени и действие «Исходная карточка».
Не использовать системную адресную книгу и не импортировать контакт автоматически.
Лимит входа256KiB,2048 строк,128 отображаемых полей; BINARY/PHOTO/URL не
скачиваются и не исполняются. Произвольные URI не становятся активными ссылками.

WA-OQ-02: rich poll показывает заголовок один раз; скрывать общий message.text
только когда он является тем же вопросом. Другой текст не теряется. Сохранять
варианты, подсчёт/выбор голосов и архив; duplicate labels не должны создавать
одинаковые SwiftUI IDs. Запрещено изменять сохранённый источник ради вёрстки.

WA-OQ-03: status@broadcast исключается только из обычного списка диалогов,
фильтров/счётчиков этого списка и выбора адресата. Раздел «Статусы», архив,
версии и их источник остаются доступными. Не удалять строку из PG или journal.
Обычный пользовательский чат с названием «Статусы» не должен исчезать.

## Фотографии профилей

WA-OQ-05: собственный worker command получает preview через существующий
contacts().get_profile_picture. Запросы допускаются только для явно подключённого
аккаунта; UI init/body не начинает protocol IO. Дедупликация одновременно
запрошенных (account,JID), bounded concurrency2, явное обновление, отмена при
смене аккаунта/закрытии. Отсутствие фото/запрет сервера показывают инициалы.

Скачать по HTTPS с обычной проверкой сертификата, без cookies/credentials,
redirect и произвольных пользовательских URL. Разрешён pps.whatsapp.net и его
поддомены; другой CDN даёт безопасную недоступность и требует отдельного
подтверждения источника/allowlist, а не расширения на любой HTTPS host. Лимит
ответа4MiB, таймаут20s. ImageIO downsample вне MainActor до512px; отвергать
неизвестный формат/слишком большие размеры (более16MP), не декодировать анимацию.

Avatar — заменяемый локальный UI cache, не архив вложения сообщения. Persistent
cache шифруется в приватном account directory; PG содержит metadata/key, не bytes.
Никаких S3 копий аватаров в этом блоке. Кэш источников ограничен64MiB на аккаунт,
декодированный cache —8MiB на окно; удаление cache не затрагивает постоянную
историю. Picture-change notification инвалидирует точный account/JID. Если
провайдер не дал события, ручное обновление остаётся доступным. В UI списка,
заголовка/профиля и участников звонка используется общий scoped avatar view.

## Несколько вложений и лимиты

WA-OQ-06: до10 файлов за одно действие Send; каждый≤100MiB, суммарно≤1000MiB.
Лимиты продукта видны до отправки и одинаковы в UI/Swift worker/Rust. Это не
заявление о максимуме WhatsApp или автоматическое расширение до2GB.
Picker допускает multiple selection; подготовка последовательная, со списком
порядка/размера/ошибки и возможностью удалить элемент. «Файл» оставляет исходные
байты; «Фото» открывает подготовку/редактор. Видео/аудио/стикеры сохраняют уже
имеющийся сценарий, без выдуманного видеоредактора.

Batch — локальная durable группа отдельных сообщений, не серверная атомарная
операция. До первого network dispatch атомарно фиксируются frozen batch и все
child outgoing rows с отдельными ID/attempt/file ID. Текст/подпись и reply
прикрепляются только к первому сообщению, как в Zen; порядок выбранных файлов
фиксируется, изменение черновика не меняет уже принятую группу.

Отправлять последовательно. После rejected/unknown остановить оставшиеся
prepared элементы. UI показывает точный исход каждого файла. Sent не повторяется;
unknown требует существующего явного resolution; restart не делает автоматической
отправки. Явное продолжение допускает только ещё prepared children и не пересоздаёт
batch/attempt у уже отправленных. Другой процесс не может повторно владеть child;
batch имеет отдельную session advisory lease на время dispatch/продолжения.

Черновик очищается только по durable admission для совпавшего account/chat/
revision. Поздняя подготовка/отправка не очищает другой чат. Вложения ранее
подготовленного draft можно переставлять до admission. Отмена подготовки
сохраняет уже подтверждённые элементы и явно показывает неготовые; нет частичной
скрытой отправки. Plaintext leases закрываются после drain; private encrypted
spool используется для restart. Старые одиночные outgoing остаются читаемыми.

S3 policy проверяется на каждом новом admission и производном файле. OFF не
разрешает originals/previews/edited/normalized/recovery copies в S3; используется
encrypted local spool. Включение позже не переносит старые preparations в S3.
PostgreSQL хранит metadata/receipts/keys/recipe, никаких файловых bytes.

## Редактор фотографий

WA-OQ-07: воспроизвести PhotoSendSheet Zen внутри текущего workspace: центральный
preview, toolbar перо/стрелка/прямоугольник/палитра, crop с apply/cancel, поворот
на90°, undo/reset, полоса выбранных фото, подпись, standard/HD, cancel/send.
Standard —1600px, HD —4096px по длинной стороне; JPEG quality0.82, без увеличения
маленького источника. Не обещать text/stickers/filters/video trim: их нет в
проверенном PhotoEditor. Отправка «как файл» всегда обходит преобразование.

Editor модель хранит нормализованные координаты и последовательность правок.
Preview/экспорт/EXIF orientation/resize/JPEG и файловые операции исполняются
worker-ом; MainActor управляет жестами и immutable preview. Worker проверяет
finite coordinates, допустимый crop и размер; верхние пределы:40MP вход,
4096px export,256 операций и32768 точек на фото. EXIF/GPS metadata не переносить
в новый JPEG. Source не изменяется. Undo относится ко всему стеку правок,
reset возвращает исходную ориентацию/кадр. Ошибка экспорта не подменяется оригиналом.

Оригинал/recipe/готовое изображение привязаны к account/chat/photo UUID/revision.
Recipe сохраняется зашифрованно вместе с локальной подготовкой; restart открывает
тот же draft без отправки. Повторный экспорт того же подтверждённого recipe не
создаёт скрытых S3 копий. Не удерживать все полные изображения пакета в памяти;
один bounded render, остальные — thumbnails. Поздний render не заменяет новое
редактирование и не попадает в другой чат.

## Групповые аудио/видеозвонки

WA-OQ-08: исходящий из group chat с явным выбором участников и audio/video;
входящий group-bound/ad-hoc принять/отклонить; состав и состояния участников,
mute/local camera, приглашение нового/повторный звонок уже указанному участнику,
покинуть звонок для себя. Личные звонки также могут расширяться приглашением.
Не добавлять call links, screenshare, waiting-room admin, hand/reactions или
управление чужими устройствами: это отдельные SDK возможности вне запроса.

Исходящий group builder:2..31 удалённых участника, максимум32 включая себя.
Точный SDK/server limit проверяется перед admission. Own PN/LID/AD aliases и
дубликаты исключаются проверенным SDK; неизвестная принадлежность не скрывает
предупреждение или не отправляет вызов другому identity. Состав группы читается
для picker явно подключённым worker; после await и перед start повторно
проверяются account/chat/call generation и выбранные адресаты. Нельзя вызвать
всю группу без явного действия пользователя.

Rust использует уже закреплённые group_call(targets).group(groupJID)/accept и
CallHandle API. Snapshot содержит sanitized roster с source JID/device/pid/state;
relay credentials, keys, capability blobs и raw signaling наружу не выходят.
События roster/terminate обязаны проверять callID+epoch; входящее сообщение о
группе не должно разрушить активный личный звонок. Один активный звонок на
account; существующий оконный coordinator сохраняет владение этим звонком.

IPC/media DTO расширяются additive полями с backward defaults для старых
личных DTO/fixtures. Group frames сохраняют sender/device/pid до UI. Для
каждого source отдельный decoder и ограниченная очередь последних кадров;
пакеты ушедшего участника/старого epoch отбрасываются. Нельзя брать последний
кадр всего звонка и выдавать его за одного собеседника.

В UI до9 видимых remote video tiles с paging/pin; остальные участники доступны
аватарами/состояниями. Одновременно максимум9 native decoders. Reply одного
media exchange содержит не более4 кадров по≤256KiB (общий≤1MiB), с fair
round-robin по видимым stream; request не превышает существующий2MiB framing,
reply≤8MiB. Видео вне видимой страницы не копится; decoder при повторном
показе начинает с keyframe. Размер декодируемого кадра ограничить1920×1080, отображаемый tile —640×480.

Audio playout использует participant-aware SDK PCM mixer; проверить несколько
говорящих, уход/rekey и silence/DTX. Личный ForeignAudio workaround нельзя
применять одним декодером ко всем источникам группы. Media/codec/queues остаются
в Rust/private Swift executors, MainActor получает ограниченные snapshots.

Поздний accept/offer/roster/frame после cancel/leave/account switch не возрождает
звонок. Teardown асинхронный, активная media epoch отзывается до drain. Unknown
offer/invite не повторяется автоматически и не восстанавливается после restart
как разрешение звонить снова. Invite/ring имеют собственный command attempt
и явный результат. «Покинуть» не обещает завершить звонок остальных участников.

## Модули, совместимость и происхождение

Расширять конкретные workers, без универсальной plugin architecture. Выделить
небольшие source units: contact presentation, avatar worker/cache/view, outgoing
batch persistence/model, photo recipe/renderer/editor, group-call roster/media.
Общие manifests, provenance, notices и docs изменяет основной исполнитель.

Существующий pin/feature graph0.7.0 и Opus1.6.1 сохраняются. Изменения generated
SDK только через reviewed patch/preparation recipe с новыми hashes; никогда
прямым редактированием .local/whatsapp-engine. Если фактический SDK дефект
требует patch, воспроизвести его offline regression и включить patch/source в
AGPL corresponding-source archive. Существующее разделение процессов/лицензий
и отсутствие Rust linkage в Swift executable сохраняются.

Изменения PG additive; старые outbox/files/versions и session/Keychain ключи
не переписываются. Identity — service/account/sourceID. Любой новый cache,
batch и media generation обязан включать account. Нет TTL/удаления сообщений,
автоматического logout/reset или replay неизвестных отправок.

## Проверка и завершение

1. Regression RED/GREEN: hostile/полный vCard, poll text/duplicate IDs, scoped
   status filtering, avatar account/cancellation/HTTPS/size/cache encryption.
2. Реальный isolated PostgreSQL/S3: batch atomic admission, live owner across
   processes, partial rejection/unknown/restart/explicit continuation, policyOFF
   до/во время preparation/export/recovery, ни файловых bytes в PG, ни новых
   PUT приOFF. Сохранение одиночных старых записей.
3. Synthetic photo pixels/coordinates: EXIF orientation, rotate+crop+marks order,
   standard/HD/no-upscale, metadata removal, cancel/stale generation, bounded
   memory/admission и восстановление того же recipe без отправки.
4. Rust/Swift group fixtures: start/accept/roster/invite/ring/leave,2..31 targets,
   duplicate/own identity, participant stream separation, multi-device/pid
   migration/rekey, bounded media fairness, simultaneous PCM, terminal races,
   late callbacks и полный набор регрессий личного звонка. Синтетический active
   или смешанный PCM не является доказательством WhatsApp connection/audio quality.
5. Canonical scripts/dev-db.sh up, scripts/test.sh, scripts/build-app.sh;
   rust clippy и проверка standalone corresponding-source build при изменении
   Rust/SDK inputs. Ordinary/QA signatures, ARM64/runtime/source/notices,
   absence-of-reference build, diff review и свежие XERJ fingerprints/queries.
6. Свежая изолированная QA с обоими qa_whatsapp_ schemas, loopback PostgreSQL/S3 и fake keys/vault/provider/
   opener/media; остальные service hosts не стартуют. Реальные UI сценарии:
   contact/poll/status/list avatars,10 mixed attachments, editor/restart,
   partial outgoing и multi-participant call preview/roster/leave; обычное и
   увеличенное окно. Отказ CUA/TCC фиксируется, не обходится другим доступом.

Результаты публикуются в docs/development-status.md, whatsapp-migration.md и
reference-interface.md отдельно: implemented, compile/tests, synthetic UI,
реальная доставка/звонок/OS. Этот документ пока не утверждает ни одного нового
PASS и не разрешает публикацию/реальные аккаунты. После утверждения требуется
письменный implementation plan и выбор способа исполнения.

## Самопроверка спецификации

Все семь выбранных WA-OQ имеют конкретный результат, владельца, лимит,
failure/restart/identity boundary и критерии проверки. WA-OQ-04 и live QA не
смешаны с закрытием разработки. Group API проверен по закреплённому исходнику;
никакого нового backend, необоснованного2GB или фальшивого group connection.
Новый UI редактора следует Zen, обработка и хранение следуют границам Макоша.
Неопубликованный baseline сохраняется. Продуктовые файлы/зависимости не менялись;
build/tests на этой стадии не запускались.
