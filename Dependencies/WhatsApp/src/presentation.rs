use serde::{Deserialize, Serialize};
use whatsapp_rust::prelude::*;
use whatsapp_rust::waproto::whatsapp as wa;

#[derive(Clone, Default, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Details {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rejection: Option<Rejection>,
    #[serde(rename = "resourceID")]
    pub resource_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub protected: Option<bool>,
    pub name: Option<String>,
    pub mime: Option<String>,
    pub size: Option<u64>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub seconds: Option<u32>,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    pub quoted_id: Option<String>,
    pub quoted_text: Option<String>,
    pub quoted_sender: Option<String>,
    pub contact_name: Option<String>,
    pub contact_vcard: Option<String>,
    pub poll_name: Option<String>,
    pub poll_options: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub poll_votes: Option<Vec<PollVote>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub poll_creator: Option<String>,
    pub receipts: Vec<Receipt>,
    pub starred: Option<bool>,
    pub pinned: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reactions: Option<Vec<Reaction>>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PollVote {
    pub sender: String,
    pub options: Vec<String>,
    pub timestamp: i64,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Reaction {
    pub sender: String,
    pub text: String,
    pub timestamp: i64,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Receipt {
    pub sender: String,
    pub level: i64,
    pub timestamp: i64,
}
pub fn details(body: &wa::Message) -> Details {
    use sha2::{Digest, Sha256};
    let base = body.get_base_message();
    let base = base
        .protocol_message
        .as_option()
        .and_then(|p| p.edited_message.as_option())
        .unwrap_or(base);
    let mut d = Details::default();
    if body.is_view_once() {
        d.protected = Some(true)
    }
    let resource = if let Some(m) = base.image_message.as_option() {
        Some((
            "image",
            m.media_key.as_deref(),
            m.file_sha256.as_deref(),
            m.file_enc_sha256.as_deref(),
            m.direct_path.as_deref(),
        ))
    } else if let Some(m) = base
        .video_message
        .as_option()
        .or(base.ptv_message.as_option())
    {
        Some((
            "video",
            m.media_key.as_deref(),
            m.file_sha256.as_deref(),
            m.file_enc_sha256.as_deref(),
            m.direct_path.as_deref(),
        ))
    } else if let Some(m) = base.document_message.as_option() {
        Some((
            "document",
            m.media_key.as_deref(),
            m.file_sha256.as_deref(),
            m.file_enc_sha256.as_deref(),
            m.direct_path.as_deref(),
        ))
    } else if let Some(m) = base.audio_message.as_option() {
        Some((
            "audio",
            m.media_key.as_deref(),
            m.file_sha256.as_deref(),
            m.file_enc_sha256.as_deref(),
            m.direct_path.as_deref(),
        ))
    } else {
        base.sticker_message.as_option().map(|m| {
            (
                "sticker",
                m.media_key.as_deref(),
                m.file_sha256.as_deref(),
                m.file_enc_sha256.as_deref(),
                m.direct_path.as_deref(),
            )
        })
    };
    if let Some((kind, key, hash, encrypted, path)) = resource
        && let Ok(bytes) = serde_json::to_vec(&(
            kind,
            key,
            hash,
            encrypted,
            if key.is_none() && hash.is_none() {
                path
            } else {
                None
            },
        ))
    {
        d.resource_id = Some(format!("{:x}", Sha256::digest(bytes)));
    }
    let context = if let Some(m) = base.document_message.as_option() {
        d.name = m.file_name.clone();
        d.mime = m.mimetype.clone();
        d.size = m.file_length;
        m.context_info.as_option()
    } else if let Some(m) = base.image_message.as_option() {
        d.mime = m.mimetype.clone();
        d.size = m.file_length;
        d.width = m.width;
        d.height = m.height;
        m.context_info.as_option()
    } else if let Some(m) = base
        .video_message
        .as_option()
        .or(base.ptv_message.as_option())
    {
        d.mime = m.mimetype.clone();
        d.size = m.file_length;
        d.width = m.width;
        d.height = m.height;
        d.seconds = m.seconds;
        m.context_info.as_option()
    } else if let Some(m) = base.audio_message.as_option() {
        d.mime = m.mimetype.clone();
        d.size = m.file_length;
        d.seconds = m.seconds;
        m.context_info.as_option()
    } else if let Some(m) = base.sticker_message.as_option() {
        d.mime = m.mimetype.clone();
        d.size = m.file_length;
        d.width = m.width;
        d.height = m.height;
        m.context_info.as_option()
    } else if let Some(m) = base.location_message.as_option() {
        d.latitude = m.degrees_latitude;
        d.longitude = m.degrees_longitude;
        d.name = m.name.clone();
        m.context_info.as_option()
    } else if let Some(m) = base.contact_message.as_option() {
        d.contact_name = m.display_name.clone();
        d.contact_vcard = m.vcard.clone();
        m.context_info.as_option()
    } else if let Some(m) = base
        .poll_creation_message
        .as_option()
        .or(base.poll_creation_message_v2.as_option())
        .or(base.poll_creation_message_v3.as_option())
    {
        d.poll_name = m.name.clone();
        d.poll_options = m
            .options
            .iter()
            .filter_map(|o| o.option_name.clone())
            .collect();
        m.context_info.as_option()
    } else {
        base.extended_text_message
            .as_option()
            .and_then(|m| m.context_info.as_option())
    };
    if let Some(c) = context {
        d.quoted_id = c.stanza_id.clone();
        d.quoted_sender = c.participant.clone();
        d.quoted_text = c
            .quoted_message
            .as_option()
            .and_then(|q| q.text_content())
            .map(str::to_owned);
    }
    d
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Rejection {
    pub code: String,
    pub timestamp: i64,
}
