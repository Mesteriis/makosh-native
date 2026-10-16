# Mail completion implementation plan

> **For agentic workers:** Use executing-plans inline; one final same-model fresh review. Preserve the dirty feature checkout and evidence.

**Goal:** Complete the agreed remaining mail functionality, excluding calendar and OAuth.
**Architecture:** Extend MakoshMail account workers and encrypted PostgreSQL state. MainActor only coordinates UI. Reuse reviewed MMail workflows and Aether layout. No new protocol library.
**Tech Stack:** SwiftUI/AppKit, Swift actors, NIO/OpenSSL3, PostgreSQL, encrypted S3.
**Spec:** User-approved remaining list in this thread and docs/mail-migration.md, with calendar/OAuth explicitly excluded on 2026-10-15.

## Global constraints
- Preserve unrelated work; no commit, push, merge or publication during this pass.
- Real accounts, live calls and ordinary-bundle notification checks remain paused.
- Permanent retained versions; S3 OFF forbids every new binary/raw copy.
- Automatic MOVE/SMTP must be durably admitted; uncertain outcomes prohibit replay.
- macOS26+, Apple Silicon, native common workspace, no reference runtime dependency.

## Review focus
- Concurrent windows/process restart must not duplicate scheduled SMTP or rule MOVE.
- Cancellation, disconnect and IDLE completion must not interleave tagged commands.
- A changed account/UIDVALIDITY must reject stale notifications and rule actions.
- Long HTML must remain inert; history browsing must never overwrite current state.
- Bundled TLS trust and dylibs must work with Homebrew absent; notarization requires a configured identity.

### Task 1: Templates, signatures and incoming rules
Files: MakoshMail/MailAutomation.swift, MailRepository.swift; App/MailAutomationSettingsView.swift, MailComposeSheet.swift, MailWorkspaceModel.swift; MailAutomationTests.swift.
Interfaces: encrypted optional MailAutomationState in MailSnapshot; account-scoped preferences and durable incoming action receipts.
- [x] RED: persistence/reopen, independent scopes, nonmatching rules, Trash precedence, no historical flood, two-window one admission, unknown MOVE no replay.
- [x] Implement matching MMail from/subject substring rules, local labels, signatures and templates. Fetch/retain full body before automatic move.
- [x] GREEN: focused automation/store/worker tests; record raw output.

### Task 2: Scheduled sends
Files: MailAutomation.swift, repository/worker, compose/outbox/model; MailSchedulingTests.swift.
Interfaces: persisted prepared MailDraft and due timestamp, single atomic claim, existing submission receipt remains authority.
- [x] RED: due time boundary, reopen, concurrent claims, cancellation before dispatch, no automatic replay after uncertain admission.
- [x] Implement scheduling/cancel/edit and actor-owned scheduler while application/account is active. UI explains closed-app behavior.
- [x] GREEN: scheduling/store/SMTP fixture tests.

### Task 3: IDLE
Files: IMAPService.swift, MailAccountWorker.swift, protocol fixture/tests.
- [x] RED: server unsolicited EXISTS wakes refresh before polling; cancellation DONE and tagged completion precede next command; unsupported server falls back; reconnect and teardown.
- [x] Implement a separate read-only watcher connection per account/folder; CAPABILITY gate, bounded IDLE renewal, cancellation-safe teardown, existing polling fallback.
- [x] GREEN: loopback protocol/worker tests.

### Task 4: History and long reading
Files: repository, MailReadingHistoryView.swift, MailViews.swift, MailHTMLView.swift; archive/reader tests.
- [x] RED: ordered immutable full historical versions, cross-letter isolation, long text/HTML accessible past previous truncation.
- [x] Implement paged version browsing and bounded text pages/full inert HTML, retaining the original body.
- [x] GREEN: PG/reader tests and native synthetic interaction.

### Task 5: Notification cold start
Files: MailNotifications.swift, repository, MailNotificationController.swift, MailSystemNotifications.swift, common router; notification tests.
- [x] RED: reopen a delivered opaque route after restart, one destructive admission, expired/stale/unread/privacy/account checks, no untrusted userInfo identity.
- [x] Persist opaque route bindings encrypted and rehydrate through repository before action; retain shared delegate and consent semantics.
- [x] GREEN: notification tests; ordinary macOS banner acceptance stays paused.

### Task 6: Reference UI acceptance
Files: changed mail views, reference-interface/development ledger.
- [x] Compare actual reference source/screenshots; fix native dossier/menu/resize issues found in isolated synthetic QA.
- [ ] Final native acceptance: settings/templates/scheduling/history/long reader/service-switch and normal/zoomed layouts verified; dossier inspector verified, Open Dossier remains blocked by a reproducible native CUA pipe closure.

### Task 7: Portable bundle
Files: scripts/build-app.sh, packaging helper/tests, TLS trust bootstrap, README/docs.
- [x] RED: recursive dependency graph has no non-system absolute Homebrew load paths; controlled bundle CA file is available without Homebrew.
- [x] Bundle reviewed libpq/OpenSSL dependencies and notices/trust source with checked provenance; strict sign and validate actual ARM64 bundle.
- [x] Report notarization/clean-machine validation honestly if required identity/machine is unavailable.

### Task 8: Final integration
- [x] scripts/dev-db.sh up → scripts/test.sh → scripts/build-app.sh, preserve exact exits/raw logs.
- [x] Fresh XERJ source fingerprint, final same-model read-only review, repair Important/Critical with regression RED/GREEN.
- [x] Update docs/AGENTS scope, actual results and remaining live/distribution acceptance. No claim of real provider delivery.


## Final validation notes
Broad gateC completes services→tests→build→repeat build, all exits0 with unchanged
source:2533 XCTest (one microphone precondition skip),131 Python tests/27 suites.
A later presentation-only change replaces the clipped native settings tab strip
with explicit segmented labels;100 Mail tests and two bundle builds are rerun.
No protocol/storage/TLS changes follow gateC. Notarization/clean Mac and live
provider/ordinary-banner acceptance remain explicitly unavailable/paused.
