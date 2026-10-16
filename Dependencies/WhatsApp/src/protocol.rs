// Bot lifecycle and protobuf mapping adapted from WhatsApp Zen account.rs at
// 790066aa411d395562a572101a74057147af67db (MIT; notice retained).
use crate::cache::{Cache, Chat, Message, Observation};
use serde::Serialize;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
use whatsapp_rust::prelude::*;
use whatsapp_rust::waproto::{buffa::Message as _, whatsapp as wa};

#[derive(Serialize)]
pub struct ConnectionStatus {
    pub state: String,
    pub qr: String,
    pub expires: i64,
    pub revision: u64,
    pub error: Option<String>,
    #[serde(rename = "avatarRevisions")]
    pub avatar_revisions: std::collections::BTreeMap<String, u64>,
    #[serde(rename = "avatarEpoch")]
    pub avatar_epoch: u64,
}
impl Default for ConnectionStatus {
    fn default() -> Self {
        Self {
            state: "offline".into(),
            qr: String::new(),
            expires: 0,
            revision: 0,
            error: None,
            avatar_revisions: Default::default(),
            avatar_epoch: 0,
        }
    }
}
impl ConnectionStatus {
    pub fn set(&mut self, state: &str) {
        self.state = state.into();
        self.qr.clear();
        self.expires = 0;
        self.revision = self.revision.wrapping_add(1);
    }
    pub fn expire(&mut self) {
        if self.state == "qr" && now() >= self.expires {
            self.set("expired");
        }
    }
    fn fail(&mut self) {
        self.set("failed");
        self.error = Some("storage".into());
    }
}
fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|v| v.as_secs() as i64)
        .unwrap_or(0)
}
struct Durability {
    cache: Cache,
    status: Arc<Mutex<ConnectionStatus>>,
}
#[async_trait::async_trait]
impl whatsapp_rust::InboundDurabilityHook for Durability {
    async fn on_history(
        &self,
        _: Arc<Client>,
        history: &whatsapp_rust::types::events::LazyHistorySync,
    ) -> anyhow::Result<()> {
        if persist_history(&self.cache, history).await.is_err() {
            if let Ok(mut s) = self.status.lock() {
                s.fail();
            }
            anyhow::bail!("durable history unavailable");
        }
        if let Ok(mut s) = self.status.lock() {
            s.revision = s.revision.wrapping_add(1);
        }
        Ok(())
    }
    async fn on_messages(&self, _: Arc<Client>, batch: &[InboundMessage]) -> anyhow::Result<()> {
        let rows = batch.iter().flat_map(inbound).collect();
        if self.cache.ingest(rows).await.is_err() {
            if let Ok(mut s) = self.status.lock() {
                s.fail();
            }
            anyhow::bail!("durable storage unavailable");
        }
        if let Ok(mut s) = self.status.lock() {
            s.revision = s.revision.wrapping_add(1);
        }
        Ok(())
    }
}
pub async fn build_bot(
    cache: Cache,
    status: Arc<Mutex<ConnectionStatus>>,
    calls: Arc<crate::calls::Calls>,
) -> Result<Bot, &'static str> {
    let qr_status = status.clone();
    let event_status = status.clone();
    let event_cache = cache.clone();
    Bot::builder()
        .with_backend(cache.store.clone())
        .with_inbound_durability_hook(Durability { cache, status })
        .on_qr_code(move |code, timeout| {
            let status = qr_status.clone();
            async move {
                if let Ok(mut s) = status.lock() {
                    if s.state == "stopping" {
                        return;
                    }
                    s.set("qr");
                    s.qr = code.to_string();
                    s.expires = now() + timeout.as_secs().min(120) as i64;
                }
            }
        })
        .on_event(move |event, _| {
            let cache = event_cache.clone();
            let status = event_status.clone();
            let calls = calls.clone();
            async move {
                calls.observe(&event).await;
                handle_event(&cache, &status, &event).await;
            }
        })
        .build()
        .await
        .map_err(|_| "connection")
}
fn inbound(inbound: &InboundMessage) -> Vec<Observation> {
    // PDO plaintext is also retained through its outer durable envelope. A
    // failed fallback callback must never let the envelope ack lose its body.
    if inbound.info.source.is_from_me
        && inbound.info.source.sender.device == 0
        && let Some(response) = inbound
            .message
            .get_base_message()
            .protocol_message
            .as_option()
            .and_then(|p| p.peer_data_operation_request_response_message.as_option())
    {
        let mut rows = Vec::new();
        for result in &response.peer_data_operation_result {
            if let Some(bytes) = result
                .placeholder_message_resend_response
                .as_option()
                .and_then(|r| r.web_message_info_bytes.as_ref())
                && let Ok(web) = whatsapp_rust::waproto::codec::web_message_info_decode(bytes)
                && let (Some(key), Some(body)) = (web.key.as_option(), web.message.as_option())
            {
                let chat = key.remote_jid.as_deref().unwrap_or("");
                let outgoing = key.from_me.unwrap_or(false);
                let sender = if outgoing {
                    ""
                } else {
                    key.participant
                        .as_deref()
                        .or(web.participant.as_deref())
                        .unwrap_or(chat)
                };
                if let Some(mut row) = map_message(
                    chat,
                    key.id.as_deref().unwrap_or(""),
                    sender,
                    outgoing,
                    web.message_timestamp.unwrap_or(0) as i64,
                    body,
                    false,
                ) {
                    row.push_name = web.push_name.clone();
                    rows.push(row);
                }
            }
        }
        // Retain the original envelope too, including unknown/invalid shapes.
        rows.extend(inbound_one(inbound));
        return rows;
    }
    inbound_one(inbound).into_iter().collect()
}
fn inbound_one(inbound: &InboundMessage) -> Option<Observation> {
    let info = &inbound.info;
    let source = &info.source;
    let chat = source.chat.to_non_ad().to_string();
    let sender = if source.is_from_me {
        String::new()
    } else {
        source.sender.to_non_ad().to_string()
    };
    let mut row = map_message(
        &chat,
        info.id.as_ref(),
        &sender,
        source.is_from_me,
        info.timestamp.timestamp(),
        &inbound.message,
        false,
    )?;
    row.push_name = Some(info.push_name.to_string());
    row.notify = !info.is_offline && !source.is_from_me;
    Some(row)
}
async fn handle_event(cache: &Cache, status: &Arc<Mutex<ConnectionStatus>>, event: &Event) {
    // Teardown callbacks cannot republish a QR/connected state.
    if status.lock().map(|s| s.state == "stopping").unwrap_or(true) {
        return;
    }
    let result = match event {
        Event::Connected(_) => {
            if let Ok(mut s) = status.lock() {
                s.set("connected");
            }
            Ok(())
        }
        Event::PairSuccess(_) => {
            if let Ok(mut s) = status.lock() {
                s.set("connecting");
            }
            Ok(())
        }
        Event::LoggedOut(_) => {
            if let Ok(mut s) = status.lock() {
                s.set("logged_out");
            }
            Ok(())
        }
        Event::Disconnected(_) => {
            if let Ok(mut s) = status.lock()
                && s.state != "logged_out"
            {
                s.set("reconnecting");
            }
            Ok(())
        }
        Event::Messages(batch) if !batch.hook_committed => {
            cache.ingest(batch.iter().flat_map(inbound).collect()).await
        }
        Event::PictureUpdate(update) => {
            if let Ok(mut s) = status.lock() {
                let jid = update.jid.to_non_ad().to_string();
                if !s.avatar_revisions.contains_key(&jid) && s.avatar_revisions.len() >= 512 {
                    s.avatar_revisions.clear();
                    s.avatar_epoch = s.avatar_epoch.wrapping_add(1);
                }
                let revision = s.avatar_revisions.entry(jid).or_default();
                *revision = revision.wrapping_add(1);
            }
            Ok(())
        }
        Event::ArchiveUpdate(u) => {
            cache
                .chat_update_at(
                    &u.jid.to_non_ad().to_string(),
                    crate::chat_rules::ChatUpdate::Archive(u.action.archived.unwrap_or(false)),
                    Some(u.timestamp.timestamp_millis()),
                )
                .await
        }
        Event::PinUpdate(u) => {
            cache
                .chat_update_at(
                    &u.jid.to_non_ad().to_string(),
                    crate::chat_rules::ChatUpdate::Pin(u.action.pinned.unwrap_or(false)),
                    Some(u.timestamp.timestamp_millis()),
                )
                .await
        }
        Event::MuteUpdate(u) => {
            let until = if !u.action.muted.unwrap_or(false) {
                0
            } else {
                let end = u.action.mute_end_timestamp.unwrap_or(-1);
                if end < 0 { -1 } else { end / 1000 }
            };
            cache
                .chat_update_at(
                    &u.jid.to_non_ad().to_string(),
                    crate::chat_rules::ChatUpdate::Mute(until),
                    Some(u.timestamp.timestamp_millis()),
                )
                .await
        }
        Event::MarkChatAsReadUpdate(u) => {
            cache
                .chat_update_at(
                    &u.jid.to_non_ad().to_string(),
                    if u.action.read.unwrap_or(true) {
                        crate::chat_rules::ChatUpdate::Read
                    } else {
                        crate::chat_rules::ChatUpdate::Unread
                    },
                    Some(u.timestamp.timestamp_millis()),
                )
                .await
        }
        Event::StarUpdate(u) => {
            let chat = u.chat_jid.to_non_ad().to_string();
            let sender = if u.from_me {
                String::new()
            } else {
                u.participant_jid
                    .as_ref()
                    .map(|j| j.to_non_ad().to_string())
                    .unwrap_or_else(|| chat.clone())
            };
            let id = serde_json::to_string(&(sender, &u.message_id)).map_err(|_| "input");
            match id {
                Ok(id) => {
                    cache
                        .flag(
                            &chat,
                            &id,
                            "star",
                            u.action.starred.unwrap_or(false),
                            u.timestamp.timestamp_millis(),
                        )
                        .await
                }
                Err(e) => Err(e),
            }
        }
        Event::ServerAck(ack) if ack.class.as_deref() == Some("message") => {
            if let Some(chat) = &ack.from {
                if let Some(code) = &ack.error {
                    cache
                        .rejection(
                            &chat.to_non_ad().to_string(),
                            &ack.id,
                            code,
                            ack.timestamp.map(|t| t.timestamp()).unwrap_or_else(now),
                        )
                        .await
                } else {
                    cache
                        .receipt(
                            &chat.to_non_ad().to_string(),
                            std::slice::from_ref(&ack.id),
                            "server",
                            1,
                            ack.timestamp.map(|t| t.timestamp()).unwrap_or_else(now),
                        )
                        .await
                }
            } else {
                Ok(())
            }
        }
        Event::Receipt(receipt) if !receipt.source.is_from_me => {
            use whatsapp_rust::wacore::types::presence::ReceiptType;
            let level = match receipt.r#type {
                ReceiptType::Read => 3,
                ReceiptType::Delivered => 2,
                ReceiptType::Played => 4,
                _ => 0,
            };
            if level == 0 {
                Ok(())
            } else {
                cache
                    .receipt(
                        &receipt.source.chat.to_non_ad().to_string(),
                        &receipt
                            .message_ids
                            .iter()
                            .map(ToString::to_string)
                            .collect::<Vec<_>>(),
                        &receipt.source.sender.to_non_ad().to_string(),
                        level,
                        receipt.timestamp.timestamp(),
                    )
                    .await
            }
        }
        _ => Ok(()),
    };
    if let Ok(mut s) = status.lock() {
        if result.is_err() {
            s.fail();
        } else {
            s.revision = s.revision.wrapping_add(1);
        }
    }
}
pub(crate) async fn persist_history(
    cache: &Cache,
    lazy: &whatsapp_rust::types::events::LazyHistorySync,
) -> Result<(), &'static str> {
    if let Some(history) = lazy.get() {
        let mut chats = Vec::new();
        let mut rows = Vec::new();
        for conversation in &history.conversations {
            let chat = &conversation.id;
            chats.push(Chat {
                id: chat.clone(),
                name: conversation
                    .name
                    .clone()
                    .filter(|n| !n.is_empty())
                    .unwrap_or_else(|| chat.clone()),
                timestamp: conversation.conversation_timestamp.unwrap_or(0) as i64,
                unread: conversation.unread_count.unwrap_or(0) as i64,
                archived: conversation.archived.unwrap_or(false),
                pinned: conversation.pinned.unwrap_or(0) > 0,
                group: chat.ends_with("@g.us"),
                muted_until: None,
                settings_revision: 0,
                settings_timestamps: Default::default(),
            });
            for entry in &conversation.messages {
                if let Some(web) = entry.message.as_option()
                    && let (Some(key), Some(body)) = (web.key.as_option(), web.message.as_option())
                {
                    let outgoing = key.from_me.unwrap_or(false);
                    let sender = if outgoing {
                        ""
                    } else {
                        key.participant
                            .as_deref()
                            .or(web.participant.as_deref())
                            .unwrap_or(chat)
                    };
                    if let Some(mut row) = map_message(
                        chat,
                        key.id.as_deref().unwrap_or(""),
                        sender,
                        outgoing,
                        web.message_timestamp.unwrap_or(0) as i64,
                        body,
                        true,
                    ) {
                        row.push_name = web.push_name.clone();
                        rows.push(row);
                    }
                }
            }
        }
        let names = history
            .pushnames
            .iter()
            .filter_map(|n| Some((n.id.clone()?, n.pushname.clone()?)))
            .collect();
        cache.ingest_history(rows, chats, names).await
    } else {
        Err("history")
    }
}
pub(crate) fn map_message(
    chat: &str,
    id: &str,
    sender: &str,
    outgoing: bool,
    timestamp: i64,
    body: &wa::Message,
    history: bool,
) -> Option<Observation> {
    if chat.is_empty() || id.is_empty() {
        return None;
    }
    let base = body.get_base_message();
    let mut stanza = id.to_owned();
    let mut sender = sender.to_owned();
    let mut outgoing = outgoing;
    let mut text = base.text_content().unwrap_or_default().to_string();
    let mut kind = "text";
    let mut edited = false;
    let mut deleted = false;
    let mut version_timestamp = timestamp.saturating_mul(1000);
    if let Some(protocol) = base.protocol_message.as_option() {
        use wa::message::protocol_message::Type;
        if matches!(protocol.r#type, Some(Type::Revoke | Type::MessageEdit)) {
            version_timestamp = protocol.timestamp_ms.unwrap_or(version_timestamp);
            let key = protocol.key.as_option()?;
            stanza = key.id.clone()?;
            outgoing = key.from_me.unwrap_or(false);
            sender = if outgoing {
                String::new()
            } else {
                key.participant.clone().unwrap_or(sender)
            };
            deleted = protocol.r#type == Some(Type::Revoke);
            edited = !deleted;
            text = protocol
                .edited_message
                .as_option()
                .and_then(|m| m.text_content())
                .unwrap_or_default()
                .to_string();
        } else {
            kind = "protocol";
        }
    } else if base.reaction_message.is_set()
        || base.pin_in_chat_message.is_set()
        || base.poll_update_message.is_set()
    {
        kind = "protocol";
    } else if let Some(media) = base.image_message.as_option() {
        kind = "image";
        text = media.caption.clone().unwrap_or_default();
    } else if let Some(media) = base
        .video_message
        .as_option()
        .or(base.ptv_message.as_option())
    {
        kind = "video";
        text = media.caption.clone().unwrap_or_default();
    } else if let Some(media) = base.document_message.as_option() {
        kind = "document";
        text = media
            .caption
            .clone()
            .or(media.file_name.clone())
            .unwrap_or_default();
    } else if base.audio_message.is_set() {
        kind = "audio";
    } else if base.sticker_message.is_set() {
        kind = "sticker";
    } else if base.contact_message.is_set() || base.contacts_array_message.is_set() {
        kind = "contact";
    } else if base.poll_creation_message.is_set()
        || base.poll_creation_message_v2.is_set()
        || base.poll_creation_message_v3.is_set()
    {
        kind = "poll";
    } else if let Some(location) = base.location_message.as_option() {
        kind = "location";
        text = format!(
            "{}, {}",
            location.degrees_latitude.unwrap_or_default(),
            location.degrees_longitude.unwrap_or_default()
        );
    } else if text.is_empty() {
        kind = "other";
    }
    let message = Message {
        chat: chat.into(),
        id: serde_json::to_string(&(&sender, &stanza)).ok()?,
        stanza,
        sender,
        timestamp,
        outgoing,
        text,
        kind: kind.into(),
        edited,
        deleted,
        version_timestamp,
        delivery: Some(0),
        details: Some(crate::presentation::details(body)),
    };
    Some(Observation {
        message,
        origin: id.into(),
        history,
        raw: body.encode_to_vec(),
        push_name: None,
        notify: !history && !outgoing,
    })
}

#[cfg(test)]
mod review_regressions {
    use super::*;
    #[test]
    fn server_nack_is_retained_before_and_after_message_projection() {
        let dir = std::env::temp_dir().join(format!("makosh-nack-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        tokio::runtime::Runtime::new().unwrap().block_on(async {
            let cache = Cache::open(dir.join("nack.db").to_str().unwrap(), vec![73; 32])
                .await
                .unwrap();
            let status = Arc::new(Mutex::new(ConnectionStatus::default()));
            for (n, early) in [("early", true), ("late", false)] {
                let event = Event::ServerAck(
                    whatsapp_rust::wacore::types::events::ServerAck::builder()
                        .id(n.into())
                        .class("message".into())
                        .from("peer@lid".parse().unwrap())
                        .error("479".into())
                        .build(),
                );
                if early {
                    handle_event(&cache, &status, &event).await;
                }
                let observation = map_message(
                    "peer@lid",
                    n,
                    "",
                    true,
                    10,
                    &wa::Message {
                        conversation: Some("sent".into()),
                        ..Default::default()
                    },
                    false,
                )
                .unwrap();
                let id = observation.message.id.clone();
                cache.ingest(vec![observation]).await.unwrap();
                if !early {
                    handle_event(&cache, &status, &event).await;
                }
                cache
                    .receipt("peer@lid", &[n.into()], "server", 1, 30)
                    .await
                    .unwrap();
                let (message, _) = cache.stored_message("peer@lid", &id).await.unwrap();
                let json = serde_json::to_value(message).unwrap();
                assert_eq!(json["details"]["rejection"]["code"], "479");
            }
        });
        std::fs::remove_dir_all(dir).unwrap();
    }
}
