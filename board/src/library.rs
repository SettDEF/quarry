//! The library: the catalogue, searchable from inside the board.
//!
//! RIA's folder view is how pictures get onto its board without leaving it.
//! Here the catalogue already exists — every source quarry crawls, every file
//! adopted — so the panel is a search box over it, in the same query language
//! as quarry's own bar.
//!
//! It asks with `find`, never `query`. The daemon keeps ONE stored result for
//! every client, and a second window running `query` would silently invalidate
//! the paging of the quarry window the person already has open.

use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Arc;

use serde_json::json;

use crate::client::Client;
use crate::model::{parse_list, Record};

const PAGE: usize = 60;

struct Answer {
    generation: u64,
    offset: usize,
    result: Result<(usize, Vec<Record>), String>,
}

pub struct Library {
    pub text: String,
    /// Showing pictures that look like this one (id, label) instead of a search.
    pub similar: Option<(String, String)>,
    /// What the shown results are for; differs from `text` while typing.
    asked: Option<String>,
    edited_at: f64,
    pub results: Vec<Record>,
    pub count: usize,
    pub loading: bool,
    pub error: Option<String>,
    generation: u64,
    tx: Sender<Answer>,
    rx: Receiver<Answer>,
}

impl Library {
    pub fn new() -> Self {
        let (tx, rx) = channel();
        Library {
            text: String::new(),
            similar: None,
            asked: None,
            edited_at: 0.0,
            results: Vec::new(),
            count: 0,
            loading: false,
            error: None,
            generation: 0,
            tx,
            rx,
        }
    }

    pub fn edited(&mut self, now: f64) {
        self.edited_at = now;
    }

    /// Take answers, and send the question once typing has paused. 220 ms: a
    /// search per keystroke over 130k rows is work nobody sees the result of.
    pub fn pump(&mut self, client: Option<&Arc<Client>>, now: f64) -> bool {
        let mut changed = false;
        while let Ok(a) = self.rx.try_recv() {
            if a.generation != self.generation {
                continue;                   // an answer to a question since replaced
            }
            self.loading = false;
            changed = true;
            match a.result {
                Ok((count, rows)) => {
                    self.error = None;
                    self.count = count;
                    if a.offset == 0 {
                        self.results = rows;
                    } else if a.offset == self.results.len() {
                        self.results.extend(rows);
                    }
                }
                Err(e) => {
                    self.error = Some(if e.contains("unknown method") {
                        "This quarryd is older than the board — restart it to search.".into()
                    } else {
                        e
                    });
                }
            }
        }

        let settled = now - self.edited_at > 0.22;
        let question = self.question();
        if settled && self.asked.as_deref() != Some(question.as_str()) {
            if let Some(c) = client {
                self.asked = Some(question);
                self.ask(c, 0);
            }
        }
        changed
    }

    /// What is being asked, as one comparable string.
    fn question(&self) -> String {
        match &self.similar {
            Some((id, _)) => format!("\u{1}similar:{id}"),
            None => self.text.clone(),
        }
    }

    pub fn show_similar(&mut self, id: &str, label: &str) {
        self.similar = Some((id.to_string(), label.to_string()));
        self.results.clear();
        self.count = 0;
        self.error = None;
        self.edited_at = f64::NEG_INFINITY;
    }

    pub fn clear_similar(&mut self) {
        self.similar = None;
        self.results.clear();
        self.count = 0;
        self.error = None;
        self.edited_at = f64::NEG_INFINITY;
    }

    pub fn more(&mut self, client: Option<&Arc<Client>>) {
        // A similarity answer is one ranked list, not pages.
        if self.similar.is_some() || self.loading || self.results.len() >= self.count {
            return;
        }
        if let Some(c) = client {
            let offset = self.results.len();
            self.ask_at(c, offset, false);
        }
    }

    fn ask(&mut self, client: &Arc<Client>, offset: usize) {
        self.ask_at(client, offset, true);
    }

    fn ask_at(&mut self, client: &Arc<Client>, offset: usize, fresh: bool) {
        if fresh {
            self.generation += 1;
        }
        self.loading = true;
        let (tx, client, generation) = (self.tx.clone(), client.clone(), self.generation);
        let q = self.text.trim().to_string();
        let similar = self.similar.as_ref().map(|(id, _)| id.clone());
        std::thread::spawn(move || {
            let answer = |p: serde_json::Value| {
                let count = p.get("count").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
                (count, parse_list::<Record>(p.get("items")))
            };
            let result = match similar {
                Some(id) => {
                    // An older daemon ignores `records` and answers `similar`
                    // the old way — by replacing the result quarry is paging.
                    // `find` arrived with `records`, so its absence is the tell,
                    // and then the question is not asked at all.
                    match client.call("find", json!({ "q": "", "limit": 0 })) {
                        Err(e) => Err(e),
                        Ok(_) => client
                            .call("similar", json!({ "id": id, "limit": 120, "records": true }))
                            .map(answer),
                    }
                }
                None => client.call("find", json!({ "q": q, "offset": offset, "limit": PAGE })).map(answer),
            };
            let _ = tx.send(Answer { generation, offset, result });
        });
    }

    /// Forget the last answer so the next pump asks again — after the catalogue
    /// changed underneath it.
    pub fn invalidate(&mut self) {
        self.asked = None;
    }
}
