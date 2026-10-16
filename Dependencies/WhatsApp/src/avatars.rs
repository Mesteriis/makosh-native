use serde_json::{Value, json};
use whatsapp_rust::ProfilePicture;
use whatsapp_rust::prelude::*;

fn descriptor(picture: ProfilePicture) -> Result<Value, &'static str> {
    if picture.id.is_empty()
        || picture.id.len() > 512
        || picture.url.is_empty()
        || picture.url.len() > 4096
    {
        return Err("input");
    }
    Ok(json!({"pictureID": picture.id, "url": picture.url}))
}
pub async fn execute(client: &Client, jid: &Jid) -> Result<Value, &'static str> {
    let picture = client
        .contacts()
        .get_profile_picture(jid, true)
        .await
        .map_err(|_| "unknown")?;
    let value = picture.map(descriptor).transpose()?;
    Ok(json!({"info": {"avatar": value}}))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn descriptor_keeps_sdk_identity_and_url_without_private_extra_fields() {
        let value = descriptor(ProfilePicture {
            id: "picture-42".into(),
            url: "https://pps.whatsapp.net/test".into(),
            direct_path: Some("private-path".into()),
            hash: Some("private-hash".into()),
        })
        .unwrap();
        assert_eq!(value["pictureID"], "picture-42");
        assert_eq!(value["url"], "https://pps.whatsapp.net/test");
        assert_eq!(value.as_object().unwrap().len(), 2);
        let serialized = value.to_string();
        assert!(!serialized.contains("private-path") && !serialized.contains("private-hash"));
    }
    #[test]
    fn descriptor_refuses_unbounded_or_empty_sdk_values() {
        for id in [String::new(), "x".repeat(513)] {
            assert!(
                descriptor(ProfilePicture {
                    id,
                    url: "https://pps.whatsapp.net/test".into(),
                    direct_path: None,
                    hash: None
                })
                .is_err()
            );
        }
    }
}
