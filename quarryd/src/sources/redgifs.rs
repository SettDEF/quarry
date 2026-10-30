//! RedGifs — adult video, and the cleanest video API quarry talks to.
//!
//! Every row is an mp4 with a rendered poster, real dimensions and a duration
//! the site measured itself, which is exactly the shape the video pipeline
//! wants: nothing to probe, nothing to guess from a file extension.
//!
//! Authentication is a formality rather than an account: `/v2/auth/temporary`
//! hands out a bearer token to anyone who asks, and it lasts about a day. So
//! this is keyless in the way that matters — nothing to register, nothing to
//! put in a config file — while still needing the same token plumbing Reddit
//! does.

use super::{Capabilities, Source, SourceQuery};
use crate::protocol::Item;
use crate::scrape;

#[derive(Default)]
pub struct RedGifs;

/// The token, and when it stops being worth trying.
///
/// In memory only: it is minted by asking, so persisting it would save one
/// request a day and add a file that can go stale.
static TOKEN: std::sync::Mutex<Option<(String, std::time::Instant)>> = std::sync::Mutex::new(None);

/// Its own client, for the same reason Reddit has one: a request to an API
/// that hands out tokens to anyone should not be indistinguishable from a
/// crawler hammering a booru, and the shared rate limiter is tuned for the
/// latter.
static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();

fn client() -> &'static reqwest::Client {
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .user_agent(scrape::USER_AGENT)
            .timeout(std::time::Duration::from_secs(30))
            .gzip(true)
            .build()
            .unwrap_or_default()
    })
}

pub fn forget_token() {
    if let Ok(mut guard) = TOKEN.lock() {
        *guard = None;
    }
}

/// A bearer token, minted if the one we have is old.
pub async fn token() -> Option<String> {
    // Twelve hours, against a stated lifetime of about a day: a token that
    // expires mid-crawl costs a retry, and asking for a new one costs one
    // request.
    const GOOD_FOR: std::time::Duration = std::time::Duration::from_secs(12 * 3600);

    if let Ok(guard) = TOKEN.lock() {
        if let Some((token, minted)) = guard.as_ref() {
            if minted.elapsed() < GOOD_FOR {
                return Some(token.clone());
            }
        }
    }

    let body = client()
        .get("https://api.redgifs.com/v2/auth/temporary")
        .send()
        .await
        .ok()?
        .text()
        .await
        .ok()?;
    let json: serde_json::Value = serde_json::from_str(&body).ok()?;
    let token = json.get("token").and_then(|v| v.as_str())?.to_string();

    if let Ok(mut guard) = TOKEN.lock() {
        *guard = Some((token.clone(), std::time::Instant::now()));
    }
    Some(token)
}

/// A GET against the API with the token attached.
pub async fn fetch(url: &str, token: &str) -> Result<String, scrape::ScrapeError> {
    let response = client()
        .get(url)
        .bearer_auth(token)
        .send()
        .await
        .map_err(|e| scrape::ScrapeError::Http(e.to_string()))?;

    let status = response.status().as_u16();
    if !response.status().is_success() {
        return Err(scrape::ScrapeError::Status(status, url.to_string()));
    }
    response.text().await.map_err(|e| scrape::ScrapeError::Http(e.to_string()))
}

impl Source for RedGifs {
    fn id(&self) -> &'static str {
        "redgifs"
    }

    fn category(&self) -> &'static str {
        "adult"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            author: true,
            text: true,
            tags: true,
            min_size: false,
            ratio: false,
            nsfw: false,
            sort: true,
            colors: false,
            // Everything here is video; asking for only video is asking for
            // this source, which the query already does by naming it.
            video: false,
            categories: Vec::new(),
        }
    }

    fn build_url(&self, query: &SourceQuery) -> String {
        let terms: Vec<&str> =
            query.text.iter().chain(query.tags.iter()).map(|s| s.as_str()).collect();
        // The search endpoint wants a term; without one it answers nothing,
        // which is the trap four other adapters here hit before it.
        let text = if terms.is_empty() { "cosplay".to_string() } else { terms.join(" ") };

        /*
         * A creator has their own listing, and it is the whole of their work:
         * probed 2026-10-13, `author:godslai` matched 1 local row while this
         * endpoint reports 308 across 8 pages. `trending` answers 0 here, so
         * the fallback is `latest` rather than the search endpoint's default.
         */
        if !query.author.is_empty() {
            let order = match query.sort {
                crate::query::Sort::Largest | crate::query::Sort::Widest => "top",
                _ => "latest",
            };
            return format!(
                "https://api.redgifs.com/v2/users/{}/search?order={}&count=40&page={}",
                scrape::urlencode(&query.author),
                order,
                query.page.max(1)
            );
        }

        // `order=new` answers 400; the site's own word is `latest`.
        let order = match query.sort {
            crate::query::Sort::Newest => "latest",
            crate::query::Sort::Largest | crate::query::Sort::Widest => "top",
            _ => "trending",
        };

        /*
         * `query`, not `search_text`.
         *
         * `search_text` is accepted and IGNORED: probed 2026-09-15, it answered
         * the same 10000-row trending feed for every word, with none of the
         * rows about the word. `query` is what the site's own search sends,
         * and its rows carry the word in their tags.
         */
        format!(
            "https://api.redgifs.com/v2/gifs/search?query={}&order={}&count=40&page={}",
            scrape::urlencode(&text),
            order,
            query.page.max(1)
        )
    }

    fn parse(&self, body: &str) -> Result<Vec<Item>, String> {
        let document: serde_json::Value =
            serde_json::from_str(body).map_err(|e| format!("redgifs: {e}"))?;

        let gifs = document
            .get("gifs")
            .and_then(|v| v.as_array())
            .ok_or_else(|| "redgifs: no gifs in the response".to_string())?;

        let mut items = Vec::with_capacity(gifs.len());
        for gif in gifs {
            let id = scrape::json_str(gif, "id");
            // `hd` is the mp4 everything else is derived from; `sd` is a
            // mobile re-encode and `silent` is the same picture without audio.
            let url = scrape::json_str(gif, "urls.hd");
            let url = if url.is_empty() { scrape::json_str(gif, "urls.sd") } else { url };
            if id.is_empty() || url.is_empty() {
                continue;
            }

            let w = scrape::json_pluck(gif, "width").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
            let h = scrape::json_pluck(gif, "height").and_then(|v| v.as_u64()).unwrap_or(0) as u32;

            let tags: Vec<String> = scrape::json_pluck(gif, "tags")
                .and_then(|v| v.as_array())
                .map(|a| a.iter().filter_map(|t| t.as_str().map(|s| s.to_lowercase())).collect())
                .unwrap_or_default();

            let mut item = scrape::normalize(
                self.id(),
                &id,
                &scrape::json_str(gif, "description"),
                &url,
                // The poster the site rendered — no frame to extract, and no
                // reason to download a video to show a tile.
                &scrape::json_str(gif, "urls.poster"),
                &format!("https://www.redgifs.com/watch/{}", id.to_lowercase()),
                w,
                h,
                tags,
            );

            // Published, and measured by whoever encoded it — better than what
            // ffprobe would tell us and free.
            item.duration =
                scrape::json_pluck(gif, "duration").and_then(|v| v.as_f64()).unwrap_or(0.0);
            item.author = scrape::json_str(gif, "userName");
            item.nsfw = true;
            // A dominant colour, already computed, in the shape util expects.
            let avg = scrape::json_str(gif, "avgColor");
            if avg.starts_with('#') && avg.len() >= 7 {
                item.dominant = avg;
            }
            items.push(item);
        }

        Ok(items)
    }

    fn has_more(&self, body: &str) -> bool {
        let Ok(document) = serde_json::from_str::<serde_json::Value>(body) else {
            return false;
        };
        let page = document.get("page").and_then(|v| v.as_u64()).unwrap_or(1);
        let pages = document.get("pages").and_then(|v| v.as_u64()).unwrap_or(1);
        page < pages
    }
}
