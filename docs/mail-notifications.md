# Почта: уведомления и продолжение переноса

Spec: docs/mail-migration.md, AGENTS.md, принятые правила Telegram/common workspace.
Продолжаем существующий MakoshMail. Источник поведения — MMail Notifier.swift,
AppModel mergeRealFolder/incremental inbox sync и SettingsView Keyboard & alerts.
Историческая первая загрузка не создаёт карточки; новые unread incoming — создают.
Архив/Корзина из карточки выполняют один MOVE, сохраняя независимый архив.

## Task 1: События и настройки вне MainActor

Files: Sources/MakoshMail/MailNotifications.swift, MailRepository.swift,
MailAccountWorker.swift; Tests/MakoshMailTests/MailNotificationStoreTests.swift.
Produces: encrypted preferences + durable INBOX UIDVALIDITY/watermark + one-shot
notification events in the same PG transaction as page persistence.
Consumes: existing MailMessageKey, folder identity and append-only archive.

- Write/run RED for initial baseline, new unread, duplicate/reopen, validity
  replacement, search/older pages, sender/account/folder restrictions, concurrent
  take and persistence. Expected: missing new event/policy behavior fails.
- Implement bounded queue, advance cursor while muted, no replay after restart;
  take events atomically. Expected: focused real PostgreSQL tests pass.

## Task 2: Общий системный обработчик и маршруты

Files: application notification router/center, MailSystemNotifications.swift,
MailWorkspaceModel.swift, WorkspaceView.swift; app boundary tests.
Produces: opaque mail cards, default open / Archive / Trash actions, separate
service namespaces, owning-window/privacy revalidation after async macOS calls.
Consumes: task1 events/preferences, existing Telegram notification delegate.

- RED for permission grant/denial/error, late policy/account/read changes, shared
  initial consent, duplicate/multi-window routes and clear isolation.
- One application delegate routes mail + Telegram. Retain old TG type aliases;
  do not replace its sink or Dock unread source. Categories merge, no raw account/
  sender/message IDs in userInfo. Expected: mail/TG notification boundary tests pass.
- Actions operate only on registered opaque events and current contexts. Archive/
  Trash use existing same-account folders and one non-replayed MOVE; cancellation
  before dispatch stops them. Expected: routing and retained-content tests pass.

## Task 3: Нативные настройки, приёмка и документация

Files: MailNotificationSettingsView.swift, MailViews.swift, development-status.md,
reference-interface.md, mail-migration.md.
Consumes: task1 settings and task2 system authorization state.

- Add global/account/folder/sender show/preview/sound controls within existing mail
  workspace; foreground setting follows MMail (ON by default). Parent restrictions
  remain authoritative. No invented thread UI: mail currently groups by sender.
- Inspect synthetic native settings, save/reopen, mute isolation and mail/TG service
  switching. Expected: actual observed flows, or exact external tool limitation.
- Run scripts/dev-db.sh up; scripts/test.sh; scripts/build-app.sh sequentially.
  Expected: exit0 plus strict signed ARM64/dependency/notice checks. Compilation
  is not native or real-provider proof. Refresh/check XERJ frozen final source.
- Fresh final static review, address Important with RED→GREEN; preserve all prior
  dirty changes. No commit/push/merge and no live account QA in this task.

Review focus: delegate/category collisions, at-most-once source admission, cursor
reset and multi-window ownership, delayed consent/add/privacy checks, stale action
contexts, accidental source mutation/retry, settings isolation and migration.


## Completion continuation2026-10-15

Encrypted saved opaque routes (bounded100) restore known notification actions
after process restart without presenting historical banners. Cold Open reads
retained content offline; Archive/Trash reconnect the stored identity and recheck
generation/unread/privacy before a single atomic claim. Explicit disconnect
revokes account activation. No raw identity from userInfo is trusted. Two
repository connections and cold router activation are covered synthetically;
ordinary macOS cards/sound and real mail remain paused, not accepted.

## Native synthetic acceptance2026-10-15

Mail-wide controls are in the mail sidebar notification button. Each account's
menu opens its own controls; a folder's context menu opens its folder controls,
and a letter's Actions menu opens sender controls. Show/preview/sound restrictions
compose across all levels;
foreground presentation defaults ON. Reset removes only the selected override.

The user granted the isolated org.makosh.mail.qa bundle permission. A fresh QA
process reports authorized. Initial silent/generic cards respected old QA folder
sound and account preview restrictions; resetting those individual overrides
produced UID13 with both features ON. The user confirmed banner, sound and opening;
the encrypted unique UID13 action receipt is consumed. Its immediate reading
selection was not captured. A controlled follow-up verifies exact click-to-open:
UID14 was selected before creating UID15; after the user clicked its notification,
native selected row and reading title both show UID15, matching the user's answer
and the consumed unique UID15 receipt. Actual banner/sound and exact Open are
accepted for this isolated QA bundle.

Individual second-account mute persists and does not prevent first-account
admission. A muted sender's UID14 is retained without notification admission;
its mute survives restart, and restart/unmute do not replay historical cards.
The QA grant does not grant the ordinary product bundle. Real-account testing
remains paused. Current checks and raw local evidence are recorded in
docs/development-status.md; no account content is logged.
