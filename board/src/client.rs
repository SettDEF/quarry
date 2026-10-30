//! Talking to quarryd.
//!
//! The protocol is newline-delimited JSON over a unix socket, described in
//! PROTOCOL.md, and this speaks it directly rather than sharing types with the
//! daemon: the wire format IS the contract, and a shared struct would quietly
//! make the two halves one program again.
//!
//! Two threads, because the socket carries two different kinds of traffic. A
//! request expects one answer and the caller wants it back; an EVENT arrives
//! unasked whenever quarry changes a board in the other window. A reader thread
//! demultiplexes them: replies go to whoever is waiting, events go on a channel
//! the UI drains each frame.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};

pub struct Client {
    write: Mutex<UnixStream>,
    next_id: AtomicU64,
    /// Where a reply should be delivered, by request id.
    waiting: Arc<Mutex<HashMap<u64, Sender<Result<Value, String>>>>>,
}

/*
 * Events come back SEPARATELY from the client, not as a field on it.
 *
 * A `Receiver` is Send but not Sync, so holding one made the whole `Client`
 * unshareable — and the client has to be shared: every texture load is a
 * thread asking the daemon for a thumbnail. Handing the receiver to the UI on
 * its own keeps the client itself trivially Sync.
 */
pub type Events = Receiver<(String, Value)>;

pub fn socket_path() -> String {
    // Same override as quarryd, so a test can pair a board with a private daemon.
    if let Ok(p) = std::env::var("QUARRY_SOCK") {
        return p;
    }
    let runtime = std::env::var("XDG_RUNTIME_DIR")
        .unwrap_or_else(|_| format!("/run/user/{}", unsafe { libc_getuid() }));
    format!("{runtime}/quarry/sock")
}

// One libc call, not worth the dependency.
unsafe fn libc_getuid() -> u32 {
    extern "C" {
        fn getuid() -> u32;
    }
    getuid()
}

impl Client {
    pub fn connect() -> Result<(Self, Events), String> {
        let path = socket_path();
        let stream = UnixStream::connect(&path)
            .map_err(|e| format!("quarryd is not running ({path}): {e}"))?;
        let reader = stream.try_clone().map_err(|e| e.to_string())?;

        let waiting: Arc<Mutex<HashMap<u64, Sender<Result<Value, String>>>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let (event_tx, events) = channel();

        let pending = Arc::clone(&waiting);
        std::thread::spawn(move || {
            for line in BufReader::new(reader).lines() {
                let Ok(line) = line else { break };
                let Ok(frame) = serde_json::from_str::<Value>(&line) else { continue };

                match frame.get("t").and_then(|v| v.as_str()) {
                    Some("ev") => {
                        let name = frame.get("m").and_then(|v| v.as_str()).unwrap_or("").to_string();
                        let payload = frame.get("p").cloned().unwrap_or(Value::Null);
                        // A dead receiver means the UI is gone; nothing to do.
                        let _ = event_tx.send((name, payload));
                    }
                    Some("res") => {
                        let id = frame.get("id").and_then(|v| v.as_u64()).unwrap_or(0);
                        let Some(tx) = pending.lock().ok().and_then(|mut w| w.remove(&id)) else {
                            continue;
                        };
                        let ok = frame.get("ok").and_then(|v| v.as_bool()).unwrap_or(false);
                        let _ = tx.send(if ok {
                            Ok(frame.get("p").cloned().unwrap_or(Value::Null))
                        } else {
                            Err(frame
                                .get("err")
                                .and_then(|v| v.as_str())
                                .unwrap_or("unknown error")
                                .to_string())
                        });
                    }
                    _ => {}
                }
            }
            // The socket closed. Everyone still waiting gets told, rather than
            // blocking forever on a reply that cannot come.
            if let Ok(mut w) = pending.lock() {
                for (_, tx) in w.drain() {
                    let _ = tx.send(Err("quarryd closed the connection".into()));
                }
            }
        });

        Ok((
            Client {
                write: Mutex::new(stream),
                next_id: AtomicU64::new(1),
                waiting,
            },
            events,
        ))
    }

    /// Ask, and wait. Used for the handful of calls the UI cannot proceed
    /// without; anything on a hot path goes through `send` instead.
    pub fn call(&self, method: &str, params: Value) -> Result<Value, String> {
        let (tx, rx) = channel();
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        self.waiting.lock().map_err(|_| "lock")?.insert(id, tx);
        self.write_frame(id, method, params)?;
        rx.recv_timeout(std::time::Duration::from_secs(20))
            .map_err(|_| format!("{method} timed out"))?
    }

    /// Fire and forget — a geometry write during a drag, where the answer is
    /// only ever "yes" and waiting for it would stall the frame.
    pub fn send(&self, method: &str, params: Value) {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let _ = self.write_frame(id, method, params);
    }

    fn write_frame(&self, id: u64, method: &str, params: Value) -> Result<(), String> {
        let frame = json!({ "t": "req", "id": id, "m": method, "p": params });
        let mut line = serde_json::to_vec(&frame).map_err(|e| e.to_string())?;
        line.push(b'\n');
        let mut sock = self.write.lock().map_err(|_| "lock")?;
        sock.write_all(&line).map_err(|e| e.to_string())
    }
}
