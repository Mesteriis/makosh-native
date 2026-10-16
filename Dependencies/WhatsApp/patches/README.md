# Reviewed whatsapp-rust 0.7.0 adaptation

`durable-history.patch` is applied only to an independently downloaded public
crate with the checksum in `Dependencies/WhatsApp.lock.json`. The preparation
recipe validates the patch hash, every changed output hash and every unchanged
published file. Registry caches and research checkouts are never edited.

The original SDK sends its HistorySync receipt before processing the chunk and
publishes history through detached callbacks. The patch adds a default awaited
`InboundDurabilityHook.on_history`, then moves the receipt behind a successful
consumer commit. Shutdown/failure suppresses the receipt and detached event.
Without a hook the original eager-receipt path is preserved.

Plaintext newsletter messages use the awaited message hook before their transport
ack and event. PDO recovered plaintext uses the hook before its detached event;
the facade also maps recovered messages from the outer durable PDO envelope, so
a failed fallback cannot authorize an envelope ack without retained content.
No session reset, extra network operation, logger or media download is added.

Status broadcasts now defer content acknowledgements behind the awaited message
hook. Inline ordering is preserved, and duplicates use the existing buffered
hook replay before acknowledgement. Empty/unknown/unrecoverable payloads keep
their terminal protocol handling; plaintext not received cannot be recovered.
Expiry does not prune Makosh's independent journal or PostgreSQL archive.
The production early-ack gate has a native executable regression; this is not
proof of server redelivery under every protocol/storage failure.

`test-whatsapp-adaptation.py` checks the real prepared SDK receipt/dispatch sites
(and fails on the original public source). Native tests separately exercise an
actual compressed protobuf history chunk, encrypted reopen, atomic rollback on
journal failure, names/unread state and newer/stale edit/delete order. These are
synthetic boundaries, not proof of server redelivery or real QR acceptance.

Outgoing VoIP offer-write cancellation now owns a guard for pending media and the
ack waiter. Its existing SDK AnswerTeardown field claims only the owned registry
generation and sends a terminal stanza after an ambiguous write. Successful setup
disarms this guard; generated SDK files are never edited by hand. Native facade
setup cancellation is separately covered with an awaited external-boundary fixture;
this is not live server or network-failure proof.

Group terminal callback ownership: the reviewed call handler copies its exact
registry transition generation into existing nonserialized IncomingCall metadata
before asynchronous dispatch. Makosh matches incoming group termination to that
witness; unscoped Elsewhere/Reject/Accept never own a group invocation. Outgoing
groups use the existing epoch-bound handle lifecycle. No package version, feature
graph, credentials or private key material is added.
