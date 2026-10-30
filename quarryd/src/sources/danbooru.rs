//! danbooru — and, by extension, every booru: the same API shape covers
//! safebooru, yande.re and konachan with a different host.
//!
//! Its filtering is a tag language of its own, which is the interesting case
//! for pushdown: quarry's `w>=1920 -nsfw` becomes danbooru's
//! `width:>=1920 rating:general`, expressed in its syntax rather than ours.

use serde::Deserialize;

use super::{Capabilities, Source, SourceQuery};
use crate::protocol::Item;
use crate::query::Sort;
use crate::scrape;

pub struct Danbooru;

#[derive(Debug, Deserialize)]
struct Row {
    id: u64,
    #[serde(default)]
    file_url: String,
    #[serde(default)]
    preview_file_url: String,
    /// Mid-size render danbooru builds for every post above its sample
    /// threshold (~850-1000px); below that it just echoes `file_url`. Either
    /// way it beats upscaling the ~150px preview for a tile.
    #[serde(default)]
    large_file_url: String,
    #[serde(default)]
    image_width: u32,
    #[serde(default)]
    image_height: u32,
    #[serde(default)]
    file_ext: String,
    #[serde(default)]
    file_size: u64,
    #[serde(default)]
    rating: String,
    #[serde(default)]
    tag_string_general: String,
    #[serde(default)]
    tag_string_artist: String,
    #[serde(default)]
    tag_string_character: String,
}

impl Danbooru {
    /// Real danbooru tags, each checked against `/tags.json` for a nonzero
    /// post count — a booru matches tags exactly, so a guessed word that isn't
    /// a real tag returns nothing rather than something close.
    pub fn popular_groups() -> &'static [(&'static str, &'static [&'static str])] {
        &[
            ("Characters", &["1girl", "1boy", "solo", "animal_ears", "twintails", "maid"]),
            ("Scenery", &["landscape", "scenery", "cityscape", "no_humans", "outdoors", "sunset"]),
            ("Style", &["chibi", "mecha", "armor", "weapon", "school_uniform", "swimsuit"]),
            ("Series", &["genshin_impact", "pokemon", "hatsune_miku", "touhou"]),
        ]
    }
}

impl Source for Danbooru {
    fn id(&self) -> &'static str {
        "danbooru"
    }

    fn category(&self) -> &'static str {
        "art"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            text: true,
            // `author:` is the artist tag, which is how danbooru files it.
            author: true,
            min_size: true,
            // Danbooru has no aspect filter — that stays in the residue.
            ratio: false,
            nsfw: true,
            sort: true,
            video: true,
            colors: false,
            tags: true,
            categories: Vec::new(),
        }
    }

    fn build_url(&self, query: &SourceQuery) -> String {
        /*
         * Free text on a booru is not a tag until the booru says which tag it
         * is. `mountain lake` sent as typed is `mountain_lake` (no such tag)
         * or `mountain` AND `lake` spelled however the words happened to be;
         * `tag_resolve` asks danbooru's own autocomplete, the same endpoint
         * its search box uses. Explicit `tag:` values are already tags.
         */
        let mut content: Vec<String> = Vec::new();
        if !query.text.is_empty() {
            content = super::tag_resolve::resolve(
                super::tag_resolve::Resolver::Danbooru,
                "https://danbooru.donmai.us/posts.json",
                &query.text,
            )
            .tags;
        }
        for tag in &query.tags {
            let tag = tag.replace(' ', "_");
            if !content.contains(&tag) {
                content.push(tag);
            }
        }

        // Danbooru's own metatag. `video` covers webm and mp4 both, where
        // `animated` would also sweep in animated GIFs — which are rasters
        // here, not video, and would come back as rows the video view cannot
        // play.
        if query.wants_video == Some(true) {
            content.push("video".into());
        }

        // The artist tag, as danbooru spells it: underscores, no prefix.
        if !query.author.is_empty() {
            let artist = query.author.replace(' ', "_");
            if !content.contains(&artist) {
                content.push(artist);
            }
        }

        /*
         * Two tags is the anonymous limit, and a longer query is rejected
         * outright (422). `rating:` does NOT count towards it — probed
         * 2026-09-15: two tags plus `rating:general` answers, three tags or
         * two plus `order:` does not. So the words the user typed come first,
         * then the size and order filters while there is room, and the rating
         * always — dropping it by truncation is how `-nsfw` used to leak
         * whenever a query had two words.
         */
        const LIMIT: usize = 2;
        let mut tags: Vec<String> = content.into_iter().take(LIMIT).collect();
        let room = |tags: &mut Vec<String>, tag: String| {
            if tags.len() < LIMIT {
                tags.push(tag);
            }
        };
        if query.min_w > 0 {
            room(&mut tags, format!("width:>={}", query.min_w));
        }
        if query.min_h > 0 {
            room(&mut tags, format!("height:>={}", query.min_h));
        }
        /*
         * Ordering, and the rule that makes it work.
         *
         * An `order:` tag on an *unfiltered* corpus makes danbooru's own
         * database time out — `order:id`, `order:id_desc` and `order:score` all
         * answer 500 ActiveRecord::QueryCanceled on their own, while
         * `rating:general order:score` is fine. So an order is only ever added
         * alongside a real filter, and `Newest` adds nothing at all because
         * newest-first is already the default.
         *
         * Found by `doctor`, which is exactly the failure it exists to catch:
         * the source was answering 500 while the app would have shown an empty
         * gallery.
         */
        let has_filter = !tags.is_empty() || query.allow_nsfw == Some(false);
        match query.sort {
            Sort::Largest if has_filter => room(&mut tags, "order:score".into()),
            Sort::Random if has_filter => room(&mut tags, "order:random".into()),
            _ => {}
        }
        if query.allow_nsfw == Some(false) {
            tags.push("rating:general".into());
        }

        // The tag string must be encoded: `width:>=1920` sent raw makes
        // danbooru's HTTP parser reject the whole request with a 500 that reads
        // like a server fault rather than a bad URL. Caught by a fixture that
        // came back as an error page.
        format!(
            "https://danbooru.donmai.us/posts.json?limit=50&page={}&tags={}",
            query.page.max(1),
            scrape::urlencode(&tags.join(" "))
        )
    }

    fn parse(&self, body: &str) -> Result<Vec<Item>, String> {
        let rows: Vec<Row> =
            serde_json::from_str(body).map_err(|e| format!("danbooru json: {e}"))?;

        Ok(rows
            .into_iter()
            .filter(|row| !row.file_url.is_empty() && row.image_width > 0)
            .map(|row| {
                let tags: Vec<String> = row
                    .tag_string_general
                    .split_whitespace()
                    .take(8)
                    .map(|t| t.to_string())
                    .collect();

                let mut item = scrape::normalize(
                    "danbooru",
                    &row.id.to_string(),
                    row.tag_string_character.split_whitespace().next().unwrap_or_default(),
                    &row.file_url,
                    &row.preview_file_url,
                    &format!("https://danbooru.donmai.us/posts/{}", row.id),
                    row.image_width,
                    row.image_height,
                    tags,
                );
                item.bytes = row.file_size;
                item.sample = row.large_file_url.clone();
                item.nsfw = row.rating != "g";
                item.author = row.tag_string_artist.split_whitespace().next().unwrap_or_default().to_string();
                if !row.file_ext.is_empty() {
                    item.ext = row.file_ext.clone();
                    item.animated = row.file_ext == "gif";
                }
                item
            })
            .collect())
    }

    fn has_more(&self, body: &str) -> bool {
        serde_json::from_str::<Vec<Row>>(body).map(|r| !r.is_empty()).unwrap_or(false)
    }
}
