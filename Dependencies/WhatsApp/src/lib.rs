#![allow(non_snake_case)]
mod avatars;
mod cache;
mod chat_rules;
mod command_cache;
mod commands;
mod jobs;
mod media;
mod polls;
mod presentation;
mod profile;
mod protocol;
mod receipts;
mod session;
use serde::Deserialize;
use serde_json::{Value, json};
use session::Session;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

const MAX_INPUT: usize = 2 * 1024 * 1024;
const MAX_OUTPUT: usize = 8 * 1024 * 1024;
#[repr(C)]
pub struct OwnedBuffer {
    pub data: *mut u8,
    pub len: usize,
}
static SESSIONS: OnceLock<Mutex<HashMap<u64, Arc<Session>>>> = OnceLock::new();
static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);
fn sessions() -> &'static Mutex<HashMap<u64, Arc<Session>>> {
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}
fn reply(f: impl FnOnce() -> Result<Value, &'static str>) -> OwnedBuffer {
    let value = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(Ok(data)) => json!({"version":1,"ok":true,"data":data}),
        Ok(Err(code)) => json!({"version":1,"ok":false,"error":code}),
        Err(_) => json!({"version":1,"ok":false,"error":"internal"}),
    };
    let bytes = serde_json::to_vec(&value)
        .unwrap_or_else(|_| b"{\"version\":1,\"ok\":false,\"error\":\"internal\"}".to_vec());
    let bytes = if bytes.len() <= MAX_OUTPUT {
        bytes
    } else {
        b"{\"version\":1,\"ok\":false,\"error\":\"size\"}".to_vec()
    };
    let mut boxed = bytes.into_boxed_slice();
    let result = OwnedBuffer {
        data: boxed.as_mut_ptr(),
        len: boxed.len(),
    };
    std::mem::forget(boxed);
    result
}
unsafe fn decode<T: for<'a> Deserialize<'a>>(
    data: *const u8,
    len: usize,
) -> Result<T, &'static str> {
    if data.is_null() || len == 0 || len > MAX_INPUT {
        return Err("input");
    }
    // SAFETY: the caller guarantees a readable allocation of len bytes for this call.
    serde_json::from_slice(unsafe { std::slice::from_raw_parts(data, len) }).map_err(|_| "input")
}
#[unsafe(no_mangle)]
pub extern "C" fn MkWAAbiVersion() -> u32 {
    1
}
/// # Safety
/// data must reference len readable bytes for the duration of this call; never called on UI thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn MkWAOpen(data: *const u8, len: usize) -> OwnedBuffer {
    reply(|| {
        let options = unsafe { decode::<session::Options>(data, len)? };
        let session = Arc::new(Session::open(options)?);
        let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
        if handle == 0 {
            return Err("internal");
        }
        sessions()
            .lock()
            .map_err(|_| "internal")?
            .insert(handle, session);
        Ok(json!({"handle":handle}))
    })
}
/// # Safety
/// data must reference len readable bytes for this call. The session serializes native commands.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn MkWACall(handle: u64, data: *const u8, len: usize) -> OwnedBuffer {
    reply(|| {
        let request = unsafe { decode::<session::Request>(data, len)? };
        let session = sessions()
            .lock()
            .map_err(|_| "internal")?
            .get(&handle)
            .cloned()
            .ok_or("closed")?;
        session.call(request)
    })
}
/// Revokes admission before waiting for in-flight commands and graceful network shutdown.
#[unsafe(no_mangle)]
pub extern "C" fn MkWAClose(handle: u64) -> OwnedBuffer {
    reply(|| {
        let session = sessions()
            .lock()
            .map_err(|_| "internal")?
            .remove(&handle)
            .ok_or("closed")?;
        session.close()?;
        Ok(Value::Null)
    })
}
/// # Safety
/// buffer must be one unmodified reply from this library, released exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn MkWAFree(buffer: OwnedBuffer) {
    if !buffer.data.is_null() {
        // SAFETY: the caller returns the exact allocation and length produced by reply().
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(buffer.data, buffer.len)) });
    }
}
#[cfg(test)]
mod tests;

mod controls;

mod calls;
