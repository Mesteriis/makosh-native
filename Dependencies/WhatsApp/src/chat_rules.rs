use crate::cache::{Cache, Chat};
use diesel::{
    prelude::*,
    sql_types::{BigInt, Text},
};
#[derive(QueryableByName)]
struct Row {
    #[diesel(sql_type=Text)]
    payload: String,
}
pub enum ChatUpdate {
    Archive(bool),
    Pin(bool),
    Mute(i64),
    Read,
    Unread,
    Name(String),
}
impl ChatUpdate {
    fn field(&self) -> &str {
        match self {
            Self::Archive(_) => "archive",
            Self::Pin(_) => "pin",
            Self::Mute(_) => "mute",
            Self::Read | Self::Unread => "read",
            Self::Name(_) => "name",
        }
    }
}
impl Cache {
    pub async fn chat_update(&self, chat: &str, update: ChatUpdate) -> Result<(), &'static str> {
        self.chat_update_at(chat, update, None).await
    }
    pub async fn chat_update_at(
        &self,
        chat: &str,
        update: ChatUpdate,
        stamp: Option<i64>,
    ) -> Result<(), &'static str> {
        let chat = chat.to_owned();
        self.shared.run(move|conn|{
            conn.transaction::<_,diesel::result::Error,_>(|conn|{
                let rows=diesel::sql_query("SELECT payload FROM mk_chats WHERE id=?1").bind::<Text,_>(&chat).load::<Row>(conn)?;
                let mut value:Chat=if let Some(row)=rows.first(){serde_json::from_str(&row.payload).map_err(|e|diesel::result::Error::DeserializationError(Box::new(e)))?}else{Chat{id:chat.clone(),name:chat.clone(),timestamp:0,unread:0,archived:false,pinned:false,group:chat.ends_with("@g.us"),muted_until:None,settings_revision:0,settings_timestamps:Default::default()}};
                if let Some(stamp)=stamp {if value.settings_timestamps.get(update.field()).is_some_and(|old|*old>stamp){return Ok(())}value.settings_timestamps.insert(update.field().into(),stamp);}
                value.settings_revision=value.settings_revision.saturating_add(1);
                match update {ChatUpdate::Archive(on)=>{value.archived=on;if on{value.pinned=false}},ChatUpdate::Pin(on)=>value.pinned=on,ChatUpdate::Mute(until)=>value.muted_until=Some(until),ChatUpdate::Read=>value.unread=0,ChatUpdate::Unread=>value.unread=value.unread.max(1),ChatUpdate::Name(name)=>{Cache::write_name(conn,&chat,&name,false)?;value.name=name;}};
                let payload=serde_json::to_string(&value).map_err(|e|diesel::result::Error::SerializationError(Box::new(e)))?;
                diesel::sql_query("INSERT INTO mk_chats VALUES(?1,?2,?3) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload").bind::<Text,_>(&chat).bind::<BigInt,_>(value.timestamp).bind::<Text,_>(payload).execute(conn)?;Ok(())
            }).map_err(|e|whatsapp_rust::wacore::store::error::StoreError::Database(Box::new(e)))
        }).await.map_err(|_|"storage").map(|()|{self.mark_changed();})
    }
}
