// Source-scoped, durable control projection; original envelopes remain journalled.
use crate::cache::{Cache, Message, Observation};
use diesel::{
    prelude::*,
    sql_types::{BigInt, Binary, Text},
};
use whatsapp_rust::{
    prelude::*,
    waproto::{buffa::Message as _, whatsapp as wa},
};
#[derive(QueryableByName)]
struct Row {
    #[diesel(sql_type=Text)]
    payload: String,
}
#[derive(QueryableByName)]
struct Control {
    #[diesel(sql_type=Text)]
    field: String,
    #[diesel(sql_type=Text)]
    actor: String,
    #[diesel(sql_type=Text)]
    value: String,
    #[diesel(sql_type=BigInt)]
    stamp: i64,
}
fn target(chat: &str, key: &wa::MessageKey) -> Option<String> {
    if key.remote_jid.as_deref().is_some_and(|s| s != chat) {
        return None;
    }
    let sender = if key.from_me.unwrap_or(false) {
        ""
    } else {
        key.participant.as_deref().unwrap_or(chat)
    };
    serde_json::to_string(&(sender, key.id.as_ref()?)).ok()
}
#[derive(serde::Serialize, serde::Deserialize)]
struct PollWire {
    creator: Option<String>,
    payload: Vec<u8>,
    iv: Vec<u8>,
}
pub(crate) fn record(
    conn: &mut diesel::SqliteConnection,
    observation: &Observation,
) -> QueryResult<()> {
    if observation.raw.is_empty() {
        return Ok(());
    }
    let Ok(body) = wa::Message::decode_from_slice(&observation.raw) else {
        return Ok(());
    };
    let body = body.get_base_message();
    let m = &observation.message;
    let control = if let Some(r) = body.reaction_message.as_option() {
        r.key
            .as_option()
            .and_then(|k| target(&m.chat, k))
            .map(|id| {
                (
                    id,
                    "reaction",
                    m.sender.clone(),
                    r.text.clone().unwrap_or_default(),
                    r.sender_timestamp_ms.unwrap_or(m.version_timestamp),
                )
            })
    } else if let Some(p) = body.pin_in_chat_message.as_option() {
        p.key
            .as_option()
            .and_then(|k| target(&m.chat, k))
            .map(|id| {
                (
                    id,
                    "pin",
                    String::new(),
                    if p.r#type == Some(wa::message::pin_in_chat_message::Type::PinForAll) {
                        "true"
                    } else {
                        "false"
                    }
                    .to_owned(),
                    p.sender_timestamp_ms.unwrap_or(m.version_timestamp),
                )
            })
    } else {
        None
    };
    if let Some((id, field, actor, value, stamp)) = control {
        update(
            conn,
            (&m.chat, &id),
            field,
            &actor,
            &value,
            stamp,
            &observation.origin,
        )?;
    }
    if let Some(vote) = body.poll_update_message.as_option() {
        if let Some(key) = vote.poll_creation_message_key.as_option()
            && let Some(id) = target(&m.chat, key)
        {
            let stamp = vote.sender_timestamp_ms.unwrap_or(m.version_timestamp);
            diesel::sql_query("INSERT INTO mk_poll_votes VALUES(?1,?2,?3,?4,?5) ON CONFLICT(chat,id,actor) DO UPDATE SET payload=excluded.payload,stamp=excluded.stamp WHERE excluded.stamp>=mk_poll_votes.stamp")
                .bind::<Text,_>(&m.chat).bind::<Text,_>(&id).bind::<Text,_>(&m.sender).bind::<Text,_>(serde_json::to_string(&PollWire{creator:key.participant.clone(),payload:vote.vote.enc_payload.clone().unwrap_or_default(),iv:vote.vote.enc_iv.clone().unwrap_or_default()}).map_err(|e|diesel::result::Error::SerializationError(Box::new(e)))?).bind::<BigInt,_>(stamp).execute(conn)?;
            apply_votes(conn, &m.chat, &id)?;
        }
    } else if m.kind == "poll" {
        apply_votes(conn, &m.chat, &m.id)?;
    }
    Ok(())
}
#[derive(QueryableByName)]
struct PollBody {
    #[diesel(sql_type=Text)]
    payload: String,
    #[diesel(sql_type=Binary)]
    raw: Vec<u8>,
}
#[derive(QueryableByName)]
struct EncryptedVote {
    #[diesel(sql_type=Text)]
    actor: String,
    #[diesel(sql_type=Text)]
    payload: String,
    #[diesel(sql_type=BigInt)]
    stamp: i64,
}
fn apply_votes(conn: &mut diesel::SqliteConnection, chat: &str, id: &str) -> QueryResult<()> {
    use sha2::{Digest, Sha256};
    use whatsapp_rust::wacore::poll;
    let polls=diesel::sql_query("SELECT json_extract(payload,'$.message') AS payload,raw FROM mk_journal WHERE json_extract(payload,'$.message.chat')=?1 AND json_extract(payload,'$.message.id')=?2 AND json_extract(payload,'$.message.kind')='poll' AND length(raw)>0 ORDER BY sequence DESC LIMIT 1").bind::<Text,_>(chat).bind::<Text,_>(id).load::<PollBody>(conn)?;
    let Some(row) = polls.first() else {
        return Ok(());
    };
    let Ok(message) = serde_json::from_str::<Message>(&row.payload) else {
        return Ok(());
    };
    let Ok(body) = wa::Message::decode_from_slice(&row.raw) else {
        return Ok(());
    };
    let base = body.get_base_message();
    let Some(secret) = base.message_context_info.message_secret.as_deref() else {
        return Ok(());
    };
    let options = &message
        .details
        .as_ref()
        .map(|d| d.poll_options.clone())
        .unwrap_or_default();
    for vote in
        diesel::sql_query("SELECT actor,payload,stamp FROM mk_poll_votes WHERE chat=?1 AND id=?2")
            .bind::<Text, _>(chat)
            .bind::<Text, _>(id)
            .load::<EncryptedVote>(conn)?
    {
        let Ok(value) = serde_json::from_str::<PollWire>(&vote.payload) else {
            continue;
        };
        let creator = value
            .creator
            .as_deref()
            .or(message
                .details
                .as_ref()
                .and_then(|d| d.poll_creator.as_deref()))
            .unwrap_or(&message.sender);
        let payload = &value.payload;
        let iv = &value.iv;
        let Ok(hashes) = poll::decrypt_poll_vote_with_secret(
            poll::PollVoteCiphertext {
                enc_payload: payload,
                enc_iv: iv,
            },
            secret,
            &message.stanza,
            creator,
            &vote.actor,
        ) else {
            continue;
        };
        let selected: Vec<String> = options
            .iter()
            .filter(|option| {
                hashes
                    .iter()
                    .any(|h| h.as_slice() == Sha256::digest(option.as_bytes()).as_slice())
            })
            .cloned()
            .collect();
        if hashes.len() != selected.len() {
            continue;
        };
        let encoded = serde_json::to_string(&selected)
            .map_err(|e| diesel::result::Error::SerializationError(Box::new(e)))?;
        update(
            conn,
            (chat, id),
            "vote",
            &vote.actor,
            &encoded,
            vote.stamp,
            "poll",
        )?;
    }
    Ok(())
}
pub(crate) fn update(
    conn: &mut diesel::SqliteConnection,
    source: (&str, &str),
    field: &str,
    actor: &str,
    value: &str,
    stamp: i64,
    origin: &str,
) -> QueryResult<()> {
    let (chat, id) = source;
    let changed=diesel::sql_query("INSERT INTO mk_controls(chat,id,field,actor,value,stamp) VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(chat,id,field,actor) DO UPDATE SET value=excluded.value,stamp=excluded.stamp WHERE excluded.stamp>=mk_controls.stamp")
        .bind::<Text,_>(chat).bind::<Text,_>(id).bind::<Text,_>(field).bind::<Text,_>(actor).bind::<Text,_>(value).bind::<BigInt,_>(stamp).execute(conn)?;
    if changed > 0 {
        for row in diesel::sql_query("SELECT payload FROM mk_messages WHERE chat=?1 AND id=?2")
            .bind::<Text, _>(chat)
            .bind::<Text, _>(id)
            .load::<Row>(conn)?
        {
            let mut message: Message = serde_json::from_str(&row.payload)
                .map_err(|e| diesel::result::Error::DeserializationError(Box::new(e)))?;
            decorate(conn, &mut message)?;
            Cache::insert(
                conn,
                Observation {
                    message,
                    origin: format!("control:{origin}:{field}:{actor}:{stamp}"),
                    history: true,
                    raw: Vec::new(),
                    push_name: None,
                    notify: false,
                },
            )?;
        }
    }
    Ok(())
}
pub(crate) fn decorate(
    conn: &mut diesel::SqliteConnection,
    message: &mut Message,
) -> QueryResult<()> {
    let rows=diesel::sql_query("SELECT field,actor,value,stamp FROM mk_controls WHERE chat=?1 AND id=?2 ORDER BY actor,field").bind::<Text,_>(&message.chat).bind::<Text,_>(&message.id).load::<Control>(conn)?;
    if rows.is_empty() {
        return Ok(());
    }
    let details = message.details.get_or_insert_with(Default::default);
    let mut reactions = Vec::new();
    let mut votes = Vec::new();
    for row in rows {
        match row.field.as_str() {
            "vote" => {
                if let Ok(options) = serde_json::from_str::<Vec<String>>(&row.value) {
                    votes.push(crate::presentation::PollVote {
                        sender: row.actor,
                        options,
                        timestamp: row.stamp,
                    });
                }
            }
            "reaction" => {
                if !row.value.is_empty() {
                    reactions.push(crate::presentation::Reaction {
                        sender: row.actor,
                        text: row.value,
                        timestamp: row.stamp,
                    });
                }
            }
            "pin" => details.pinned = Some(row.value == "true"),
            "star" => details.starred = Some(row.value == "true"),
            _ => {}
        }
    }
    details.reactions = Some(reactions);
    if !votes.is_empty() {
        details.poll_votes = Some(votes)
    };
    Ok(())
}
impl Cache {
    pub async fn flag(
        &self,
        chat: &str,
        id: &str,
        field: &str,
        on: bool,
        stamp: i64,
    ) -> Result<(), &'static str> {
        if !["star", "pin"].contains(&field) {
            return Err("input");
        }
        let (chat, id, field) = (chat.to_owned(), id.to_owned(), field.to_owned());
        self.shared
            .run(move |conn| {
                conn.transaction::<_, diesel::result::Error, _>(|conn| {
                    update(
                        conn,
                        (&chat, &id),
                        &field,
                        "",
                        if on { "true" } else { "false" },
                        stamp,
                        "local",
                    )
                })
                .map_err(|e| whatsapp_rust::wacore::store::error::StoreError::Database(Box::new(e)))
            })
            .await
            .map_err(|_| "storage")?;
        self.mark_changed();
        Ok(())
    }
}
