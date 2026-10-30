//! Bing Images — the whole web, searched with the words as typed.
//!
//! Every other source searches one site. This one answers what a person gets
//! typing the same words into Bing's image search: pictures from anywhere,
//! ranked by Bing. It is the source that makes a query that no board has a
//! tag for still come back with something that is actually about it.
//!
//! The endpoint is the one the results page itself calls while you scroll,
//! `/images/async`, which answers server-rendered HTML with no script needed.
//! Each result is an `<a class="iusc" m="{…}">` whose `m` attribute is
//! HTML-escaped JSON:
//!
//!   murl  the original image, on the host that published it
//!   turl  Bing's own thumbnail (tse*.mm.bing.net), always fetchable
//!   purl  the page the image was found on
//!   t     the title   · md5 a stable id
//!
//! The pixel size is not in `m`; it is the `<span class="nowrap">W&#215;H`
//! caption printed under the same tile.
//!
//! Probed 2026-09-15: 35 rows per page for `mountain lake`, page 2 (`first=36`)
//! a different 35 with Bing's usual four-row overlap, which `dedupe` absorbs.
//! Answers the daemon's own User-Agent.

use super::{Capabilities, Source, SourceQuery};
use crate::protocol::Item;
use crate::scrape;

pub struct Bing;

pub const PER_PAGE: u32 = 35;

/// Bing stops returning new images after roughly a thousand; past that it
/// serves the tail again, which would look like a crawl that never ends.
const MAX_PAGES: u32 = 28;

/// A stable short id for a URL, when the row carries none of its own.
pub(crate) fn url_id(url: &str) -> String {
    let mut hash: u64 = 0xcbf29ce484222325;
    for b in url.as_bytes() {
        hash ^= *b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

/// Bing marks the matched words in titles with private-use characters.
fn clean_title(title: &str) -> String {
    title.chars().filter(|c| !('\u{e000}'..='\u{f8ff}').contains(c)).collect::<String>().trim().to_string()
}

/// The words to search for — or, with none, something worth browsing.
pub(crate) fn search_terms(query: &SourceQuery) -> String {
    let terms: Vec<&str> =
        query.text.iter().chain(query.tags.iter()).map(|s| s.as_str()).collect();
    if !terms.is_empty() {
        return terms.join(" ");
    }
    match query.kind.as_str() {
        "avatar" => "avatar art".to_string(),
        "banner" => "banner art".to_string(),
        "icon" => "icon".to_string(),
        _ => "4k wallpaper".to_string(),
    }
}

impl Source for Bing {
    fn id(&self) -> &'static str {
        "bing"
    }

    fn category(&self) -> &'static str {
        "photography"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            author: false,
            text: true,
            // A tag is just more words to a web search.
            tags: true,
            // `imagesize-custom_W_H` is a real minimum; still re-checked
            // locally, as every pushed minimum is.
            min_size: true,
            ratio: false,
            // SafeSearch: `-nsfw` asks for strict.
            nsfw: true,
            sort: false,
            video: false,
            colors: false,
            categories: Vec::new(),
        }
    }

    fn build_url(&self, query: &SourceQuery) -> String {
        let first = (query.page.max(1) - 1) * PER_PAGE + 1;
        let adult = if query.allow_nsfw == Some(false) { "strict" } else { "off" };
        let mut url = format!(
            "https://www.bing.com/images/async?q={}&first={first}&count={PER_PAGE}&adlt={adult}&mmasync=1",
            scrape::urlencode(&search_terms(query)),
        );
        if query.min_w > 0 || query.min_h > 0 {
            url.push_str(&format!(
                "&qft={}",
                scrape::urlencode(&format!(
                    "+filterui:imagesize-custom_{}_{}",
                    query.min_w.max(1),
                    query.min_h.max(1)
                ))
            ));
        }
        url
    }

    fn parse(&self, body: &str) -> Result<Vec<Item>, String> {
        // Split at every result tile; each piece holds one `m` and, after it,
        // that tile's size caption.
        let starts: Vec<usize> = body.match_indices("class=\"iusc\"").map(|(i, _)| i).collect();
        if starts.is_empty() {
            let lowered = body.to_lowercase();
            if lowered.contains("captcha") || lowered.contains("/challenge") {
                return Err("bing asked for a captcha — it is rate-limiting this address".into());
            }
            // A page past the end is an empty body or a bare list; that is a
            // real "no more", not a failure.
            return Ok(Vec::new());
        }

        let mut items = Vec::with_capacity(starts.len());
        for (n, start) in starts.iter().enumerate() {
            let end = starts.get(n + 1).copied().unwrap_or(body.len());
            let chunk = &body[*start..end];

            let Some(raw) = scrape::regex_all(chunk, r#"\bm="(\{[^"]*\})""#, 1)
                .ok()
                .and_then(|m| m.into_iter().next())
            else {
                continue;
            };
            let Ok(meta) = serde_json::from_str::<serde_json::Value>(&scrape::html_unescape(&raw))
            else {
                continue;
            };

            let url = scrape::json_str(&meta, "murl");
            if !url.starts_with("http") {
                continue;
            }
            let id = match scrape::json_str(&meta, "md5") {
                md5 if !md5.is_empty() => md5,
                _ => url_id(&url),
            };

            let (w, h) = scrape::regex_captures(
                chunk,
                r#"class="nowrap">\s*(?P<w>\d{1,5})\s*(?:&#215;|×|x)\s*(?P<h>\d{1,5})"#,
            )
            .ok()
            .and_then(|rows| rows.into_iter().next())
            .map(|row| {
                (
                    row.get("w").and_then(|v| v.parse().ok()).unwrap_or(0),
                    row.get("h").and_then(|v| v.parse().ok()).unwrap_or(0),
                )
            })
            .unwrap_or((0, 0));

            let page_url = scrape::json_str(&meta, "purl");
            let mut item = scrape::normalize(
                self.id(),
                &id,
                &clean_title(&scrape::json_str(&meta, "t")),
                &url,
                &scrape::json_str(&meta, "turl"),
                &page_url,
                w,
                h,
                Vec::new(),
            );
            // The site that published it is the closest thing to an author a
            // web result has.
            item.author = scrape::host_of(&page_url).unwrap_or_default();
            items.push(item);
        }
        Ok(items)
    }

    fn has_more(&self, body: &str) -> bool {
        body.contains("class=\"iusc\"")
    }

    fn page_limit(&self) -> Option<u32> {
        Some(MAX_PAGES)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../../tests/fixtures/bing-images-async.html");

    #[test]
    fn url_carries_the_words_the_page_and_safe_search() {
        let q = SourceQuery { text: vec!["blue".into(), "boat".into()], page: 1, ..Default::default() };
        let url = Bing.build_url(&q);
        assert!(url.starts_with("https://www.bing.com/images/async?q=blue+boat&"), "{url}");
        assert!(url.contains("first=1&count=35"), "{url}");
        assert!(url.contains("adlt=off"), "{url}");

        let q2 = SourceQuery { page: 2, allow_nsfw: Some(false), min_w: 2560, min_h: 1440, ..q };
        let url = Bing.build_url(&q2);
        assert!(url.contains("first=36"), "{url}");
        assert!(url.contains("adlt=strict"), "{url}");
        assert!(url.contains("imagesize-custom_2560_1440"), "{url}");
    }

    #[test]
    fn pushdown_sends_minus_nsfw_as_strict() {
        let parsed = crate::query::parse("blue boat -nsfw");
        let (pushed, residue) = crate::sources::pushdown(&parsed, &Bing.capabilities());
        assert_eq!(pushed.text, vec!["blue", "boat"]);
        assert_eq!(pushed.allow_nsfw, Some(false));
        assert!(residue.clauses.is_empty());
        assert!(Bing.build_url(&pushed).contains("adlt=strict"));
    }

    #[test]
    fn parses_tiles_with_full_url_thumb_page_title_and_size() {
        let items = Bing.parse(FIXTURE).expect("parses");
        assert_eq!(items.len(), 3);

        let first = &items[0];
        assert_eq!(first.source, "bing");
        assert_eq!(first.source_id, "0a1b2c3d4e5f60718293a4b5c6d7e8f9");
        assert_eq!(first.url, "https://photos.example.org/full/boat-1.jpg");
        assert_eq!(first.thumb, "https://tse1.mm.bing.net/th?id=OIP.fake1&pid=Api");
        assert_eq!(first.page_url, "https://photos.example.org/gallery/boat?a=1&b=2");
        assert_eq!(first.title, "A blue boat on a lake");
        assert_eq!((first.w, first.h), (1920, 1080));
        assert_eq!(first.author, "photos.example.org");

        // A tile with no caption still parses, with no size.
        assert_eq!((items[2].w, items[2].h), (0, 0));
        // No md5: an id derived from the URL, stable run to run.
        assert_eq!(items[2].source_id, url_id("https://img.example.net/p/3.png"));

        assert!(Bing.has_more(FIXTURE));
    }

    #[test]
    fn a_page_past_the_end_is_empty_not_an_error() {
        assert!(Bing.parse("<ul></ul>").expect("empty is fine").is_empty());
        assert!(!Bing.has_more("<ul></ul>"));
        assert!(Bing.parse("<html>please solve this captcha</html>").is_err());
    }
}
