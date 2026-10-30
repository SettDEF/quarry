//! What each board looks like, for the switcher.
//!
//! A list of board names makes you remember which is which; four of the
//! pictures on each lets you recognise it. Which four: the most recently
//! raised — the top of the stack is what you were last working with.
//!
//! Fetched off the UI thread, and only again when a board's picture count
//! changes, so opening the switcher never waits on the daemon.

use std::collections::HashMap;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Arc;

use serde_json::json;

use crate::client::Client;
use crate::model::{parse_list, Piece};

pub struct Previews {
    ids: HashMap<String, Vec<String>>,
    /// The picture count each board had when it was last asked about.
    asked: HashMap<String, i64>,
    tx: Sender<(String, Vec<String>)>,
    rx: Receiver<(String, Vec<String>)>,
}

impl Previews {
    pub fn new() -> Self {
        let (tx, rx) = channel();
        Previews { ids: HashMap::new(), asked: HashMap::new(), tx, rx }
    }

    pub fn want(&mut self, client: Option<&Arc<Client>>, name: &str, items: i64) {
        if self.asked.get(name) == Some(&items) {
            return;
        }
        let Some(client) = client.cloned() else { return };
        self.asked.insert(name.to_string(), items);
        let (tx, name) = (self.tx.clone(), name.to_string());
        std::thread::spawn(move || {
            let Ok(p) = client.call("boards", json!({ "action": "items", "name": name })) else { return };
            let mut pieces: Vec<Piece> = parse_list(p.get("items"));
            pieces.sort_by_key(|p| std::cmp::Reverse(p.z));
            let _ = tx.send((name, pieces.into_iter().take(4).map(|p| p.id).collect()));
        });
    }

    pub fn pump(&mut self) -> bool {
        let mut got = false;
        while let Ok((name, ids)) = self.rx.try_recv() {
            self.ids.insert(name, ids);
            got = true;
        }
        got
    }

    pub fn get(&self, name: &str) -> &[String] {
        self.ids.get(name).map(|v| v.as_slice()).unwrap_or(&[])
    }

    /// After a rename or delete, so a stale name does not keep its pictures.
    pub fn forget(&mut self, name: &str) {
        self.ids.remove(name);
        self.asked.remove(name);
    }
}
