//! Erome — albums of pictures and clips, posted by people rather than studios.
//!
//! The search listing has one cover per album, which is all the old manifest
//! read: every album was a single 250px thumbnail, and its pictures and clips
//! were nowhere. So each album page on a listing is fetched too and every
//! picture and clip in it becomes a row of its own, in the album's order — the
//! way Reddit galleries are opened. An album page that fails keeps its cover
//! row, so a slow site degrades to the old listing rather than to nothing.
//!
//! The clips are on `v*.erome.com`, which answers 403 without an erome.com
//! Referer (verified 2026-10-23); pictures load without one. Rows carry the
//! album page as `page_url`, which the stream proxy sends as the Referer, and
//! the host is registered for exports and thumbnails.

use scraper::{ElementRef, Html, Selector};

use super::{prefetch, Capabilities, Source, SourceQuery};
use crate::protocol::Item;
use crate::scrape;

pub struct Erome;

const SITE: &str = "https://www.erome.com";

/// Album pages fetched at once: a listing is 36 albums, and 36 requests at a
/// time to one small site is how a scraper gets itself blocked. Six at a time
/// still drew a 429 for a few minutes (2026-10-23); four has not.
const AT_ONCE: usize = 4;

/// One album on the listing.
#[derive(Debug, Clone, PartialEq)]
pub struct Album {
    /// the number in `id="album-23314278"`, the old rows' id
    pub id: String,
    pub url: String,
    pub cover: String,
    pub title: String,
}

/// One picture or clip inside an album.
#[derive(Debug, Clone, PartialEq)]
pub struct Media {
    /// the file's own name (`X8IkxInY`), stable across re-crawls
    pub key: String,
    pub url: String,
    pub thumb: String,
    pub w: u32,
    pub h: u32,
    pub video: bool,
    pub seconds: f64,
}

fn sel(css: &str) -> Selector {
    Selector::parse(css).expect("static selector")
}

fn attr(el: &ElementRef, name: &str) -> String {
    el.value().attr(name).unwrap_or_default().trim().to_string()
}

fn absolute(url: &str) -> String {
    if url.starts_with("//") {
        format!("https:{url}")
    } else if url.starts_with('/') {
        format!("{SITE}{url}")
    } else {
        url.to_string()
    }
}

/// `X8IkxInY` from `…/CFDM9n5H/X8IkxInY.jpg?v=1` and `…/s9yDpq8N_720p.mp4`.
fn file_key(url: &str) -> String {
    let name = url.split(['?', '#']).next().unwrap_or_default().rsplit('/').next().unwrap_or_default();
    let stem = name.split('.').next().unwrap_or_default();
    stem.split('_').next().unwrap_or_default().to_string()
}

/// "13:33" or "1:02:03" as seconds.
fn clock(text: &str) -> f64 {
    text.trim().split(':').try_fold(0.0, |acc, part| part.trim().parse::<f64>().map(|n| acc * 60.0 + n)).unwrap_or(0.0)
}

/// A card's alt text is the album's title plus one of its files' keys —
/// "Trip HD #jtZZQUaX" — and the key is not part of anybody's title.
fn clean_title(alt: &str) -> String {
    match alt.rsplit_once(" #") {
        Some((title, key)) if key.len() == 8 && key.chars().all(|c| c.is_ascii_alphanumeric()) => title.trim().to_string(),
        _ => alt.trim().to_string(),
    }
}

/*
 * AN ALBUM IS READ ONCE.
 *
 * An album does not change after it is posted, but every crawl of a listing
 * opened all 36 of its album pages again — the 26 seconds a page took, and
 * the 429 Erome answered after a few rounds. Kept in memory for half a day,
 * capped so a long session cannot grow it without bound.
 */
static OPENED: std::sync::Mutex<Option<std::collections::HashMap<String, (std::time::Instant, String)>>> =
    std::sync::Mutex::new(None);
const KEEP: std::time::Duration = std::time::Duration::from_secs(12 * 3600);
const KEEP_AT_MOST: usize = 3000;

/// Album pages, from memory where they were read recently, else fetched —
/// `AT_ONCE` at a time — and remembered.
fn album_pages(urls: &[String]) -> Vec<Option<String>> {
    let mut out: Vec<Option<String>> = vec![None; urls.len()];
    let mut wanted = Vec::new();
    {
        let held = OPENED.lock().unwrap_or_else(|e| e.into_inner());
        for (i, url) in urls.iter().enumerate() {
            match held.as_ref().and_then(|m| m.get(url)) {
                Some((at, page)) if at.elapsed() < KEEP => out[i] = Some(page.clone()),
                _ => wanted.push(i),
            }
        }
    }
    let asked: Vec<String> = wanted.iter().map(|&i| urls[i].clone()).collect();
    let fetched: Vec<Option<String>> = asked.chunks(AT_ONCE).flat_map(prefetch::get_many).map(Result::ok).collect();
    let mut held = OPENED.lock().unwrap_or_else(|e| e.into_inner());
    let map = held.get_or_insert_with(Default::default);
    for (&i, page) in wanted.iter().zip(fetched) {
        if let Some(page) = &page {
            if map.len() >= KEEP_AT_MOST {
                map.retain(|_, (at, _)| at.elapsed() < KEEP);
                if map.len() >= KEEP_AT_MOST {
                    map.clear();
                }
            }
            map.insert(urls[i].clone(), (std::time::Instant::now(), page.clone()));
        }
        out[i] = page;
    }
    out
}

/// The albums on a search page, in order.
pub fn listing(html: &str) -> Vec<Album> {
    let doc = Html::parse_document(html);
    let (link, img) = (sel("a.album-link"), sel("img.album-thumbnail"));
    doc.select(&sel("div.album"))
        .filter_map(|card| {
            let id = attr(&card, "id").strip_prefix("album-")?.to_string();
            let url = absolute(&attr(&card.select(&link).next()?, "href"));
            // Every card holds several thumbnails; only the first is a real
            // picture, the rest are lazy placeholders (`data:` URIs).
            let first = card.select(&img).find(|i| attr(i, "src").starts_with("http"))?;
            Some(Album { id, url, cover: attr(&first, "src"), title: clean_title(&attr(&first, "alt")) })
        })
        .collect()
}

/// An album page: its title, its poster's name, and every picture and clip.
pub fn album(html: &str) -> (String, String, Vec<Media>) {
    let doc = Html::parse_document(html);
    let text = |css: &str| doc.select(&sel(css)).next().map(|e| e.text().collect::<String>().trim().to_string()).unwrap_or_default();
    let (title, author) = (text("h1"), text("#user_name"));
    let (source, video, picture, front, duration) =
        (sel("video source[src]"), sel("video[poster]"), sel("div.img[data-src]"), sel("img.img-front"), sel("span.duration"));
    let mut media = Vec::new();
    for group in doc.select(&sel("div.media-group")) {
        // A clip is in the group twice (the inline player and the lightbox);
        // the best `res` of either is the file.
        if let Some(best) = group.select(&source).max_by_key(|s| attr(s, "res").parse::<u32>().unwrap_or(0)) {
            let url = absolute(&attr(&best, "src"));
            let thumb = group.select(&video).next().map(|v| absolute(&attr(&v, "poster"))).unwrap_or_default();
            let seconds = group.select(&duration).next().map(|d| clock(&d.text().collect::<String>())).unwrap_or(0.0);
            media.push(Media { key: file_key(&url), url, thumb, w: 0, h: 0, video: true, seconds });
        } else if let Some(pic) = group.select(&picture).next() {
            let url = absolute(&attr(&pic, "data-src"));
            let size = group.select(&front).next();
            let num = |name: &str| size.as_ref().and_then(|i| attr(i, name).parse().ok()).unwrap_or(0);
            media.push(Media { key: file_key(&url), url: url.clone(), thumb: url, w: num("width"), h: num("height"), video: false, seconds: 0.0 });
        }
    }
    media.retain(|m| !m.key.is_empty() && m.url.starts_with("http"));
    (title, author, media)
}

/// A listing's albums as rows: each opened album as its pictures and clips,
/// the rest as their covers. `pages[i]` is album `i`'s page, if it came back.
pub fn rows(albums: &[Album], pages: &[Option<String>]) -> Vec<Item> {
    let mut items = Vec::new();
    for (n, a) in albums.iter().enumerate() {
        let slug = a.url.rsplit('/').next().unwrap_or(&a.id);
        // `tag:album:<slug>` is the whole album, in one search — see the
        // "rest of this album" row in Find similar.
        let album_tag = vec![format!("album:{}", slug.to_lowercase())];
        let opened = pages.get(n).and_then(|p| p.as_deref()).map(album).filter(|(_, _, m)| !m.is_empty());
        let Some((title, author, media)) = opened else {
            let mut item = scrape::normalize("erome", &a.id, &a.title, &a.cover, &a.cover, &a.url, 0, 0, album_tag.clone());
            item.nsfw = true;
            items.push(item);
            continue;
        };
        let title = if title.is_empty() { a.title.clone() } else { title };
        let count = media.len();
        for (i, m) in media.into_iter().enumerate() {
            let name = if count > 1 { format!("{title} · {}/{count}", i + 1) } else { title.clone() };
            let mut item =
                scrape::normalize("erome", &format!("{slug}-{}", m.key), &name, &m.url, &m.thumb, &a.url, m.w, m.h, album_tag.clone());
            item.nsfw = true;
            item.author = author.clone();
            // The site's own player clock, as RedGifs' is: measured by the
            // site, not guessed from a file.
            item.duration = m.seconds;
            // `normalize` looks for a URL ending in .gif; these end in `?v=…`.
            item.animated |= item.ext == "gif";
            items.push(item);
        }
    }
    items
}

impl Source for Erome {
    fn id(&self) -> &'static str {
        "erome"
    }

    fn category(&self) -> &'static str {
        "adult"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            // An uploader's own page lists their albums: `author:` is a real
            // search here, not a filter over somebody else's results.
            author: true,
            text: true,
            min_size: false,
            ratio: false,
            nsfw: false,
            // `o=new` is the site's own newest-first; the default is popular.
            sort: true,
            video: false,
            colors: false,
            tags: false,
            categories: Vec::new(),
        }
    }

    fn build_url(&self, query: &SourceQuery) -> String {
        if !query.author.is_empty() {
            return format!("{SITE}/{}?page={}", scrape::urlencode(&query.author), query.page.max(1));
        }
        let words = query.text.iter().chain(query.tags.iter()).map(|w| scrape::urlencode(w)).collect::<Vec<_>>().join("+");
        // An empty search answers nothing; "hd" is the site's busiest word.
        let words = if words.is_empty() { "hd".to_string() } else { words };
        let order = if query.sort == crate::query::Sort::Newest { "&o=new" } else { "" };
        format!("{SITE}/search?q={words}{order}&page={}", query.page.max(1))
    }

    fn parse(&self, body: &str) -> Result<Vec<Item>, String> {
        scrape::set_referer("erome.com", "https://www.erome.com/");
        let albums = listing(body);
        if albums.is_empty() && body.contains("captcha") {
            return Err("erome answered a captcha page".into());
        }
        let urls: Vec<String> = albums.iter().map(|a| a.url.clone()).collect();
        Ok(rows(&albums, &album_pages(&urls)))
    }

    fn has_more(&self, body: &str) -> bool {
        body.contains("rel=\"next\"")
    }

    fn sections(&self) -> Vec<(String, String, String, bool)> {
        ["hd", "amateur"].iter().map(|w| ("Popular".to_string(), w.to_string(), w.to_string(), true)).collect()
    }
}
