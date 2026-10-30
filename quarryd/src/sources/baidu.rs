//! Baidu Images — the Chinese web, searched with the words as typed.
//!
//! Bing and DuckDuckGo index the English-speaking web; Baidu indexes the
//! Chinese one, which is most of the anime, illustration and wallpaper sites
//! nobody else crawls.
//!
//! The endpoint is the one the results page calls while you scroll,
//! `/search/acjson`. It answers JSON — but only to a visitor Baidu has seen:
//! without a `BAIDUID` cookie it says `{"antiFlag":1,"message":"Forbid spider
//! access"}`. The cookie is handed out by the home page to anyone who asks,
//! including this agent (verified 2026-10-23), so it is fetched once and sent
//! on every request to `image.baidu.com`.
//!
//! Each row carries the original's real address in `replaceUrl[0].ObjURL`
//! (`objURL` itself is obfuscated), its size, Baidu's own 500px thumbnail and
//! the page it came from.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Deserialize;

use super::{prefetch, Capabilities, Source, SourceQuery};
use crate::protocol::Item;
use crate::scrape;

pub struct Baidu;

const PER_PAGE: u32 = 30;

/// When the cookie was fetched: Baidu keeps it a year, a day is plenty.
static COOKIE_AT: Mutex<Option<Instant>> = Mutex::new(None);

/// A `BAIDUID` for `image.baidu.com`, fetched when there is none (or after a
/// refusal) — the reason a search is answered at all.
pub fn ensure_cookie(force: bool) {
    let mut at = COOKIE_AT.lock().unwrap_or_else(|e| e.into_inner());
    if !force && at.is_some_and(|t| t.elapsed() < Duration::from_secs(24 * 3600)) {
        return;
    }
    let Ok(pairs) = prefetch::cookies("https://www.baidu.com/") else { return };
    let jar: Vec<String> = pairs.into_iter().filter(|p| p.starts_with("BAIDUID=") || p.starts_with("BIDUPSID=")).collect();
    if jar.is_empty() {
        return;
    }
    scrape::set_host_header("image.baidu.com", "Cookie", &jar.join("; "));
    scrape::set_referer("image.baidu.com", "https://image.baidu.com/");
    *at = Some(Instant::now());
}

#[derive(Debug, Default, Deserialize)]
struct Page {
    #[serde(default)]
    data: Vec<serde_json::Value>,
    #[serde(default, rename = "antiFlag")]
    anti_flag: i64,
    #[serde(default)]
    message: String,
}

/// `"2048"` or `2048`.
fn number(v: Option<&serde_json::Value>) -> u32 {
    match v {
        Some(serde_json::Value::Number(n)) => n.as_u64().unwrap_or(0) as u32,
        Some(serde_json::Value::String(s)) => s.parse().unwrap_or(0),
        _ => 0,
    }
}

/*
 * BAIDU'S ADDRESSES, UNSCRAMBLED.
 *
 * `objURL` and `fromURL` are a fixed substitution: three tokens for `:`, `.`
 * and `/`, then a letter-for-letter table. `ippr_z2C$qAzdH3FAzdH3F4k1…` is
 * `http://mbd…`. It has not changed in a decade of scrapers relying on it.
 */
pub fn unscramble(scrambled: &str) -> String {
    let joined = scrambled.replace("_z2C$q", ":").replace("_z&e3B", ".").replace("AzdH3F", "/");
    joined
        .chars()
        .map(|c| match c {
            'w' => 'a', 'k' => 'b', 'v' => 'c', '1' => 'd', 'j' => 'e', 'u' => 'f', '2' => 'g',
            'i' => 'h', 't' => 'i', '3' => 'j', 'h' => 'k', 's' => 'l', '4' => 'm', 'g' => 'n',
            '5' => 'o', 'r' => 'p', '6' => 'r', 'f' => 's', 'p' => 't', '7' => 'u', 'e' => 'v',
            'o' => 'w', '8' => '1', 'd' => '2', 'n' => '3', '9' => '4', 'c' => '5', 'm' => '6',
            '0' => '7', 'b' => '8', 'l' => '9', 'a' => '0',
            other => other,
        })
        .collect()
}

fn text<'a>(row: &'a serde_json::Value, key: &str) -> &'a str {
    row.get(key).and_then(|v| v.as_str()).unwrap_or("")
}

/// `replaceUrl` arrives as a real array, or — in the HTML-ish JSON Baidu also
/// serves — as a string of Python-style single quotes. Either way, the first
/// `ObjURL` in it.
fn original(row: &serde_json::Value) -> String {
    match row.get("replaceUrl") {
        Some(serde_json::Value::Array(list)) => list
            .iter()
            .find_map(|r| r.get("ObjURL").or_else(|| r.get("ObjUrl")).and_then(|v| v.as_str()))
            .unwrap_or("")
            .to_string(),
        Some(serde_json::Value::String(s)) => s
            .split("'ObjURL': '")
            .nth(1)
            .and_then(|rest| rest.split('\'').next())
            .unwrap_or("")
            .to_string(),
        _ => String::new(),
    }
}

impl Source for Baidu {
    fn id(&self) -> &'static str {
        "baidu"
    }

    fn category(&self) -> &'static str {
        "photography"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            author: false,
            text: true,
            tags: true,
            min_size: false,
            ratio: false,
            nsfw: false,
            sort: false,
            video: false,
            colors: false,
            categories: Vec::new(),
        }
    }

    fn build_url(&self, query: &SourceQuery) -> String {
        ensure_cookie(false);
        let words = scrape::urlencode(&super::bing::search_terms(query));
        let first = (query.page.max(1) - 1) * PER_PAGE;
        format!(
            "https://image.baidu.com/search/acjson?tn=resultjson_com&ipn=rj&ct=201326592&fp=result\
             &queryWord={words}&word={words}&ie=utf-8&oe=utf-8&pn={first}&rn={PER_PAGE}"
        )
    }

    fn parse(&self, body: &str) -> Result<Vec<Item>, String> {
        // Baidu escapes single quotes as `\'`, which is not JSON.
        let page: Page = serde_json::from_str(&body.replace("\\'", "'")).map_err(|e| format!("baidu json: {e}"))?;
        if page.anti_flag != 0 {
            // The cookie aged out or was refused: the next round fetches a new one.
            *COOKIE_AT.lock().unwrap_or_else(|e| e.into_inner()) = None;
            return Err(format!("baidu refused the search ({}) — asking for a new cookie", page.message));
        }
        Ok(page
            .data
            .iter()
            .filter(|row| row.is_object() && !text(row, "thumbURL").is_empty())
            .filter_map(|row| {
                let thumb = text(row, "thumbURL");
                let mut url = original(row);
                if !url.starts_with("http") {
                    url = unscramble(text(row, "objURL"));
                }
                // No original: Baidu's own copy, which is at least the picture.
                let url = if url.starts_with("http") { url } else { text(row, "middleURL").to_string() };
                if !url.starts_with("http") {
                    return None;
                }
                let id = if text(row, "os").is_empty() { text(row, "cs") } else { text(row, "os") };
                let title = text(row, "fromPageTitleEnc");
                let page = unscramble(text(row, "fromURL"));
                let host = text(row, "fromURLHost");
                let mut item = scrape::normalize(
                    "baidu",
                    id,
                    title,
                    &url,
                    thumb,
                    &page,
                    number(row.get("width")),
                    number(row.get("height")),
                    Vec::new(),
                );
                // An address that did not unscramble is no link: the host is.
                if !item.page_url.starts_with("http") && !host.is_empty() {
                    item.page_url = format!("https://{host}/");
                }
                Some(item)
            })
            .collect())
    }

    fn has_more(&self, body: &str) -> bool {
        body.matches("\"thumbURL\"").count() >= (PER_PAGE as usize) / 2
    }
}
