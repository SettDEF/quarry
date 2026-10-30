//! Yandex Images — an index of the whole web, read out of its own page state.
//!
//! Unlike every other source here, Yandex hosts almost nothing it returns. It
//! is a *finder*: each result names a picture on somebody else's site, plus a
//! copy of it on Yandex's own CDN at thumbnail size. Two consequences shape
//! this adapter.
//!
//! The first is that the original may refuse us. A row whose `origUrl` is on a
//! host that blocks hotlinking still has a working Yandex-hosted thumbnail, so
//! the tile fills and only the full-size export fails — the ladder in
//! `thumb_source_candidates` already prefers `thumb` at tile sizes, so this
//! degrades exactly the right way round.
//!
//! The second is that a search engine's idea of "sunset wallpaper" is thirty
//! Pinterest re-uploads at 736px unless you tell it otherwise. Pushing the size
//! filter down is not an optimisation here, it is the difference between a
//! usable source and a bad one: measured on `cyberpunk city`, unfiltered gave 4
//! results of 30 at 1920px or wider, and `isize=eq&iw=3840&ih=2160` gave 30 of
//! 30 at exactly 4K, from varied hosts, all fetchable.
//!
//! There is no API and no key. The results are in the page, as JSON inside a
//! `data-state` attribute — the state the page's own JavaScript reads.

use super::{Capabilities, Source, SourceQuery};
use crate::protocol::Item;
use crate::scrape;

#[derive(Default)]
pub struct Yandex;

impl Yandex {
    /// Yandex's size buckets, from a minimum width.
    ///
    /// `isize=eq` with an exact `iw`/`ih` is the only *precise* filter it has,
    /// and precision is the wrong trade here: asking for exactly 3840x2160
    /// drops 3840x1600, which is the ultrawide the query was probably about.
    /// The bucket is a coarse push-down and the residue filter is exact.
    fn size_bucket(min_w: u32, min_h: u32) -> Option<&'static str> {
        let want = min_w.max(min_h);
        if want >= 1600 {
            Some("wallpaper")
        } else if want >= 800 {
            Some("large")
        } else if want >= 300 {
            Some("medium")
        } else {
            None
        }
    }

    fn orientation(ratio: Option<f64>) -> Option<&'static str> {
        match ratio? {
            r if r > 1.2 => Some("horizontal"),
            r if r < 0.85 => Some("vertical"),
            _ => Some("square"),
        }
    }

    /// Every `data-state` document on the page, parsed.
    ///
    /// A cbir page carries three of them and the one that matters is never
    /// first — the results, the sites and the other sizes each live in a
    /// different blob — so callers look through all of them rather than
    /// assuming a position that would move the first time Yandex adds a
    /// widget.
    fn states(body: &str) -> Vec<serde_json::Value> {
        scrape::regex_all(body, r#"data-state="(\{&quot;[^"]*)""#, 1)
            .unwrap_or_default()
            .iter()
            .filter_map(|raw| serde_json::from_str(&scrape::html_unescape(raw)).ok())
            .collect()
    }

    /// The search results, out of whichever blob has them in it.
    fn entities(body: &str) -> Vec<serde_json::Value> {
        let mut out = Vec::new();

        for document in Self::states(body) {
            // An object keyed by result id, not an array: order comes from the
            // `pos` field each entry carries.
            let Some(entities) =
                scrape::json_pluck(&document, "initialState.serpList.items.entities")
                    .and_then(|v| v.as_object())
            else {
                continue;
            };

            out.extend(entities.values().cloned());
            if !out.is_empty() {
                break;
            }
        }

        out.sort_by_key(|e| e.get("pos").and_then(|v| v.as_u64()).unwrap_or(u64::MAX));
        out
    }

    /// The one answer a 200 from Yandex can be that is not an answer.
    fn is_captcha(html: &str) -> bool {
        let lowered = html.to_lowercase();
        lowered.contains("showcaptcha") || lowered.contains("smartcaptcha")
    }
}

/*
 * REVERSE IMAGE SEARCH — "where else is this picture".
 *
 * The other two providers answer for drawn art: iqdb and SauceNAO index
 * boorus and Pixiv, and they are very good at that and blind to everything
 * else. Yandex indexes the open web, which is what makes it the one worth
 * having for a photograph, a screenshot, or a painting in a museum.
 *
 * It takes TWO requests, and the reason is worth writing down. Asking
 * `rpt=imageview&url=…` returns a real page with a real `cbir_id` — the
 * handle Yandex has given this picture — but its results list is EMPTY:
 * the page fetches the matches afterwards from JavaScript. Adding
 * `cbir_page=similar` with that id renders them server-side instead, in
 * exactly the `serpList.items.entities` shape the text search already
 * parses. So the second request is not a workaround; it is the page that
 * actually contains the answer.
 */
impl Yandex {
    /// What a captcha page means, said once so every caller says the same.
    pub const CAPTCHA: &'static str =
        "yandex asked for a captcha — it is rate-limiting this address";

    /// Step one: the viewer page, which is where the `cbir_id` lives.
    pub fn reverse_url(image_url: &str) -> String {
        format!(
            "https://yandex.com/images/search?rpt=imageview&url={}",
            scrape::urlencode(image_url)
        )
    }

    /// The handle Yandex gave the picture. Percent-encoded in the page and
    /// used percent-encoded in the next URL, so it is taken verbatim.
    pub fn cbir_id(html: &str) -> Option<String> {
        scrape::regex_all(html, r"cbir_id=([A-Za-z0-9_%\-]{10,})", 1)
            .unwrap_or_default()
            .into_iter()
            .next()
    }

    /*
     * A cbir_id is used percent-encoded, and arrives both ways.
     *
     * Scraped out of a page it is already encoded (`4034288%2FQlj…`); the
     * upload endpoint answers with the raw `shard/id`. Encoding an encoded one
     * would turn `%2F` into `%252F` and Yandex would answer the landing page,
     * so which one this is decides whether it needs encoding at all.
     */
    fn encoded_cbir(cbir_id: &str) -> String {
        if cbir_id.contains('%') {
            cbir_id.to_string()
        } else {
            cbir_id.replace('/', "%2F")
        }
    }

    /// Step two: the cbir page that actually carries an answer.
    ///
    /// `similar` is the look-alikes, `sites` is every page Yandex has seen
    /// this picture on — and that one also carries the other sizes it knows
    /// of, which is where a bigger copy comes from.
    /*
     * REVERSE SEARCH HAS ITS OWN FAMILY FILTER, and it was still on.
     *
     * `fyandex=0` was added to the text-search URL when the adult switch was
     * wired up, and this — the one used by "find similar" and by the reverse
     * lookups — was missed. So searching the catalogue for adult pictures
     * worked and asking Yandex "what else looks like this one" quietly came
     * back family-safe, which reads as there being nothing similar rather than
     * as a filter nobody turned off.
     *
     * `adult` is the same switch, passed in because this is a free function
     * with no view of the preferences.
     */
    pub fn page_url(image_url: &str, cbir_id: &str, page: &str, adult: bool) -> String {
        let filter = if adult { "&fyandex=0" } else { "" };
        format!(
            "https://yandex.com/images/search?cbir_id={}&cbir_page={page}&rpt=imageview&url={}{filter}",
            Self::encoded_cbir(cbir_id),
            scrape::urlencode(image_url)
        )
    }

    pub fn similar_url(image_url: &str, cbir_id: &str, adult: bool) -> String {
        Self::page_url(image_url, cbir_id, "similar", adult)
    }

    /*
     * The matches, in the shape the other providers answer with.
     *
     * Yandex publishes no similarity score — it ranks rather than scores — so
     * `similarity` is deliberately absent rather than invented. A number made
     * up here would be indistinguishable from iqdb's measured one.
     */
    pub fn reverse_matches(html: &str) -> Result<Vec<serde_json::Value>, String> {
        let entities = Self::entities(html);
        if entities.is_empty() {
            if Self::is_captcha(html) {
                return Err(Self::CAPTCHA.into());
            }
            return Ok(Vec::new());
        }

        let mut out = Vec::with_capacity(entities.len());
        for entity in entities {
            let source_url = {
                let page = scrape::json_str(&entity, "snippet.url");
                if page.is_empty() { scrape::json_str(&entity, "origUrl") } else { page }
            };
            if source_url.is_empty() {
                continue;
            }
            let thumb = match scrape::json_str(&entity, "image") {
                t if t.starts_with("//") => format!("https:{t}"),
                t => t,
            };
            let host = source_url
                .split("://")
                .nth(1)
                .and_then(|rest| rest.split('/').next())
                .unwrap_or_default()
                .to_string();

            // Computed here rather than inline: `json!` reads a braced block
            // as an object literal, not as Rust.
            let title = {
                let alt = scrape::json_str(&entity, "alt");
                if alt.is_empty() { scrape::json_str(&entity, "snippet.title") } else { alt }
            };

            out.push(serde_json::json!({
                "category": "similar",
                "sourceUrl": source_url,
                "thumbnail": thumb,
                "host": host,
                "width": scrape::json_pluck(&entity, "origWidth").and_then(|v| v.as_u64()).unwrap_or(0),
                "height": scrape::json_pluck(&entity, "origHeight").and_then(|v| v.as_u64()).unwrap_or(0),
                "title": title,
            }));
        }
        Ok(out)
    }
}

/*
 * YANDEX WITHOUT A URL — hand it the picture itself.
 *
 * Handing Yandex a `url=` only works for a picture that is on the open web,
 * reachable from Moscow, and that Yandex is willing to go and fetch. That
 * rules out a local file, a hotlink-protected host, a video (whose `url` is
 * not a picture at all) and anything it has simply never crawled — which is
 * most of the times the answer was "yandex did not recognise that image".
 *
 * Its own drop zone does not use a URL: it POSTs the bytes to the avatars
 * uploader and searches the copy that comes back. That endpoint is boring and
 * stable, and the response is JSON rather than a page to scrape.
 *
 * ONE THING ABOUT IT IS NOT GUESSABLE: the body is the RAW FILE, not a
 * multipart form. `upfile=@…` — the shape every write-up of this describes —
 * is answered `400 Incorrect avatar size` whatever the query string says, and
 * so is a `file=` part; only `Content-Type: image/jpeg` with the bytes as the
 * whole body works. Measured 2026-09-17.
 */
impl Yandex {
    /// `cbird=37` is the search-by-image client id; the namespace is the
    /// bucket the copy is stored in, and `orig` is the size the results page
    /// is then pointed at.
    pub const UPLOAD_URL: &'static str = "https://yandex.com/images-apphost/image-download\
?cbird=37&images_avatars_size=orig&images_avatars_namespace=images-cbir";

    /// Yandex's own copy of an uploaded picture: the handle, and the URL the
    /// cbir pages want in their `url=`.
    pub fn parse_upload(body: &str) -> Result<(String, String), String> {
        let json: serde_json::Value = serde_json::from_str(body)
            .map_err(|_| "yandex's uploader did not answer with JSON".to_string())?;
        let cbir_id = scrape::json_str(&json, "cbir_id");
        // `url` and `sizes.orig.path` are the same string today; falling back
        // rather than picking one means a rename of either does not break it.
        let url = match scrape::json_str(&json, "url") {
            u if u.is_empty() => scrape::json_str(&json, "sizes.orig.path"),
            u => u,
        };
        if cbir_id.is_empty() || url.is_empty() {
            return Err("yandex's uploader took the picture but gave no handle".into());
        }
        Ok((cbir_id, url))
    }

    /*
     * EVERY PAGE THIS PICTURE IS ON.
     *
     * A different question from "what looks like it": these are documents,
     * not pictures, and what you want from them is the page and who runs it.
     * Kept in the `reverse_matches` shape so one client renders both.
     */
    pub fn sites(html: &str) -> Result<Vec<serde_json::Value>, String> {
        if Self::is_captcha(html) {
            return Err(Self::CAPTCHA.into());
        }
        let mut out = Vec::new();
        for document in Self::states(html) {
            let Some(sites) = scrape::json_pluck(&document, "initialState.cbirSites.sites")
                .and_then(|v| v.as_array())
            else {
                continue;
            };
            for site in sites {
                let page = scrape::json_str(site, "url");
                if page.is_empty() {
                    continue;
                }
                let thumb = biggest_thumb(&scrape::json_str(site, "thumb.url"));
                out.push(serde_json::json!({
                    "category": "page",
                    "sourceUrl": page,
                    "imageUrl": scrape::json_str(site, "originalImage.url"),
                    "thumbnail": thumb,
                    "host": scrape::json_str(site, "domain"),
                    "width": scrape::json_pluck(site, "originalImage.width").and_then(|v| v.as_u64()).unwrap_or(0),
                    "height": scrape::json_pluck(site, "originalImage.height").and_then(|v| v.as_u64()).unwrap_or(0),
                    "title": scrape::json_str(site, "title"),
                }));
            }
            if !out.is_empty() {
                break;
            }
        }
        Ok(out)
    }

    /*
     * EVERY COPY OF THIS PICTURE, AS ROWS.
     *
     * The `sites` page is the richest answer Yandex gives: each entry names a
     * page, the domain that runs it, and THE ORIGINAL IMAGE ON IT with real
     * dimensions — 281 of them for a photograph, every one with a size. That
     * is both "where else does this exist" and "find me a bigger copy", which
     * is why one fetch serves both menu entries.
     *
     * `cbirOtherSizes` on the same page is a short curated list of the same
     * thing, grouped small/medium/large. It overlaps, so the two are merged
     * and deduplicated by URL rather than fetched separately.
     *
     * Yandex's own ranking is preserved; the caller sorts if it wants
     * biggest-first.
     */
    /// One row per URL, however many of Yandex's blobs mention it.
    #[allow(clippy::too_many_arguments)]
    fn push_copy(
        out: &mut Vec<Item>,
        seen: &mut Vec<String>,
        url: &str,
        thumb: &str,
        page: &str,
        title: &str,
        w: u32,
        h: u32,
    ) {
        if url.is_empty() || w == 0 || h == 0 || seen.iter().any(|u| u == url) {
            return;
        }
        seen.push(url.to_string());
        let host = scrape::host_of(url).unwrap_or_default();
        let title =
            if title.is_empty() { format!("{w}\u{d7}{h} on {host}") } else { title.to_string() };
        // The URL is the identity: Yandex gives these rows no id of their own.
        let mut item = scrape::normalize(
            "yandex",
            &scrape::cache_key(url),
            &title,
            url,
            thumb,
            page,
            w,
            h,
            Vec::new(),
        );
        item.author = host;
        out.push(item);
    }

    pub fn copies(html: &str, fallback_thumb: &str) -> Vec<Item> {
        let mut out: Vec<Item> = Vec::new();
        let mut seen: Vec<String> = Vec::new();

        for document in Self::states(html) {
            if let Some(sites) = scrape::json_pluck(&document, "initialState.cbirSites.sites")
                .and_then(|v| v.as_array())
            {
                for site in sites {
                    let thumb = match scrape::json_str(site, "thumb.url") {
                        t if t.is_empty() => fallback_thumb.to_string(),
                        t => biggest_thumb(&t),
                    };
                    Self::push_copy(
                        &mut out,
                        &mut seen,
                        &scrape::json_str(site, "originalImage.url"),
                        &thumb,
                        &strip_yandex_utm(&scrape::json_str(site, "url")),
                        &scrape::json_str(site, "title"),
                        scrape::json_pluck(site, "originalImage.width").and_then(|v| v.as_u64()).unwrap_or(0) as u32,
                        scrape::json_pluck(site, "originalImage.height").and_then(|v| v.as_u64()).unwrap_or(0) as u32,
                    );
                }
            }

            if let Some(groups) =
                scrape::json_pluck(&document, "initialState.cbirOtherSizes.items")
                    .and_then(|v| v.as_object())
            {
                for entry in groups.values().filter_map(|g| g.as_array()).flatten() {
                    // "2367\u{d7}3308" — a multiplication sign, not an x. These
                    // rows carry no thumbnail of their own, so they wear the
                    // asking picture's: they ARE it, at another size.
                    let (w, h) = scrape::json_str(entry, "text")
                        .split_once('\u{d7}')
                        .and_then(|(w, h)| Some((w.trim().parse().ok()?, h.trim().parse().ok()?)))
                        .unwrap_or((0u32, 0u32));
                    Self::push_copy(
                        &mut out,
                        &mut seen,
                        &scrape::json_str(entry, "url"),
                        fallback_thumb,
                        "",
                        "",
                        w,
                        h,
                    );
                }
            }
            if !out.is_empty() {
                break;
            }
        }
        out
    }
}

/// Yandex's own thumbnail, at the biggest size it stores.
///
/// The page asks its CDN for `&w=296&h=180` because that is the size of the
/// row it draws. Dropping those gives 240x320 of the same file for the same
/// request — still a thumbnail, but twice the pixels, which is the difference
/// between a wall tile that is soft and one that is not.
fn biggest_thumb(url: &str) -> String {
    let full = if url.starts_with("//") { format!("https:{url}") } else { url.to_string() };
    let Some((base, query)) = full.split_once('?') else {
        return full;
    };
    let kept: Vec<&str> = query
        .split('&')
        .filter(|p| !p.starts_with("w=") && !p.starts_with("h="))
        .collect();
    if kept.is_empty() { base.to_string() } else { format!("{base}?{}", kept.join("&")) }
}

/// Yandex tags every outbound link with its own campaign parameters. They are
/// noise in a link you are about to open or copy, and nothing needs them.
fn strip_yandex_utm(url: &str) -> String {
    let Some((base, query)) = url.split_once('?') else {
        return url.to_string();
    };
    let kept: Vec<&str> = query
        .split('&')
        .filter(|p| !p.starts_with("utm_medium=") && !p.starts_with("utm_source=yandex"))
        .collect();
    if kept.is_empty() { base.to_string() } else { format!("{base}?{}", kept.join("&")) }
}

impl Source for Yandex {
    fn id(&self) -> &'static str {
        "yandex"
    }

    fn category(&self) -> &'static str {
        "wallpapers"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            author: false,
            text: true,
            // Buckets, not exact bounds — see `size_bucket`.
            min_size: true,
            ratio: true,
            /*
             * THE FAMILY FILTER FOLLOWS THE SWITCH, like every other engine.
             *
             * This said `fyandex=0` exists and is not used, because turning the
             * open web's filter off is not something quarry should do ON A
             * USER'S BEHALF. That reasoning is right and it is why this stays
             * filtered by default — but it is not a reason to refuse when the
             * user has said so themselves. "Show adult results" is off until
             * someone turns it on, and the daemon appends `nsfw:false` to every
             * query while it is off, which is what reaches `allow_nsfw` here.
             *
             * So the filter is on unless you asked for it to be off, which is
             * exactly what google (`safe=off`), bing (`adlt=off`), searxng
             * (`safesearch=0`) and duckduckgo (`p=-1`) already do. Yandex was
             * the only engine that ignored the switch.
             */
            nsfw: true,
            sort: false,
            video: false,
            colors: false,
            tags: true,
            categories: Vec::new(),
        }
    }

    fn build_url(&self, query: &SourceQuery) -> String {
        // A search engine with no query is not a gallery — it answers nothing.
        // The kind is the best available guess at what an empty bar wants.
        let terms: Vec<String> =
            query.text.iter().chain(query.tags.iter()).map(|t| t.to_string()).collect();
        let text = if terms.is_empty() {
            match query.kind.as_str() {
                "avatar" => "avatar icon art".to_string(),
                "banner" => "banner art".to_string(),
                "cover" => "poster art".to_string(),
                _ => "4k wallpaper".to_string(),
            }
        } else {
            terms.join(" ")
        };

        let mut url = format!(
            "https://yandex.com/images/search?text={}",
            scrape::urlencode(&text)
        );

        // Yandex counts pages from zero.
        let page = query.page.saturating_sub(1);
        if page > 0 {
            url.push_str(&format!("&p={page}"));
        }
        if let Some(bucket) = Self::size_bucket(query.min_w, query.min_h) {
            url.push_str(&format!("&isize={bucket}"));
        }
        if let Some(orientation) = Self::orientation(query.ratio) {
            url.push_str(&format!("&iorient={orientation}"));
        }
        /*
         * Only an explicit "no adult" leaves Yandex's own filter in place; a
         * query that did not say is unfiltered, the same rule google uses for
         * `safe`. With the adult switch off the daemon says `nsfw:false` on
         * every query, so "did not say" only ever happens once you have turned
         * it on yourself.
         */
        if query.allow_nsfw != Some(false) {
            url.push_str("&fyandex=0");
        }
        url
    }

    fn parse(&self, body: &str) -> Result<Vec<Item>, String> {
        let entities = Self::entities(body);

        if entities.is_empty() {
            /*
             * Say WHICH nothing this is.
             *
             * Yandex answers a scraper it does not like with a 200 and a
             * captcha page, which parses to zero rows and looks exactly like
             * "no results for that query" — the failure that wastes an
             * afternoon. It is worth two string searches to tell them apart.
             */
            if Self::is_captcha(body) {
                return Err(Self::CAPTCHA.into());
            }
            if !body.to_lowercase().contains("data-state") {
                return Err("yandex returned a page with no search state in it".into());
            }
            return Ok(Vec::new());
        }

        let mut items = Vec::with_capacity(entities.len());
        for entity in entities {
            let url = scrape::json_str(&entity, "origUrl");
            let id = scrape::json_str(&entity, "id");
            if url.is_empty() || id.is_empty() {
                continue;
            }

            let width = scrape::json_pluck(&entity, "origWidth").and_then(|v| v.as_u64()).unwrap_or(0);
            let height =
                scrape::json_pluck(&entity, "origHeight").and_then(|v| v.as_u64()).unwrap_or(0);

            let title = {
                let alt = scrape::json_str(&entity, "alt");
                if alt.is_empty() { scrape::json_str(&entity, "snippet.title") } else { alt }
            };

            // The page the picture is actually on, not Yandex's viewer for it:
            // that is where a licence or an artist would be found.
            let page_url = scrape::json_str(&entity, "snippet.url");

            // Protocol-relative, as CDNs often are.
            let thumb = match scrape::json_str(&entity, "image") {
                t if t.starts_with("//") => format!("https:{t}"),
                t => t,
            };

            let mut item = scrape::normalize(
                self.id(),
                &id,
                &title,
                &url,
                &thumb,
                &page_url,
                width as u32,
                height as u32,
                Vec::new(),
            );

            /*
             * The preview ladder is what makes this source fast.
             *
             * Yandex publishes several sizes of each result, on its own CDN,
             * already fetched and already resized. Taking the largest one that
             * is still a preview gives the wall a `sample` to draw from
             * without touching the origin host at all — which is both quicker
             * and the polite way to browse somebody else's pictures.
             */
            if let Some(previews) =
                scrape::json_pluck(&entity, "viewerData.preview").and_then(|v| v.as_array())
            {
                let mut best: Option<(u64, String)> = None;
                for preview in previews {
                    let w = scrape::json_pluck(preview, "w").and_then(|v| v.as_u64()).unwrap_or(0);
                    let candidate = scrape::json_str(preview, "url");
                    if candidate.is_empty() || w == 0 {
                        continue;
                    }
                    // Bytes come from the same place, and only the original
                    // entry knows them.
                    if candidate == url {
                        item.bytes = scrape::json_pluck(preview, "fileSizeInBytes")
                            .and_then(|v| v.as_u64())
                            .unwrap_or(0);
                    }
                    if w <= 1280 && best.as_ref().is_none_or(|(bw, _)| w > *bw) {
                        best = Some((w, candidate));
                    }
                }
                if let Some((_, sample)) = best {
                    item.sample = sample;
                }
            }

            // The site it came from is the closest thing to an author here, and
            // it is what tells you whether a result is worth trusting.
            item.author = scrape::json_str(&entity, "snippet.domain");
            item.animated = item.animated
                || scrape::json_pluck(&entity, "gifLabel").is_some_and(|v| !v.is_null());

            items.push(item);
        }

        Ok(items)
    }
}

/*
 * Synthetic fixtures in the shape the upload endpoint and the two cbir pages
 * serve: invented handles, hosts and titles. A live request in a test is a
 * flaky suite, and Yandex is the source most likely to answer a test runner
 * with a captcha.
 */
#[cfg(test)]
mod tests {
    use super::Yandex;

    const UPLOAD: &str = include_str!("../../tests/fixtures/yandex-upload.json");
    const SIMILAR: &str = include_str!("../../tests/fixtures/yandex-cbir-similar.html");
    const SITES: &str = include_str!("../../tests/fixtures/yandex-cbir-sites.html");

    #[test]
    fn the_upload_answers_with_a_handle_and_a_copy() {
        let (cbir, url) = Yandex::parse_upload(UPLOAD).expect("parses");
        assert_eq!(cbir, "4034288/FxtR-SyntheticHandle0000");
        assert!(url.starts_with("https://avatars.mds.yandex.net/get-images-cbir/"), "{url}");
    }

    #[test]
    fn an_uploaded_handle_is_encoded_once() {
        // The uploader's raw `shard/id`, and a scraped one that is already
        // encoded — both have to come out as exactly one `%2F`.
        let raw = Yandex::page_url("https://x/y.jpg", "4034288/Qlj-Ke", "similar", false);
        assert!(raw.contains("cbir_id=4034288%2FQlj-Ke"), "{raw}");
        let scraped = Yandex::page_url("https://x/y.jpg", "4034288%2FQlj-Ke", "similar", false);
        assert!(scraped.contains("cbir_id=4034288%2FQlj-Ke"), "{scraped}");
        assert!(!scraped.contains("%252F"), "{scraped}");
    }

    #[test]
    fn the_similar_page_reads_as_matches() {
        let matches = Yandex::reverse_matches(SIMILAR).expect("parses");
        assert!(matches.len() >= 3, "{}", matches.len());
        let first = &matches[0];
        assert!(first["sourceUrl"].as_str().unwrap().starts_with("http"));
        assert!(first["thumbnail"].as_str().unwrap().starts_with("https://"));
        assert!(!first["host"].as_str().unwrap().is_empty());
    }

    #[test]
    fn the_sites_page_names_the_pages_it_is_on() {
        let sites = Yandex::sites(SITES).expect("parses");
        assert!(!sites.is_empty());
        assert_eq!(sites[0]["category"], "page");
        assert!(sites.iter().all(|s| !s["host"].as_str().unwrap().is_empty()));
    }

    #[test]
    fn copies_are_rows_with_real_sizes_and_a_thumbnail_that_loads() {
        let copies = Yandex::copies(SITES, "file:///cache/asked.jpg");
        assert!(copies.len() >= 3, "{}", copies.len());
        assert!(copies.iter().all(|i| i.w > 0 && i.h > 0), "a size is the point of these");
        assert!(copies.iter().all(|i| i.ratio > 0.0), "a zero ratio collapses the row");
        assert!(copies.iter().all(|i| i.id.starts_with("yandex:")));
        assert!(copies.iter().all(|i| !i.thumb.is_empty()));
        // The other-sizes rows have no thumbnail of their own and wear ours.
        assert!(copies.iter().any(|i| i.thumb == "file:///cache/asked.jpg"));
        // One URL, one row, however many blobs mention it.
        let mut urls: Vec<&str> = copies.iter().map(|i| i.url.as_str()).collect();
        let before = urls.len();
        urls.sort_unstable();
        urls.dedup();
        assert_eq!(urls.len(), before, "a copy was listed twice");
    }

    #[test]
    fn a_thumbnail_loses_the_size_the_page_happened_to_want() {
        // 296x180 is the row Yandex drew; without it the CDN serves 240x320 of
        // the same file — see `biggest_thumb`.
        assert_eq!(
            super::biggest_thumb("//avatars.mds.yandex.net/i?id=abc-images-thumbs&n=13&w=296&h=180"),
            "https://avatars.mds.yandex.net/i?id=abc-images-thumbs&n=13"
        );
        assert_eq!(super::biggest_thumb("https://x.test/t.jpg"), "https://x.test/t.jpg");
    }

    #[test]
    fn a_link_loses_yandexs_campaign_tags() {
        assert_eq!(
            super::strip_yandex_utm("https://x.test/a?utm_medium=organic&utm_source=yandexsmartcamera"),
            "https://x.test/a"
        );
        // Somebody else's query string is theirs, and stays.
        assert_eq!(super::strip_yandex_utm("https://x.test/a?id=7"), "https://x.test/a?id=7");
    }

    #[test]
    fn a_captcha_is_named_rather_than_read_as_nothing() {
        let page = "<html><body>__CAPTCHA_ROOT__ showcaptcha</body></html>";
        assert_eq!(Yandex::reverse_matches(page).unwrap_err(), Yandex::CAPTCHA);
        assert_eq!(Yandex::sites(page).unwrap_err(), Yandex::CAPTCHA);
    }
}

/*
 * The adult switch reaches the text search and the reverse search by different
 * routes, and for a while only one of them. Searching the catalogue for adult
 * pictures worked while "find similar" came back family-safe — which looks
 * like there being nothing similar, not like a filter.
 */
#[cfg(test)]
mod reverse_filter_tests {
    use super::Yandex;

    #[test]
    fn find_similar_turns_the_family_filter_off_when_adult_is_on() {
        let url = Yandex::similar_url("https://example.test/a.jpg", "cbir123", true);
        assert!(url.contains("fyandex=0"), "still family-filtered: {url}");
        assert!(url.contains("cbir_page=similar"), "{url}");
    }

    #[test]
    fn the_filter_stays_on_when_adult_is_off() {
        let url = Yandex::similar_url("https://example.test/a.jpg", "cbir123", false);
        assert!(!url.contains("fyandex"), "unasked-for adult results: {url}");
    }

    /// "Which sites have this picture" is the same search with the same switch.
    #[test]
    fn the_sites_page_is_filtered_the_same_way() {
        let on = Yandex::page_url("https://example.test/a.jpg", "cbir123", "sites", true);
        let off = Yandex::page_url("https://example.test/a.jpg", "cbir123", "sites", false);
        assert!(on.contains("fyandex=0"), "{on}");
        assert!(!off.contains("fyandex"), "{off}");
    }
}
