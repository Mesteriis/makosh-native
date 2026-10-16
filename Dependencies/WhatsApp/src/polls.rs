// Poll wire construction follows whatsapp-rust 0.7.0 (MIT; SDK notice retained).
use whatsapp_rust::{
    prelude::*,
    waproto::{buffa::MessageField, whatsapp as wa},
};
pub fn creation(
    name: &str,
    options: &[String],
    secret: &[u8],
) -> Result<wa::Message, &'static str> {
    if name.trim().is_empty()
        || !(2..=12).contains(&options.len())
        || secret.len() != 32
        || options.iter().any(|o| o.trim().is_empty())
        || options
            .iter()
            .collect::<std::collections::HashSet<_>>()
            .len()
            != options.len()
    {
        return Err("input");
    }
    Ok(wa::Message {
        poll_creation_message_v3: MessageField::some(wa::message::PollCreationMessage {
            name: Some(name.into()),
            options: options
                .iter()
                .map(|o| wa::message::poll_creation_message::Option {
                    option_name: Some(o.clone()),
                    option_hash: None,
                })
                .collect(),
            selectable_options_count: Some(1),
            poll_content_type: Some(wa::message::PollContentType::TEXT),
            ..Default::default()
        }),
        message_context_info: MessageField::some(wa::MessageContextInfo {
            message_secret: Some(secret.to_vec()),
            ..Default::default()
        }),
        ..Default::default()
    })
}
pub fn new_creation(name: &str, options: &[String]) -> Result<wa::Message, &'static str> {
    let mut secret = zeroize::Zeroizing::new([0u8; 32]);
    // SAFETY: getentropy receives exactly the owned 32-byte writable buffer;
    // macOS supports this cryptographic source and the error is checked.
    if unsafe { libc::getentropy(secret.as_mut_ptr().cast(), secret.len()) } != 0 {
        return Err("storage");
    }
    creation(name, options, secret.as_slice())
}
pub async fn vote(
    client: &Client,
    cache: &crate::cache::Cache,
    chat: &str,
    a: &crate::commands::Action,
) -> Result<serde_json::Value, &'static str> {
    use whatsapp_rust::waproto::buffa::Message as _;
    let (row, raw) = cache.stored_message(chat, &a.target).await?;
    if row.deleted {
        return Err("input");
    }
    let body = wa::Message::decode_from_slice(&raw).map_err(|_| "input")?;
    let base = body.get_base_message();
    let poll = base
        .poll_creation_message_v3
        .as_option()
        .or(base.poll_creation_message_v2.as_option())
        .or(base.poll_creation_message.as_option())
        .ok_or("input")?;
    let labels: Vec<&str> = poll
        .options
        .iter()
        .filter_map(|o| o.option_name.as_deref())
        .collect();
    if a.options.len() > poll.selectable_options_count.unwrap_or(1) as usize
        || a.options.iter().any(|o| !labels.contains(&o.as_str()))
    {
        return Err("input");
    }
    let secret: &[u8] = base
        .message_context_info
        .message_secret
        .as_ref()
        .map(|s| s.as_ref())
        .ok_or("input")?;
    let creator = if row.outgoing {
        if chat.ends_with("@g.us")
            && client
                .groups()
                .get_metadata(&chat.parse::<Jid>().map_err(|_| "input")?)
                .await
                .map_err(|_| "unknown")?
                .addressing_mode
                == whatsapp_rust::wacore::types::message::AddressingMode::Lid
        {
            client.lid().ok_or("offline")?
        } else {
            client.pn().ok_or("offline")?
        }
    } else {
        row.sender.parse::<Jid>().map_err(|_| "input")?
    };
    let result = client
        .polls()
        .vote(
            chat.parse::<Jid>().map_err(|_| "input")?,
            &row.stanza,
            &creator,
            secret,
            &a.options,
        )
        .await
        .map_err(|_| "unknown")?;
    Ok(serde_json::json!({"stanza":result.message_id.to_string()}))
}
