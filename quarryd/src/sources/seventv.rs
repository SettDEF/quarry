//! 7TV — animated Twitch emotes, the ones Discord servers are full of.
//!
//! Keyless GraphQL, so the request is a POST body like AniList's. Only animated
//! emotes are asked for: still ones are what emoji.gg and Iconify already have,
//! and moving ones are why anyone comes here (721,076 of them on 2026-10-21).
//!
//! Each emote carries its files with exact sizes, so `bytes` is the real size of
//! the GIF — and `bytes<256k` is "fits Discord's emoji limit".

use serde::Deserialize;
use serde_json::{json, Value};

use super::{Capabilities, Source, SourceQuery};
use crate::protocol::Item;
use crate::scrape;

pub struct SevenTv;

const PER_PAGE: u32 = 72;

const DOCUMENT: &str = r#"query ($q: String!, $page: Int, $limit: Int) {
  emotes(query: $q, page: $page, limit: $limit, filter: { animated: true },
         sort: { value: "popularity", order: DESCENDING }) {
    items { id name animated owner { display_name } host { url files { name width height format size } } }
  }
}"#;

#[derive(Debug, Default, Deserialize)]
struct Response {
    #[serde(default)]
    data: Option<Data>,
    #[serde(default)]
    errors: Vec<Value>,
}

#[derive(Debug, Default, Deserialize)]
struct Data {
    #[serde(default)]
    emotes: Emotes,
}

#[derive(Debug, Default, Deserialize)]
struct Emotes {
    #[serde(default)]
    items: Vec<Emote>,
}

#[derive(Debug, Deserialize)]
struct Emote {
    id: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    owner: Option<Owner>,
    #[serde(default)]
    host: Host,
}

#[derive(Debug, Default, Deserialize)]
struct Owner {
    #[serde(default)]
    display_name: String,
}

#[derive(Debug, Default, Deserialize)]
struct Host {
    #[serde(default)]
    url: String,
    #[serde(default)]
    files: Vec<File>,
}

#[derive(Debug, Deserialize)]
struct File {
    name: String,
    #[serde(default)]
    width: u32,
    #[serde(default)]
    height: u32,
    #[serde(default)]
    size: u64,
}

impl Source for SevenTv {
    fn id(&self) -> &'static str {
        "7tv"
    }

    fn category(&self) -> &'static str {
        "icons"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            author: false,
            text: true,
            min_size: false,
            ratio: false,
            nsfw: false,
            sort: false,
            video: false,
            colors: false,
            tags: false,
            categories: Vec::new(),
        }
    }

    fn build_url(&self, _query: &SourceQuery) -> String {
        "https://7tv.io/v3/gql".to_string()
    }

    fn body(&self, query: &SourceQuery) -> Option<Value> {
        // An empty query is the most popular emotes, which is the right browse.
        let text =
            query.text.iter().chain(query.tags.iter()).cloned().collect::<Vec<_>>().join(" ");
        Some(json!({
            "query": DOCUMENT,
            "variables": { "q": text, "page": query.page.max(1), "limit": PER_PAGE },
        }))
    }

    fn parse(&self, body: &str) -> Result<Vec<Item>, String> {
        let response: Response =
            serde_json::from_str(body).map_err(|e| format!("7tv json: {e}"))?;
        // Past its last page 7TV answers an error, not an empty list.
        if response.data.is_none() && !response.errors.is_empty() {
            return Err(format!("7tv: {}", response.errors[0]));
        }
        let emotes = response.data.unwrap_or_default().emotes.items;
        Ok(emotes
            .into_iter()
            .filter_map(|emote| {
                // `host.url` is protocol-relative: `//cdn.7tv.app/emote/<id>`.
                let base = format!("https:{}", emote.host.url);
                let gif = emote.host.files.iter().find(|f| f.name == "4x.gif")?;
                // The 2x GIF is a quarter of the bytes and plenty for a tile.
                let thumb = if emote.host.files.iter().any(|f| f.name == "2x.gif") {
                    format!("{base}/2x.gif")
                } else {
                    format!("{base}/4x.gif")
                };
                let mut item = scrape::normalize(
                    "7tv",
                    &emote.id,
                    &emote.name,
                    &format!("{base}/4x.gif"),
                    &thumb,
                    &format!("https://7tv.app/emotes/{}", emote.id),
                    gif.width,
                    gif.height,
                    Vec::new(),
                );
                item.kind = "emote".into();
                item.animated = true;
                item.bytes = gif.size;
                item.author = emote.owner.map(|o| o.display_name).unwrap_or_default();
                Some(item)
            })
            .collect())
    }

    fn has_more(&self, body: &str) -> bool {
        serde_json::from_str::<Response>(body)
            .ok()
            .and_then(|r| r.data)
            .map(|d| d.emotes.items.len() as u32 >= PER_PAGE)
            .unwrap_or(false)
    }
}
