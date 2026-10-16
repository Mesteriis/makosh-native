use crate::cache::{Cache, Cursor};
use crate::protocol::{ConnectionStatus, build_bot};
use serde::Deserialize;
use serde_json::Value;
use std::fs::{File, OpenOptions};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::runtime::Runtime;
use whatsapp_rust::bot::BotHandle;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Options {
    pub version: u32,
    pub directory: String,
    pub key: Vec<u8>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub version: u32,
    pub command: String,
    #[serde(default)]
    pub chat: String,
    #[serde(default = "default_limit")]
    pub limit: i64,
    pub before: Option<Cursor>,
    pub sequence: Option<i64>,
    pub action: Option<crate::commands::Action>,
    pub ticket: Option<String>,
    pub media: Option<crate::calls::Exchange>,
}
fn default_limit() -> i64 {
    50
}
pub(crate) fn bounded_journal(
    rows: Vec<crate::cache::JournalEntry>,
) -> Result<Vec<crate::cache::JournalEntry>, &'static str> {
    let mut batch = Vec::new();
    let mut used = 64usize;
    for row in rows {
        let size = serde_json::to_vec(&row).map_err(|_| "storage")?.len() + 1;
        if used.saturating_add(size) >= 7 * 1024 * 1024 {
            if batch.is_empty() {
                return Err("size");
            }
            break;
        }
        used += size;
        batch.push(row);
    }
    Ok(batch)
}
struct Running {
    closed: bool,
    bot: Option<BotHandle>,
    exported: i64,
    jobs: crate::jobs::CommandJobs,
}
pub struct Session {
    runtime: Runtime,
    cache: Cache,
    calls: Arc<crate::calls::Calls>,
    status: Arc<Mutex<ConnectionStatus>>,
    running: Mutex<Running>,
    _lease: File,
}
fn private_file(path: &Path, create: bool) -> Result<File, &'static str> {
    let f = OpenOptions::new()
        .read(true)
        .write(true)
        .create(create)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|_| "storage")?;
    let m = f.metadata().map_err(|_| "storage")?;
    if !m.is_file()
        || m.uid() != unsafe { libc::geteuid() }
        || m.mode() & 0o077 != 0
        || m.nlink() != 1
    {
        return Err("permissions");
    }
    Ok(f)
}
impl Session {
    pub fn open(options: Options) -> Result<Self, &'static str> {
        if options.version != 1 {
            return Err("version");
        }
        if options.key.len() != 32 {
            return Err("key");
        }
        let dir = Path::new(&options.directory);
        if !dir.is_absolute() {
            return Err("input");
        }
        let meta = dir.symlink_metadata().map_err(|_| "storage")?;
        if !meta.is_dir()
            || meta.file_type().is_symlink()
            || meta.uid() != unsafe { libc::geteuid() }
            || meta.permissions().mode() & 0o077 != 0
        {
            return Err("permissions");
        }
        let lease = private_file(&dir.join("owner.lock"), true)?;
        // SAFETY: lease is an open owned file descriptor; flock does not outlive it.
        if unsafe {
            libc::flock(
                std::os::fd::AsRawFd::as_raw_fd(&lease),
                libc::LOCK_EX | libc::LOCK_NB,
            )
        } != 0
        {
            return Err("owned");
        }
        let file = dir.join("session.db");
        drop(private_file(&file, true)?);
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("makosh-whatsapp")
            .enable_all()
            .build()
            .map_err(|_| "runtime")?;
        let path = file.to_str().ok_or("input")?;
        let cache = runtime.block_on(Cache::open(path, options.key))?;
        Ok(Self {
            runtime,
            cache,
            calls: Arc::new(crate::calls::Calls::default()),
            status: Arc::new(Mutex::new(ConnectionStatus::default())),
            running: Mutex::new(Running {
                closed: false,
                bot: None,
                exported: 0,
                jobs: Default::default(),
            }),
            _lease: lease,
        })
    }
    pub fn call(&self, r: Request) -> Result<Value, &'static str> {
        if r.version != 1 {
            return Err("version");
        }
        if !(1..=100).contains(&r.limit) || r.chat.len() > 1024 {
            return Err("input");
        }
        let mut running = self.running.lock().map_err(|_| "internal")?;
        if running.closed {
            return Err("closed");
        }
        match r.command.as_str() {
            "call_media" => self
                .runtime
                .block_on(self.calls.media(&r.media.ok_or("input")?)),
            "command_result" => self
                .runtime
                .block_on(self.cache.command_result(&r.ticket.ok_or("input")?)),
            "perform" => {
                use sha2::{Digest, Sha256};
                let action = r.action.ok_or("input")?;
                action.validate(&r.chat)?;
                let control = action.op.starts_with("call_");
                if !running.jobs.can_admit(&action.op) {
                    return Err("busy");
                }
                if self.status.lock().map_err(|_| "internal")?.state != "connected" {
                    return Err("offline");
                }
                let client = running.bot.as_ref().ok_or("offline")?.client();
                crate::calls::Calls::preflight(&client, &action)?;
                let digest = format!(
                    "{:x}",
                    Sha256::digest(serde_json::to_vec(&(&r.chat, &action)).map_err(|_| "input")?)
                );
                self.runtime.block_on(async {
                    if let Some(result) = self.cache.admit_command(&action.attempt, &digest).await?
                    {
                        return Ok(result);
                    }
                    let call_epoch = if action.op.starts_with("call_") {
                        self.calls.admit(&r.chat, &action).await?
                    } else {
                        0
                    };
                    let terminal = if action.op == "call_end" {
                        self.calls.end_local(call_epoch).await
                    } else {
                        None
                    };
                    let is_end = action.op == "call_end";
                    let termination = is_end || action.op == "call_reject";
                    let cache = self.cache.clone();
                    let calls = self.calls.clone();
                    let ticket = action.attempt.clone();
                    let work = async move {
                        tokio::time::timeout(Duration::from_secs(45), async {
                            if is_end {
                                crate::calls::Calls::signal_end(client, terminal).await
                            } else if action.op.starts_with("call_") {
                                calls.execute(client, &r.chat, &action, call_epoch).await
                            } else {
                                crate::commands::execute(client, &cache, &r.chat, &action).await
                            }
                        })
                        .await
                        .map_err(|_| "unknown")?
                    };
                    if termination {
                        running
                            .jobs
                            .start_termination(self.cache.clone(), ticket, work)?
                    } else if control {
                        running
                            .jobs
                            .start_control(self.cache.clone(), ticket, work)?
                    } else {
                        running.jobs.start(self.cache.clone(), ticket, work)?
                    };
                    Ok(serde_json::json!({"pending":true}))
                })
            }
            "snapshot" => {
                let mut status = self.status.lock().map_err(|_| "internal")?;
                status.expire();
                let mut value = serde_json::to_value(&*status).map_err(|_| "internal")?;
                value["revision"] = status.revision.wrapping_add(self.cache.revision()).into();
                drop(status);
                value["call"] = serde_json::to_value(self.runtime.block_on(self.calls.snapshot()))
                    .map_err(|_| "internal")?;
                Ok(value)
            }
            "connect" => {
                self.runtime.block_on(running.jobs.shutdown());
                self.runtime.block_on(self.calls.stop());
                if let Some(bot) = running.bot.take() {
                    self.runtime.block_on(bot.shutdown());
                }
                if self.status.lock().map_err(|_| "internal")?.state == "logged_out" {
                    return Err("logged_out");
                }
                self.status
                    .lock()
                    .map_err(|_| "internal")?
                    .set("connecting");
                let bot = self.runtime.block_on(async {
                    tokio::time::timeout(
                        Duration::from_secs(20),
                        build_bot(self.cache.clone(), self.status.clone(), self.calls.clone()),
                    )
                    .await
                    .map_err(|_| "timeout")?
                })?;
                // BotHandle is itself a Future. Return the background owner;
                // awaiting it here would block commands until disconnection.
                let _runtime = self.runtime.enter();
                running.bot = Some(bot.spawn());
                Ok(Value::Null)
            }
            "disconnect" => {
                self.runtime.block_on(running.jobs.shutdown());
                self.runtime.block_on(self.calls.stop());
                self.status.lock().map_err(|_| "internal")?.set("stopping");
                if let Some(bot) = running.bot.take() {
                    self.runtime.block_on(bot.shutdown());
                }
                let mut status = self.status.lock().map_err(|_| "internal")?;
                if status.state != "logged_out" {
                    status.set("offline");
                }
                Ok(Value::Null)
            }
            "chats" => {
                serde_json::to_value(self.runtime.block_on(self.cache.chats(r.before, r.limit))?)
                    .map_err(|_| "internal")
            }
            "messages" => serde_json::to_value(
                self.runtime
                    .block_on(self.cache.messages(r.chat, r.before, r.limit))?,
            )
            .map_err(|_| "internal"),
            "journal" => {
                let rows = bounded_journal(self.runtime.block_on(self.cache.journal(r.limit))?)?;
                if let Some(last) = rows.last() {
                    running.exported = running.exported.max(last.sequence);
                }
                serde_json::to_value(rows).map_err(|_| "internal")
            }
            "ack" => {
                let sequence = r.sequence.ok_or("input")?;
                if sequence < 0 || sequence > running.exported {
                    return Err("input");
                }
                self.runtime.block_on(self.cache.ack(sequence))?;
                Ok(Value::Null)
            }
            _ => Err("command"),
        }
    }
    pub fn close(&self) -> Result<(), &'static str> {
        let mut running = self.running.lock().map_err(|_| "internal")?;
        running.closed = true;
        self.runtime.block_on(running.jobs.shutdown());
        self.runtime.block_on(self.calls.stop());
        self.status.lock().map_err(|_| "internal")?.set("stopping");
        if let Some(bot) = running.bot.take() {
            self.runtime.block_on(bot.shutdown());
        }
        Ok(())
    }
}
