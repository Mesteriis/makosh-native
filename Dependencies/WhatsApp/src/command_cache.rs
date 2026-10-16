use crate::cache::{Cache, Message};
use diesel::{
    prelude::*,
    sql_types::{BigInt, Binary, Text},
};
use serde_json::Value;

#[derive(QueryableByName)]
struct CommandRow {
    #[diesel(sql_type=Text)]
    digest: String,
    #[diesel(sql_type=Text)]
    state: String,
    #[diesel(sql_type=Text)]
    result: String,
}
#[derive(QueryableByName)]
struct BodyRow {
    #[diesel(sql_type=BigInt)]
    sequence: i64,
    #[diesel(sql_type=Binary)]
    raw: Vec<u8>,
}
#[derive(QueryableByName)]
struct CurrentRow {
    #[diesel(sql_type=Text)]
    payload: String,
}
impl Cache {
    pub async fn command_result(&self, ticket: &str) -> Result<Value, &'static str> {
        let ticket = ticket.to_owned();
        let rows = self
            .shared
            .run(move |conn| {
                diesel::sql_query("SELECT digest,state,result FROM mk_commands WHERE attempt=?1")
                    .bind::<Text, _>(ticket)
                    .load::<CommandRow>(conn)
                    .map_err(|e| {
                        whatsapp_rust::wacore::store::error::StoreError::Database(Box::new(e))
                    })
            })
            .await
            .map_err(|_| "storage")?;
        let row = rows.first().ok_or("input")?;
        match row.state.as_str() {
            "pending" => Ok(serde_json::json!({"pending":true})),
            "done" => serde_json::from_str(&row.result).map_err(|_| "storage"),
            _ => Err("unknown"),
        }
    }
    pub async fn fail_command(&self, ticket: &str) -> Result<(), &'static str> {
        let ticket = ticket.to_owned();
        self.shared
            .run(move |conn| {
                diesel::sql_query(
                    "UPDATE mk_commands SET state='unknown' WHERE attempt=?1 AND state='pending'",
                )
                .bind::<Text, _>(ticket)
                .execute(conn)
                .map_err(|e| whatsapp_rust::wacore::store::error::StoreError::Database(Box::new(e)))
            })
            .await
            .map_err(|_| "storage")?;
        Ok(())
    }
    pub async fn admit_command(
        &self,
        attempt: &str,
        digest: &str,
    ) -> Result<Option<Value>, &'static str> {
        let (attempt, digest) = (attempt.to_owned(), digest.to_owned());
        let expected = digest.clone();
        let (created, rows) = self
            .shared
            .run(move |conn| {
                conn.transaction::<_, diesel::result::Error, _>(|conn| {
                    let created = diesel::sql_query(
                        "INSERT OR IGNORE INTO mk_commands VALUES(?1,?2,'pending','')",
                    )
                    .bind::<Text, _>(&attempt)
                    .bind::<Text, _>(&digest)
                    .execute(conn)?;
                    let rows = diesel::sql_query(
                        "SELECT digest,state,result FROM mk_commands WHERE attempt=?1",
                    )
                    .bind::<Text, _>(&attempt)
                    .load::<CommandRow>(conn)?;
                    Ok((created, rows))
                })
                .map_err(|e| whatsapp_rust::wacore::store::error::StoreError::Database(Box::new(e)))
            })
            .await
            .map_err(|_| "storage")?;
        let row = rows.first().ok_or("storage")?;
        if row.digest != expected {
            // This attempt may already have submitted another payload. Do not
            // let the caller interpret it as a fresh pre-dispatch rejection.
            return Err("attempt");
        }
        if created == 1 {
            return Ok(None);
        }
        if row.state != "done" {
            return Err("unknown");
        }
        Ok(Some(
            serde_json::from_str(&row.result).map_err(|_| "storage")?,
        ))
    }
    pub async fn finish_command(&self, attempt: &str, result: &Value) -> Result<(), &'static str> {
        let attempt = attempt.to_owned();
        let result = serde_json::to_string(result).map_err(|_| "input")?;
        let changed=self.shared.run(move |conn| {
            diesel::sql_query("UPDATE mk_commands SET state='done',result=?2 WHERE attempt=?1 AND state='pending'")
                .bind::<Text,_>(attempt).bind::<Text,_>(result).execute(conn)
                .map_err(|e|whatsapp_rust::wacore::store::error::StoreError::Database(Box::new(e)))
        }).await.map_err(|_|"storage")?;
        if changed != 1 {
            return Err("unknown");
        }
        Ok(())
    }
    pub async fn stored_message(
        &self,
        chat: &str,
        id: &str,
    ) -> Result<(Message, Vec<u8>), &'static str> {
        self.stored_resource(chat, id, None).await
    }
    pub async fn stored_resource(
        &self,
        chat: &str,
        id: &str,
        resource: Option<&str>,
    ) -> Result<(Message, Vec<u8>), &'static str> {
        if resource.is_some_and(|r| r.len() != 64 || !r.bytes().all(|b| b.is_ascii_hexdigit())) {
            return Err("input");
        }
        use whatsapp_rust::{prelude::*, waproto::buffa::Message as _};
        let (chat, id) = (chat.to_owned(), id.to_owned());
        let current_chat = chat.clone();
        let current_id = id.clone();
        let rows = self
            .shared
            .read(move |conn| {
                diesel::sql_query("SELECT payload FROM mk_messages WHERE chat=?1 AND id=?2")
                    .bind::<Text, _>(current_chat)
                    .bind::<Text, _>(current_id)
                    .load::<CurrentRow>(conn)
                    .map_err(|e| {
                        whatsapp_rust::wacore::store::error::StoreError::Database(Box::new(e))
                    })
            })
            .await
            .map_err(|_| "storage")?;
        let current: Message =
            serde_json::from_str(&rows.first().ok_or("input")?.payload).map_err(|_| "storage")?;
        let mut before = i64::MAX;
        loop {
            let (chat, id) = (chat.clone(), id.clone());
            let rows=self.shared.read(move|conn|diesel::sql_query("SELECT sequence,raw FROM mk_journal WHERE json_extract(payload,'$.message.chat')=?1 AND json_extract(payload,'$.message.id')=?2 AND length(raw)>0 AND sequence<?3 ORDER BY sequence DESC LIMIT 16").bind::<Text,_>(chat).bind::<Text,_>(id).bind::<BigInt,_>(before).load::<BodyRow>(conn).map_err(|e|whatsapp_rust::wacore::store::error::StoreError::Database(Box::new(e)))).await.map_err(|_|"storage")?;
            if rows.is_empty() {
                return Err("input");
            }
            for row in &rows {
                let Ok(body) = wa::Message::decode_from_slice(&row.raw) else {
                    continue;
                };
                let base = body.get_base_message();
                let content = if let Some(protocol) = base.protocol_message.as_option() {
                    let Some(edited) = protocol.edited_message.as_option() else {
                        continue;
                    };
                    edited.get_base_message()
                } else {
                    base
                };
                if content.reaction_message.is_set()
                    || content.pin_in_chat_message.is_set()
                    || content.poll_update_message.is_set()
                {
                    continue;
                }
                let mut content = content.clone();
                let media = content.image_message.is_set()
                    || content.video_message.is_set()
                    || content.document_message.is_set()
                    || content.audio_message.is_set()
                    || content.sticker_message.is_set()
                    || content.ptv_message.is_set();
                if ["image", "video", "document", "audio", "sticker"]
                    .contains(&current.kind.as_str())
                    && !media
                {
                    continue;
                }
                if let Some(expected) = resource
                    && crate::presentation::details(&content)
                        .resource_id
                        .as_deref()
                        != Some(expected)
                {
                    continue;
                }
                if current.edited && resource.is_none() {
                    if let Some(m) = content.image_message.as_option_mut() {
                        m.caption = Some(current.text.clone());
                    }
                    if let Some(m) = content.video_message.as_option_mut() {
                        m.caption = Some(current.text.clone());
                    }
                    if let Some(m) = content.document_message.as_option_mut() {
                        m.caption = Some(current.text.clone());
                    }
                }
                return Ok((current, content.encode_to_vec()));
            }
            before = rows.last().ok_or("storage")?.sequence;
        }
    }
}
