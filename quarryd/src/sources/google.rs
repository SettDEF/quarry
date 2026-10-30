//! Google Images, through the Custom Search JSON API.
//!
//! A key, because Google has no endpoint a program can read any more: `tbm=isch`
//! answers a 302 to consent or `/sorry/` without a real browser (re-checked
//! 2026-09-17) and the `asearch=ichunk` partial is gone. `searxng.rs` is the
//! keyless half of the same job — Google is one of the engines it merges.
//!
//! ## Setting it up (five minutes, no billing account)
//!
//! 1. Create an engine at
//!    <https://programmablesearchengine.google.com/controlpanel/create>.
//! 2. Setup → Basics: switch **"Search the entire web"** on and delete the
//!    placeholder site. An engine restricted to sites searches those sites.
//! 3. Same page: switch **"Image search"** on, or `searchType=image` answers an
//!    empty `items` for every query — which reads as "no results", not "not set up".
//! 4. Copy the **Search engine ID** into `$GOOGLE_CSE_CX`.
//! 5. Get a key from the "Get a Key" button at
//!    <https://developers.google.com/custom-search/v1/introduction> → `$GOOGLE_CSE_KEY`.
//!
//! ## The free limit
//!
//! **100 requests per day per project**, then HTTP 429 `rateLimitExceeded` until
//! midnight Pacific unless billing is on ($5/1000, capped at 10k/day). That is
//! 100 *pages* of at most 10 results (`num` is capped at 10), so one endless
//! scroll can spend a tenth of the day. With the vars unset the source does not
//! register at all, the way an `[auth]` manifest behaves.
//!
//! ## The request
//!
//! `GET …/customsearch/v1?key=…&cx=…&searchType=image&q=…&num=10&start=N&safe=active|off`
//!
//! `start` is one-based and `start + num - 1 <= 100`, so page 10 (`start=91`) is
//! the last; past that it is a 400. Rows carry `link`, `title`, `displayLink`,
//! `mime` and an `image` object with `contextLink`, `thumbnailLink`, `width`,
//! `height`, `byteSize`.
//!
//! Verified 2026-09-17: the endpoint is live and answers 403 "Method doesn't
//! allow unregistered callers" with no key, which is what makes the unset case a
//! clean "not configured". The row shape is the documented one — this checkout
//! has no key to exercise it against.

use std::sync::Once;

use super::{Capabilities, Source, SourceQuery};
use crate::protocol::Item;
use crate::scrape;

/// Google's own cap. Asking for more is a 400, not a bigger page.
pub const PER_PAGE: u32 = 10;

/// `start + num - 1 <= 100`, so page 10 starts at 91 and there is no page 11.
const MAX_PAGES: u32 = 10;

pub const KEY_VAR: &str = "GOOGLE_CSE_KEY";
pub const CX_VAR: &str = "GOOGLE_CSE_CX";

/// The one-click hint a `[auth]` manifest would log.
const HINT: &str = "create a Programmable Search Engine set to \"search the entire web\" with image search on at https://programmablesearchengine.google.com/controlpanel/create (that gives $GOOGLE_CSE_CX), and a key from https://developers.google.com/custom-search/v1/introduction — 100 searches a day free";

static ANNOUNCED: Once = Once::new();

pub struct Google {
    key: String,
    cx: String,
}

impl Google {
    /// The source, or nothing plus a one-off line naming the missing variable.
    /// Nothing, rather than a source that 403s on every query — a caller has to
    /// be able to tell those apart.
    pub fn from_env() -> Option<Google> {
        Self::from_vars(|name| std::env::var(name).ok())
    }

    /// The same against a lookup function, so a test can exercise "one set, one
    /// not" without racing the process-global environment.
    pub fn from_vars(get: impl Fn(&str) -> Option<String>) -> Option<Google> {
        let value = |name: &str| {
            get(name).map(|v| v.trim().to_string()).filter(|v| !v.is_empty())
        };
        // A blank var is a half-finished setup, not a credential.
        match (value(KEY_VAR), value(CX_VAR)) {
            (Some(key), Some(cx)) => Some(Google { key, cx }),
            (key, cx) => {
                let mut missing = Vec::new();
                if key.is_none() {
                    missing.push(KEY_VAR);
                }
                if cx.is_none() {
                    missing.push(CX_VAR);
                }
                if !cfg!(test) {
                    ANNOUNCED.call_once(|| {
                        eprintln!(
                            "[quarryd] google image search is off — ${} not set — {HINT}",
                            missing.join(", $")
                        );
                    });
                }
                None
            }
        }
    }

    /// The request URL — split out so it is testable without a key on the machine.
    pub fn search_url(key: &str, cx: &str, query: &SourceQuery) -> String {
        let start = (query.page.max(1) - 1) * PER_PAGE + 1;
        // Only `-nsfw` asks for `active`; a query that did not say stays unfiltered.
        let safe = if query.allow_nsfw == Some(false) { "active" } else { "off" };
        format!(
            "https://www.googleapis.com/customsearch/v1?key={}&cx={}&searchType=image&q={}&num={PER_PAGE}&start={start}&safe={safe}",
            scrape::urlencode(key),
            scrape::urlencode(cx),
            scrape::urlencode(&super::bing::search_terms(query)),
        )
    }
}

/// Turn an API error document into a sentence naming the fix.
fn api_error(document: &serde_json::Value) -> Option<String> {
    let error = document.get("error")?;
    let code = error.get("code").and_then(|v| v.as_u64()).unwrap_or(0);
    let reason = scrape::json_str(error, "errors[0].reason");
    let message = scrape::json_str(error, "message");

    Some(match reason.as_str() {
        "dailyLimitExceeded" | "rateLimitExceeded" | "quotaExceeded" =>
            "google: this key's free quota is spent — the Custom Search JSON API allows 100 searches a day, and it resets at midnight Pacific"
                .to_string(),
        "keyInvalid" | "badRequest" if message.contains("API key") => {
            format!("google: ${KEY_VAR} was refused — {message}")
        }
        "invalid" if message.to_lowercase().contains("cx") => {
            format!("google: ${CX_VAR} was refused — {message}")
        }
        _ if code == 403 => format!("google: refused ({code}) — {message} — {HINT}"),
        _ => format!("google: {code} {message}"),
    })
}

impl Source for Google {
    fn id(&self) -> &'static str {
        "google"
    }

    fn category(&self) -> &'static str {
        "photography"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            author: false,
            text: true,
            tags: true,
            // `imgSize` picks one bucket, not a floor: `xlarge` for `w>=800`
            // would drop every `huge` row that also satisfies it. Every row
            // carries its real size, so the minimum is applied locally instead.
            min_size: false,
            ratio: false,
            nsfw: true,
            sort: false,
            video: false,
            colors: false,
            categories: Vec::new(),
        }
    }

    fn build_url(&self, query: &SourceQuery) -> String {
        Self::search_url(&self.key, &self.cx, query)
    }

    fn parse(&self, body: &str) -> Result<Vec<Item>, String> {
        let document: serde_json::Value = serde_json::from_str(body)
            .map_err(|_| "google: the answer was not JSON".to_string())?;

        if let Some(message) = api_error(&document) {
            return Err(message);
        }

        // Past the end there is no `items` key at all — a real "no more".
        let Some(rows) = document.get("items").and_then(|v| v.as_array()) else {
            return Ok(Vec::new());
        };

        let mut items = Vec::with_capacity(rows.len());
        for row in rows {
            let url = scrape::json_str(row, "link");
            if !url.starts_with("http") {
                continue;
            }
            let page_url = scrape::json_str(row, "image.contextLink");
            let w = scrape::json_pluck(row, "image.width").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
            let h = scrape::json_pluck(row, "image.height").and_then(|v| v.as_u64()).unwrap_or(0) as u32;

            let mut item = scrape::normalize(
                self.id(),
                &super::bing::url_id(&url),
                &scrape::json_str(row, "title"),
                &url,
                &scrape::json_str(row, "image.thumbnailLink"),
                &page_url,
                w,
                h,
                Vec::new(),
            );
            // The publishing site: the closest thing to an author a web result has.
            item.author = match scrape::json_str(row, "displayLink") {
                named if !named.is_empty() => named,
                _ => scrape::host_of(&page_url).unwrap_or_default(),
            };
            item.bytes = scrape::json_pluck(row, "image.byteSize")
                .and_then(|v| v.as_u64())
                .unwrap_or(0);
            items.push(item);
        }
        Ok(items)
    }

    fn has_more(&self, body: &str) -> bool {
        serde_json::from_str::<serde_json::Value>(body)
            .ok()
            .map(|d| {
                scrape::json_pluck(&d, "queries.nextPage[0].startIndex")
                    .and_then(|v| v.as_u64())
                    // `nextPage` is published even for a start index Google refuses.
                    .map(|start| start as u32 + PER_PAGE - 1 <= 100)
                    .unwrap_or(false)
            })
            .unwrap_or(false)
    }

    fn page_limit(&self) -> Option<u32> {
        Some(MAX_PAGES)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../../tests/fixtures/google-cse-images.json");

    fn google() -> Google {
        Google { key: "test-key".into(), cx: "0123:abcd".into() }
    }

    #[test]
    fn url_carries_the_keys_the_words_the_page_and_safe_search() {
        let q = SourceQuery {
            text: vec!["mountain".into(), "lake".into()],
            page: 1,
            ..Default::default()
        };
        let url = google().build_url(&q);
        assert!(url.starts_with("https://www.googleapis.com/customsearch/v1?key=test-key&cx=0123%3Aabcd&"), "{url}");
        assert!(url.contains("searchType=image"), "{url}");
        assert!(url.contains("q=mountain+lake"), "{url}");
        assert!(url.contains("&num=10&start=1"), "{url}");
        assert!(url.ends_with("&safe=off"), "nothing said means no filter: {url}");
    }

    #[test]
    fn pages_ten_at_a_time_and_stops_where_the_api_does() {
        let base = SourceQuery { text: vec!["red".into(), "car".into()], ..Default::default() };
        let start = |page| {
            let url = google().build_url(&SourceQuery { page, ..base.clone() });
            url.split("&start=").nth(1).unwrap().split('&').next().unwrap().to_string()
        };
        assert_eq!(start(1), "1");
        assert_eq!(start(2), "11");
        assert_eq!(start(10), "91");
        // Page 0 is the caller not having said.
        assert_eq!(start(0), "1");
        assert_eq!(google().page_limit(), Some(10), "start=101 is a 400 from Google");
    }

    #[test]
    fn pushdown_sends_minus_nsfw_as_safe_active() {
        let parsed = crate::query::parse("cyberpunk city -nsfw");
        let (pushed, residue) = crate::sources::pushdown(&parsed, &google().capabilities());
        assert_eq!(pushed.text, vec!["cyberpunk", "city"]);
        assert_eq!(pushed.allow_nsfw, Some(false));
        assert!(residue.clauses.is_empty());
        assert!(google().build_url(&pushed).ends_with("&safe=active"));
    }

    #[test]
    fn a_minimum_size_stays_local_rather_than_becoming_a_bucket() {
        let parsed = crate::query::parse("mountain lake w>=1920");
        let (pushed, residue) = crate::sources::pushdown(&parsed, &google().capabilities());
        assert_eq!(pushed.min_w, 0, "imgSize is a bucket, not a floor");
        // It lands in the residue twice — `pushdown` re-adds every minimum on
        // top of the fallthrough — which is harmless: same predicate, same answer.
        assert!(
            residue.clauses.iter().all(|c| matches!(&c.term, crate::query::Term::Number { key, .. } if key == "w")),
            "only the width minimum is left over"
        );
        assert!(!residue.clauses.is_empty());
        assert!(!google().build_url(&pushed).contains("imgSize"));
    }

    #[test]
    fn the_source_exists_only_when_both_variables_are_set() {
        assert!(Google::from_vars(|_| None).is_none());
        assert!(Google::from_vars(|name| (name == KEY_VAR).then(|| "k".to_string())).is_none());
        assert!(Google::from_vars(|name| (name == CX_VAR).then(|| "c".to_string())).is_none());
        // A blank value is a half-finished setup, not a credential.
        assert!(Google::from_vars(|_| Some("   ".to_string())).is_none());

        let both = Google::from_vars(|name| {
            Some(if name == KEY_VAR { "k".to_string() } else { "c".to_string() })
        })
        .expect("both set");
        assert_eq!((both.key.as_str(), both.cx.as_str()), ("k", "c"));
    }

    #[test]
    fn parses_rows_with_image_thumb_page_title_size_and_publisher() {
        let items = google().parse(FIXTURE).expect("parses");
        assert_eq!(items.len(), 2, "the row with no link is skipped");

        let first = &items[0];
        assert_eq!(first.source, "google");
        assert_eq!(first.source_id, super::super::bing::url_id(&first.url));
        assert_eq!(first.url, "https://photos.example.org/full/lake.jpg");
        assert_eq!(first.thumb, "https://encrypted-tbn0.example.net/images?q=fake1");
        assert_eq!(first.page_url, "https://photos.example.org/gallery/lake");
        assert_eq!(first.title, "A mountain lake at dawn");
        assert_eq!((first.w, first.h), (2133, 1600));
        assert_eq!(first.author, "photos.example.org");
        assert_eq!(first.bytes, 481_923);

        // No displayLink: the host comes off the context link.
        assert_eq!(items[1].author, "cars.example.com");

        assert!(google().has_more(FIXTURE));
    }

    #[test]
    fn the_last_page_is_not_more() {
        // `nextPage` starting past Google's own 100-result ceiling.
        let tail = r#"{"queries":{"nextPage":[{"startIndex":101}]},"items":[]}"#;
        assert!(!google().has_more(tail));
        // No `nextPage` at all.
        let end = r#"{"queries":{"request":[{"startIndex":91}]}}"#;
        assert!(!google().has_more(end));
        assert!(google().parse(end).expect("no items is fine").is_empty());
    }

    #[test]
    fn an_api_error_says_which_variable_or_which_limit() {
        let quota = r#"{"error":{"code":429,"message":"Quota exceeded","errors":[{"reason":"rateLimitExceeded"}]}}"#;
        let err = google().parse(quota).unwrap_err();
        assert!(err.contains("100 searches a day"), "{err}");

        let unregistered = r#"{"error":{"code":403,"message":"Method doesn't allow unregistered callers","errors":[{"reason":"forbidden"}]}}"#;
        let err = google().parse(unregistered).unwrap_err();
        assert!(err.contains("programmablesearchengine"), "the error must name the fix: {err}");

        let bad_key = r#"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","errors":[{"reason":"badRequest"}]}}"#;
        assert!(google().parse(bad_key).unwrap_err().contains(KEY_VAR));

        assert!(google().parse("<html>nope</html>").unwrap_err().contains("not JSON"));
    }
}
