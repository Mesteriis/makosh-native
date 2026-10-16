use whatsapp_rust::wacore_binary::JidExt;
// Command workflows adapted from the reviewed Zen account.rs/commands.rs (MIT).
// Unlike that reference, admission is durable and an uncertain send never replays.
use crate::cache::Cache;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use whatsapp_rust::waproto::{
    buffa::{Message as _, MessageField},
    whatsapp as wa,
};
use whatsapp_rust::{
    prelude::*,
    send::{RevokeType, SendOptions},
};

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Action {
    pub op: String,
    #[serde(default, rename = "callEpoch")]
    pub call_epoch: Option<u64>,
    #[serde(default, rename = "callContext")]
    pub call_context: Option<String>,
    pub attempt: String,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub target: String,
    #[serde(default)]
    pub reply: Option<String>,
    #[serde(default)]
    pub mentions: Vec<String>,
    #[serde(default)]
    pub to: String,
    #[serde(default)]
    pub on: bool,
    #[serde(default)]
    pub duration: i64,
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub mime: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub options: Vec<String>,
    #[serde(default)]
    pub latitude: Option<f64>,
    #[serde(default)]
    pub longitude: Option<f64>,
    #[serde(default)]
    pub category: String,
    #[serde(default)]
    pub value: String,
}
fn valid_uuid(value: &str) -> bool {
    value.len() == 36
        && value.chars().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c == '-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}
impl Action {
    pub fn validate(&self, chat: &str) -> Result<(), &'static str> {
        if !valid_uuid(&self.attempt)
            || self.call_context.as_deref().is_some_and(|v| !valid_uuid(v))
            || chat.parse::<Jid>().is_err()
            || chat.len() > 1024
            || self.text.len() > 65536
            || self.target.len() > 2048
            || self.to.len() > 1024
            || self.path.len() > 4096
            || self.name.len() > 512
            || self.mime.len() > 128
            || self.mentions.len() > 100
            || self.mentions.iter().any(|j| j.parse::<Jid>().is_err())
        {
            return Err("input");
        }
        match self.op.as_str() {
            "location"
                if self
                    .latitude
                    .is_none_or(|v| !v.is_finite() || !(-90.0..=90.0).contains(&v))
                    || self
                        .longitude
                        .is_none_or(|v| !v.is_finite() || !(-180.0..=180.0).contains(&v)) =>
            {
                Err("input")
            }
            "contact"
                if self.to.parse::<Jid>().is_err() || !self.to.ends_with("@s.whatsapp.net") =>
            {
                Err("input")
            }
            "poll"
                if self.text.trim().is_empty()
                    || !(2..=12).contains(&self.options.len())
                    || self
                        .options
                        .iter()
                        .any(|s| s.trim().is_empty() || s.len() > 512)
                    || self
                        .options
                        .iter()
                        .collect::<std::collections::HashSet<_>>()
                        .len()
                        != self.options.len() =>
            {
                Err("input")
            }
            "group_update"
                if self.target.parse::<Jid>().is_err()
                    || !["add", "remove", "promote", "demote"]
                        .contains(&self.category.as_str()) =>
            {
                Err("input")
            }
            "set_name" | "group_name" | "group_create" if self.text.trim().is_empty() => {
                Err("input")
            }
            "ephemeral" if ![0, 86400, 604800, 7776000].contains(&self.duration) => Err("input"),
            "privacy_set" if crate::profile::privacy_pair(&self.category, &self.value).is_err() => {
                Err("input")
            }
            "vote" if self.target.is_empty() || self.options.len() > 12 => Err("input"),
            "text" | "edit" if self.text.trim().is_empty() => Err("input"),
            "edit" | "revoke" | "react" | "forward" | "star" | "pin" if self.target.is_empty() => {
                Err("input")
            }
            "forward" if self.to.parse::<Jid>().is_err() => Err("input"),
            "react" if self.text.len() > 128 => Err("input"),
            "media"
                if !["image", "video", "audio", "sticker", "document"]
                    .contains(&self.kind.as_str())
                    || self.path.is_empty() =>
            {
                Err("input")
            }
            "download" if self.path.is_empty() || self.target.is_empty() => Err("input"),
            "media" | "download" | "text" | "edit" | "revoke" | "react" | "forward" | "star"
            | "archive" | "pin" | "pin_chat" | "mute" | "read" | "typing" => Ok(()),
            "call_group_start" => {
                let group: Jid = chat.parse().map_err(|_| "input")?;
                if !group.is_group() {
                    return Err("input");
                }
                crate::calls::validate_group_targets(&self.options)
            }
            "call_invite" | "call_ring" => {
                if self.target.is_empty()
                    || self.call_epoch.is_none_or(|e| e == 0)
                    || self.to.parse::<Jid>().is_err()
                {
                    Err("input")
                } else {
                    Ok(())
                }
            }
            "call_start" | "call_accept" | "call_end" | "call_mute" | "call_video"
            | "call_reject" => Ok(()),
            "location" | "contact" | "poll" | "vote" | "block" | "profile" | "user_info"
            | "avatar" | "privacy" | "privacy_set" | "set_name" | "set_about" | "group_info"
            | "group_name" | "group_about" | "group_update" | "group_create" | "group_leave"
            | "group_link" | "ephemeral" => Ok(()),
            _ => Err("command"),
        }
    }
}
async fn target(
    cache: &Cache,
    chat: &str,
    id: &str,
) -> Result<(crate::cache::Message, wa::Message), &'static str> {
    let (row, raw) = cache.stored_message(chat, id).await?;
    let body = wa::Message::decode_from_slice(&raw).map_err(|_| "input")?;
    let body = body
        .get_base_message()
        .protocol_message
        .as_option()
        .and_then(|p| p.edited_message.as_option())
        .cloned()
        .unwrap_or(body);
    Ok((row, body))
}
fn key(chat: &str, row: &crate::cache::Message) -> wa::MessageKey {
    wa::MessageKey {
        remote_jid: Some(chat.into()),
        from_me: Some(row.outgoing),
        id: Some(row.stanza.clone()),
        participant: (chat.ends_with("@g.us") && !row.outgoing).then(|| row.sender.clone()),
    }
}
pub(crate) fn with_context(
    mut body: wa::Message,
    context: wa::ContextInfo,
) -> Result<wa::Message, &'static str> {
    let context = MessageField::some(context);
    if let Some(text) = body.conversation.take() {
        body.extended_text_message = MessageField::some(wa::message::ExtendedTextMessage {
            text: Some(text),
            context_info: context,
            ..Default::default()
        });
    } else if let Some(m) = body.extended_text_message.as_option_mut() {
        m.context_info = context;
    } else if let Some(m) = body.image_message.as_option_mut() {
        m.context_info = context;
    } else if let Some(m) = body.video_message.as_option_mut() {
        m.context_info = context;
    } else if let Some(m) = body.document_message.as_option_mut() {
        m.context_info = context;
    } else if let Some(m) = body.audio_message.as_option_mut() {
        m.context_info = context;
    } else if let Some(m) = body.sticker_message.as_option_mut() {
        m.context_info = context;
    } else if let Some(m) = body.location_message.as_option_mut() {
        m.context_info = context;
    } else if let Some(m) = body.contact_message.as_option_mut() {
        m.context_info = context;
    } else {
        return Err("input");
    }
    Ok(body)
}
async fn record_sent(
    cache: &Cache,
    chat: &str,
    stanza: &str,
    body: &wa::Message,
    creator: Option<String>,
) -> Result<(), &'static str> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| "unknown")?
        .as_secs() as i64;
    let mut observation =
        crate::protocol::map_message(chat, stanza, "", true, now, body, false).ok_or("unknown")?;
    if observation.message.kind == "poll"
        && let Some(details) = &mut observation.message.details
    {
        details.poll_creator = creator;
    }
    cache.ingest(vec![observation]).await.map_err(|_| "unknown")
}
pub async fn execute(
    client: std::sync::Arc<Client>,
    cache: &Cache,
    chat: &str,
    a: &Action,
) -> Result<Value, &'static str> {
    let jid: Jid = chat.parse().map_err(|_| "input")?;
    let stanza = format!("MK{}", a.attempt.replace('-', "").to_uppercase());
    let mut body = wa::Message::text(a.text.trim().to_owned());
    if a.op == "vote" {
        return crate::polls::vote(&client, cache, chat, a).await;
    }
    if crate::profile::handles(&a.op) {
        return crate::profile::execute(&client, cache, chat, a).await;
    }
    if a.op == "download" {
        crate::media::download(&client, cache, chat, a).await?;
        return Ok(Value::Null);
    }
    if ["text", "media", "location", "contact", "poll"].contains(&a.op.as_str()) {
        if a.op == "poll" {
            body = crate::polls::new_creation(&a.text, &a.options)?;
        }
        if a.op == "location" {
            body = wa::Message {
                location_message: MessageField::some(wa::message::LocationMessage {
                    degrees_latitude: a.latitude,
                    degrees_longitude: a.longitude,
                    name: (!a.text.is_empty()).then(|| a.text.clone()),
                    ..Default::default()
                }),
                ..Default::default()
            };
        }
        if a.op == "contact" {
            let contact: Jid = a.to.parse().map_err(|_| "input")?;
            if !contact.user.chars().all(|c| c.is_ascii_digit()) {
                return Err("input");
            }
            let name = a
                .text
                .replace('\\', "\\\\")
                .replace(';', "\\;")
                .replace(',', "\\,")
                .replace('\n', "\\n")
                .replace('\r', "");
            body = wa::Message {
                contact_message: MessageField::some(wa::message::ContactMessage {
                    display_name: Some(a.text.clone()),
                    vcard: Some(format!(
                        "BEGIN:VCARD\nVERSION:3.0\nFN:{name}\nTEL;type=CELL;waid={0}:+{0}\nEND:VCARD",
                        contact.user
                    )),
                    ..Default::default()
                }),
                ..Default::default()
            };
        }
        let mut context = wa::ContextInfo {
            mentioned_jid: a.mentions.clone(),
            ..Default::default()
        };
        if let Some(reply) = &a.reply {
            let (row, quoted) = target(cache, chat, reply).await?;
            context.stanza_id = Some(row.stanza);
            context.participant = if row.outgoing {
                Some(
                    client
                        .lid()
                        .or_else(|| client.pn())
                        .ok_or("offline")?
                        .to_string(),
                )
            } else {
                Some(row.sender)
            };
            context.quoted_message = MessageField::some(quoted.get_base_message().clone());
        }
        if a.op == "media" {
            body = crate::media::upload(&client, a).await?;
        }
        if a.reply.is_some() || !a.mentions.is_empty() {
            body = with_context(body, context)?;
        }
        client
            .send_message_with_options(
                jid,
                body.clone(),
                SendOptions::default().with_message_id(stanza.clone()),
            )
            .await
            .map_err(|_| "unknown")?;
        record_sent(
            cache,
            chat,
            &stanza,
            &body,
            client.pn().map(|j| j.to_non_ad().to_string()),
        )
        .await?;
        return Ok(json!({"stanza":stanza}));
    }
    match a.op.as_str() {
        "react" => {
            let (row, _) = target(cache, chat, &a.target).await?;
            client
                .send_reaction(jid, key(chat, &row), &a.text)
                .await
                .map_err(|_| "unknown")?;
        }
        "edit" | "revoke" => {
            let (row, _) = target(cache, chat, &a.target).await?;
            if !row.outgoing || row.deleted {
                return Err("input");
            }
            if a.op == "edit" {
                client
                    .edit_message(jid, row.stanza, body)
                    .await
                    .map_err(|_| "unknown")?;
            } else {
                client
                    .revoke_message(jid, row.stanza, RevokeType::Sender)
                    .await
                    .map_err(|_| "unknown")?;
            }
        }
        "forward" => {
            let (row, body) = target(cache, chat, &a.target).await?;
            if row.deleted {
                return Err("input");
            }
            let to: Jid = a.to.parse().map_err(|_| "input")?;
            let body = with_context(
                body.get_base_message().clone(),
                wa::ContextInfo {
                    is_forwarded: Some(true),
                    forwarding_score: Some(1),
                    ..Default::default()
                },
            )?;
            client
                .send_message_with_options(
                    to,
                    body.clone(),
                    SendOptions::default().with_message_id(stanza.clone()),
                )
                .await
                .map_err(|_| "unknown")?;
            record_sent(
                cache,
                &a.to,
                &stanza,
                &body,
                client.pn().map(|j| j.to_non_ad().to_string()),
            )
            .await?;
            return Ok(json!({"stanza":stanza}));
        }
        "archive" => {
            let actions = client.chat_actions();
            if a.on {
                actions.archive_chat(&jid, None).await
            } else {
                actions.unarchive_chat(&jid, None).await
            }
            .map_err(|_| "unknown")?;
            cache
                .chat_update(chat, crate::chat_rules::ChatUpdate::Archive(a.on))
                .await?;
        }
        "pin_chat" => {
            let actions = client.chat_actions();
            if a.on {
                actions.pin_chat(&jid).await
            } else {
                actions.unpin_chat(&jid).await
            }
            .map_err(|_| "unknown")?;
            cache
                .chat_update(chat, crate::chat_rules::ChatUpdate::Pin(a.on))
                .await?;
        }
        "mute" => {
            let actions = client.chat_actions();
            if a.duration == 0 {
                actions.unmute_chat(&jid).await
            } else if a.duration < 0 {
                actions.mute_chat(&jid).await
            } else {
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_err(|_| "input")?
                    .as_millis() as i64;
                actions
                    .mute_chat_until(&jid, now.saturating_add(a.duration.saturating_mul(1000)))
                    .await
            }
            .map_err(|_| "unknown")?;
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_err(|_| "unknown")?
                .as_secs() as i64;
            cache
                .chat_update(
                    chat,
                    crate::chat_rules::ChatUpdate::Mute(if a.duration <= 0 {
                        a.duration.signum()
                    } else {
                        now.saturating_add(a.duration)
                    }),
                )
                .await?;
        }
        "pin" => {
            let (row, _) = target(cache, chat, &a.target).await?;
            client
                .send_message_with_options(
                    jid,
                    wa::Message {
                        pin_in_chat_message: MessageField::some(wa::message::PinInChatMessage {
                            key: MessageField::some(key(chat, &row)),
                            r#type: Some(if a.on {
                                wa::message::pin_in_chat_message::Type::PinForAll
                            } else {
                                wa::message::pin_in_chat_message::Type::UnpinForAll
                            }),
                            ..Default::default()
                        }),
                        ..Default::default()
                    },
                    SendOptions::default().with_message_id(stanza.clone()),
                )
                .await
                .map_err(|_| "unknown")?;
            cache
                .flag(
                    chat,
                    &row.id,
                    "pin",
                    a.on,
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map_err(|_| "unknown")?
                        .as_millis() as i64,
                )
                .await?;
        }
        "star" => {
            let (row, _) = target(cache, chat, &a.target).await?;
            let participant = row.sender.parse::<Jid>().ok();
            let actions = client.chat_actions();
            if a.on {
                actions
                    .star_message(&jid, participant.as_ref(), &row.stanza, row.outgoing)
                    .await
            } else {
                actions
                    .unstar_message(&jid, participant.as_ref(), &row.stanza, row.outgoing)
                    .await
            }
            .map_err(|_| "unknown")?;
            cache
                .flag(
                    chat,
                    &row.id,
                    "star",
                    a.on,
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map_err(|_| "unknown")?
                        .as_millis() as i64,
                )
                .await?;
        }
        "read" => {
            let rows = cache.messages(chat.into(), None, 100).await?;
            let mut by_sender = std::collections::HashMap::<String, Vec<String>>::new();
            for row in rows.into_iter().filter(|r| !r.outgoing) {
                by_sender.entry(row.sender).or_default().push(row.stanza);
            }
            for (sender, ids) in by_sender {
                let sender = sender.parse::<Jid>().ok();
                let ids: Vec<&str> = ids.iter().map(String::as_str).collect();
                client
                    .mark_as_read(
                        &jid,
                        if chat.ends_with("@g.us") {
                            sender.as_ref()
                        } else {
                            None
                        },
                        &ids,
                    )
                    .await
                    .map_err(|_| "unknown")?;
            }
            client
                .chat_actions()
                .mark_chat_as_read(&jid, true, None)
                .await
                .map_err(|_| "unknown")?;
            cache
                .chat_update(chat, crate::chat_rules::ChatUpdate::Read)
                .await?;
        }
        "typing" => {
            let state = client.chatstate();
            if a.on {
                state.send_composing(&jid).await
            } else {
                state.send_paused(&jid).await
            }
            .map_err(|_| "unknown")?;
        }
        _ => return Err("command"),
    }
    Ok(Value::Null)
}
