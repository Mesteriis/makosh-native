# Teams migration decisions — 2026-10-16

Decisions made during the approved inline plan; each includes its cost if wrong.
These explain implementation limits and pending acceptance, not additional consent.

1. Ruling: work in the existing feature checkout without creating a worktree — the approved plan preserves the preceding uncommitted adapters/dependencies — cost: changes are not isolated in a second Git checkout; exact baseline hashes retained.

2. Ruling: use manual source/hash checkpoints and an immutable review packet instead of per-task commits/commit-range helpers — do not stage the earlier dirty baseline — cost: no separate commit/remote checkpoint until the user requests integration.

3. Ruling: preserve ignored task ledger and raw evidence at completion — without committed checkpoints they are the reproducible execution record — cost: disk use.

4. Ruling: focused iterations may use a private SwiftPM wrapper after scripts/test.sh prepares dependencies — avoids repeating unchanged native preparation for each RED/GREEN — cost if wrong: preparation drift; full scripts/test.sh remains final gate.

5. Ruling: TeamsPage includes continuationFailure and continuation carries visited URL digests — invalid/cyclic nextLink must not discard already received values or falsely mark a scan complete — cost if wrong: checkpoint format includes scan ancestry and may grow for very large scans; consumers must persist the explicit incomplete state.

6. Ruling: add explicit readSharedFiles capability — the approved Files.Read.All distinction needs its own UI grant rather than broadening readFiles — cost if wrong: one additional permission choice.

7. Ruling: Core conversationID uses SHA256 of the collision-free canonical scope, base64url encoded — Core takes a String limited to1024 bytes, while opaque multi-part Teams scopes can be longer; full source identity remains encrypted in the journal/payload — cost if wrong: theoretical digest collision or a mapping migration; no raw IDs are shortened in service records.

8. Ruling: use a concrete TeamsAuthorizationPermit for synchronous vault/principal write admission — a generation check before an awaited actor call alone leaves a late-write window — cost if wrong: cancellation may wait on an already admitted synchronous service write; MainActor stays free, late publication is still rejected.

9. Ruling: settle an already admitted receipt against its immutable account/scope/attempt after disconnect, then reject obsolete UI publication — otherwise a received201 could be lost solely because the window changed — cost if wrong: a local durable receipt may finish after disconnect; no new remote dispatch is admitted.

10. Ruling: channel file-reader review gets a separate optional channelMembers capability (ChannelMember.Read.All) and allMembers API — official v1.0 requires it to include indirect/shared-channel members — cost if wrong: extra explicit consent or channel file sharing remains unavailable; basic/text grants never widen automatically.

11. Ruling: thread file records use the parent-channel Core policy identity while service records retain the exact original thread scope — Core checks S3 policy on file-record conversation identity, so thread-specific aliases could bypass a later parent OFF — cost if wrong: generic Core file lookup requires the Teams mapping; no service/message scope is rebound.

12. Ruling: shutdown drains already admitted mutations before closing their journal — known in-flight receipts must remain durable — cost if wrong: shutdown may wait up to the bounded network timeout; UI executor is never blocked.

13. Ruling: use streamed direct Graph PUT with documented URL conflictBehavior=fail and a unique target, rather than upload sessions — files are bounded100MiB, below Graph250MiB direct limit — cost if wrong: a provider refusal is unknown/not retried; no session recovery/overwrite. Earlier upload-session notes were research, superseded.

14. Ruling: preauthenticated download redirects are restricted to trusted Graph-issued HTTPS Microsoft file host families, plus public-address checks — no arbitrary message URL fetch — cost if wrong: an additional legitimate CDN/national-cloud host is rejected until reviewed; DNS preflight alone is not claimed as endpoint pinning.

15. Ruling: selected folder must prove full owner/coowner ACL visibility and an audience limited to reviewed users; nonowner channel folders fail closed — partial permissions cannot prove exclusivity — cost if wrong: user must select a suitable own-drive folder or obtain eligible ownership, never automatic access widening.

16. Ruling: App links MakoshTeams and Teams tests import MakoshApp in Task7 instead of Task8 — shared system-router tests need actual native host types — cost if wrong: focused builds also compile/link existing app/tests and expose preexisting warnings sooner.

17. Ruling: exact retained versionSequences accompany history values — stable row IDs and version-scoped file access must survive edits/search — cost if wrong: parallel arrays require equal-length validation and API evolution.

18. Ruling: operational provider-order index stores scan epoch/page offset, while immutable versions remain unchanged — API page order differs from observation sequence — cost if wrong: legacy rows use arrival-order fallback and ephemeral old cursors without position are rejected; no absolute timestamp-order guarantee.

19. Ruling: an extended history snapshot remains until explicit latest/selection/search — periodic refresh must not discard loaded pages — cost if wrong: new incoming messages wait until the user returns to latest.

20. Ruling: synthetic QA accepts only loopback PostgreSQL/S3 and owned fixture files, pins libpq hostaddr and parses actual keyword DSNs through libpq — fake keys must never touch private stores or files — cost if wrong: remote developer services/custom libpq options cannot use this synthetic mode.

21. Ruling: synthetic connection is its own state, with a fresh QA-only bundle and no other-service hosts — local fixture success must not claim a protocol connection or OS banner — cost if wrong: ordinary host behavior remains a separate acceptance boundary.

22. Ruling: grant token exchange/installation and refresh share the account .refresh lease — refresh already reloads the bundle after ownership, so old sessions cannot overwrite a new grant — cost if wrong: an incremental grant during an active refresh fails operationBusy and needs an explicit later retry.

23. Ruling: channel files verify complete inherited individual read ACLs from the exact parent instead of creating direct invites — membership must not gain durable extra grants — cost if wrong: group/partial/unprovable inherited ACLs fail closed and may require another eligible folder; no automatic scope widening.

24. Ruling: accepted files bind exact version to existing preparations, including deduplicated early echo — reopening must reuse retained bytes without newS3copy/local promotion — cost if wrong: old pre-release QA receipts without these bindings are not automatically rewritten; no published Teams data existed at baseline.

25. Final: Ruling: real Entra/tenant/ConditionalAccess/provider/delivery/permissions — keep explicit unrun while live QA paused/no selectedTeamsaccount — cost if wrong: interoperability remains unknown until authorized acceptance.

26. Final: Ruling: OS banners/realKeychain/TCC/minimumOS/cleanmachine/release — synthetic/build results do not prove them — cost if wrong: distribution and OS acceptance remain pending.

27. Final: Ruling: dossier visual — repeated CUA pipe failure remains unverified, preserve PG/provenance evidence separately — cost if wrong: final visual layout/navigation is not accepted.

28. Final: Ruling: nationalcloud/CDN/pinning — retain globalcloud/host-family restriction and explicit DNSpreflight limitation — cost if wrong: legitimate additional hosts are rejected until reviewed.

29. Final: Ruling: nonowner/unprovablefolderACL — retain approved failclosed ownership proof — cost if wrong: suitable shared folders can be unavailable.

30. Final: Ruling: personalTeams/calls/screensharing/calendar/chatcreation/outgoingeditdeletereactions — retain explicit scope exclusions — cost if wrong: these operations need separate user scope expansion.

31. Final: Ruling: prior dirty Mail/WhatsApp/Telegram — review only actualTeamsintegration against capturedhashes, no initialsharedbytes available — cost if wrong: no exact textual initialdirtydiff; prior adapters were independently full-tested, not re-reviewed here.

32. Final: Ruling: retained upstreamRust — provenance only, no runtime findings assigned — cost if wrong: upstream runtime defects remain relevant only if a future integration starts compiling it.

No deferred Minor findings. All eight Important findings were fixed in one pass;
no second reviewer, Git publication or real-account acceptance. Detailed current
results: [development-status.md](development-status.md).
