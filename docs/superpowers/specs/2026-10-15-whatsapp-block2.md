# WhatsApp block 2

User authorization: implement the entire second WhatsApp block in the existing
workspace. Zen revision 790066aa411d395562a572101a74057147af67db remains the
functional/layout reference. Block 1 is the accepted foundation, not work to redo.

## Result

Complete the remaining native workspace workflows: durable outgoing text,
reply/edit/reaction/forward/revoke, delivery/read receipts, rich media and files,
voice/stickers/location/contact/polls, retained statuses, chat/message search and
favorites, chat/group/profile controls, account/chat notification preferences,
per-chat S3 admission, source-scoped dossier association, and audio/video calls.
Reference destructive cache/history actions must never remove Makosh retention.
Status expiry hides an item from the current status view, not from the archive.

## Required boundaries

- Rust is a separately licensed and sourced AGPL process. Review exact newly
  enabled dependencies before use. No Swift linking or reference-folder runtime.
- MainActor only conducts UI. Protocol/SQL/keys/crypto/files/media own workers.
- Persist a unique outgoing attempt before dispatch. Lost/timeout result is
  unknown, blocks automatic replay, and cannot be overwritten by late completion
  for another attempt. Restart must preserve uncertainty and every recipient/file.
- Archive all received versions before durable acknowledgement. Receipt updates
  are monotonic and account/source scoped. Remote revoke retains prior content.
- File bytes use encrypted S3 or encrypted local preparation, never PostgreSQL.
  S3 OFF forbids all new copies; personal chats default ON, groups OFF. Existing
  objects remain readable. No local preparation is promoted on a later toggle.
- One macOS notification delegate; encrypted durable account/chat preferences,
  baseline historical content, consume muted events, callback-time account/read/
  privacy/window guards. No private text, keys, QR or protocol logs.
- Calls own generations and bounded media queues; explicit camera/microphone
  permission. No global media singleton. Active-call device switching excluded.
- Account identity and exact external IDs never silently rebind. Dossier links
  retain provenance and use existing transactional contact contracts.

## Acceptance

Meaningful native/Rust/PostgreSQL/S3 regressions, reference UI comparison, all
repository build/test gates, source/runtime closure verification and one fresh
whole-change review. Tests use qa_whatsapp_ application AND archive schemas and
fixed isolated keys. Real WhatsApp linking/messaging/calls remain pending a
selected account and explicit resume; Telegram/mail live QA stays paused.
Compilation, synthetic behavior, queue admission and real delivery are separate
evidence. No Git publication or release/notarization is requested.
