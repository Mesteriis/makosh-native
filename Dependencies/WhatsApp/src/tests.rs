use super::*;
use serde_json::json;
use std::os::unix::fs::PermissionsExt;

fn test_dir() -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!(
        "makosh-wa-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    std::fs::create_dir(&path).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
    path
}
static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
fn options(dir: &std::path::Path, key: u8) -> Vec<u8> {
    serde_json::to_vec(&json!({"version":1,"directory":dir,"key":vec![key;32]})).unwrap()
}
fn result(buffer: OwnedBuffer) -> serde_json::Value {
    assert!(!buffer.data.is_null());
    // SAFETY: these bytes are owned by this valid native reply until MkWAFree below.
    let value =
        serde_json::from_slice(unsafe { std::slice::from_raw_parts(buffer.data, buffer.len) })
            .unwrap();
    unsafe { MkWAFree(buffer) };
    value
}
fn open(dir: &std::path::Path, key: u8) -> serde_json::Value {
    let bytes = options(dir, key);
    result(unsafe { MkWAOpen(bytes.as_ptr(), bytes.len()) })
}
fn call(handle: u64, value: serde_json::Value) -> serde_json::Value {
    let bytes = serde_json::to_vec(&value).unwrap();
    result(unsafe { MkWACall(handle, bytes.as_ptr(), bytes.len()) })
}
#[test]
fn abi_rejects_bad_input_and_stale_handles() {
    assert_eq!(MkWAAbiVersion(), 1);
    assert_eq!(
        result(unsafe { MkWAOpen(std::ptr::null(), 1) })["error"],
        "input"
    );
    let bytes = b"{";
    assert_eq!(
        result(unsafe { MkWAOpen(bytes.as_ptr(), bytes.len()) })["error"],
        "input"
    );
    assert_eq!(
        result(unsafe { MkWAOpen(bytes.as_ptr(), MAX_INPUT + 1) })["error"],
        "input"
    );
    assert_eq!(
        call(u64::MAX, json!({"version":1,"command":"snapshot"}))["error"],
        "closed"
    );
}
#[test]
fn open_is_offline_exclusive_and_wrong_key_preserves_cache() {
    let dir = test_dir();
    let response = open(&dir, 7);
    assert_eq!(response["ok"], true, "{response}");
    let handle = response["data"]["handle"].as_u64().unwrap();
    assert_eq!(
        call(handle, json!({"version":1,"command":"snapshot"}))["data"]["state"],
        "offline"
    );
    assert_eq!(open(&dir, 7)["error"], "owned");
    assert_eq!(
        call(handle, json!({"version":2,"command":"snapshot"}))["error"],
        "version"
    );
    assert_eq!(
        call(handle, json!({"version":1,"command":"send"}))["error"],
        "command"
    );
    assert_eq!(result(MkWAClose(handle))["ok"], true);
    let before = std::fs::read(dir.join("session.db")).unwrap();
    assert!(!before.starts_with(b"SQLite format 3"));
    assert_eq!(open(&dir, 8)["ok"], false);
    assert_eq!(std::fs::read(dir.join("session.db")).unwrap(), before);
    let reopened = open(&dir, 7);
    assert_eq!(reopened["ok"], true, "{reopened}");
    assert_eq!(
        result(MkWAClose(reopened["data"]["handle"].as_u64().unwrap()))["ok"],
        true
    );
    assert_eq!(
        call(handle, json!({"version":1,"command":"snapshot"}))["error"],
        "closed"
    );
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn retained_versions_deletion_and_paging_survive_replay() {
    for history in [false, true] {
        use crate::cache::{Cache, Cursor};
        use crate::protocol::map_message;
        use whatsapp_rust::waproto::{buffa::MessageField, whatsapp as wa};
        let dir = test_dir();
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            let cache = Cache::open(dir.join("session.db").to_str().unwrap(), vec![7; 32])
                .await
                .unwrap();
            let original = wa::Message {
                conversation: Some("original".into()),
                ..Default::default()
            };
            let first = map_message(
                "group@g.us",
                "same-id",
                "alice@lid",
                false,
                10,
                &original,
                history,
            )
            .unwrap();
            cache
                .ingest(vec![first.clone(), first.clone()])
                .await
                .unwrap();
            // A second sender can reuse a stanza ID in the same group.
            let second = map_message(
                "group@g.us",
                "same-id",
                "bob@lid",
                false,
                10,
                &original,
                history,
            )
            .unwrap();
            cache.ingest(vec![second]).await.unwrap();
            let edit = wa::Message {
                protocol_message: MessageField::some(wa::message::ProtocolMessage {
                    r#type: Some(wa::message::protocol_message::Type::MessageEdit),
                    key: MessageField::some(wa::MessageKey {
                        id: Some("same-id".into()),
                        participant: Some("alice@lid".into()),
                        from_me: Some(false),
                        ..Default::default()
                    }),
                    edited_message: MessageField::some(wa::Message {
                        conversation: Some("edited".into()),
                        ..Default::default()
                    }),
                    ..Default::default()
                }),
                ..Default::default()
            };
            cache
                .ingest(vec![
                    map_message(
                        "group@g.us",
                        "edit-id",
                        "alice@lid",
                        false,
                        20,
                        &edit,
                        history,
                    )
                    .unwrap(),
                ])
                .await
                .unwrap();
            let delete = wa::Message {
                protocol_message: MessageField::some(wa::message::ProtocolMessage {
                    r#type: Some(wa::message::protocol_message::Type::Revoke),
                    key: MessageField::some(wa::MessageKey {
                        id: Some("same-id".into()),
                        participant: Some("alice@lid".into()),
                        from_me: Some(false),
                        ..Default::default()
                    }),
                    ..Default::default()
                }),
                ..Default::default()
            };
            cache
                .ingest(vec![
                    map_message(
                        "group@g.us",
                        "delete-id",
                        "alice@lid",
                        false,
                        30,
                        &delete,
                        history,
                    )
                    .unwrap(),
                ])
                .await
                .unwrap();
            cache.ingest(vec![first]).await.unwrap();
            let messages = cache.messages("group@g.us".into(), None, 1).await.unwrap();
            assert_eq!(messages.len(), 1);
            let cursor = Cursor {
                timestamp: messages[0].timestamp,
                id: messages[0].id.clone(),
            };
            let older = cache
                .messages("group@g.us".into(), Some(cursor), 1)
                .await
                .unwrap();
            assert_eq!(older.len(), 1);
            assert_ne!(messages[0].id, older[0].id);
            let all = cache.messages("group@g.us".into(), None, 50).await.unwrap();
            let alice = all.iter().find(|m| m.sender == "alice@lid").unwrap();
            assert!(alice.deleted);
            assert_eq!(alice.text, "edited");
            assert_eq!(alice.timestamp, 10);
            let journal = cache.journal(100).await.unwrap();
            assert_eq!(journal.len(), 4);
            assert_eq!(
                cache.journal(100).await.unwrap()[0].sequence,
                journal[0].sequence
            );
            cache.ack(journal[1].sequence).await.unwrap();
            assert_eq!(cache.journal(100).await.unwrap().len(), 2);
            drop(cache);
            let cache = Cache::open(dir.join("session.db").to_str().unwrap(), vec![7; 32])
                .await
                .unwrap();
            assert_eq!(cache.journal(100).await.unwrap().len(), 2);
            assert_eq!(
                cache
                    .messages("group@g.us".into(), None, 50)
                    .await
                    .unwrap()
                    .len(),
                2
            );
        });
        std::fs::remove_dir_all(dir).unwrap();
    }
}

#[test]
fn chat_cursor_uses_latest_timestamp_and_qr_expires() {
    use crate::{
        cache::Cache,
        protocol::{ConnectionStatus, map_message},
    };
    use whatsapp_rust::waproto::whatsapp as wa;
    let dir = test_dir();
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap();
    rt.block_on(async {
        let cache = Cache::open(dir.join("session.db").to_str().unwrap(), vec![7; 32])
            .await
            .unwrap();
        let body = wa::Message {
            conversation: Some("hello".into()),
            ..Default::default()
        };
        cache
            .ingest(vec![
                map_message("peer@lid", "one", "peer@lid", false, 10, &body, true).unwrap(),
                map_message("peer@lid", "two", "peer@lid", false, 20, &body, false).unwrap(),
            ])
            .await
            .unwrap();
        assert_eq!(cache.chats(None, 50).await.unwrap()[0].timestamp, 20);
        assert_eq!(cache.chats(None, 50).await.unwrap()[0].unread, 1);
    });
    let mut status = ConnectionStatus::default();
    status.set("qr");
    status.qr = "not-a-real-code".into();
    status.expires = 1;
    status.expire();
    assert_eq!(status.state, "expired");
    assert!(status.qr.is_empty());
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn journal_export_is_bounded_without_skipping_records() {
    use crate::cache::{JournalEntry, Message};
    let rows = (1..=100)
        .map(|sequence| JournalEntry {
            sequence,
            message: Message {
                chat: "peer@lid".into(),
                id: sequence.to_string(),
                stanza: sequence.to_string(),
                sender: "peer@lid".into(),
                timestamp: 10,
                outgoing: false,
                text: "x".repeat(100_000),
                kind: "text".into(),
                edited: false,
                deleted: false,
                version_timestamp: 10_000,
                delivery: Some(0),
                details: None,
            },
            history: false,
            observed: 100,
            notify: None,
        })
        .collect();
    let batch = crate::session::bounded_journal(rows).unwrap();
    assert!(!batch.is_empty());
    assert!(batch.len() < 100);
    assert!(serde_json::to_vec(&batch).unwrap().len() < 7 * 1024 * 1024);
    for (index, row) in batch.iter().enumerate() {
        assert_eq!(row.sequence, index as i64 + 1);
    }
}

// A stored-block zlib fixture needs no additional production/test dependency.
fn compressed_fixture(bytes: &[u8]) -> Vec<u8> {
    assert!(bytes.len() < 65536);
    let len = bytes.len() as u16;
    let mut out = vec![0x78, 0x01, 0x01];
    out.extend_from_slice(&len.to_le_bytes());
    out.extend_from_slice(&(!len).to_le_bytes());
    out.extend_from_slice(bytes);
    let (mut a, mut b) = (1u32, 0u32);
    for byte in bytes {
        a = (a + u32::from(*byte)) % 65521;
        b = (b + a) % 65521;
    }
    out.extend_from_slice(&((b << 16) | a).to_be_bytes());
    out
}

#[test]
fn raw_media_versions_with_equal_caption_are_retained() {
    use crate::{cache::Cache, protocol::map_message};
    use whatsapp_rust::waproto::{buffa::MessageField, whatsapp as wa};
    let dir = test_dir();
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap();
    rt.block_on(async {
        let cache = Cache::open(dir.join("session.db").to_str().unwrap(), vec![7; 32])
            .await
            .unwrap();
        for url in ["synthetic://one", "synthetic://two", "synthetic://two"] {
            let body = wa::Message {
                image_message: MessageField::some(wa::message::ImageMessage {
                    url: Some(url.into()),
                    caption: Some("same caption".into()),
                    ..Default::default()
                }),
                ..Default::default()
            };
            cache
                .ingest(vec![
                    map_message("peer@lid", "same", "peer@lid", false, 10, &body, false).unwrap(),
                ])
                .await
                .unwrap();
        }
        assert_eq!(
            cache.journal(50).await.unwrap().len(),
            2,
            "Raw resource changes are versions, exact replay is a duplicate"
        );
        assert_eq!(cache.chats(None, 50).await.unwrap()[0].unread, 1);
    });
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn history_commit_is_atomic_and_metadata_survives_reopen() {
    use crate::{cache::Cache, protocol::persist_history};
    use whatsapp_rust::{
        types::events::LazyHistorySync,
        waproto::{
            buffa::{Message as _, MessageField},
            whatsapp as wa,
        },
    };
    let dir = test_dir();
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap();
    rt.block_on(async {
        let history = wa::HistorySync {
            conversations: vec![wa::Conversation {
                id: "peer@lid".into(),
                unread_count: Some(3),
                archived: Some(true),
                pinned: Some(1),
                conversation_timestamp: Some(10),
                messages: vec![wa::HistorySyncMsg {
                    message: MessageField::some(wa::WebMessageInfo {
                        key: MessageField::some(wa::MessageKey {
                            remote_jid: Some("peer@lid".into()),
                            id: Some("history-one".into()),
                            from_me: Some(false),
                            ..Default::default()
                        }),
                        message: MessageField::some(wa::Message {
                            conversation: Some("durable history".into()),
                            ..Default::default()
                        }),
                        message_timestamp: Some(10),
                        ..Default::default()
                    }),
                    ..Default::default()
                }],
                ..Default::default()
            }],
            pushnames: vec![wa::Pushname {
                id: Some("peer@lid".into()),
                pushname: Some("Test peer".into()),
            }],
            ..Default::default()
        };
        let bytes = history.encode_to_vec();
        let lazy = LazyHistorySync::new(
            compressed_fixture(&bytes).into(),
            bytes.len(),
            0,
            None,
            None,
        );
        let path = dir.join("history.db");
        let cache = Cache::open(path.to_str().unwrap(), vec![7; 32])
            .await
            .unwrap();
        persist_history(&cache, &lazy).await.unwrap();
        assert_eq!(cache.journal(50).await.unwrap().len(), 1);
        drop(cache);
        let cache = Cache::open(path.to_str().unwrap(), vec![7; 32])
            .await
            .unwrap();
        let chat = cache.chats(None, 50).await.unwrap().remove(0);
        assert_eq!(chat.name, "Test peer");
        assert_eq!(chat.unread, 3);
        assert!(chat.archived && chat.pinned);
        let control = crate::protocol::map_message(
            "control@lid",
            "control",
            "",
            true,
            30,
            &wa::Message {
                protocol_message: MessageField::some(wa::message::ProtocolMessage::default()),
                ..Default::default()
            },
            false,
        )
        .unwrap();
        cache.ingest(vec![control]).await.unwrap();
        assert_eq!(
            cache.chats(None, 50).await.unwrap().len(),
            1,
            "Internal protocol traffic is retained without a phantom chat"
        );
        let mut live = crate::protocol::map_message(
            "peer@lid",
            "live",
            "peer@lid",
            false,
            20,
            &wa::Message {
                conversation: Some("live".into()),
                ..Default::default()
            },
            false,
        )
        .unwrap();
        live.push_name = Some("Renamed test peer".into());
        cache.ingest(vec![live.clone(), live]).await.unwrap();
        persist_history(&cache, &lazy).await.unwrap();
        let chat = cache.chats(None, 50).await.unwrap().remove(0);
        assert_eq!(chat.unread, 4);
        assert_eq!(chat.name, "Renamed test peer");
        assert_eq!(chat.timestamp, 20);
        assert!(chat.archived && chat.pinned);
        // A failing chunk rolls back its chat, names and every journal row.
        let failed = Cache::open(dir.join("failed.db").to_str().unwrap(), vec![8; 32])
            .await
            .unwrap();
        failed.reject_new_journal_rows().await;
        assert!(persist_history(&failed, &lazy).await.is_err());
        assert!(failed.chats(None, 50).await.unwrap().is_empty());
        assert!(failed.journal(50).await.unwrap().is_empty());
        let corrupt = LazyHistorySync::new(vec![1, 2, 3].into(), 3, 0, None, None);
        assert!(persist_history(&cache, &corrupt).await.is_err());
    });
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn command_admission_is_durable_and_cannot_replay_an_unknown_attempt() {
    let dir = test_dir();
    let runtime = tokio::runtime::Runtime::new().unwrap();
    runtime.block_on(async {
        let cache =
            crate::cache::Cache::open(dir.join("commands.db").to_str().unwrap(), vec![81; 32])
                .await
                .unwrap();
        assert_eq!(
            cache.admit_command("attempt-1", "digest-a").await.unwrap(),
            None
        );
        assert_eq!(
            cache
                .admit_command("attempt-1", "digest-a")
                .await
                .unwrap_err(),
            "unknown"
        );
        assert_eq!(
            cache
                .admit_command("attempt-1", "digest-b")
                .await
                .unwrap_err(),
            "attempt"
        );
        cache
            .finish_command("attempt-1", &json!({"stanza":"fixed-stanza"}))
            .await
            .unwrap();
        assert_eq!(
            cache.admit_command("attempt-1", "digest-a").await.unwrap(),
            Some(json!({"stanza":"fixed-stanza"}))
        );
    });
    std::fs::remove_dir_all(dir).unwrap();
}
#[test]
fn known_mutations_fail_offline_without_opening_the_network() {
    let dir = test_dir();
    let opened = open(&dir, 82);
    let handle = opened["data"]["handle"].as_u64().unwrap();
    let response = call(
        handle,
        json!({"version":1,"command":"perform","chat":"123@lid","action":{"op":"text","attempt":"00112233-4455-6677-8899-aabbccddeeff","text":"hello","mentions":[]}}),
    );
    assert_eq!(response["error"], "offline", "{response}");
    let rejected = call(
        handle,
        json!({"version":1,"command":"perform","chat":"123@lid","action":{"op":"text","attempt":"invalid","text":"","mentions":[]}}),
    );
    assert_eq!(rejected["error"], "input", "{rejected}");
    assert_eq!(
        call(handle, json!({"version":1,"command":"snapshot"}))["data"]["state"],
        "offline"
    );
    result(MkWAClose(handle));
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn media_metadata_quotes_and_receipts_are_retained_without_regression() {
    use whatsapp_rust::waproto::{buffa::MessageField, whatsapp as wa};
    let dir = test_dir();
    let runtime = tokio::runtime::Runtime::new().unwrap();
    runtime.block_on(async {
        let cache = crate::cache::Cache::open(dir.join("rich.db").to_str().unwrap(), vec![83; 32])
            .await
            .unwrap();
        let body = wa::Message {
            document_message: MessageField::some(wa::message::DocumentMessage {
                file_name: Some("report.pdf".into()),
                mimetype: Some("application/pdf".into()),
                file_length: Some(1234),
                caption: Some("caption".into()),
                context_info: MessageField::some(wa::ContextInfo {
                    stanza_id: Some("quoted".into()),
                    participant: Some("peer@lid".into()),
                    quoted_message: MessageField::some(wa::Message {
                        conversation: Some("original quote".into()),
                        ..Default::default()
                    }),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        };
        let observation =
            crate::protocol::map_message("peer@lid", "outgoing", "", true, 10, &body, false)
                .unwrap();
        let id = observation.message.id.clone();
        cache.ingest(vec![observation]).await.unwrap();
        cache
            .receipt("peer@lid", &["outgoing".into()], "peer@lid", 3, 20)
            .await
            .unwrap();
        cache
            .receipt("peer@lid", &["outgoing".into()], "peer@lid", 2, 21)
            .await
            .unwrap();
        let (message, _) = cache.stored_message("peer@lid", &id).await.unwrap();
        assert_eq!(message.delivery, Some(3));
        let details = message.details.unwrap();
        assert_eq!(details.name.as_deref(), Some("report.pdf"));
        assert_eq!(details.size, Some(1234));
        assert_eq!(details.quoted_text.as_deref(), Some("original quote"));
        let journal = cache.journal(100).await.unwrap();
        assert_eq!(
            journal.len(),
            2,
            "A lower receipt never makes a new content regression"
        );
    });
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn media_handoff_rejects_symlinks_public_files_and_large_payloads() {
    use std::os::unix::{
        fs::{PermissionsExt, symlink},
        prelude::OpenOptionsExt,
    };
    let dir = test_dir();
    let path = dir.join("file");
    std::fs::write(&path, b"synthetic media").unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(
        crate::media::read_private(path.to_str().unwrap()).unwrap(),
        b"synthetic media"
    );
    symlink(&path, dir.join("link")).unwrap();
    assert!(crate::media::read_private(dir.join("link").to_str().unwrap()).is_err());
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(crate::media::read_private(path.to_str().unwrap()).is_err());
    let large = dir.join("large");
    let f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&large)
        .unwrap();
    f.set_len(101 * 1024 * 1024).unwrap();
    assert!(crate::media::read_private(large.to_str().unwrap()).is_err());
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn pending_jobs_do_not_block_cache_and_shutdown_awaits_cancellation() {
    let dir = test_dir();
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        let cache = crate::cache::Cache::open(dir.join("jobs.db").to_str().unwrap(), vec![84; 32])
            .await
            .unwrap();
        cache.admit_command("job-1", "digest").await.unwrap();
        let (_send, receive) = tokio::sync::oneshot::channel::<()>();
        let mut jobs = crate::jobs::CommandJobs::default();
        jobs.start(cache.clone(), "job-1".into(), async move {
            let _ = receive.await;
            Ok(json!({"stanza":"late"}))
        })
        .unwrap();
        assert!(cache.chats(None, 50).await.unwrap().is_empty());
        assert_eq!(
            cache.command_result("job-1").await.unwrap(),
            json!({"pending":true})
        );
        jobs.shutdown().await;
        assert_eq!(
            cache.command_result("job-1").await.unwrap(),
            json!({"pending":true}),
            "Aborted work never fabricates a successful receipt"
        );
    });
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn old_journal_keeps_missing_fields_so_existing_receipts_remain_valid() {
    use diesel::{
        prelude::*,
        sql_types::{Binary, Text},
    };
    let dir = test_dir();
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async{
        let cache=crate::cache::Cache::open(dir.join("legacy.db").to_str().unwrap(),vec![85;32]).await.unwrap();
        cache.shared.run(|conn|diesel::sql_query("INSERT INTO mk_journal(token,payload,raw) VALUES('legacy',?1,?2)").bind::<Text,_>(r#"{"message":{"chat":"peer@lid","id":"one","stanza":"one","sender":"peer@lid","timestamp":10,"outgoing":false,"text":"legacy","kind":"text","edited":false,"deleted":false,"versionTimestamp":10000},"history":false,"observed":100}"#).bind::<Binary,_>(Vec::<u8>::new()).execute(conn).map_err(|e|whatsapp_rust::wacore::store::error::StoreError::Database(Box::new(e)))).await.unwrap();
        let rows=cache.journal(100).await.unwrap();let value=serde_json::to_value(&rows[0]).unwrap();
        assert!(value["message"]["delivery"].is_null(),"A new default cannot rebind a previously transferred observation");
        assert!(value["notify"].is_null());
        assert_eq!(value["message"]["text"],"legacy");
    });
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn server_chat_rules_survive_late_history_and_encrypted_reopen() {
    use crate::chat_rules::ChatUpdate;
    use whatsapp_rust::waproto::whatsapp as wa;
    let dir = test_dir();
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        let cache = crate::cache::Cache::open(dir.join("rules.db").to_str().unwrap(), vec![86; 32])
            .await
            .unwrap();
        let row = crate::protocol::map_message(
            "peer@lid",
            "first",
            "peer@lid",
            false,
            10,
            &wa::Message {
                conversation: Some("hello".into()),
                ..Default::default()
            },
            false,
        )
        .unwrap();
        cache.ingest(vec![row]).await.unwrap();
        let old = cache.chats(None, 50).await.unwrap();
        cache
            .chat_update_at("peer@lid", ChatUpdate::Mute(-1), Some(100))
            .await
            .unwrap();
        cache
            .chat_update_at("peer@lid", ChatUpdate::Mute(0), Some(50))
            .await
            .unwrap();
        cache
            .chat_update("peer@lid", ChatUpdate::Archive(true))
            .await
            .unwrap();
        cache
            .chat_update("peer@lid", ChatUpdate::Read)
            .await
            .unwrap();
        cache
            .ingest_history(Vec::new(), old, Vec::new())
            .await
            .unwrap();
        let chat = cache.chats(None, 50).await.unwrap().remove(0);
        assert_eq!(chat.muted_until, Some(-1));
        assert!(chat.archived);
        assert_eq!(chat.unread, 0);
    });
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn media_reply_context_and_forward_mark_are_encoded_in_the_actual_protobuf() {
    use whatsapp_rust::waproto::{buffa::MessageField, whatsapp as wa};
    let image = wa::Message {
        image_message: MessageField::some(wa::message::ImageMessage {
            caption: Some("caption".into()),
            ..Default::default()
        }),
        ..Default::default()
    };
    let context = wa::ContextInfo {
        stanza_id: Some("quoted-stanza".into()),
        participant: Some("peer@lid".into()),
        ..Default::default()
    };
    let quoted = crate::commands::with_context(image, context).unwrap();
    assert_eq!(
        quoted.image_message.context_info.stanza_id.as_deref(),
        Some("quoted-stanza")
    );
    let forwarded = crate::commands::with_context(
        quoted,
        wa::ContextInfo {
            is_forwarded: Some(true),
            forwarding_score: Some(1),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(
        forwarded.image_message.context_info.is_forwarded,
        Some(true)
    );
    assert_eq!(forwarded.image_message.caption.as_deref(), Some("caption"));
    assert!(
        !forwarded.image_message.context_info.stanza_id.is_some(),
        "A forward replaces source-chat quote context"
    );
}

#[test]
fn settings_groups_and_rich_send_commands_are_validated_before_network_admission() {
    let dir = test_dir();
    let opened = open(&dir, 87);
    let handle = opened["data"]["handle"].as_u64().unwrap();
    for action in [
        json!({"op":"block","on":true}),
        json!({"op":"group_info"}),
        json!({"op":"profile"}),
        json!({"op":"privacy"}),
        json!({"op":"location","latitude":55.75,"longitude":37.61}),
        json!({"op":"contact","text":"Test","to":"123456789@s.whatsapp.net"}),
        json!({"op":"poll","text":"Question","options":["A","B"]}),
    ] {
        let mut action = action;
        action["attempt"] = json!("00112233-4455-6677-8899-aabbccddeeff");
        let response = call(
            handle,
            json!({"version":1,"command":"perform","chat":"123@lid","action":action}),
        );
        assert_eq!(response["error"], "offline", "{response}");
    }
    let invalid = call(
        handle,
        json!({"version":1,"command":"perform","chat":"123@lid","action":{"op":"location","attempt":"00112233-4455-6677-8899-aabbccddeeff","latitude":1000,"longitude":37.61}}),
    );
    assert_eq!(invalid["error"], "input");
    result(MkWAClose(handle));
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn created_poll_has_the_secret_and_exact_options_needed_for_later_votes() {
    let secret = [9u8; 32];
    let body = crate::polls::creation("Question", &["A".into(), "B".into()], &secret).unwrap();
    assert_eq!(
        body.poll_creation_message_v3.name.as_deref(),
        Some("Question")
    );
    assert_eq!(
        body.poll_creation_message_v3.selectable_options_count,
        Some(1)
    );
    assert_eq!(
        body.poll_creation_message_v3
            .options
            .iter()
            .map(|o| o.option_name.as_deref())
            .collect::<Vec<_>>(),
        vec![Some("A"), Some("B")]
    );
    assert_eq!(
        body.message_context_info
            .message_secret
            .as_ref()
            .unwrap()
            .as_slice(),
        secret.as_slice()
    );
    assert!(crate::polls::creation("Question", &["A".into(), "A".into()], &secret).is_err());
}

#[test]
fn completed_cache_mutation_advances_the_snapshot_revision() {
    let dir = test_dir();
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        let cache =
            crate::cache::Cache::open(dir.join("revision.db").to_str().unwrap(), vec![88; 32])
                .await
                .unwrap();
        let initial = cache.revision();
        cache
            .chat_update("peer@lid", crate::chat_rules::ChatUpdate::Archive(true))
            .await
            .unwrap();
        assert!(
            cache.revision() > initial,
            "A command completion must be observable without waiting for an unrelated server event"
        );
    });
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn deleted_media_keeps_its_usable_resource_body_for_preview_and_quotes() {
    use whatsapp_rust::waproto::{
        buffa::{Message as _, MessageField},
        whatsapp as wa,
    };
    let dir = test_dir();
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        let cache =
            crate::cache::Cache::open(dir.join("deleted-media.db").to_str().unwrap(), vec![89; 32])
                .await
                .unwrap();
        let body = wa::Message {
            image_message: MessageField::some(wa::message::ImageMessage {
                caption: Some("retained caption".into()),
                direct_path: Some("/synthetic-resource".into()),
                media_key: Some(vec![1; 32]),
                ..Default::default()
            }),
            ..Default::default()
        };
        let first = crate::protocol::map_message(
            "peer@lid", "original", "peer@lid", false, 10, &body, false,
        )
        .unwrap();
        let id = first.message.id.clone();
        let resource = first.message.details.as_ref().unwrap().resource_id.clone();
        cache.ingest(vec![first]).await.unwrap();
        let edit = wa::Message {
            protocol_message: MessageField::some(wa::message::ProtocolMessage {
                r#type: Some(wa::message::protocol_message::Type::MessageEdit),
                key: MessageField::some(wa::MessageKey {
                    id: Some("original".into()),
                    remote_jid: Some("peer@lid".into()),
                    from_me: Some(false),
                    ..Default::default()
                }),
                edited_message: MessageField::some(wa::Message {
                    conversation: Some("new caption".into()),
                    ..Default::default()
                }),
                timestamp_ms: Some(15000),
                ..Default::default()
            }),
            ..Default::default()
        };
        cache
            .ingest(vec![
                crate::protocol::map_message(
                    "peer@lid", "edit", "peer@lid", false, 15, &edit, false,
                )
                .unwrap(),
            ])
            .await
            .unwrap();
        let deleted = wa::Message {
            protocol_message: MessageField::some(wa::message::ProtocolMessage {
                r#type: Some(wa::message::protocol_message::Type::Revoke),
                key: MessageField::some(wa::MessageKey {
                    id: Some("original".into()),
                    remote_jid: Some("peer@lid".into()),
                    from_me: Some(false),
                    ..Default::default()
                }),
                timestamp_ms: Some(20000),
                ..Default::default()
            }),
            ..Default::default()
        };
        cache
            .ingest(vec![
                crate::protocol::map_message(
                    "peer@lid", "revoke", "peer@lid", false, 20, &deleted, false,
                )
                .unwrap(),
            ])
            .await
            .unwrap();
        let (current, raw) = cache.stored_message("peer@lid", &id).await.unwrap();
        assert!(current.deleted);
        assert_eq!(current.details.as_ref().unwrap().resource_id, resource);
        assert_eq!(current.text, "new caption");
        let retained = wa::Message::decode_from_slice(&raw).unwrap();
        assert_eq!(
            retained.image_message.caption.as_deref(),
            Some("new caption")
        );
        assert_eq!(
            retained.image_message.direct_path.as_deref(),
            Some("/synthetic-resource")
        );
    });
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn reactions_target_retained_message_and_preserve_newest_actor_value() {
    use whatsapp_rust::waproto::{buffa::MessageField, whatsapp as wa};
    let dir = test_dir();
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        let cache =
            crate::cache::Cache::open(dir.join("controls.db").to_str().unwrap(), vec![92; 32])
                .await
                .unwrap();
        let reaction = |id: &str, text: &str, ms: i64| {
            crate::protocol::map_message(
                "group@g.us",
                id,
                "actor@lid",
                false,
                ms / 1000,
                &wa::Message {
                    reaction_message: MessageField::some(wa::message::ReactionMessage {
                        key: MessageField::some(wa::MessageKey {
                            id: Some("original".into()),
                            participant: Some("peer@lid".into()),
                            from_me: Some(false),
                            ..Default::default()
                        }),
                        text: Some(text.into()),
                        sender_timestamp_ms: Some(ms),
                        ..Default::default()
                    }),
                    ..Default::default()
                },
                false,
            )
            .unwrap()
        };
        cache
            .ingest(vec![reaction("r1", "👍", 20000)])
            .await
            .unwrap();
        cache
            .ingest(vec![
                crate::protocol::map_message(
                    "group@g.us",
                    "original",
                    "peer@lid",
                    false,
                    10,
                    &wa::Message {
                        conversation: Some("body".into()),
                        ..Default::default()
                    },
                    false,
                )
                .unwrap(),
            ])
            .await
            .unwrap();
        cache
            .ingest(vec![reaction("r0", "old", 15000)])
            .await
            .unwrap();
        let rows = cache.messages("group@g.us".into(), None, 50).await.unwrap();
        assert_eq!(rows.len(), 1);
        let value = serde_json::to_value(&rows[0]).unwrap();
        assert_eq!(value["details"]["reactions"][0]["text"], "👍");
        cache.ingest(vec![reaction("r2", "", 21000)]).await.unwrap();
        let rows = cache.messages("group@g.us".into(), None, 50).await.unwrap();
        let value = serde_json::to_value(&rows[0]).unwrap();
        assert_eq!(value["details"]["reactions"], serde_json::json!([]));
    });
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn media_resource_identity_excludes_caption_and_quote_changes() {
    use whatsapp_rust::waproto::{buffa::MessageField, whatsapp as wa};
    let mut body = wa::Message {
        image_message: MessageField::some(wa::message::ImageMessage {
            caption: Some("a".into()),
            direct_path: Some("/resource".into()),
            media_key: Some(vec![3; 32]),
            ..Default::default()
        }),
        ..Default::default()
    };
    let first = crate::presentation::details(&body).resource_id;
    body.image_message.as_option_mut().unwrap().caption = Some("b".into());
    assert_eq!(first, crate::presentation::details(&body).resource_id);
    body.image_message.as_option_mut().unwrap().media_key = Some(vec![4; 32]);
    assert_ne!(first, crate::presentation::details(&body).resource_id);
}

#[test]
fn status_transport_ack_is_deferred_for_the_durable_hook() {
    assert!(!whatsapp_rust::inbound_early_ack_allowed(true, false, true));
    assert!(!whatsapp_rust::inbound_early_ack_allowed(true, true, false));
    assert!(whatsapp_rust::inbound_early_ack_allowed(false, false, true));
    assert!(whatsapp_rust::inbound_early_ack_allowed(false, true, false));
    assert!(!whatsapp_rust::inbound_early_ack_allowed(
        false, false, false
    ));
}

#[test]
fn call_media_queues_are_bounded_and_reject_another_generation() {
    let queues = crate::calls::MediaQueues::new("call".into(), 7);
    let request = crate::calls::Exchange {
        id: "call".into(),
        epoch: 7,
        audio: vec![vec![1; 960]; 3],
        video: vec![0; 64],
        ..Default::default()
    };
    for _ in 0..40 {
        queues.exchange(&request).unwrap();
    }
    assert!(queues.mic_len() <= 3);
    assert!(queues.camera_len() <= 4);
    let stale = crate::calls::Exchange {
        epoch: 6,
        ..request
    };
    assert!(queues.exchange(&stale).is_err());
    let oversized = crate::calls::Exchange {
        id: "call".into(),
        epoch: 7,
        audio: vec![vec![0; 961]],
        video: vec![],
        ..Default::default()
    };
    assert!(queues.exchange(&oversized).is_err());
}

#[test]
fn end_revokes_call_admission_before_the_async_start_job_runs() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        let calls = crate::calls::Calls::default();
        let start = serde_json::from_value::<crate::commands::Action>(
            serde_json::json!({"op":"call_start","attempt":"00000000-0000-4000-8000-000000000123"}),
        )
        .unwrap();
        let epoch = calls.admit("peer@lid", &start).await.unwrap();
        assert!(calls.is_current(epoch).await);
        let end = serde_json::from_value::<crate::commands::Action>(
            serde_json::json!({"op":"call_end","attempt":"00000000-0000-4000-8000-000000000124"}),
        )
        .unwrap();
        calls.admit("peer@lid", &end).await.unwrap();
        assert!(!calls.is_current(epoch).await);
    });
}

#[test]
fn call_controls_have_reserved_capacity_when_media_jobs_are_busy() {
    let dir = test_dir();
    tokio::runtime::Runtime::new().unwrap().block_on(async {
        let cache =
            crate::cache::Cache::open(dir.join("call-priority.db").to_str().unwrap(), vec![95; 32])
                .await
                .unwrap();
        let mut jobs = crate::jobs::CommandJobs::default();
        for n in 0..2 {
            jobs.start(cache.clone(), format!("media-{n}"), std::future::pending())
                .unwrap();
        }
        assert!(!jobs.has_capacity(false));
        assert!(jobs.has_capacity(true));
        jobs.start_control(cache, "call-end".into(), std::future::pending())
            .unwrap();
        jobs.shutdown().await;
    });
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn call_codec_uses_the_independently_reviewed_native_opus_version() {
    assert!(
        crate::calls::codec_version()
            .unwrap()
            .contains("libopus 1.6.1")
    );
}

#[test]
fn termination_keeps_capacity_when_all_control_jobs_are_busy() {
    tokio::runtime::Runtime::new().unwrap().block_on(async {
        let dir = test_dir();
        let cache =
            crate::cache::Cache::open(dir.join("terminate.db").to_str().unwrap(), vec![96; 32])
                .await
                .unwrap();
        let mut jobs = crate::jobs::CommandJobs::default();
        for n in 0..2 {
            jobs.start_control(
                cache.clone(),
                format!("control-{n}"),
                std::future::pending(),
            )
            .unwrap();
        }
        assert!(jobs.can_admit("call_end"));
        assert!(jobs.can_admit("call_reject"));
        assert!(!jobs.can_admit("call_start"));
        jobs.shutdown().await;
    });
}
#[test]
fn foreign_opus_is_not_interleaved_with_duplicate_mlow_silence() {
    let queues = crate::calls::MediaQueues::new("call".into(), 7);
    queues.receive_foreign(vec![42; 960]);
    queues.receive_decoded(vec![0; 960]);
    let reply = queues
        .exchange(&crate::calls::Exchange {
            id: "call".into(),
            epoch: 7,
            audio: vec![],
            video: vec![],
            ..Default::default()
        })
        .unwrap();
    assert_eq!(reply["audio"].as_array().unwrap().len(), 1);
    assert_eq!(reply["audio"][0][0], 42);
}

#[test]
fn encrypted_poll_vote_is_retained_and_replaced_per_actor() {
    use sha2::{Digest, Sha256};
    use whatsapp_rust::{
        wacore::poll,
        waproto::{buffa::MessageField, whatsapp as wa},
    };
    let dir = test_dir();
    tokio::runtime::Runtime::new().unwrap().block_on(async {
        let cache =
            crate::cache::Cache::open(dir.join("poll-votes.db").to_str().unwrap(), vec![97; 32])
                .await
                .unwrap();
        let secret = vec![11; 32];
        let body =
            crate::polls::creation("Question", &["One".into(), "Two".into()], &secret).unwrap();
        let pollrow =
            crate::protocol::map_message("peer@lid", "poll", "peer@lid", false, 1, &body, true)
                .unwrap();
        let id = pollrow.message.id.clone();
        cache.ingest(vec![pollrow]).await.unwrap();
        for (stamp, choice) in [(20, "One"), (30, "Two"), (25, "One")] {
            let (enc, iv) = poll::encrypt_poll_vote_with_secret(
                &[Sha256::digest(choice.as_bytes()).to_vec()],
                &secret,
                "poll",
                "peer@lid",
                "voter@lid",
            )
            .unwrap();
            let vote = wa::Message {
                poll_update_message: MessageField::some(wa::message::PollUpdateMessage {
                    poll_creation_message_key: MessageField::some(wa::MessageKey {
                        remote_jid: Some("peer@lid".into()),
                        id: Some("poll".into()),
                        from_me: Some(false),
                        ..Default::default()
                    }),
                    vote: MessageField::some(wa::message::PollEncValue {
                        enc_payload: Some(enc),
                        enc_iv: Some(iv.to_vec()),
                    }),
                    sender_timestamp_ms: Some(stamp),
                    ..Default::default()
                }),
                ..Default::default()
            };
            cache
                .ingest(vec![
                    crate::protocol::map_message(
                        "peer@lid",
                        &format!("vote-{stamp}"),
                        "voter@lid",
                        false,
                        stamp,
                        &vote,
                        false,
                    )
                    .unwrap(),
                ])
                .await
                .unwrap();
        }
        let rows = cache.messages("peer@lid".into(), None, 100).await.unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].id, id);
        let votes = rows[0]
            .details
            .as_ref()
            .unwrap()
            .poll_votes
            .as_ref()
            .unwrap();
        assert_eq!(votes.len(), 1);
        assert_eq!(votes[0].options, vec!["Two"]);
    });
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn protected_view_once_wrapper_survives_presentation_unwrap() {
    use whatsapp_rust::prelude::*;
    use whatsapp_rust::waproto::{buffa::MessageField, whatsapp as wa};
    let body = wa::Message {
        view_once_message_v2: MessageField::some(wa::message::FutureProofMessage {
            message: MessageField::some(wa::Message::text("private view-once caption")),
        }),
        ..Default::default()
    };
    assert_eq!(crate::presentation::details(&body).protected, Some(true));
}

#[test]
fn historical_resource_lookup_does_not_download_a_newer_replacement() {
    use whatsapp_rust::waproto::{
        buffa::{Message as _, MessageField},
        whatsapp as wa,
    };
    let dir = test_dir();
    tokio::runtime::Runtime::new().unwrap().block_on(async {
        let cache = crate::cache::Cache::open(
            dir.join("historical-file.db").to_str().unwrap(),
            vec![98; 32],
        )
        .await
        .unwrap();
        let mut old_resource = String::new();
        let mut id = String::new();
        for n in 1..=2 {
            let body = wa::Message {
                image_message: MessageField::some(wa::message::ImageMessage {
                    media_key: Some(vec![n as u8; 32]),
                    direct_path: Some(format!("/resource-{n}")),
                    ..Default::default()
                }),
                ..Default::default()
            };
            let row = crate::protocol::map_message(
                "peer@lid", "photo", "peer@lid", false, n, &body, true,
            )
            .unwrap();
            if n == 1 {
                old_resource = row
                    .message
                    .details
                    .as_ref()
                    .unwrap()
                    .resource_id
                    .clone()
                    .unwrap();
                id = row.message.id.clone()
            };
            cache.ingest(vec![row]).await.unwrap();
        }
        let (_, raw) = cache
            .stored_resource("peer@lid", &id, Some(&old_resource))
            .await
            .unwrap();
        let body = wa::Message::decode_from_slice(&raw).unwrap();
        assert_eq!(
            body.image_message.direct_path.as_deref(),
            Some("/resource-1")
        );
    });
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn ending_a_call_cancels_owned_setup_before_it_can_send_a_late_offer() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        let calls = std::sync::Arc::new(crate::calls::Calls::default());
        let start = serde_json::from_value::<crate::commands::Action>(
            json!({"op":"call_start","attempt":"00000000-0000-4000-8000-000000000133"}),
        )
        .unwrap();
        let epoch = calls.admit("peer@lid", &start).await.unwrap();
        let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
        let worker = calls.clone();
        let setup = tokio::spawn(async move {
            worker
                .during(epoch, async move {
                    let _ = ready_tx.send(());
                    std::future::pending::<Result<(), &'static str>>().await
                })
                .await
        });
        ready_rx.await.unwrap();
        let end = serde_json::from_value::<crate::commands::Action>(
            json!({"op":"call_end","attempt":"00000000-0000-4000-8000-000000000134"}),
        )
        .unwrap();
        calls.admit("peer@lid", &end).await.unwrap();
        let result = tokio::time::timeout(std::time::Duration::from_millis(300), setup)
            .await
            .expect("Owned setup must stop without waiting for network")
            .unwrap();
        assert_eq!(result, Err("closed"));
    });
}

#[test]
fn early_receipt_survives_reopen_and_decorates_later_message() {
    let dir = test_dir();
    tokio::runtime::Runtime::new().unwrap().block_on(async {
        let path = dir.join("early.db");
        let cache = crate::cache::Cache::open(path.to_str().unwrap(), vec![72; 32])
            .await
            .unwrap();
        cache
            .receipt("peer@lid", &["early".into()], "peer@lid", 3, 20)
            .await
            .unwrap();
        drop(cache);
        let cache = crate::cache::Cache::open(path.to_str().unwrap(), vec![72; 32])
            .await
            .unwrap();
        let body = whatsapp_rust::waproto::whatsapp::Message {
            conversation: Some("sent".into()),
            ..Default::default()
        };
        let observation =
            crate::protocol::map_message("peer@lid", "early", "", true, 10, &body, false).unwrap();
        let id = observation.message.id.clone();
        cache.ingest(vec![observation]).await.unwrap();
        let (m, _) = cache.stored_message("peer@lid", &id).await.unwrap();
        assert_eq!(m.delivery, Some(3));
        assert_eq!(m.details.unwrap().receipts[0].level, 3);
    });
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn remote_terminal_revokes_queued_acceptance_and_pending_setup() {
    use whatsapp_rust::{
        prelude::*,
        wacore::types::call::{CallAction, IncomingCall},
    };
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        let calls=Arc::new(crate::calls::Calls::default());
        let from:Jid="peer@lid".parse().unwrap();
        let incoming=IncomingCall::builder().from(from.clone()).stanza_id("offer".into())
            .timestamp(std::time::SystemTime::now().into()).offline(false)
            .action(CallAction::Offer {call_id:"incoming".into(),call_creator:from.clone(),caller_pn:None,caller_country_code:None,device_class:None,joinable:false,is_video:false,audio:vec![],group_jid:None}).build();
        calls.observe(&Event::IncomingCall(incoming)).await;
        let accept=serde_json::from_value::<crate::commands::Action>(json!({"op":"call_accept","target":"incoming","attempt":"00000000-0000-4000-8000-000000000155"})).unwrap();
        let epoch=calls.admit("peer@lid",&accept).await.unwrap();
        let owner=calls.clone();
        let setup=tokio::spawn(async move { owner.during(epoch,std::future::pending::<Result<(),&'static str>>()).await });
        tokio::task::yield_now().await;
        let terminal=IncomingCall::builder().from(from.clone()).stanza_id("end".into())
            .timestamp(std::time::SystemTime::now().into()).offline(false)
            .action(CallAction::Terminate {call_id:"incoming".into(),call_creator:from,reason:None,duration:None,audio_duration:None}).build();
        calls.observe(&Event::IncomingCall(terminal)).await;
        assert!(!calls.is_current(epoch).await,"remote terminal must revoke queued admission");
        assert!(tokio::time::timeout(std::time::Duration::from_millis(100),setup).await.is_ok(),"pending setup must be cancelled");
        assert_eq!(calls.snapshot().await.unwrap().state,"ended");
        let peer:Jid="peer@lid".parse().unwrap();
        let late=IncomingCall::builder().from(peer.clone()).stanza_id("late-accept".into())
            .timestamp(std::time::SystemTime::now().into()).offline(false)
            .action(CallAction::Accept { call_id:"incoming".into(),call_creator:peer,audio:vec![] }).build();
        calls.observe(&Event::IncomingCall(late)).await;
        assert_eq!(calls.snapshot().await.unwrap().state,"ended","late acceptance cannot resurrect a terminated call");
    });
}
