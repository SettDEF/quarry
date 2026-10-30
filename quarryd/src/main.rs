//! quarryd — the quarry daemon.
//!
//! Phase 2: it serves the fixture over the v1 protocol (PROTOCOL.md) so the
//! front end can stop reading files and start talking to a daemon, months
//! before the daemon can crawl anything. The backend reports itself as `mock`
//! for exactly that reason.
//!
//!   quarryd [--fixture PATH] [--socket PATH] [--quiet]

use std::path::PathBuf;
use std::sync::Arc;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::Mutex;

mod catalog;
mod db;
mod prefs;
mod protocol;
mod image;
mod nsfw;
mod stream;
mod query;
mod scrape;
mod sources;
mod util;

use catalog::Catalog;
use protocol::{ItemsParams, QueryParams, Request, Response, MAX_LIMIT, PROTOCOL_VERSION};

/// What one source's last fetches looked like. See `record_health`.
#[derive(Clone, serde::Serialize)]
struct SourceHealth {
    ok: bool,
    status: u16,
    detail: String,
    rows: usize,
    last_ok: i64,
    last_fail: i64,
    /// Failures in a row. One is weather; five is a site that changed.
    fails: u32,
    checks: u64,
}

struct Server {
    catalog: Mutex<Catalog>,
    /// Per source, how its last fetches went — the validator's memory.
    health: Mutex<std::collections::HashMap<String, SourceHealth>>,
    /// Where the same story is written down, so a restart does not forget it.
    health_log: String,
    // Shared rather than borrowed: the endless-scroll handler spawns a task per
    // source, and a spawned task cannot hold a reference to `self`.
    /// Next page per (source, query) — the daemon owns "where we are" so the
    /// client can simply ask for more.
    cursors: Mutex<std::collections::HashMap<String, u32>>,
    /// When each finished cursor finished — so a home feed that ran dry can
    /// start over later and find what was posted since.
    exhausted_at: Mutex<std::collections::HashMap<String, std::time::Instant>>,
    /*
     * HOW MUCH EACH SOURCE IS ACTUALLY GIVING, PER PAGE.
     *
     * With sixty sources, asking every one for the same eight pages spends
     * most of a round on sites that answer with rows the catalogue already
     * has: a booru crawled to its end returns forty known posts a page, and a
     * busy one returns forty new ones. This is a rolling average of NEW rows
     * per page, per source and query, and it decides how many pages each gets
     * next round. A source nobody has asked yet has no average, and gets the
     * full budget so it can prove itself.
     */
    yields: Mutex<std::collections::HashMap<String, f32>>,
    /// Streams handed to the player through loopback, with the headers their
    /// hosts insist on. `None` when the port could not be bound.
    proxy: Mutex<Option<Arc<stream::Proxy>>>,
    /// A page read once, kept for a few minutes: these hosts refuse
    /// back-to-back requests, and `renditions` right after `resolve` was
    /// getting a 403 and answering "no qualities" for a video that has four.
    /// The URLs inside are signed and outlive this by hours.
    /// page → (when this answer stops being trusted, what was found). A DEADLINE
    /// rather than an insert time, because an empty answer is held for far less
    /// long than a real one — see `videos_for_page`.
    page_videos: Mutex<std::collections::HashMap<String, (std::time::Instant, Vec<(String, String)>)>>,
    /// The tags each video page showed, kept for `adopt_page_tags`.
    page_tags: Mutex<std::collections::HashMap<String, Vec<String>>>,
    concurrency: tokio::sync::Semaphore,
    /// Crawls and downloads, held apart from the pool above: one `more` round
    /// can run for forty seconds and a video for minutes, and while they held
    /// general permits a screen of thumbnails waited behind them — the wall
    /// stayed empty while the daemon was busy fetching things nobody could see.
    background: tokio::sync::Semaphore,
    http: Arc<scrape::Http>,
    thumb_dir: String,
    model_dir: String,
    started: std::time::Instant,
    quiet: bool,
    /*
     * UNSOLICITED FRAMES, AT LAST.
     *
     * `protocol::Event` has existed since PROTOCOL.md described it and the
     * client has dispatched on `t == "ev"` the whole time, but nothing ever
     * sent one — it was `#[allow(dead_code)]`. It stopped being optional when
     * the board became a second application: quarry writes a picture onto a
     * board and the board app, sitting open beside it, had no way to know.
     *
     * A broadcast channel rather than a list of clients: a slow or wedged
     * connection lags its own receiver and is dropped from the channel, and
     * cannot hold up the daemon or anybody else's events.
     */
    events: tokio::sync::broadcast::Sender<String>,
}

/// Which URL to thumbnail from, best first, for a request of `size`.
///
/// WHICH ONE FIRST DEPENDS ON HOW BIG A PICTURE WAS ASKED FOR. The preview
/// always went first, so a 2048 request fetched a board's ~300px sample and
/// UPSCALED it: the detail view showed a soft, blocky version of a picture
/// whose original was right there. A preview cannot answer a question larger
/// than itself, and no amount of resampling invents the detail back.
///
/// Three tiers, not two — a mid-size `sample` (Moebooru's `sample_url`,
/// Danbooru's `large_file_url`, ~850-1000px) sits between the ~300px preview
/// and the multi-MB original:
///   - at or below 640, the preview is plenty for a tile and the cheapest fetch;
///   - above that and up to ~1280, the sample is the right size and the
///     original would be overkill for a DPR-2 tile;
///   - above ~1280, the original is genuinely needed.
/// Every tier keeps the other two as fallbacks, because sources get their own
/// URLs wrong often enough to be worth a second try — including an empty or
/// unpublished `sample`, which just drops out (`skip empty strings` below).
///
/// Shared by `thumb` and `thumbs` ON PURPOSE. It lived inside `thumb` alone,
/// and `thumbs` — the bulk handler the app actually calls for every tile AND
/// for the detail view — kept its own one-liner that always took the preview.
/// Every size returned the same 300px image; only the filename changed.
fn thumb_source_candidates(item: &crate::protocol::Item, size: u32) -> Vec<String> {
    // A booru preview is ~300px. It answers a 320 request and nothing larger.
    const PREVIEW_IS_ENOUGH: u32 = 320;
    // What a wall tile asks for. On a 2x screen a tile DRAWS at ~605px, so a
    // 300px preview was being upscaled — the reason the wall still looked soft
    // after the detail view was fixed.
    const TILE: u32 = 640;
    const SAMPLE_IS_ENOUGH: u32 = 1280;

    let tier: [&str; 3] = if size <= PREVIEW_IS_ENOUGH {
        [&item.thumb, &item.sample, &item.url]
    } else if size <= TILE {
        /*
         * Tile range: sample, then the PREVIEW, and the original last.
         *
         * The fallback order matters more here than anywhere else. A row with
         * no stored sample falling through to the original would fetch several
         * megabytes for one tile, across a wall of them — which is how you get
         * rate-limited and make everything slower. Soft-and-cheap is the right
         * failure for a tile; the detail view is where paying for the real
         * thing is worth it.
         */
        [&item.sample, &item.thumb, &item.url]
    } else if size <= SAMPLE_IS_ENOUGH {
        [&item.sample, &item.url, &item.thumb]
    } else {
        [&item.url, &item.sample, &item.thumb]
    };

    let mut candidates: Vec<String> =
        tier.into_iter().filter(|s| !s.is_empty()).map(|s| s.to_string()).collect();
    candidates.dedup();
    candidates
}

#[cfg(test)]
mod thumb_candidate_tests {
    use super::thumb_source_candidates;
    use crate::scrape::normalize;

    fn item(thumb: &str, sample: &str, url: &str) -> crate::protocol::Item {
        let mut it = normalize("s", "1", "t", url, thumb, "", 2000, 1000, vec![]);
        it.sample = sample.to_string();
        it
    }

    #[test]
    fn at_or_below_320_prefers_the_preview() {
        let it = item("https://x/thumb.jpg", "https://x/sample.jpg", "https://x/orig.jpg");
        assert_eq!(
            thumb_source_candidates(&it, 320),
            vec!["https://x/thumb.jpg", "https://x/sample.jpg", "https://x/orig.jpg"]
        );
    }

    /// A tile asks for 640 and DRAWS at ~605 on a 2x screen, so a ~300px
    /// preview is not enough — but the fallback must stay cheap.
    #[test]
    fn a_tile_prefers_the_sample_and_falls_back_to_the_preview_not_the_original() {
        let it = item("https://x/thumb.jpg", "https://x/sample.jpg", "https://x/orig.jpg");
        assert_eq!(
            thumb_source_candidates(&it, 640),
            vec!["https://x/sample.jpg", "https://x/thumb.jpg", "https://x/orig.jpg"]
        );
    }

    /// The expensive mistake this ordering exists to prevent: a wall of tiles
    /// each pulling a multi-megabyte original because no sample was stored.
    #[test]
    fn a_tile_without_a_sample_falls_back_to_the_preview_first() {
        let it = item("https://x/thumb.jpg", "", "https://x/orig.jpg");
        let got = thumb_source_candidates(&it, 640);
        assert_eq!(got.first().map(String::as_str), Some("https://x/thumb.jpg"),
            "a tile with no sample must take the cheap preview, not the original");
        assert_eq!(got, vec!["https://x/thumb.jpg", "https://x/orig.jpg"]);
    }

    #[test]
    fn between_640_and_1280_prefers_the_sample() {
        let it = item("https://x/thumb.jpg", "https://x/sample.jpg", "https://x/orig.jpg");
        assert_eq!(
            thumb_source_candidates(&it, 1280),
            vec!["https://x/sample.jpg", "https://x/orig.jpg", "https://x/thumb.jpg"]
        );
    }

    #[test]
    fn above_1280_prefers_the_original() {
        let it = item("https://x/thumb.jpg", "https://x/sample.jpg", "https://x/orig.jpg");
        assert_eq!(
            thumb_source_candidates(&it, 2048),
            vec!["https://x/orig.jpg", "https://x/sample.jpg", "https://x/thumb.jpg"]
        );
    }

    #[test]
    fn an_empty_sample_just_drops_out() {
        let it = item("https://x/thumb.jpg", "", "https://x/orig.jpg");
        assert_eq!(thumb_source_candidates(&it, 1280), vec!["https://x/orig.jpg", "https://x/thumb.jpg"]);
    }
}

/// Extensions a cached thumbnail might be sitting under, newest-first.
///
/// New writes are `.jpg` (photographic) or `.png` (alpha survives — see
/// `image::thumb_format`). `.webp` stays checked forever: it is what every
/// thumbnail written before this change is named, and this list is how those
/// ~15,500 existing files keep being found and served rather than silently
/// orphaned and re-fetched from a booru that will rate-limit us for it.
const THUMB_EXTS: [&str; 3] = ["jpg", "png", "webp"];

/*
 * HOW MANY RATIOS MAY RIDE IN ONE FRAME.
 *
 * Not a politeness limit — a hard ceiling imposed by the client's JS engine.
 * QV4's `JSON.parse` segfaults on an array of roughly 600,000 elements or more
 * (bisected in pure JS, no socket: 500,000 parses, 600,000 does not), and one
 * ratio per row of a large catalogue sails past that. The crash has no JS error
 * and no QML file attached to it, so leaving the cap out cost a day of reading
 * backtraces that all pointed at the garbage collector.
 *
 * 100,000 is comfortably under the ceiling, is more rows than any viewport can
 * reach before the next slice lands, and keeps a frame around 1.4 MB.
 */
const RATIOS_CHUNK: usize = 100_000;

/// Where a row's thumbnail lives once it has been fetched, in a specific
/// format. The format is not known until the image is decoded (see
/// `image::thumb_format`), so callers check `cached_thumb`/`cached_thumb_sync`
/// BEFORE they have one, and build a concrete path only after encoding.
///
/// Free function, not a `Server` method: the `thumbs` handler spawns one
/// `tokio::task` per fetch (`futures_lite_join`), which needs `'static`
/// futures and so cannot borrow `&self` — it captures `thumb_dir` by value
/// instead and calls this directly.
fn thumb_file(thumb_dir: &str, id: &str, size: u32, ext: &str) -> String {
    format!("{thumb_dir}/{}-{size}.{ext}", scrape::cache_key(id))
}

impl Server {
    /// Write a video out unchanged, and record the slot it was for.
    ///
    /// Deliberately parallel to the tail of `export` rather than shared with
    /// it: everything the two have in common is the template and the slot
    /// record, and everything they do differently is the whole middle of the
    /// function. Factoring that into one path with an `if` at every step is
    /// how you get a function nobody can read.
    async fn export_video(
        &self,
        req_id: u64,
        item: &crate::protocol::Item,
        bytes: &[u8],
        params: &serde_json::Value,
    ) -> Response {
        // Whatever the file actually is, not what the URL claimed.
        // Also the path for any family exported as the original (`original: true`).
        let is_video = image::is_video(bytes) || item.family == "video";
        let ext = if !item.ext.is_empty() {
            item.ext.clone()
        } else if is_video {
            "mp4".to_string()
        } else {
            crate::scrape::guess_ext(&item.url, None)
        };

        let (w, h, duration) = if !is_video {
            (item.w, item.h, 0.0)
        } else {
            let spool = std::env::temp_dir().join(format!("quarry-export-{}.bin", std::process::id()));
            let facts = match tokio::fs::write(&spool, bytes).await {
                Ok(()) => image::probe_video(&spool).ok(),
                Err(_) => None,
            };
            let _ = tokio::fs::remove_file(&spool).await;
            facts.unwrap_or((item.w, item.h, item.duration))
        };

        let template = params
            .get("path")
            .and_then(|v| v.as_str())
            .unwrap_or(if is_video {
                "~/Videos/quarry/{target}/{slug}-{w}x{h}.{ext}"
            } else {
                "~/Pictures/quarry/{kind}/{slug}-{w}x{h}.{ext}"
            });
        let target_id = params.get("target").and_then(|v| v.as_str()).unwrap_or("unnamed");
        let target_group = params.get("group").and_then(|v| v.as_str()).unwrap_or("");

        let expanded = util::expand_template(
            template,
            &[
                ("kind", item.kind.clone()),
                ("source", item.source.clone()),
                ("slug", item.slug.clone()),
                ("target", if target_id.is_empty() { item.kind.clone() } else { target_id.to_string() }),
                ("group", if target_group.is_empty() { item.kind.clone() } else { target_group.to_lowercase() }),
                ("w", w.to_string()),
                ("h", h.to_string()),
                ("ext", ext.clone()),
            ],
        );
        let path = util::unique_path(&expanded);

        if let Err(e) = util::write_atomic(&path, bytes).await {
            return Response::err(req_id, format!("write: {e}"));
        }

        self.catalog.lock().await.slot_set(target_id, &item.id, &path.to_string_lossy(), false);
        if duration > 0.0 {
            self.catalog.lock().await.remember_video(&item.id, w, h, duration);
        }

        self.log(format_args!(
            "export {} -> {} ({}, {}, unmodified)",
            item.id,
            path.display(),
            util::human_bytes(bytes.len() as u64),
            if is_video { format!("{duration:.1}s of video") } else { "original".into() }
        ));

        Response::ok(
            req_id,
            serde_json::json!({
                "path": path.to_string_lossy(),
                "bytes": bytes.len(),
                "width": w,
                "height": h,
                "duration": duration,
                "human": util::human_bytes(bytes.len() as u64),
                // So the caller knows the recipe was not applied and can say so
                // rather than claiming a crop it did not make.
                "verbatim": true,
            }),
        )
    }

    fn thumb_path(&self, id: &str, size: u32, ext: &str) -> String {
        thumb_file(&self.thumb_dir, id, size, ext)
    }

    /// The existing cached path for this id/size, in whatever format it was
    /// last written as — `.jpg`, `.png`, or a pre-existing lossless `.webp`.
    /// `None` means nothing is cached yet; the caller must fetch and decode
    /// before it can know which extension the new file gets.
    /*
     * MAKE SURE A ROW HAS A PERCEPTUAL HASH.
     *
     * Hashes are a by-product of thumbnailing, so only pictures you have
     * actually looked at have one — 7% of this catalogue. "More like this"
     * therefore refused on most rows, which reads as the feature being broken
     * rather than as the row being unmeasured.
     *
     * Prefers a thumbnail already on disk, because that costs no network at
     * all: the bytes are right there and hashing them is a decode and some
     * arithmetic. Only if there is none does it fetch, and `allow_fetch` is how
     * the caller says whether that is acceptable — the backfill sweep says no,
     * a person asking about one picture says yes.
     */
    /*
     * ONE PASS OF THE HASHING BACKLOG.
     *
     * Extracted so the background sweep and the explicit `backfill` request run
     * exactly the same code — a second implementation of this would drift, and
     * the one that drifts is always the one nobody watches.
     */
    async fn backfill_once(&self, limit: usize, use_network: bool) -> serde_json::Value {
        // Collect the worklist and RELEASE the lock: the fetches below must not
        // hold up every other request on the socket.
        let work = {
            let catalog = self.catalog.lock().await;
            catalog.unhashed(limit)
        };
        let wanted = work.len();

        let mut from_cache = 0usize;
        let mut from_network = 0usize;
        let mut failed = 0usize;
        let mut done: Vec<(String, String, String)> = Vec::new();
        // Rows with no cached thumbnail, so the next round starts past them.
        let mut unhashable: Vec<String> = Vec::new();
        let mut reasons: Vec<String> = Vec::new();

        for (id, thumb_url, full_url) in work {
            // Tier one: a thumbnail we already wrote, whichever format
            // (jpg/png/legacy webp) it landed in.
            let mut bytes: Option<Vec<u8>> = None;
            'search: for step in [320u32, 640, 160, 1280] {
                for ext in THUMB_EXTS {
                    let cached = self.thumb_path(&id, step, ext);
                    if let Ok(b) = tokio::fs::read(&cached).await {
                        bytes = Some(b);
                        from_cache += 1;
                        break 'search;
                    }
                }
            }
            // Tier two: the small preview, if allowed.
            if bytes.is_none() && use_network {
                for candidate in [&thumb_url, &full_url] {
                    if candidate.is_empty() {
                        continue;
                    }
                    if let Ok(b) = self.http.fetch_bytes(candidate).await {
                        bytes = Some(b);
                        from_network += 1;
                        break;
                    }
                }
            }
            let Some(bytes) = bytes else {
                failed += 1;
                if reasons.len() < 4 {
                    reasons.push(format!("{id}: nothing fetched"));
                }
                /*
                 * Nothing on disk for this row, and we were told not to fetch.
                 * Remember that, or the next round reads the same window and
                 * offers it again — which is how the sweep's hit rate decayed
                 * from 37 per 200 to 7 while it re-tried the same dead rows.
                 *
                 * Only when the network was off: a network failure is a bad
                 * minute, not a fact about the row.
                 */
                if !use_network {
                    unhashable.push(id);
                }
                continue;
            };
            match image::load(&bytes, (256, 256)) {
                Ok(decoded) => done.push((
                    id,
                    format!("{:016x}", image::phash(&decoded)),
                    util::to_hex(image::dominant_color(&decoded)),
                )),
                Err(e) => {
                    failed += 1;
                    // WHY, not just how many. A backfill that hashes
                    // nothing and says only "failed: 40" is the same
                    // dead end as a blank screen with healthy counters.
                    if reasons.len() < 4 {
                        reasons.push(format!("{id}: {e} ({} bytes)", bytes.len()));
                    }
                }
            }
        }

        let (hashed, total) = {
            let mut catalog = self.catalog.lock().await;
            for (id, phash, dominant) in &done {
                catalog.remember_hashes(id, phash, dominant);
            }
            for id in &unhashable {
                catalog.skip_hashing(id);
            }
            catalog.hash_coverage()
        };

        serde_json::json!({
            "wanted": wanted,
            "hashedNow": done.len(),
            "fromCache": from_cache,
            "fromNetwork": from_network,
            "failed": failed,
            // A few actual failures, so "hashed nothing" is diagnosable without
            // attaching a debugger.
            "reasons": reasons,
            // The denominator, so a caller can drive this to completion and
            // show honest progress.
            "coverage": hashed,
            "total": total,
            "remaining": total.saturating_sub(hashed),
        })
    }

    /*
     * A PICTURE, AS BYTES, SMALL ENOUGH TO HAND TO A STRANGER.
     *
     * Decoded through `load_any` and re-encoded rather than forwarded raw, so
     * one code path covers everything the catalogue holds: a video answers
     * with its poster frame, an SVG with a render, a 4K original with a
     * 1024px copy instead of eight megabytes of somebody else's bandwidth.
     *
     * A cached thumbnail first when there is a big enough one — it is already
     * on disk and already fetched once — then the same candidate ladder a
     * tile uses, and a local row's own file, whose `url` is a path and not an
     * address.
     */
    async fn searchable_bytes(
        &self,
        item: &crate::protocol::Item,
    ) -> Result<(Vec<u8>, &'static str), String> {
        // Big enough that a crop or a re-encode still matches, small enough
        // to be one polite request.
        const UPLOAD: u32 = 1024;

        let mut sources: Vec<Vec<u8>> = Vec::new();
        for size in [1280u32, 640] {
            if let Some(path) = self.cached_thumb(&item.id, size).await {
                if let Ok(bytes) = tokio::fs::read(&path).await {
                    sources.push(bytes);
                    break;
                }
            }
        }

        let mut last = "that row has no image to search with".to_string();
        for candidate in thumb_source_candidates(item, UPLOAD) {
            if !sources.is_empty() {
                break;
            }
            let fetched = if candidate.starts_with("http") {
                self.http.fetch_bytes(&candidate).await.map_err(|e| e.to_string())
            } else {
                tokio::fs::read(candidate.trim_start_matches("file://"))
                    .await
                    .map_err(|e| e.to_string())
            };
            match fetched {
                Ok(bytes) => sources.push(bytes),
                Err(e) => last = e,
            }
        }

        for bytes in sources {
            let decoded = match image::load_any(&bytes, (UPLOAD, UPLOAD)) {
                Ok((decoded, _)) => decoded,
                Err(e) => {
                    last = format!("decode: {e}");
                    continue;
                }
            };
            let ladder = image::thumb_ladder(&decoded, &[UPLOAD], image::THUMB_QUALITY)
                .map_err(|e| format!("encode: {e}"))?;
            let Some((_, encoded, format)) = ladder.into_iter().next() else {
                continue;
            };
            let mime = match format {
                image::Format::Png => "image/png",
                image::Format::WebpLossless => "image/webp",
                image::Format::Jpeg => "image/jpeg",
            };
            return Ok((encoded, mime));
        }
        Err(last)
    }

    /*
     * THE HANDLE YANDEX GIVES A PICTURE — however it has to be got.
     *
     * Two routes, and the order is a cost decision, not a reliability one.
     *
     * Handing over a URL is one small GET and asks Yandex to go and fetch a
     * picture it very likely already has. It works when the row is on the open
     * web — and it is exactly what fails, silently and often, when it is not:
     * a local file has no URL at all, a hotlink-blocking CDN refuses Yandex
     * the same way it refuses us, a video's `url` is not a picture, and a page
     * nobody has crawled is simply unknown. Every one of those came back as
     * "yandex did not recognise that image".
     *
     * Uploading the bytes is what its own drop zone does, and it has no such
     * failure mode: whatever the picture is, Yandex now has a copy and a
     * handle for it. It costs a megabyte of somebody else's bandwidth, so it
     * is the fallback rather than the first move.
     *
     * Measured 2026-09-17 over six pictures — a Wikimedia photograph, a crop
     * of it, a wallhaven wallpaper, a video's poster frame, a flat logo and
     * random noise: upload 6 of 6, each answering with a full page of 40
     * results; the URL route only for the two that were already public.
     *
     * Answers (the url Yandex should be pointed at, the handle).
     */
    async fn yandex_handle(
        &self,
        item: &crate::protocol::Item,
    ) -> Result<(String, String), String> {
        let mut candidates: Vec<String> = if is_still_image(item) {
            vec![item.url.clone(), item.sample.clone(), item.thumb.clone()]
        } else {
            // A video's file is not something Yandex can look at; its
            // thumbnail is.
            vec![item.thumb.clone(), item.sample.clone()]
        };
        candidates.retain(|u| u.starts_with("http"));
        candidates.dedup();

        let mut last_error = String::new();
        for candidate in candidates.iter().take(2) {
            let viewer = sources::yandex::Yandex::reverse_url(candidate);
            let page = match self.http.fetch_text(&viewer).await {
                Ok(page) => page,
                Err(e) => {
                    last_error = format!("yandex: {e}");
                    continue;
                }
            };
            if let Some(cbir) = sources::yandex::Yandex::cbir_id(&page) {
                return Ok((candidate.clone(), cbir));
            }
            if page.to_lowercase().contains("captcha") {
                // Uploading would meet the same wall, harder.
                return Err(sources::yandex::Yandex::CAPTCHA.to_string());
            }
            last_error = "yandex did not recognise that image".to_string();
        }

        let (bytes, mime) = self.searchable_bytes(item).await.map_err(|e| {
            if last_error.is_empty() { e } else { format!("{last_error} · {e}") }
        })?;
        let answer = self
            .http
            .post_bytes(sources::yandex::Yandex::UPLOAD_URL, mime, &bytes)
            .await
            .map_err(|e| format!("yandex upload: {e}"))?;
        let (cbir, copy) = sources::yandex::Yandex::parse_upload(&answer)?;
        self.log(format_args!(
            "yandex took {} by upload ({} bytes, {mime})",
            item.id,
            bytes.len()
        ));
        Ok((copy, cbir))
    }

    /// Yandex's "similar images" for a row, added to the catalogue; the ids.
    async fn web_similar(&self, id: &str) -> Result<Vec<String>, String> {
        let item = {
            let catalog = self.catalog.lock().await;
            catalog.by_id(id).ok_or_else(|| format!("no such item: {id}"))?
        };
        let (image_url, cbir) = self.yandex_handle(&item).await?;
        let body = self
            .http
            .fetch_text(&sources::yandex::Yandex::similar_url(&image_url, &cbir, crate::prefs::Prefs::load().show_adult))
            .await
            .map_err(|e| format!("yandex: {e}"))?;
        let source = sources::by_id("yandex").ok_or("the yandex source is missing")?;
        let items = source.parse(&body)?;
        let (usable, _) = scrape::keep_usable(scrape::dedupe(items));
        let ids: Vec<String> = usable.iter().map(|i| i.id.clone()).collect();
        let (added, known) = self.catalog.lock().await.add(usable);
        self.log(format_args!("similar web for {id}: {} found, {added} new, {known} known", ids.len()));
        Ok(ids)
    }

    /*
     * EVERY COPY OF THIS PICTURE ON THE WEB.
     *
     * One fetch of Yandex's `sites` page answers both menu entries: "where
     * else it appears" is the rows as Yandex ranked them, and "find a bigger
     * copy" is the same rows with the ones no larger than yours dropped and
     * the rest sorted by area. Asking twice would be two captcha risks and two
     * page loads for one question.
     *
     * `only_bigger` with nothing bigger is a real answer and says so, rather
     * than falling back to the full list and quietly answering a different
     * question.
     */
    async fn web_copies(&self, id: &str, only_bigger: bool) -> Result<Vec<String>, String> {
        let item = {
            let catalog = self.catalog.lock().await;
            catalog.by_id(id).ok_or_else(|| format!("no such item: {id}"))?
        };
        let (image_url, cbir) = self.yandex_handle(&item).await?;
        let page = sources::yandex::Yandex::page_url(&image_url, &cbir, "sites", crate::prefs::Prefs::load().show_adult);
        let body = self.http.fetch_text(&page).await.map_err(|e| format!("yandex: {e}"))?;

        // The asking row's own thumbnail, for the copies Yandex lists without
        // one: they ARE this picture, at another size.
        let mut copies = sources::yandex::Yandex::copies(&body, &item.thumb);
        if only_bigger {
            let area = (item.w as u64) * (item.h as u64);
            copies.retain(|other| (other.w as u64) * (other.h as u64) > area);
            copies.sort_by_key(|other| std::cmp::Reverse((other.w as u64) * (other.h as u64)));
        }
        let (usable, _) = scrape::keep_usable(scrape::dedupe(copies));
        if usable.is_empty() {
            return Err(if only_bigger {
                format!("no copy bigger than {}\u{d7}{} anywhere", item.w, item.h)
            } else {
                "yandex has not seen this picture anywhere".to_string()
            });
        }
        let ids: Vec<String> = usable.iter().map(|i| i.id.clone()).collect();
        let (added, known) = self.catalog.lock().await.add(usable);
        self.log(format_args!(
            "copies for {id} (bigger={only_bigger}): {} found, {added} new, {known} known",
            ids.len()
        ));
        Ok(ids)
    }

    /*
     * "More like this" from the picture's own site.
     *
     * wallhaven has a real similar search (`like:<id>`, its "similar
     * wallpapers" link). Everywhere else with tag search, the site is asked for
     * the picture's two most distinctive tags — the character and the series
     * rather than `highres solo` — which is what "more like this" means on a
     * booru. A text-only site gets the title's longer words. Answers the ids
     * it added, and a line saying how it asked.
     */
    /// The playable files a page declares, fetched at most once every five
    /// minutes per page.
    /*
     * A ROW LEARNS ITS TAGS FROM ITS OWN PAGE.
     *
     * Ten tube sites list a title and a poster and nothing else, so 3,000 of
     * their videos had no tags: "Search its tags" said there were none and
     * `tag:` never found them. The page the player is fetched from carries
     * them (see `page_tags` on Source), so they are added the first time the
     * video is opened — re-read from the catalogue, so this never undoes the
     * update `resolve` made a moment before.
     */
    async fn adopt_page_tags(&self, id: &str, page: &str) {
        let Some(found) = self.page_tags.lock().await.get(page).cloned() else { return };
        let mut catalog = self.catalog.lock().await;
        let Some(mut row) = catalog.by_id(id) else { return };
        let before = row.tags.len();
        for tag in found {
            if !row.tags.iter().any(|t| t.eq_ignore_ascii_case(&tag)) {
                row.tags.push(tag);
            }
        }
        if row.tags.len() > before {
            catalog.replace(row);
        }
    }

    async fn videos_for_page(&self, page: &str, source: &str) -> Result<Vec<(String, String)>, String> {
        const KEEP: std::time::Duration = std::time::Duration::from_secs(300);
        if let Some((until, found)) = self.page_videos.lock().await.get(page) {
            if std::time::Instant::now() < *until {
                return Ok(found.clone());
            }
        }
        /*
         * ARRIVE FROM THE SITE, or some pages are simply not there.
         *
         * hqporner answers 404 to a detail page requested with no Referer and
         * 200 to the same URL with one — measured 2026-10-01 on
         * `/hdporn/109623-…`, which its own listing links and which the app
         * reported as "http 404" on a row eight hours old. Not every page does
         * it: older ones serve fine either way, so the source looked half
         * broken rather than protected.
         *
         * The site's own root is what a browser sends when you click through
         * from a listing, which is the only way anybody reaches one of these,
         * so it is the honest value — not a forged one. The iframe hop below
         * already does this for the player host; the page itself never learned.
         */
        if let Some(host) = scrape::host_of(page) {
            fetchkit::set_referer(&host, &format!("https://{host}/"));
        }
        /*
         * FRESH, NEVER FROM THE CACHE.
         *
         * The media URLs on a video page are SIGNED and short-lived. The HTTP
         * cache holds a page for 15 minutes, so a page fetched 14 minutes ago
         * answers with links that have already expired — measured on pornhub:
         * HTTP 410 on every rendition, and the player showed a black rectangle
         * because nothing reported a failure.
         *
         * This is the one fetch in the daemon whose VALUE expires rather than
         * just going stale, so it is the one that must not be reused.
         */
        let body = self.http.fetch_text_fresh(page).await.map_err(|e| e.to_string())?;
        if let Some(src) = sources::by_id(source) {
            let tags = src.page_tags(&body);
            if !tags.is_empty() {
                let mut held = self.page_tags.lock().await;
                // Small, but not without bound over a long session.
                if held.len() > 5000 {
                    held.clear();
                }
                held.insert(page.to_string(), tags);
            }
        }
        /*
         * EPORNER IS ASKED ITS OWN WAY FIRST.
         *
         * Its page does declare an og:video — gvideo.eporner.com/<id>/<id>.mp4
         * — and that file answers 403, which is the "the host would not serve
         * it" in the viewer. The files the player actually uses come from an
         * endpoint (see eporner_request), so the scrape is the fallback here
         * rather than the first answer.
         */
        let mut found = Vec::new();
        if let Some(ask) = eporner_request(&body, page) {
            if let Ok(answer) = self.http.fetch_text(&ask).await {
                found = eporner_videos(&answer);
            }
        }
        /*
         * The pornhub family's own endpoint, before the page scan — see
         * `media_definition_request`. Asked first because what the scan would
         * find on these pages is the related-videos rail, not the film.
         */
        if found.is_empty() {
            if let Some(ask) = media_definition_request(&body) {
                if let Ok(answer) = self.http.fetch_text(&ask).await {
                    found = media_definition_videos(&answer);
                }
            }
        }
        /*
         * The page named an endpoint rather than files.
         *
         * redtube's player asks /media/mp4 for its qualities. Asked BEFORE the
         * scan below: the page is full of `…_fb.mp4` hover previews for the
         * related videos, the scan found those first, and every redtube video
         * played as somebody else's ten-second preview. The answer is signed
         * and short-lived, which is fine: this lookup is cached for minutes.
         */
        if found.is_empty() {
            for index in media_indexes(&body, page) {
                if let Ok(answer) = self.http.fetch_text(&index).await {
                    let files = media_index_files(&answer, page);
                    if !files.is_empty() {
                        found = files;
                        break;
                    }
                }
            }
        }
        if found.is_empty() {
            found = videos_on_page(&body, page);
        }
        /*
         * THE PLAYER IS ON ANOTHER HOST.
         *
         * Last, because it costs another request to another site and almost no page
         * needs it. hqporner does: its own page has no file on it at all, only an
         * iframe to mydaddy.cc, which is where the three qualities live. Its referer
         * is this page, which those hosts check.
         */
        if found.is_empty() {
            for frame in player_iframes(&body, page) {
                /*
                 * THE PLAYER HOST WANTS TO KNOW WHICH PAGE EMBEDDED IT.
                 *
                 * mydaddy.cc — hqporner's player — answers 200 and a 181-byte
                 * "This domain has been blocked" to anyone who asks without a
                 * Referer, whatever User-Agent they send. With the hqporner page as
                 * the referer the same URL returns the three qualities. Registered
                 * per host, so the files the page then names are fetched the same
                 * way; `set_referer` already applies to a host's subdomains.
                 */
                if let Some(host) = fetchkit::host_of(&frame) {
                    fetchkit::set_referer(&host, page);
                }
                let Ok(inner) = self.http.fetch_text(&frame).await else { continue };
                let files = videos_on_page(&inner, &frame);
                if !files.is_empty() {
                    found = files;
                    break;
                }
            }
        }

        /*
         * A FAILURE IS NOT CACHED FOR AS LONG AS AN ANSWER.
         *
         * Caching "no video on that page" for five minutes means a page that failed
         * once — a timeout, a 503, a extractor that has since been fixed — stays
         * unplayable for five minutes however many times you press play, and the
         * retry costs nothing because it never happens. It made this very bug look
         * unfixed after it had been fixed: the daemon answered in 2 ms from a cached
         * empty while the new code sat there unused.
         *
         * Twenty seconds is still enough to stop a double-click being two crawls.
         */
        const KEEP_EMPTY: std::time::Duration = std::time::Duration::from_secs(20);
        let hold = if found.is_empty() { KEEP_EMPTY } else { KEEP };
        self.page_videos
            .lock()
            .await
            .insert(page.to_string(), (std::time::Instant::now() + hold, found.clone()));
        Ok(found)
    }

    async fn native_similar(&self, id: &str) -> Result<(Vec<String>, String), String> {
        let item = {
            let catalog = self.catalog.lock().await;
            catalog.by_id(id).ok_or_else(|| format!("no such item: {id}"))?
        };
        let source = sources::by_id(&item.source).ok_or_else(|| format!("{} is not a source that can be asked", item.source))?;
        let caps = source.capabilities();
        let base = sources::SourceQuery {
            page: 1,
            wants_video: if item.family == "video" { Some(true) } else { None },
            ..Default::default()
        };

        /*
         * A LADDER, NOT A SINGLE QUESTION.
         *
         * Each rung is narrower than the next is broad: the site's own similar
         * search, the picture's two most specific tags together, each of them
         * alone, the title's words. The first rung that brings pictures back
         * answers. Measured on the live sites: two rare tags together often
         * match nothing (an artist AND a series), and wallhaven's `like:`
         * answers 403 without an account — each would have been a "similar
         * does nothing" on its own.
         */
        let mut ladder: Vec<(sources::SourceQuery, String)> = Vec::new();
        if item.source == "wallhaven" && !item.source_id.is_empty() {
            let mut like = base.clone();
            like.text = vec![format!("like:{}", item.source_id)];
            ladder.push((like, "wallhaven's own similar wallpapers".to_string()));
            // Its tags by id, from the wallpaper's own page: exact, where names
            // are ambiguous.
            let info = format!("https://wallhaven.cc/api/v1/w/{}", item.source_id);
            if let Ok(body) = self.http.fetch_text(&info).await {
                if let Ok(json) = serde_json::from_str::<serde_json::Value>(&body) {
                    let tags: Vec<(u64, String)> = json["data"]["tags"]
                        .as_array()
                        .map(|tags| {
                            tags.iter()
                                .filter_map(|t| Some((t["id"].as_u64()?, t["name"].as_str().unwrap_or("").to_string())))
                                .collect()
                        })
                        .unwrap_or_default();
                    for (tag_id, name) in tags.into_iter().take(3) {
                        let mut tagged = base.clone();
                        tagged.text = vec![format!("id:{tag_id}")];
                        ladder.push((tagged, format!("wallhaven tagged {name}")));
                    }
                }
            }
        }
        if caps.tags && !item.tags.is_empty() {
            let tags = self.catalog.lock().await.distinctive_tags(&item, 3);
            if tags.len() >= 2 {
                let mut both = base.clone();
                both.tags = tags[..2].to_vec();
                ladder.push((both, format!("{} tagged {}", item.source, tags[..2].join(" + "))));
            }
            for tag in &tags {
                let mut one = base.clone();
                one.tags = vec![tag.clone()];
                ladder.push((one, format!("{} tagged {tag}", item.source)));
            }
        }
        if caps.text && !item.title.is_empty() {
            let words: Vec<String> = item
                .title
                .split(|c: char| !c.is_alphanumeric())
                .filter(|w| w.chars().count() > 3)
                .take(4)
                .map(str::to_string)
                .collect();
            if !words.is_empty() {
                let mut titled = base.clone();
                let how = format!("{} for “{}”", item.source, words.join(" "));
                titled.text = words.clone();
                ladder.push((titled, how));
            }
            // An icon called "rewind eight" is found by "rewind".
            if words.len() > 1 {
                for word in words.iter().take(2) {
                    let mut one = base.clone();
                    one.text = vec![word.clone()];
                    ladder.push((one, format!("{} for “{word}”", item.source)));
                }
            }
        }
        if ladder.is_empty() {
            return Err(format!("{} cannot be asked for similar pictures", item.source));
        }

        // A thin answer is kept but not settled for: two pictures is a tag
        // too specific to be "more like this", so the next rung is tried and
        // the fuller answer wins.
        const ENOUGH: usize = 8;
        let mut best: Option<(Vec<crate::protocol::Item>, String)> = None;
        let mut last_error = String::new();
        for (query, how) in ladder.into_iter().take(7) {
            let url = source.build_url(&query);
            let document = source.body(&query);
            let body = match fetch_page(&self.http, &url, document.as_ref()).await {
                Ok(body) => body,
                Err(e) => {
                    last_error = format!("{}: {e}", item.source);
                    continue;
                }
            };
            // Several boards answer "no posts" with an empty body, not `[]`.
            let rows = if body.trim().is_empty() {
                Vec::new()
            } else {
                match source.parse(&body) {
                    Ok(rows) => rows,
                    Err(e) => {
                        last_error = format!("{}: {e}", item.source);
                        continue;
                    }
                }
            };
            let (mut usable, _) = scrape::keep_usable(scrape::dedupe(rows));
            usable.retain(|other| other.id != item.id);
            if usable.is_empty() {
                last_error = format!("{how}: nothing");
                continue;
            }
            let enough = usable.len() >= ENOUGH;
            if best.as_ref().is_none_or(|(kept, _)| usable.len() > kept.len()) {
                best = Some((usable, how));
            }
            if enough {
                break;
            }
        }
        let Some((usable, how)) = best else {
            return Err(last_error);
        };
        let ids: Vec<String> = usable.iter().map(|i| i.id.clone()).collect();
        let (added, known) = self.catalog.lock().await.add(usable);
        self.log(format_args!("similar native for {id} ({how}): {} found, {added} new, {known} known", ids.len()));
        Ok((ids, how))
    }

    async fn ensure_hashed(&self, id: &str, allow_fetch: bool) -> Result<String, String> {
        let item = {
            let catalog = self.catalog.lock().await;
            match catalog.by_id(id) {
                Some(item) => item.clone(),
                None => return Err(format!("no such item: {id}")),
            }
        };
        if !item.phash.is_empty() {
            return Ok(item.phash);
        }

        let bytes = match self.cached_thumb(&item.id, 320).await {
            Some(path) => tokio::fs::read(&path)
                .await
                .map_err(|e| format!("read {path}: {e}"))?,
            None => {
                if !allow_fetch {
                    return Err("not measured, and no thumbnail on disk".to_string());
                }
                // A video file does not decode as a picture; its thumbnail does.
                let url = if item.url.is_empty() || !is_still_image(&item) { &item.thumb } else { &item.url };
                if url.is_empty() {
                    return Err("that row has no image to measure".to_string());
                }
                self.http
                    .fetch_bytes(url)
                    .await
                    .map_err(|e| format!("fetch: {e}"))?
            }
        };

        // 256 is the hint the crawl's own hashing pass uses: a phash is a 32×32
        // reduction, so decoding larger buys nothing and costs a lot on a sweep.
        let decoded = image::load(&bytes, (256, 256)).map_err(|e| format!("decode: {e}"))?;
        let phash = format!("{:016x}", image::phash(&decoded));
        let dominant = util::to_hex(image::dominant_color(&decoded));
        self.catalog
            .lock()
            .await
            .remember_hashes(&item.id, &phash, &dominant);
        Ok(phash)
    }

    async fn cached_thumb(&self, id: &str, size: u32) -> Option<String> {
        for ext in THUMB_EXTS {
            let p = self.thumb_path(id, size, ext);
            if tokio::fs::metadata(&p).await.is_ok() {
                return Some(p);
            }
        }
        None
    }

    /// Same lookup as `cached_thumb`, but synchronous — for the hot path in
    /// `items` that fills in `thumb_local` for a whole page without going
    /// async per row.
    fn cached_thumb_sync(&self, id: &str, size: u32) -> Option<String> {
        for ext in THUMB_EXTS {
            let p = self.thumb_path(id, size, ext);
            if std::path::Path::new(&p).exists() {
                return Some(p);
            }
        }
        None
    }

    /*
     * WHICH SOURCES ARE ACTUALLY ANSWERING.
     *
     * `doctor` probes every source on demand, which answers "is it broken
     * right now if I ask it directly". It does not answer the question that
     * matters while you browse: this wall is empty — is the site refusing me,
     * or is there genuinely nothing there? A site that starts answering 403
     * looked EXACTLY like a site with no pictures.
     *
     * So every fetch a source does while you use quarry is recorded here: the
     * last time it worked, the last time it did not and why, and how many
     * times in a row. The counter is the useful part — one failure is a
     * network blip, five in a row is a site that has changed.
     *
     * It also goes to a file, because a daemon that restarts forgets, and
     * "it broke last Tuesday" is a thing you want to be able to look up.
     */
    async fn record_health(&self, source: &str, ok: bool, status: u16, detail: &str, rows: usize) {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let (was_ok, streak) = {
            let mut table = self.health.lock().await;
            let entry = table.entry(source.to_string()).or_insert_with(|| SourceHealth {
                ok: true,
                status: 0,
                detail: String::new(),
                rows: 0,
                last_ok: 0,
                last_fail: 0,
                fails: 0,
                checks: 0,
            });
            let was_ok = entry.checks == 0 || entry.ok;
            entry.checks += 1;
            entry.ok = ok;
            entry.status = status;
            entry.rows = rows;
            entry.detail = detail.chars().take(200).collect();
            if ok {
                entry.last_ok = now;
                entry.fails = 0;
            } else {
                entry.last_fail = now;
                entry.fails += 1;
            }
            (was_ok, entry.fails)
        };

        /*
         * Written when the ANSWER CHANGES, not on every fetch.
         *
         * A working source is fetched hundreds of times an hour; a line each
         * would bury the one line that matters under a megabyte of "fine".
         * So: the first failure, every fifth one after that while it stays
         * broken, and the recovery.
         */
        let worth_writing = (ok && !was_ok) || (!ok && (was_ok || streak % 5 == 0));
        if !worth_writing {
            return;
        }
        let line = if ok {
            format!("{now}\t{source}\tok\t{status}\t{rows} rows\n")
        } else {
            format!("{now}\t{source}\tfail\t{status}\t{} (failure {streak})\n", detail.replace('\n', " "))
        };
        let path = self.health_log.clone();
        tokio::task::spawn_blocking(move || {
            use std::io::Write;
            // Capped rather than rotated: this is a diagnostic, not an audit
            // trail, and a log that can fill a disk is its own bug.
            if std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0) > 1_000_000 {
                let _ = std::fs::remove_file(&path);
            }
            if let Some(dir) = std::path::Path::new(&path).parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            if let Ok(mut file) =
                std::fs::OpenOptions::new().create(true).append(true).open(&path)
            {
                let _ = file.write_all(line.as_bytes());
            }
        });
    }

    fn log(&self, args: std::fmt::Arguments) {
        if !self.quiet {
            eprintln!("[quarryd] {args}");
        }
    }

    async fn handle(self: &Arc<Self>, req: Request) -> Response {
        match req.m.as_str() {
            "hello" => {
                let catalog = self.catalog.lock().await;
                Response::ok(
                    req.id,
                    serde_json::json!({
                        "protocol": PROTOCOL_VERSION,
                        // "live" once the catalogue is a database rather than a
                        // fixture held in memory.
                        "backend": if catalog.persistent() { "live" } else { "mock" },
                        "version": env!("CARGO_PKG_VERSION"),
                        "items": catalog.len(),
                        // Said at the door, so a client knows before its first
                        // query that the answers cannot be trusted.
                        "damaged": catalog.damage(),
                        // And whether the one irreplaceable file — the copy of
                        // your boards and collections — is actually being written.
                        "userData": catalog.backup_error(),
                        // Whether this process is still the binary that is
                        // installed. Advice, not an error — see PROTOCOL.md.
                        "stale": binary_is_stale(),
                        // Who is actually answering. A restart that is accepted
                        // and then refuses the catalogue leaves the OLD process
                        // serving, and "restart it" is useless advice without a
                        // way to tell which one to stop.
                        "pid": std::process::id(),
                    }),
                )
            }

            "query" => {
                let params: QueryParams = match serde_json::from_value(req.p.clone()) {
                    Ok(p) => p,
                    Err(e) => return Response::err(req.id, format!("bad query params: {e}")),
                };
                let mut catalog = self.catalog.lock().await;
                let result = catalog.query(&params);
                self.log(format_args!(
                    "query kind={:?} source={:?} q={:?} repeat={} -> {} rows",
                    params.kind, params.source, params.q, params.repeat, result.count
                ));
                let damage = catalog.damage();
                Response::ok(
                    req.id,
                    serde_json::json!({
                        // A query that could not run answered "0 rows" and the
                        // app drew its ordinary "nothing matched" — for a whole
                        // day, over a full catalogue with a broken index.
                        "damaged": damage,
                        "userData": catalog.backup_error(),
                        "queryId": result.query_id,
                        "count": result.count,
                        // How many rows were the same picture as another. An
                        // empty-looking result should never be a mystery.
                        "duplicates": result.duplicates,
                        /*
                         * THE FIRST SLICE ONLY — the rest comes from `ratios`.
                         *
                         * One ratio per row of this user's 752,415-item
                         * catalogue is a 10.3 MB frame holding a 752,168-element
                         * array, and QV4 SEGFAULTS parsing an array that long:
                         * bisected in pure JS with no socket in it, 500,000
                         * parses and 600,000 does not. There is no JS error to
                         * catch, so the app simply died on launch.
                         *
                         * See PROTOCOL.md `ratios`.
                         */
                        "ratios": result
                            .ratios
                            .iter()
                            .take(RATIOS_CHUNK)
                            .copied()
                            .collect::<Vec<f64>>(),
                        "ratiosFrom": 0,
                        "sort": result.sort,
                        "unknown": result.unknown,
                    }),
                )
            }

            // Append what the crawl added to the result already open. See
            // Catalog::extend — this is what an endless feed does instead of
            // re-running the query under a client that is scrolling.
            // What is on the disk, per source, for the delete picker. Adult rows
            // are COUNTED here, not hidden — this list exists to remove them.
            "stored" => {
                let catalog = self.catalog.lock().await;
                let rows: Vec<serde_json::Value> = catalog
                    .stored_counts()
                    .into_iter()
                    .map(|(source, count, adult)| {
                        serde_json::json!({ "source": source, "count": count, "adult": adult })
                    })
                    .collect();
                let adult: usize = rows
                    .iter()
                    .map(|r| r["adult"].as_u64().unwrap_or(0) as usize)
                    .sum();
                Response::ok(req.id, serde_json::json!({ "sources": rows, "adult": adult }))
            }

            /*
             * Delete what a query matches, and the files cached for it.
             *
             * The adult switch hides; this removes. Both are wanted and they are
             * not the same promise — see PROTOCOL.md `purge`.
             */
            "purge" => {
                let params: QueryParams = match serde_json::from_value(req.p.clone()) {
                    Ok(p) => p,
                    Err(e) => return Response::err(req.id, format!("bad purge params: {e}")),
                };
                /*
                 * An empty query means "delete the catalogue". Nobody types that
                 * on purpose, and it is the one mistake here with no way back —
                 * so it is refused rather than confirmed.
                 */
                if params.q.trim().is_empty() {
                    return Response::err(
                        req.id,
                        "purge needs a query — an empty one would delete the whole catalogue".to_string(),
                    );
                }

                /*
                 * `dryRun` answers "how much would go" through the SAME match,
                 * so the number the panel shows beside the button cannot drift
                 * from the number the button then deletes.
                 */
                let dry = req.p.get("dryRun").and_then(|v| v.as_bool()).unwrap_or(false);
                let ids = {
                    let mut catalog = self.catalog.lock().await;
                    if dry {
                        catalog.purge_preview(&params)
                    } else {
                        match catalog.purge(&params) {
                            Ok(ids) => ids,
                            Err(e) => return Response::err(req.id, e),
                        }
                    }
                };

                /*
                 * The thumbnails, by cache key rather than by id.
                 *
                 * Scanning the cache once and testing each file against a set is
                 * O(files); globbing the directory per id would be 600,000 passes
                 * over it. Files are named `<key>-<size>.<ext>`, so the key is
                 * everything before the last '-'.
                 */
                let keys: std::collections::HashSet<String> =
                    ids.iter().map(|id| scrape::cache_key(id)).collect();
                let mut files = 0usize;
                let mut bytes = 0u64;
                if let Ok(entries) = std::fs::read_dir(&self.thumb_dir) {
                    for entry in entries.flatten() {
                        let name = entry.file_name().to_string_lossy().to_string();
                        let stem = match name.rsplit_once('-') {
                            Some((stem, _)) => stem,
                            None => continue,
                        };
                        // `preview-<key>.png` is written for 3D poses; it carries
                        // the key on the other side of the dash.
                        let key = stem.strip_prefix("preview-").unwrap_or(stem);
                        if !keys.contains(key) {
                            continue;
                        }
                        let size = entry.metadata().map(|m| m.len()).unwrap_or(0);
                        if dry {
                            files += 1;
                            bytes += size;
                        } else if std::fs::remove_file(entry.path()).is_ok() {
                            files += 1;
                            bytes += size;
                        }
                    }
                }

                Response::ok(
                    req.id,
                    serde_json::json!({
                        "rows": ids.len(),
                        "files": files,
                        "bytes": bytes,
                    }),
                )
            }

            // The rest of the wall's geometry, a slice at a time. `query` sends
            // only the first RATIOS_CHUNK because a longer array kills the
            // client's JS engine outright; this is how the client gets the rest.
            "ratios" => {
                let query_id = req.p.get("queryId").and_then(|v| v.as_u64()).unwrap_or(0);
                let from = req
                    .p
                    .get("from")
                    .and_then(|v| v.as_u64())
                    .unwrap_or(0) as usize;
                let count = req
                    .p
                    .get("count")
                    .and_then(|v| v.as_u64())
                    .map(|n| n as usize)
                    .unwrap_or(RATIOS_CHUNK)
                    .min(RATIOS_CHUNK);
                let catalog = self.catalog.lock().await;
                match catalog.ratios_slice(query_id, from, count) {
                    Some((ratios, total)) => Response::ok(
                        req.id,
                        serde_json::json!({
                            "queryId": query_id,
                            "from": from,
                            "ratios": ratios,
                            "total": total,
                        }),
                    ),
                    None => Response::err(req.id, format!("stale queryId {query_id}")),
                }
            }

            "extend" => {
                let params: QueryParams = match serde_json::from_value(req.p.clone()) {
                    Ok(p) => p,
                    Err(e) => return Response::err(req.id, format!("bad extend params: {e}")),
                };
                let query_id = req.p.get("queryId").and_then(|v| v.as_u64()).unwrap_or(0);
                let mut catalog = self.catalog.lock().await;
                match catalog.extend(&params, query_id) {
                    Some((count, ratios)) => Response::ok(
                        req.id,
                        serde_json::json!({
                            "queryId": query_id,
                            "count": count,
                            "added": ratios.len(),
                            "ratios": ratios,
                        }),
                    ),
                    None => Response::err(req.id, format!("stale queryId {query_id}")),
                }
            }

            // A query that keeps nothing, for a second window. See Catalog::find.
            /*
             * ONE RANDOM PICTURE, AS A FILE: what the shell's "Random wallpaper"
             * button needs, in one request instead of four (search, query,
             * items, export) and a socat session.
             *
             * `{source?, q?, path?, crawl?, pages?}`. With a source and `crawl`
             * (default on) it first fetches a random page among the first
             * `pages` (10) so the pick is not always from the same rows; a
             * refused crawl is not fatal, the catalogue may hold enough. Then one
             * row with a fresh `sort:random`, exported as the original file.
             */
            "random" => {
                let source = req.p.get("source").and_then(|v| v.as_str()).unwrap_or_default().to_string();
                let filter = req
                    .p
                    .get("q")
                    .and_then(|v| v.as_str())
                    .unwrap_or("kind:wallpaper -nsfw -video")
                    .to_string();
                let sub = |m: &str, p: serde_json::Value| Request { t: "req".into(), id: req.id, m: m.into(), p };

                if !source.is_empty() && req.p.get("crawl").and_then(|v| v.as_bool()).unwrap_or(true) {
                    let pages = req.p.get("pages").and_then(|v| v.as_u64()).unwrap_or(10).max(1);
                    let nanos = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.subsec_nanos() as u64)
                        .unwrap_or(0);
                    let page = 1 + nanos % pages;
                    let crawled = Box::pin(self.handle(sub(
                        "search",
                        serde_json::json!({ "source": source, "q": filter, "page": page }),
                    )))
                    .await;
                    if !crawled.ok {
                        self.log(format_args!("random: crawl of {source} page {page} failed, picking from the catalogue"));
                    }
                }

                let scope = if source.is_empty() { String::new() } else { format!("source:{source} ") };
                let found = Box::pin(self.handle(sub(
                    "find",
                    serde_json::json!({ "q": format!("{scope}{filter} sort:random"), "limit": 1 }),
                )))
                .await;
                let item = found.p.as_ref().and_then(|p| p.get("items")).and_then(|i| i.get(0)).cloned();
                let Some(item) = item else {
                    let from = if source.is_empty() { "the catalogue".to_string() } else { source.clone() };
                    return Response::err(req.id, format!("nothing matching \"{filter}\" from {from} yet"));
                };
                let id = item.get("id").and_then(|v| v.as_str()).unwrap_or_default().to_string();

                let mut export = serde_json::json!({ "id": id, "recipe": { "original": true }, "target": "random" });
                if let Some(path) = req.p.get("path") {
                    export["path"] = path.clone();
                }
                let exported = Box::pin(self.handle(sub("export", export))).await;
                if !exported.ok {
                    return Response::err(req.id, exported.err.unwrap_or_else(|| "export failed".into()));
                }
                let mut answer = exported.p.unwrap_or_else(|| serde_json::json!({}));
                answer["id"] = serde_json::json!(id);
                answer["item"] = item;
                Response::ok(req.id, answer)
            }

            "find" => {
                let params: QueryParams = match serde_json::from_value(req.p.clone()) {
                    Ok(p) => p,
                    Err(e) => return Response::err(req.id, format!("bad find params: {e}")),
                };
                let offset = req.p.get("offset").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
                let limit = req.p.get("limit").and_then(|v| v.as_u64()).unwrap_or(60) as usize;
                let catalog = self.catalog.lock().await;
                let (count, items) = catalog.find(&params, offset, limit.min(MAX_LIMIT));
                let items: Vec<_> = items
                    .into_iter()
                    .map(|mut item| {
                        if let Some(path) = self.cached_thumb_sync(&item.id, 320) {
                            item.thumb_local = path;
                        }
                        item
                    })
                    .collect();
                Response::ok(
                    req.id,
                    serde_json::json!({ "count": count, "offset": offset, "items": items }),
                )
            }

            "items" => {
                let params: ItemsParams = match serde_json::from_value(req.p.clone()) {
                    Ok(p) => p,
                    Err(e) => return Response::err(req.id, format!("bad items params: {e}")),
                };
                let limit = params.limit.min(MAX_LIMIT);
                let catalog = self.catalog.lock().await;
                match catalog.page(params.query_id, params.offset, limit).map(|items| {
                    // Fill in the thumbnails that already exist on disk.
                    items
                        .into_iter()
                        .map(|mut item| {
                            if let Some(path) = self.cached_thumb_sync(&item.id, 320) {
                                item.thumb_local = path;
                            }
                            item
                        })
                        .collect::<Vec<_>>()
                }) {
                    Some(items) => Response::ok(
                        req.id,
                        serde_json::json!({
                            "queryId": params.query_id,
                            "offset": params.offset,
                            "items": items,
                        }),
                    ),
                    // Stale query ids are an error, not silently the new result:
                    // handing back rows from a different query is worse than a
                    // visible failure.
                    None => Response::err(req.id, format!("stale queryId {}", params.query_id)),
                }
            }

            "locate" => {
                let query_id = req.p.get("queryId").and_then(|v| v.as_u64()).unwrap_or(0);
                let id = req.p.get("id").and_then(|v| v.as_str()).unwrap_or_default();
                let catalog = self.catalog.lock().await;
                // -1 rather than an error: "not in this result" is an ordinary
                // answer, and the caller has a fallback for it.
                let at = catalog.locate(query_id, id).map(|n| n as i64).unwrap_or(-1);
                Response::ok(req.id, serde_json::json!({ "queryId": query_id, "id": id, "at": at }))
            }

            "item" => {
                let id = req.p.get("id").and_then(|v| v.as_str()).unwrap_or_default();
                let catalog = self.catalog.lock().await;
                match catalog.by_id(id) {
                    Some(item) => Response::ok(req.id, serde_json::json!({ "item": item })),
                    None => Response::err(req.id, format!("no such item: {id}")),
                }
            }

            // More like this, from what is already indexed. No network, no
            // third party: the perceptual hashes are computed when thumbnails
            // are made, so this is a scan over data the catalogue already holds.
            "similar" => {
                let id = req.p.get("id").and_then(|v| v.as_str()).unwrap_or_default();
                let limit = req.p.get("limit").and_then(|v| v.as_u64()).unwrap_or(60) as usize;
                // 64-bit hash: 0 is identical, <=10 is "the same picture again"
                // (a re-encode, a resize, a crop), and past ~16 it is noise.
                let max_distance =
                    req.p.get("maxDistance").and_then(|v| v.as_u64()).unwrap_or(12) as u32;

                // Measure it now if nobody has. Asking "what is like this" about
                // a picture in front of you should not depend on whether you
                // happened to open it before.
                let wants_web = req.p.get("web").and_then(|v| v.as_bool()).unwrap_or(false);
                /*
                 * THE WAYS TO ASK "WHAT IS LIKE THIS".
                 *
                 *   look    — pictures in the catalogue that look the same
                 *             (perceptual hash, re-encodes and crops)
                 *   dupes   — the same, with the caller's tighter
                 *             `maxDistance`: the same file again, not a
                 *             picture of the same thing
                 *   web     — Yandex's look-alikes from anywhere
                 *   native  — the picture's own site: its "similar" where it
                 *             has one (wallhaven), else its search for the
                 *             picture's most distinctive tags
                 *   sites   — every copy of THIS picture Yandex has seen, on
                 *             whichever page carries it
                 *   bigger  — those copies, larger than yours, biggest first
                 *   all     — catalogue, site and web at once, catalogue first
                 *
                 * `web: true` without a method is the older spelling of `all`.
                 */
                let method = req
                    .p
                    .get("method")
                    .and_then(|v| v.as_str())
                    .unwrap_or(if wants_web { "all" } else { "look" })
                    .to_string();
                let want_local = matches!(method.as_str(), "all" | "look" | "dupes");
                let want_web = matches!(method.as_str(), "all" | "web");
                let want_native = matches!(method.as_str(), "all" | "native");
                // Both read one Yandex page; only the filtering differs.
                let want_copies = matches!(method.as_str(), "sites" | "bigger");
                if !(want_local || want_web || want_native || want_copies) {
                    return Response::err(req.id, format!("unknown similar method: {method}"));
                }
                if want_local {
                    if let Err(e) = self.ensure_hashed(id, true).await {
                        // The web and the site need no hash; only a
                        // catalogue-only question is over without one.
                        if !(want_web || want_native) {
                            return Response::err(req.id, e);
                        }
                    }
                }

                // `records: true` answers with the pictures and stores nothing,
                // so the board can ask without resetting quarry's own result.
                if req.p.get("records").and_then(|v| v.as_bool()).unwrap_or(false) {
                    let catalog = self.catalog.lock().await;
                    return match catalog.similar_records(id, max_distance, limit.min(MAX_LIMIT)) {
                        Ok((items, scanned, hashed)) => Response::ok(
                            req.id,
                            serde_json::json!({ "count": items.len(), "items": items, "scanned": scanned, "hashed": hashed }),
                        ),
                        Err(e) => Response::err(req.id, e),
                    };
                }

                /*
                 * `web: true` also asks Yandex for pictures that look like it,
                 * adds them to the catalogue, and puts them after the
                 * catalogue's own matches. A web failure is reported beside a
                 * result rather than instead of one.
                 */
                // The two network questions run side by side: each is a few
                // seconds, and waiting for one before asking the other doubled
                // the time a click took to answer.
                let (web_answer, native_answer, copies_answer) = tokio::join!(
                    async {
                        if want_web {
                            Some(self.web_similar(id).await)
                        } else {
                            None
                        }
                    },
                    async {
                        if want_native {
                            Some(self.native_similar(id).await)
                        } else {
                            None
                        }
                    },
                    async {
                        if want_copies {
                            Some(self.web_copies(id, method == "bigger").await)
                        } else {
                            None
                        }
                    }
                );
                let (web_ids, web_error) = match web_answer {
                    Some(Ok(ids)) => (ids, String::new()),
                    Some(Err(e)) => (Vec::new(), e),
                    None => (Vec::new(), String::new()),
                };
                let (native_ids, native_how, native_error) = match native_answer {
                    Some(Ok((ids, how))) => (ids, how, String::new()),
                    Some(Err(e)) => (Vec::new(), String::new(), e),
                    None => (Vec::new(), String::new(), String::new()),
                };
                let (copies_ids, copies_error) = match copies_answer {
                    Some(Ok(ids)) => (ids, String::new()),
                    Some(Err(e)) => (Vec::new(), e),
                    None => (Vec::new(), String::new()),
                };
                // Copies of this exact picture first — they ARE it — then the
                // site's own answer, which knows it, then the web's.
                let mut extra = copies_ids.clone();
                for other in native_ids.iter().chain(web_ids.iter()) {
                    if !extra.contains(other) {
                        extra.push(other.clone());
                    }
                }
                if !want_local && extra.is_empty() {
                    let why = [native_error.as_str(), web_error.as_str(), copies_error.as_str()]
                        .into_iter()
                        .filter(|e| !e.is_empty())
                        .collect::<Vec<_>>()
                        .join(" · ");
                    return Response::err(req.id, if why.is_empty() { "nothing alike found".to_string() } else { why });
                }

                let mut catalog = self.catalog.lock().await;
                match catalog.similar_with(id, max_distance, limit, &extra, want_local) {
                    // The same shape a `query` answers with, because it IS one —
                    // the client pages it, sizes it and lays it out with the
                    // code it already has.
                    Ok((result, scanned, hashed)) => Response::ok(
                        req.id,
                        serde_json::json!({
                            "queryId": result.query_id,
                            "count": result.count,
                            "ratios": result.ratios,
                            "sort": result.sort,
                            "duplicates": result.duplicates,
                            "unknown": result.unknown,
                            // So an empty answer can say WHICH empty it is:
                            // nothing alike, or nothing hashed yet.
                            "scanned": scanned,
                            "hashed": hashed,
                            "maxDistance": max_distance,
                            "web": web_ids.len(),
                            "webError": web_error,
                            "native": native_ids.len(),
                            "nativeHow": native_how,
                            "nativeError": native_error,
                            "copies": copies_ids.len(),
                            "copiesError": copies_error,
                            "method": method,
                        }),
                    ),
                    Err(e) => Response::err(req.id, e),
                }
            }

            /*
             * A THUMBNAIL FOR A FILE ON DISK.
             *
             * `thumb` is catalogue-shaped: it takes an item id and knows where
             * to fetch from. The desktop shell mostly has a path — a wallpaper
             * folder — and was spawning a Python virtualenv and ImageMagick to
             * resize it. Same ladder, same cache, same encoder, no network and
             * no catalogue lookup.
             *
             * The cache key is the absolute path, so two files with the same
             * basename in different folders do not collide.
             */
            "thumb_path" => {
                let path = req.p.get("path").and_then(|v| v.as_str()).unwrap_or_default();
                let size = req.p.get("size").and_then(|v| v.as_u64()).unwrap_or(320) as u32;
                if path.is_empty() {
                    return Response::err(req.id, "thumb_path needs a path".to_string());
                }
                let src = util::expand_tilde(path);
                let meta = match tokio::fs::metadata(&src).await {
                    Ok(m) => m,
                    Err(e) => return Response::err(req.id, format!("{path}: {e}")),
                };
                // The mtime is in the key: a wallpaper edited in place must not
                // keep serving the thumbnail of what it used to be.
                let stamp = meta
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs())
                    .unwrap_or(0);
                /*
                 * WRITE WHERE THE DESKTOP LOOKS.
                 *
                 * `spec: "freedesktop"` files the thumbnail by the standard's
                 * own rule — MD5 of the file URI, under a size-named directory,
                 * as PNG — instead of in quarry's private cache. The shell's
                 * ThumbnailImage computes exactly that path and would never
                 * have found a private one, and neither would a file manager.
                 *
                 * Without the flag it stays in quarry's cache, keyed on path
                 * and mtime so an edited file does not keep serving the old
                 * picture. The spec has no mtime in its name, so that guard is
                 * the caller's there — which is what the standard intends.
                 */
                let fdo = req.p.get("spec").and_then(|v| v.as_str()) == Some("freedesktop");
                // The quarry-cache key. Not yet a full path: the extension
                // depends on the decoded image (alpha vs not), which is not
                // known until it is loaded below.
                let key = format!("{src}-{stamp}");
                if fdo {
                    let cache = util::freedesktop_thumb_path(&src, size);
                    if tokio::fs::metadata(&cache).await.is_ok() {
                        return Response::ok(req.id, serde_json::json!({ "path": cache, "cached": true }));
                    }
                } else if let Some(cache) = self.cached_thumb(&key, size).await {
                    return Response::ok(req.id, serde_json::json!({ "path": cache, "cached": true }));
                }
                let bytes = match tokio::fs::read(&src).await {
                    Ok(b) => b,
                    Err(e) => return Response::err(req.id, format!("read {path}: {e}")),
                };
                let decoded = match image::load(&bytes, (size, size)) {
                    Ok(d) => d,
                    Err(e) => return Response::err(req.id, format!("decode {path}: {e}")),
                };
                // The spec says PNG, and every reader of that directory expects
                // one; quarry's own cache picks JPEG or PNG per-image — see
                // image::thumb_format — so alpha (icons, rasterised vectors)
                // survives and photographs don't pay a lossless tax.
                let (cache, encoded) = if fdo {
                    let render = size.min(decoded.width().max(decoded.height())).max(1);
                    let scaled = decoded.resize(render, render, ::image::imageops::FilterType::Lanczos3);
                    match image::encode(&scaled, image::Format::Png, 92) {
                        Ok(b) => (util::freedesktop_thumb_path(&src, size), b),
                        Err(e) => return Response::err(req.id, format!("encode: {e}")),
                    }
                } else {
                    match image::thumb_ladder(&decoded, &[size], image::THUMB_QUALITY) {
                        Ok(mut l) => {
                            let (_, bytes, format) = l.remove(0);
                            (self.thumb_path(&key, size, image::extension(format)), bytes)
                        }
                        Err(e) => return Response::err(req.id, format!("encode: {e}")),
                    }
                };
                if let Err(e) = util::write_atomic(&cache, &encoded).await {
                    return Response::err(req.id, format!("write: {e}"));
                }
                Response::ok(
                    req.id,
                    serde_json::json!({
                        "path": cache,
                        "cached": false,
                        "spec": if fdo { "freedesktop" } else { "quarry" },
                        "w": decoded.width(),
                        "h": decoded.height(),
                        "phash": format!("{:016x}", image::phash(&decoded)),
                        "dominant": util::to_hex(image::dominant_color(&decoded)),
                    }),
                )
            }

            /*
             * BACKFILL THE PERCEPTUAL HASHES.
             *
             * A hash is a by-product of making a thumbnail, so a catalogue that
             * has been crawled but not browsed has almost none — and dedupe and
             * "more like this" can only ever see what has been hashed. This
             * closes that gap without waiting for someone to scroll past every
             * row.
             *
             * TWO TIERS, AND THE FIRST IS FREE. A cache hit in `thumb` returns
             * early without decoding, so there are rows with a thumbnail
             * already on disk and no hash. Those cost a decode and nothing
             * else. Only what is left needs the network, and it fetches the
             * SMALL preview: a perceptual hash is stable under rescaling and
             * re-encoding (see the test in image.rs, hamming <= 4), so the
             * preview answers the same question as the original for a fraction
             * of the bytes.
             *
             * Bounded per call rather than a background sweep: the client asks
             * for another batch when it wants one, which makes it cancellable
             * by simply not asking, and keeps progress honest.
             */
            "backfill" => {
                let limit = req.p.get("limit").and_then(|v| v.as_u64()).unwrap_or(200) as usize;
                let use_network = req.p.get("network").and_then(|v| v.as_bool()).unwrap_or(true);
                Response::ok(req.id, self.backfill_once(limit, use_network).await)
            }

            /*
             * WHERE ELSE DOES THIS PICTURE EXIST.
             *
             * Deliberately NOT a `Source`. That trait answers a text query and
             * `SourceQuery` has nowhere to put a picture, so fitting reverse
             * search into it would mean redesigning the trait every existing
             * source implements — a large change to make one feature reachable.
             * These providers are plain functions, so this calls them directly
             * and the trait question stays open until something else needs it.
             *
             * The image is sent by URL rather than uploaded: a catalogue row is
             * already hosted somewhere, and both services accept a `url`
             * parameter, which avoids a multipart dependency entirely.
             */
            "reverse" => {
                let id = req.p.get("id").and_then(|v| v.as_str()).unwrap_or_default();
                let provider = req.p.get("provider").and_then(|v| v.as_str()).unwrap_or("saucenao");

                let image_url = {
                    let catalog = self.catalog.lock().await;
                    match catalog.by_id(id) {
                        Some(item) => {
                            // The original, not the thumbnail: these match on
                            // image content, and a 240px preview is a worse
                            // question than the picture itself.
                            if item.url.is_empty() { item.thumb.clone() } else { item.url.clone() }
                        }
                        None => return Response::err(req.id, format!("no such item: {id}")),
                    }
                };
                if image_url.is_empty() {
                    return Response::err(req.id, "that row has no image to search with".to_string());
                }

                match provider {
                    "saucenao" => {
                        let key = match sources::saucenao::api_key() {
                            Ok(k) => k,
                            // Says which missing thing it is, and how to supply
                            // it — an empty result would look like "no matches".
                            Err(e) => return Response::err(req.id, e),
                        };
                        let url = sources::saucenao::build_url(&image_url, &key);
                        let body = match self.http.fetch_text(&url).await {
                            Ok(b) => b,
                            Err(e) => return Response::err(req.id, format!("saucenao: {e}")),
                        };
                        match sources::saucenao::parse(&body) {
                            Ok(r) => Response::ok(
                                req.id,
                                serde_json::json!({
                                    "provider": "saucenao",
                                    "searched": image_url,
                                    "matches": r.matches.iter().map(|m| serde_json::json!({
                                        "similarity": m.similarity,
                                        "title": m.title,
                                        "index": m.index_name,
                                        "thumbnail": m.thumbnail,
                                        "urls": m.urls,
                                    })).collect::<Vec<_>>(),
                                    // The quota is part of the answer: a zero
                                    // here is "used up", not "nothing alike".
                                    "shortRemaining": r.short_remaining,
                                    "longRemaining": r.long_remaining,
                                }),
                            ),
                            Err(e) => Response::err(req.id, format!("saucenao: {e}")),
                        }
                    }
                    /*
                     * Yandex — the one that knows about photographs.
                     *
                     * Two requests: the handle first (a URL if the picture is
                     * on the open web, the picture itself uploaded if it is
                     * not — see `yandex_handle`), then the cbir page, which is
                     * the one that actually carries an answer.
                     *
                     * `page` picks which question: `similar` is look-alikes,
                     * `sites` is every page this exact picture is on.
                     */
                    "yandex" => {
                        let item = {
                            let catalog = self.catalog.lock().await;
                            match catalog.by_id(id) {
                                Some(item) => item.clone(),
                                None => return Response::err(req.id, format!("no such item: {id}")),
                            }
                        };
                        let (searched, cbir) = match self.yandex_handle(&item).await {
                            Ok(pair) => pair,
                            Err(e) => return Response::err(req.id, e),
                        };
                        let page = match req.p.get("page").and_then(|v| v.as_str()) {
                            Some("sites") => "sites",
                            _ => "similar",
                        };
                        let body = match self
                            .http
                            .fetch_text(&sources::yandex::Yandex::page_url(&searched, &cbir, page, crate::prefs::Prefs::load().show_adult))
                            .await
                        {
                            Ok(b) => b,
                            Err(e) => return Response::err(req.id, format!("yandex: {e}")),
                        };
                        let parsed = if page == "sites" {
                            sources::yandex::Yandex::sites(&body)
                        } else {
                            sources::yandex::Yandex::reverse_matches(&body)
                        };
                        match parsed {
                            Ok(matches) => Response::ok(
                                req.id,
                                serde_json::json!({
                                    "provider": "yandex",
                                    "page": page,
                                    "searched": searched,
                                    "matches": matches,
                                }),
                            ),
                            Err(e) => Response::err(req.id, e),
                        }
                    }

                    "iqdb" => {
                        // "3d" for the separate photo/3D-art index; anything
                        // else (including absent) is the anime/booru index —
                        // the default a bare provider="iqdb" should mean.
                        let service = match req.p.get("service").and_then(|v| v.as_str()) {
                            Some("3d") => sources::iqdb::Service::ThreeD,
                            _ => sources::iqdb::Service::All,
                        };
                        let (endpoint, fields) =
                            sources::iqdb::build_request(&image_url, service);
                        let form: Vec<(&str, &str)> =
                            fields.iter().map(|f| (f.name, f.value.as_str())).collect();
                        let body = match self.http.post_form(endpoint, &form).await {
                            Ok(b) => b,
                            Err(e) => return Response::err(req.id, format!("iqdb: {e}")),
                        };
                        match sources::iqdb::parse(&body) {
                            Ok(sources::iqdb::SearchResult::Matches(matches)) => Response::ok(
                                req.id,
                                serde_json::json!({
                                    "provider": "iqdb",
                                    "searched": image_url,
                                    "matches": matches.iter().map(|m| serde_json::json!({
                                        // The tier iqdb itself labels, lowercased.
                                        // Rendered from the enum's own Debug so
                                        // this arm does not have to be edited
                                        // every time the parser learns something
                                        // new about the page's real structure.
                                        "category": format!("{:?}", m.category).to_lowercase(),
                                        "sourceUrl": m.source_url,
                                        "thumbnail": m.thumbnail,
                                        "host": m.host,
                                        "width": m.width,
                                        "height": m.height,
                                        "rating": m.rating,
                                        "similarity": m.similarity,
                                    })).collect::<Vec<_>>(),
                                }),
                            ),
                            // iqdb's own "no matches" notice is a real answer,
                            // not a failure — kept apart from an empty
                            // `matches` for an unrelated reason (see
                            // `sources::iqdb::SearchResult`), so the reason is
                            // carried through rather than collapsed away.
                            Ok(sources::iqdb::SearchResult::NoMatches(reason)) => Response::ok(
                                req.id,
                                serde_json::json!({
                                    "provider": "iqdb",
                                    "searched": image_url,
                                    "matches": Vec::<serde_json::Value>::new(),
                                    "noMatchReason": reason,
                                }),
                            ),
                            Err(e) => Response::err(req.id, format!("iqdb: {e}")),
                        }
                    }
                    other => Response::err(req.id, format!("unknown provider: {other}")),
                }
            }

            "complete" => {
                let prefix = req.p.get("prefix").and_then(|v| v.as_str()).unwrap_or_default();
                let catalog = self.catalog.lock().await;
                let suggestions =
                    crate::query::complete(prefix, &|key: &str| catalog.values_of(key));
                Response::ok(
                    req.id,
                    serde_json::json!({ "prefix": prefix, "suggestions": suggestions }),
                )
            }

            /*
             * Live search with the query pushed down.
             *
             * This is where the filter work pays: asking wallhaven for
             * `atleast=3440x1440&ratios=21x9` returns a page of usable
             * ultrawides, where asking for everything and filtering 24 rows
             * locally returns two. Whatever the source cannot express is
             * applied here afterwards, with the same matcher the local
             * catalogue uses.
             */
            "search" => {
                let source_id = req.p.get("source").and_then(|v| v.as_str()).unwrap_or("wallhaven");
                let text = req.p.get("q").and_then(|v| v.as_str()).unwrap_or_default();
                let page = req.p.get("page").and_then(|v| v.as_u64()).unwrap_or(1) as u32;

                if !source_allowed(source_id, crate::prefs::Prefs::load().show_adult) {
                    return Response::err(
                        req.id,
                        format!("{source_id} is an adult source and adult content is switched off"),
                    );
                }
                let Some(source) = sources::by_id(source_id) else {
                    return Response::err(req.id, format!("unknown source: {source_id}"));
                };

                let parsed = crate::query::parse(text);
                // A site with no search of its own answers typed words with its
                // front page; that is not an answer, so it is not asked.
                if let Some(reason) = source
                    .unavailable()
                    .or_else(|| sources::text_search::skip_source(&parsed, source.as_ref()))
                {
                    self.log(format_args!("search {source_id}: {reason}"));
                    return Response::ok(
                        req.id,
                        serde_json::json!({
                            "source": source_id, "url": "", "fetched": 0, "added": 0, "duplicate": 0,
                            "filteredLocally": 0, "unusable": 0, "hasMore": false, "skipped": reason,
                        }),
                    );
                }
                let (mut pushed, residue) = sources::pushdown(&parsed, &source.capabilities());
                dont_fetch_adult(&mut pushed, crate::prefs::Prefs::load().show_adult);
                pushed.page = page;
                let url = source.build_url(&pushed);
                let document = source.body(&pushed);

                let searched = !pushed.text.is_empty()
                    || !pushed.tags.is_empty()
                    || !pushed.author.is_empty();
                let body = match fetch_page(&self.http, &url, document.as_ref()).await {
                    Ok(body) => body,
                    Err(e) if empty_listing(&e, searched) => String::new(),
                    Err(e) => {
                        // The site refused or never answered. Recorded before
                        // the error is returned, because the client shows this
                        // as an empty wall and nothing else.
                        let status = match &e {
                            scrape::ScrapeError::Status(code, _) => *code,
                            _ => 0,
                        };
                        self.record_health(source_id, false, status, &e.to_string(), 0).await;
                        return Response::err(req.id, format!("{source_id}: {e}"));
                    }
                };

                let rows = match source.parse(&body) {
                    Ok(rows) => rows,
                    Err(e) => {
                        // It answered, and the answer was not what this
                        // adapter expects — a site that changed its shape.
                        // Worth telling apart from a refusal, so the detail
                        // says which it was.
                        self.record_health(source_id, false, 200, &format!("unreadable: {e}"), 0)
                            .await;
                        return Response::err(req.id, format!("{source_id}: {e}"));
                    }
                };
                self.record_health(source_id, true, 200, "", rows.len()).await;

                let fetched = rows.len();
                let kept: Vec<_> =
                    rows.into_iter().filter(|item| crate::query::matches(item, &residue)).collect();
                let filtered_out = fetched - kept.len();
                let (mut usable, unusable) = scrape::keep_usable(scrape::dedupe(kept));
                mark_adult(&mut usable, source_id);
                // What found them is the only description some sources give.
                scrape::tag_with_terms(&mut usable, &pushed.text);
                scrape::tag_with_terms(&mut usable, &pushed.tags);

                let more = source.has_more_after(&body, fetched);
                // The rows themselves, in the site's own order — a caller
                // showing this page (a lens) wants what the site answered, not
                // a catalogue query that would mix in everything older.
                let mut page_items = usable.clone();
                let (added, duplicate, changed) = {
                    let mut catalog = self.catalog.lock().await;
                    let before = catalog.changes();
                    let (added, duplicate) = catalog.add(usable);
                    (added, duplicate, catalog.changes() > before)
                };
                if changed {
                    self.emit("catalog.changed", serde_json::json!({ "added": added, "source": source_id }));
                }

                /*
                 * …BUT NOT THE ROWS THE CATALOGUE JUST REFUSED.
                 *
                 * A row marked broken — a fetch that failed once, long ago — is
                 * dropped by `add` and never stored, and then every later
                 * question about it is answered "no such item": no thumbnail,
                 * no qualities, no stream. The client was still being handed
                 * those rows, so a page of thirty arrived with nine cards that
                 * could never fill in, for ever. Measured on this machine:
                 * eleven of twenty thumbnails answered, nine were these.
                 *
                 * They are dropped from the answer instead. A page with fewer
                 * rows is honest; a page with holes in it is not.
                 */
                {
                    let catalog = self.catalog.lock().await;
                    let before = page_items.len();
                    page_items.retain(|item| !catalog.is_broken(&item.id));
                    let dropped = before - page_items.len();
                    if dropped > 0 {
                        self.log(format_args!(
                            "search {source_id} page {page} -> {dropped} rows the catalogue has blacklisted were left out"
                        ));
                    }
                }

                self.log(format_args!(
                    "search {source_id} page {page} -> {fetched} fetched, {added} added ({filtered_out} filtered locally, {duplicate} known, {unusable} unusable)"
                ));

                Response::ok(
                    req.id,
                    serde_json::json!({
                        "source": source_id,
                        "url": url,
                        "fetched": fetched,
                        "added": added,
                        "duplicate": duplicate,
                        "filteredLocally": filtered_out,
                        "unusable": unusable,
                        "hasMore": more,
                        "items": page_items,
                    }),
                )
            }

            /*
             * Enrich one row from its own page.
             *
             * A listing gives an image and an id; the item's page gives the
             * title, the uploader, the tags it was filed under and the site's
             * own "more like this" strip. That is worth one request when you
             * open something, and forty wasted ones during a crawl — so it
             * happens here, on demand.
             */
            "enrich" => {
                let id = req.p.get("id").and_then(|v| v.as_str()).unwrap_or_default();

                let item = {
                    let catalog = self.catalog.lock().await;
                    match catalog.by_id(id) {
                        Some(item) => item.clone(),
                        None => return Response::err(req.id, format!("no such item: {id}")),
                    }
                };

                if item.source != "pfps.gg" || item.page_url.is_empty() {
                    // Nothing to add: the row already carries everything its
                    // source publishes.
                    return Response::ok(req.id, serde_json::json!({ "item": item, "enriched": false }));
                }

                let body = match self.http.fetch_text(&item.page_url).await {
                    Ok(body) => body,
                    Err(e) => return Response::err(req.id, format!("fetch: {e}")),
                };

                let detail = sources::pfps_gg::PfpsGg::parse_detail(&body);
                let mut enriched = item.clone();
                if !detail.title.is_empty() {
                    enriched.title = detail.title;
                }
                if !detail.author.is_empty() {
                    enriched.author = detail.author;
                }
                if !detail.tags.is_empty() {
                    enriched.tags = detail.tags;
                }

                self.catalog.lock().await.replace(enriched.clone());

                Response::ok(
                    req.id,
                    serde_json::json!({
                        "item": enriched,
                        "enriched": true,
                        "related": detail.related,
                    }),
                )
            }

            /*
             * Endless scroll: fetch the next page for this query, from every
             * source that still has one.
             *
             * The client does not track pages; the daemon does, keyed by the
             * query text. Scrolling to the bottom of a wall should keep going
             * the way a browser userscript keeps appending pages, and that only
             * works if "next" is a fact the daemon owns rather than a number the
             * UI has to guess.
             *
             * Sources are crawled in parallel here — this is one round trip for
             * the client no matter how many sources answer it.
             */
            "more" => {
                let text = req.p.get("q").and_then(|v| v.as_str()).unwrap_or_default().to_string();
                /*
                 * Several pages per call, not one.
                 *
                 * A source hands back 24–50 rows a page, and after filtering
                 * locally a page can add a handful — so fetching one page per
                 * scroll means the wall grows a screen at a time and asks
                 * again immediately. Pages are independent URLs, so they are
                 * fetched together: the cost of four pages is the cost of the
                 * slowest one, not the sum.
                 *
                 * The per-host crawl delay still applies, which is what keeps
                 * this polite rather than a stampede.
                 */
                let pages = req
                    .p
                    .get("pages")
                    .and_then(|v| v.as_u64())
                    .unwrap_or(3)
                    .clamp(1, 50) as u32;

                /*
                 * WHICH SOURCES, AND IN WHAT ORDER — THE USER'S CHOICE.
                 *
                 * A caller naming sources explicitly still gets exactly those:
                 * "search these three" is an instruction, not a suggestion. But
                 * a crawl that did not name any used to mean *every* source,
                 * which at twenty-four of them is how a wallpaper search ends
                 * up a quarter furry booru. Preferences decide that set now,
                 * and their weights decide who is asked first.
                 */
                let prefs = crate::prefs::Prefs::load();
                let names: Vec<String> = match req.p.get("sources").and_then(|v| v.as_array()) {
                    Some(list) => {
                        list.iter().filter_map(|v| v.as_str().map(String::from)).collect()
                    }
                    None => {
                        let all = sources::all();
                        prefs.order(all.iter().map(|s| s.id()))
                    }
                };
                // Applied to the NAMED list as well as the default one: a client
                // asking for an adult source by name is still asking for
                // something the person switched off.
                let names: Vec<String> =
                    names.into_iter().filter(|id| source_allowed(id, prefs.show_adult)).collect();

                let parsed = crate::query::parse(&text);
                // Cursors are keyed on the query as MEANT, not as typed: a
                // trailing space from a completion, or a capital letter, must
                // not restart every site at page one.
                let normalized = text.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase();
                /*
                 * THE HOME FEED IS EVERY SITE'S FRONT PAGE, PAGED FOREVER.
                 *
                 * With nothing typed there is nothing to rank by relevance, and
                 * asking a site for "relevance" with no words is how wallhaven
                 * answered an empty page and was marked finished on the first
                 * scroll. With no words, a site is asked for its newest, the
                 * way its own front page lists them.
                 *
                 * And finished is not forever there: sites keep posting, so a
                 * front page that ran out starts again from page one a few
                 * minutes later. Known rows are skipped on insert, so only what
                 * is new comes in.
                 */
                // Home is "nothing selective was asked for". `author:x` is
                // selective and was not counted, so an author query crawled
                // every front page and filtered all of it away as "endless".
                let home = !sources::text_search::has_words(&parsed);
                const HOME_RESTART: std::time::Duration = std::time::Duration::from_secs(300);

                let mut plans = Vec::new();
                // (source, cursor key) for everything asked this round, so the
                // round can write back where each one got to.
                let mut touched: Vec<(String, String)> = Vec::new();
                // Sources that cannot express this query, with the reason —
                // reported rather than silently dropped, so "nothing came back"
                // can be told apart from "nobody was asked".
                let mut skipped: Vec<serde_json::Value> = Vec::new();
                for name in names {
                    let Some(source) = sources::by_id(&name) else { continue };
                    if let Some(why) = source
                        .unavailable()
                        .or_else(|| sources::text_search::skip_source(&parsed, source.as_ref()))
                    {
                        skipped.push(serde_json::json!({ "source": name, "why": why }));
                        continue;
                    }

                    let key = format!("{name}\u{1}{normalized}");
                    /*
                     * Pages are spent where they bring something back.
                     *
                     * Never fewer than one: a quiet source is still asked, so
                     * it can recover the moment it starts posting again — this
                     * decides how deep to go, never whether to go.
                     */
                    let budget = pages_budget(self.yields.lock().await.get(&key).copied(), pages);
                    let from = {
                        let mut cursors = self.cursors.lock().await;
                        let entry = cursors.entry(key.clone()).or_insert(0);
                        if *entry == u32::MAX {
                            let rested = self
                                .exhausted_at
                                .lock()
                                .await
                                .get(&key)
                                .is_none_or(|at| at.elapsed() >= HOME_RESTART);
                            if !(home && rested) {
                                continue;      // this source is done for this query
                            }
                            *entry = 0;        // a front page, rested: start over
                        }
                        let from = *entry + 1;
                        /*
                         * ENDLESS MEANS ENDLESS.
                         *
                         * The per-source `pages` preference used to cap this
                         * too, and it was wrong twice over: the cursor advanced
                         * by the capped budget while the loop below still
                         * fetched the full page count, so a source set to two
                         * pages skipped pages it never downloaded — and a cap on
                         * the endless scroll is a scroll that ends. The
                         * preference is how deep an explicit SEARCH goes (see
                         * `search`); scrolling keeps going for as long as any
                         * source has pages.
                         */
                        *entry += budget;
                        from
                    };

                    touched.push((name.clone(), key.clone()));
                    plans.push((name, source, from, budget, key));
                }
                let sources_asked = plans.len();
                // Copied out because the plans are built on blocking threads and
                // `prefs` does not travel with them.
                let show_adult = prefs.show_adult;

                /*
                 * URLS ARE BUILT SIDE BY SIDE, OFF THE ASYNC THREADS.
                 *
                 * Building a URL can mean a network lookup now: a tag board
                 * turns typed words into its real tags through its own
                 * autocomplete (see sources/tag_resolve.rs), which blocks. One
                 * source after another, a new query waited for every board's
                 * lookup in turn before a single page was asked for.
                 */
                /*
                 * EACH SOURCE FETCHES AS SOON AS ITS OWN URLS ARE BUILT.
                 *
                 * Every source's URLs used to be built first and only then was
                 * any page asked for, so one board's slow tag lookup held up
                 * every other site: measured, the first rows of every search
                 * landed at 15.5 s and nothing at all before. Now a source's
                 * pages go out the moment its URLs exist, and finished pages
                 * come back over one channel in the order they finish.
                 *
                 * EACH PAGE IS FILED THE MOMENT IT ARRIVES — not in one insert
                 * at the end, which waited for the slowest host and once ran
                 * past the app's deadline (3,643 rows fetched, 14 on screen).
                 * A page that takes longer than twenty seconds is given back
                 * and asked again next round: one slow host must not hold
                 * every other site's answer.
                 */
                let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
                for (name, source, from, budget, key) in plans {
                    let parsed = parsed.clone();
                    let http = Arc::clone(&self.http);
                    let tx = tx.clone();
                    tokio::spawn(async move {
                        let jobs = tokio::task::spawn_blocking(move || {
                            let (mut pushed, residue) = sources::pushdown(&parsed, &source.capabilities());
                            dont_fetch_adult(&mut pushed, show_adult);
                            if home && pushed.text.is_empty() && pushed.tags.is_empty() && parsed.sort == crate::query::Sort::Relevance {
                                pushed.sort = crate::query::Sort::Newest;
                            }
                            // Whether anything was actually searched for, so a
                            // 404 can be read as "no rows" rather than "broken".
                            let searched = !pushed.text.is_empty()
                                || !pushed.tags.is_empty()
                                || !pushed.author.is_empty();
                            (from..from + budget)
                                .map(|page| {
                                    let mut per_page = pushed.clone();
                                    per_page.page = page;
                                    (source.build_url(&per_page), source.body(&per_page), residue.clone(), searched)
                                })
                                .collect::<Vec<_>>()
                        })
                        .await
                        .unwrap_or_default();
                        for (url, document, residue, searched) in jobs {
                            let http = Arc::clone(&http);
                            let tx = tx.clone();
                            let (name, key) = (name.clone(), key.clone());
                            tokio::spawn(async move {
                                let body = match tokio::time::timeout(
                                    std::time::Duration::from_secs(20),
                                    fetch_page(&http, &url, document.as_ref()),
                                )
                                .await
                                {
                                    Ok(Ok(body)) => Ok(body),
                                    // An empty search reads as an empty page, which
                                    // `parse` already answers with zero rows.
                                    Ok(Err(e)) if empty_listing(&e, searched) => Ok(String::new()),
                                    Ok(Err(e)) => Err(e.to_string()),
                                    Err(_) => Err("timed out".to_string()),
                                };
                                let _ = tx.send((name, body, residue, key));
                            });
                        }
                    });
                }
                drop(tx);

                let mut added_total = 0usize;
                let mut pages_read = 0usize;
                let mut fetched_total = 0usize;
                let mut duplicate = 0usize;
                let mut unusable = 0usize;
                // (new rows, pages) per cursor key, for the yield average.
                let mut harvest_of: std::collections::HashMap<String, (usize, usize)> = std::collections::HashMap::new();
                let mut exhausted: Vec<String> = Vec::new();
                // A page that did not arrive is not a source with no more
                // pages. Reported apart, so a moment of bad network cannot tell
                // the app that the whole scroll is over.
                let mut failed: Vec<String> = Vec::new();

                while let Some((name, body, residue, key)) = rx.recv().await {
                    let Ok(body) = body else {
                        if !failed.contains(&name) {
                            failed.push(name.clone());
                        }
                        // Give the page back: the next call asks for it again.
                        let mut cursors = self.cursors.lock().await;
                        if let Some(entry) = cursors.get_mut(&key) {
                            if *entry != u32::MAX && *entry > 0 {
                                *entry -= 1;
                            }
                        }
                        continue;
                    };
                    let Some(source) = sources::by_id(&name) else { continue };
                    let Ok(rows) = source.parse(&body) else {
                        if !failed.contains(&name) {
                            failed.push(name);
                        }
                        continue;
                    };

                    pages_read += 1;
                    let fetched = rows.len();
                    fetched_total += fetched;
                    let kept: Vec<_> =
                        rows.into_iter().filter(|item| crate::query::matches(item, &residue)).collect();
                    // Known rows are skipped by `add`, so pages that overlap
                    // across a round cost a lookup, not a duplicate.
                    let (mut usable, dropped) = scrape::keep_usable(scrape::dedupe(kept));
                    mark_adult(&mut usable, &name);
                    // The words that fetched them, kept — see tag_with_terms. The
                    // whole query text, because a `more` spans several sources
                    // and they do not all split it the same way.
                    scrape::tag_with_terms(&mut usable, &[text.clone()]);
                    let (added, known, changed) = {
                        let mut catalog = self.catalog.lock().await;
                        let before = catalog.changes();
                        let (added, known) = catalog.add(usable);
                        (added, known, catalog.changes() > before)
                    };
                    // Said per page, not per round: the wall grows as each site
                    // answers instead of when the slowest one does. A page of
                    // known rows says it too — they may have learned the words.
                    if changed {
                        self.emit("catalog.changed", serde_json::json!({ "added": added, "source": name }));
                    }
                    added_total += added;
                    duplicate += known;
                    unusable += dropped;
                    let tally = harvest_of.entry(key.clone()).or_insert((0, 0));
                    tally.0 += added;
                    tally.1 += 1;

                    if !source.has_more_after(&body, fetched) {
                        if !exhausted.contains(&name) {
                            exhausted.push(name.clone());
                        }
                        self.exhausted_at.lock().await.insert(key.clone(), std::time::Instant::now());
                        self.cursors.lock().await.insert(key, u32::MAX);
                    }
                }

                /*
                 * WRITTEN BACK ONCE, NOT PER PAGE.
                 *
                 * Thirty sources a round is thirty rows; one statement each
                 * would be thirty commits, so the whole round goes in one
                 * transaction after the pages have landed.
                 */
                {
                    // The rolling average that decides next round's depth:
                    // half what this round found, half what came before.
                    let mut yields = self.yields.lock().await;
                    for (key, (added, pages_read)) in &harvest_of {
                        if *pages_read == 0 {
                            continue;
                        }
                        let fresh = *added as f32 / *pages_read as f32;
                        let blended = yields.get(key).map(|old| old * 0.5 + fresh * 0.5).unwrap_or(fresh);
                        yields.insert(key.clone(), blended);
                    }
                    drop(yields);

                    let cursors = self.cursors.lock().await;
                    let finished = self.exhausted_at.lock().await;
                    let now = std::time::Instant::now();
                    let epoch_now = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_secs() as i64)
                        .unwrap_or(0);
                    let rows: Vec<(String, String, u32, i64)> = touched
                        .iter()
                        .filter_map(|(name, key)| {
                            let page = *cursors.get(key)?;
                            let finished_at = finished
                                .get(key)
                                .map(|at| epoch_now - now.duration_since(*at).as_secs() as i64)
                                .unwrap_or(0);
                            Some((name.clone(), normalized.clone(), page, finished_at))
                        })
                        .collect();
                    drop(finished);
                    drop(cursors);
                    self.catalog.lock().await.remember_cursors(&rows);
                }

                // Measure a few of the rows just added, over the network.
                // Collapsing copies needs hashes, and the idle sweep only uses
                // thumbnails already on disk — so a fresh crawl's duplicates
                // stayed visible until something happened to look at them.
                if added_total > 0 {
                    let hasher: Arc<Server> = Arc::clone(self);
                    tokio::spawn(async move {
                        hasher.backfill_once(40, true).await;
                    });
                }

                self.log(format_args!(
                    "more q={text:?} x{pages} pages -> {fetched_total} fetched, {added_total} added ({duplicate} known, {unusable} unusable), exhausted {exhausted:?}"
                ));

                Response::ok(
                    req.id,
                    serde_json::json!({
                        "added": added_total,
                        "fetched": fetched_total,
                        "duplicate": duplicate,
                        // Pages that actually came back. This echoed the
                        // REQUESTED count, so the app's page tally was the
                        // number it had just sent and never a measurement.
                        "pages": pages_read,
                        "asked": pages,
                        // How many sources this round covered, so a caller can
                        // tell "most of them ran dry" from "three did" without
                        // hardcoding a source count that went stale at 3.
                        "sources": sources_asked,
                        "exhausted": exhausted,
                        "failed": failed,
                        "skipped": skipped,
                        // A home feed never ends: finished sites start over.
                        "endless": home,
                    }),
                )
            }

            /*
             * Is every source still answering, and still parseable? A broken
             * adapter must be named here rather than showing as an empty
             * gallery.
             */
            "doctor" => {
                let mut report = Vec::new();
                for source in sources::all() {
                    // Newest, not relevance: an empty relevance search returns
                    // nothing on wallhaven, which would report a working source
                    // as broken — the exact failure mode doctor exists to
                    // prevent, pointed the wrong way.
                    let browse = sources::SourceQuery {
                        page: 1,
                        sort: crate::query::Sort::Newest,
                        ..Default::default()
                    };
                    let url = source.build_url(&browse);
                    let document = source.body(&browse);

                    // A POST source cannot be probed with a GET: AniList
                    // answers one with a 404, and doctor would report a healthy
                    // adapter as broken — its own failure mode, pointed the
                    // wrong way. Its one request doubles as the probe.
                    let (status, detail, fetched) = if document.is_some() {
                        match fetch_page(&self.http, &url, document.as_ref()).await {
                            Ok(body) => (200, format!("200, {} bytes", body.len()), Some(body)),
                            Err(scrape::ScrapeError::Status(code, _)) => {
                                (code, format!("{code}"), None)
                            }
                            Err(e) => (0, e.to_string(), None),
                        }
                    } else {
                        let (status, detail) = self.http.probe(&url).await;
                        (status, detail, None)
                    };

                    let parsed = match fetched {
                        Some(body) => source.parse(&body).map(|r| r.len()).unwrap_or(0),
                        None if status == 200 => match self.http.fetch_text(&url).await {
                            Ok(body) => source.parse(&body).map(|r| r.len()).unwrap_or(0),
                            Err(_) => 0,
                        },
                        None => 0,
                    };
                    /*
                     * A probe is a fetch like any other, so it lands in the
                     * same record and the same log. One place to look for
                     * "when did this site stop working", whether the answer
                     * came from browsing or from pressing the button.
                     */
                    /*
                     * A SOURCE THAT CANNOT BE PROBED IS NOT A BROKEN SOURCE.
                     *
                     * `local` reads a folder on this machine, so the probe
                     * builds `file://local/?page=1`, which is not a URL and
                     * cannot answer — and the first run of this validator
                     * duly reported the user's own pictures as a failing
                     * site. Anything that is not http is left alone here; its
                     * real fetches still record normally.
                     */
                    if url.starts_with("http") {
                        self.record_health(
                            source.id(),
                            status == 200 && parsed > 0,
                            status,
                            if status == 200 && parsed == 0 {
                                "answered with nothing usable"
                            } else {
                                &detail
                            },
                            parsed,
                        )
                        .await;
                    }
                    report.push(serde_json::json!({
                        "source": source.id(),
                        // The URL is in the report because "danbooru: 500" is
                        // not actionable and "danbooru: 500 for <url>" is.
                        "url": url,
                        "status": status,
                        "detail": detail,
                        "parsed": parsed,
                        "ok": status == 200 && parsed > 0,
                    }));
                }
                Response::ok(req.id, serde_json::json!({ "sources": report }))
            }

            /*
             * Cache an item's thumbnail locally and answer with the path.
             *
             * This is also the fix for the sources that refuse hotlinked
             * images: cdn.donmai.us and the Art Institute's IIIF host both
             * answer 403 to a direct request from the view, while their
             * metadata APIs are fine. The daemon fetches, the view loads a
             * file. Measured in PERF.md as the reason the ladder belongs here.
             */
            "thumb" => {
                let id = req.p.get("id").and_then(|v| v.as_str()).unwrap_or_default();
                let size = req.p.get("size").and_then(|v| v.as_u64()).unwrap_or(320) as u32;
                /*
                 * A SIGNED URL GOES STALE, AND THE STORED ONE IS THE OLD ONE.
                 *
                 * Pornhub's posters are `…?hdnea=st=…~exp=…~hmac=…`: signed,
                 * and good for a day. The catalogue keeps the URL it first saw,
                 * so a row fetched yesterday answers 403 today and the cell
                 * stays empty for ever — measured here, twelve of thirty.
                 *
                 * A caller looking at a LIVE listing has the fresh URL in its
                 * hand: it arrived with the page it is drawing. So it may send
                 * it, and it is tried first when it differs from what is
                 * stored. This is also what lets a row the catalogue chose not
                 * to keep have a picture at all.
                 */
                let fresh_url = req.p.get("url").and_then(|v| v.as_str()).unwrap_or_default();

                let mut item = {
                    let catalog = self.catalog.lock().await;
                    match catalog.by_id(id) {
                        Some(item) => item.clone(),
                        None if !fresh_url.is_empty() => {
                            let mut stand_in = crate::scrape::normalize("", id, "", fresh_url, fresh_url, "", 0, 0, Vec::new());
                            stand_in.id = id.to_string();
                            stand_in
                        }
                        None => return Response::err(req.id, format!("no such item: {id}")),
                    }
                };

                if !fresh_url.is_empty() && fresh_url != item.url {
                    // The stored one stays as a fallback: `thumb_source_candidates`
                    // keeps the thumbnail tier and the original in the list.
                    item.thumb = item.url.clone();
                    item.url = fresh_url.to_string();
                }

                if let Some(cache) = self.cached_thumb(&item.id, size).await {
                    return Response::ok(req.id, serde_json::json!({ "path": cache, "cached": true }));
                }

                // Best-first, sized to the request — see thumb_source_candidates's
                // doc comment for which tier and why. A row where every
                // candidate fails cannot ever fill its cell, so it is marked
                // broken and stops appearing in results rather than sitting
                // there empty.
                let candidates = thumb_source_candidates(&item, size);

                let mut bytes = None;
                let mut last_error = String::from("no url");
                /*
                 * Only a PERMANENT failure hides a row.
                 *
                 * Marking a row broken is forever — it survives restarts and
                 * re-crawls, which is the point when a picture is genuinely
                 * gone. A 429 from a host that is merely busy is not that, and
                 * treating it as one deletes rows from the catalogue for being
                 * popular. Every candidate has to fail, and fail permanently.
                 */
                let mut permanent = !candidates.is_empty();
                for candidate in &candidates {
                    // The thumbnail lane: someone is looking at this cell.
                    match self.http.fetch_bytes_now(candidate).await {
                        Ok(b) => {
                            bytes = Some(b);
                            break;
                        }
                        Err(e) => {
                            /*
                             * …unless the url was signed and has aged out.
                             *
                             * A 403 is normally an answer — a hotlink block is
                             * not a hiccup — but a signed poster url answers
                             * exactly that when its hour is up, and the picture
                             * is still there behind a fresh signature. Writing
                             * those off emptied twelve tiles of thirty here and
                             * kept them empty.
                             */
                            let stale_signature = matches!(&e, scrape::ScrapeError::Status(401 | 403, _)) && scrape::is_signed_url(candidate);
                            permanent &= e.is_permanent() && !stale_signature;
                            last_error = e.to_string();
                        }
                    }
                }

                let Some(bytes) = bytes else {
                    let newly = if permanent {
                        self.catalog.lock().await.mark_broken(&item.id)
                    } else {
                        self.log(format_args!("thumb {} deferred: {last_error}", item.id));
                        false
                    };
                    self.log(format_args!("thumb {} unavailable: {last_error}", item.id));
                    return Response::err(
                        req.id,
                        format!("unavailable: {last_error}"),
                    )
                    .with_broken(newly);
                };

                let (decoded, video) = match image::load_any(&bytes, (size, size)) {
                    Ok(pair) => pair,
                    Err(e) => {
                        // Bytes that are not a picture are as useless as no
                        // bytes: an HTML error page served with a 200, most
                        // often.
                        let newly = self.catalog.lock().await.mark_broken(&item.id);
                        return Response::err(req.id, format!("decode: {e}")).with_broken(newly);
                    }
                };

                /*
                 * A VIDEO'S FACTS COME FROM THE FILE, ONCE.
                 *
                 * Sources report a video's dimensions inconsistently and its
                 * length almost never, and a duration nobody measured is worse
                 * than none because the UI would print it. This is the one
                 * moment the daemon holds the actual file, so what ffprobe saw
                 * is written down here and never asked again.
                 */
                if let Some(facts) = video {
                    self.catalog.lock().await.remember_video(
                        &item.id,
                        facts.w,
                        facts.h,
                        facts.duration,
                    );
                }

                let ladder = match image::thumb_ladder(&decoded, &[size], image::THUMB_QUALITY) {
                    Ok(l) => l,
                    Err(e) => return Response::err(req.id, format!("encode: {e}")),
                };
                let cache = self.thumb_path(&item.id, size, image::extension(ladder[0].2));

                if let Err(e) = util::write_atomic(&cache, &ladder[0].1).await {
                    return Response::err(req.id, format!("write: {e}"));
                }

                // Keep them. Both were computed here and returned to a client
                // that had nowhere to put them, so nothing was ever hashed and
                // "more like this" had nothing to compare.
                let phash = format!("{:016x}", image::phash(&decoded));
                let dominant = util::to_hex(image::dominant_color(&decoded));
                self.catalog.lock().await.remember_hashes(&item.id, &phash, &dominant);

                Response::ok(
                    req.id,
                    serde_json::json!({
                        "path": cache,
                        "cached": false,
                        "phash": phash,
                        "dominant": dominant,
                    }),
                )
            }

            /*
             * Warm a batch of thumbnails.
             *
             * The client asks once per page of records rather than once per
             * tile: ninety tiles a screen meant ninety round trips, and the
             * ones already on disk cost a request each to discover. Fetching
             * happens in parallel here, and the answer is a map of id to path
             * for everything that ended up cached.
             */
            "thumbs" => {
                let size = req.p.get("size").and_then(|v| v.as_u64()).unwrap_or(320) as u32;
                let ids: Vec<String> = req
                    .p
                    .get("ids")
                    .and_then(|v| v.as_array())
                    .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect())
                    .unwrap_or_default();

                let mut ready = serde_json::Map::new();
                let mut wanted = Vec::new();

                for id in ids {
                    if let Some(path) = self.cached_thumb_sync(&id, size) {
                        ready.insert(id, serde_json::Value::String(path));
                        continue;
                    }
                    let item = {
                        let catalog = self.catalog.lock().await;
                        catalog.by_id(&id)
                    };
                    if let Some(item) = item {
                        wanted.push((id, item));
                    }
                }

                // `cachedOnly`: answer with what is on disk NOW. A wall waiting for
                // the slowest of 24 downloads showed nothing for seconds; it loads
                // the rest itself and warms the cache with a second, normal call.
                if req.p.get("cachedOnly").and_then(|v| v.as_bool()).unwrap_or(false) {
                    wanted.clear();
                }

                let thumb_dir = self.thumb_dir.clone();
                let fetched = futures_lite_join(wanted.into_iter().map(|(id, item)| {
                    let http = Arc::clone(&self.http);
                    let thumb_dir = thumb_dir.clone();
                    async move {
                        // Same choice as `thumb` — see thumb_source_candidates.
                        let mut bytes = None;
                        for candidate in thumb_source_candidates(&item, size) {
                            if let Ok(b) = http.fetch_bytes(&candidate).await {
                                bytes = Some(b);
                                break;
                            }
                        }
                        let bytes = bytes?;
                        let decoded = image::load(&bytes, (size, size)).ok()?;
                        let ladder =
                            image::thumb_ladder(&decoded, &[size], image::THUMB_QUALITY).ok()?;
                        let (_, encoded, format) = ladder.into_iter().next()?;
                        let path = thumb_file(&thumb_dir, &id, size, image::extension(format));
                        util::write_atomic(&path, &encoded).await.ok()?;
                        Some((id, path))
                    }
                }))
                .await;

                for entry in fetched.into_iter().flatten() {
                    ready.insert(entry.0, serde_json::Value::String(entry.1));
                }

                Response::ok(req.id, serde_json::json!({ "thumbs": ready }))
            }

            /*
             * Fetch a 3D model, with everything it needs to open.
             *
             * A glTF is not one file: Poly Haven's is 2.6 KB of JSON plus a
             * binary buffer and its textures, referenced by *relative* path. So
             * the whole set is downloaded into one directory, keeping those
             * paths intact, and the viewer is handed the .gltf — which is the
             * only arrangement a runtime loader can open.
             */
            /*
             * A VIDEO THE PLAYER COULD NOT OPEN, FETCHED BY THE ONE THAT CAN.
             *
             * The viewer hands a clip's URL straight to the media player, and a
             * player is a poor HTTP client: measured on the live catalogue,
             * cdn.donmai.us answers a browser-looking request without its
             * Referer with 403, and upload.wikimedia.org answers 429 to any
             * burst whatever the User-Agent — each surfaced as "Could not open
             * media: Input/output error" over a black pane. The daemon's client
             * sends the referer the source registered, waits out a 429, and for
             * Commons also tries the site's own smaller transcodes, which are
             * separate files on the same host. The file lands in the media
             * cache and the player plays that.
             */
            "media" => {
                let id = req.p.get("id").and_then(|v| v.as_str()).unwrap_or_default();
                let item = {
                    let catalog = self.catalog.lock().await;
                    match catalog.by_id(id) {
                        Some(item) => item,
                        None => return Response::err(req.id, format!("no such item: {id}")),
                    }
                };
                if item.url.starts_with("file://") {
                    return Response::ok(req.id, serde_json::json!({ "path": item.url.trim_start_matches("file://"), "cached": true }));
                }
                // A chosen quality (see `renditions`), or the row's own file.
                let wanted = req.p.get("url").and_then(|v| v.as_str()).unwrap_or_default().to_string();
                let same_site = |a: &str, b: &str| {
                    let host = |u: &str| u.split("://").nth(1).unwrap_or("").split('/').next().unwrap_or("").to_string();
                    let (a, b) = (host(a), host(b));
                    !a.is_empty() && (a == b || a.ends_with(&format!(".{b}")) || b.ends_with(&format!(".{a}")))
                };
                /*
                 * A chosen quality is trusted when it is the row's own host or
                 * one the row's page declared. Host-matching alone rejected
                 * every tube stream — the page is pornhub.com and the file is
                 * phncdn.com — and `media` then quietly fell back to the
                 * poster, so "load the full video" downloaded a 320×180 still.
                 */
                let wanted = if wanted.is_empty() {
                    String::new()
                } else if same_site(&wanted, &item.url) || same_site(&wanted, &item.page_url) {
                    wanted
                } else if item.page_url.starts_with("http")
                    && self
                        .videos_for_page(&item.page_url, &item.source)
                        .await
                        .map(|streams| streams.iter().any(|(url, _)| url == &wanted))
                        .unwrap_or(false)
                {
                    wanted
                } else {
                    String::new()
                };

                let media_dir = self.model_dir.trim_end_matches("/models").to_string() + "/media";
                // The extension comes from the file being FETCHED, not from
                // the row: a tube row's own url is a .jpg poster, and naming
                // the cached video after it meant a later call found that
                // poster sitting there and served it as the video.
                let ext = {
                    let from = if wanted.is_empty() { &item.url } else { &wanted };
                    let path = from.split(['?', '#']).next().unwrap_or("");
                    let ext = path.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
                    if ext == "m3u8" {
                        "mp4".to_string()
                    } else if ext.len() <= 5 && !ext.is_empty() && ext.chars().all(|c| c.is_ascii_alphanumeric()) {
                        ext
                    } else {
                        "mp4".to_string()
                    }
                };
                // The quality is part of the cached name, so switching between
                // two of them does not overwrite one with the other.
                let tag = if wanted.is_empty() { String::new() } else { format!("-{:08x}", wanted.bytes().fold(2166136261u32, |h, b| (h ^ b as u32).wrapping_mul(16777619))) };
                let target = format!("{media_dir}/{}{tag}.{ext}", scrape::cache_key(&item.id));
                // A few kilobytes is a poster or a failed write, never a video:
                // serving it back reads as "played instantly, showed nothing".
                let plausible = |len: u64| if item.family == "video" { len > 64 * 1024 } else { len > 0 };
                if std::fs::metadata(&target).map(|m| plausible(m.len())).unwrap_or(false) {
                    return Response::ok(req.id, serde_json::json!({ "path": target, "cached": true }));
                }
                tokio::fs::create_dir_all(&media_dir).await.ok();

                // Commons first offers its own transcodes: the original of a
                // nature clip was 594 MB, its 480p copy 74 MB, and not every
                // size exists for every file (measured: 720p 404, 480p 200).
                let mut candidates = Vec::new();
                if let Some(rest) = item.url.split('?').next().unwrap_or("").strip_prefix("https://upload.wikimedia.org/wikipedia/commons/") {
                    // commons/a/ab/Name.webm → commons/transcoded/a/ab/Name.webm/Name.webm.720p.vp9.webm
                    if let Some(name) = rest.rsplit('/').next() {
                        for size in ["720p", "480p", "360p"] {
                            candidates.push(format!(
                                "https://upload.wikimedia.org/wikipedia/commons/transcoded/{rest}/{name}.{size}.vp9.webm"
                            ));
                        }
                    }
                }
                const MAX_MEDIA: u64 = 400 * 1024 * 1024;
                if !wanted.is_empty() {
                    // Asked for by name: that file, and nothing else.
                    candidates.clear();
                    candidates.push(wanted.clone());
                } else if item.bytes == 0 || (item.bytes as u64) <= MAX_MEDIA {
                    candidates.push(item.url.clone());
                }

                let mut last_error = String::new();
                for candidate in &candidates {
                    /*
                     * A playlist is not a file: HLS has to be pulled segment by
                     * segment and remuxed, and these hosts answer 410/412 to a
                     * request without the page's Referer — which a media player
                     * cannot send. ffmpeg can, and copies the streams without
                     * re-encoding.
                     */
                    if candidate.split(['?', '#']).next().unwrap_or("").ends_with(".m3u8") {
                        let referer = if item.page_url.starts_with("http") { item.page_url.clone() } else { candidate.clone() };
                        // spawn_blocking: the tokio "process" feature is not
                        // enabled here, and ffmpeg is a long call either way.
                        let args: Vec<String> = vec![
                            "-nostdin".into(), "-loglevel".into(), "error".into(), "-y".into(),
                            "-user_agent".into(), scrape::USER_AGENT.to_string(),
                            "-headers".into(), format!("Referer: {referer}\r\n"),
                            "-i".into(), candidate.clone(),
                            "-c".into(), "copy".into(), "-bsf:a".into(), "aac_adtstoasc".into(),
                            "-fs".into(), MAX_MEDIA.to_string(),
                            target.clone(),
                        ];
                        let out = tokio::task::spawn_blocking(move || {
                            std::process::Command::new("ffmpeg").args(&args).output()
                        })
                        .await
                        .unwrap_or_else(|e| Err(std::io::Error::other(e.to_string())));
                        match out {
                            Ok(done) if done.status.success() || std::fs::metadata(&target).map(|m| m.len() > 0).unwrap_or(false) => {
                                let written = std::fs::metadata(&target).map(|m| m.len()).unwrap_or(0);
                                self.log(format_args!("media {id}: {written} bytes via hls"));
                                trim_media_cache(&media_dir, budget_from_env("QUARRY_MEDIA_BUDGET_MB", 512));
                                return Response::ok(req.id, serde_json::json!({ "path": target, "cached": false, "bytes": written }));
                            }
                            Ok(done) => {
                                last_error = String::from_utf8_lossy(&done.stderr).lines().last().unwrap_or("ffmpeg failed").to_string();
                            }
                            Err(e) => last_error = format!("ffmpeg: {e}"),
                        }
                        continue;
                    }

                    for attempt in 0..3u64 {
                        match self.http.download_to(candidate, &target, MAX_MEDIA).await {
                            Ok(written) if written > 0 => {
                                self.log(format_args!("media {id}: {written} bytes via {}", if candidate == &item.url { "original" } else { "transcode" }));
                                trim_media_cache(&media_dir, budget_from_env("QUARRY_MEDIA_BUDGET_MB", 512));
                                return Response::ok(req.id, serde_json::json!({ "path": target, "cached": false, "bytes": written }));
                            }
                            Ok(_) => {
                                let _ = std::fs::remove_file(&target);
                                last_error = "empty file".to_string();
                                break;
                            }
                            Err(scrape::ScrapeError::RateLimited(_)) => {
                                last_error = "the host is rate-limiting — try again in a minute".to_string();
                                tokio::time::sleep(std::time::Duration::from_secs(2 + attempt * 3)).await;
                            }
                            Err(e) => {
                                last_error = e.to_string();
                                break;
                            }
                        }
                    }
                }
                Response::err(req.id, last_error)
            }

            /*
             * A thumbnail from a video page, turned into the video.
             *
             * Search engines index a still and link the page it came from, so
             * the row is a picture of a video. This reads the page and takes
             * the file the page itself declares.
             */
            "resolve" => {
                let id = req.p.get("id").and_then(|v| v.as_str()).unwrap_or_default();
                let item = {
                    let catalog = self.catalog.lock().await;
                    catalog.by_id(id).ok_or_else(|| format!("no such item: {id}"))
                };
                let item = match item {
                    Ok(item) => item,
                    Err(e) => return Response::err(req.id, e),
                };
                // Already a video AND its own file plays: nothing to resolve.
                // A "video" whose url is its poster still needs the page read —
                // tube sites publish the still and keep the stream behind it.
                if item.family == "video" && url_plays(&item.url) {
                    return Response::ok(req.id, serde_json::json!({ "url": item.url, "family": "video", "changed": false }));
                }
                let page = if item.page_url.starts_with("http") { item.page_url.clone() } else { item.url.clone() };
                if !page.starts_with("http") {
                    return Response::err(req.id, "that row has no page to look at".to_string());
                }
                let streams = match self.videos_for_page(&page, &item.source).await {
                    Ok(streams) => streams,
                    Err(e) => return Response::err(req.id, e),
                };
                let Some((url, _)) = streams.first().cloned() else {
                    return Response::err(req.id, "no video on that page".to_string());
                };
                let duration = 0.0;

                let mut updated = item.clone();
                updated.family = "video".into();
                updated.url = url.clone();
                updated.ext = url.split(['?', '#']).next().unwrap_or("").rsplit('.').next().unwrap_or("mp4").to_string();
                if duration > 0.0 {
                    updated.duration = duration;
                }
                if updated.thumb.is_empty() {
                    updated.thumb = item.url.clone();
                }
                self.catalog.lock().await.replace(updated);
                self.adopt_page_tags(id, &page).await;
                self.log(format_args!("resolve {id}: video on {page}"));
                Response::ok(req.id, serde_json::json!({ "url": url, "family": "video", "duration": duration, "changed": true }))
            }

            /*
             * The qualities this video actually has.
             *
             * Sites publish the same clip several ways — Commons renders
             * 1080/720/480/360 transcodes, boards keep a sample beside the
             * original, tube pages list their own — and the viewer had no way
             * to ask for the small one on a slow line or the big one on a
             * wall. Probed, not guessed: a rendition is only offered once its
             * host has answered for it.
             */
            /*
             * REDDIT, FOR A LENS.
             *
             * A row can carry a picture; it cannot carry what was said under
             * it, and the comment tree is the reason anyone opens reddit at
             * all. Every unauthenticated path has answered 403 since 2024 —
             * `www`, `api.` and `old.` alike — so a lens cannot fetch this for
             * itself, and the credential lives here rather than in QML.
             *
             * Deliberately narrow: GET only, the OAuth host only, and a path
             * the caller supplies, so this is a reddit door rather than a
             * general-purpose proxy for anything a lens fancies.
             */
            "reddit" => {
                let path = req.p.get("path").and_then(|v| v.as_str()).unwrap_or_default();
                if !path.starts_with('/') || path.contains("://") {
                    return Response::err(req.id, "path must start with / and name no host".to_string());
                }
                if !sources::reddit::configured() {
                    return Response::err(
                        req.id,
                        "reddit needs an app credential — set REDDIT_CLIENT_ID, REDDIT_CLIENT_SECRET, REDDIT_USER and REDDIT_PASS in ~/.secure/reddit-app.env".to_string(),
                    );
                }
                let Some(token) = sources::reddit::token().await else {
                    return Response::err(req.id, "reddit would not mint a token — check the credential".to_string());
                };
                let url = format!("https://oauth.reddit.com{path}");
                match sources::reddit::fetch(&url, &token).await {
                    Ok(text) => match serde_json::from_str::<serde_json::Value>(&text) {
                        Ok(json) => Response::ok(req.id, serde_json::json!({ "json": json })),
                        Err(e) => Response::err(req.id, format!("reddit sent something that was not JSON: {e}")),
                    },
                    Err(e) => Response::err(req.id, format!("{e}")),
                }
            }

            /*
             * PORNHUB'S OWN LISTS, FOR ITS LENS.
             *
             * The webmasters API has more than a search: `/categories` is the
             * site's real category list (ids and all), `/stars` is every
             * performer it knows, and `/video_by_id` carries what a video page
             * shows and a catalogue row cannot — views, rating, the performers
             * in it, the categories it is filed under.
             *
             * It goes through here rather than from QML because this host
             * answers 403 to back-to-back requests: the limiter and the cache
             * that make the crawler work are the same ones that keep a lens
             * from being blocked. Narrow on purpose — one host, one path
             * prefix, GET only.
             */
            "pornhub" => {
                let path = req.p.get("path").and_then(|v| v.as_str()).unwrap_or_default();
                if path.contains("://") || path.starts_with('/') {
                    return Response::err(req.id, "path is a webmasters endpoint, without a host".to_string());
                }
                // `stars_detailed` is a separate endpoint, not a path under
                // `stars` — leaving it out made the performer wall come back
                // empty with no error anywhere.
                let allowed = ["categories", "stars", "stars_detailed", "video_by_id", "search", "tags"];
                let head = path.split(['?', '/']).next().unwrap_or("");
                if !allowed.contains(&head) {
                    return Response::err(req.id, format!("not a webmasters endpoint: {head}"));
                }
                let url = format!("https://www.pornhub.com/webmasters/{path}");
                match self.http.fetch_text(&url).await {
                    Ok(text) => match serde_json::from_str::<serde_json::Value>(&text) {
                        Ok(json) => Response::ok(req.id, serde_json::json!({ "json": json })),
                        Err(e) => Response::err(req.id, format!("pornhub sent something that was not JSON: {e}")),
                    },
                    Err(e) => Response::err(req.id, format!("{e}")),
                }
            }

            "renditions" => {
                let id = req.p.get("id").and_then(|v| v.as_str()).unwrap_or_default();
                /*
                 * A ROW THE CATALOGUE DID NOT KEEP IS STILL A PAGE.
                 *
                 * `search` answers with what it fetched, and the catalogue
                 * drops the ones it already holds under another id — so a lens
                 * showing a live feed can be looking at a row that is not in
                 * the database, ask for its qualities, and be told "no such
                 * item" about a video that is plainly on the screen. A page url
                 * is enough to resolve one, so it is accepted as a fallback.
                 */
                let page_url = req
                    .p
                    .get("pageUrl")
                    .or_else(|| req.p.get("page_url"))
                    .and_then(|v| v.as_str())
                    .unwrap_or_default();
                let item = {
                    let catalog = self.catalog.lock().await;
                    match catalog.by_id(id) {
                        Some(item) => item,
                        None if !page_url.is_empty() => {
                            let mut stand_in = crate::scrape::normalize(
                                "pornhub",
                                id,
                                "",
                                page_url,
                                "",
                                "",
                                0,
                                0,
                                Vec::new(),
                            );
                            stand_in.page_url = page_url.to_string();
                            stand_in.family = "video".into();
                            stand_in
                        }
                        None => return Response::err(req.id, format!("no such item: {id}")),
                    }
                };

                let mut found: Vec<serde_json::Value> = Vec::new();
                let mut seen: Vec<String> = Vec::new();
                let mut push = |url: &str, label: &str, w: u32, h: u32, bytes: u64, seen: &mut Vec<String>, found: &mut Vec<serde_json::Value>| {
                    if !url.starts_with("http") || seen.contains(&url.to_string()) {
                        return;
                    }
                    seen.push(url.to_string());
                    found.push(serde_json::json!({
                        "label": label, "url": url, "w": w, "h": h, "bytes": bytes,
                    }));
                };

                let playable_ext = |u: &str| {
                    let path = u.split(['?', '#']).next().unwrap_or("").to_ascii_lowercase();
                    [".mp4", ".webm", ".mkv", ".mov", ".m4v", ".m3u8"].iter().any(|e| path.ends_with(e))
                };
                // A video row's own file is often its poster — these sites
                // publish the still and keep the stream on the page. A poster
                // is not a quality, so it is not offered as one.
                let own_plays = item.family != "video" || playable_ext(&item.url);
                if own_plays {
                    push(&item.url, "Original", item.w, item.h, item.bytes, &mut seen, &mut found);
                }
                if item.family != "video" || playable_ext(&item.sample) {
                    push(&item.sample, "Smaller", 0, 0, 0, &mut seen, &mut found);
                }

                // Commons: its own renders, which exist per file rather than
                // per wiki — 720p is missing for plenty of them.
                if let Some(rest) = item.url.split('?').next().unwrap_or("").strip_prefix("https://upload.wikimedia.org/wikipedia/commons/") {
                    if let Some(name) = rest.rsplit('/').next() {
                        let sizes: Vec<(&'static str, u32, u32)> = vec![("1080p", 1920, 1080), ("720p", 1280, 720), ("480p", 854, 480), ("360p", 640, 360)];
                        let probes = sizes.into_iter().map(|(label, w, h)| {
                            let url = format!("https://upload.wikimedia.org/wikipedia/commons/transcoded/{rest}/{name}.{label}.vp9.webm");
                            let http = Arc::clone(&self.http);
                            async move {
                                let (status, _) = http.probe(&url).await;
                                (url, label, w, h, status)
                            }
                        });
                        for (url, label, w, h, status) in futures_lite_join(probes).await {
                            if status == 200 {
                                push(&url, label, w, h, 0, &mut seen, &mut found);
                            }
                        }
                    }
                }

                // Whatever the page itself declares, for rows that are a still
                // of a video somewhere else.
                let mut trouble = String::new();
                if (found.len() < 2 || !own_plays) && item.page_url.starts_with("http") {
                    match self.videos_for_page(&item.page_url, &item.source).await {
                        Ok(streams) => {
                            for (url, label) in streams {
                                push(&url, &label, 0, 0, 0, &mut seen, &mut found);
                            }
                        }
                        // Said out loud: "no qualities" and "the site would not
                        // answer just now" are different answers.
                        Err(e) => trouble = e,
                    }
                }

                if item.page_url.starts_with("http") {
                    self.adopt_page_tags(&item.id, &item.page_url).await;
                }
                Response::ok(req.id, serde_json::json!({ "id": item.id, "renditions": found, "error": trouble }))
            }

            /*
             * What you did, kept so you can get back to it.
             *
             * `history` reads (newest first, optionally one kind or matching
             * text), `history_add` records one, `history_clear` forgets a kind
             * or everything. The app decides what is worth recording; the
             * daemon only bounds it.
             */
            "history" => {
                let kind = req.p.get("kind").and_then(|v| v.as_str()).unwrap_or_default();
                let needle = req.p.get("q").and_then(|v| v.as_str()).unwrap_or_default();
                let limit = req.p.get("limit").and_then(|v| v.as_u64()).unwrap_or(200).clamp(1, 2000) as usize;
                let rows: Vec<serde_json::Value> = self
                    .catalog
                    .lock()
                    .await
                    .history(kind, needle, limit)
                    .into_iter()
                    .map(|(at, kind, value, item, context)| {
                        // `context` is stored as opaque text; parsed here so a
                        // client reads an object rather than a string it has to
                        // unwrap itself. Unparseable or empty becomes null.
                        let where_ = serde_json::from_str::<serde_json::Value>(&context)
                            .unwrap_or(serde_json::Value::Null);
                        serde_json::json!({ "at": at, "kind": kind, "value": value, "item": item, "context": where_ })
                    })
                    .collect();
                Response::ok(req.id, serde_json::json!({ "count": rows.len(), "entries": rows }))
            }

            "history_add" => {
                let kind = req.p.get("kind").and_then(|v| v.as_str()).unwrap_or("search");
                let value = req.p.get("value").and_then(|v| v.as_str()).unwrap_or_default();
                let item = req.p.get("item").and_then(|v| v.as_str()).unwrap_or_default();
                if value.is_empty() && item.is_empty() {
                    return Response::err(req.id, "nothing to record".to_string());
                }
                // Where the client was: an object it gets back verbatim. The
                // daemon stores it and never reads into it — a lens knows what
                // its own screens are called and nothing here should.
                let context = match req.p.get("context") {
                    Some(v) if !v.is_null() => v.to_string(),
                    _ => String::new(),
                };
                self.catalog.lock().await.history_add(kind, value, item, &context);
                Response::ok(req.id, serde_json::json!({ "kind": kind }))
            }

            "history_clear" => {
                let kind = req.p.get("kind").and_then(|v| v.as_str()).unwrap_or_default();
                let removed = self.catalog.lock().await.history_clear(kind);
                self.log(format_args!("history cleared: {removed} rows ({})", if kind.is_empty() { "all" } else { kind }));
                Response::ok(req.id, serde_json::json!({ "removed": removed }))
            }

            /*
             * A playable local URL for a stream the player cannot fetch.
             *
             * Same choice as `media`, without the wait: `media` downloads the
             * whole file first (six minutes for a three-minute clip), this
             * hands back a loopback URL that re-requests upstream with the
             * page's Referer as the player asks for each part.
             */
            "stream" => {
                let id = req.p.get("id").and_then(|v| v.as_str()).unwrap_or_default();
                let wanted = req.p.get("url").and_then(|v| v.as_str()).unwrap_or_default().to_string();
                // The same reason as `renditions`: a live feed can be showing a
                // row the catalogue chose not to keep, and "no such item" about
                // a video that is on the screen and has already resolved its
                // qualities is a nonsense answer. The page is what this needs
                // anyway — it is where the Referer comes from.
                let page_url = req
                    .p
                    .get("pageUrl")
                    .or_else(|| req.p.get("page_url"))
                    .and_then(|v| v.as_str())
                    .unwrap_or_default();
                let item = {
                    let catalog = self.catalog.lock().await;
                    match catalog.by_id(id) {
                        Some(item) => item,
                        None if !page_url.is_empty() || !wanted.is_empty() => {
                            let mut stand_in = crate::scrape::normalize(
                                "",
                                id,
                                "",
                                if wanted.is_empty() { page_url } else { &wanted },
                                "",
                                page_url,
                                0,
                                0,
                                Vec::new(),
                            );
                            stand_in.page_url = page_url.to_string();
                            stand_in.family = "video".into();
                            stand_in
                        }
                        None => return Response::err(req.id, format!("no such item: {id}")),
                    }
                };
                let url = if !wanted.is_empty() {
                    wanted
                } else if url_plays(&item.url) {
                    item.url.clone()
                } else {
                    match self.videos_for_page(&item.page_url, &item.source).await {
                        Ok(streams) => match streams.first() {
                            Some((url, _)) => url.clone(),
                            None => return Response::err(req.id, "no video on that page".to_string()),
                        },
                        Err(e) => return Response::err(req.id, e),
                    }
                };
                if item.page_url.starts_with("http") {
                    self.adopt_page_tags(&item.id, &item.page_url).await;
                }

                let proxy = {
                    let mut held = self.proxy.lock().await;
                    if held.is_none() {
                        *held = stream::Proxy::start(Arc::clone(&self.http)).await;
                    }
                    held.clone()
                };
                let Some(proxy) = proxy else {
                    return Response::err(req.id, "could not open a local port for the stream".to_string());
                };
                let referer = if item.page_url.starts_with("http") { item.page_url.clone() } else { url.clone() };
                let local = proxy.offer(&url, &referer).await;
                self.log(format_args!("stream {id} -> {local}"));
                Response::ok(req.id, serde_json::json!({ "url": local, "upstream": url }))
            }

            /*
             * A picture from somewhere that is not the catalogue.
             *
             * A lens shows a site's own images, and loading them straight from
             * QML has no pacing, no retry and no cache — 4chan's CDN answers
             * 429 as soon as a thread opens, and every picture in it is then
             * simply blank. Here they go through the same limiter and disk
             * cache as everything else, and come back as a local file.
             */
            "cache_url" => {
                let url = req.p.get("url").and_then(|v| v.as_str()).unwrap_or_default().to_string();
                if !url.starts_with("http") {
                    return Response::err(req.id, "not a url".to_string());
                }
                let referer = req.p.get("referer").and_then(|v| v.as_str()).unwrap_or_default().to_string();
                let dir = format!("{}/lens", self.model_dir.trim_end_matches("/models"));
                let ext = {
                    let path = url.split(['?', '#']).next().unwrap_or("");
                    let ext = path.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
                    if !ext.is_empty() && ext.len() <= 5 && ext.chars().all(|c| c.is_ascii_alphanumeric()) { ext } else { "bin".to_string() }
                };
                let target = format!(
                    "{dir}/{:08x}.{ext}",
                    url.bytes().fold(2166136261u32, |h, b| (h ^ b as u32).wrapping_mul(16777619))
                );
                if std::fs::metadata(&target).map(|m| m.len() > 0).unwrap_or(false) {
                    return Response::ok(req.id, serde_json::json!({ "path": target, "cached": true }));
                }
                tokio::fs::create_dir_all(&dir).await.ok();
                if !referer.is_empty() {
                    scrape::set_referer(&url, &referer);
                }
                match self.http.fetch_bytes_now(&url).await {
                    Ok(bytes) if !bytes.is_empty() => {
                        if let Err(e) = util::write_atomic(&target, &bytes).await {
                            return Response::err(req.id, format!("write: {e}"));
                        }
                        // Same ceiling as the thumbnail cache, trimmed on the
                        // same schedule.
                        Response::ok(req.id, serde_json::json!({ "path": target, "cached": false, "bytes": bytes.len() }))
                    }
                    Ok(_) => Response::err(req.id, "empty answer".to_string()),
                    Err(e) => Response::err(req.id, e.to_string()),
                }
            }

            "model" => {
                let id = req.p.get("id").and_then(|v| v.as_str()).unwrap_or_default();
                let resolution =
                    req.p.get("resolution").and_then(|v| v.as_str()).unwrap_or("1k").to_string();

                let item = {
                    let catalog = self.catalog.lock().await;
                    match catalog.by_id(id) {
                        Some(item) => item.clone(),
                        None => return Response::err(req.id, format!("no such item: {id}")),
                    }
                };

                if item.family != "model" {
                    return Response::err(req.id, format!("{id} is not a model"));
                }

                let dir = format!("{}/{}", self.model_dir, scrape::cache_key(&item.id));
                let target = format!("{dir}/model.gltf");
                if std::path::Path::new(&target).exists() {
                    return Response::ok(
                        req.id,
                        serde_json::json!({ "path": target, "cached": true }),
                    );
                }

                /*
                 * THE ROW'S `url` IS THE THUMBNAIL, NOT THE MODEL.
                 *
                 * This fetched `item.url` and parsed it as a files manifest.
                 * Every model row in the catalogue carries a PNG there — it is
                 * the picture the wall draws — so every open failed with
                 * `manifest: parse: expected value at line 1 column 1`, which
                 * is serde telling you it was handed an image. Measured: 0 of
                 * 10 models across all three model sources would open.
                 *
                 * The manifest is derived from the asset instead, which is the
                 * only thing the row reliably identifies.
                 */
                let manifest_url = match model_manifest_url(&item.source, &item.id, &item.url) {
                    Ok(url) => url,
                    Err(why) => return Response::err(req.id, why),
                };

                let manifest: serde_json::Value = match self.http.fetch_json(&manifest_url).await {
                    Ok(v) => v,
                    Err(e) => return Response::err(req.id, format!("manifest: {e}")),
                };

                /*
                 * The asked-for resolution, or the nearest one that exists.
                 *
                 * Poly Haven publishes 1k/2k/4k/8k but not for every asset, and
                 * refusing to open a model because the exact size is missing is
                 * a worse answer than opening the one it does have.
                 */
                let gltf = manifest.get("gltf");
                let entry = gltf
                    .and_then(|g| g.get(&resolution))
                    .and_then(|r| r.get("gltf"))
                    .cloned()
                    .or_else(|| {
                        let available = gltf?.as_object()?;
                        for fallback in ["1k", "2k", "4k", "8k"] {
                            if let Some(found) =
                                available.get(fallback).and_then(|r| r.get("gltf"))
                            {
                                return Some(found.clone());
                            }
                        }
                        None
                    });
                let Some(entry) = entry else {
                    return Response::err(req.id, format!("no gltf for {id}"));
                };

                let Some(main_url) = entry.get("url").and_then(|v| v.as_str()) else {
                    return Response::err(req.id, "manifest has no url".to_string());
                };

                // The model, then everything it references, in parallel.
                let mut jobs: Vec<(String, String)> = vec![(target.clone(), main_url.to_string())];
                if let Some(includes) = entry.get("include").and_then(|v| v.as_object()) {
                    for (relative, spec) in includes {
                        let Some(url) = spec.get("url").and_then(|v| v.as_str()) else { continue };
                        jobs.push((format!("{dir}/{relative}"), url.to_string()));
                    }
                }

                let count = jobs.len();
                let results = futures_lite_join(jobs.into_iter().map(|(path, url)| {
                    let http = Arc::clone(&self.http);
                    async move {
                        let bytes = http.fetch_bytes(&url).await.ok()?;
                        util::write_atomic(&path, &bytes).await.ok()?;
                        Some(bytes.len())
                    }
                }))
                .await;

                let fetched: usize = results.iter().flatten().count();
                let bytes: usize = results.iter().flatten().sum();

                if !std::path::Path::new(&target).exists() {
                    return Response::err(req.id, "model file did not download".to_string());
                }

                self.log(format_args!(
                    "model {id} -> {fetched}/{count} files, {}",
                    util::human_bytes(bytes as u64)
                ));

                Response::ok(
                    req.id,
                    serde_json::json!({
                        "path": target,
                        "cached": false,
                        "files": fetched,
                        "bytes": bytes,
                    }),
                )
            }

            /*
             * Save a target of your own.
             *
             * Targets have always been data — the shipped ones are a literal in
             * QML — but there was no way to *make* one without editing a file
             * by hand, which meant every knob in the export sheet was a
             * one-shot: tweak, export, lose it. This merges one target into
             * ~/.config/quarry/targets.json by id, which the app already
             * watches, so a saved target appears in the list immediately.
             */
            "saveTarget" => {
                let Some(target) = req.p.get("target").cloned() else {
                    return Response::err(req.id, "no target".to_string());
                };
                let Some(id) = target.get("id").and_then(|v| v.as_str()).map(String::from) else {
                    return Response::err(req.id, "target has no id".to_string());
                };

                let home = std::env::var("HOME").unwrap_or_default();
                let path = format!("{home}/.config/quarry/targets.json");

                let mut targets: Vec<serde_json::Value> = tokio::fs::read_to_string(&path)
                    .await
                    .ok()
                    .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
                    .and_then(|doc| doc.get("targets").and_then(|t| t.as_array()).cloned())
                    .unwrap_or_default();

                // By id, so saving twice edits rather than duplicates.
                targets.retain(|t| t.get("id").and_then(|v| v.as_str()) != Some(id.as_str()));
                targets.push(target);

                let document = serde_json::json!({ "targets": targets });
                let encoded = serde_json::to_vec_pretty(&document)
                    .map_err(|e| e.to_string())
                    .unwrap_or_default();

                if let Err(e) = util::write_atomic(&path, &encoded).await {
                    return Response::err(req.id, format!("write: {e}"));
                }

                self.log(format_args!("saved target {id} ({} total)", targets.len()));
                Response::ok(req.id, serde_json::json!({ "id": id, "targets": targets.len(), "path": path }))
            }

            /*
             * A preview of an export, without exporting.
             *
             * The crop box needs to show what the recipe will actually produce,
             * and that is the same pipeline — so it is the same code, writing to
             * the cache at a size that fits a panel rather than to Pictures at
             * full size. Keeping them one path is what stops the preview and the
             * export from drifting apart, which is the classic way a crop tool
             * starts lying.
             */
            "preview" => {
                let id = req.p.get("id").and_then(|v| v.as_str()).unwrap_or_default();
                let recipe: image::Recipe = match req.p.get("recipe") {
                    Some(value) => match serde_json::from_value(value.clone()) {
                        Ok(r) => r,
                        Err(e) => return Response::err(req.id, format!("bad recipe: {e}")),
                    },
                    None => image::Recipe::default(),
                };
                let max = req.p.get("max").and_then(|v| v.as_u64()).unwrap_or(640) as u32;

                let item = {
                    let catalog = self.catalog.lock().await;
                    match catalog.by_id(id) {
                        Some(item) => item.clone(),
                        None => return Response::err(req.id, format!("no such item: {id}")),
                    }
                };

                let bytes = match self.http.fetch_bytes(&item.url).await {
                    Ok(b) => b,
                    Err(e) => return Response::err(req.id, format!("fetch: {e}")),
                };

                let decoded = match image::load(&bytes, (recipe.width.max(max), recipe.height.max(max))) {
                    Ok(img) => img,
                    Err(e) => return Response::err(req.id, format!("decode: {e}")),
                };

                let rendered = match image::apply(&decoded, &recipe) {
                    Ok(img) => img,
                    Err(e) => return Response::err(req.id, format!("render: {e}")),
                };

                // Shown, not kept: a preview at panel size costs a fraction of
                // the export and is overwritten by the next one.
                let shown = if rendered.width() > max || rendered.height() > max {
                    rendered.resize(max, max, ::image::imageops::FilterType::Triangle)
                } else {
                    rendered
                };

                let encoded = match image::encode(&shown, image::Format::Png, 90) {
                    Ok(b) => b,
                    Err(e) => return Response::err(req.id, format!("encode: {e}")),
                };

                let path = format!("{}/preview-{}.png", self.thumb_dir, scrape::cache_key(&item.id));
                if let Err(e) = util::write_atomic(&path, &encoded).await {
                    return Response::err(req.id, format!("write: {e}"));
                }

                Response::ok(
                    req.id,
                    serde_json::json!({
                        "path": path,
                        "width": shown.width(),
                        "height": shown.height(),
                        "sourceWidth": decoded.width(),
                        "sourceHeight": decoded.height(),
                    }),
                )
            }

            /*
             * Export: fetch the original, apply the recipe, write the file.
             *
             * The recipe is data (see image::Recipe) and the response echoes it,
             * so the UI can show exactly what was applied under *Advanced* —
             * which is how an export gets debugged.
             */
            "export" => {
                let id = req.p.get("id").and_then(|v| v.as_str()).unwrap_or_default();
                // "The file as it is": `{original: true}`, or `{fit: "none"}` with no
                // size (which used to fail with "missing field width"). Written
                // through unchanged, like a video.
                let original = req.p.get("recipe").is_some_and(|r| {
                    r.get("original").and_then(|v| v.as_bool()) == Some(true)
                        || (r.get("fit").and_then(|v| v.as_str()) == Some("none") && r.get("width").is_none())
                });
                let recipe: image::Recipe = match req.p.get("recipe") {
                    _ if original => image::Recipe::default(),
                    Some(value) => match serde_json::from_value(value.clone()) {
                        Ok(r) => r,
                        Err(e) => return Response::err(req.id, format!("bad recipe: {e}")),
                    },
                    None => image::Recipe::default(),
                };

                let item = {
                    let catalog = self.catalog.lock().await;
                    match catalog.by_id(id) {
                        Some(item) => item.clone(),
                        None => return Response::err(req.id, format!("no such item: {id}")),
                    }
                };

                let bytes = match self.http.fetch_bytes(&item.url).await {
                    Ok(b) => b,
                    Err(e) => return Response::err(req.id, format!("fetch: {e}")),
                };

                /*
                 * A VIDEO IS EXPORTED AS ITSELF.
                 *
                 * Every other family goes through fit, crop and re-encode,
                 * which for a video would mean writing out one frame as a PNG
                 * — the recipe's `cover` and `smart` gravity have no meaning
                 * for something that moves, and `mpvpaper` will letterbox and
                 * pan it to the screen anyway. So the file is written through
                 * unchanged, and the export reports the size it really is.
                 */
                if original || image::is_video(&bytes) || item.family == "video" {
                    return self.export_video(req.id, &item, &bytes, &req.p).await;
                }

                // A vector is rasterised at the export size from its own source
                // — never rendered once and rescaled.
                let decoded = match image::load(&bytes, (recipe.width, recipe.height)) {
                    Ok(img) => img,
                    Err(e) => return Response::err(req.id, format!("decode: {e}")),
                };

                let rendered = match image::apply(&decoded, &recipe) {
                    Ok(img) => img,
                    Err(e) => return Response::err(req.id, format!("render: {e}")),
                };

                let encoded = match image::encode(&rendered, recipe.format, recipe.quality) {
                    Ok(b) => b,
                    Err(e) => return Response::err(req.id, format!("encode: {e}")),
                };

                let template = req
                    .p
                    .get("path")
                    .and_then(|v| v.as_str())
                    .unwrap_or("~/Pictures/quarry/{kind}/{slug}-{w}x{h}.{ext}");

                let ext = image::extension(recipe.format);

                /*
                 * `{kind}` IS THE SOURCE'S WORD, NOT THE DESTINATION'S.
                 *
                 * A 3072x1920 wallpaper landed in `~/Pictures/quarry/avatar/`
                 * because that is what the board called the row it came from.
                 * The file's shape is decided entirely by the target's recipe,
                 * so the target is what should name the folder — `{target}`
                 * and `{group}` say where a picture was going, which is the
                 * only thing you know about it a month later.
                 *
                 * `{kind}` stays, and stays the default when the caller sends
                 * no target, so an old template still means what it did.
                 */
                // Which slot this export was for. "unnamed" rather than empty
                // so an export made without one is still recorded as *something*
                // — an unattributed file in Pictures is exactly what quarry
                // exists to stop being the only trace.
                let target_id = req.p.get("target").and_then(|v| v.as_str()).unwrap_or("unnamed");
                let target_group = req.p.get("group").and_then(|v| v.as_str()).unwrap_or("");
                let expanded = util::expand_template(
                    template,
                    &[
                        ("kind", item.kind.clone()),
                        ("source", item.source.clone()),
                        ("slug", item.slug.clone()),
                        ("target", if target_id.is_empty() {
                            item.kind.clone()
                        } else {
                            target_id.to_string()
                        }),
                        ("group", if target_group.is_empty() {
                            item.kind.clone()
                        } else {
                            target_group.to_lowercase()
                        }),
                        ("w", recipe.width.to_string()),
                        ("h", recipe.height.to_string()),
                        ("ext", ext.to_string()),
                    ],
                );
                // Never silently overwrite a previous export.
                let path = util::unique_path(&expanded);

                if let Err(e) = util::write_atomic(&path, &encoded).await {
                    return Response::err(req.id, format!("write: {e}"));
                }

                // Exporting for a target is the closest quarry gets to knowing
                // what you put where — recorded as "for this slot", not as
                // "in it", until something confirms otherwise.
                self.catalog
                    .lock()
                    .await
                    .slot_set(&target_id, &item.id, &path.to_string_lossy(), false);

                self.log(format_args!(
                    "export {id} -> {} ({})",
                    path.display(),
                    util::human_bytes(encoded.len() as u64)
                ));

                Response::ok(
                    req.id,
                    serde_json::json!({
                        "path": path.to_string_lossy(),
                        "bytes": encoded.len(),
                        "width": recipe.width,
                        "height": recipe.height,
                        "recipe": recipe,
                        "human": util::human_bytes(encoded.len() as u64),
                    }),
                )
            }

            /*
             * Hide a row for good.
             *
             * The UI has had a Hide button since the detail page existed and
             * nothing behind it: hiding lasted until the next query. It is a
             * row in its own table now, so it survives both a restart and a
             * re-crawl that would otherwise add the same picture straight back.
             */
            "hide" => {
                let id = req.p.get("id").and_then(|v| v.as_str()).unwrap_or_default();
                if id.is_empty() {
                    return Response::err(req.id, "no id".to_string());
                }
                let newly = self.catalog.lock().await.hide_by_hand(id);
                self.log(format_args!("hide {id}"));
                Response::ok(req.id, serde_json::json!({ "id": id, "hidden": newly }))
            }

            /*
             * WHAT EACH SOURCE IS SET TO, AND SETTING IT.
             *
             * `sources` already says what exists and what it holds; this says
             * what you have decided about it. Kept as its own method rather
             * than folded in, because one is a fact about the catalogue and
             * the other is a preference — and the UI reads the first
             * constantly and writes the second rarely.
             */
            "sourcePrefs" => {
                let prefs = crate::prefs::Prefs::load();
                let all = sources::all();

                let rows: Vec<serde_json::Value> = all
                    .iter()
                    .map(|source| {
                        let id = source.id();
                        let mine = prefs.for_source(id);
                        serde_json::json!({
                            "id": id,
                            "category": source.category(),
                            "enabled": mine.enabled,
                            "pages": mine.pages,
                            "weight": mine.weight,
                            "video": source.capabilities().video,
                        })
                    })
                    .collect();

                Response::ok(
                    req.id,
                    serde_json::json!({
                        "sources": rows,
                        "blend": prefs.blend,
                        "seed": prefs.seed,
                        "adult": prefs.show_adult,
                        "path": crate::prefs::Prefs::path().display().to_string(),
                    }),
                )
            }

            "setSourcePrefs" => {
                let mut prefs = crate::prefs::Prefs::load();

                if let Some(id) = req.p.get("id").and_then(|v| v.as_str()) {
                    let entry = prefs.sources.entry(id.to_string()).or_default();
                    if let Some(on) = req.p.get("enabled").and_then(|v| v.as_bool()) {
                        entry.enabled = on;
                    }
                    if let Some(pages) = req.p.get("pages").and_then(|v| v.as_u64()) {
                        // Ten pages of one source is already a lot to ask of it.
                        entry.pages = (pages as u32).min(10);
                    }
                    if let Some(weight) = req.p.get("weight").and_then(|v| v.as_i64()) {
                        entry.weight = weight.clamp(-10, 10) as i32;
                    }
                }
                if let Some(blend) = req.p.get("blend").and_then(|v| v.as_str()) {
                    prefs.blend = blend.to_string();
                }
                if let Some(seed) = req.p.get("seed").and_then(|v| v.as_u64()) {
                    prefs.seed = seed;
                }
                let adult_changed = match req.p.get("adult").and_then(|v| v.as_bool()) {
                    Some(on) if on != prefs.show_adult => {
                        prefs.show_adult = on;
                        true
                    }
                    _ => false,
                };

                // The open catalogue is told at once, so the next query obeys the
                // new setting — a switch that needed a restart to take effect would
                // be a switch nobody could trust either.
                if adult_changed {
                    self.catalog.lock().await.set_show_adult(prefs.show_adult);
                }

                match prefs.save() {
                    Ok(()) => Response::ok(
                        req.id,
                        serde_json::json!({
                            "saved": true, "blend": prefs.blend, "seed": prefs.seed,
                            "adult": prefs.show_adult,
                        }),
                    ),
                    Err(e) => Response::err(req.id, e),
                }
            }

            /*
             * STOP REFUSING ROWS THE DAEMON HID BY ITSELF.
             *
             * A thumbnail that would not fetch used to hide its row forever,
             * whatever the reason — including a 429 from a host that was
             * merely busy. That bug is fixed at the source, but the rows it
             * already hid are still hidden, and there are usually thousands.
             * This forgets those decisions; the pictures come back on the next
             * crawl that finds them.
             *
             * It never touches a row somebody hid on purpose. That is what the
             * `reason` column is for.
             */
            "restore" => {
                let scope = req.p.get("scope").and_then(|v| v.as_str()).unwrap_or("auto");

                /*
                 * ONE LOCK, HELD ONCE, RELEASED BEFORE THE REPLY IS BUILT.
                 *
                 * Written first as `match self.catalog.lock().await.unhide(…)`
                 * with another `lock()` inside the arm — which deadlocks the
                 * daemon, because the guard from a match scrutinee lives until
                 * the end of the whole match. It answered nothing at all until
                 * the client gave up.
                 */
                let (before, result, after) = {
                    let mut catalog = self.catalog.lock().await;
                    let before = catalog.hidden_tally();
                    let result = catalog.unhide(scope);
                    let after = catalog.hidden_tally();
                    (before, result, after)
                };

                let tally = |rows: Vec<(String, usize)>| {
                    rows.into_iter()
                        .map(|(reason, items)| serde_json::json!({ "reason": reason, "items": items }))
                        .collect::<Vec<_>>()
                };

                match result {
                    Ok(removed) => {
                        self.log(format_args!("restored {removed} hidden rows ({scope})"));
                        Response::ok(
                            req.id,
                            serde_json::json!({
                                "restored": removed,
                                "scope": scope,
                                "before": tally(before),
                                "remaining": tally(after),
                            }),
                        )
                    }
                    Err(e) => Response::err(req.id, e),
                }
            }

            /*
             * Collections: keeping, as opposed to finding.
             *
             * One method for all of it because they are one idea — list what
             * exists, put something in, take something out. Adding to a
             * collection that does not exist creates it, since "put this in
             * Wallpapers" should not require making Wallpapers first.
             */
            /*
             * What is in each slot.
             *
             * `applied` is the honest distinction: quarry sets wallpapers
             * itself, so it knows those; a Steam avatar it can only export and
             * hope. Recording both, differently, beats pretending to know.
             */
            "slots" => {
                let action = req.p.get("action").and_then(|v| v.as_str()).unwrap_or("list");
                let catalog = self.catalog.lock().await;

                match action {
                    "list" => Response::ok(req.id, serde_json::json!({ "slots": catalog.slots() })),
                    "of" => {
                        let item = req.p.get("id").and_then(|v| v.as_str()).unwrap_or_default();
                        Response::ok(
                            req.id,
                            serde_json::json!({ "id": item, "slots": catalog.slots_of(item) }),
                        )
                    }
                    "applied" => {
                        let target = req.p.get("target").and_then(|v| v.as_str()).unwrap_or_default();
                        let item = req.p.get("id").and_then(|v| v.as_str()).unwrap_or_default();
                        let path = req.p.get("path").and_then(|v| v.as_str()).unwrap_or_default();
                        if target.is_empty() || item.is_empty() {
                            return Response::err(req.id, "need a target and an id".to_string());
                        }
                        catalog.slot_set(target, item, path, true);
                        self.log(format_args!("applied {item} to {target}"));
                        Response::ok(req.id, serde_json::json!({ "slots": catalog.slots() }))
                    }
                    other => Response::err(req.id, format!("unknown action: {other}")),
                }
            }

            /*
             * TAKE IN A FILE THAT IS ALREADY ON THIS MACHINE.
             *
             * Dropping a picture onto the board has to put it somewhere, and
             * the honest somewhere is the catalogue: it then gets a thumbnail,
             * a dominant colour and a phash like everything else, and it can be
             * found again by searching rather than only by remembering which
             * board it is on. A board of pictures that exist only on that board
             * would be a second, worse library.
             *
             * It is the `local` source's shape exactly — a `file://` row — so
             * nothing downstream needs to know a human dropped this one.
             */
            "adopt" => {
                let path = req.p.get("path").and_then(|v| v.as_str()).unwrap_or_default();
                let path = path.strip_prefix("file://").unwrap_or(path);
                // Percent-decoding, because a drag from a file manager sends a
                // URI and "My Pictures" arrives as "My%20Pictures".
                let decoded = percent_decode(path);
                let file = std::path::Path::new(&decoded);
                if !file.is_file() {
                    return Response::err(req.id, format!("not a file: {decoded}"));
                }

                let (w, h) = ::image::image_dimensions(file).unwrap_or((0, 0));
                let name = file
                    .file_stem()
                    .and_then(|n| n.to_str())
                    .unwrap_or("dropped")
                    .to_string();
                let url = format!("file://{decoded}");
                let mut item = scrape::normalize("local", &decoded, &name, &url, &url, &url, w, h, Vec::new());
                item.bytes = std::fs::metadata(file).map(|m| m.len()).unwrap_or(0);
                if let Some(dir) = file.parent().and_then(|p| p.file_name()).and_then(|d| d.to_str()) {
                    item.tags.push(dir.to_lowercase());
                }

                // What the client already knows about the file it is handing
                // over: a lens reading an adult board marks every row it takes,
                // and the blur and "hide them" settings then have something to
                // act on. An older daemon ignores these and nothing breaks.
                if req.p.get("nsfw").and_then(|v| v.as_bool()).unwrap_or(false) {
                    item.nsfw = true;
                }
                if let Some(extra) = req.p.get("tags").and_then(|v| v.as_array()) {
                    for tag in extra.iter().filter_map(|t| t.as_str()) {
                        let tag = tag.to_lowercase();
                        if !tag.is_empty() && !item.tags.contains(&tag) {
                            item.tags.push(tag);
                        }
                    }
                }
                if let Some(page) = req.p.get("page_url").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
                    item.page_url = page.to_string();
                }
                if let Some(title) = req.p.get("title").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
                    item.title = title.to_string();
                }

                let id = item.id.clone();
                let mut catalog = self.catalog.lock().await;
                catalog.add(vec![item]);
                match catalog.by_id(&id) {
                    Some(item) => Response::ok(req.id, serde_json::json!({ "item": item })),
                    None => Response::err(req.id, format!("could not take in {decoded}")),
                }
            }

            /*
             * Boards: arranging, as opposed to keeping.
             *
             * One method for the whole idea, the way `collections` is — list,
             * read one, place, remove, remember where the view was, delete.
             * The geometry is whatever the UI says it is; the daemon's job here
             * is to remember it exactly and to key it on an id that outlives a
             * re-crawl.
             */
            "boards" => {
                let action = req.p.get("action").and_then(|v| v.as_str()).unwrap_or("list");
                let name = req.p.get("name").and_then(|v| v.as_str()).unwrap_or_default();
                let item = req.p.get("id").and_then(|v| v.as_str()).unwrap_or_default();
                let num = |key: &str| req.p.get(key).and_then(|v| v.as_f64()).unwrap_or(0.0);
                let flag = |key: &str| req.p.get(key).and_then(|v| v.as_bool()).unwrap_or(false);

                let catalog = self.catalog.lock().await;
                match action {
                    "list" => Response::ok(req.id, serde_json::json!({ "boards": catalog.boards() })),
                    // A board can be made empty. `place` and `view` both create
                    // on demand, but naming one before you have anything to put
                    // on it is the normal way to start.
                    "create" => match catalog.board_view(name, 0.0, 0.0, 1.0) {
                        Ok(()) => {
                            self.emit("board.changed", serde_json::json!({ "name": name }));
                            Response::ok(req.id, serde_json::json!({ "boards": catalog.boards() }))
                        }
                        Err(e) => Response::err(req.id, e),
                    },
                    "items" => {
                        if name.is_empty() {
                            return Response::err(req.id, "need a board name".to_string());
                        }
                        Response::ok(
                            req.id,
                            serde_json::json!({
                                "name": name,
                                "items": catalog.board_items(name),
                                "containers": catalog.board_containers(name),
                            }),
                        )
                    }
                    "place" => {
                        if name.is_empty() || item.is_empty() {
                            return Response::err(req.id, "need a board name and an id".to_string());
                        }
                        match catalog.board_place(
                            name,
                            item,
                            num("x"),
                            num("y"),
                            num("w"),
                            num("h"),
                            num("angle"),
                            flag("hflip"),
                            flag("vflip"),
                            req.p.get("z").and_then(|v| v.as_i64()).unwrap_or(0),
                            flag("sharp"),
                            req.p.get("container").and_then(|v| v.as_i64()).unwrap_or(0),
                        ) {
                            Ok(()) => {
                                self.emit("board.changed", serde_json::json!({ "name": name }));
                                Response::ok(req.id, serde_json::json!({ "placed": true }))
                            }
                            Err(e) => Response::err(req.id, e),
                        }
                    }
                    "remove" => match catalog.board_remove(name, item) {
                        Ok(()) => {
                            self.emit("board.changed", serde_json::json!({ "name": name }));
                            Response::ok(
                                req.id,
                                serde_json::json!({ "items": catalog.board_items(name) }),
                            )
                        }
                        Err(e) => Response::err(req.id, e),
                    },
                    // Containers: the same one-method shape as the rest.
                    "container" => {
                        if name.is_empty() {
                            return Response::err(req.id, "need a board name".to_string());
                        }
                        let id = req.p.get("container").and_then(|v| v.as_i64()).unwrap_or(0);
                        let label = req.p.get("label").and_then(|v| v.as_str()).unwrap_or("");
                        match catalog.board_container_set(
                            name,
                            id,
                            num("x"),
                            num("y"),
                            req.p.get("w").and_then(|v| v.as_f64()).unwrap_or(600.0),
                            req.p.get("h").and_then(|v| v.as_f64()).unwrap_or(400.0),
                            label,
                            req.p.get("tint").and_then(|v| v.as_i64()).unwrap_or(0),
                        ) {
                            Ok(made) => {
                                self.emit("board.changed", serde_json::json!({ "name": name }));
                                Response::ok(
                                    req.id,
                                    serde_json::json!({
                                        "container": made,
                                        "containers": catalog.board_containers(name),
                                    }),
                                )
                            }
                            Err(e) => Response::err(req.id, e),
                        }
                    }
                    "uncontain" => {
                        let id = req.p.get("container").and_then(|v| v.as_i64()).unwrap_or(0);
                        match catalog.board_container_delete(name, id) {
                            Ok(()) => {
                                self.emit("board.changed", serde_json::json!({ "name": name }));
                                Response::ok(
                                    req.id,
                                    serde_json::json!({ "containers": catalog.board_containers(name) }),
                                )
                            }
                            Err(e) => Response::err(req.id, e),
                        }
                    }
                    "view" => match catalog.board_view(name, num("x"), num("y"), num("z")) {
                        Ok(()) => Response::ok(req.id, serde_json::json!({ "saved": true })),
                        Err(e) => Response::err(req.id, e),
                    },
                    "rename" => {
                        let to = req.p.get("to").and_then(|v| v.as_str()).unwrap_or_default();
                        if name.is_empty() || to.trim().is_empty() {
                            return Response::err(req.id, "need a board name and a new one".to_string());
                        }
                        match catalog.board_rename(name, to.trim()) {
                            Ok(()) => {
                                self.emit("board.changed", serde_json::json!({ "name": to.trim() }));
                                Response::ok(req.id, serde_json::json!({ "boards": catalog.boards() }))
                            }
                            Err(e) => Response::err(req.id, e),
                        }
                    }
                    "delete" => match catalog.board_delete(name) {
                        Ok(()) => {
                            self.emit("board.changed", serde_json::json!({ "name": name }));
                            Response::ok(req.id, serde_json::json!({ "boards": catalog.boards() }))
                        }
                        Err(e) => Response::err(req.id, e),
                    },
                    other => Response::err(req.id, format!("unknown action: {other}")),
                }
            }

            "collections" => {
                let action = req.p.get("action").and_then(|v| v.as_str()).unwrap_or("list");
                let name = req.p.get("name").and_then(|v| v.as_str()).unwrap_or_default();
                let item = req.p.get("id").and_then(|v| v.as_str()).unwrap_or_default();

                let catalog = self.catalog.lock().await;
                match action {
                    "list" => Response::ok(
                        req.id,
                        serde_json::json!({ "collections": catalog.collections() }),
                    ),
                    "of" => Response::ok(
                        req.id,
                        serde_json::json!({ "id": item, "collections": catalog.collections_of(item) }),
                    ),
                    "add" | "remove" => {
                        if name.is_empty() || item.is_empty() {
                            return Response::err(req.id, "need a name and an id".to_string());
                        }
                        match catalog.collection_set(name, item, action == "add") {
                            Ok(()) => {
                                self.log(format_args!("{action} {item} {} {name}", if action == "add" { "to" } else { "from" }));
                                Response::ok(
                                    req.id,
                                    serde_json::json!({
                                        "collections": catalog.collections(),
                                        "of": catalog.collections_of(item),
                                    }),
                                )
                            }
                            Err(e) => Response::err(req.id, e),
                        }
                    }
                    other => Response::err(req.id, format!("unknown action: {other}")),
                }
            }

            "sources" => {
                let catalog = self.catalog.lock().await;
                // The switch, read once for the section filter below.
                let show_adult = catalog.show_adult();
                // Kinds travel with sources: a filter panel wants both, with
                // counts, and asking twice for one screen of chrome is silly.
                Response::ok(
                    req.id,
                    serde_json::json!({
                        // An empty rail because there is nothing, or an empty
                        // rail because the file broke: not the same thing.
                        "damaged": catalog.damage(),
                        "sources": catalog.sources(),
                        // What each source suggests you start from.
                        /*
                         * PER SOURCE, and attributed.
                         *
                         * These were briefly merged into one app-wide taxonomy.
                         * That is wrong for what they are: a site's categories
                         * are ITS table of contents, they only mean anything
                         * while you are looking at that site, and merging them
                         * put a wall of profile-picture subjects in front of a
                         * wallpaper search. The client shows a source's list on
                         * that source's page and nowhere else.
                         */
                        "suggestions": sources::all()
                            .iter()
                            .flat_map(|s| {
                                sources::suggestion_groups(s.id()).into_iter().map(
                                    move |(group, terms)| {
                                        serde_json::json!({
                                            "source": s.id(),
                                            "group": group,
                                            "terms": terms,
                                        })
                                    },
                                )
                            })
                            .filter(|v| !v["terms"].as_array().map(|a| a.is_empty()).unwrap_or(true))
                            .collect::<Vec<_>>(),
                        // A site's own sections, attributed the same way its
                        // suggestions are: they only mean anything on that site.
                        /*
                         * Adult sections are DROPPED HERE, not marked for the
                         * client to hide. A category the client is told about
                         * and asked not to show is one forgotten `visible:`
                         * away from being shown; one it never hears about
                         * cannot be.
                         */
                        "sections": sources::all()
                            .iter()
                            .flat_map(|s| {
                                let id = s.id();
                                s.sections().into_iter().map(move |(group, label, q, adult)| {
                                    (id, group, label, q, adult)
                                })
                            })
                            .filter(|(_, _, _, _, adult)| show_adult || !adult)
                            .map(|(id, group, label, q, _)| {
                                serde_json::json!({
                                    "source": id, "group": group, "label": label, "q": q,
                                })
                            })
                            .collect::<Vec<_>>(),
                        "kinds": catalog.kinds(),
                        "families": catalog.families(),
                    }),
                )
            }

            /*
             * CLEAR CACHED THUMBNAILS BY EXTENSION.
             *
             * `thumb_ladder` used to write every thumbnail as lossless WebP;
             * it now picks JPEG or PNG per image (image::thumb_format). Old
             * files are not deleted automatically — THUMB_EXTS still finds and
             * serves them — because mass-deleting them (15,573 files, most at
             * the 640px rung) means re-fetching ~12,700 images from public
             * boorus, which is exactly how this gets rate-limited.
             *
             * This is the explicit, opt-in way to reclaim that space: `ext`
             * (default "webp", the legacy format) removes every file under
             * the quarry thumb cache ending in `.<ext>`. Nothing runs unless
             * this is called.
             */
            /*
             * WHAT QUARRY IS KEEPING ON YOUR DISK.
             *
             * There was no way to ask. The caches are trimmed on a schedule
             * and the budgets were environment variables with the defaults
             * compiled in, so "how much is quarry storing" was a question you
             * answered with `du` and "may it keep less" was one you answered
             * by editing a unit file.
             *
             * Walking 58,000 thumbnail files takes long enough to be worth not
             * doing twice in a row, so the answer is held for twenty seconds —
             * a settings panel that polls must not turn into a disk crawler.
             */
            /*
             * THE VALIDATOR'S ANSWER: which sources are working.
             *
             * Sorted worst first, because a list of sixty sources sorted by
             * name is a list nobody reads. A source that has never been asked
             * appears as unknown rather than as working — claiming health for
             * something never tested is how a validator becomes decoration.
             */
            "health" => {
                let table = self.health.lock().await.clone();
                let mut rows: Vec<serde_json::Value> = sources::all()
                    .iter()
                    .map(|source| {
                        let id = source.id().to_string();
                        match table.get(&id) {
                            Some(h) => serde_json::json!({
                                "id": id,
                                "state": if h.ok { "ok" } else { "failing" },
                                "status": h.status,
                                "detail": h.detail,
                                "rows": h.rows,
                                "fails": h.fails,
                                "lastOk": h.last_ok,
                                "lastFail": h.last_fail,
                                "checks": h.checks,
                            }),
                            None => serde_json::json!({
                                "id": id,
                                "state": "unknown",
                                "status": 0,
                                "detail": "",
                                "rows": 0,
                                "fails": 0,
                                "lastOk": 0,
                                "lastFail": 0,
                                "checks": 0,
                            }),
                        }
                    })
                    .collect();
                rows.sort_by_key(|row| {
                    let state = row["state"].as_str().unwrap_or("");
                    let fails = row["fails"].as_u64().unwrap_or(0);
                    // failing (most failures first), then unknown, then ok
                    match state {
                        "failing" => (0i64, -(fails as i64)),
                        "unknown" => (1, 0),
                        _ => (2, 0),
                    }
                });
                let failing = rows.iter().filter(|r| r["state"] == "failing").count();
                Response::ok(
                    req.id,
                    serde_json::json!({
                        "sources": rows,
                        "failing": failing,
                        "log": self.health_log,
                    }),
                )
            }

            "storage" => {
                let root = self.thumb_dir.trim_end_matches("/thumbs").to_string();
                // The catalogue can report itself; it is the one thing here
                // that is not a cache.
                let (db_path, db_bytes) = {
                    let catalog = self.catalog.lock().await;
                    (catalog.db_path(), catalog.db_bytes())
                };
                let prefs = crate::prefs::Prefs::load();
                let report = tokio::task::spawn_blocking(move || {
                    let mut dirs = Vec::new();
                    let mut total = 0u64;
                    for (name, label) in [
                        ("thumbs", "Thumbnails"),
                        ("media", "Video and audio"),
                        ("http", "Pages and API answers"),
                        ("frames", "Video frames"),
                        ("models", "3D models"),
                        ("lens", "Lens data"),
                    ] {
                        let (bytes, files) = measure_dir(&format!("{root}/{name}"));
                        total += bytes;
                        dirs.push(serde_json::json!({
                            "id": name,
                            "label": label,
                            "bytes": bytes,
                            "files": files,
                        }));
                    }
                    serde_json::json!({
                        "dirs": dirs,
                        "cacheBytes": total,
                        "catalogueBytes": db_bytes,
                        "cataloguePath": db_path,
                        "root": root,
                        "budgets": {
                            "thumbsMb": prefs.thumb_budget_mb,
                            "mediaMb": prefs.media_budget_mb,
                            "httpMb": prefs.http_budget_mb,
                        },
                    })
                })
                .await
                .unwrap_or_else(|_| serde_json::json!({}));
                Response::ok(req.id, report)
            }

            /*
             * Change what the caches are allowed to hold, and act on it now.
             *
             * Saved rather than applied-and-forgotten: the hourly trim reads
             * the same numbers, so a limit set here is the limit from now on.
             * Zero is "no limit" and is honoured as such.
             */
            "set_budget" => {
                let thumbs = req.p.get("thumbsMb").and_then(|v| v.as_u64());
                let media = req.p.get("mediaMb").and_then(|v| v.as_u64());
                let http = req.p.get("httpMb").and_then(|v| v.as_u64());
                {
                    let mut prefs = crate::prefs::Prefs::load();
                    if let Some(mb) = thumbs {
                        prefs.thumb_budget_mb = mb;
                    }
                    if let Some(mb) = media {
                        prefs.media_budget_mb = mb;
                    }
                    if let Some(mb) = http {
                        prefs.http_budget_mb = mb;
                    }
                    if let Err(e) = prefs.save() {
                        return Response::err(req.id, format!("save prefs: {e}"));
                    }
                }
                let prefs = crate::prefs::Prefs::load();
                let root = self.thumb_dir.trim_end_matches("/thumbs").to_string();
                let freed = tokio::task::spawn_blocking(move || {
                    let mut freed = 0u64;
                    if prefs.thumb_budget_mb > 0 {
                        freed += trim_cache_dir(
                            &format!("{root}/thumbs"),
                            prefs.thumb_budget_mb.saturating_mul(1024 * 1024),
                        );
                    }
                    if prefs.media_budget_mb > 0 {
                        freed += trim_cache_dir(
                            &format!("{root}/media"),
                            prefs.media_budget_mb.saturating_mul(1024 * 1024),
                        );
                    }
                    if prefs.http_budget_mb > 0 {
                        freed += trim_cache_dir(
                            &format!("{root}/http"),
                            prefs.http_budget_mb.saturating_mul(1024 * 1024),
                        );
                    }
                    freed
                })
                .await
                .unwrap_or(0);
                Response::ok(req.id, serde_json::json!({ "bytesFreed": freed }))
            }

            /*
             * Empty one cache, or all of them, now.
             *
             * Nothing here is irreplaceable — every one of these directories
             * is rebuilt by browsing — which is what makes a delete button
             * safe to offer at all. The catalogue itself is NOT in this list
             * for the same reason: it is the only thing that is not a copy.
             */
            /*
             * START OVER — every crawled row, out.
             *
             * Behind a `confirm` flag on purpose. This is the one request that
             * destroys something no re-crawl brings back in the same order,
             * and a typo'd method name should not be able to do it.
             */
            "catalogue_clear" => {
                if req.p.get("confirm").and_then(|v| v.as_bool()) != Some(true) {
                    return Response::err(req.id, "catalogue_clear needs confirm: true".to_string());
                }
                let mut catalog = self.catalog.lock().await;
                let before = catalog.db_bytes();
                match catalog.empty_catalogue() {
                    Ok(removed) => {
                        let after = catalog.db_bytes();
                        self.log(format_args!(
                            "catalogue emptied: {removed} rows, {} bytes freed",
                            before.saturating_sub(after)
                        ));
                        Response::ok(
                            req.id,
                            serde_json::json!({
                                "removed": removed,
                                "bytesFreed": before.saturating_sub(after),
                            }),
                        )
                    }
                    Err(e) => Response::err(req.id, e),
                }
            }

            "cache_clear" => {
                let what = req.p.get("what").and_then(|v| v.as_str()).unwrap_or("").to_string();
                let known = ["thumbs", "media", "http", "frames", "models", "lens"];
                if what != "all" && !known.contains(&what.as_str()) {
                    return Response::err(
                        req.id,
                        format!("unknown cache: {what} — have {} or all", known.join(", ")),
                    );
                }
                let root = self.thumb_dir.trim_end_matches("/thumbs").to_string();
                let asked = what.clone();
                let (removed, freed) = tokio::task::spawn_blocking(move || {
                    let mut removed = 0u64;
                    let mut freed = 0u64;
                    for name in known {
                        if asked != "all" && asked != name {
                            continue;
                        }
                        let (r, f) = empty_dir(&format!("{root}/{name}"));
                        removed += r;
                        freed += f;
                    }
                    (removed, freed)
                })
                .await
                .unwrap_or((0, 0));
                self.log(format_args!("cleared {what}: {removed} files, {freed} bytes"));
                Response::ok(req.id, serde_json::json!({ "removed": removed, "bytesFreed": freed }))
            }

            "thumbs_clear" => {
                let ext = req.p.get("ext").and_then(|v| v.as_str()).unwrap_or("webp").to_string();
                let suffix = format!(".{ext}");
                let mut removed = 0u64;
                let mut bytes_freed = 0u64;
                let mut dir = match tokio::fs::read_dir(&self.thumb_dir).await {
                    Ok(d) => d,
                    Err(e) => return Response::err(req.id, format!("read {}: {e}", self.thumb_dir)),
                };
                while let Ok(Some(entry)) = dir.next_entry().await {
                    let name = entry.file_name();
                    if !name.to_string_lossy().ends_with(&suffix) {
                        continue;
                    }
                    let size = entry.metadata().await.map(|m| m.len()).unwrap_or(0);
                    if tokio::fs::remove_file(entry.path()).await.is_ok() {
                        removed += 1;
                        bytes_freed += size;
                    }
                }
                self.log(format_args!(
                    "thumbs_clear ext={ext} removed={removed} bytesFreed={bytes_freed}"
                ));
                Response::ok(
                    req.id,
                    serde_json::json!({ "ext": ext, "removed": removed, "bytesFreed": bytes_freed }),
                )
            }

            "stats" => {
                let catalog = self.catalog.lock().await;
                Response::ok(
                    req.id,
                    serde_json::json!({
                        "items": catalog.len(),
                        "broken": catalog.broken_count(),
                        "queries": catalog.queries,
                        "uptimeMs": self.started.elapsed().as_millis() as u64,
                        "backend": if catalog.persistent() { "live" } else { "mock" },
                        "catalogue": catalog.db_path(),
                        "catalogueBytes": catalog.db_bytes(),
                        "rowsOnDisk": catalog.rows_on_disk(),
                        // Actionable now that the reasons are told apart: rows
                        // hidden by a fetch failure can be restored.
                        "hidden": catalog.hidden_tally()
                            .iter()
                            .map(|(r, n)| serde_json::json!({ "reason": r, "items": n }))
                            .collect::<Vec<_>>(),
                    }),
                )
            }

            other => Response::err(req.id, format!("unknown method: {other}")),
        }
    }
}

/*
 * One task per request, not one at a time.
 *
 * The obvious loop — read a frame, await the handler, write the answer — makes
 * every request wait for the one before it. That is invisible for a query and
 * ruinous for a thumbnail: each `thumb` fetches from the network, so a screen
 * of twenty tiles filled one after another, and a `query` issued while they
 * were arriving sat behind all of them. The app felt slow while the renderer
 * was idle at full frame rate.
 *
 * Requests carry ids and responses echo them, so answering out of order is
 * already what the protocol describes. A semaphore bounds how much runs at
 * once, because the point is to overlap latency, not to open fifty sockets to
 * someone's image host.
 */
impl Server {
    /// Tell every connected client that something changed. Fire and forget:
    /// with no listeners this is a no-op, which is the normal case.
    fn emit(&self, method: &str, payload: serde_json::Value) {
        let event = protocol::Event {
            t: "ev",
            m: method.to_string(),
            p: payload,
        };
        if let Ok(mut line) = serde_json::to_string(&event) {
            line.push('\n');
            let _ = self.events.send(line);
        }
    }
}

async fn serve(server: Arc<Server>, stream: UnixStream) {
    let (read_half, write_half) = stream.into_split();
    let writer = Arc::new(Mutex::new(write_half));
    let mut lines = BufReader::new(read_half).lines();

    // Events, pushed down this connection for as long as it lives. Through the
    // same writer mutex as the responses, so an event can never land in the
    // middle of one.
    let pump = {
        let writer = Arc::clone(&writer);
        let mut rx = server.events.subscribe();
        tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(line) => {
                        let mut out = writer.lock().await;
                        if out.write_all(line.as_bytes()).await.is_err() {
                            return;              // the client went away
                        }
                    }
                    // Lagged: frames were missed while this client was busy.
                    // Nothing to recover — an event only says "ask again".
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(_) => return,
                }
            }
        })
    };

    /*
     * THUMBNAILS A CLIENT NO LONGER WANTS CAN BE WITHDRAWN.
     *
     * A new search replaces every tile, but the old tiles' `thumb` requests
     * still held the shared permits while they waited on image hosts, and the
     * new screen's queued behind them: measured, rows on screen at 0.56 s and
     * the first picture drawn at 2.5 s. `cancel {ids}` aborts those by request
     * id; an aborted request gets no answer, and the client forgets it.
     */
    let inflight: Arc<std::sync::Mutex<std::collections::HashMap<u64, tokio::task::AbortHandle>>> =
        Arc::default();

    while let Ok(Some(line)) = lines.next_line().await {
        if line.trim().is_empty() {
            continue;
        }
        let parsed = serde_json::from_str::<Request>(&line);
        if let Some(req) = parsed.as_ref().ok().filter(|r| r.m == "cancel") {
            let mut aborted = 0;
            {
                let mut held = inflight.lock().unwrap_or_else(|e| e.into_inner());
                for id in req.p.get("ids").and_then(|v| v.as_array()).into_iter().flatten() {
                    if let Some(handle) = id.as_u64().and_then(|id| held.remove(&id)) {
                        handle.abort();
                        aborted += 1;
                    }
                }
            }
            let response = Response::ok(req.id, serde_json::json!({ "cancelled": aborted }));
            if let Ok(mut buf) = serde_json::to_vec(&response) {
                buf.push(b'\n');
                let _ = writer.lock().await.write_all(&buf).await;
            }
            continue;
        }
        let cancellable = parsed.as_ref().ok().filter(|r| r.m == "thumb").map(|r| r.id);

        /*
         * Two classes of request, and only one of them may overtake.
         *
         * `query` replaces the daemon's current result and `items` reads it, so
         * letting those race means a page answered from a query the client has
         * not sent yet — which is exactly what happened the moment this became
         * concurrent. They stay in order, per connection.
         *
         * The slow ones are the network ones, and none of them touch the result:
         * a thumbnail, an export, a crawl. Those run in parallel, which is the
         * whole point — a screen of tiles fills at once instead of one at a
         * time.
         */
        let ordered = matches!(
            serde_json::from_str::<Request>(&line).map(|r| r.m),
            Ok(ref m) if matches!(m.as_str(), "query" | "items" | "item" | "sources" | "stats" | "hello" | "extend")
        );

        let server = Arc::clone(&server);
        let writer = Arc::clone(&writer);

        let task = async move {
            let slow = matches!(
                serde_json::from_str::<Request>(&line).map(|r| r.m).as_deref(),
                Ok("more" | "search" | "backfill" | "media" | "similar" | "resolve" | "enrich" | "doctor" | "reverse" | "adopt" | "random")
            );
            /*
             * THE ORDERED ONES TAKE NO PERMIT.
             *
             * They answer from the catalogue in a millisecond and already run
             * one at a time per connection. Behind the shared permits they
             * queued after a screenful of thumbnails, each waiting on some
             * image host: measured, an `extend` sent 1 s into a search was
             * still unanswered at 5 s, so the wall sat still while results
             * were filed underneath it.
             */
            let _permit = if ordered {
                None
            } else if slow {
                Some(server.background.acquire().await)
            } else {
                Some(server.concurrency.acquire().await)
            };

            let response = match serde_json::from_str::<Request>(&line) {
                Ok(req) => server.handle(req).await,
                // A frame that will not parse has no id to echo, so it answers
                // on id 0 rather than vanishing.
                Err(e) => Response::err(0, format!("malformed frame: {e}")),
            };

            let mut buf = match serde_json::to_vec(&response) {
                Ok(b) => b,
                Err(e) => {
                    server.log(format_args!("failed to encode response: {e}"));
                    return;
                }
            };
            buf.push(b'\n');

            // One writer, so two answers cannot interleave into one line.
            let mut out = writer.lock().await;
            let _ = out.write_all(&buf).await;
        };

        if ordered {
            task.await;
        } else {
            let handle = tokio::spawn(task);
            if let Some(id) = cancellable {
                let mut held = inflight.lock().unwrap_or_else(|e| e.into_inner());
                // Finished ones are swept now and then rather than each removing
                // itself: a handful of stale handles cost nothing.
                if held.len() > 256 {
                    held.retain(|_, h| !h.is_finished());
                }
                held.insert(id, handle.abort_handle());
            }
        }
    }

    // The read half is done, so this connection is over. Without this the pump
    // would sit on the channel forever holding the write half open.
    pump.abort();
}

/// Fetch one source's page, whichever verb it speaks.
///
/// GraphQL sources have no URL to vary and answer a GET with a 404, so an
/// adapter that returns a body is POSTed instead. Every call site goes through
/// here so a new POST source needs no change outside its own file.
/*
 * HOW MANY PAGES A SOURCE IS WORTH THIS ROUND.
 *
 * `fresh` is its rolling average of NEW rows per page for this query. A source
 * still bringing pages of new rows gets the whole budget; one that has been
 * crawled to its end answers with rows the catalogue already has, and a page
 * of those costs a request and gives nothing. Never zero: one page keeps it in
 * the round, so it recovers by itself the moment it posts again.
 */
fn pages_budget(fresh: Option<f32>, pages: u32) -> u32 {
    match fresh {
        // Never asked for this query: let it prove itself at full depth.
        None => pages,
        Some(fresh) if fresh >= 8.0 => pages,
        Some(fresh) if fresh >= 2.0 => pages.div_ceil(2).max(2).min(pages),
        Some(fresh) if fresh >= 0.5 => 2.min(pages),
        Some(_) => 1,
    }
}

#[cfg(test)]
mod paging_budget_tests {
    use super::pages_budget;

    #[test]
    fn depth_follows_what_a_source_actually_brings() {
        assert_eq!(pages_budget(None, 8), 8, "an unknown source gets a real chance");
        assert_eq!(pages_budget(Some(40.0), 8), 8, "a busy source keeps the budget");
        assert_eq!(pages_budget(Some(3.0), 8), 4);
        assert_eq!(pages_budget(Some(1.0), 8), 2);
        assert_eq!(pages_budget(Some(0.0), 8), 1, "a dry source is still asked, once");
    }

    #[test]
    fn a_small_budget_is_never_inflated() {
        for fresh in [None, Some(40.0), Some(3.0), Some(1.0), Some(0.0)] {
            assert!(pages_budget(fresh, 1) == 1, "{fresh:?} asked for more than the caller allowed");
        }
        assert!(pages_budget(Some(3.0), 2) <= 2);
    }
}

/*
 * A CACHE IS A BUDGET, NOT A PILE.
 *
 * Measured on this machine: 5.6 GB of thumbnails, 424 MB of cached pages and
 * 107 MB of video on a disk with 1.5 GB left — at which point SQLite answers
 * "disk I/O error" and the daemon will not start at all. Nothing here is
 * precious: every file can be fetched again. So each cache gets a ceiling and
 * the oldest files go first.
 *
 * Both budgets can be set from the environment, because the right number
 * depends on the disk this runs on:
 *   QUARRY_THUMB_BUDGET_MB (default 3000)
 *   QUARRY_MEDIA_BUDGET_MB (default 512)
 */
fn budget_from_env(name: &str, default_mb: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(default_mb)
        .saturating_mul(1024 * 1024)
}

/// Trim a cache directory to `budget` bytes, oldest files first. Returns the
/// bytes freed. Reads the directory once; on a cache of a few hundred thousand
/// files that is seconds, which is why it runs at startup and on a timer
/// rather than after every write.
/// How much a cache directory holds: bytes and files, one level deep.
fn measure_dir(dir: &str) -> (u64, u64) {
    let Ok(entries) = std::fs::read_dir(dir) else { return (0, 0) };
    let mut bytes = 0u64;
    let mut files = 0u64;
    for entry in entries.flatten() {
        match entry.metadata() {
            Ok(meta) if meta.is_file() => {
                bytes += meta.len();
                files += 1;
            }
            // A cache with subdirectories (the lens store) counts what is in
            // them rather than reporting zero.
            Ok(meta) if meta.is_dir() => {
                let (b, f) = measure_dir(&entry.path().to_string_lossy());
                bytes += b;
                files += f;
            }
            _ => {}
        }
    }
    (bytes, files)
}

/// Delete everything in a cache directory. Returns (files, bytes).
fn empty_dir(dir: &str) -> (u64, u64) {
    let Ok(entries) = std::fs::read_dir(dir) else { return (0, 0) };
    let mut removed = 0u64;
    let mut freed = 0u64;
    for entry in entries.flatten() {
        let Ok(meta) = entry.metadata() else { continue };
        if meta.is_dir() {
            let (r, f) = empty_dir(&entry.path().to_string_lossy());
            removed += r;
            freed += f;
            let _ = std::fs::remove_dir(entry.path());
            continue;
        }
        let size = meta.len();
        if std::fs::remove_file(entry.path()).is_ok() {
            removed += 1;
            freed += size;
        }
    }
    (removed, freed)
}

fn trim_cache_dir(dir: &str, budget: u64) -> u64 {
    let Ok(entries) = std::fs::read_dir(dir) else { return 0 };
    let mut files: Vec<(std::time::SystemTime, u64, std::path::PathBuf)> = entries
        .flatten()
        .filter_map(|e| {
            let meta = e.metadata().ok()?;
            meta.is_file().then(|| (meta.modified().unwrap_or(std::time::UNIX_EPOCH), meta.len(), e.path()))
        })
        .collect();
    let mut total: u64 = files.iter().map(|f| f.1).sum();
    if total <= budget {
        return 0;
    }
    files.sort_by_key(|f| f.0);
    let mut freed = 0u64;
    for (_, len, path) in files {
        if total <= budget {
            break;
        }
        if std::fs::remove_file(&path).is_ok() {
            total = total.saturating_sub(len);
            freed += len;
        }
    }
    freed
}

/// Keep the media cache under `budget` bytes, oldest files first. Videos are
/// large and re-fetchable; a cache that only grows fills a disk.
fn trim_media_cache(dir: &str, budget: u64) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut files: Vec<(std::time::SystemTime, u64, std::path::PathBuf)> = entries
        .flatten()
        .filter_map(|e| {
            let meta = e.metadata().ok()?;
            meta.is_file().then(|| (meta.modified().unwrap_or(std::time::UNIX_EPOCH), meta.len(), e.path()))
        })
        .collect();
    let mut total: u64 = files.iter().map(|f| f.1).sum();
    files.sort_by_key(|f| f.0);
    for (_, len, path) in files {
        if total <= budget {
            break;
        }
        if std::fs::remove_file(&path).is_ok() {
            total = total.saturating_sub(len);
        }
    }
}

/// The video a page declares: og:video, a JSON-LD contentUrl, or a <video>/
/// <source> element. Returns (url, duration in seconds).
/*
 * A tube page's real streams.
 *
 * These sites put a preview clip in `og:video` — 90 kB, a few seconds — and
 * the actual video in a `flashvars_<id>` blob as one entry per quality, HLS
 * now that the mp4 list comes back empty. Taking the first playable URL on the
 * page gets the preview, so the blob is read first and wins.
 */
/*
 * EPORNER HANDS ITS FILES OUT SEPARATELY.
 *
 * The page carries `vid` and a 32-character `hash`, and the player asks
 * /xhr/video/<vid> for the sources — with the hash re-encoded, eight hex digits
 * at a time, as base 36. Asking with the raw hash answers `available: false`,
 * which is why a generic scrape of the page found nothing and the viewer said
 * the host would not serve it.
 */
/*
 * THE PORNHUB FAMILY KEEPS THE REAL FILE BEHIND ONE MORE REQUEST.
 *
 * YouPorn, pornhub, redtube and tube8 all embed a `mediaDefinition` array, and
 * the entries do not hold a file — they hold an ENDPOINT:
 *
 *     "mediaDefinitions":[{"format":"hls","videoUrl":"https://www.youporn.com/media/hls/?s=…"},
 *                         {"format":"mp4","videoUrl":"https://www.youporn.com/media/mp4/?s=…"}]
 *
 * Asking the mp4 one answers with the actual qualities:
 *
 *     [{"quality":"1080","videoUrl":"https://ev-ph.ypncdn.com/…/1080P_4000K_<id>.mp4?…"}, …]
 *
 * None of that has a media extension on it, so the page scan walked straight
 * past it and fell through to whatever `.mp4` WAS written in the markup — which
 * on these sites is the related-videos rail: 37 hover previews named
 * `…_fb.mp4`, every one a different video and about nine seconds long. That is
 * why YouPorn played a nine-second clip of something else entirely.
 *
 * `mp4` is preferred over `hls` deliberately. The HLS entry is a playlist whose
 * segments are fetched separately and signed per request, so the stream proxy —
 * which rewrites one URL, not a playlist — serves an empty body for it.
 */
/*
 * WHERE A MODEL'S FILES ARE DESCRIBED, given only a catalogue row.
 *
 * A row knows its source and its id; what it does NOT know is where to get the
 * geometry, because the `url` column holds the thumbnail every other family
 * uses it for. So the manifest is derived per source, and a source that cannot
 * hand over a model says so in words rather than failing somewhere deeper with
 * a parse error about a PNG.
 */
fn model_manifest_url(source: &str, id: &str, url: &str) -> Result<String, String> {
    let slug = id.rsplit(':').next().unwrap_or_default();
    match source {
        // api.polyhaven.com/files/<slug> → { gltf: { 1k: { gltf: { url, include } } } }
        s if s.starts_with("polyhaven") => {
            if slug.is_empty() {
                return Err(format!("no asset name in {id}"));
            }
            Ok(format!("https://api.polyhaven.com/files/{slug}"))
        }
        /*
         * Sketchfab is in the catalogue as a BROWSE source — see PLAN.md. Its
         * download endpoint needs an OAuth token per user, and the models are
         * individually licensed, so there is nothing to fetch here however the
         * row looks.
         */
        s if s.starts_with("sketchfab") => Err(
            "Sketchfab models can only be browsed here — opening one needs a Sketchfab account."
                .to_string(),
        ),
        _ => {
            // An unknown source may still carry a real manifest. An image URL
            // certainly is not one, and saying so beats a parse error.
            let lower = url.to_ascii_lowercase();
            let image = [".png", ".jpg", ".jpeg", ".webp", ".gif"]
                .iter()
                .any(|ext| lower.split(['?', '#']).next().unwrap_or("").ends_with(ext));
            if image || url.is_empty() {
                return Err(format!("{source} does not say where its models are"));
            }
            Ok(url.to_string())
        }
    }
}

fn media_definition_request(html: &str) -> Option<String> {
    let text = html.replace("\\/", "/");
    // The mp4 entry, wherever it sits in the array.
    let pattern = r#""format"\s*:\s*"mp4"\s*,\s*"videoUrl"\s*:\s*"([^"]+)""#;
    let first = |pattern: &str| -> Option<String> {
        scrape::regex_all(&text, pattern, 1).ok()?.into_iter().next()
    };
    // Some pages write the pair the other way round.
    let direct = first(pattern).or_else(|| {
        first(r#""videoUrl"\s*:\s*"([^"]+)"\s*,\s*"format"\s*:\s*"mp4""#)
    })?;
    let url = direct.replace("\\/", "/");
    // An endpoint, not a file: a direct file is already handled by the scan.
    if !url.starts_with("http") || url.contains(".mp4") {
        return None;
    }
    Some(url)
}

/// The qualities that endpoint answers with, best first.
fn media_definition_videos(json: &str) -> Vec<(String, String)> {
    let Ok(parsed) = serde_json::from_str::<serde_json::Value>(json) else {
        return Vec::new();
    };
    let Some(list) = parsed.as_array() else {
        return Vec::new();
    };
    let mut out: Vec<(String, String)> = Vec::new();
    for entry in list {
        let url = entry.get("videoUrl").and_then(|v| v.as_str()).unwrap_or_default();
        if !url.starts_with("http") {
            continue;
        }
        let quality = entry.get("quality").and_then(|v| match v {
            serde_json::Value::String(s) => Some(s.clone()),
            serde_json::Value::Number(n) => Some(n.to_string()),
            _ => None,
        });
        let label = match quality {
            Some(q) if !q.is_empty() => format!("{}p", q.trim_end_matches('p')),
            _ => "Original".to_string(),
        };
        if !out.iter().any(|(seen, _)| seen == url) {
            out.push((url.to_string(), label));
        }
    }
    // Biggest first, so the default pick is the best quality.
    out.sort_by_key(|(_, label)| {
        std::cmp::Reverse(label.trim_end_matches('p').parse::<u32>().unwrap_or(0))
    });
    out
}

fn eporner_request(html: &str, page: &str) -> Option<String> {
    if !page.contains("eporner.com") {
        return None;
    }
    let field = |name: &str| -> Option<String> {
        let at = html.find(&format!("{name} = '"))?;
        let rest = &html[at + name.len() + 4..];
        let end = rest.find('\'')?;
        Some(rest[..end].to_string())
    };
    let vid = field("vid")?;
    let hash = field("hash")?;
    if vid.is_empty() || hash.len() != 32 {
        return None;
    }
    let mut encoded = String::new();
    for chunk in hash.as_bytes().chunks(8) {
        let part = u64::from_str_radix(std::str::from_utf8(chunk).ok()?, 16).ok()?;
        encoded.push_str(&base36(part));
    }
    Some(format!(
        "https://www.eporner.com/xhr/video/{vid}?hash={encoded}&domain=www.eporner.com&fallback=false&embed=false&supportedFormats=dash,mp4"
    ))
}

fn base36(mut n: u64) -> String {
    const DIGITS: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyz";
    if n == 0 {
        return "0".to_string();
    }
    let mut out = Vec::new();
    while n > 0 {
        out.push(DIGITS[(n % 36) as usize]);
        n /= 36;
    }
    out.reverse();
    String::from_utf8(out).unwrap_or_default()
}

/// The mp4 files in an eporner sources answer, best first. Labels are its own
/// ("720p HD", "480p"), trimmed to what the quality menu shows.
fn eporner_videos(json: &str) -> Vec<(String, String)> {
    let Ok(blob) = serde_json::from_str::<serde_json::Value>(json) else {
        return Vec::new();
    };
    let Some(files) = blob["sources"]["mp4"].as_object() else {
        return Vec::new();
    };
    let mut out: Vec<(String, String)> = files
        .iter()
        .filter_map(|(label, entry)| {
            let url = entry.get("src").and_then(|s| s.as_str()).unwrap_or("");
            (url.starts_with("http")).then(|| (url.to_string(), label.trim().to_string()))
        })
        .collect();
    out.sort_by_key(|(_, label)| std::cmp::Reverse(height_label(label)));
    out
}

/// The picture height a quality label names: "720p HD" is 720.
fn height_label(label: &str) -> u32 {
    label
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect::<String>()
        .parse()
        .unwrap_or(0)
}

/*
 * THE PLAYER'S OWN LIST OF FILES.
 *
 * pornhub and redtube both put a `mediaDefinitions` array in the page. The old
 * scan started at `flashvars_`, which redtube does not write, so its videos
 * looked like a page with nothing on it. Finding the array itself covers both,
 * and the entries differ in two more ways redtube needed: its URLs are relative
 * to the page, and its qualities are not in the page at all — each entry points
 * at an endpoint that lists them (see `media_indexes`).
 */
fn media_definitions(html: &str) -> Vec<serde_json::Value> {
    let Some(key) = html.find("\"mediaDefinitions\"") else { return Vec::new() };
    let rest = &html[key..];
    let Some(open) = rest.find('[') else { return Vec::new() };
    let bytes = rest.as_bytes();
    let (mut depth, mut end, mut in_string, mut escaped) = (0i32, None, false, false);
    for (i, c) in bytes.iter().enumerate().skip(open) {
        match c {
            b'"' if !escaped => in_string = !in_string,
            b'\\' if in_string => {
                escaped = !escaped;
                continue;
            }
            b'[' if !in_string => depth += 1,
            b']' if !in_string => {
                depth -= 1;
                if depth == 0 {
                    end = Some(i + 1);
                    break;
                }
            }
            _ => {}
        }
        escaped = false;
    }
    let Some(end) = end else { return Vec::new() };
    serde_json::from_str::<Vec<serde_json::Value>>(&rest[open..end]).unwrap_or_default()
}

/// The entry's file, made absolute against the page it was found on.
fn definition_url(def: &serde_json::Value, page: &str) -> Option<String> {
    let raw = def.get("videoUrl").and_then(|u| u.as_str()).unwrap_or("").replace("\\/", "/");
    if raw.is_empty() {
        return None;
    }
    if raw.starts_with("http") {
        Some(raw)
    } else {
        scrape::abs_url(page, &raw)
    }
}

/// A definition's quality as a label, when it names one. An entry with no
/// quality is an endpoint that lists them rather than a file.
fn definition_quality(def: &serde_json::Value) -> Option<String> {
    match def.get("quality") {
        Some(serde_json::Value::String(q)) if q.chars().all(|c| c.is_ascii_digit()) && !q.is_empty() => Some(format!("{q}p")),
        Some(serde_json::Value::Number(q)) => Some(format!("{q}p")),
        _ => None,
    }
}

fn flashvars_videos(html: &str, page: &str) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = media_definitions(html)
        .iter()
        .filter_map(|def| Some((definition_url(def, page)?, definition_quality(def)?)))
        .collect();
    // Best first: the viewer takes the head when nothing was asked for.
    out.sort_by_key(|(_, label)| std::cmp::Reverse(height_label(label)));
    out
}

/// The endpoints a page offers instead of files — redtube's `/media/mp4` and
/// `/media/hls`, which answer with the qualities. mp4 first: it plays without
/// a proxy, where HLS needs one for the page referer.
fn media_indexes(html: &str, page: &str) -> Vec<String> {
    let mut out: Vec<(u8, String)> = media_definitions(html)
        .iter()
        .filter(|def| definition_quality(def).is_none())
        .filter_map(|def| {
            let url = definition_url(def, page)?;
            let format = def.get("format").and_then(|f| f.as_str()).unwrap_or("");
            Some((if format == "mp4" { 0 } else { 1 }, url))
        })
        .collect();
    out.sort_by_key(|(rank, _)| *rank);
    out.into_iter().map(|(_, url)| url).collect()
}

/// What such an endpoint answers: the same shape as a definition, with the
/// quality filled in and a real file behind it.
fn media_index_files(json: &str, page: &str) -> Vec<(String, String)> {
    let Ok(defs) = serde_json::from_str::<Vec<serde_json::Value>>(json) else {
        return Vec::new();
    };
    let mut out: Vec<(String, String)> = defs
        .iter()
        .filter_map(|def| Some((definition_url(def, page)?, definition_quality(def)?)))
        .collect();
    out.sort_by_key(|(_, label)| std::cmp::Reverse(height_label(label)));
    out
}

/*
 * DOES THIS URL NAME A FILE A PLAYER CAN OPEN?
 *
 * The trailing slash is the whole reason this is a function rather than the two
 * copies of a closure it replaces. Kernel Video Sharing — the engine behind
 * porntrex, rule34video and a long tail of older tube sites — serves
 * `.../2836667_1080p.mp4/?token=...`, with a slash BETWEEN the extension and the
 * query. Splitting on `?` and asking `ends_with(".mp4")` says no, so every one of
 * those files was discarded as unplayable and the viewer reported "no video on that
 * page" about a page with three of them on it.
 */
fn playable_url(u: &str) -> bool {
    let path = u.split(['?', '#']).next().unwrap_or("").to_ascii_lowercase();
    let path = path.trim_end_matches('/');
    [".mp4", ".webm", ".m3u8", ".mov", ".m4v"].iter().any(|ext| path.ends_with(ext))
}

/*
 * KERNEL VIDEO SHARING, WHICH IS MOST OF THE OLDER TUBE WEB.
 *
 * KVS puts its files in a `flashvars` object rather than in the markup:
 *
 *     flashvars = {
 *         license_code: '$535555517668914',
 *         video_url: 'https://.../2836667.mp4/',           video_url_text: '480p',
 *         video_alt_url: 'https://.../2836667_720p.mp4/',  video_alt_url_text: '720p HD',
 *         video_alt_url2: 'https://.../2836667_1080p.mp4/', video_alt_url2_text: '1080p FHD',
 *     }
 *
 * Nothing above looked for it: `flashvars_videos` is pornhub's `mediaDefinitions`
 * JSON despite the name, and the `<video>`/`og:video` patterns find markup these
 * pages do not have. So porntrex and rule34video — and anything else on this engine
 * — resolved to nothing at all.
 *
 * SINGLE QUOTES, because that is what the engine emits; double are accepted too
 * rather than assumed not to exist.
 *
 * NOT DECODED. Some KVS deployments obfuscate the path and need `license_code` to
 * unpick it; those URLs begin `function/`. Both sites checked here serve plain ones,
 * so this takes what it can read and skips what it cannot, leaving the encoded case
 * to be added when a site that needs it turns up. A half-right decoder would hand
 * the player a URL that 404s, which is worse than saying nothing.
 */
fn kvs_flashvars(html: &str, page: &str) -> Vec<(String, String)> {
    let Some(start) = html.find("flashvars") else { return Vec::new() };
    // Bounded: far enough for the whole object, short enough that a stray mention of
    // the word elsewhere cannot drag in half the document.
    let window = &html[start..html.len().min(start + 8_000)];

    let mut out: Vec<(String, String)> = Vec::new();
    let mut keys: Vec<String> = vec!["video_url".to_string(), "video_alt_url".to_string()];
    keys.extend((2..=8).map(|n| format!("video_alt_url{n}")));

    for key in keys {
        let pattern = format!(r#"{key}\s*:\s*['"]([^'"]+)['"]"#);
        let Some(raw) = scrape::regex_all(window, &pattern, 1).unwrap_or_default().into_iter().next() else {
            continue;
        };
        let raw = raw.replace("\\/", "/");
        if raw.starts_with("function/") || !playable_url(&raw) {
            continue;
        }
        let Some(url) = (if raw.starts_with("http") { Some(raw) } else { scrape::abs_url(page, &raw) }) else {
            continue;
        };
        if out.iter().any(|(seen, _)| seen == &url) {
            continue;
        }
        // The site's own label — "1080p FHD" — rather than one inferred from the
        // path, because the site knows and the path only hints.
        let label = scrape::regex_all(window, &format!(r#"{key}_text\s*:\s*['"]([^'"]*)['"]"#), 1)
            .unwrap_or_default()
            .into_iter()
            .next()
            .filter(|t| !t.trim().is_empty())
            .unwrap_or_else(|| "Another copy".to_string());
        out.push((url, label.trim().to_string()));
    }
    out.sort_by_key(|(_, label)| std::cmp::Reverse(height_label(label)));
    out
}

/*
 * WHATEVER IS LEFT: ANY URL ON THE PAGE THAT NAMES A PLAYABLE FILE.
 *
 * A last resort, run only when every structured attempt above has found nothing.
 * Some players keep their files in a JavaScript object under a key nobody else uses
 * — youjizz writes `...-852-480-1095-h264.mp4\/master.m3u8` with escaped slashes,
 * spankwire writes `...mp4?validfrom=...&amp;validto=...` with the query HTML-escaped
 * — and no amount of guessing at key names finds those. The file itself is right
 * there in the text, so this reads the text.
 *
 * TWO UNESCAPINGS FIRST, because both of those pages hide their URLs behind one:
 * `\/` back to `/`, and `&amp;` back to `&`. Without the second, a signed URL loses
 * every parameter after the first and 403s.
 *
 * Last, and never first, because it is indiscriminate: a page's advertising is also
 * made of .mp4 files. Preview and ad hosts are dropped by name, and the result is
 * sorted by what the path claims, so a real 1080p beats a 10-second teaser.
 */
fn loose_media_urls(html: &str, page: &str) -> Vec<(String, String)> {
    let text = html.replace("\\/", "/").replace("&amp;", "&");
    /*
     * A SOURCE WITH NO SCHEME IS STILL A SOURCE.
     *
     * `<source src='//video.example/…/hd/1234.mp4'>` is ordinary, valid HTML —
     * the browser fills in the page's own scheme — and the scan below only
     * matches `http://` or `https://`, so those files were invisible. The page
     * had the video on it in plain text and the daemon answered "no video on
     * that page".
     *
     * Measured on hqporner 2026-10-01: 5 of 7 sampled videos failed this way.
     * Its newer films embed a player from a host that writes absolute URLs and
     * its older ones a host that does not, so the source looked half-broken in
     * a way that tracked the age of the film rather than anything about it.
     *
     * The leading character is captured and put back so that the `//` in an
     * URL that already HAS a scheme cannot match: there, `//` is preceded by a
     * colon, which is not in the class.
     */
    let text = match regex::Regex::new(
        r#"(?i)(["'=(,\s])//([a-z0-9.-]+/[^"'\s\\<>()]*?\.(?:mp4|m3u8|webm|mov))"#,
    ) {
        Ok(re) => re.replace_all(&text, "${1}https://${2}").into_owned(),
        Err(_) => text,
    };
    let mut out: Vec<(String, String)> = Vec::new();

    for raw in scrape::regex_all(&text, r#"https?://[^"'\s\\<>()]+?\.(?:mp4|m3u8|webm|mov)(?:\?[^"'\s\\<>()]*)?"#, 0)
        .unwrap_or_default()
    {
        let lowered = raw.to_ascii_lowercase();
        /*
         * The things that are on the page and are not the video: advertising, the
         * site's own interface sounds, and the little looping previews a thumbnail
         * plays on hover — that last one is the dangerous case, because it is a real
         * clip of the right film and three seconds long.
         */
        if ["/ads", "advert", "doubleclick", "exosrv", "adtng", "juicyads", "trafficjunky",
            "/preview", "preview.", "-preview", "/trailer", "/teaser", "sprite", "/logo", "thumb"]
            .iter()
            .any(|bad| lowered.contains(bad))
        {
            continue;
        }
        if !playable_url(&raw) {
            continue;
        }
        if out.iter().any(|(seen, _)| seen == &raw) {
            continue;
        }
        let label = ["2160p", "1440p", "1080", "720", "480", "360", "240"]
            .iter()
            .find(|q| lowered.contains(*q))
            .map(|q| if q.ends_with('p') { q.to_string() } else { format!("{q}p") })
            .unwrap_or_else(|| "Another copy".to_string());
        out.push((raw, label));
    }
    let _ = page;
    out.sort_by_key(|(_, label)| std::cmp::Reverse(height_label(label)));
    out.truncate(8);
    out
}

/*
 * THE PLAYER ON ANOTHER HOST.
 *
 * hqporner keeps nothing playable on its own page: the clip is an
 * `<iframe src="//mydaddy.cc/video/afb4ae095e2640ecca/">` and the files live on the
 * page behind it. Without following it there is genuinely no video to find, which is
 * exactly what the viewer kept reporting.
 *
 * ONE HOP, and only for an iframe that looks like a player. These pages carry
 * several ad iframes each, and fetching all of them would be a handful of requests
 * to a handful of strangers for nothing.
 */
fn player_iframes(html: &str, page: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for raw in scrape::regex_all(html, r#"<iframe[^>]+src=\\?["']([^"'\\]+)["']"#, 1).unwrap_or_default() {
        let lowered = raw.to_ascii_lowercase();
        if !["/video/", "/embed", "/player", "/e/", "/v/"].iter().any(|hint| lowered.contains(hint)) {
            continue;
        }
        if ["doubleclick", "googlesynd", "/ads", "adserver", "exosrv"].iter().any(|bad| lowered.contains(bad)) {
            continue;
        }
        let Some(url) = (if raw.starts_with("http") { Some(raw) } else { scrape::abs_url(page, &raw) }) else {
            continue;
        };
        if !out.contains(&url) {
            out.push(url);
        }
        if out.len() >= 3 {
            break;
        }
    }
    out
}

/// Every playable file a page declares, best-labelled first. `video_on_page`
/// is the same walk, stopping at the first.
/*
 * WHETHER A SOURCE MAY BE CRAWLED AT ALL RIGHT NOW.
 *
 * The hiding in `Catalog::rank` keeps adult rows out of every answer, which is
 * what makes the switch safe for what is already on disk. This is the other
 * half: with the switch off, an adult site is not asked for anything, so
 * nothing new arrives to be hidden later.
 *
 * Both halves matter. Hiding alone would quietly fill the catalogue — and the
 * thumbnail cache, on disk, in a folder with the pictures in it — with
 * material the person has said they do not want.
 */
/*
 * DO NOT FETCH IT EITHER.
 *
 * `Catalog::rank` hides adult rows from every answer, which is what makes the
 * switch safe for what is already on disk. This is the third part, after
 * `source_allowed`: a source that is not itself adult but can carry adult rows —
 * most boorus, reddit — is asked not to send them.
 *
 * Without it, "hidden" would mean "crawled, stored, thumbnailed and then not
 * drawn": the rows land in the catalogue and their pictures land in the
 * thumbnail cache, in a folder, on disk. Hiding something you went and fetched
 * anyway is not what the person asked for.
 *
 * A source that cannot express it (`caps.nsfw` false) simply ignores this, and
 * whatever it sends is still hidden by `rank`. That is the honest limit of
 * push-down, and it is why hiding exists as well rather than instead.
 */
fn dont_fetch_adult(pushed: &mut sources::SourceQuery, show_adult: bool) {
    if !show_adult {
        pushed.allow_nsfw = Some(false);
    }
}

fn source_allowed(id: &str, show_adult: bool) -> bool {
    if show_adult {
        return true;
    }
    !sources::by_id(id).map(|s| s.category() == "adult").unwrap_or(false)
}

/// A tube site's hover preview of ANOTHER video: pornhub-family CDNs name them
/// `…_fb.mp4` ("flipbook") and a page carries dozens, one per related video.
fn is_hover_preview(url: &str) -> bool {
    let path = url.split(['?', '#']).next().unwrap_or(url).to_ascii_lowercase();
    path.ends_with("_fb.mp4")
}

fn videos_on_page(html: &str, page: &str) -> Vec<(String, String)> {
    // Every route in the scan below, filtered once.
    let mut found = videos_on_page_any(html, page);
    found.retain(|(url, _)| !is_hover_preview(url));
    found
}

fn videos_on_page_any(html: &str, page: &str) -> Vec<(String, String)> {
    let from_player = flashvars_videos(html, page);
    if !from_player.is_empty() {
        return from_player;
    }
    let from_kvs = kvs_flashvars(html, page);
    if !from_kvs.is_empty() {
        return from_kvs;
    }
    let playable = |u: &str| playable_url(u);
    let mut out: Vec<(String, String)> = Vec::new();
    let mut add = |raw: String, out: &mut Vec<(String, String)>| {
        let raw = raw.replace("\\/", "/");
        if !playable(&raw) {
            return;
        }
        let Some(url) = (if raw.starts_with("http") { Some(raw.clone()) } else { scrape::abs_url(page, &raw) }) else {
            return;
        };
        if out.iter().any(|(seen, _)| seen == &url) {
            return;
        }
        // "1080P" / "_720p_" / "hd" in the URL is the site telling us what it is.
        let lowered = url.to_lowercase();
        // The site's own name for it where the URL says one, and an honest
        // "another copy" where it does not — a made-up "Source 2" reads like a
        // quality and is not one.
        let label = ["2160p", "1440p", "1080p", "720p", "480p", "360p", "240p"]
            .iter()
            .find(|q| lowered.contains(*q))
            .map(|q| q.to_string())
            .unwrap_or_else(|| {
                if lowered.contains("hd") {
                    "HD".to_string()
                } else if lowered.contains("sd") || lowered.contains("mobile") || lowered.contains("small") {
                    "Smaller".to_string()
                } else {
                    format!("Another copy {}", out.len() + 1)
                }
            });
        out.push((url, label));
    };
    for key in ["og:video:secure_url", "og:video:url", "og:video", "twitter:player:stream", "contentUrl"] {
        let pattern = format!(r#"(?:property|name|")\s*[=:]\s*"{key}"[^>]*?content="([^"]+)""#);
        for raw in scrape::regex_all(html, &pattern, 1).unwrap_or_default() {
            add(raw, &mut out);
        }
        for raw in scrape::regex_all(html, &format!(r#""{key}"\s*:\s*"([^"]+)""#), 1).unwrap_or_default() {
            add(raw, &mut out);
        }
    }
    /*
     * `src="..."` AND `src=\"...\"`.
     *
     * hqporner's player builds its markup inside a JavaScript string, so every quote
     * in it is backslash-escaped. The unescaped pattern alone found nothing on a page
     * listing three qualities in plain sight.
     */
    for pattern in [r#"<(?:video|source)[^>]+src="([^"]+)""#, r#"<(?:video|source)[^>]+src=\\"([^\\"]+)\\""#] {
        for raw in scrape::regex_all(html, pattern, 1).unwrap_or_default() {
            add(raw, &mut out);
        }
    }
    /*
     * The player's own labels, where it gives them.
     *
     * `<source src=... title="1080p Full HD">` is the site saying what the file is,
     * and it beats guessing from the path — these URLs are `.../1080.mp4`, which the
     * inference above reads as "Another copy 3".
     */
    for pattern in [r#"<source[^>]+src="([^"]+)"[^>]*title="([^"]*)""#, r#"<source[^>]+src=\\"([^\\"]+)\\"[^>]*title=\\"([^\\"]*)\\""#] {
        // Two passes over one pattern: `regex_all` yields one capture group at a
        // time, and the matches come back in the same order both times.
        let urls = scrape::regex_all(html, pattern, 1).unwrap_or_default();
        let titles = scrape::regex_all(html, pattern, 2).unwrap_or_default();
        for (raw, title) in urls.into_iter().zip(titles) {
            if title.trim().is_empty() {
                continue;
            }
            let raw = raw.replace("\\/", "/");
            let Some(url) = (if raw.starts_with("http") { Some(raw) } else { scrape::abs_url(page, &raw) }) else {
                continue;
            };
            if let Some(slot) = out.iter_mut().find(|(seen, _)| seen == &url) {
                slot.1 = title.trim().to_string();
            }
        }
    }
    out.sort_by_key(|(_, label)| std::cmp::Reverse(height_label(label)));
    // Tube pages list their qualities as JSON: {"quality":"720","videoUrl":"…"}
    for raw in scrape::regex_all(html, r#""videoUrl"\s*:\s*"([^"]+)""#, 1).unwrap_or_default() {
        add(raw, &mut out);
    }
    if out.is_empty() {
        out = loose_media_urls(html, page);
    }
    out
}

fn video_on_page(html: &str, page: &str) -> Option<(String, f64)> {
    let playable = |u: &str| playable_url(u);
    let mut found: Option<String> = None;
    for key in ["og:video:secure_url", "og:video:url", "og:video", "twitter:player:stream", "contentUrl"] {
        let pattern = format!(r#"(?:property|name|")\s*[=:]\s*"{key}"[^>]*?content="([^"]+)""#);
        let hit = scrape::regex_all(html, &pattern, 1)
            .unwrap_or_default()
            .into_iter()
            .chain(scrape::regex_all(html, &format!(r#""{key}"\s*:\s*"([^"]+)""#), 1).unwrap_or_default())
            .map(|u| u.replace("\\/", "/"))
            .find(|u| playable(u));
        if hit.is_some() {
            found = hit;
            break;
        }
    }
    if found.is_none() {
        found = scrape::regex_all(html, r#"<(?:video|source)[^>]+src="([^"]+)""#, 1)
            .unwrap_or_default()
            .into_iter()
            .map(|u| u.replace("\\/", "/"))
            .find(|u| playable(u));
    }
    let found = found?;
    let url = if found.starts_with("http") { found.clone() } else { scrape::abs_url(page, &found)? };
    let duration = scrape::regex_all(html, r#"(?:og:video:duration"[^>]*content="|"duration"\s*:\s*")(\d+)"#, 1)
        .unwrap_or_default()
        .into_iter()
        .next()
        .and_then(|d| d.parse::<f64>().ok())
        .unwrap_or(0.0);
    Some((url, duration))
}

#[cfg(test)]
mod video_page_tests {
    use super::{eporner_request, eporner_videos, video_on_page};

    // The hash goes to the endpoint eight hex digits at a time as base 36 —
    // measured against the live page for NQrjJt2eGgh, which answers
    // `available: false` for any other encoding.
    #[test]
    fn eporner_asks_with_its_hash_re_encoded() {
        let page = "var vid = \'NQrjJt2eGgh\';\n var hash = \'0c793a9aaf781b5f53fd8fdbc2cbc427\';";
        let ask = eporner_request(page, "https://www.eporner.com/video-NQrjJt2eGgh/x/").expect("request");
        assert!(ask.contains("/xhr/video/NQrjJt2eGgh?"), "{ask}");
        assert!(ask.contains("hash=3glevu1copnj3nayguz1i1rg9z"), "{ask}");
        // Another site's page is not eporner's, whatever it contains.
        assert!(eporner_request(page, "https://example.com/v/1").is_none());
    }

    #[test]
    fn eporner_sources_come_back_best_first() {
        let answer = r#"{"sources":{"mp4":{
            "360p":{"src":"https://cdn.example/360","type":"video/mp4"},
            "720p HD":{"src":"https://cdn.example/720","type":"video/mp4"},
            "480p":{"src":"","type":"video/mp4"}}}}"#;
        let files = eporner_videos(answer);
        assert_eq!(files.first().map(|(_, l)| l.as_str()), Some("720p HD"));
        // An entry with no file is not a quality you can pick.
        assert_eq!(files.len(), 2);
        assert_eq!(files[0].0, "https://cdn.example/720");
    }

    #[test]
    fn a_page_that_declares_its_video_gives_it_up() {
        let og = r#"<meta property="og:video:secure_url" content="https://cdn.example/clip.mp4">
                    <meta property="og:video:duration" content="93">"#;
        assert_eq!(video_on_page(og, "https://site.example/v/1"), Some(("https://cdn.example/clip.mp4".into(), 93.0)));

        let element = r#"<video poster="/p.jpg"><source src="/media/clip.webm" type="video/webm"></video>"#;
        assert_eq!(
            video_on_page(element, "https://site.example/v/1"),
            Some(("https://site.example/media/clip.webm".into(), 0.0)),
            "a relative source resolves against its page"
        );

        let json_ld = r#"{"@type":"VideoObject","contentUrl":"https:\/\/cdn.example\/a.mp4"}"#;
        assert_eq!(video_on_page(json_ld, "https://site.example/v/1").map(|f| f.0), Some("https://cdn.example/a.mp4".into()));
    }

    #[test]
    fn a_picture_page_is_not_a_video() {
        let html = r#"<meta property="og:image" content="https://cdn.example/pic.jpg"><img src="/pic.jpg">"#;
        assert_eq!(video_on_page(html, "https://site.example/p/1"), None);
    }
}

/// Mark what a source did not: rows from an adult board, and rows whose own
/// words say so. Under-marking is what the blur and "hide them" settings
/// cannot recover from.
fn mark_adult(items: &mut [crate::protocol::Item], source_id: &str) {
    let adult_board = sources::by_id(source_id).is_some_and(|s| s.category() == "adult");
    for item in items.iter_mut() {
        if item.nsfw {
            continue;
        }
        if adult_board {
            item.nsfw = true;
            continue;
        }
        let words = format!("{} {} {}", item.title, item.tags.join(" "), item.page_url);
        if nsfw::is_adult(&words) {
            item.nsfw = true;
        }
    }
}

/// Whether the row's `url` is a picture something can look at — not a video,
/// a model or a sound, whose thumbnail has to stand in for it.
/// Whether a URL names something a player can open. Unlike `is_still_image`
/// this looks only at the URL: a row can be marked video and still carry its
/// poster as `url`, which is exactly the case that has to be resolved.
fn url_plays(url: &str) -> bool {
    let path = url.split(['?', '#']).next().unwrap_or("").to_ascii_lowercase();
    [".mp4", ".webm", ".mkv", ".mov", ".m4v", ".m3u8"].iter().any(|e| path.ends_with(e))
}

fn is_still_image(item: &crate::protocol::Item) -> bool {
    if matches!(item.family.as_str(), "video" | "model" | "audio") {
        return false;
    }
    let ext = item.url.split('?').next().unwrap_or("").rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    !matches!(ext.as_str(), "mp4" | "webm" | "mkv" | "mov" | "m4v" | "glb" | "gltf" | "mp3" | "ogg" | "wav")
}

/*
 * A SEARCH THAT MATCHED NOTHING IS NOT A BROKEN SOURCE.
 *
 * Shimmie boards answer 404 for a tag with no posts — verified on lyrabooru,
 * fanservice and booru.gikopoi, all of which browse fine and 404 on any term
 * they have no rows for. Counted as a failure it burns the source's retry, and
 * it inflates the `failed` list the app reads to decide the scroll is over.
 *
 * Only when something was actually searched for: a 404 on a plain browse is a
 * manifest pointing at the wrong place, which must still be reported.
 */
fn empty_listing(error: &scrape::ScrapeError, searched: bool) -> bool {
    searched && matches!(error, scrape::ScrapeError::Status(404, _))
}

async fn fetch_page(
    http: &scrape::Http,
    url: &str,
    body: Option<&serde_json::Value>,
) -> scrape::Result<String> {
    /*
     * A SOURCE THAT IS NOT ON THE INTERNET.
     *
     * The local folder source is a `Source` like every other one — same
     * push-down, same crawl loop, same dedupe — and that only works if a
     * directory listing arrives the same way a page of JSON does. So it names
     * itself with a `file://` URL and this reads the disk instead of the
     * network. Everything downstream cannot tell, and does not need to.
     */
    if let Some(rest) = url.strip_prefix("file://local") {
        let page = rest
            .split("page=")
            .nth(1)
            .and_then(|p| p.split('&').next())
            .and_then(|p| p.parse::<u32>().ok())
            .unwrap_or(1);
        // Blocking work — a recursive walk with a header read per file — kept
        // off the async worker threads that are answering everything else.
        return tokio::task::spawn_blocking(move || sources::local::Local::scan(page, 200))
            .await
            .map_err(|e| scrape::ScrapeError::Io(format!("local scan: {e}")));
    }

    /*
     * A SOURCE THAT NEEDS A TOKEN.
     *
     * Reddit's OAuth host is the only way in since it started answering 403 to
     * everything else, and a bearer header is not something `build_url` can
     * express. Handled here for the same reason `file://` is: one place knows,
     * and the crawl loop, the push-down and `doctor` all stay unchanged.
     *
     * A 401 means the token died between minting and using it — rare, but the
     * cache is shared with the user's own scripts, so another process may have
     * replaced it. Dropping the cached copy and asking once more is the whole
     * recovery.
     */
    if url.starts_with("https://oauth.reddit.com") {
        let Some(token) = sources::reddit::token().await else {
            return Err(scrape::ScrapeError::Http(
                "reddit: no credentials — set REDDIT_CLIENT_ID/SECRET/USER/PASS, or run \
                 reddit_oauth_setup.sh"
                    .into(),
            ));
        };
        return match sources::reddit::fetch(url, &token).await {
            Err(scrape::ScrapeError::Status(401, _)) => {
                // The token died between minting and using it — the cache is
                // shared with the user's own scripts, so another process may
                // have replaced it. One retry with a fresh one.
                sources::reddit::forget_token();
                let token = sources::reddit::token()
                    .await
                    .ok_or_else(|| scrape::ScrapeError::Http("reddit: token refused".into()))?;
                sources::reddit::fetch(url, &token).await
            }
            other => other,
        };
    }

    // The same shape as the Reddit branch above: a token this adapter mints
    // for itself, and one retry if it turns out to have expired.
    if url.starts_with("https://api.redgifs.com") {
        let Some(token) = sources::redgifs::token().await else {
            return Err(scrape::ScrapeError::Http("redgifs: could not get a token".into()));
        };
        return match sources::redgifs::fetch(url, &token).await {
            Err(scrape::ScrapeError::Status(401, _)) => {
                sources::redgifs::forget_token();
                let token = sources::redgifs::token()
                    .await
                    .ok_or_else(|| scrape::ScrapeError::Http("redgifs: token refused".into()))?;
                sources::redgifs::fetch(url, &token).await
            }
            other => other,
        };
    }

    match body {
        Some(document) => {
            http.post_json::<serde_json::Value>(url, document).await.map(|v| v.to_string())
        }
        None => http.fetch_text(url).await,
    }
}

/// Run several futures at once and collect them in order.
///
/// `join_all` without pulling in the futures crate: the daemon has four
/// dependencies and none of them is a combinator library.
async fn futures_lite_join<F, T>(futures: impl IntoIterator<Item = F>) -> Vec<T>
where
    F: std::future::Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    let handles: Vec<_> = futures.into_iter().map(tokio::spawn).collect();
    let mut out = Vec::with_capacity(handles.len());
    for handle in handles {
        if let Ok(value) = handle.await {
            out.push(value);
        }
    }
    out
}

/// Percent-decoding, for paths that arrive as URIs from a file manager.
///
/// Deliberately minimal: this only ever sees a local path, so the full URI
/// grammar is not the problem — "%20" and friends are.
fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(byte) = u8::from_str_radix(&input[i + 1..i + 3], 16) {
                out.push(byte);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn socket_path() -> PathBuf {
    if let Ok(p) = std::env::var("QUARRY_SOCK") {
        return PathBuf::from(p);
    }
    let runtime = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(runtime).join("quarry").join("sock")
}

const DEFAULT_FIXTURE: &str = "fixtures/sample.json";
const PACKAGED_FIXTURE: &str = "/usr/share/quarry/fixtures/sample.json";

/// Where a first run looks for its seed fixture: what was asked for, then the
/// packaged copy, then one next to the binary. The default is a RELATIVE path,
/// which only ever resolved when quarryd was launched from its own source tree.
fn fixture_candidates(asked: &std::path::Path) -> Vec<PathBuf> {
    let mut out = vec![asked.to_path_buf()];
    if asked == std::path::Path::new(DEFAULT_FIXTURE) {
        // Must match the install path in PKGBUILD (pinned by a test below).
        out.push(PathBuf::from(PACKAGED_FIXTURE));
        if let Some(dir) = std::env::current_exe().ok().and_then(|e| e.parent().map(|p| p.to_path_buf())) {
                out.push(dir.join(DEFAULT_FIXTURE));
        }
    }
    out
}

/*
 * Is the pid in the lock file a daemon that is actually running?
 *
 * Three ways it can be no, and the second one cost somebody their app:
 *   - the process is gone, so /proc/<pid> does not exist;
 *   - it is a ZOMBIE — dead, but still listed because nobody has reaped it,
 *     which is exactly what a daemon killed by its parent looks like;
 *   - the pid has been recycled by some unrelated program.
 */
fn holder_is_alive(pid: i32) -> bool {
    let stat = match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
        Ok(text) => text,
        Err(_) => return false,
    };
    // "pid (comm) STATE …" — comm can contain spaces and brackets, so the
    // state is the field after the LAST ')'.
    let state = stat
        .rsplit_once(')')
        .map(|(_, rest)| rest.trim_start())
        .and_then(|rest| rest.split_whitespace().next())
        .unwrap_or("");
    if state == "Z" {
        return false;
    }
    match std::fs::read_to_string(format!("/proc/{pid}/comm")) {
        Ok(name) => name.trim() == "quarryd",
        // Another user's process: not ours, and not something to be blocked by.
        Err(_) => false,
    }
}

/*
 * IS THIS PROCESS STILL THE INSTALLED BINARY?
 *
 * A package upgrade replaces the file; the running process keeps the inode it
 * already opened and carries on executing yesterday's code. `version` goes on
 * reporting the number that is INSTALLED, which is the trap: an installed fix
 * and a running fix look identical from outside, and four separate debugging
 * rounds here ended at "the fix is right and does nothing".
 *
 * The identity is taken ONCE, at startup, before anything can have replaced it
 * — a lazy first read after an upgrade would record the new file and never
 * report anything. Inode and length rather than mtime: a reinstall of the same
 * build is a new inode and is honestly a different file, while mtime can be
 * preserved by an archive tool and would miss it.
 */
#[derive(Clone)]
struct BinaryFingerprint {
    path: std::path::PathBuf,
    ino: u64,
    len: u64,
}

static BINARY: std::sync::OnceLock<Option<BinaryFingerprint>> = std::sync::OnceLock::new();

fn remember_binary() {
    BINARY.get_or_init(|| {
        use std::os::unix::fs::MetadataExt;
        let path = std::env::current_exe().ok()?;
        let meta = std::fs::metadata(&path).ok()?;
        Some(BinaryFingerprint { path, ino: meta.ino(), len: meta.len() })
    });
}

fn binary_is_stale() -> bool {
    use std::os::unix::fs::MetadataExt;
    let Some(Some(known)) = BINARY.get() else {
        // Never recorded — we cannot claim anything, and guessing "stale"
        // would put a warning on screen with nothing behind it.
        return false;
    };
    let now = std::fs::metadata(&known.path).ok().map(|m| (m.ino(), m.len()));
    binary_was_replaced(known, now)
}

/// The decision on its own, so it can be tested without replacing the test
/// runner's own executable.
fn binary_was_replaced(known: &BinaryFingerprint, now: Option<(u64, u64)>) -> bool {
    match now {
        Some((ino, len)) => ino != known.ino || len != known.len,
        /*
         * The file is gone and nothing took its place. That is an uninstall or
         * a build directory being cleaned, not an upgrade: this process is
         * still the one that was put there, so it is not stale and saying so
         * would send someone to restart a daemon whose binary no longer exists.
         */
        None => false,
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // First, before an upgrade can land underneath us. See `binary_is_stale`.
    remember_binary();

    let mut fixture = PathBuf::from(DEFAULT_FIXTURE);
    let mut socket = socket_path();
    let mut quiet = false;

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--fixture" => fixture = PathBuf::from(args.next().unwrap_or_default()),
            "--socket" => socket = PathBuf::from(args.next().unwrap_or_default()),
            "--quiet" => quiet = true,
            other => return Err(format!("unknown argument: {other}").into()),
        }
    }

    // The catalogue lives in XDG_STATE_HOME: it is neither a cache (losing it
    // loses what you found) nor config (you did not write it).
    let state_root = std::env::var("XDG_STATE_HOME")
        .unwrap_or_else(|_| format!("{}/.local/state", std::env::var("HOME").unwrap_or_default()));
    let db_path = std::path::PathBuf::from(format!("{state_root}/quarry/catalog.db"));

    /*
     * ONE DAEMON PER CATALOGUE.
     *
     * Two daemons on one SQLite file is the leading explanation for a
     * catalogue found with its first page zeroed — 362 MB that answered
     * "file is not a database" to everything. WAL survives ordinary sharing,
     * but nothing here needs a second writer, and the cost of finding out the
     * hard way is somebody's library.
     *
     * The guard is a pid file, not a lock crate: a stale one from a killed
     * daemon is detected by asking what that process actually is, which is a
     * couple of reads in /proc and needs no dependency.
     *
     * "Still exists" is not the question, and getting that wrong locked a
     * person out of their own catalogue. A daemon that dies while its parent is
     * still running becomes a ZOMBIE: /proc/<pid> is still there, the process
     * is not, and the next daemon refused to start — which systemd then retried
     * until it hit the start limit and gave up for good. So the check is: a
     * live process, not a zombie, and actually a quarryd — the last part also
     * covers the pid having been reused by something else entirely.
     */
    let lock_path = db_path.with_extension("db.lock");
    if let Ok(text) = std::fs::read_to_string(&lock_path) {
        if let Ok(other) = text.trim().parse::<i32>() {
            if other != std::process::id() as i32 && holder_is_alive(other) {
                eprintln!(
                    "[quarryd] another daemon (pid {other}) already has {} open — refusing to share it. \
                     Stop that one, or start this with its own XDG_STATE_HOME.",
                    db_path.display()
                );
                std::process::exit(3);
            }
        }
    }
    if let Some(dir) = lock_path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::write(&lock_path, std::process::id().to_string());

    // Read only if the catalogue turns out to be empty (see Catalog::open).
    let catalog = Catalog::open(&db_path, || {
        let tried = fixture_candidates(&fixture);
        tried
            .iter()
            .find_map(|p| std::fs::read_to_string(p).ok())
            .ok_or_else(|| {
                let list: Vec<_> = tried.iter().map(|p| p.display().to_string()).collect();
                format!(
                    "the catalogue is empty and no seed fixture was found (tried: {})",
                    list.join(", ")
                )
            })
    })?;
    let count = catalog.len();

    if let Some(dir) = socket.parent() {
        tokio::fs::create_dir_all(dir).await?;
        // 0700: the filesystem is the access control, which is why this
        // protocol has no token (see PROTOCOL.md).
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
        }
    }
    // A socket file left behind by a killed daemon would make bind fail.
    let _ = tokio::fs::remove_file(&socket).await;

    let listener = UnixListener::bind(&socket)?;
    let http = scrape::Http::new()?
        .with_cache(
            format!("{}/quarry/http", std::env::var("XDG_CACHE_HOME")
                .unwrap_or_else(|_| format!("{}/.cache", std::env::var("HOME").unwrap_or_default()))),
            std::time::Duration::from_secs(900),
        );

    let cache_root = std::env::var("XDG_CACHE_HOME")
        .unwrap_or_else(|_| format!("{}/.cache", std::env::var("HOME").unwrap_or_default()));
    let thumb_dir = format!("{cache_root}/quarry/thumbs");
    let model_dir = format!("{cache_root}/quarry/models");
    tokio::fs::create_dir_all(&thumb_dir).await.ok();
    tokio::fs::create_dir_all(&model_dir).await.ok();

    /*
     * The caches are trimmed on the way up, and hourly after that.
     *
     * At startup because that is the moment a full disk has already broken
     * something (SQLite refuses to open at all), and hourly because a crawl of
     * sixty sources writes thumbnails the whole time it runs. Both directories
     * hold nothing that cannot be fetched again.
     */
    // Which words mean adult, from the public list, refreshed weekly.
    {
        let dir = format!("{cache_root}/quarry");
        nsfw::load(&dir);
        let terms_http = scrape::Http::new().ok();
        tokio::spawn(async move {
            let Some(terms_http) = terms_http else { return };
            loop {
                if let Some(count) = nsfw::refresh(&terms_http, &dir).await {
                    eprintln!("[quarryd] adult term list refreshed: {count} terms");
                }
                tokio::time::sleep(std::time::Duration::from_secs(24 * 3600)).await;
            }
        });
    }

    {
        let thumbs = thumb_dir.clone();
        let media = format!("{cache_root}/quarry/media");
        /*
         * THE SAVED LIMITS, NOT THE COMPILED-IN ONES.
         *
         * These budgets are a setting now (Settings → Storage). An env var
         * still wins where one is set, because that is how a packager or a
         * test pins them; otherwise what the person chose in the app is what
         * the hourly trim enforces. Zero means no limit, and skips the trim
         * entirely rather than trimming to nothing.
         */
        let saved = crate::prefs::Prefs::load();
        let thumb_budget = budget_from_env("QUARRY_THUMB_BUDGET_MB", saved.thumb_budget_mb);
        let media_budget = budget_from_env("QUARRY_MEDIA_BUDGET_MB", saved.media_budget_mb);
        let http_budget = budget_from_env("QUARRY_HTTP_BUDGET_MB", saved.http_budget_mb);
        let http = format!("{cache_root}/quarry/http");
        tokio::task::spawn_blocking(move || {
            let mut freed = 0u64;
            if thumb_budget > 0 {
                freed += trim_cache_dir(&thumbs, thumb_budget);
            }
            if media_budget > 0 {
                freed += trim_cache_dir(&media, media_budget);
            }
            if http_budget > 0 {
                freed += trim_cache_dir(&http, http_budget);
            }
            if freed > 0 {
                eprintln!("[quarryd] trimmed caches, {} MB freed", freed / (1024 * 1024));
            }
        });
        let thumbs = thumb_dir.clone();
        let media = format!("{cache_root}/quarry/media");
        let http_trim = format!("{cache_root}/quarry/http");
        tokio::spawn(async move {
            let mut hourly = tokio::time::interval(std::time::Duration::from_secs(3600));
            hourly.tick().await;      // the first tick is immediate; startup did it
            loop {
                hourly.tick().await;
                let (thumbs, media, http_trim) = (thumbs.clone(), media.clone(), http_trim.clone());
                let _ = tokio::task::spawn_blocking(move || {
                    // Re-read every hour: a limit changed in Settings takes
                    // effect at the next sweep without a restart.
                    let saved = crate::prefs::Prefs::load();
                    let thumbs_mb = budget_from_env("QUARRY_THUMB_BUDGET_MB", saved.thumb_budget_mb);
                    let media_mb = budget_from_env("QUARRY_MEDIA_BUDGET_MB", saved.media_budget_mb);
                    let http_mb = budget_from_env("QUARRY_HTTP_BUDGET_MB", saved.http_budget_mb);
                    if thumbs_mb > 0 {
                        trim_cache_dir(&thumbs, thumbs_mb);
                    }
                    if media_mb > 0 {
                        trim_cache_dir(&media, media_mb);
                    }
                    if http_mb > 0 {
                        trim_cache_dir(&http_trim, http_mb);
                    }
                })
                .await;
            }
        });
    }

    /*
     * WHERE THE LAST RUN GOT TO.
     *
     * Cursors are stored per source and query, so a restart does not ask
     * thirty-odd sites for page one again — the page whose rows are already
     * here. A source that had finished keeps its finish time, aged into this
     * process's clock, so the home feed's "rest, then start over" survives a
     * restart too.
     */
    let mut resumed = std::collections::HashMap::new();
    let mut finished = std::collections::HashMap::new();
    let now_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    for (source, query, page, finished_at) in catalog.cursors() {
        let key = format!("{source}\u{1}{query}");
        resumed.insert(key.clone(), page);
        if finished_at > 0 {
            let ago = (now_secs - finished_at).clamp(0, 86_400) as u64;
            if let Some(when) = std::time::Instant::now().checked_sub(std::time::Duration::from_secs(ago)) {
                finished.insert(key, when);
            }
        }
    }
    if !resumed.is_empty() {
        eprintln!("[quarryd] resumed {} crawl cursors", resumed.len());
    }

    let server = Arc::new(Server {
        catalog: Mutex::new(catalog),
        health: Mutex::new(std::collections::HashMap::new()),
        health_log: format!("{state_root}/quarry/sources.log"),
        cursors: Mutex::new(resumed),
        exhausted_at: Mutex::new(finished),
        yields: Mutex::new(std::collections::HashMap::new()),
        page_videos: Mutex::new(std::collections::HashMap::new()),
        page_tags: Mutex::new(std::collections::HashMap::new()),
        proxy: Mutex::new(None),
        // Enough to hide network latency behind itself; not so much that a
        // scroll turns into a stampede on someone's CDN. Tunable so the value
        // is a measurement rather than a guess — QUARRY_CONCURRENCY=1 restores
        // the old strictly-serial behaviour for comparison.
        // 64 frames of slack per connection. An event is a nudge to re-read,
        // not data, so a client that misses some has lost nothing it cannot
        // ask for — which is exactly why lagging is survivable here.
        events: tokio::sync::broadcast::channel(64).0,
        background: tokio::sync::Semaphore::new(
            std::env::var("QUARRY_CRAWL_CONCURRENCY")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(6),
        ),
        concurrency: tokio::sync::Semaphore::new(
            std::env::var("QUARRY_CONCURRENCY")
                .ok()
                .and_then(|v| v.parse().ok())
                // Raised with the source count: a screen of tiles is ~30
                // thumbnails across as many hosts, and at 12 the last ones
                // waited for the first to finish before they even started.
                .unwrap_or(24),
        ),
        http: Arc::new(http),
        thumb_dir,
        model_dir,
        started: std::time::Instant::now(),
        quiet,
    });

    /*
     * VALIDATE THE MANIFESTS AT BOOT, NOT ON THE FIRST QUESTION.
     *
     * `sources::all()` is lazy — it ran only when a handler asked, so a
     * manifest that could not load (a typo, or credentials it needs and does
     * not have) said nothing until something happened to want the source list.
     * Start the daemon and watch it: silence, whether every source is fine or
     * one of them is quietly missing.
     *
     * Calling it once here costs a directory read and makes the startup line
     * honest — anything wrong with a source is next to the line that says the
     * daemon is up, which is the moment someone is looking.
     */
    let source_count = sources::all().len();

    server.log(format_args!(
        "listening on {} — {} items in {}, {} sources",
        socket.display(),
        count,
        db_path.display(),
        source_count
    ));

    // Fold the write-ahead log back in periodically: a crawl that ran an hour
    // ago should not depend on the next write to become durable.
    let checkpointer = Arc::clone(&server);
    tokio::spawn(async move {
        let mut every = tokio::time::interval(std::time::Duration::from_secs(60));
        loop {
            every.tick().await;
            checkpointer.catalog.lock().await.checkpoint();
        }
    });

    /*
     * HASH WHAT IS ALREADY ON DISK, QUIETLY.
     *
     * A perceptual hash is a by-product of making a thumbnail, so only pictures
     * someone has actually looked at had one — 7% of this catalogue — and "more
     * like this" was therefore unavailable on almost everything. That reads as
     * a broken feature rather than an unmeasured row.
     *
     * `network: false` is the whole point: this only hashes rows whose
     * thumbnail is ALREADY cached, so it costs a decode and no traffic at all.
     * Nobody's CDN is touched, nothing is fetched behind your back, and the
     * coverage climbs on its own as you browse. Rows that were never
     * thumbnailed stay unmeasured until you look at one — and `similar` now
     * measures that one on demand.
     *
     * Idle-priced: a small batch, rarely, and it stops asking once the cached
     * backlog is exhausted rather than spinning on an empty worklist.
     */
    let hasher = Arc::clone(&server);
    tokio::spawn(async move {
        // Let the socket and the first queries have the machine to themselves.
        tokio::time::sleep(std::time::Duration::from_secs(20)).await;
        let mut idle_rounds = 0u32;
        loop {
            let report = hasher.backfill_once(120, false).await;
            let did = report.get("hashedNow").and_then(|v| v.as_u64()).unwrap_or(0);
            let remaining = report.get("remaining").and_then(|v| v.as_u64()).unwrap_or(0);

            if did > 0 {
                idle_rounds = 0;
                hasher.log(format_args!(
                    "hashed {did} from cache, {remaining} rows still unmeasured"
                ));
            } else {
                // Nothing cached left to do. Back off rather than sweep a
                // worklist that cannot be satisfied without the network.
                idle_rounds = idle_rounds.saturating_add(1);
            }

            let wait = if idle_rounds == 0 { 15 } else { 300 };
            tokio::time::sleep(std::time::Duration::from_secs(wait)).await;
        }
    });

    let shutdown_socket = socket.clone();
    tokio::spawn(async move {
        let _ = tokio::signal::ctrl_c().await;
        let _ = std::fs::remove_file(&shutdown_socket);
        std::process::exit(0);
    });

    loop {
        let (stream, _) = listener.accept().await?;
        let server = Arc::clone(&server);
        tokio::spawn(serve(server, stream));
    }
}

#[cfg(test)]
mod fixture_path_tests {
    use super::*;

    /// The packaged path is a string in Rust and a string in PKGBUILD, and
    /// nothing but this test connects them. Guessed wrong once already.
    #[test]
    fn packaged_fixture_matches_the_pkgbuild_install() {
        let pkgbuild = std::fs::read_to_string("../PKGBUILD").expect("PKGBUILD next to the crate");
        let installed = pkgbuild
            .lines()
            .find(|l| l.contains("fixtures/sample.json") && l.contains("install -D"))
            .expect("PKGBUILD installs the seed fixture");
        assert!(
            installed.contains(&format!("$pkgdir{PACKAGED_FIXTURE}")),
            "PKGBUILD installs the fixture somewhere quarryd does not look:\n  {installed}"
        );
    }

    #[test]
    fn an_explicit_fixture_is_not_second_guessed() {
        let asked = std::path::Path::new("/tmp/mine.json");
        assert_eq!(fixture_candidates(asked), vec![PathBuf::from("/tmp/mine.json")]);
    }
}

#[cfg(test)]
mod empty_listing_tests {
    use super::empty_listing;
    use crate::scrape::ScrapeError;

    /// Shimmie boards answer 404 for a tag they have no posts for. Counted as a
    /// failure that burned the source's retry every round and inflated the
    /// `failed` list the app reads to decide the scroll is over.
    #[test]
    fn a_404_on_a_search_is_no_rows_not_a_failure() {
        let missing = ScrapeError::Status(404, "https://lyrabooru.org/post/list/sunset/1".into());
        assert!(empty_listing(&missing, true), "a searched 404 is an empty result");
        // A plain browse that 404s is a manifest pointing at the wrong place.
        assert!(!empty_listing(&missing, false), "a browse 404 is still a real failure");
    }

    /// Everything else stays a failure whether or not words were sent — a 520
    /// or a timeout says nothing about whether the tag has posts.
    #[test]
    fn other_statuses_are_still_failures() {
        for status in [403u16, 429, 500, 520] {
            let error = ScrapeError::Status(status, "https://furbooru.org/".into());
            assert!(!empty_listing(&error, true), "{status} must stay a failure");
        }
    }
}

/*
 * THE OLDER TUBE SITES, WHICH COULD NOT PLAY AT ALL.
 *
 * Reported as "some nsfw websites like the old ones cannot play video" and confirmed
 * against the live daemon: hqporner, porntrex and rule34video all answered
 * `resolve` with "no video on that page" while xvideos, eporner, redtube, tube8 and
 * xhamster worked.
 *
 * The inputs below are the shapes those three pages actually serve, captured on
 * 2026-09-27 and trimmed to the part that matters — the URLs and quality labels, none
 * of the content.
 */
#[cfg(test)]
mod tube_video_tests {

    /*
     * A `<source>` WITH NO SCHEME.
     *
     * Exactly the shape hqporner's older films serve, through flyflv: the mp4
     * is right there in the markup and begins `//`, which every browser
     * resolves against the page and the scan did not. 5 of 7 sampled videos
     * answered "no video on that page" because of it.
     */
    #[test]
    fn a_protocol_relative_source_is_a_playable_file() {
        let html = concat!(
            "<video poster='https://static.example/7.jpg' controls>",
            "<source src='//video.example/key=AbC,end=1790811031,ip=1.2.3.4/buffer=1600K/hd/3376.mp4'",
            " type='video/mp4' label='720p' default/>",
            "<source src='//video.example/key=XyZ,end=1790811031,ip=1.2.3.4/speed=89600/sd/3376.mp4'",
            " type='video/mp4' label='480p'/>",
            "</video>"
        );
        let found = loose_media_urls(html, "https://example.test/movies/player/3376");
        assert_eq!(found.len(), 2, "both qualities: {found:?}");
        assert!(
            found.iter().all(|(u, _)| u.starts_with("https://video.example/")),
            "not resolved against the page: {found:?}"
        );
        assert!(found[0].0.ends_with("/hd/3376.mp4"), "{found:?}");
    }

    /// The `//` inside a scheme must not be touched — it is preceded by a colon,
    /// which is why the leading character is captured rather than assumed.
    #[test]
    fn an_absolute_url_is_left_alone() {
        let html = "<source src=\"https://video.example/a/720.mp4\">";
        let found = loose_media_urls(html, "https://example.test/x");
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0].0, "https://video.example/a/720.mp4");
    }
    use super::*;

    /// porntrex, verbatim apart from the whitespace the page pads it with.
    const PORNTREX: &str = r#"flashvars = {
        video_id: '2836667',
        license_code: '$535555517668914',
        video_url: 'https://www.porntrex.com/get_file/22/7dca/2836000/2836667/2836667.mp4/',
        postfix: '.mp4',
        video_url_text: '480p',
        video_alt_url: 'https://www.porntrex.com/get_file/22/f044/2836000/2836667/2836667_720p.mp4/',
        video_alt_url_text: '720p HD',
        video_alt_url2: 'https://www.porntrex.com/get_file/22/0b9e/2836000/2836667/2836667_1080p.mp4/',
        video_alt_url2_text: '1080p FHD',
    }"#;

    /*
     * The trailing slash after `.mp4` is the entire first bug. Every one of these
     * files was found and then thrown away as "not playable".
     */
    #[test]
    fn a_url_with_a_slash_between_the_extension_and_the_query_is_playable() {
        assert!(playable_url("https://x.test/a/2836667_1080p.mp4/"));
        assert!(playable_url("https://x.test/a/4000813_360.mp4/?v-acctoken=abc"));
        assert!(playable_url("https://x.test/a/clip.mp4"));
        assert!(playable_url("https://x.test/a/stream.m3u8?sig=1"));
        assert!(!playable_url("https://x.test/video/2836667/some-title"));
        assert!(!playable_url("https://x.test/thumb.jpg"));
    }

    #[test]
    fn every_quality_in_a_kvs_flashvars_block_is_found_with_the_sites_own_label() {
        let found = kvs_flashvars(PORNTREX, "https://www.porntrex.com/video/2836667/x");
        assert_eq!(found.len(), 3, "480p, 720p and 1080p: {found:?}");

        // Best first — the viewer takes the head when nothing was asked for.
        assert_eq!(found[0].1, "1080p FHD");
        assert!(found[0].0.ends_with("2836667_1080p.mp4/"), "{:?}", found[0].0);
        assert_eq!(found[2].1, "480p");
    }

    /// rule34video is the same engine with a token on the query.
    #[test]
    fn a_kvs_url_carrying_a_query_token_survives() {
        let html = "flashvars = { license_code: '$611881720187049', \
                     video_url: 'https://rule34video.com/get_file/54/42f6/4000813_360.mp4/?v-acctoken=MTEy', \
                     video_url_text: '360p' }";
        let found = kvs_flashvars(html, "https://rule34video.com/video/4000813/x/");
        assert_eq!(found.len(), 1);
        assert!(found[0].0.contains("v-acctoken="), "the token must not be trimmed off");
    }

    /*
     * An obfuscated KVS path needs `license_code` to unpick and this does not do it.
     * Skipping is the honest answer; handing a player `function/0/...` would be a URL
     * that 404s, and a silent wrong answer is the failure being fixed here.
     */
    #[test]
    fn an_obfuscated_kvs_path_is_skipped_rather_than_guessed_at() {
        let html = "flashvars = { video_url: 'function/0/https://x.test/get_file/1/enc.mp4/', \
                     video_url_text: '720p' }";
        assert!(kvs_flashvars(html, "https://x.test/video/1/").is_empty());
    }

    #[test]
    fn a_page_with_no_flashvars_is_no_videos_rather_than_a_panic() {
        for html in ["", "<html><body>nothing</body></html>", "flashvars", "flashvars = {}"] {
            assert!(kvs_flashvars(html, "https://x.test/p").is_empty(), "{html:?}");
        }
    }

    /*
     * hqporner's player writes its markup inside a JavaScript string, so every quote
     * is escaped. Captured from mydaddy.cc, which is where its iframe leads.
     */
    #[test]
    fn source_tags_with_escaped_quotes_are_found() {
        let html = r#"var player = "<video><source src=\"//s52.bigcdn.cc/pubs/6ab9/360.mp4\" title=\"360p\" type=\"video/mp4\" />\
            <source src=\"//s52.bigcdn.cc/pubs/6ab9/1080.mp4\" title=\"1080p Full HD\" type=\"video/mp4\" /></video>";"#;
        let found = videos_on_page(html, "https://mydaddy.cc/video/afb4ae095e2640ecca/");
        assert_eq!(found.len(), 2, "{found:?}");
        assert!(found.iter().any(|(u, _)| u.ends_with("1080.mp4")));
        assert!(found.iter().all(|(u, _)| u.starts_with("https://")), "made absolute: {found:?}");
    }

    /// The hop that makes hqporner work at all — and the ad iframes it must not take.
    #[test]
    fn a_player_iframe_is_followed_and_an_ad_iframe_is_not() {
        let html = r#"
            <iframe width="300" height="250" src="https://ads.exosrv.com/iframe.php?id=9"></iframe>
            <iframe width="560" height="350" src="//mydaddy.cc/video/afb4ae095e2640ecca/"></iframe>
            <iframe src="https://googlesyndication.com/embed/x"></iframe>
        "#;
        let frames = player_iframes(html, "https://hqporner.com/hdporn/123187-x.html");
        assert_eq!(frames, vec!["https://mydaddy.cc/video/afb4ae095e2640ecca/"], "{frames:?}");
    }

    /*
     * youjizz keeps its files in a JavaScript object with escaped slashes, and its
     * `og:video` points at the page rather than a file — so every structured pattern
     * correctly found nothing, and the clip was sitting in the text all along.
     */
    #[test]
    fn a_file_hidden_behind_escaped_slashes_is_found_as_a_last_resort() {
        let html = r#"{"quality":"720","filename":"https:\/\/cdne-pics.youjizz.com\/1\/b\/a\/1ba9-1280-720-1279-h264.mp4"}"#;
        let found = videos_on_page(html, "https://www.youjizz.com/videos/x-54273261.html");
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0].0, "https://cdne-pics.youjizz.com/1/b/a/1ba9-1280-720-1279-h264.mp4");
        assert_eq!(found[0].1, "720p");
    }

    /*
     * spankwire's URLs are signed and the query is HTML-escaped. Without decoding
     * `&amp;` the URL keeps only its first parameter and the host answers 403 — a
     * failure that looks like a dead link rather than a parsing mistake.
     */
    #[test]
    fn an_html_escaped_query_string_is_decoded_or_the_signature_is_lost() {
        let html = r#"<script>var s = "https://ev-ph.ypncdn.com/videos/1080P_4000K_1.mp4?validfrom=1790528202&amp;validto=1790535402&amp;hash=abc";</script>"#;
        let found = videos_on_page(html, "https://www.spankwire.com/watch/209815991/");
        assert_eq!(found.len(), 1, "{found:?}");
        assert!(found[0].0.contains("&validto="), "every parameter must survive: {:?}", found[0].0);
        assert!(found[0].0.contains("&hash=abc"));
        assert_eq!(found[0].1, "1080p");
    }

    /*
     * The dangerous case for a loose scan: the hover preview is a real clip of the
     * right film, three seconds long, and it is on the page next to the real one.
     */
    #[test]
    fn the_loose_scan_leaves_previews_and_advertising_alone() {
        let html = r#"
            <script>
              var ad = "https://a.adtng.com/spot/banner.mp4";
              var hover = "https://cdn.test/preview/2836667_preview.mp4";
              var real = "https://cdn.test/videos/2836667_1080p.mp4";
            </script>"#;
        let found = loose_media_urls(html, "https://x.test/p");
        assert_eq!(found.len(), 1, "{found:?}");
        assert!(found[0].0.ends_with("2836667_1080p.mp4"));
    }

    /// It must not fire while a structured answer exists, or a page with both would
    /// hand back advertising alongside its film.
    #[test]
    fn the_loose_scan_is_a_last_resort_only() {
        let html = r#"<video><source src="https://cdn.test/real_720p.mp4"></video>
                      <script>var ad = "https://cdn.test/other_1080p.mp4";</script>"#;
        let found = videos_on_page(html, "https://x.test/p");
        assert_eq!(found.len(), 1, "the <source> wins outright: {found:?}");
        assert!(found[0].0.ends_with("real_720p.mp4"));
    }

    #[test]
    fn an_iframe_that_is_plainly_not_a_player_is_left_alone() {
        let html = r#"<iframe src="https://x.test/comments/thread?id=1"></iframe>
                      <iframe src="https://x.test/banner.html"></iframe>"#;
        assert!(player_iframes(html, "https://x.test/p").is_empty());
    }
}

/*
 * AN INSTALLED FIX AND A RUNNING FIX LOOK IDENTICAL FROM OUTSIDE.
 *
 * That is the whole bug this answers: `version` reports what is on disk, so a
 * daemon left over from before an upgrade reports the new number while running
 * the old code. Four debugging rounds here ended at "the fix is right and does
 * nothing" before anyone thought to check `/proc/<pid>/exe`.
 */
#[cfg(test)]
mod staleness_tests {
    use super::*;

    fn known() -> BinaryFingerprint {
        BinaryFingerprint { path: std::path::PathBuf::from("/usr/bin/quarryd"), ino: 42, len: 1000 }
    }

    #[test]
    fn the_same_file_is_not_stale() {
        assert!(!binary_was_replaced(&known(), Some((42, 1000))));
    }

    /// A package upgrade writes a new file at the same path: new inode.
    #[test]
    fn a_replaced_file_is_stale() {
        assert!(binary_was_replaced(&known(), Some((99, 1000))), "new inode not noticed");
    }

    /// Belt and braces for a filesystem that reuses an inode number: the size
    /// of a rebuilt binary is essentially never identical.
    #[test]
    fn a_same_inode_different_size_file_is_stale() {
        assert!(binary_was_replaced(&known(), Some((42, 1001))), "new length not noticed");
    }

    /*
     * Gone is not stale. An uninstall, or a build directory cleaned out from
     * under a daemon started from `target/release`, leaves this process as the
     * only copy there is — telling someone to restart it would send them to
     * start a binary that no longer exists.
     */
    #[test]
    fn a_missing_file_is_not_called_stale() {
        assert!(!binary_was_replaced(&known(), None));
    }
}

/*
 * NINE SECONDS OF SOMEBODY ELSE'S VIDEO.
 *
 * The pornhub family keeps the real file behind an endpoint, and a YouPorn page
 * carries 37 `…_fb.mp4` hover previews for the related-videos rail. The page
 * scan walked past the endpoint (no media extension on it) and happily took the
 * previews — so YouPorn played a nine-second clip of a different video, which
 * is a failure that looks like a working player.
 */
#[cfg(test)]
mod media_definition_tests {
    use super::*;

    const PAGE: &str = r#"
        <script>
        var flashvars = {"mediaDefinitions":[
          {"format":"hls","videoUrl":"https:\/\/www.youporn.com\/media\/hls\/?s=abc"},
          {"format":"mp4","videoUrl":"https:\/\/www.youporn.com\/media\/mp4\/?s=abc"}
        ]};
        </script>
        <a href="https://ev-ph.ypncdn.com/videos/1/360P_360K_111_fb.mp4">related</a>
    "#;

    /// The mp4 endpoint is preferred over the hls one — see the note on the
    /// function for why the proxy cannot serve a playlist.
    #[test]
    fn the_mp4_endpoint_is_picked_not_the_hls_one() {
        let ask = media_definition_request(PAGE).expect("an endpoint");
        assert!(ask.contains("/media/mp4/"), "{ask}");
        assert!(!ask.contains("/media/hls/"), "{ask}");
    }

    /// A direct file needs no second request; the ordinary page scan has it.
    #[test]
    fn a_direct_file_is_not_treated_as_an_endpoint() {
        let page = r#"{"format":"mp4","videoUrl":"https:\/\/cdn.test\/720P_1500K_9.mp4"}"#;
        assert!(media_definition_request(page).is_none());
    }

    /// What the endpoint answers: real qualities, best first.
    #[test]
    fn the_answer_becomes_renditions_best_first() {
        let answer = r#"[
          {"format":"mp4","quality":"480","videoUrl":"https://cdn.test/480P_2000K_9.mp4?h=x"},
          {"format":"mp4","quality":"1080","videoUrl":"https://cdn.test/1080P_4000K_9.mp4?h=x"},
          {"format":"mp4","quality":"720","videoUrl":"https://cdn.test/720P_4000K_9.mp4?h=x"}
        ]"#;
        let found = media_definition_videos(answer);
        let labels: Vec<&str> = found.iter().map(|(_, l)| l.as_str()).collect();
        assert_eq!(labels, vec!["1080p", "720p", "480p"], "not sorted best first");
        assert!(found[0].0.contains("1080P_4000K"));
    }

    /// pornhub answers `[]` for a video it only publishes as HLS. That is an
    /// honest empty, not a parse failure, and must not panic or invent a row.
    #[test]
    fn an_empty_answer_is_simply_no_renditions() {
        assert!(media_definition_videos("[]").is_empty());
        assert!(media_definition_videos("not json at all").is_empty());
    }
}

/*
 * Opening a 3D model was broken for every source at once, and the symptom was
 * a JSON parse error — which reads as a corrupt download rather than as the
 * app asking the wrong URL. These pin the mapping that fixes it.
 */
#[cfg(test)]
mod model_manifest_tests {
    use super::model_manifest_url;

    #[test]
    fn poly_haven_asks_the_files_api_for_the_asset() {
        let got = model_manifest_url(
            "polyhaven_mod",
            "polyhaven_mod:antique_estoc",
            "https://cdn.polyhaven.com/asset_img/thumbs/antique_estoc.png?width=256",
        );
        assert_eq!(got, Ok("https://api.polyhaven.com/files/antique_estoc".to_string()));
    }

    /// The thumbnail in the row is never the manifest — this is the whole bug.
    #[test]
    fn the_rows_thumbnail_is_not_used_as_a_manifest() {
        let thumb = "https://cdn.polyhaven.com/asset_img/thumbs/stone_fire_pit.png";
        let got = model_manifest_url("polyhaven_mod", "polyhaven_mod:stone_fire_pit", thumb).unwrap();
        assert!(!got.contains("asset_img"), "asked for the thumbnail: {got}");
        assert!(got.ends_with("/files/stone_fire_pit"));
    }

    #[test]
    fn sketchfab_says_why_rather_than_failing_on_a_png() {
        let err = model_manifest_url(
            "sketchfab",
            "sketchfab:184f49c680ea4955957cd37fd8ef5068",
            "https://media.sketchfab.com/models/184f/thumbnails/a.jpeg",
        )
        .unwrap_err();
        assert!(err.to_lowercase().contains("account"), "unhelpful: {err}");
    }

    #[test]
    fn an_unknown_source_pointing_at_an_image_is_refused_in_words() {
        let err = model_manifest_url("somewhere", "somewhere:1", "https://x.test/a.png").unwrap_err();
        assert!(err.contains("does not say where"), "unhelpful: {err}");
    }

    #[test]
    fn an_unknown_source_with_a_json_url_is_still_tried() {
        let got = model_manifest_url("somewhere", "somewhere:1", "https://x.test/files.json");
        assert_eq!(got, Ok("https://x.test/files.json".to_string()));
    }
}

#[cfg(test)]
mod hover_preview_tests {
    use super::*;

    /// A redtube-shaped page: the film behind a relative `/media/mp4`, and the
    /// related-videos rail full of `_fb.mp4` previews of OTHER videos.
    const PAGE: &str = r#"<script>var page_params = {"mediaDefinitions":[{"format":"mp4","videoUrl":"\/media\/mp4?s=fixtureSignature","remote":true}]};</script>
<div class="related"><video src="https://cdn.fixture.example/videos/202401/01/111/360P_360K_111_fb.mp4?validto=1&amp;hash=a"></video>
<video src="https://cdn.fixture.example/videos/202402/02/222/360P_360K_222_fb.mp4?validto=1&amp;hash=b"></video></div>"#;

    #[test]
    fn a_hover_preview_is_not_the_video() {
        assert!(is_hover_preview("https://cdn.fixture.example/v/360P_360K_111_fb.mp4?validto=1"));
        assert!(!is_hover_preview("https://cdn.fixture.example/v/200102_1132_720P_4000K_111.mp4?validto=1"));
        let found = videos_on_page(PAGE, "https://www.fixture.example/111");
        assert!(found.iter().all(|(url, _)| !url.contains("_fb.mp4")), "{found:?}");
    }

    #[test]
    fn the_players_own_endpoint_is_found_and_made_absolute() {
        assert_eq!(
            media_indexes(PAGE, "https://www.fixture.example/111"),
            vec!["https://www.fixture.example/media/mp4?s=fixtureSignature".to_string()]
        );
        let files = media_index_files(
            r#"[{"format":"mp4","quality":"720","videoUrl":"https:\/\/cdn.fixture.example\/v\/720P_4000K_111.mp4"},{"format":"mp4","quality":"240","videoUrl":"https:\/\/cdn.fixture.example\/v\/240P_1000K_111.mp4"}]"#,
            "https://www.fixture.example/111",
        );
        assert_eq!(files[0], ("https://cdn.fixture.example/v/720P_4000K_111.mp4".to_string(), "720p".to_string()));
    }
}
