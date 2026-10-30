//! DeviantArt, through the door it left open.
//!
//! The `/api/v1` route wants an OAuth dance before it will answer a public
//! search, and 401s without one. The backend RSS feed answers the same question
//! keyless, sixty deviations a page, with pixel dimensions on every row — so
//! this adapter is a `parse_rss` call and a field mapping instead of a token
//! store, a refresh loop and a secret on disk.

use super::{Capabilities, Source, SourceQuery};
use crate::protocol::Item;
use crate::scrape;

pub struct DeviantArt;

/// The feed's page size, and it is not negotiable — `offset` steps by rows, so
/// a page number has to be multiplied back out into one.
const PER_PAGE: u32 = 60;

/// The deviation id: the trailing number of its URL.
///
/// It outlives the slug in front of it, so a deviation renamed by its artist is
/// still recognised as the row we already have rather than added again.
fn id_of(link: &str) -> String {
    let tail = link.rsplit('-').next().unwrap_or_default();
    if !tail.is_empty() && tail.bytes().all(|b| b.is_ascii_digit()) {
        tail.to_string()
    } else {
        scrape::slugify(link)
    }
}

/// Who made it.
///
/// `media:credit` occurs twice per deviation — the username, then the artist's
/// avatar image — and a feed reader that keeps the last one files every picture
/// under a `.gif` URL. The deviation link carries the same username as its
/// first path segment, which is the value that cannot be shadowed.
fn author_of(link: &str, credit: &str) -> String {
    if !credit.is_empty() && !credit.starts_with("http") {
        return credit.to_string();
    }
    link.split('/').nth(3).unwrap_or_default().to_string()
}

impl Source for DeviantArt {
    fn id(&self) -> &'static str {
        "deviantart"
    }

    fn category(&self) -> &'static str {
        "art"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            author: false,
            text: true,
            // The feed takes one search box and nothing else: no size, no
            // aspect, no ordering. Everything else belongs to the residue.
            min_size: false,
            ratio: false,
            /*
             * STILL false, and that is the correct answer.
             *
             * This capability means "the API can filter this", and the RSS feed
             * takes no maturity parameter. Claiming it would make `pushdown`
             * hand `-nsfw` to a query string that ignores it AND drop the
             * clause from the residue, so the filter would stop being applied
             * anywhere — a silent no-op in place of a visible gap.
             *
             * Left false, the clause stays in the residue and the local matcher
             * applies it against `item.nsfw`, which is populated from
             * `media:rating` now. Same outcome, honestly obtained.
             */
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

        format!(
            "https://backend.deviantart.com/rss.xml?type=deviation&q={}&offset={}",
            scrape::urlencode(&text),
            (query.page.max(1) - 1) * PER_PAGE
        )
    }

    fn parse(&self, body: &str) -> Result<Vec<Item>, String> {
        let entries = scrape::parse_rss(body).map_err(|e| format!("deviantart rss: {e}"))?;

        Ok(entries
            .into_iter()
            .filter(|entry| !entry.media_url.is_empty())
            .map(|entry| {
                let mut item = scrape::normalize(
                    "deviantart",
                    &id_of(&entry.link),
                    &entry.title,
                    &entry.media_url,
                    &entry.thumb_url,
                    &entry.link,
                    entry.width,
                    entry.height,
                    Vec::new(),
                );
                // DeviantArt hosts everything from wallpapers to icon sheets
                // under one search, so the shape of the picture is the only
                // honest signal of what it is for — which is what `normalize`
                // already derived from the dimensions above.
                item.author = author_of(&entry.link, &entry.author);
                // The feed's own maturity flag. Without reading it every row
                // claimed to be safe, so `-nsfw` filtered nothing here and the
                // mature work DeviantArt serves BLURRED to a logged-out client
                // came through as if it were fine.
                item.nsfw = entry.rating == "adult";
                item
            })
            .collect())
    }

    fn has_more(&self, body: &str) -> bool {
        // The feed publishes its own next page as an Atom link and omits it on
        // the last one; believing it beats counting rows, which would call a
        // short final page a failure.
        body.contains("rel=\"next\"")
    }
}
