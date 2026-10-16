use crate::{
    cache::{Cache, Message, Observation},
    presentation::{Details, Receipt, Rejection},
};
use diesel::{
    prelude::*,
    sql_types::{BigInt, Text},
};
#[derive(QueryableByName)]
struct Row {
    #[diesel(sql_type=Text)]
    payload: String,
}
#[derive(QueryableByName)]
struct ReceiptRow {
    #[diesel(sql_type=Text)]
    sender: String,
    #[diesel(sql_type=BigInt)]
    level: i64,
    #[diesel(sql_type=BigInt)]
    stamp: i64,
}
#[derive(QueryableByName)]
struct RejectionRow {
    #[diesel(sql_type=Text)]
    code: String,
    #[diesel(sql_type=BigInt)]
    stamp: i64,
}
fn db_error(e: diesel::result::Error) -> whatsapp_rust::wacore::store::error::StoreError {
    whatsapp_rust::wacore::store::error::StoreError::Database(Box::new(e))
}
/// Persistent source facts precede projection. SharedSqlite serializes both this
/// admission and Cache::insert, including receipt-before-local-send races.
pub(crate) fn decorate(conn: &mut diesel::SqliteConnection, m: &mut Message) -> QueryResult<()> {
    if !m.outgoing {
        return Ok(());
    }
    let rows = diesel::sql_query(
        "SELECT sender,level,stamp FROM mk_receipts WHERE chat=?1 AND stanza=?2 ORDER BY sender",
    )
    .bind::<Text, _>(&m.chat)
    .bind::<Text, _>(&m.stanza)
    .load::<ReceiptRow>(conn)?;
    for r in rows {
        m.delivery = Some(m.delivery.unwrap_or(0).max(r.level.min(3)));
        let d = m.details.get_or_insert_with(Details::default);
        if d.receipts
            .iter()
            .all(|old| old.sender != r.sender || old.level < r.level)
        {
            d.receipts.retain(|old| old.sender != r.sender);
            d.receipts.push(Receipt {
                sender: r.sender,
                level: r.level,
                timestamp: r.stamp,
            });
        }
    }
    if let Some(r) =
        diesel::sql_query("SELECT code,stamp FROM mk_rejections WHERE chat=?1 AND stanza=?2")
            .bind::<Text, _>(&m.chat)
            .bind::<Text, _>(&m.stanza)
            .load::<RejectionRow>(conn)?
            .first()
    {
        m.details.get_or_insert_with(Details::default).rejection = Some(Rejection {
            code: r.code.clone(),
            timestamp: r.stamp,
        });
    }
    Ok(())
}
fn project(
    conn: &mut diesel::SqliteConnection,
    chat: &str,
    id: &str,
    origin: &str,
) -> QueryResult<()> {
    let rows=diesel::sql_query("SELECT payload FROM mk_messages WHERE chat=?1 AND json_extract(payload,'$.stanza')=?2 AND json_extract(payload,'$.outgoing')=1")
        .bind::<Text,_>(chat).bind::<Text,_>(id).load::<Row>(conn)?;
    for row in rows {
        let mut message: Message = serde_json::from_str(&row.payload)
            .map_err(|e| diesel::result::Error::DeserializationError(Box::new(e)))?;
        let old = message.clone();
        decorate(conn, &mut message)?;
        if old != message {
            Cache::insert(
                conn,
                Observation {
                    message,
                    origin: origin.into(),
                    history: true,
                    raw: vec![],
                    push_name: None,
                    notify: false,
                },
            )?;
        }
    }
    Ok(())
}
impl Cache {
    pub async fn receipt(
        &self,
        chat: &str,
        ids: &[String],
        sender: &str,
        level: i64,
        timestamp: i64,
    ) -> Result<(), &'static str> {
        if !(1..=4).contains(&level) || ids.len() > 256 {
            return Err("input");
        }
        let (chat, ids, sender) = (chat.to_owned(), ids.to_vec(), sender.to_owned());
        self.shared.run(move|conn|conn.transaction::<_,diesel::result::Error,_>(|conn| {
            for id in ids {
                diesel::sql_query("INSERT INTO mk_receipts(chat,stanza,sender,level,stamp) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(chat,stanza,sender) DO UPDATE SET level=excluded.level,stamp=excluded.stamp WHERE excluded.level>mk_receipts.level")
                    .bind::<Text,_>(&chat).bind::<Text,_>(&id).bind::<Text,_>(&sender).bind::<BigInt,_>(level).bind::<BigInt,_>(timestamp).execute(conn)?;
                project(conn,&chat,&id,&format!("receipt:{id}:{sender}:{level}"))?;
            } Ok(())
        }).map_err(db_error)).await.map_err(|_|"storage")?;
        self.mark_changed();
        Ok(())
    }
    pub async fn rejection(
        &self,
        chat: &str,
        id: &str,
        code: &str,
        timestamp: i64,
    ) -> Result<(), &'static str> {
        if code.is_empty()
            || code.len() > 64
            || !code
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        {
            return Err("input");
        }
        let (chat, id, code) = (chat.to_owned(), id.to_owned(), code.to_owned());
        self.shared.run(move|conn|conn.transaction::<_,diesel::result::Error,_>(|conn|{
            diesel::sql_query("INSERT INTO mk_rejections(chat,stanza,code,stamp) VALUES(?1,?2,?3,?4) ON CONFLICT(chat,stanza) DO UPDATE SET code=excluded.code,stamp=excluded.stamp WHERE excluded.stamp>mk_rejections.stamp")
                .bind::<Text,_>(&chat).bind::<Text,_>(&id).bind::<Text,_>(&code).bind::<BigInt,_>(timestamp).execute(conn)?;
            project(conn,&chat,&id,&format!("nack:{id}:{code}:{timestamp}"))
        }).map_err(db_error)).await.map_err(|_|"storage")?;
        self.mark_changed();
        Ok(())
    }
}
