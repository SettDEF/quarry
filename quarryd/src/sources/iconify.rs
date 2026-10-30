//! Iconify — the `icon` kind, solved in one adapter.
//!
//! Two hundred thousand icons across every published set, keyless, addressed by
//! a `prefix:name` pair that is also the path to the SVG. Nothing has to be
//! crawled: the search endpoint returns the names, and the name is the URL.

use serde::Deserialize;

use super::{Capabilities, Source, SourceQuery};
use crate::protocol::Item;
use crate::scrape;

pub struct Iconify;

/// One screen of the icon grid, with a row of headroom.
const PER_PAGE: u32 = 64;

/// How deep the search window goes at all.
///
/// `limit` is not a page size here — it is the size of the whole result set,
/// and `start` only offsets inside it. The service clamps it to 999 and answers
/// a `start` past that with a bare `400 Bad request`, so the scroll ends there
/// whether or not more icons match.
const MAX_RESULTS: u32 = 999;

/// An empty `query` is a 400, not an empty page, so a browse with no term needs
/// a seed. This one spans nearly every set, which is what makes it a browse
/// rather than a search result.
const BROWSE: &str = "home";

#[derive(Debug, Deserialize)]
struct Response {
    #[serde(default)]
    icons: Vec<String>,
    #[serde(default)]
    start: u32,
}

impl Iconify {
    /// Iconify's search endpoint matches icon names and keywords, not set
    /// prefixes — "mdi" or "heroicons" typed as a query mostly misses or comes
    /// back empty. These are icon subjects, each checked live against
    /// api.iconify.design/search and confirmed to fill a page.
    pub fn popular_groups() -> &'static [(&'static str, &'static [&'static str])] {
        &[
            ("Interface", &["menu", "search", "settings", "close", "check", "arrow"]),
            ("Objects", &["mail", "calendar", "camera", "cart", "bell", "clock", "folder"]),
            ("Weather & nature", &["sun", "moon", "cloud", "rain", "snow", "leaf", "fire"]),
            ("Brands", &["github", "twitter", "discord", "youtube", "spotify", "instagram"]),
        ]
    }
}

impl Source for Iconify {
    fn id(&self) -> &'static str {
        "iconify"
    }

    fn category(&self) -> &'static str {
        "icons"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            author: false,
            text: true,
            // An icon has no resolution to filter on — that is the point of it.
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

    fn build_url(&self, query: &SourceQuery) -> String {
        let text =
            query.text.iter().chain(query.tags.iter()).cloned().collect::<Vec<_>>().join(" ");
        let term = if text.is_empty() { BROWSE } else { text.as_str() };

        // Both parameters move together: `limit` has to grow to cover the row
        // being asked for, because a `start` at or past it is a 400 rather than
        // an empty page. `limit=64&start=64` is rejected; `limit=128&start=64`
        // is the second page.
        let start = ((query.page.max(1) - 1) * PER_PAGE).min(MAX_RESULTS - 1);
        format!(
            "https://api.iconify.design/search?query={}&limit={}&start={}",
            scrape::urlencode(term),
            (start + PER_PAGE).min(MAX_RESULTS),
            start
        )
    }

    fn parse(&self, body: &str) -> Result<Vec<Item>, String> {
        let response: Response =
            serde_json::from_str(body).map_err(|e| format!("iconify json: {e}"))?;

        Ok(response
            .icons
            .into_iter()
            .filter_map(|id| {
                let (prefix, name) = id.split_once(':')?;
                let mut item = scrape::normalize(
                    "iconify",
                    &id,
                    name,
                    &format!("https://api.iconify.design/{prefix}/{name}.svg"),
                    "",
                    &format!("https://icon-sets.iconify.design/{prefix}/{name}/"),
                    0,
                    0,
                    vec![prefix.to_string()],
                );
                // The search response carries no geometry, and an icon set is
                // authored on a square grid — a tile laid out as a square is
                // right far more often than one laid out as nothing.
                item.ratio = 1.0;
                // Iconify serves the monotone sets — the great majority — with
                // `currentColor`, so recolouring is the normal case here rather
                // than a detected exception. The palette sets (twemoji, logos)
                // are told apart at index time, with the SVG in hand.
                item.tintable = true;
                Some(item)
            })
            .collect())
    }

    fn has_more(&self, body: &str) -> bool {
        serde_json::from_str::<Response>(body)
            .map(|r| r.icons.len() as u32 >= PER_PAGE && r.start + PER_PAGE < MAX_RESULTS)
            .unwrap_or(false)
    }
}
