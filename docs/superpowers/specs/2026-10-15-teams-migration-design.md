# Teams migration design — 2026-10-15

Status: Swift approach approved by the user on2026-10-15
(“Утвердить Swift-вариант (рекомендуется)”). The implementation plan and inline method were subsequently approved. All nine
tasks and one final review/fix pass are implemented as of2026-10-16; see current
development-status.md and teams-migration.md for actual checks and unrun live acceptance.

## Intent and existing decisions

The user requested the next selected service, Teams, transferred into Makosh like
Telegram, mail and WhatsApp. Preserve the existing native workspace, independent
service execution, permanent received history, encrypted PostgreSQL/S3 boundaries,
per-source settings and shared dossier. Earlier live-account checks remain paused.
The accepted integration direction is already in
[service-integration.md](../../service-integration.md#teams); this specification
makes its Teams-specific behavior and acceptance concrete.

Reference: rvben/teams-cli at
`9c8a72c32369f9d9bd15b793099522a80070a063`, selected by references.lock.json.
The checked clone is clean; fresh XERJ project/reference searches were confirmed
against auth.rs, graph.rs, config.rs, lib.rs, main.rs and tui.rs. Exact research
file hashes and the pre-task dirty baseline are retained in ignored
`.local/teams-migration/`. No upstream installer, build, login or account store was
used. No previous Telegram/mail/WhatsApp work is to be redone or discarded.

## Verified basis and approach

The reference's public Rust library exposes delegated browser PKCE/device-code
login, token refresh, /me, joined teams, channels, chats, paged messages and text
sending. It is not a ready Swift SDK: its crate also includes CLI/TUI dependencies.
Its TUI supplies account/conversation/message hierarchy, not a native macOS shell.
The actual main.rs load_tui_data path currently fills joined-team names with empty
message arrays; the richer demo is not evidence of a working conversation UI.
Makosh's native views must consume the verified Graph operations directly.
Its capabilities explicitly exclude personal Microsoft accounts, user calls,
screen sharing, private protocols and tenant administration. No attachment upload
or chat-create operation was found in GraphClient; an advertised Chat.Create scope
alone does not establish that feature.

Two viable approaches were compared:

1. **Recommended: native Swift service implementing the inspected public
   Graph/OAuth contracts.** This is expressly allowed by service-integration.md.
   It follows existing Swift actors and storage contracts without adding a Rust
   process or pulling CLI/TUI crates into the app. Cost: Makosh owns the Swift
   transport and OAuth lifecycle, including their security/regression coverage.
2. **Extract and independently pin a minimal Rust library adapter.** This retains
   more of the original implementation but needs a separately reviewed core,
   ABI/process lifecycle and dependency graph; upstream hardcoded keyring/output
   behavior still needs adaptation. Cost: another native runtime boundary.

Running or embedding the CLI/TUI is not a product integration. The recommended
port retains source attribution and an independent product pin/notices; build,
test and run must work without `.references/` or any previous project checkout.
Foundation, Security, CryptoKit and existing MakoshCore/libpq/storage facilities
are the intended runtime dependencies. Any added external library must first be
independently pinned and reviewed; none is installed by this specification.

## Result and boundaries

Implement multiple work/school accounts; explicit delegated sign-in, reconnect,
disconnect and token refresh; teams/channels/chats; complete resumable paging of
messages and channel replies; native text sending and channel replies; attachments;
retained versions/search/export; local unread state and notifications; source-scoped
S3 rules; and person-to-dossier association. A remote send receipt must not be
presented as another user's delivery/read receipt. Unread/read state is local
unless a specific provider contract is independently established.

Personal Teams, calls, screen sharing, tenant administration, undocumented/private
protocols, creation/deletion of teams/channels, chat creation, outgoing edit/delete/
reaction operations, calendar integration and a webhook/backend deployment are
outside this reference transfer. Received edits/deletion/reactions/attachments are
still retained when present in Graph responses. Existing app-passcode/autolock and
active-call-device-switch exclusions remain intact.

## Service and UI ownership

- `MakoshTeams` is a concrete SwiftPM service target, with immutable typed account,
  tenant, conversation, message, attachment, page, attempt and error values.
- Its service/session actors own OAuth, Graph requests, sync/polling and cancellation.
  Separate service-owned persistence/file executors perform libpq, Keychain,
  crypto, parsing, file preparation and S3 work. MainActor only coordinates UI,
  browser presentation, user commands and publication of generation-checked values.
- `TeamsWorkspaceModel` and Teams-specific views replace the current Teams
  disconnected placeholder inside WorkspaceView. Reuse the common sidebar,
  backdrop and dossier contracts; do not import Telegram/WhatsApp domain types.
- Preserve the reference hierarchy: selected account, conversations and selected
  message history. Add explicit chat/team/channel navigation and channel threads
  using the verified Graph structures. Native composer, file preview, outbox,
  profile/dossier and source settings follow existing workspace patterns.
- No IO in model/view initialization; no account connection on selecting a sidebar
  item. Disconnect/teardown is asynchronous. Every suspended result checks account,
  tenant, conversation and generation before publication or further side effects.

## Authentication and identity

Use a Makosh-owned Entra public-client registration or an explicitly configured
organization registration; do not silently borrow teams-cli's bundled application
ID or import its tokens/config/keyring. No client secret or Microsoft password is
accepted by Makosh. Client ID and authority are setup metadata; absent configuration
leaves sign-in unavailable with an actionable explanation, while offline archives
remain usable. Do not create an Entra application or start real sign-in in this task.

Browser PKCE is the default; device code is an explicit alternative. Browser
callbacks bind the pending account/authority, random state, S256 verifier and OIDC
nonce, have a bounded lifetime/input size, and publish success only after validation.
Loopback handling accepts only the owned listener and expected callback; unrelated
requests cannot complete or consume the pending authorization. Device polling
honors interval/expiry, permanently increases delay on slow_down and stops on
decline/cancel/expiry. Raw provider descriptions/codes/tokens/URLs are not logged.

Validate ID-token signature and authority metadata/JWKS, issuer, audience, expiry,
tenant/user claims and browser nonce before binding a session. Graph access tokens
remain opaque. Match the verified principal with /me; another tenant/principal
cannot overwrite an existing account. A changed client registration, authority or
verified principal requires a new account identity. Source identities include the
service, local account, tenant and exact external ID, including guest-user provenance.

Token and archive-key operations happen on owned executors with checked Keychain
results. Missing/unreadable keys fail closed without resetting a session/archive.
Refresh is single-owner across windows/processes; retain a valid previous refresh
token when a successful response omits its replacement. Cancelled incremental
consent preserves the existing session. Reconnect is explicit after invalid_grant;
there is no automatic logout, repeated login prompt or desktop-token extraction.

Request capabilities incrementally:

| Capability | Intended delegated permission boundary |
| --- | --- |
| Basic sign-in and personal chat history | openid, profile, offline_access, User.Read, Chat.Read |
| List teams/channels | Team.ReadBasic.All, Channel.ReadBasic.All |
| Send as the signed-in user | ChatMessage.Send for chats; ChannelMessage.Send for channels |
| Read channel history/replies | ChannelMessage.Read.All, requested separately with admin-consent explanation |
| Read attachment content | Files.Read; Files.Read.All only when the selected shared/channel resource requires it |
| Resolve a sharing-URL-only attachment through /shares | Files.ReadWrite is required by that API even for lookup; explain and request it explicitly, or leave this attachment unavailable without widening access |
| Upload and grant selected-file access | Files.ReadWrite; Files.ReadWrite.All only for an explicitly selected shared/channel destination that requires it |

Do not request Chat.Create or directory/application-wide permissions for unused
operations. The inspected message-post page currently labels its chat permission
table ChannelMessage.Send, while the official permissions reference describes
ChatMessage.Send for user chat sends and matches the pinned reference. Use the
explicit capability split above; retain 403/consent diagnostics and verify the
actual tenant later, rather than automatically escalating to Chat.ReadWrite or
Group.ReadWrite.All.

## Graph, paging and durable synchronization

Restrict authenticated requests to the configured Microsoft Graph v1.0 origin
(initially the global cloud), with correct path-component encoding. Never send
tokens to arbitrary nextLink/contentUrl/redirect hosts. Validate continuation URLs
against the owning account, collection and resource, reject cycles/malformed
pages, and retain every returned item: the reference's truncate-before-nextLink
behavior must not discard records. Page size is at most50 for message lists;
larger logical histories remain resumable instead of being declared complete.

Channel roots and replies are separate resources; exhaust and checkpoint reply
pages explicitly, including replies@odata.nextLink. A bounded polling worker
refreshes connected resources and resumes durable continuation work. Respect
Retry-After and cancellation; only safe reads receive bounded retry. There is no
claim of push delivery while the app is stopped or recovery of content never
returned to this client by Graph.

Atomically retain each received page, exact message versions, source metadata and
checkpoint in encrypted PostgreSQL before advancing durable sync state. Permanent
Core archive observations preserve original HTML/text and rich metadata; attachment
bytes never enter PostgreSQL. Remote deletion, channel removal, disconnect and
cache eviction cannot purge received history. An empty/deleted provider body does
not erase an older received version. Stale pages cannot replace newer source state.
Search/export use stable indexed retained pages beyond the currently loaded UI.

## Sending and files

Persist a unique immutable attempt, destination, content and file references before
any remote mutation. PostgreSQL advisory ownership covers active attempts across
processes. A timeout/lost reply/ambiguous response survives restart as unknown and
blocks replay. A late completion may settle only its own live attempt. Explicit
resolution/copy-retry follows the existing service pattern; no generic auto-resend.

Attachments are an extension required by Makosh's migration plan, not a claimed
teams-cli upload feature. Use verified Graph OneDrive/SharePoint file resources,
then reference them from chatMessage. Initial Makosh guardrails are at most10 files
per submission and100MiB per file, streamed/bounded; these are application limits,
not a statement of Graph's limits. Preserve every file and recipient on recovery.

For chat uploads, use an explicitly selected OneDrive destination and disclose the
captured recipients before granting read access. Fully resolve the selected chat's
membership, recheck immediately before sharing, require sign-in, and do not create
anonymous/organization-wide links or send invitation emails. Changed/unresolved
membership or partial sharing results block publication for explicit resolution.
Channel uploads use that channel's verified filesFolder and inherited access.
Upload, permission grant and message publication each have their own durable
admission/receipt: a message failure cannot authorize upload or send replay, and no
cleanup removes user files or retained archive objects. Remote membership changes
during an in-flight grant are not atomically controlled by this client.

Read hosted content through its exact Graph resource. Resolve file references via
Graph drive items; never perform arbitrary URL fetching with a bearer token.
Service-issued preauthenticated download URLs use a separate credential-free
bounded transport; raw user content URLs cannot select its target. Preserve exact
resource/version metadata and fail visibly when the old remote file is unavailable.

Use encrypted private local preparation and the existing encrypted S3 repository.
S3 preference is per service/account/conversation: one-to-one chats default ON,
group/meeting chats and channels OFF. OFF prohibits every new S3 copy, including
preparation/retry/normalized files; old objects remain readable and local
preparations are never automatically promoted after enabling. Check policy before
admission and after suspensions; retain documented queued/in-flight PUT boundaries.
Native Quick Look/Save opens authenticated local leases. No executable HTML,
JavaScript, remote image fetch or network-capable HTML editor importer.

## Notifications and dossier

Use the single ApplicationSystemNotificationRouter with a separate Teams namespace
and opaque routes. Persist global/account/conversation show/preview/sound settings,
baseline first history, consume muted events and avoid replay after reconnect.
Callback-time account/local-read/privacy/OS-lock/window checks and asynchronous
permission revalidation match existing channels. One chat's settings cannot affect
another account/tenant. Synthetic events never report a real protocol connection.

Person-to-dossier links use existing atomic contact import contracts and preserve
tenant/account/user provenance. A team/channel/group is not a person. Never merge
users by display name/email alone or overwrite manual dossier observations. Leaving
Teams preserves dossier, archive and other services' settings and connections.

## Validation and acceptance

1. Offline scripted OAuth/Graph fixtures: PKCE/state/nonce/JWS rejection, fragmented
   callbacks, cancellation/late results, device pending/slowdown/expiry, refresh
   rotation/ownership, revoked scope, 401/403/429, URL/path/redirect containment,
   oversized/malformed pages, continuation cycles, extra returned records, replies
   paging, multi-account/tenant switching and stale-source ordering.
2. Real local PostgreSQL/S3 with synthetic keys/data: append-only versions after
   remote deletion, atomic page/checkpoint rollback, retained offline search/export,
   durable unknown attempts/restart/no-replay/live-owner exclusion, staged file and
   partial-sharing failures, S3 OFF/no-promotion, preference/notification isolation
   and provenance-preserving dossier links.
3. Isolated native QA only: explicit --teams-synthetic-preview and
   --database-config; both application/archive schemas must start with qa_teams_.
   Fake vault/Graph boundaries, no browser sign-in, personal Keychain or other
   accounts. Inspect the actual sidebar, chats/channels/replies/composer/files,
   outbox/settings/archive/dossier and two-account narrow/large-window flows.
4. Required scripts/dev-db.sh up, scripts/test.sh and scripts/build-app.sh;
   complete scoped tests and affected existing-channel regressions, ordinary/QA
   bundle verification, independent reference pin/notices verification and one
   fresh final review. Preserve the initial dirty baseline and raw failed checks.
5. Record actual outcomes and open questions in development-status/reference UI
   docs. Real Entra registration/tenant consent/linking, real Graph delivery/files,
   OS banner and supported-macOS acceptance remain explicitly unrun until the user
   resumes live QA with a selected account and actions. Local success does not
   stand for provider, release, notarization or clean-machine acceptance.

## Official contracts checked during design

- [Chat list](https://learn.microsoft.com/en-us/graph/api/chat-list?view=graph-rest-1.0): work/school delegated API; personal accounts unsupported.
- [Chat messages](https://learn.microsoft.com/en-us/graph/api/chat-list-messages?view=graph-rest-1.0): Chat.Read, paging and supported ordering/filter combinations.
- [Channel messages](https://learn.microsoft.com/en-us/graph/api/channel-list-messages?view=graph-rest-1.0): separate replies/continuations and ChannelMessage.Read.All.
- [Post chatMessage](https://learn.microsoft.com/en-us/graph/api/chatmessage-post?view=graph-rest-1.0): chat/channel/reply destinations and existing SharePoint file references.
- [Permissions](https://learn.microsoft.com/en-us/graph/permissions-reference#chatmessagesend): delegated ChatMessage.Send, ChannelMessage.Send and admin-consented channel history.
- [OAuth authorization code](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow), [device code](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code), [ID-token claims](https://learn.microsoft.com/en-us/entra/identity-platform/id-token-claims-reference): public-client flow and session/identity validation inputs.
- [Channel filesFolder](https://learn.microsoft.com/en-us/graph/api/channel-get-filesfolder?view=graph-rest-1.0), [file upload](https://learn.microsoft.com/en-us/graph/api/driveitem-put-content?view=graph-rest-1.0), [selected-recipient grants](https://learn.microsoft.com/en-us/graph/api/driveitem-invite?view=graph-rest-1.0): file transport and explicit access boundaries.
- [Chat members](https://learn.microsoft.com/en-us/graph/api/chat-list-members?view=graph-rest-1.0), [reply pages](https://learn.microsoft.com/en-us/graph/api/chatmessage-list-replies?view=graph-rest-1.0), [shared drive items](https://learn.microsoft.com/en-us/graph/api/shares-get?view=graph-rest-1.0): full roster, thread continuation and sharing-link lookup. The lookup-permission clarification above was found during planning and is explicit in the implementation plan for review; it never authorizes silent elevation or link redemption.

The next artifact is the implementation plan. Design approval does not claim a
Teams module, dependency build, authentication or UI acceptance.
