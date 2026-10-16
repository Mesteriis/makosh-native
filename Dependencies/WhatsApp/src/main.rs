// Separate AGPL-3.0-only protocol worker. stdout is private framed IPC, never a log.
use MakoshWhatsApp::{MkWACall, MkWAClose, MkWAFree, MkWAOpen, OwnedBuffer};
use serde::Deserialize;
use serde_json::Value;
use std::io::{Read, Write};
use zeroize::Zeroizing;
const MAX_FRAME: usize = 2 * 1024 * 1024;
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    op: String,
    request: Option<Value>,
}
fn send(output: &mut impl Write, buffer: OwnedBuffer) -> std::io::Result<()> {
    // SAFETY: buffer is an unmodified live reply from this worker's library.
    let bytes = unsafe { std::slice::from_raw_parts(buffer.data, buffer.len) };
    let result = output
        .write_all(&(bytes.len() as u32).to_be_bytes())
        .and_then(|_| output.write_all(bytes))
        .and_then(|_| output.flush());
    unsafe { MkWAFree(buffer) };
    result
}
fn run() -> std::io::Result<()> {
    let mut input = std::io::stdin().lock();
    let mut output = std::io::stdout().lock();
    let mut handle = 0;
    let result = (|| {
        loop {
            let mut length = [0u8; 4];
            match input.read_exact(&mut length) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
                Err(e) => return Err(e),
            }
            let length = u32::from_be_bytes(length) as usize;
            if length == 0 || length > MAX_FRAME {
                return Err(std::io::ErrorKind::InvalidData.into());
            }
            let mut frame = Zeroizing::new(vec![0u8; length]);
            input.read_exact(&mut frame)?;
            let envelope: Envelope =
                serde_json::from_slice(&frame).map_err(|_| std::io::ErrorKind::InvalidData)?;
            let request = Zeroizing::new(
                serde_json::to_vec(&envelope.request)
                    .map_err(|_| std::io::ErrorKind::InvalidData)?,
            );
            let response = match envelope.op.as_str() {
                "open" if handle == 0 => {
                    let reply = unsafe { MkWAOpen(request.as_ptr(), request.len()) };
                    // SAFETY: inspect the owned reply before send frees it.
                    let value: Value = serde_json::from_slice(unsafe {
                        std::slice::from_raw_parts(reply.data, reply.len)
                    })
                    .map_err(|_| std::io::ErrorKind::InvalidData)?;
                    handle = value["data"]["handle"].as_u64().unwrap_or(0);
                    reply
                }
                "call" if handle != 0 => unsafe {
                    MkWACall(handle, request.as_ptr(), request.len())
                },
                "close" if handle != 0 => {
                    let reply = MkWAClose(handle);
                    handle = 0;
                    send(&mut output, reply)?;
                    break;
                }
                _ => return Err(std::io::ErrorKind::InvalidData.into()),
            };
            send(&mut output, response)?;
        }
        Ok(())
    })();
    if handle != 0 {
        unsafe { MkWAFree(MkWAClose(handle)) };
    }
    result
}
fn main() {
    // Private upstream panic text is never written to stderr. Errors become a
    // fixed nonzero status, with session files retained for explicit recovery.
    std::panic::set_hook(Box::new(|_| {}));
    unsafe { libc::umask(0o077) };
    if run().is_err() {
        std::process::exit(2);
    }
}
