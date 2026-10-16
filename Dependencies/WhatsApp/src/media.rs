use crate::{cache::Cache, commands::Action};
use std::{
    fs::{File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::Path,
};
use whatsapp_rust::waproto::{
    buffa::{Message as _, MessageField},
    whatsapp as wa,
};
use whatsapp_rust::{
    download::{DownloadWriter, Downloadable, MediaType},
    prelude::*,
    upload::UploadOptions,
};
pub const MAX_FILE: u64 = 100 * 1024 * 1024;
fn private_parent(path: &Path) -> Result<(), &'static str> {
    if !path.is_absolute() {
        return Err("input");
    }
    let parent = path.parent().ok_or("input")?;
    let m = parent.symlink_metadata().map_err(|_| "input")?;
    if !m.is_dir()
        || m.file_type().is_symlink()
        || m.mode() & 0o077 != 0
        || m.uid() != unsafe { libc::geteuid() }
    {
        return Err("input");
    }
    Ok(())
}
pub fn read_private(path: &str) -> Result<Vec<u8>, &'static str> {
    let path = Path::new(path);
    private_parent(path)?;
    let mut f = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| "input")?;
    let before = f.metadata().map_err(|_| "input")?;
    if !before.is_file()
        || before.len() > MAX_FILE
        || before.mode() & 0o077 != 0
        || before.uid() != unsafe { libc::geteuid() }
        || before.nlink() != 1
    {
        return Err("input");
    }
    let mut bytes = Vec::new();
    std::io::Read::by_ref(&mut f)
        .take(MAX_FILE + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "input")?;
    let after = f.metadata().map_err(|_| "input")?;
    if bytes.len() as u64 != before.len()
        || after.len() != before.len()
        || after.mtime() != before.mtime()
        || after.mtime_nsec() != before.mtime_nsec()
        || after.ctime() != before.ctime()
        || after.ctime_nsec() != before.ctime_nsec()
    {
        return Err("input");
    }
    Ok(bytes)
}
pub async fn upload(client: &Client, a: &Action) -> Result<wa::Message, &'static str> {
    let bytes = read_private(&a.path)?;
    let kind = match a.kind.as_str() {
        "image" => MediaType::Image,
        "video" => MediaType::Video,
        "audio" => MediaType::Audio,
        "sticker" => MediaType::Image,
        "document" => MediaType::Document,
        _ => return Err("input"),
    };
    let up = client
        .upload(bytes, kind, UploadOptions::default())
        .await
        .map_err(|_| "unknown")?;
    let caption = (!a.text.is_empty()).then(|| a.text.clone());
    let body = match a.kind.as_str() {
        "image" => wa::Message {
            image_message: MessageField::some(wa::message::ImageMessage {
                url: Some(up.url),
                direct_path: Some(up.direct_path),
                media_key: Some(up.media_key.to_vec()),
                mimetype: Some(a.mime.clone()),
                file_enc_sha256: Some(up.file_enc_sha256.to_vec()),
                file_sha256: Some(up.file_sha256.to_vec()),
                file_length: Some(up.file_length),
                caption,
                ..Default::default()
            }),
            ..Default::default()
        },
        "video" => wa::Message {
            video_message: MessageField::some(wa::message::VideoMessage {
                url: Some(up.url),
                direct_path: Some(up.direct_path),
                media_key: Some(up.media_key.to_vec()),
                mimetype: Some(a.mime.clone()),
                file_enc_sha256: Some(up.file_enc_sha256.to_vec()),
                file_sha256: Some(up.file_sha256.to_vec()),
                file_length: Some(up.file_length),
                caption,
                ..Default::default()
            }),
            ..Default::default()
        },
        "audio" => wa::Message {
            audio_message: MessageField::some(wa::message::AudioMessage {
                url: Some(up.url),
                direct_path: Some(up.direct_path),
                media_key: Some(up.media_key.to_vec()),
                mimetype: Some(a.mime.clone()),
                file_enc_sha256: Some(up.file_enc_sha256.to_vec()),
                file_sha256: Some(up.file_sha256.to_vec()),
                file_length: Some(up.file_length),
                ptt: Some(a.on),
                seconds: Some(a.duration.clamp(0, 600) as u32),
                ..Default::default()
            }),
            ..Default::default()
        },
        "sticker" => wa::Message {
            sticker_message: MessageField::some(wa::message::StickerMessage {
                url: Some(up.url),
                direct_path: Some(up.direct_path),
                media_key: Some(up.media_key.to_vec()),
                mimetype: Some("image/webp".into()),
                file_enc_sha256: Some(up.file_enc_sha256.to_vec()),
                file_sha256: Some(up.file_sha256.to_vec()),
                file_length: Some(up.file_length),
                ..Default::default()
            }),
            ..Default::default()
        },
        _ => wa::Message {
            document_message: MessageField::some(wa::message::DocumentMessage {
                url: Some(up.url),
                direct_path: Some(up.direct_path),
                media_key: Some(up.media_key.to_vec()),
                mimetype: Some(a.mime.clone()),
                file_enc_sha256: Some(up.file_enc_sha256.to_vec()),
                file_sha256: Some(up.file_sha256.to_vec()),
                file_length: Some(up.file_length),
                file_name: Some(a.name.clone()),
                caption,
                ..Default::default()
            }),
            ..Default::default()
        },
    };
    Ok(body)
}
struct LimitedWriter {
    file: File,
}
impl Write for LimitedWriter {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if self
            .file
            .stream_position()?
            .saturating_add(bytes.len() as u64)
            > MAX_FILE
        {
            return Err(std::io::Error::other("size"));
        }
        self.file.write(bytes)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.file.flush()
    }
}
impl Seek for LimitedWriter {
    fn seek(&mut self, to: SeekFrom) -> std::io::Result<u64> {
        let at = self.file.seek(to)?;
        if at > MAX_FILE {
            return Err(std::io::Error::other("size"));
        }
        Ok(at)
    }
}
impl DownloadWriter for LimitedWriter {
    fn truncate(&mut self, len: u64) -> std::io::Result<()> {
        if len > MAX_FILE {
            return Err(std::io::Error::other("size"));
        }
        self.file.set_len(len)
    }
}
pub async fn download(
    client: &Client,
    cache: &Cache,
    chat: &str,
    a: &Action,
) -> Result<(), &'static str> {
    let (_, raw) = cache
        .stored_resource(
            chat,
            &a.target,
            (!a.value.is_empty()).then_some(a.value.as_str()),
        )
        .await?;
    let body = wa::Message::decode_from_slice(&raw).map_err(|_| "input")?;
    let body = body.get_base_message();
    let media: (&dyn Downloadable, u64) = if let Some(m) = body.image_message.as_option() {
        (m, m.file_length.unwrap_or(0))
    } else if let Some(m) = body
        .video_message
        .as_option()
        .or(body.ptv_message.as_option())
    {
        (m, m.file_length.unwrap_or(0))
    } else if let Some(m) = body.audio_message.as_option() {
        (m, m.file_length.unwrap_or(0))
    } else if let Some(m) = body.sticker_message.as_option() {
        (m, m.file_length.unwrap_or(0))
    } else if let Some(m) = body.document_message.as_option() {
        (m, m.file_length.unwrap_or(0))
    } else {
        return Err("input");
    };
    if media.1 > MAX_FILE {
        return Err("input");
    }
    let path = Path::new(&a.path);
    private_parent(path)?;
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| "input")?;
    let result = client
        .download_to_writer(media.0, LimitedWriter { file })
        .await;
    if result.is_err() {
        let _ = std::fs::remove_file(path);
        return Err("media");
    }
    Ok(())
}
