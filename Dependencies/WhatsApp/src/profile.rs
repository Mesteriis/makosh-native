// Explicit settings/group workflows from the reviewed Zen basis. Remote
// operations never delete Makosh history or rewrite a source identity.
use crate::{cache::Cache, commands::Action};
use serde_json::{Value, json};
use whatsapp_rust::wacore::iq::privacy::{PrivacyCategory, PrivacyValue};
use whatsapp_rust::{
    GroupCreateOptions, GroupDescription, GroupParticipantOptions, PreviousDescription, prelude::*,
};
pub fn handles(op: &str) -> bool {
    [
        "block",
        "profile",
        "user_info",
        "avatar",
        "privacy",
        "privacy_set",
        "set_name",
        "set_about",
        "group_info",
        "group_name",
        "group_about",
        "group_update",
        "group_create",
        "group_leave",
        "group_link",
        "ephemeral",
    ]
    .contains(&op)
}
pub fn privacy_pair(
    category: &str,
    value: &str,
) -> Result<(PrivacyCategory, PrivacyValue), &'static str> {
    let c = match category {
        "last" => PrivacyCategory::Last,
        "online" => PrivacyCategory::Online,
        "profile" => PrivacyCategory::Profile,
        "status" => PrivacyCategory::Status,
        "groupadd" => PrivacyCategory::GroupAdd,
        "readreceipts" => PrivacyCategory::ReadReceipts,
        "calladd" => PrivacyCategory::CallAdd,
        _ => return Err("input"),
    };
    let v = match value {
        "all" => PrivacyValue::All,
        "contacts" => PrivacyValue::Contacts,
        "none" => PrivacyValue::None,
        "match_last_seen" => PrivacyValue::MatchLastSeen,
        "known" => PrivacyValue::Known,
        _ => return Err("input"),
    };
    if !c.is_valid_value(&v) {
        return Err("input");
    }
    Ok((c, v))
}
pub async fn execute(
    client: &Client,
    cache: &Cache,
    chat: &str,
    a: &Action,
) -> Result<Value, &'static str> {
    let jid: Jid = chat.parse().map_err(|_| "input")?;
    match a.op.as_str() {
        "avatar" => return crate::avatars::execute(client, &jid).await,
        "profile" | "user_info" => {
            let who = if a.op == "profile" {
                client.lid().or_else(|| client.pn()).ok_or("offline")?
            } else {
                jid
            };
            let infos = client
                .contacts()
                .get_user_info(std::slice::from_ref(&who))
                .await
                .map_err(|_| "unknown")?;
            let about = infos
                .into_values()
                .next()
                .and_then(|v| v.status)
                .unwrap_or_default();
            let blocked = client
                .blocking()
                .is_blocked(&who)
                .await
                .map_err(|_| "unknown")?;
            return Ok(
                json!({"info":{"name":if a.op=="profile"{client.push_name()}else{String::new()},"about":about,"jid":who.to_non_ad().to_string(),"blocked":blocked}}),
            );
        }
        "block" => {
            if a.on {
                client.blocking().block(&jid).await
            } else {
                client.blocking().unblock(&jid).await
            }
            .map_err(|_| "unknown")?;
        }
        "set_name" => client
            .profile()
            .set_push_name(a.text.trim())
            .await
            .map_err(|_| "unknown")?,
        "set_about" => client
            .profile()
            .set_status_text(a.text.trim())
            .await
            .map_err(|_| "unknown")?,
        "privacy" => {
            let settings = client
                .fetch_privacy_settings()
                .await
                .map_err(|_| "unknown")?;
            let rules: std::collections::BTreeMap<String, String> = settings
                .settings
                .iter()
                .map(|v| (v.category.as_str().to_owned(), v.value.as_str().to_owned()))
                .collect();
            return Ok(json!({"info":{"rules":rules}}));
        }
        "privacy_set" => {
            let (c, v) = privacy_pair(&a.category, &a.value)?;
            client
                .set_privacy_setting(c, v)
                .await
                .map_err(|_| "unknown")?;
        }
        "group_info" => {
            let group = client
                .groups()
                .get_metadata(&jid)
                .await
                .map_err(|_| "unknown")?;
            let own = [client.lid(), client.pn()];
            cache
                .chat_update(
                    chat,
                    crate::chat_rules::ChatUpdate::Name(group.subject.clone()),
                )
                .await?;
            let members:Vec<Value>=group.participants.iter().map(|p|json!({"jid":p.jid.to_non_ad().to_string(),"admin":p.is_admin(),"me":own.iter().flatten().any(|j|j.to_non_ad()==p.jid.to_non_ad())})).collect();
            return Ok(
                json!({"info":{"jid":group.id.to_non_ad().to_string(),"name":group.subject,"about":group.description.unwrap_or_default(),"members":members,"locked":group.is_locked,"announce":group.is_announcement}}),
            );
        }
        "group_name" => {
            client
                .groups()
                .set_subject(
                    jid,
                    whatsapp_rust::wacore::iq::groups::GroupSubject::new(&a.text)
                        .map_err(|_| "input")?,
                )
                .await
                .map_err(|_| "unknown")?;
            cache
                .chat_update(chat, crate::chat_rules::ChatUpdate::Name(a.text.clone()))
                .await?;
        }
        "group_about" => {
            let description = if a.text.trim().is_empty() {
                None
            } else {
                Some(GroupDescription::new(a.text.trim()).map_err(|_| "input")?)
            };
            client
                .groups()
                .set_description(jid, description, PreviousDescription::Resolve)
                .await
                .map_err(|_| "unknown")?;
        }
        "group_update" => {
            let member: Jid = a.target.parse().map_err(|_| "input")?;
            let groups = client.groups();
            let results = match a.category.as_str() {
                "add" => groups.add_participants(jid, &[member]).await,
                "remove" => groups.remove_participants(jid, &[member]).await,
                "promote" => groups.promote_participants(jid, &[member]).await,
                "demote" => groups.demote_participants(jid, &[member]).await,
                _ => return Err("input"),
            }
            .map_err(|_| "unknown")?;
            if results.is_empty() || results.iter().any(|r| !r.is_ok()) {
                return Err("remote_rejected");
            }
        }
        "group_create" => {
            let participants = a
                .mentions
                .iter()
                .map(|s| {
                    s.parse::<Jid>()
                        .map(|jid| GroupParticipantOptions::builder().jid(jid).finish())
                        .map_err(|_| "input")
                })
                .collect::<Result<Vec<_>, _>>()?;
            let options = GroupCreateOptions::builder()
                .subject(a.text.trim())
                .participants(participants)
                .build();
            let group = client
                .groups()
                .create_group(options)
                .await
                .map_err(|_| "unknown")?;
            cache
                .chat_update(
                    &group.metadata.id.to_non_ad().to_string(),
                    crate::chat_rules::ChatUpdate::Name(group.metadata.subject.clone()),
                )
                .await?;
            return Ok(
                json!({"info":{"jid":group.metadata.id.to_non_ad().to_string(),"name":group.metadata.subject}}),
            );
        }
        "group_leave" => client.groups().leave(jid).await.map_err(|_| "unknown")?,
        "group_link" => {
            let url = client
                .groups()
                .get_invite_link(jid, false)
                .await
                .map_err(|_| "unknown")?;
            return Ok(json!({"info":{"link":url}}));
        }
        "ephemeral" => {
            if chat.ends_with("@g.us") {
                client
                    .groups()
                    .set_ephemeral(jid, a.duration as u32)
                    .await
                    .map_err(|_| "unknown")?;
            } else {
                client
                    .set_chat_disappearing_timer(jid, a.duration as u32)
                    .await
                    .map_err(|_| "unknown")?;
            }
        }
        _ => return Err("command"),
    }
    Ok(Value::Null)
}
