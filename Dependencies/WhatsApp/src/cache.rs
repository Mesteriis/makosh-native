use diesel::connection::SimpleConnection;
use diesel::{
    prelude::*,
    sql_types::{BigInt, Binary, Text},
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use whatsapp_rust::wacore::store::error::StoreError;
use whatsapp_rust_sqlite_storage::{SharedSqlite, SqliteStore, SqliteStoreConfig, Synchronous};
use zeroize::Zeroizing;

fn db_error(e: diesel::result::Error) -> StoreError {
    StoreError::Database(Box::new(e))
}
#[derive(QueryableByName)]
struct Cipher {
    #[diesel(sql_type=Text)]
    cipher_version: String,
}
#[derive(QueryableByName)]
struct Payload {
    #[diesel(sql_type=Text)]
    payload: String,
}
#[derive(QueryableByName)]
struct Number {
    #[diesel(sql_type=BigInt,column_name=value)]
    _value: i64,
}
#[derive(QueryableByName)]
struct ChatRow {
    #[diesel(sql_type=BigInt)]
    value: i64,
    #[diesel(sql_type=Text)]
    payload: String,
}
#[derive(QueryableByName)]
struct JournalRow {
    #[diesel(sql_type=BigInt)]
    sequence: i64,
    #[diesel(sql_type=Text)]
    payload: String,
}
#[derive(Clone, Serialize, Deserialize, Debug, PartialEq)]
pub struct Chat {
    pub id: String,
    pub name: String,
    pub timestamp: i64,
    pub unread: i64,
    pub archived: bool,
    pub pinned: bool,
    pub group: bool,
    #[serde(default, rename = "mutedUntil")]
    pub muted_until: Option<i64>,
    #[serde(default, rename = "settingsRevision")]
    pub settings_revision: u64,
    #[serde(default, rename = "settingsTimestamps")]
    pub settings_timestamps: std::collections::BTreeMap<String, i64>,
}
#[derive(Clone, Serialize, Deserialize, Debug, PartialEq)]
pub struct Message {
    pub chat: String,
    pub id: String,
    pub stanza: String,
    pub sender: String,
    pub timestamp: i64,
    pub outgoing: bool,
    pub text: String,
    pub kind: String,
    pub edited: bool,
    pub deleted: bool,
    #[serde(default, rename = "versionTimestamp")]
    pub version_timestamp: i64,
    #[serde(default)]
    pub delivery: Option<i64>,
    #[serde(default)]
    pub details: Option<crate::presentation::Details>,
}
impl Message {
    fn version_order(&self) -> (i64, u8) {
        (
            if self.version_timestamp == 0 {
                self.timestamp.saturating_mul(1000)
            } else {
                self.version_timestamp
            },
            if self.deleted {
                2
            } else if self.edited {
                1
            } else {
                0
            },
        )
    }
}
#[derive(Clone)]
pub struct Observation {
    pub message: Message,
    pub origin: String,
    pub history: bool,
    pub raw: Vec<u8>,
    pub push_name: Option<String>,
    pub notify: bool,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct JournalEntry {
    pub sequence: i64,
    pub message: Message,
    pub history: bool,
    pub observed: i64,
    #[serde(default)]
    pub notify: Option<bool>,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Cursor {
    pub timestamp: i64,
    pub id: String,
}
#[derive(Clone)]
pub struct Cache {
    pub store: SqliteStore,
    pub(crate) shared: SharedSqlite,
    projection_revision: std::sync::Arc<std::sync::atomic::AtomicU64>,
}

impl Cache {
    pub fn revision(&self) -> u64 {
        self.projection_revision
            .load(std::sync::atomic::Ordering::Acquire)
    }
    pub(crate) fn mark_changed(&self) {
        self.projection_revision
            .fetch_add(1, std::sync::atomic::Ordering::AcqRel);
    }
    pub async fn open(path: &str, key: Vec<u8>) -> Result<Self, &'static str> {
        if key.len() != 32 {
            return Err("key");
        }
        let key = Zeroizing::new(key);
        let config = SqliteStoreConfig {
            synchronous: Synchronous::Full,
            busy_timeout: std::time::Duration::from_secs(5),
            ..Default::default()
        }
        .with_connection_init(move |conn| {
            let hex = Zeroizing::new(key.iter().map(|b| format!("{b:02x}")).collect::<String>());
            conn.batch_execute(&format!(
                "PRAGMA key = \"x'{}'\"; PRAGMA cipher_memory_security=ON;",
                hex.as_str()
            ))?;
            // SQLCipher must be present; an ignored key pragma is never acceptable.
            let cipher = diesel::sql_query("PRAGMA cipher_version").load::<Cipher>(conn)?;
            if cipher.first().is_none_or(|c| c.cipher_version.is_empty()) {
                return Err("cipher unavailable".into());
            }
            diesel::sql_query("SELECT count(*) AS value FROM sqlite_master")
                .load::<Number>(conn)?;
            Ok(())
        });
        let store = SqliteStore::with_config(path, config)
            .await
            .map_err(|_| "key_or_storage")?;
        let shared = store.shared();
        shared.run(|conn| {
            conn.batch_execute("CREATE TABLE IF NOT EXISTS mk_commands(attempt TEXT PRIMARY KEY,digest TEXT NOT NULL,state TEXT NOT NULL,result TEXT NOT NULL);").map_err(db_error)?;
            conn.batch_execute("CREATE TABLE IF NOT EXISTS mk_chats(id TEXT PRIMARY KEY,ts BIGINT NOT NULL,payload TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS mk_messages(chat TEXT NOT NULL,id TEXT NOT NULL,ts BIGINT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(chat,id));
                CREATE TABLE IF NOT EXISTS mk_receipts(chat TEXT NOT NULL,stanza TEXT NOT NULL,sender TEXT NOT NULL,level BIGINT NOT NULL,stamp BIGINT NOT NULL,PRIMARY KEY(chat,stanza,sender));
                CREATE TABLE IF NOT EXISTS mk_rejections(chat TEXT NOT NULL,stanza TEXT NOT NULL,code TEXT NOT NULL,stamp BIGINT NOT NULL,PRIMARY KEY(chat,stanza));
                CREATE TABLE IF NOT EXISTS mk_controls(chat TEXT NOT NULL,id TEXT NOT NULL,field TEXT NOT NULL,actor TEXT NOT NULL,value TEXT NOT NULL,stamp BIGINT NOT NULL,PRIMARY KEY(chat,id,field,actor));
                CREATE TABLE IF NOT EXISTS mk_poll_votes(chat TEXT NOT NULL,id TEXT NOT NULL,actor TEXT NOT NULL,payload TEXT NOT NULL,stamp BIGINT NOT NULL,PRIMARY KEY(chat,id,actor));
                CREATE TABLE IF NOT EXISTS mk_names(id TEXT PRIMARY KEY,name TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS mk_message_page ON mk_messages(chat,ts DESC,id DESC);
                CREATE TABLE IF NOT EXISTS mk_journal(sequence INTEGER PRIMARY KEY AUTOINCREMENT,token TEXT NOT NULL UNIQUE,payload TEXT NOT NULL,raw BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS mk_checkpoint(id INTEGER PRIMARY KEY CHECK(id=1),sequence BIGINT NOT NULL);
                INSERT OR IGNORE INTO mk_checkpoint VALUES(1,0);
                CREATE TRIGGER IF NOT EXISTS mk_journal_no_update BEFORE UPDATE ON mk_journal BEGIN SELECT RAISE(ABORT,'append only'); END;
                CREATE TRIGGER IF NOT EXISTS mk_journal_no_delete BEFORE DELETE ON mk_journal BEGIN SELECT RAISE(ABORT,'append only'); END;") .map_err(db_error)
        }).await.map_err(|_| "storage")?;
        Ok(Self {
            store,
            shared,
            projection_revision: Default::default(),
        })
    }
    #[cfg(test)]
    pub async fn reject_new_journal_rows(&self) {
        self.shared.run(|conn|conn.batch_execute("CREATE TRIGGER fail_journal BEFORE INSERT ON mk_journal BEGIN SELECT RAISE(ABORT,'test failure'); END;").map_err(db_error)).await.unwrap();
    }
    fn write_chats(conn: &mut diesel::SqliteConnection, chats: Vec<Chat>) -> QueryResult<()> {
        for mut chat in chats {
            if let Some(row) = diesel::sql_query("SELECT payload FROM mk_chats WHERE id=?1")
                .bind::<Text, _>(&chat.id)
                .load::<Payload>(conn)?
                .first()
            {
                let old: Chat = serde_json::from_str(&row.payload)
                    .map_err(|e| diesel::result::Error::DeserializationError(Box::new(e)))?;
                if old.settings_revision > 0 {
                    chat.archived = old.archived;
                    chat.pinned = old.pinned;
                    chat.muted_until = old.muted_until;
                    chat.unread = old.unread;
                    chat.settings_revision = old.settings_revision;
                    chat.settings_timestamps = old.settings_timestamps;
                }
            }
            let payload = serde_json::to_string(&chat)
                .map_err(|e| diesel::result::Error::SerializationError(Box::new(e)))?;
            diesel::sql_query("INSERT INTO mk_chats VALUES(?1,?2,?3) ON CONFLICT(id) DO UPDATE SET ts=excluded.ts,payload=excluded.payload WHERE excluded.ts>=mk_chats.ts")
                .bind::<Text,_>(chat.id).bind::<BigInt,_>(chat.timestamp).bind::<Text,_>(payload).execute(conn)?;
        }
        Ok(())
    }
    pub async fn ingest_history(
        &self,
        rows: Vec<Observation>,
        chats: Vec<Chat>,
        names: Vec<(String, String)>,
    ) -> Result<(), &'static str> {
        self.shared
            .run(move |conn| {
                conn.transaction::<_, diesel::result::Error, _>(|conn| {
                    Self::write_chats(conn, chats)?;
                    for (id, name) in names {
                        Self::write_name(conn, &id, &name, true)?;
                    }
                    for row in rows {
                        Self::insert(conn, row)?;
                    }
                    Ok(())
                })
                .map_err(db_error)
            })
            .await
            .map_err(|_| "storage")
            .map(|()| {
                self.mark_changed();
            })
    }
    pub(crate) fn write_name(
        conn: &mut diesel::SqliteConnection,
        id: &str,
        name: &str,
        history: bool,
    ) -> QueryResult<()> {
        if name.is_empty() || id.ends_with("@g.us") {
            return Ok(());
        }
        let sql = if history {
            "INSERT INTO mk_names VALUES(?1,?2) ON CONFLICT(id) DO NOTHING"
        } else {
            "INSERT INTO mk_names VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET name=excluded.name"
        };
        diesel::sql_query(sql)
            .bind::<Text, _>(id)
            .bind::<Text, _>(name)
            .execute(conn)?;
        let rows = diesel::sql_query("SELECT payload FROM mk_chats WHERE id=?1")
            .bind::<Text, _>(id)
            .load::<Payload>(conn)?;
        if let Some(row) = rows.first() {
            let mut chat: Chat = serde_json::from_str(&row.payload)
                .map_err(|e| diesel::result::Error::DeserializationError(Box::new(e)))?;
            chat.name = diesel::sql_query("SELECT name AS payload FROM mk_names WHERE id=?1")
                .bind::<Text, _>(id)
                .load::<Payload>(conn)?[0]
                .payload
                .clone();
            let value = serde_json::to_string(&chat)
                .map_err(|e| diesel::result::Error::SerializationError(Box::new(e)))?;
            diesel::sql_query("UPDATE mk_chats SET payload=?2 WHERE id=?1")
                .bind::<Text, _>(id)
                .bind::<Text, _>(value)
                .execute(conn)?;
        }
        Ok(())
    }
    pub async fn ingest(&self, observations: Vec<Observation>) -> Result<(), &'static str> {
        self.shared
            .run(move |conn| {
                conn.transaction::<_, diesel::result::Error, _>(|conn| {
                    for observation in observations {
                        Self::insert(conn, observation)?;
                    }
                    Ok(())
                })
                .map_err(db_error)
            })
            .await
            .map_err(|_| "storage")
            .map(|()| {
                self.mark_changed();
            })
    }
    pub(crate) fn insert(
        conn: &mut diesel::SqliteConnection,
        observation: Observation,
    ) -> QueryResult<()> {
        let Observation {
            mut message,
            origin,
            history,
            raw,
            push_name,
            notify,
        } = observation;
        let encode = |v: &Message| {
            serde_json::to_string(v)
                .map_err(|e| diesel::result::Error::SerializationError(Box::new(e)))
        };
        let fingerprint = encode(&message)?;
        let mut hash = Sha256::new();
        hash.update(Sha256::digest(&raw));
        hash.update(
            serde_json::to_vec(&(&message.chat, &message.sender, &origin, &fingerprint))
                .map_err(|e| diesel::result::Error::SerializationError(Box::new(e)))?,
        );
        let token = format!("{:x}", hash.finalize());
        if !diesel::sql_query("SELECT payload FROM mk_journal WHERE token=?1")
            .bind::<Text, _>(&token)
            .load::<Payload>(conn)?
            .is_empty()
        {
            return Ok(());
        }
        let previous = diesel::sql_query("SELECT payload FROM mk_messages WHERE chat=?1 AND id=?2")
            .bind::<Text, _>(&message.chat)
            .bind::<Text, _>(&message.id)
            .load::<Payload>(conn)?;
        let mut project = true;
        if let Some(previous) = previous.first() {
            let old: Message = serde_json::from_str(&previous.payload)
                .map_err(|e| diesel::result::Error::DeserializationError(Box::new(e)))?;
            project = message.version_order() >= old.version_order();
            if let Some(previous) = old.delivery {
                message.delivery = Some(message.delivery.unwrap_or(0).max(previous));
            }
            if let Some(details) = &mut message.details
                && let Some(old_details) = &old.details
            {
                for receipt in &old_details.receipts {
                    if details
                        .receipts
                        .iter()
                        .all(|r| r.sender != receipt.sender || r.level < receipt.level)
                    {
                        details.receipts.retain(|r| r.sender != receipt.sender);
                        details.receipts.push(receipt.clone());
                    }
                }
            }
            if message.deleted || message.edited {
                if message.edited
                    && message
                        .details
                        .as_ref()
                        .is_none_or(|d| d.resource_id.is_none())
                    && old
                        .details
                        .as_ref()
                        .is_some_and(|d| d.resource_id.is_some())
                {
                    message.details = old.details.clone();
                }
                if message.deleted {
                    message.text = old.text;
                    message.edited = old.edited;
                }
                message.kind = old.kind;
                message.timestamp = old.timestamp;
                message.outgoing = old.outgoing;
                if message.deleted {
                    message.details = old.details;
                }
            }
        }
        crate::receipts::decorate(conn, &mut message)?;
        crate::controls::decorate(conn, &mut message)?;
        let journal=serde_json::to_string(&serde_json::json!({"message":message,"history":history,"notify":notify,"observed":std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|v|v.as_secs() as i64).unwrap_or(0)})).map_err(|e| diesel::result::Error::SerializationError(Box::new(e)))?;
        diesel::sql_query("INSERT INTO mk_journal(token,payload,raw) VALUES(?1,?2,?3)")
            .bind::<Text, _>(token)
            .bind::<Text, _>(journal)
            .bind::<Binary, _>(&raw)
            .execute(conn)?;
        // Keep protocol envelopes durably, without inventing user messages or
        // a self-chat from pairing/history/PDO control traffic.
        crate::controls::record(
            conn,
            &Observation {
                message: message.clone(),
                origin,
                history,
                raw: raw.clone(),
                push_name: None,
                notify: false,
            },
        )?;
        crate::receipts::decorate(conn, &mut message)?;
        crate::controls::decorate(conn, &mut message)?;
        let payload = encode(&message)?;
        if message.kind == "protocol" {
            return Ok(());
        }
        if project {
            diesel::sql_query("INSERT INTO mk_messages VALUES(?1,?2,?3,?4) ON CONFLICT(chat,id) DO UPDATE SET ts=excluded.ts,payload=excluded.payload")
                .bind::<Text,_>(&message.chat).bind::<Text,_>(&message.id).bind::<BigInt,_>(message.timestamp).bind::<Text,_>(payload).execute(conn)?;
        }
        let old_chat = diesel::sql_query("SELECT ts AS value,payload FROM mk_chats WHERE id=?1")
            .bind::<Text, _>(&message.chat)
            .load::<ChatRow>(conn)?;
        let mut chat = if let Some(row) = old_chat.first() {
            let mut c: Chat = serde_json::from_str(&row.payload)
                .map_err(|e| diesel::result::Error::DeserializationError(Box::new(e)))?;
            c.timestamp = row.value;
            c
        } else {
            Chat {
                id: message.chat.clone(),
                name: message.chat.clone(),
                timestamp: message.timestamp,
                unread: 0,
                archived: false,
                pinned: false,
                group: message.chat.ends_with("@g.us"),
                muted_until: None,
                settings_revision: 0,
                settings_timestamps: Default::default(),
            }
        };
        chat.timestamp = chat.timestamp.max(message.timestamp);
        if !history
            && previous.is_empty()
            && !message.outgoing
            && !message.edited
            && !message.deleted
        {
            chat.unread = chat.unread.saturating_add(1);
        }
        if !message.outgoing
            && let Some(name) = push_name
        {
            Self::write_name(conn, &message.sender, &name, history)?;
        }
        if !chat.group
            && let Some(name) =
                diesel::sql_query("SELECT name AS payload FROM mk_names WHERE id=?1")
                    .bind::<Text, _>(&chat.id)
                    .load::<Payload>(conn)?
                    .first()
        {
            chat.name = name.payload.clone();
        }
        let value = serde_json::to_string(&chat)
            .map_err(|e| diesel::result::Error::SerializationError(Box::new(e)))?;
        diesel::sql_query("INSERT INTO mk_chats VALUES(?1,?2,?3) ON CONFLICT(id) DO UPDATE SET ts=excluded.ts,payload=excluded.payload")
            .bind::<Text,_>(chat.id).bind::<BigInt,_>(chat.timestamp).bind::<Text,_>(value).execute(conn)?;
        Ok(())
    }
    pub async fn chats(
        &self,
        before: Option<Cursor>,
        limit: i64,
    ) -> Result<Vec<Chat>, &'static str> {
        self.shared.read(move |conn| {
            let cursor=before.unwrap_or(Cursor{timestamp:i64::MAX,id:String::new()});
            let rows=diesel::sql_query("SELECT ts AS value,payload FROM mk_chats WHERE ts<?1 OR (ts=?1 AND id<?2) ORDER BY ts DESC,id DESC LIMIT ?3")
                .bind::<BigInt,_>(cursor.timestamp).bind::<Text,_>(cursor.id).bind::<BigInt,_>(limit).load::<ChatRow>(conn).map_err(db_error)?;
            rows.into_iter().map(|r| { let mut chat:Chat=serde_json::from_str(&r.payload).map_err(|e|StoreError::Database(Box::new(e)))?;chat.timestamp=r.value;Ok(chat) }).collect()
        }).await.map_err(|_|"storage")
    }
    pub async fn messages(
        &self,
        chat: String,
        before: Option<Cursor>,
        limit: i64,
    ) -> Result<Vec<Message>, &'static str> {
        self.shared.read(move |conn| {
            let cursor=before.unwrap_or(Cursor{timestamp:i64::MAX,id:String::new()});
            let rows=diesel::sql_query("SELECT payload FROM mk_messages WHERE chat=?1 AND (ts<?2 OR (ts=?2 AND id<?3)) ORDER BY ts DESC,id DESC LIMIT ?4")
                .bind::<Text,_>(chat).bind::<BigInt,_>(cursor.timestamp).bind::<Text,_>(cursor.id).bind::<BigInt,_>(limit).load::<Payload>(conn).map_err(db_error)?;
            rows.into_iter().map(|r|serde_json::from_str(&r.payload).map_err(|e|StoreError::Database(Box::new(e)))).collect()
        }).await.map_err(|_|"storage")
    }
    pub async fn journal(&self, limit: i64) -> Result<Vec<JournalEntry>, &'static str> {
        self.shared.read(move |conn| {
            let rows=diesel::sql_query("SELECT sequence,payload FROM mk_journal WHERE sequence>(SELECT sequence FROM mk_checkpoint WHERE id=1) ORDER BY sequence LIMIT ?1")
                .bind::<BigInt,_>(limit).load::<JournalRow>(conn).map_err(db_error)?;
            rows.into_iter().map(|r| { let mut v:serde_json::Value=serde_json::from_str(&r.payload).map_err(|e|StoreError::Database(Box::new(e)))?; v["sequence"]=r.sequence.into(); serde_json::from_value(v).map_err(|e|StoreError::Database(Box::new(e))) }).collect()
        }).await.map_err(|_|"storage")
    }
    pub async fn ack(&self, sequence: i64) -> Result<(), &'static str> {
        self.shared
            .run(move |conn| {
                diesel::sql_query("UPDATE mk_checkpoint SET sequence=MAX(sequence,?1) WHERE id=1")
                    .bind::<BigInt, _>(sequence)
                    .execute(conn)
                    .map_err(db_error)
            })
            .await
            .map(|_| ())
            .map_err(|_| "storage")
    }
}
