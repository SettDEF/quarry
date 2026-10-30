//! DuckDuckGo Images — a second whole-web image search.
//!
//! Asked the way its own results page asks, in two steps:
//!
//! 1. `https://duckduckgo.com/?q=…&iax=images&ia=images` — an ordinary search
//!    page, which carries a `vqd` token for that query;
//! 2. `https://duckduckgo.com/i.js?q=…&vqd=…&o=json&p=…&s=…` — the JSON the
//!    page loads its tiles from. Without the token it answers 403.
//!
//! Step 1 happens inside `build_url` (see `prefetch`), once per query: the
//! token is cached, so every later page — and endless scroll asks for several
//! at once — is only step 2.
//!
//! Rows carry `image` (the original), `thumbnail` (a Bing-served proxy),
//! `url` (the page), `title`, `width`, `height`, `source`. Paging is an offset
//! in hundreds: the answer's `next` names `s=100` after the first page,
//! whatever the row count was. `p=1` is SafeSearch on, `p=-1` off.
//!
//! Probed 2026-09-15: `red car` answered 81 rows on page 1 and 93 different
//! rows on page 2 (`s=100`), no overlap. Answers the daemon's own User-Agent;
//! a browser User-Agent without a browser behind it got 403.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use super::{Capabilities, Source, SourceQuery};
use crate::protocol::Item;
use crate::scrape;

pub struct DuckDuckGo;

const OFFSET_STEP: u32 = 100;

/// A token outlives a search session, but not by days.
const TOKEN_FOR: Duration = Duration::from_secs(20 * 60);

static TOKENS: Mutex<Option<HashMap<String, (Instant, String)>>> = Mutex::new(None);

/// Read the `vqd` token out of a search page.
pub fn vqd_from(html: &str) -> Option<String> {
    scrape::regex_all(html, r#"vqd=["']?(\d+-[\d-]+)["']?"#, 1)
        .ok()
        .and_then(|found| found.into_iter().next())
}

/// The token for `terms`, from the cache or from DuckDuckGo.
fn vqd_for(terms: &str) -> Option<String> {
    if let Ok(guard) = TOKENS.lock() {
        if let Some((at, token)) = guard.as_ref().and_then(|m| m.get(terms)) {
            if at.elapsed() < TOKEN_FOR {
                return Some(token.clone());
            }
        }
    }

    let page = format!(
        "https://duckduckgo.com/?q={}&iax=images&ia=images",
        scrape::urlencode(terms)
    );
    let token = match super::prefetch::get(&page) {
        Ok(html) => vqd_from(&html),
        Err(e) => {
            if !cfg!(test) {
                eprintln!("[quarryd] duckduckgo: could not open the search page for a token — {e}");
            }
            None
        }
    }?;

    if let Ok(mut guard) = TOKENS.lock() {
        let map = guard.get_or_insert_with(HashMap::new);
        if map.len() > 500 {
            map.clear();
        }
        map.insert(terms.to_string(), (Instant::now(), token.clone()));
    }
    Some(token)
}

fn size_filter(min_w: u32, min_h: u32) -> &'static str {
    match min_w.max(min_h) {
        w if w >= 1600 => "size:Wallpaper",
        w if w >= 800 => "size:Large",
        w if w >= 300 => "size:Medium",
        _ => "",
    }
}

impl DuckDuckGo {
    /// The i.js URL for a query, given its token. Separate from `build_url`
    /// so it can be tested without the token request.
    pub fn images_url(query: &SourceQuery, vqd: Option<&str>) -> String {
        let terms = super::bing::search_terms(query);
        let safe = if query.allow_nsfw == Some(false) { "1" } else { "-1" };
        let filters = format!(",{},,,,", size_filter(query.min_w, query.min_h));
        let mut url = format!(
            "https://duckduckgo.com/i.js?l=us-en&o=json&q={}",
            scrape::urlencode(&terms)
        );
        if let Some(vqd) = vqd {
            url.push_str(&format!("&vqd={vqd}"));
        }
        url.push_str(&format!("&f={}&p={safe}", scrape::urlencode(&filters)));
        let offset = (query.page.max(1) - 1) * OFFSET_STEP;
        if offset > 0 {
            url.push_str(&format!("&s={offset}"));
        }
        url
    }
}

impl Source for DuckDuckGo {
    fn id(&self) -> &'static str {
        "duckduckgo"
    }

    fn category(&self) -> &'static str {
        "photography"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            author: false,
            text: true,
            tags: true,
            // A coarse bucket; the exact minimum is re-checked locally.
            min_size: true,
            ratio: false,
            nsfw: true,
            sort: false,
            video: false,
            colors: false,
            categories: Vec::new(),
        }
    }

    fn build_url(&self, query: &SourceQuery) -> String {
        let terms = super::bing::search_terms(query);
        // Without a token the request still goes out and is refused with a
        // 403, which names the failure; a made-up token would not.
        let vqd = vqd_for(&terms);
        Self::images_url(query, vqd.as_deref())
    }

    fn parse(&self, body: &str) -> Result<Vec<Item>, String> {
        let document: serde_json::Value = serde_json::from_str(body).map_err(|_| {
            if body.contains("If this error persists") {
                "duckduckgo refused the request (no valid vqd token for this query)".to_string()
            } else {
                "duckduckgo: the answer was not JSON".to_string()
            }
        })?;
        let rows = document
            .get("results")
            .and_then(|v| v.as_array())
            .ok_or_else(|| "duckduckgo: no results list in the answer".to_string())?;

        let mut items = Vec::with_capacity(rows.len());
        for row in rows {
            let url = scrape::json_str(row, "image");
            if !url.starts_with("http") {
                continue;
            }
            let id = match scrape::json_str(row, "image_token") {
                token if !token.is_empty() => token,
                _ => super::bing::url_id(&url),
            };
            let w = scrape::json_pluck(row, "width").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
            let h = scrape::json_pluck(row, "height").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
            let page_url = scrape::json_str(row, "url");

            let mut item = scrape::normalize(
                self.id(),
                &id,
                &scrape::json_str(row, "title"),
                &url,
                &scrape::json_str(row, "thumbnail"),
                &page_url,
                w,
                h,
                Vec::new(),
            );
            item.author = scrape::host_of(&page_url).unwrap_or_default();
            items.push(item);
        }
        Ok(items)
    }

    fn has_more(&self, body: &str) -> bool {
        serde_json::from_str::<serde_json::Value>(body)
            .ok()
            .map(|d| {
                let next = d.get("next").and_then(|v| v.as_str()).unwrap_or_default();
                let rows = d.get("results").and_then(|v| v.as_array()).map(|r| r.len()).unwrap_or(0);
                !next.is_empty() && rows > 0
            })
            .unwrap_or(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../../tests/fixtures/duckduckgo-i.json");

    #[test]
    fn reads_the_token_from_a_search_page() {
        let html = r#"<html><script>DDG.deep.initialize('/d.js?q=blue%20boat&l=us-en&s=0&dl=en&ct=DE&vqd=4-123456789012345678901234567890123456789&bing_market=en-US');</script></html>"#;
        assert_eq!(vqd_from(html).as_deref(), Some("4-123456789012345678901234567890123456789"));
        let quoted = r#"<script>vqd="4-98765432109876543210"</script>"#;
        assert_eq!(vqd_from(quoted).as_deref(), Some("4-98765432109876543210"));
        assert_eq!(vqd_from("<html>nothing</html>"), None);
    }

    #[test]
    fn url_pages_by_hundreds_and_maps_safe_search() {
        let q = SourceQuery { text: vec!["blue".into(), "boat".into()], page: 1, ..Default::default() };
        let url = DuckDuckGo::images_url(&q, Some("4-1"));
        assert!(url.starts_with("https://duckduckgo.com/i.js?l=us-en&o=json&q=blue+boat&vqd=4-1&"), "{url}");
        assert!(url.ends_with("&p=-1"), "no -nsfw means SafeSearch off: {url}");
        assert!(!url.contains("&s="), "{url}");

        let q3 = SourceQuery { page: 3, allow_nsfw: Some(false), min_w: 2560, ..q };
        let url = DuckDuckGo::images_url(&q3, Some("4-1"));
        assert!(url.contains("&p=1&s=200"), "{url}");
        assert!(url.contains("size%3AWallpaper"), "{url}");
    }

    #[test]
    fn build_url_without_network_still_names_the_query() {
        // Under test the token request fails; the URL is still the real
        // endpoint for the real words, and DuckDuckGo's 403 will say why.
        let q = SourceQuery { text: vec!["kite".into()], page: 1, ..Default::default() };
        let url = DuckDuckGo.build_url(&q);
        assert!(url.contains("q=kite"), "{url}");
        assert!(!url.contains("vqd="), "{url}");
    }

    #[test]
    fn parses_rows_with_every_field_it_is_given() {
        let items = DuckDuckGo.parse(FIXTURE).expect("parses");
        assert_eq!(items.len(), 2, "a row with no image URL is skipped");
        let first = &items[0];
        assert_eq!(first.source, "duckduckgo");
        assert_eq!(first.source_id, "fake-token-1");
        assert_eq!(first.url, "https://photos.example.org/full/kite.jpg");
        assert_eq!(first.thumb, "https://tse4.mm.bing.net/th?id=OIP.fakekite&pid=Api");
        assert_eq!(first.page_url, "https://photos.example.org/kites/red");
        assert_eq!(first.title, "A red kite over a field");
        assert_eq!((first.w, first.h), (2400, 1600));
        assert!((first.ratio - 1.5).abs() < 1e-9);
        assert!(DuckDuckGo.has_more(FIXTURE));
    }

    #[test]
    fn the_last_page_and_a_refusal_are_told_apart() {
        let last = r#"{"results":[],"next":null,"query":"kite"}"#;
        assert!(DuckDuckGo.parse(last).expect("empty is fine").is_empty());
        assert!(!DuckDuckGo.has_more(last));
        let refused = "If this error persists, please let us know: ops@duckduckgo.com";
        assert!(DuckDuckGo.parse(refused).unwrap_err().contains("vqd"));
    }
}
