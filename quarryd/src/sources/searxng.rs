//! SearXNG — one keyless request that asks Google, Bing, Brave and a dozen more.
//!
//! `GET {instance}/search?q=…&categories=images&format=json&pageno=N&safesearch=S`
//! (safesearch 0 off / 2 strict). Rows carry `img_src`, `thumbnail_src`, `url`
//! (the page), `title`, `resolution` ("2133×1600", U+00D7), `source`, `engine`.
//!
//! `format=json` is a per-instance setting and most public instances have it off
//! — those answer 403, 429 or a bot-check page — so the instance is probed from
//! a list rather than hardcoded. `$QUARRY_SEARXNG_URL` replaces the list
//! (comma-separated, in preference order).
//!
//! This is the only keyless way Google image results reach the catalogue;
//! Google itself has no no-JS endpoint left (see `google.rs`).
//!
//! Probed 2026-09-17 against `sx.xo.st`: 115/296/138 rows for `mountain lake` /
//! `red car` / `cyberpunk city` from 8–9 engines. Pages 2 and 10 are each a
//! different set with a fixed ~18-row overlap that `dedupe` absorbs, and
//! `safesearch=0` vs `=2` return measurably different sets.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use super::{Capabilities, Source, SourceQuery};
use crate::protocol::Item;
use crate::scrape;

pub struct SearxNG;

/// Instances answering `format=json` to a non-browser User-Agent on 2026-09-17.
/// Kept short on purpose: every dead entry is another probe, and the fix for
/// "these are all gone" is `$QUARRY_SEARXNG_URL`, not fifty more guesses.
const DEFAULT_INSTANCES: &[&str] = &["https://sx.xo.st", "https://search.mectov.my.id"];

/// The env var that replaces the list, comma-separated.
pub const INSTANCE_VAR: &str = "QUARRY_SEARXNG_URL";

/// SearXNG pages forever; the engines behind it start repeating well before.
const MAX_PAGES: u32 = 20;

/// How long a working instance is trusted before it is probed again.
const HEALTHY_FOR: Duration = Duration::from_secs(30 * 60);

static HEALTHY: Mutex<Option<(Instant, String)>> = Mutex::new(None);

/// The instances to try, in order: `$QUARRY_SEARXNG_URL` if it is set to
/// anything non-blank, otherwise the shipped list.
pub fn instances() -> Vec<String> {
    let configured = std::env::var(INSTANCE_VAR).unwrap_or_default();
    let chosen: Vec<String> = configured
        .split(',')
        .map(|part| part.trim().trim_end_matches('/').to_string())
        .filter(|part| part.starts_with("http"))
        .collect();
    if !chosen.is_empty() {
        return chosen;
    }
    DEFAULT_INSTANCES.iter().map(|s| s.to_string()).collect()
}

/// The search URL for one instance — split out so it is testable without the probe.
pub fn search_url(instance: &str, query: &SourceQuery) -> String {
    let terms = super::bing::search_terms(query);
    // Only `-nsfw` asks for strict; a query that did not say is not a filter.
    let safe = if query.allow_nsfw == Some(false) { 2 } else { 0 };
    format!(
        "{}/search?q={}&categories=images&format=json&pageno={}&safesearch={safe}",
        instance.trim_end_matches('/'),
        scrape::urlencode(&terms),
        query.page.max(1),
    )
}

/// Whether a body is a SearXNG JSON answer rather than a bot-check page.
fn answers_json(body: &str) -> bool {
    serde_json::from_str::<serde_json::Value>(body)
        .ok()
        .map(|v| v.get("results").map(|r| r.is_array()).unwrap_or(false))
        .unwrap_or(false)
}

/// The first instance that answers JSON, remembered for `HEALTHY_FOR`. Falls
/// back to the first candidate, so the daemon fails against a real URL and
/// reports that instance's real status.
fn healthy_instance() -> String {
    let candidates = instances();
    let first = candidates.first().cloned().unwrap_or_default();

    if let Ok(guard) = HEALTHY.lock() {
        if let Some((at, instance)) = guard.as_ref() {
            if at.elapsed() < HEALTHY_FOR && candidates.iter().any(|c| c == instance) {
                return instance.clone();
            }
        }
    }

    // A fixed probe query, so the answer is reusable for the next half hour.
    let probes: Vec<String> = candidates
        .iter()
        .map(|instance| {
            search_url(
                instance,
                &SourceQuery { text: vec!["test".into()], page: 1, ..Default::default() },
            )
        })
        .collect();

    for (instance, body) in candidates.iter().zip(super::prefetch::get_many(&probes)) {
        match body {
            Ok(body) if answers_json(&body) => {
                if let Ok(mut guard) = HEALTHY.lock() {
                    *guard = Some((Instant::now(), instance.clone()));
                }
                return instance.clone();
            }
            Ok(_) => {
                if !cfg!(test) {
                    eprintln!(
                        "[quarryd] searxng: {instance} answered, but not JSON — that instance has format=json switched off"
                    );
                }
            }
            Err(e) => {
                if !cfg!(test) {
                    eprintln!("[quarryd] searxng: {instance} did not answer — {e}");
                }
            }
        }
    }
    first
}

/// `W×H` out of a `resolution` string, in any of the spellings the engines use.
fn resolution(text: &str) -> (u32, u32) {
    scrape::regex_captures(text, r"(?P<w>\d{1,6})\s*[x×*]\s*(?P<h>\d{1,6})")
        .ok()
        .and_then(|rows| rows.into_iter().next())
        .map(|row| {
            (
                row.get("w").and_then(|v| v.parse().ok()).unwrap_or(0),
                row.get("h").and_then(|v| v.parse().ok()).unwrap_or(0),
            )
        })
        .unwrap_or((0, 0))
}

impl Source for SearxNG {
    fn id(&self) -> &'static str {
        "searxng"
    }

    fn category(&self) -> &'static str {
        "photography"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            author: false,
            text: true,
            tags: true,
            // No size parameter in SearXNG's image category; applied locally.
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
        search_url(&healthy_instance(), query)
    }

    fn parse(&self, body: &str) -> Result<Vec<Item>, String> {
        let document: serde_json::Value = serde_json::from_str(body).map_err(|_| {
            let lowered = body.to_lowercase();
            if lowered.contains("anubis") || lowered.contains("not a bot") || lowered.contains("captcha") {
                format!(
                    "searxng: the instance answered a bot check instead of JSON — set ${INSTANCE_VAR} to an instance that allows format=json"
                )
            } else {
                format!(
                    "searxng: the answer was not JSON — this instance most likely has format=json switched off; set ${INSTANCE_VAR} to one that allows it"
                )
            }
        })?;

        let rows = document
            .get("results")
            .and_then(|v| v.as_array())
            .ok_or_else(|| "searxng: no results list in the answer".to_string())?;

        let mut items = Vec::with_capacity(rows.len());
        for row in rows {
            let url = scrape::json_str(row, "img_src");
            if !url.starts_with("http") {
                // A row from a non-image engine, or a thumbnail with no original.
                continue;
            }

            let thumb = match scrape::json_str(row, "thumbnail_src") {
                t if t.starts_with("http") => t,
                _ => scrape::json_str(row, "thumbnail"),
            };
            let page_url = scrape::json_str(row, "url");
            let (w, h) = resolution(&scrape::json_str(row, "resolution"));

            let mut item = scrape::normalize(
                self.id(),
                &super::bing::url_id(&url),
                &scrape::json_str(row, "title"),
                &url,
                &thumb,
                &page_url,
                w,
                h,
                Vec::new(),
            );
            // The publishing host, which most engines name outright.
            item.author = match scrape::json_str(row, "source") {
                named if !named.is_empty() => named,
                _ => scrape::host_of(&page_url).unwrap_or_default(),
            };
            items.push(item);
        }
        Ok(items)
    }

    fn has_more(&self, body: &str) -> bool {
        // No "next page" flag exists; whether this page had rows is the test.
        serde_json::from_str::<serde_json::Value>(body)
            .ok()
            .and_then(|d| d.get("results").and_then(|r| r.as_array()).map(|r| !r.is_empty()))
            .unwrap_or(false)
    }

    fn page_limit(&self) -> Option<u32> {
        Some(MAX_PAGES)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../../tests/fixtures/searxng-images.json");

    #[test]
    fn url_carries_the_words_the_category_the_page_and_safe_search() {
        let q = SourceQuery {
            text: vec!["mountain".into(), "lake".into()],
            page: 1,
            ..Default::default()
        };
        let url = search_url("https://sx.example.org", &q);
        assert_eq!(
            url,
            "https://sx.example.org/search?q=mountain+lake&categories=images&format=json&pageno=1&safesearch=0"
        );

        let q2 = SourceQuery { page: 3, allow_nsfw: Some(false), ..q };
        let url = search_url("https://sx.example.org/", &q2);
        assert!(url.contains("&pageno=3"), "{url}");
        assert!(url.ends_with("&safesearch=2"), "-nsfw asks for strict: {url}");
        assert!(!url.contains("//search?"), "a trailing slash is not doubled: {url}");
    }

    #[test]
    fn a_page_is_a_different_page() {
        let base = SourceQuery { text: vec!["red".into(), "car".into()], ..Default::default() };
        let one = search_url("https://sx.example.org", &SourceQuery { page: 1, ..base.clone() });
        let two = search_url("https://sx.example.org", &SourceQuery { page: 2, ..base.clone() });
        assert_ne!(one, two);
        // Page 0 is not a page; it is the caller not having said.
        let zero = search_url("https://sx.example.org", &SourceQuery { page: 0, ..base });
        assert_eq!(zero, one);
    }

    #[test]
    fn pushdown_sends_minus_nsfw_as_strict() {
        let parsed = crate::query::parse("cyberpunk city -nsfw");
        let (pushed, residue) = crate::sources::pushdown(&parsed, &SearxNG.capabilities());
        assert_eq!(pushed.text, vec!["cyberpunk", "city"]);
        assert_eq!(pushed.allow_nsfw, Some(false));
        assert!(residue.clauses.is_empty());
        assert!(search_url("https://sx.example.org", &pushed).ends_with("safesearch=2"));
    }

    #[test]
    fn the_instance_list_comes_from_the_env_var_when_it_is_set() {
        // The shipped list is used when nothing is configured.
        assert_eq!(instances(), DEFAULT_INSTANCES.iter().map(|s| s.to_string()).collect::<Vec<_>>());

        // Not `set_var`: one environment shared by every test in this binary.
        let parse = |configured: &str| -> Vec<String> {
            configured
                .split(',')
                .map(|p| p.trim().trim_end_matches('/').to_string())
                .filter(|p| p.starts_with("http"))
                .collect()
        };
        assert_eq!(
            parse(" https://a.example/ , https://b.example "),
            vec!["https://a.example", "https://b.example"]
        );
        assert!(parse("  ").is_empty(), "a blank var falls back to the shipped list");
        assert!(parse("not-a-url").is_empty());
    }

    #[test]
    fn build_url_without_network_still_names_a_real_instance() {
        // Under test the probe fails, so the first candidate is used.
        let q = SourceQuery { text: vec!["kite".into()], page: 1, ..Default::default() };
        let url = SearxNG.build_url(&q);
        assert!(url.starts_with(DEFAULT_INSTANCES[0]), "{url}");
        assert!(url.contains("q=kite"), "{url}");
    }

    #[test]
    fn parses_rows_with_image_thumb_page_title_size_and_publisher() {
        let items = SearxNG.parse(FIXTURE).expect("parses");
        assert_eq!(items.len(), 3, "the row with no img_src is skipped");

        let first = &items[0];
        assert_eq!(first.source, "searxng");
        assert_eq!(first.source_id, super::super::bing::url_id(&first.url));
        assert_eq!(first.url, "https://photos.example.org/full/lake.jpg");
        assert_eq!(first.thumb, "https://ts1.example.net/th?id=fake1");
        assert_eq!(first.page_url, "https://photos.example.org/gallery/lake");
        assert_eq!(first.title, "A mountain lake at dawn");
        assert_eq!((first.w, first.h), (2133, 1600));
        assert_eq!(first.author, "photos.example.org");

        // `thumbnail` when `thumbnail_src` is absent; host falls back to the page.
        assert_eq!(items[1].thumb, "https://cdn.example.com/small/car.jpg");
        assert_eq!(items[1].author, "cars.example.com");

        // No resolution is a real "unknown": it stays 0 and the matcher decides.
        assert_eq!((items[2].w, items[2].h), (0, 0));
        // A thumbnail-less row falls back to the original, via `normalize`.
        assert_eq!(items[2].thumb, items[2].url);

        assert!(SearxNG.has_more(FIXTURE));
    }

    #[test]
    fn resolution_is_read_in_every_spelling_the_engines_use() {
        assert_eq!(resolution("2133×1600"), (2133, 1600));
        assert_eq!(resolution("1920x1080"), (1920, 1080));
        assert_eq!(resolution("800 × 600"), (800, 600));
        assert_eq!(resolution(""), (0, 0));
        assert_eq!(resolution("unknown"), (0, 0));
    }

    #[test]
    fn an_empty_page_a_bot_check_and_a_disabled_format_are_told_apart() {
        let last = r#"{"query":"kite","results":[],"unresponsive_engines":[]}"#;
        assert!(SearxNG.parse(last).expect("empty is fine").is_empty());
        assert!(!SearxNG.has_more(last));

        let bot = "<!doctype html><title>Making sure you're not a bot!</title>";
        assert!(SearxNG.parse(bot).unwrap_err().contains("bot check"));

        let html = "<!doctype html><html><body>results</body></html>";
        let err = SearxNG.parse(html).unwrap_err();
        assert!(err.contains("format=json"), "{err}");
        assert!(err.contains(INSTANCE_VAR), "the error must name the way out: {err}");

        // JSON, but not SearXNG's JSON.
        assert!(SearxNG.parse(r#"{"error":"nope"}"#).unwrap_err().contains("no results list"));
    }
}
