//! The v1 wire protocol, mirroring PROTOCOL.md.
//!
//! PROTOCOL.md is the authority: these types exist to make it impossible to
//! send a frame the document does not describe.

use serde::{Deserialize, Serialize};

/// The catalog record. Exactly `ITEM.md` — the fixture is validated against it
/// on load, so a contract violation is a startup error, not a blank tile.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Item {
    pub id: String,
    pub source: String,
    pub source_id: String,
    pub family: String,
    pub kind: String,
    #[serde(default)]
    pub title: String,
    pub slug: String,
    pub url: String,
    pub thumb: String,
    /// Mid-size URL (Moebooru `sample_url`, Danbooru `large_file_url`), when the
    /// source actually publishes one. Empty when it doesn't.
    #[serde(default)]
    pub sample: String,
    #[serde(default)]
    pub page_url: String,
    #[serde(default)]
    pub ext: String,
    #[serde(default)]
    pub w: u32,
    #[serde(default)]
    pub h: u32,
    #[serde(default)]
    pub ratio: f64,
    #[serde(default)]
    pub bytes: u64,
    #[serde(default)]
    pub animated: bool,
    /// Seconds of video, 0 for a still.
    ///
    /// Filled in when the daemon has actually looked at the file (`ffprobe`
    /// while making the poster frame), not from a source's metadata — several
    /// report it wrong or not at all, and a duration nobody measured is worse
    /// than no duration, because the UI would print it.
    #[serde(default)]
    pub duration: f64,
    #[serde(default)]
    pub tintable: bool,
    #[serde(default)]
    pub nsfw: bool,
    #[serde(default)]
    pub author: String,
    #[serde(default)]
    pub license: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub added_at: i64,
    #[serde(default)]
    pub phash: String,
    #[serde(default)]
    pub dominant: String,
    /// Where the daemon has already cached a thumbnail for this row, if it has.
    ///
    /// Sent with the record so the client does not need a round trip per tile
    /// to discover it — at ninety tiles a screen that was thousands of requests
    /// for files that were already on disk.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub thumb_local: String,
}

#[derive(Debug, Deserialize)]
pub struct Request {
    #[allow(dead_code)]
    pub t: String,
    pub id: u64,
    pub m: String,
    #[serde(default)]
    pub p: serde_json::Value,
}

#[derive(Debug, Serialize)]
pub struct Response {
    pub t: &'static str,
    pub id: u64,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub p: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub err: Option<String>,
}

impl Response {
    /// Flag an error as "this row will never work", so the client can drop it
    /// from the view instead of leaving an empty cell behind.
    pub fn with_broken(mut self, broken: bool) -> Self {
        if broken {
            self.p = Some(serde_json::json!({ "broken": true }));
        }
        self
    }

    pub fn ok(id: u64, p: serde_json::Value) -> Self {
        Response { t: "res", id, ok: true, p: Some(p), err: None }
    }

    pub fn err(id: u64, message: impl Into<String>) -> Self {
        Response { t: "res", id, ok: false, p: None, err: Some(message.into()) }
    }
}

/// Unsolicited frames — see `Server::emit`.
///
/// `board.changed` is the first of them, and the reason they stopped being
/// theoretical: quarry and the board are two applications sharing one
/// catalogue, so a write in one has to reach the other.
#[derive(Debug, Serialize)]
pub struct Event {
    pub t: &'static str,
    pub m: String,
    pub p: serde_json::Value,
}

/// Query parameters. Every field optional: an empty query is "everything".
#[derive(Debug, Default, Clone, Deserialize)]
pub struct QueryParams {
    #[serde(default)]
    pub q: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub source: String,
    #[serde(default)]
    pub family: String,
    /// The perf harness asks for a catalog N times the fixture. Nothing is
    /// materialised: it multiplies the result index, not the records.
    #[serde(default = "one")]
    pub repeat: usize,
    /// Collapse rows that are the same picture. Defaults ON: the same art is
    /// posted to several boards, so a result is full of rows with different
    /// ids, different URLs and different sources that are one image.
    #[serde(default = "yes")]
    pub dedupe: bool,
}

fn yes() -> bool {
    true
}

fn one() -> usize {
    1
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ItemsParams {
    pub query_id: u64,
    #[serde(default)]
    pub offset: usize,
    #[serde(default = "default_limit")]
    pub limit: usize,
}

fn default_limit() -> usize {
    500
}

pub const MAX_LIMIT: usize = 1000;
pub const PROTOCOL_VERSION: u32 = 1;
